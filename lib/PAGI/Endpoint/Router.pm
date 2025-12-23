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

PAGI::Endpoint::Router - Class-based router with lifespan support

=head1 SYNOPSIS

    package MyApp::API;
    use parent 'PAGI::Endpoint::Router';
    use Future::AsyncAwait;

    async sub on_startup {
        my ($self) = @_;
        $self->stash->{db} = DBI->connect(...);
    }

    async sub on_shutdown {
        my ($self) = @_;
        $self->stash->{db}->disconnect;
    }

    sub routes {
        my ($self, $r) = @_;
        $r->get('/users' => 'list_users');
        $r->get('/users/:id' => 'get_user');
    }

    async sub list_users {
        my ($self, $req, $res) = @_;
        await $res->json({ users => [] });
    }

    # Use it
    my $app = MyApp::API->to_app;

=head1 DESCRIPTION

PAGI::Endpoint::Router provides a class-based approach to routing with
integrated lifespan management. It combines the power of PAGI::App::Router
with lifecycle hooks and method-based handlers.

=head1 METHODS

=head2 new

    my $router = PAGI::Endpoint::Router->new;

Creates a new router instance.

=head2 stash

    $self->stash->{db} = $connection;

Returns the router's stash hashref. Values set here in C<on_startup>
are available to all handlers via C<$req->stash>, C<$ws->stash>, etc.

=head2 to_app

    my $app = MyRouter->to_app;

Returns a PAGI application coderef.

=head2 on_startup

    async sub on_startup {
        my ($self) = @_;
        # Initialize resources
    }

Called once when the application starts. Override to initialize
database connections, caches, etc.

=head2 on_shutdown

    async sub on_shutdown {
        my ($self) = @_;
        # Cleanup resources
    }

Called once when the application shuts down.

=head2 routes

    sub routes {
        my ($self, $r) = @_;
        $r->get('/path' => 'handler_method');
    }

Override to define routes.

=cut
