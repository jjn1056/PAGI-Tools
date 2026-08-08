package PAGI::Routing::Compiler;

use strict;
use warnings;
use Carp qw(croak);
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(blessed refaddr);
use PAGI::Context;
use PAGI::Routing::HeadBoundary ();
use PAGI::Routing::Middleware ();
use PAGI::Routing::Resolver ();
use PAGI::Utils ();

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
        my $type = $scope->{type} // 'http';
        return if $type eq 'lifespan';
        croak "unsupported PAGI scope type '$type'"
            unless $type eq 'http' || $type eq 'websocket' || $type eq 'sse';

        my ($head_scope, $wire_send)
            = PAGI::Routing::HeadBoundary->prepare($scope, $send);
        my $routing_scope = $class->_routing_scope($head_scope, $resolver);

        my $returned = $app->($routing_scope, $receive, $wire_send);
        await Future->wrap($returned);
        return;
    };
}

sub _compile_router_body {
    my ($class, $router, $resolver, $location_prefix) = @_;

    my $not_found_handler = $router->not_found || sub {
        my ($context) = @_;
        return $context->text('Not Found');
    };
    my $method_not_allowed_handler = $router->method_not_allowed || sub {
        my ($context) = @_;
        return $context->text('Method Not Allowed');
    };
    my $not_found = $class->_compile_generated_handler(
        $not_found_handler,
        404,
    );
    my $method_not_allowed = $class->_compile_generated_handler(
        $method_not_allowed_handler,
        405,
    );
    my $dispatcher = $class->_compile_dispatcher(
        $router->routes,
        $not_found,
        $method_not_allowed,
        $resolver,
        $location_prefix,
    );

    return PAGI::Routing::Middleware->_wrap_descriptors(
        $router->middleware,
        $dispatcher,
    );
}

sub _compile_dispatcher {
    my ($class, $nodes, $not_found, $method_not_allowed, $resolver,
        $location_prefix) = @_;

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

        my $mounted_app;
        if ($node->is_raw) {
            my $target = PAGI::Utils::to_app($node->target);
            $mounted_app = async sub {
                my ($scope, $receive, $send) = @_;
                my $returned = $target->($scope, $receive, $send);
                await Future->wrap($returned);
                return;
            };
        }
        elsif (defined $node->router) {
            $mounted_app = $class->_compile_router_body(
                $node->router,
                $resolver,
                \@location,
            );
        }
        else {
            $mounted_app = $class->_compile_dispatcher(
                $node->routes,
                $not_found,
                $method_not_allowed,
                $resolver,
                \@location,
            );
        }

        $mounted_app = PAGI::Routing::Middleware->_wrap_descriptors(
            $node->middleware,
            $mounted_app,
        );
        push @compiled_entries, {
            mount => $node,
            metadata => $metadata,
            app   => $mounted_app,
        };
    }

    return async sub {
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

        my $decision = $class->_select_http(\@compiled_entries, $scope);

        if ($decision->{kind} eq 'full') {
            my $returned = $decision->{app}->(
                $decision->{scope},
                $receive,
                $send,
            );
            await Future->wrap($returned);
            return;
        }

        if ($decision->{kind} eq 'partial') {
            my $allow = join ', ', @{$decision->{allowed_methods}};
            my $provenance = {};
            my $generated_send = $class->_generated_allow_send(
                $send,
                $allow,
                $provenance,
            );
            my $returned = $method_not_allowed->(
                $scope,
                $receive,
                $generated_send,
                $allow,
                $provenance,
            );
            await Future->wrap($returned);
            return;
        }

        my $returned = $not_found->($scope, $receive, $send);
        await Future->wrap($returned);
        return;
    };
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
    my ($class, $handler, $policy) = @_;

    return async sub {
        my ($scope, $receive, $send, @policy_arguments) = @_;
        my $context = PAGI::Context->new($scope, $receive, $send);
        my $policy_state = $policy
            ? $policy->{before}->($context, @policy_arguments)
            : undef;
        my $returned = $handler->($context);
        my $result = await Future->wrap($returned);

        croak 'handler did not return a response'
            unless PAGI::Utils::is_response($result);

        $policy->{after}->($result, $policy_state) if $policy;
        await $context->respond($result);
        return;
    };
}

