package PAGI::Routing::Compiler;

use strict;
use warnings;
use Carp qw(croak);
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(blessed refaddr);
use PAGI::Context;
use PAGI::Pages ();
use PAGI::Routing::HeadBoundary ();
use PAGI::Routing::Middleware ();
use PAGI::Routing::Resolver ();
use PAGI::Utils ();

my $ALLOW_STATE_KEY = "\0PAGI::Routing::Compiler::allow";
my $ALLOW_STATE_TOKEN = sub { return };

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

sub _authoritative_allow_send {
    my ($class, $state, $send) = @_;

    return sub {
        my ($event) = @_;
        if (ref($event) eq 'HASH'
                && ($event->{type} // '') eq 'http.response.start'
                && ($event->{status} // 0) == 405
                && $state->{router_generated}) {
            my @headers = grep {
                !(ref($_) eq 'ARRAY'
                    && defined($_->[0])
                    && lc($_->[0]) eq 'allow')
            } @{$event->{headers} // []};
            push @headers, [
                'allow',
                join(', ', @{$state->{allowed_methods} // []}),
            ];
            $event = {
                %$event,
                headers => \@headers,
            };
            $state->{router_generated} = 0;
        }
        return Future->wrap($send->($event));
    };
}

sub _allow_state {
    my ($class, $scope) = @_;
    return unless ref($scope) eq 'HASH';
    my $state = $scope->{$ALLOW_STATE_KEY};
    return unless ref($state) eq 'HASH';
    return unless ref($state->{token})
        && refaddr($state->{token}) == refaddr($ALLOW_STATE_TOKEN);
    return $state;
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
        my $allow_state = {
            token            => $ALLOW_STATE_TOKEN,
            router_generated => 0,
            allowed_methods  => undef,
        };
        my $authority_scope = {
            %$head_scope,
            $ALLOW_STATE_KEY => $allow_state,
        };
        my $authority_send = $class->_authoritative_allow_send(
            $allow_state,
            $wire_send,
        );
        my $routing_scope = $class->_routing_scope(
            $authority_scope,
            $resolver,
        );

        my $returned = $app->($routing_scope, $receive, $authority_send);
        await Future->wrap($returned);
        return;
    };
}

sub _compile_router_body {
    my ($class, $router, $resolver, $location_prefix, $enter_child) = @_;

    $location_prefix = [] unless $enter_child;

    my $http_default = defined $router->http_default
        ? PAGI::Utils::to_app($router->http_default)
        : PAGI::Utils::to_app(PAGI::Pages->not_found);

    my $dispatcher = $class->_compile_dispatcher(
        $router->routes,
        $resolver,
        $location_prefix,
        $http_default,
    );

    my $app = PAGI::Routing::Middleware->_wrap_descriptors(
        $router->middleware,
        $dispatcher,
    );

    return $app unless $enter_child;
    return async sub {
        my ($scope, $receive, $send) = @_;
        my $child_scope = $class->_enter_child_routing_scope(
            $scope,
            $resolver,
        );
        await Future->wrap($app->($child_scope, $receive, $send));
        return;
    };
}

sub _compile_dispatcher {
    my ($class, $nodes, $resolver, $location_prefix, $http_default) = @_;

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
            inspectable_router => blessed($node->app)
                && $node->app->isa('PAGI::Routing::Router') ? 1 : 0,
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

            await Future->wrap(
                $class->_send_protocol_not_found($scope, $send),
            );
            return;
        }

        my $decision = $class->_select_http(
            \@compiled_entries,
            $scope,
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

        if ($decision->{kind} eq 'partial') {
            my $state = $class->_allow_state($scope);
            croak 'Router authoritative Allow state is missing'
                unless $state;
            $state->{router_generated} = 1;
            $state->{allowed_methods} = [@{$decision->{allowed_methods}}];

            my $response = PAGI::Pages->method_not_allowed(
                $scope, allow => $decision->{allowed_methods},
            );
            await Future->wrap($response->respond($send));
            return;
        }

        await Future->wrap($http_default->($scope, $receive, $send));
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
        await Future->wrap($send->({ type => 'websocket.close' }));
        return;
    }

    my $prefix = "$type.http.response";
    await Future->wrap($send->({
        type    => "$prefix.start",
        status  => 404,
        headers => [['content-type', 'text/plain']],
    }));
    await Future->wrap($send->({
        type => "$prefix.body",
        body => 'Not Found',
        more => 0,
    }));
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

        await Future->wrap($context->respond($result));
        return;
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

            my $child_scope = $class->_mount_scope($scope, $match);
            if ($entry->{inspectable_router}) {
                $class->_record_mount_match(
                    $scope, $entry->{metadata}, $match->{captures},
                );
            }
            else {
                $class->_record_opaque_mount_match(
                    $scope, $entry->{metadata}, $match->{captures},
                );
            }
            return {
                kind  => 'full',
                app   => $entry->{app},
                scope => $child_scope,
            };
        }

        my $route = $entry->{route};
        next unless $route->kind eq 'route';
        my $captures = $route->_pattern->match_route($path);
        my $methods = $route->methods;
        my $method_matches = defined($captures)
            && (!ref($methods) && $methods eq '*'
            ? 1
            : grep { $_ eq $method } @$methods);
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

            my $child_scope = $class->_mount_scope($scope, $match);
            if ($entry->{inspectable_router}) {
                $class->_record_mount_match(
                    $scope, $entry->{metadata}, $match->{captures},
                );
            }
            else {
                $class->_record_opaque_mount_match(
                    $scope, $entry->{metadata}, $match->{captures},
                );
            }
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

sub _enter_child_routing_scope {
    my ($class, $scope, $resolver) = @_;
    my $container = $scope->{'pagi.routing'};
    croak 'inspectable child Router requires compatible routing metadata'
        unless $class->_compatible_routing_container($container);
    my $parent = $class->_current_routing_frame($scope);
    croak 'inspectable child Router requires a parent routing frame'
        unless $parent;

    my $frame = {
        resolver          => $resolver,
        root_path         => $parent->{root_path},
        logical_namespace => $parent->{logical_namespace},
        captures          => { %{$parent->{captures}} },
        mounts            => [map { +{%$_} } @{$parent->{mounts}}],
        match             => undef,
    };
    push @{$container->{frames}}, $frame;
    return $scope;
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

sub _record_opaque_mount_match {
    my ($class, $scope, $metadata, $captures) = @_;
    return unless ref($metadata) eq 'HASH';
    my $frame = $class->_current_routing_frame($scope);
    return unless $frame;

    my %effective_captures = (
        %{ref($frame->{captures}) eq 'HASH' ? $frame->{captures} : {}},
        %{ref($captures) eq 'HASH' ? $captures : {}},
    );
    $frame->{match} = { %{$metadata->{match}} };
    $frame->{logical_namespace}
        = $metadata->{match}{logical_namespace};
    $frame->{captures} = { %effective_captures };
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

Compiles declarative routing descriptions into fresh application graphs. A
Router scans its declarations in order. A full Route or Mount invokes its
compiled application and owns the request. HTTP PARTIAL produces a negotiated
L<PAGI::Pages> 405 with the first-seen method union, while HTTP NONE invokes
the Router's compiled C<http_default> or the stock negotiated Pages 404.
WebSocket and SSE misses retain their protocol-specific denial and close
outcomes and never invoke C<http_default>.

Each public Router invocation installs request-local routing metadata,
authoritative-Allow state, and the final HEAD wire boundary outside Router,
Mount, child Router, and Route middleware. A Router-generated 405 marks that
private state before emission. The outer send adapter removes every
case-insensitive C<Allow> field after routing middleware has run and appends
one normalized authoritative value. Selected endpoint or opaque-application
405 responses are not marked and are therefore not rewritten by this policy.
HEAD suppresses body, sendfile, and trailer events only after inner middleware
has observed the GET-equivalent representation and completed its headers.

An explicit C<< app => $child >> Router Mount is inspectable for reverse
routing but remains a child application boundary at runtime. Once its prefix
matches, the child Router owns its full, partial, none, WebSocket, and SSE
outcomes; the parent neither resumes scanning nor unions its method evidence.
The child contributes its own dispatcher and Router middleware. The containing
Resolver supplies placement-specific effective metadata without mutating the
child description or invoking the child's public C<to_app> boundary.

This ownership is final after a matching Mount prefix. Child Router 404 and
405 responses unwind through child Router, Mount, and parent Router
middleware, but never resume parent declaration scanning. A root Mount
consumes no prefix and leaves C<path> and C<root_path> unchanged.

The executable nesting order is outer Router middleware, Mount middleware,
child Router middleware, nested Mount middleware, route middleware, and
handler. Router defaults and generated 405 responses use the same selected
wrappers without entering Route middleware. Each placement is compiled
independently, including one default-app coercion and fresh middleware graph,
and each public compilation constructs another fresh set of wrappers.

C<compile> is a synchronous build-time boundary: it resolves middleware,
native components, and match entries but starts no request and emits no events.
It returns a native async PAGI coderef. Invocation of that coderef installs a
fresh root C<pagi.routing> frame. Entering an inspectable mounted Router
appends a child boundary frame that retains the root Resolver and root entry
C<root_path> while copying the selected placement's logical namespace,
captures, and cumulative Mount chain. The child description remains immutable.
Opaque mounted applications instead retain terminal Mount metadata in the
current frame and may install their own metadata if they compile another
Router behind that boundary.

Compatible version-1 routing metadata contributes ancestor frames. Malformed
or newer metadata is preserved on the incoming scope as an
incompatible boundary: the new shallow child scope receives a fresh version-1
container and ignores foreign ancestry rather than croaking or mutating it.
Each root frame begins with canonical C<logical_namespace> C</>, fresh
C<captures> and C<mounts> containers, and no leaf match. A selected leaf
publishes its effective pattern, canonical name, kind, description, namespace,
and complete capture snapshot. PARTIAL and NONE publish no leaf. Capture,
Mount, frame, container, and authoritative-Allow state are request-local; only
the immutable compiled Resolver is shared between concurrent requests. Every
application and response completion seam accepts either an immediate value or
a Future through C<Future-E<gt>wrap>.

This is an internal compiler. Public composition and migration contracts are
documented by L<PAGI::Routing>, L<PAGI::Routing::Router>,
L<PAGI::Routing::Mount>, L<PAGI::Compose>, and the
L<routing composition upgrade guide|https://github.com/jjn1056/PAGI-Tools/blob/main/UPGRADING.md#routing-composition-redesign>.

=cut
