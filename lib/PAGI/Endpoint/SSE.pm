package PAGI::Endpoint::SSE;

use strict;
use warnings;

use Future::AsyncAwait;
use Carp qw(croak);
use Module::Load qw(load);

our $VERSION = '0.01';

# Factory class method - override in subclass for customization
sub sse_class { 'PAGI::SSE' }

# Keepalive interval in seconds (0 = disabled)
sub keepalive_interval { 0 }

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

async sub handle {
    my ($self, $sse) = @_;

    # Configure keepalive if specified
    my $keepalive = $self->keepalive_interval;
    if ($keepalive > 0) {
        $sse->keepalive($keepalive);
    }

    # Register disconnect callback
    if ($self->can('on_disconnect')) {
        $sse->on_close(sub {
            $self->on_disconnect($sse);
        });
    }

    # Call on_connect if defined
    if ($self->can('on_connect')) {
        await $self->on_connect($sse);
    } else {
        # Default: just start the stream
        await $sse->start;
    }

    # Wait for disconnect
    await $sse->run;
}

sub to_app {
    my ($class) = @_;
    my $sse_class = $class->sse_class;
    load($sse_class);

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $endpoint = $class->new;
        my $sse = $sse_class->new($scope, $receive, $send);

        await $endpoint->handle($sse);
    };
}

1;

__END__

=head1 NAME

PAGI::Endpoint::SSE - Class-based Server-Sent Events endpoint handler

=head1 SYNOPSIS

    package MyApp::Notifications;
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;

    sub keepalive_interval { 30 }

    async sub on_connect {
        my ($self, $sse) = @_;
        my $user_id = $sse->stash->{user_id};

        # Send welcome event
        await $sse->send_event(
            event => 'connected',
            data  => { user_id => $user_id },
        );

        # Handle reconnection
        if (my $last_id = $sse->last_event_id) {
            await send_missed_events($sse, $last_id);
        }

        # Subscribe to notifications
        subscribe($user_id, sub {
            my ($event) = @_;
            $sse->try_send_json($event);
        });
    }

    sub on_disconnect {
        my ($self, $sse) = @_;
        unsubscribe($sse->stash->{user_id});
    }

    # Use with PAGI server
    my $app = MyApp::Notifications->to_app;

=head1 DESCRIPTION

PAGI::Endpoint::SSE provides a class-based approach to handling
Server-Sent Events connections with lifecycle hooks.

=head1 LIFECYCLE METHODS

=head2 on_connect

    async sub on_connect {
        my ($self, $sse) = @_;
        await $sse->send_event(data => 'Hello!');
    }

Called when a client connects. The SSE stream is automatically
started before this is called. Use this to send initial events
and set up subscriptions.

=head2 on_disconnect

    sub on_disconnect {
        my ($self, $sse) = @_;
        # Cleanup subscriptions
    }

Called when connection closes. This is synchronous (not async).

=head1 CLASS METHODS

=head2 keepalive_interval

    sub keepalive_interval { 30 }

Seconds between keepalive pings. Set to 0 to disable (default).
Keepalives prevent proxy timeouts on idle connections.

=head2 sse_class

    sub sse_class { 'PAGI::SSE' }

Override to use a custom SSE wrapper.

=head2 to_app

    my $app = MyEndpoint->to_app;

Returns a PAGI-compatible async coderef.

=head1 SEE ALSO

L<PAGI::SSE>, L<PAGI::Endpoint::HTTP>, L<PAGI::Endpoint::WebSocket>

=cut
