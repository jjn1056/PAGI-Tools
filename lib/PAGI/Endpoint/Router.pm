package PAGI::Endpoint::Router;

use strict;
use warnings;

use Future::AsyncAwait;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use Module::Load qw(load);

our $VERSION = '0.01';

sub new {
    my ($class, %args) = @_;
    return bless {
        _stash => {},
    }, $class;
}

sub stash {
    my ($self) = @_;
    return $self->{_stash};
}

# Override in subclass to define routes
sub routes {
    my ($self, $r) = @_;
    # Default: no routes
}

# Override in subclass for startup logic
async sub on_startup {
    my ($self) = @_;
    # Default: no-op
}

# Override in subclass for shutdown logic
async sub on_shutdown {
    my ($self) = @_;
    # Default: no-op
}

sub to_app {
    my ($class) = @_;

    # Create instance that lives for app lifetime
    my $instance = blessed($class) ? $class : $class->new;

    # Build internal router
    load('PAGI::App::Router');
    my $internal_router = PAGI::App::Router->new;

    # Let subclass define routes
    $instance->_build_routes($internal_router);

    my $app = $internal_router->to_app;

    return async sub {
        my ($scope, $receive, $send) = @_;

        my $type = $scope->{type} // '';

        # Handle lifespan events
        if ($type eq 'lifespan') {
            await $instance->_handle_lifespan($scope, $receive, $send);
            return;
        }

        # Merge stash into scope for handlers
        $scope->{'pagi.stash'} = {
            %{$scope->{'pagi.stash'} // {}},
            %{$instance->stash},
        };

        # Dispatch to internal router
        await $app->($scope, $receive, $send);
    };
}

async sub _handle_lifespan {
    my ($self, $scope, $receive, $send) = @_;

    while (1) {
        my $msg = await $receive->();
        my $type = $msg->{type} // '';

        if ($type eq 'lifespan.startup') {
            eval { await $self->on_startup };
            if ($@) {
                await $send->({
                    type    => 'lifespan.startup.failed',
                    message => "$@",
                });
                return;
            }
            await $send->({ type => 'lifespan.startup.complete' });
        }
        elsif ($type eq 'lifespan.shutdown') {
            eval { await $self->on_shutdown };
            await $send->({ type => 'lifespan.shutdown.complete' });
            return;
        }
    }
}

sub _build_routes {
    my ($self, $r) = @_;

    # Create a wrapper router that intercepts route registration
    my $wrapper = PAGI::Endpoint::Router::RouteBuilder->new($self, $r);
    $self->routes($wrapper);
}

# Internal route builder that wraps handlers
package PAGI::Endpoint::Router::RouteBuilder;

use strict;
use warnings;
use Future::AsyncAwait;
use Scalar::Util qw(blessed);

sub new {
    my ($class, $endpoint, $router) = @_;
    return bless {
        endpoint => $endpoint,
        router   => $router,
    }, $class;
}

# HTTP methods
sub get     { shift->_add_http_route('GET', @_) }
sub post    { shift->_add_http_route('POST', @_) }
sub put     { shift->_add_http_route('PUT', @_) }
sub patch   { shift->_add_http_route('PATCH', @_) }
sub delete  { shift->_add_http_route('DELETE', @_) }
sub head    { shift->_add_http_route('HEAD', @_) }
sub options { shift->_add_http_route('OPTIONS', @_) }

sub _add_http_route {
    my ($self, $method, $path, @rest) = @_;

    my ($middleware, $handler) = $self->_parse_route_args(@rest);

    # Wrap middleware
    my @wrapped_mw = map { $self->_wrap_middleware($_) } @$middleware;

    # Wrap handler
    my $wrapped = $self->_wrap_http_handler($handler);

    # Register with internal router using the appropriate HTTP method
    my $router_method = lc($method);
    $self->{router}->$router_method($path, @wrapped_mw ? (\@wrapped_mw, $wrapped) : $wrapped);

    return $self;
}

sub _parse_route_args {
    my ($self, @args) = @_;

    if (@args == 2 && ref($args[0]) eq 'ARRAY') {
        return ($args[0], $args[1]);
    }
    elsif (@args == 1) {
        return ([], $args[0]);
    }
    else {
        die "Invalid route arguments";
    }
}

sub _wrap_http_handler {
    my ($self, $handler) = @_;

    my $endpoint = $self->{endpoint};

    # If handler is a string, it's a method name
    if (!ref($handler)) {
        my $method_name = $handler;
        my $method = $endpoint->can($method_name)
            or die "No such method: $method_name in " . ref($endpoint);

        return async sub {
            my ($scope, $receive, $send) = @_;

            require PAGI::Request;
            require PAGI::Response;

            my $req = PAGI::Request->new($scope, $receive);
            my $res = PAGI::Response->new($send, $scope);

            # Inject stash
            $req->set_stash($scope->{'pagi.stash'} // {});

            await $endpoint->$method($req, $res);
        };
    }

    # Already a coderef - wrap it
    return async sub {
        my ($scope, $receive, $send) = @_;

        require PAGI::Request;
        require PAGI::Response;

        my $req = PAGI::Request->new($scope, $receive);
        my $res = PAGI::Response->new($send, $scope);

        $req->set_stash($scope->{'pagi.stash'} // {});

        await $handler->($req, $res);
    };
}

sub websocket {
    my ($self, $path, @rest) = @_;

    my ($middleware, $handler) = $self->_parse_route_args(@rest);
    my @wrapped_mw = map { $self->_wrap_middleware($_) } @$middleware;
    my $wrapped = $self->_wrap_websocket_handler($handler);

    $self->{router}->websocket($path, @wrapped_mw ? (\@wrapped_mw, $wrapped) : $wrapped);

    return $self;
}

sub _wrap_websocket_handler {
    my ($self, $handler) = @_;

    my $endpoint = $self->{endpoint};

    if (!ref($handler)) {
        my $method_name = $handler;
        my $method = $endpoint->can($method_name)
            or die "No such method: $method_name";

        return async sub {
            my ($scope, $receive, $send) = @_;

            require PAGI::WebSocket;

            my $ws = PAGI::WebSocket->new($scope, $receive, $send);

            # Inject router stash into WS stash
            my $router_stash = $scope->{'pagi.stash'} // {};
            for my $key (keys %$router_stash) {
                $ws->stash->{$key} = $router_stash->{$key};
            }

            await $endpoint->$method($ws);
        };
    }

    return async sub {
        my ($scope, $receive, $send) = @_;

        require PAGI::WebSocket;

        my $ws = PAGI::WebSocket->new($scope, $receive, $send);

        my $router_stash = $scope->{'pagi.stash'} // {};
        for my $key (keys %$router_stash) {
            $ws->stash->{$key} = $router_stash->{$key};
        }

        await $handler->($ws);
    };
}

sub sse {
    my ($self, $path, @rest) = @_;

    my ($middleware, $handler) = $self->_parse_route_args(@rest);
    my @wrapped_mw = map { $self->_wrap_middleware($_) } @$middleware;
    my $wrapped = $self->_wrap_sse_handler($handler);

    $self->{router}->sse($path, @wrapped_mw ? (\@wrapped_mw, $wrapped) : $wrapped);

    return $self;
}

sub _wrap_sse_handler {
    my ($self, $handler) = @_;

    my $endpoint = $self->{endpoint};

    if (!ref($handler)) {
        my $method_name = $handler;
        my $method = $endpoint->can($method_name)
            or die "No such method: $method_name";

        return async sub {
            my ($scope, $receive, $send) = @_;

            require PAGI::SSE;

            my $sse = PAGI::SSE->new($scope, $receive, $send);

            # Inject router stash
            my $router_stash = $scope->{'pagi.stash'} // {};
            for my $key (keys %$router_stash) {
                $sse->stash->{$key} = $router_stash->{$key};
            }

            await $endpoint->$method($sse);
        };
    }

    return async sub {
        my ($scope, $receive, $send) = @_;

        require PAGI::SSE;

        my $sse = PAGI::SSE->new($scope, $receive, $send);

        my $router_stash = $scope->{'pagi.stash'} // {};
        for my $key (keys %$router_stash) {
            $sse->stash->{$key} = $router_stash->{$key};
        }

        await $handler->($sse);
    };
}

sub _wrap_middleware {
    my ($self, $mw) = @_;

    my $endpoint = $self->{endpoint};

    # String = method name
    if (!ref($mw)) {
        my $method = $endpoint->can($mw)
            or die "No such middleware method: $mw";

        return async sub {
            my ($scope, $receive, $send, $next) = @_;

            require PAGI::Request;
            require PAGI::Response;

            my $req = PAGI::Request->new($scope, $receive);
            my $res = PAGI::Response->new($send, $scope);

            $req->set_stash($scope->{'pagi.stash'} // {});

            await $endpoint->$method($req, $res, $next);
        };
    }

    # Already a coderef or object - pass through
    return $mw;
}

# Pass through mount to internal router
sub mount {
    my ($self, @args) = @_;
    $self->{router}->mount(@args);
    return $self;
}

1;

__END__

=head1 NAME

PAGI::Endpoint::Router - Class-based router with lifespan and wrapped handlers

=head1 SYNOPSIS

    package MyApp::API;
    use parent 'PAGI::Endpoint::Router';
    use Future::AsyncAwait;

    # Lifespan hooks
    async sub on_startup {
        my ($self) = @_;
        $self->stash->{db} = DBI->connect(...);
    }

    async sub on_shutdown {
        my ($self) = @_;
        $self->stash->{db}->disconnect;
    }

    # Route definitions
    sub routes {
        my ($self, $r) = @_;

        # HTTP routes - handler receives ($self, $req, $res)
        $r->get('/users' => 'list_users');
        $r->get('/users/:id' => 'get_user');
        $r->post('/users' => 'create_user');

        # With middleware
        $r->delete('/users/:id' => ['require_admin'] => 'delete_user');

        # WebSocket - handler receives ($self, $ws)
        $r->websocket('/ws/chat/:room' => 'chat_handler');

        # SSE - handler receives ($self, $sse)
        $r->sse('/events/:channel' => 'events_handler');

        # Mount sub-routers
        $r->mount('/admin' => MyApp::Admin->to_app);
    }

    # HTTP handlers receive wrapped objects
    async sub list_users {
        my ($self, $req, $res) = @_;
        my $db = $req->stash->{db};
        my $users = $db->selectall_arrayref(...);
        await $res->json($users);
    }

    async sub get_user {
        my ($self, $req, $res) = @_;
        my $id = $req->param('id');  # Route parameter
        await $res->json({ id => $id });
    }

    # Middleware as methods
    async sub require_admin {
        my ($self, $req, $res, $next) = @_;
        if ($req->get('user')->{role} eq 'admin') {
            await $next->();
        } else {
            await $res->status(403)->json({ error => 'Forbidden' });
        }
    }

    # WebSocket handlers receive PAGI::WebSocket
    async sub chat_handler {
        my ($self, $ws) = @_;
        my $room = $ws->param('room');

        await $ws->accept;
        $ws->start_heartbeat(25);  # Keepalive

        await $ws->each_json(async sub {
            my ($data) = @_;
            await $ws->send_json({ echo => $data });
        });
    }

    # SSE handlers receive PAGI::SSE
    async sub events_handler {
        my ($self, $sse) = @_;
        await $sse->every(1, async sub {
            await $sse->send_event('tick', { ts => time });
        });
    }

    # Create app
    my $app = MyApp::API->to_app;

=head1 DESCRIPTION

PAGI::Endpoint::Router provides a Rails/Django-style class-based approach
to building PAGI applications. It combines:

=over 4

=item * B<Lifespan management> - C<on_startup>/C<on_shutdown> hooks for
database connections, initialization, cleanup

=item * B<Method-based handlers> - Define handlers as class methods instead
of anonymous subs

=item * B<Wrapped objects> - Handlers receive C<PAGI::Request>/C<PAGI::Response>
for HTTP, C<PAGI::WebSocket> for WebSocket, C<PAGI::SSE> for SSE

=item * B<Middleware as methods> - Define middleware as class methods with
C<$next> parameter

=item * B<Shared stash> - C<$self-E<gt>stash> from startup available to all
handlers via C<$req-E<gt>stash>, C<$ws-E<gt>stash>, etc.

=back

=head1 HANDLER SIGNATURES

Handlers receive different wrapped objects based on route type:

    # HTTP routes: get, post, put, patch, delete, head, options
    async sub handler ($self, $req, $res) { }
    # $req = PAGI::Request, $res = PAGI::Response

    # WebSocket routes
    async sub handler ($self, $ws) { }
    # $ws = PAGI::WebSocket

    # SSE routes
    async sub handler ($self, $sse) { }
    # $sse = PAGI::SSE

    # Middleware
    async sub middleware ($self, $req, $res, $next) { }

=head1 METHODS

=head2 to_app

    my $app = MyRouter->to_app;

Returns a PAGI application coderef. Creates a single instance that
persists for the application lifetime (for stash sharing).

=head2 stash

    $self->stash->{db} = $connection;

Returns the router's stash hashref. Values set here in C<on_startup>
are available to all handlers via C<$req-E<gt>stash>, C<$ws-E<gt>stash>, etc.

=head2 on_startup

    async sub on_startup {
        my ($self) = @_;
        # Initialize resources
    }

Called once when the application starts (on first lifespan.startup event).
Override to initialize database connections, caches, etc.

=head2 on_shutdown

    async sub on_shutdown {
        my ($self) = @_;
        # Cleanup resources
    }

Called once when the application shuts down. Override to close
connections and cleanup resources.

=head2 routes

    sub routes {
        my ($self, $r) = @_;
        $r->get('/path' => 'handler_method');
    }

Override to define routes. The C<$r> parameter is a route builder with
methods for HTTP, WebSocket, and SSE routes.

=head1 ROUTE BUILDER METHODS

The C<$r> object passed to C<routes()> supports:

=head2 HTTP Methods

    $r->get($path => 'handler');
    $r->get($path => ['middleware'] => 'handler');

    $r->post($path => ...);
    $r->put($path => ...);
    $r->patch($path => ...);
    $r->delete($path => ...);
    $r->head($path => ...);
    $r->options($path => ...);

=head2 WebSocket

    $r->websocket($path => 'handler');

=head2 SSE

    $r->sse($path => 'handler');

=head2 Mount

    $r->mount($prefix => $app);

Mount another PAGI app at a prefix.

=head1 SEE ALSO

L<PAGI::App::Router>, L<PAGI::Request>, L<PAGI::Response>,
L<PAGI::WebSocket>, L<PAGI::SSE>, L<PAGI::Endpoint::HTTP>,
L<PAGI::Endpoint::WebSocket>, L<PAGI::Endpoint::SSE>

=cut
