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
    # Placeholder - will be implemented in next tasks
    $self->routes($r);
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
