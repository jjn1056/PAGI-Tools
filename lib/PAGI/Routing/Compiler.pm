package PAGI::Routing::Compiler;

use strict;
use warnings;
use Carp qw(croak);
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(blessed);
use PAGI::Context;
use PAGI::Routing::HeadBoundary ();
use PAGI::Routing::Middleware ();
use PAGI::Routing::Resolver ();
use PAGI::Utils ();

my $TRACE_RECORDER_FOR;
my $TRACE_PARENT_KEY = "\0PAGI::Routing::Trace::parent";
BEGIN {
    require PAGI::Routing::Trace;
    PAGI::Routing::Trace->_claim_compiler_recorder_factory(sub {
        ($TRACE_RECORDER_FOR) = @_;
    });
}

sub compile {
    my ($class, $description) = @_;

    croak 'routing description is required'
        unless blessed($description);

    if ($description->isa('PAGI::Routing::Route')
            || $description->isa('PAGI::Routing::Mount')) {
        require PAGI::Routing::Router;
        $description = PAGI::Routing::Router->new(routes => [$description]);
    }

    croak 'unsupported routing description'
        unless $description->isa('PAGI::Routing::Router');

    return $class->_compile_router($description);
}

sub _compile_router {
    my ($class, $router) = @_;

    my $resolver = $router->_resolver;
    my $app = $class->_compile_router_body($router, $resolver, []);

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $type = $scope->{type};
        croak 'PAGI scope type is required'
            unless defined($type) && !ref($type) && length($type);
        return if $type eq 'lifespan';
        croak "unsupported PAGI scope type '$type'"
            unless $type eq 'http' || $type eq 'websocket' || $type eq 'sse';

        my ($head_scope, $wire_send)
            = PAGI::Routing::HeadBoundary->prepare($scope, $send);
        my $routing_scope = $class->_routing_scope($head_scope, $resolver);
        my ($trace_scope) = PAGI::Routing::Trace->_ensure_http_scope(
            $routing_scope,
        );

        my $returned = $app->($trace_scope, $receive, $wire_send);
        await Future->wrap($returned);
        return;
    };
}

sub _compile_router_body {
    my ($class, $router, $resolver, $location_prefix, $enter_child) = @_;

    $location_prefix = [] unless $enter_child;

    my $dispatcher = $class->_compile_dispatcher(
        $router->routes,
        $resolver,
        $location_prefix,
        'router',
    );

    return PAGI::Routing::Middleware->_wrap_descriptors(
        $router->middleware,
        $dispatcher,
    );
}