sub _compile_generated_handler {
    my ($class, $handler, $status) = @_;

    my $policy = {
        before => sub {
            my ($context, $allow, $provenance) = @_;
            $provenance ||= {};
            my $seeded = $context->response->status($status);
            $seeded->header('Allow' => $allow)
                if $status == 405 && defined $allow;
            $provenance->{seed_identity} = refaddr($seeded);
            return $provenance;
        },
        after => sub {
            my ($result, $state) = @_;
            $state->{returned_seed} = refaddr($result) == $state->{seed_identity}
                ? 1
                : 0;
        },
    };

    return $class->_compile_http_handler($handler, $policy);
}

sub _generated_allow_send {
    my ($class, $send, $allow, $provenance) = @_;

    return sub {
        my ($event) = @_;
        return $send->($event)
            unless ($event->{type} // '') eq 'http.response.start';

        my $headers = ref($event->{headers}) eq 'ARRAY'
            ? $event->{headers}
            : [];

        if (($event->{status} // 0) == 405) {
            for my $pair (@$headers) {
                return $send->($event)
                    if ref($pair) eq 'ARRAY'
                        && defined $pair->[0]
                        && lc($pair->[0]) eq 'allow';
            }

            return $send->({
                %$event,
                headers => [@$headers, ['Allow' => $allow]],
            });
        }

        return $send->($event) unless $provenance->{returned_seed};

        my @filtered;
        my $removed_seed;
        for my $pair (@$headers) {
            if (!$removed_seed
                    && ref($pair) eq 'ARRAY'
                    && defined $pair->[0]
                    && lc($pair->[0]) eq 'allow'
                    && defined $pair->[1]
                    && $pair->[1] eq $allow) {
                $removed_seed = 1;
                next;
            }
            push @filtered, $pair;
        }

        return $send->($event) unless $removed_seed;
        return $send->({
            %$event,
            headers => \@filtered,
        });
    };
}

sub _select_http {
    my ($class, $compiled_entries, $scope) = @_;

    my $path = defined $scope->{path} ? $scope->{path} : '/';
    my $method = uc(defined $scope->{method} ? $scope->{method} : '');
    my @allowed_methods;
    my %method_seen;

    for my $entry (@$compiled_entries) {
        if (my $mount = $entry->{mount}) {
            my $match = $mount->_pattern->match_mount($path);
            next unless defined $match;

            $class->_record_mount_match(
                $scope, $entry->{metadata}, $match->{captures},
            );

            return {
                kind  => 'full',
                app   => $entry->{app},
                scope => $class->_mount_scope($scope, $match),
            };
        }

        my $route = $entry->{route};
        next unless $route->kind eq 'route';
        my $captures = $route->_pattern->match_route($path);
        next unless defined $captures;

        my $methods = $route->methods;
        my $method_matches = !ref($methods) && $methods eq '*'
            ? 1
            : grep { $_ eq $method } @$methods;

        if ($method_matches) {
            $class->_record_leaf_match(
                $scope, $entry->{metadata}, $captures,
            );
            my %path_params = (
                %{ref($scope->{path_params}) eq 'HASH' ? $scope->{path_params} : {}},
                %$captures,
            );
            my $matched_scope = {
                %$scope,
                path_params => \%path_params,
            };
            return {
                kind => 'full',
                app => $entry->{app},
                scope => $matched_scope,
            };
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

sub _select_protocol {
    my ($class, $compiled_entries, $scope, $protocol) = @_;

    my $path = defined $scope->{path} ? $scope->{path} : '/';
    for my $entry (@$compiled_entries) {
        if (my $mount = $entry->{mount}) {
            my $match = $mount->_pattern->match_mount($path);
            next unless defined $match;

            $class->_record_mount_match(
                $scope, $entry->{metadata}, $match->{captures},
            );

            return {
                kind  => 'full',
                app   => $entry->{app},
                scope => $class->_mount_scope($scope, $match),
            };
        }

        my $route = $entry->{route};
        next unless $route->kind eq $protocol;
        my $captures = $route->_pattern->match_route($path);
        next unless defined $captures;

        $class->_record_leaf_match(
            $scope, $entry->{metadata}, $captures,
        );

        my %path_params = (
            %{ref($scope->{path_params}) eq 'HASH' ? $scope->{path_params} : {}},
            %$captures,
        );
        return {
            kind => 'full',
            app => $entry->{app},
            scope => {
                %$scope,
                path_params => \%path_params,
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
            && $frame->{resolver}->can('path_for');
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

    if ($metadata->{is_raw}) {
        $frame->{match} = { %{$metadata->{match}} };
        return;
    }

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

    my %path_params = (
        %{ref($scope->{path_params}) eq 'HASH' ? $scope->{path_params} : {}},
        %{$match->{captures}},
    );
    my $child_scope = {
        %$scope,
        path_params => \%path_params,
    };

    if (length $match->{consumed}) {
        $child_scope->{path} = $match->{remainder};
        $child_scope->{root_path} = $class->_join_path_boundary(
            $scope->{root_path},
            $match->{consumed},
        );
    }

    return $child_scope;
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
decisions invoke their selected leaf or declaration-ordered mount, while
partial and none decisions are rendered through the normal handler adapter as
generated 405 and 404 responses. Inline mounts inherit those handlers with a
fresh local Allow set. Application mounts remain opaque after their prefix
matches. Generated response and Allow state remain request-local.

An explicit C<< router => $child >> mount is transparent to composed route
inspection but is a child dispatch boundary at runtime. Once its prefix
matches, the child Router owns its full, partial, none, WebSocket, and SSE
outcomes; the parent neither resumes scanning nor unions its Allow methods.
The child contributes its own generated handlers, dispatcher, and Router
middleware. The containing Resolver supplies placement-specific effective
metadata without mutating the child description or invoking the child's public
C<to_app> boundary.

The executable nesting order is outer Router middleware, Router-mount
middleware, child Router middleware, any selected inline-mount middleware,
route middleware, and handler. Mount middleware therefore also surrounds the
child's generated and protocol-miss outcomes. Each placement is compiled
independently, and each public compilation constructs another fresh set of
middleware wrappers.

C<compile> is a synchronous build-time boundary: it resolves middleware,
native components, match entries, and fallback adapters but starts no request
and emits no events. It returns a native async PAGI coderef. Invocation of that
coderef installs exactly one fresh request-local C<pagi.routing> frame and one
outermost HEAD wire boundary. Mounted Router bodies share that frame and HEAD
owner, so all middleware sees the complete downstream match and the
unsuppressed GET representation before HEAD body and sendfile suppression at
the edge. The compiler matches the request, adapts synchronous and
Future-backed completions, and emits or forwards the appropriate protocol
events.

Compatible version-1 routing metadata contributes ancestor frames. Opaque,
malformed, or newer metadata is preserved on the incoming scope as an
incompatible boundary: the new shallow child scope receives a fresh version-1
container and ignores foreign ancestry rather than croaking or mutating it.
Each frame captures the compiled router's entry C<root_path>; Context reverse
routing uses that field and falls back only for legacy/manual v1 frames that
omit it. Every API-created frame also begins with canonical
C<logical_namespace> C</> and a fresh empty C<captures> hash. Entering an
inline or Router mount replaces both values with that placement's namespace
and a fresh snapshot of consumed effective-prefix captures. A FULL leaf
replaces them with its containing namespace and complete effective captures.
PARTIAL candidates never publish leaf state, so generated 404 and 405 handlers
retain only the namespace and prefix snapshot owned by their selected mount
ancestry. The capture hash is never aliased to C<< scope->{path_params} >> and
no mutable frame state is shared between requests.

=cut