sub _compile_dispatcher {
    my ($class, $nodes, $resolver, $location_prefix, $frame_kind) = @_;

    $location_prefix ||= [];

    my @compiled_entries;
    for my $index (0 .. $#$nodes) {
        my $node = $nodes->[$index];
        my @location = (@$location_prefix, $index);
        my $metadata = $resolver
            ? $resolver->_metadata_for_location(\@location)
            : undef;

        if ($node->isa('PAGI::Routing::Route')) {
            push @compiled_entries, {
                route => $node,
                metadata => $metadata,
                app   => $node->kind eq 'route'
                    ? $class->_compile_http_leaf($node)
                    : $class->_compile_protocol_leaf($node),
            };
            next;
        }

        next unless $node->isa('PAGI::Routing::Mount');

        push @compiled_entries, {
            mount => $node,
            metadata => $metadata,
            app   => $class->_compile_mounted_app(
                $node,
                $resolver,
                \@location,
            ),
        };
    }

    my $dispatch = async sub {
        my ($scope, $receive, $send) = @_;
        my $type = $scope->{type} // 'http';

        if ($type eq 'websocket' || $type eq 'sse') {
            my $decision = $class->_select_protocol(
                \@compiled_entries,
                $scope,
                $type,
            );
            if ($decision->{kind} eq 'full') {
                my $returned = $decision->{app}->(
                    $decision->{scope},
                    $receive,
                    $send,
                );
                await Future->wrap($returned);
                return;
            }

            await $class->_send_protocol_not_found($scope, $send);
            return;
        }

        my $trace = $scope->{'pagi.routing.trace'};
        my $recorder = $TRACE_RECORDER_FOR->($trace);
        my $parent_link = delete $scope->{$TRACE_PARENT_KEY};
        my $frame_id = $recorder->_begin_frame(
            { kind => $frame_kind // 'inline' },
            $parent_link,
        );

        my $decision;
        my $ok = eval {
            $decision = $class->_select_http(
                \@compiled_entries,
                $scope,
                $recorder,
                $frame_id,
            );

            if ($decision->{kind} eq 'full') {
                my $returned = $decision->{app}->(
                    $decision->{scope},
                    $receive,
                    $send,
                );
                await Future->wrap($returned);
            }
            1;
        };
        unless ($ok) {
            my $error = $@;
            $recorder->_complete_exception($frame_id);
            die $error;
        }

        if ($decision->{kind} eq 'partial') {
            $recorder->_complete_decline($frame_id, {
                path_matched => 1,
                method_matched => 0,
                allowed_methods => $decision->{allowed_methods},
            });
            return;
        }
        if ($decision->{kind} eq 'none') {
            $recorder->_complete_decline($frame_id, {
                path_matched => 0,
                method_matched => 0,
                allowed_methods => [],
            });
            return;
        }
        if (($decision->{_trace_selection} // '') eq 'child') {
            delete $decision->{scope}{$TRACE_PARENT_KEY};
            my $completed = eval {
                $recorder->_complete_child(
                    $frame_id,
                    $decision->{_trace_parent_link},
                );
                1;
            };
            unless ($completed) {
                my $error = $@;
                die $error
                    unless $error =~ /\Arouting parent link was not consumed by a child\b/;
                $recorder->_complete_success($frame_id);
            }
            return;
        }
        $recorder->_complete_success($frame_id);
        return;
    };

    return $dispatch;
}

sub _compile_mounted_app {
    my ($class, $mount, $root_resolver, $location) = @_;

    my $base = $mount->app;
    my $app = blessed($base) && $base->isa('PAGI::Routing::Router')
        ? $class->_compile_router_body(
            $base,
            $root_resolver,
            $location,
            1,
        )
        : PAGI::Utils::to_app($base);
    my $awaiting = async sub {
        my ($scope, $receive, $send) = @_;
        await Future->wrap($app->($scope, $receive, $send));
        return;
    };

    return PAGI::Routing::Middleware->_wrap_descriptors(
        $mount->middleware,
        $awaiting,
    );
}

async sub _send_protocol_not_found {
    my ($class, $scope, $send) = @_;
    my $type = $scope->{type};

    if ($type eq 'websocket'
            && !exists(($scope->{extensions} // {})->{'websocket.http.response'})) {
        await $send->({ type => 'websocket.close' });
        return;
    }

    my $prefix = "$type.http.response";
    await $send->({
        type    => "$prefix.start",
        status  => 404,
        headers => [['content-type', 'text/plain']],
    });
    await $send->({
        type => "$prefix.body",
        body => 'Not Found',
        more => 0,
    });
    return;
}

sub _compile_protocol_leaf {
    my ($class, $route) = @_;

    my $app;
    if ($route->is_raw) {
        my $raw_app = PAGI::Utils::to_app($route->target);
        $app = async sub {
            my ($scope, $receive, $send) = @_;
            my $returned = $raw_app->($scope, $receive, $send);
            await Future->wrap($returned);
            return;
        };
    }
    else {
        my $handler = $route->target;
        $app = async sub {
            my ($scope, $receive, $send) = @_;
            my $context = PAGI::Context->new($scope, $receive, $send);
            my $returned = $handler->($context);
            await Future->wrap($returned);
            return;
        };
    }

    return PAGI::Routing::Middleware->_wrap_descriptors(
        $route->middleware,
        $app,
    );
}

sub _compile_http_leaf {
    my ($class, $route) = @_;

    my $app;
    if ($route->is_raw) {
        my $raw_app = PAGI::Utils::to_app($route->target);
        $app = async sub {
            my ($scope, $receive, $send) = @_;
            my $returned = $raw_app->($scope, $receive, $send);
            await Future->wrap($returned);
            return;
        };
    }
    else {
        $app = $class->_compile_http_handler($route->target);
    }

    return PAGI::Routing::Middleware->_wrap_descriptors(
        $route->middleware,
        $app,
    );
}

sub _compile_http_handler {
    my ($class, $handler) = @_;

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $context = PAGI::Context->new($scope, $receive, $send);
        my $returned = $handler->($context);
        my $result = await Future->wrap($returned);

        croak 'handler did not return a response'
            unless PAGI::Utils::is_response($result);

        await $context->respond($result);
        return;
    };
}

sub _select_http {
    my ($class, $compiled_entries, $scope, $recorder, $frame_id) = @_;

    my $path = defined $scope->{path} ? $scope->{path} : '/';
    my $method = uc(defined $scope->{method} ? $scope->{method} : '');
    my @allowed_methods;
    my %method_seen;

    for my $entry (@$compiled_entries) {
        if (my $mount = $entry->{mount}) {
            my $match = $mount->_pattern->match_mount($path);
            $class->_record_trace_attempt(
                $recorder,
                $frame_id,
                $entry,
                defined($match) ? 1 : 0,
                defined($match) ? 1 : 0,
            );
            next unless defined $match;

            my $child_scope = $class->_mount_scope($scope, $match);
            $class->_record_mount_match(
                $scope, $entry->{metadata}, $match->{captures},
            );
            my $decision = {
                kind  => 'full',
                app   => $entry->{app},
                scope => $child_scope,
            };
            if ($recorder) {
                my $link = $recorder->_expect_child($frame_id);
                $decision->{scope} = {
                    %$child_scope,
                    $TRACE_PARENT_KEY => $link,
                };
                $decision->{_trace_selection} = 'child';
                $decision->{_trace_parent_link} = $link;
            }
            return $decision;
        }

        my $route = $entry->{route};
        unless ($route->kind eq 'route') {
            $class->_record_trace_attempt(
                $recorder, $frame_id, $entry, 0, 0,
            );
            next;
        }
        my $captures = $route->_pattern->match_route($path);
        my $methods = $route->methods;
        my $method_matches = defined($captures)
            && (!ref($methods) && $methods eq '*'
            ? 1
            : grep { $_ eq $method } @$methods);
        $class->_record_trace_attempt(
            $recorder,
            $frame_id,
            $entry,
            defined($captures) ? 1 : 0,
            $method_matches ? 1 : 0,
        );
        next unless defined $captures;

        if ($method_matches) {
            my $path_params = $class->_merge_path_params(
                $scope->{path_params},
                $captures,
                $path,
            );
            $class->_record_leaf_match(
                $scope, $entry->{metadata}, $captures,
            );
            my $matched_scope = {
                %$scope,
                path_params => $path_params,
            };
            my $decision = {
                kind => 'full',
                app => $entry->{app},
                scope => $matched_scope,
            };
            if ($recorder) {
                if ($route->is_raw) {
                    $recorder->_select_opaque($frame_id);
                    $decision->{scope} = $class->_shield_trace_scope(
                        $matched_scope,
                    );
                    $decision->{_trace_selection} = 'opaque';
                }
                else {
                    $recorder->_select_leaf($frame_id);
                    $decision->{_trace_selection} = 'leaf';
                }
            }
            return $decision;
        }

        for my $allowed (@$methods) {
            next if $method_seen{$allowed}++;
            push @allowed_methods, $allowed;
        }
    }

    return {
        kind => 'partial',
        allowed_methods => [@allowed_methods],
    } if @allowed_methods;

    return { kind => 'none' };
}

sub _record_trace_attempt {
    my ($class, $recorder, $frame_id, $entry, $path_matched,
        $method_matched) = @_;
    return unless $recorder;

    my $metadata = ref($entry->{metadata}) eq 'HASH'
        ? $entry->{metadata}
        : {};
    my $match = ref($metadata->{match}) eq 'HASH'
        ? $metadata->{match}
        : {};
    my $candidate_kind = $entry->{mount}
        ? 'mount'
        : $entry->{route}->kind;
    my $declaration = $entry->{mount} || $entry->{route};
    $recorder->_attempt($frame_id, {
        namespace      => $metadata->{logical_namespace},
        pattern        => $declaration->path,
        name           => $match->{name},
        desc           => $match->{desc},
        candidate_kind => $candidate_kind,
        path_matched   => $path_matched ? 1 : 0,
        method_matched => $method_matched ? 1 : 0,
    });
    return;
}

sub _shield_trace_scope {
    my ($class, $scope) = @_;
    return $scope unless (($scope->{type} // 'http') eq 'http');

    my $child_scope = { %$scope };
    delete $child_scope->{'pagi.routing.trace'};
    return $child_scope;
}

sub _select_protocol {
    my ($class, $compiled_entries, $scope, $protocol) = @_;

    my $path = defined $scope->{path} ? $scope->{path} : '/';
    for my $entry (@$compiled_entries) {
        if (my $mount = $entry->{mount}) {
            my $match = $mount->_pattern->match_mount($path);
            next unless defined $match;

            my $child_scope = $class->_mount_scope($scope, $match);
            $class->_record_mount_match(
                $scope, $entry->{metadata}, $match->{captures},
            );
            return {
                kind  => 'full',
                app   => $entry->{app},
                scope => $child_scope,
            };
        }

        my $route = $entry->{route};
        next unless $route->kind eq $protocol;
        my $captures = $route->_pattern->match_route($path);
        next unless defined $captures;

        my $path_params = $class->_merge_path_params(
            $scope->{path_params},
            $captures,
            $path,
        );
        $class->_record_leaf_match(
            $scope, $entry->{metadata}, $captures,
        );
        return {
            kind => 'full',
            app => $entry->{app},
            scope => {
                %$scope,
                path_params => $path_params,
            },
        };
    }

    return { kind => 'none' };
}

sub _routing_scope {
    my ($class, $scope, $resolver) = @_;

    my $root_path = defined $scope->{root_path} ? $scope->{root_path} : '';
    croak 'scope root_path must be a string' if ref($root_path);

    my @ancestor_frames;
    my $incoming = $scope->{'pagi.routing'};
    if ($class->_compatible_routing_container($incoming)) {
        @ancestor_frames = @{$incoming->{frames}};
    }

    my $frame = {
        resolver          => $resolver,
        root_path         => $root_path,
        logical_namespace => '/',
        captures          => {},
        mounts            => [],
        match             => undef,
    };
    my @frames = (@ancestor_frames, $frame);
    my $container = {
        version => 1,
        frames  => \@frames,
    };

    return {
        %$scope,
        'pagi.routing' => $container,
    };
}

sub _compatible_routing_container {
    my ($class, $container) = @_;

    return 0 unless ref($container) eq 'HASH';
    return 0 unless defined $container->{version}
        && !ref($container->{version})
        && $container->{version} eq '1';
    return 0 unless ref($container->{frames}) eq 'ARRAY';

    for my $frame (@{$container->{frames}}) {
        return 0 unless ref($frame) eq 'HASH';
        return 0 unless blessed($frame->{resolver})
            && $frame->{resolver}->can('path_for')
            && $frame->{resolver}->can('reverse_for_context');
        return 0 unless PAGI::Routing::Resolver::_is_canonical_namespace(
            $frame->{logical_namespace},
        );
        return 0 unless ref($frame->{captures}) eq 'HASH';
        return 0 unless ref($frame->{mounts}) eq 'ARRAY';
        return 0 if defined $frame->{match}
            && ref($frame->{match}) ne 'HASH';
        return 0 if exists $frame->{root_path}
            && (!defined $frame->{root_path} || ref($frame->{root_path}));
    }

    return 1;
}

sub _current_routing_frame {
    my ($class, $scope) = @_;
    return unless ref($scope) eq 'HASH';
    my $container = $scope->{'pagi.routing'};
    return unless ref($container) eq 'HASH';
    my $frames = $container->{frames};
    return unless ref($frames) eq 'ARRAY' && @$frames;
    my $frame = $frames->[-1];
    return ref($frame) eq 'HASH' ? $frame : undef;
}

sub _record_mount_match {
    my ($class, $scope, $metadata, $captures) = @_;
    return unless ref($metadata) eq 'HASH';
    my $frame = $class->_current_routing_frame($scope);
    return unless $frame;

    my %effective_captures = (
        %{ref($frame->{captures}) eq 'HASH' ? $frame->{captures} : {}},
        %{ref($captures) eq 'HASH' ? $captures : {}},
    );
    $frame->{logical_namespace} = $metadata->{logical_namespace};
    $frame->{captures} = { %effective_captures };

    push @{$frame->{mounts}}, { %{$metadata->{mount}} };
    return;
}

sub _record_leaf_match {
    my ($class, $scope, $metadata, $captures) = @_;
    return unless ref($metadata) eq 'HASH';
    my $frame = $class->_current_routing_frame($scope);
    return unless $frame;
    $frame->{match} = { %{$metadata->{match}} };
    $frame->{logical_namespace} = $metadata->{logical_namespace};
    my %effective_captures = (
        %{ref($frame->{captures}) eq 'HASH' ? $frame->{captures} : {}},
        %{ref($captures) eq 'HASH' ? $captures : {}},
    );
    $frame->{captures} = { %effective_captures };
    return;
}

sub _mount_scope {
    my ($class, $scope, $match) = @_;

    my $effective_path = defined $scope->{path} ? $scope->{path} : '/';
    my $path_params = $class->_merge_path_params(
        $scope->{path_params},
        $match->{captures},
        $effective_path,
    );
    my $child_scope = {
        %$scope,
        path_params => $path_params,
    };

    if (length $match->{consumed}) {
        $child_scope->{path} = $match->{remainder} eq ''
            ? '/'
            : $match->{remainder};
        $child_scope->{root_path} = $class->_join_path_boundary(
            $scope->{root_path},
            $match->{consumed},
        );
    }

    return $child_scope;
}

sub _merge_path_params {
    my ($class, $incoming, $captures, $effective_path) = @_;

    $incoming = {} unless ref($incoming) eq 'HASH';
    $captures = {} unless ref($captures) eq 'HASH';
    for my $name (sort keys %$captures) {
        croak "duplicate path parameter '$name' while entering '$effective_path'"
            if exists $incoming->{$name};
    }

    return {
        %$incoming,
        %$captures,
    };
}

sub _join_path_boundary {
    my ($class, $prefix, $suffix) = @_;
    $prefix = '' unless defined $prefix;
    chop $prefix if length($prefix) && substr($prefix, -1) eq '/'
        && length($suffix) && substr($suffix, 0, 1) eq '/';
    return $prefix . $suffix;
}

1;

__END__

=head1 NAME

PAGI::Routing::Compiler - Internal declarative routing compiler

=head1 DESCRIPTION

Compiles declarative routing descriptions into fresh application graphs. Full
decisions invoke their selected leaf or declaration-ordered mount. HTTP
partial and none decisions record a trusted decline and complete normally
without calling the send channel. A selected Mount delegates through its one
compiled child application and never resumes parent scanning. WebSocket and
SSE misses retain their protocol-specific denial and close outcomes.

For HTTP requests, a directly compiled Router also ensures a request-local
L<PAGI::Routing::Trace> and publishes trusted structural selection evidence.
Mounted Router frames preserve child ownership, while raw routes receive a
shallow scope without the parent collector.
Candidate detail is development-only, declaration-derived, and bounded by the
collector. WebSocket, SSE, and lifespan scopes do not install or modify this
HTTP evidence.

Direct Router compilation is therefore a routing component rather than a
complete HTTP application policy. Ordinary
L<PAGI::Middleware::Routing::NotFound> and
L<PAGI::Middleware::Routing::MethodNotAllowed> middleware may render declines
at Router or routing-aware Mount boundaries. The compiler itself neither
chooses HTTP fallback status nor seeds or repairs a response.

An explicit C<< app => $child >> Router Mount is inspectable for reverse
routing but remains a child application boundary at runtime. Once its prefix
matches, the child Router owns its full, partial, none, WebSocket, and SSE
outcomes; the parent neither resumes scanning nor unions its method evidence.
The child contributes its own dispatcher and Router middleware. The containing
Resolver supplies placement-specific effective metadata without mutating the
child description or invoking the child's public C<to_app> boundary.

This ownership is final after a matching Mount prefix. Unanswered child
completion bubbles only outward through the selected middleware boundaries;
it never resumes parent declaration scanning. A root Mount consumes no
prefix and leaves C<path> and C<root_path> unchanged.

The executable nesting order is outer Router middleware, Mount middleware,
child Router middleware, nested Mount middleware, route middleware, and
handler. Unanswered child completion unwinds through
those routing boundaries, allowing the first applicable fallback middleware
to respond; protocol-miss outcomes unwind through the same selected wrappers.
Each placement is compiled independently, and each public compilation
constructs another fresh set of middleware wrappers.

C<compile> is a synchronous build-time boundary: it resolves middleware,
native components, and match entries but starts no request and emits no events.
It returns a native async PAGI coderef. Invocation of that coderef installs
exactly one fresh request-local C<pagi.routing> frame and one outermost HEAD
wire boundary. Mounted Router bodies share that frame and HEAD owner, so all
middleware sees the complete downstream match and the unsuppressed GET
representation before HEAD body and sendfile suppression at the edge. The
compiler matches the request, adapts synchronous and Future-backed
completions, and emits or forwards only selected application and
protocol-specific events.

Compatible version-1 routing metadata contributes ancestor frames. Malformed
or newer metadata is preserved on the incoming scope as an
incompatible boundary: the new shallow child scope receives a fresh version-1
container and ignores foreign ancestry rather than croaking or mutating it.
Each frame captures the compiled router's entry C<root_path>; Context reverse
routing uses that field and falls back only for legacy/manual v1 frames that
omit it. Every API-created frame also begins with canonical
C<logical_namespace> C</> and a fresh empty C<captures> hash. Entering an
inspectable mounted Router replaces both values with that placement's logical
namespace and a fresh snapshot of consumed effective-prefix captures. A FULL
leaf replaces them with its containing logical namespace and complete
effective captures.
PARTIAL candidates never publish leaf state, so unanswered declines retain
only the logical namespace and prefix snapshot owned by their selected Mount
ancestry. The capture hash is never aliased to C<< scope->{path_params} >> and
no mutable frame state is shared between requests.

=cut
