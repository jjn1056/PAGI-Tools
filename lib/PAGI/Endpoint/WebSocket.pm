package PAGI::Endpoint::WebSocket;

use strict;
use warnings;

use Future::AsyncAwait;
use Carp qw(croak);
use Module::Load qw(load);

our $VERSION = '0.01';

# Factory class method - override in subclass for customization
sub websocket_class { 'PAGI::WebSocket' }

# Encoding: 'text', 'bytes', or 'json'
sub encoding { 'text' }

sub to_app {
    my ($class) = @_;
    my $ws_class = $class->websocket_class;
    load($ws_class);

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $endpoint = $class->new;
        my $ws = $ws_class->new($scope, $receive, $send);

        await $endpoint->handle($ws);
    };
}

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

async sub handle {
    my ($self, $ws) = @_;

    # Call on_connect if defined
    if ($self->can('on_connect')) {
        await $self->on_connect($ws);
    } else {
        # Default: accept the connection
        await $ws->accept;
    }

    # Register disconnect callback
    if ($self->can('on_disconnect')) {
        $ws->on_close(sub {
            my ($code, $reason) = @_;
            $self->on_disconnect($ws, $code, $reason);
        });
    }

    # Handle messages based on encoding
    if ($self->can('on_receive')) {
        my $encoding = $self->encoding;

        if ($encoding eq 'json') {
            await $ws->each_json(async sub {
                my ($data) = @_;
                await $self->on_receive($ws, $data);
            });
        } elsif ($encoding eq 'bytes') {
            await $ws->each_bytes(async sub {
                my ($data) = @_;
                await $self->on_receive($ws, $data);
            });
        } else {
            # Default: text
            await $ws->each_text(async sub {
                my ($data) = @_;
                await $self->on_receive($ws, $data);
            });
        }
    } else {
        # No on_receive, just wait for disconnect
        await $ws->run;
    }
}

1;

__END__

=head1 NAME

PAGI::Endpoint::WebSocket - Class-based WebSocket endpoint handler

=head1 SYNOPSIS

    package MyApp::Chat;
    use parent 'PAGI::Endpoint::WebSocket';
    use Future::AsyncAwait;

    sub encoding { 'json' }  # or 'text', 'bytes'

    async sub on_connect {
        my ($self, $ws) = @_;
        await $ws->accept;
        await $ws->send_json({ type => 'welcome' });
    }

    async sub on_receive {
        my ($self, $ws, $data) = @_;
        # $data is already decoded based on encoding()
        await $ws->send_json({ type => 'echo', message => $data });
    }

    sub on_disconnect {
        my ($self, $ws, $code) = @_;
        cleanup_user($ws->stash->{user_id});
    }

    # Use with PAGI server
    my $app = MyApp::Chat->to_app;

=head1 DESCRIPTION

PAGI::Endpoint::WebSocket provides a Starlette-inspired class-based
approach to handling WebSocket connections with lifecycle hooks.

=head1 LIFECYCLE METHODS

=head2 on_connect

    async sub on_connect {
        my ($self, $ws) = @_;
        await $ws->accept;
    }

Called when a client connects. You should call C<< $ws->accept >>
to accept the connection. If not defined, connection is auto-accepted.

=head2 on_receive

    async sub on_receive {
        my ($self, $ws, $data) = @_;
        await $ws->send_text("Got: $data");
    }

Called for each message received. The C<$data> format depends on
the C<encoding()> setting.

=head2 on_disconnect

    sub on_disconnect {
        my ($self, $ws, $code, $reason) = @_;
        # Cleanup
    }

Called when connection closes. This is synchronous (not async).

=head1 CLASS METHODS

=head2 encoding

    sub encoding { 'json' }  # 'text', 'bytes', or 'json'

Controls how incoming messages are decoded:

=over 4

=item C<text> - Messages passed as strings (default)

=item C<bytes> - Messages passed as raw bytes

=item C<json> - Messages decoded from JSON

=back

=head2 websocket_class

    sub websocket_class { 'PAGI::WebSocket' }

Override to use a custom WebSocket wrapper.

=head2 to_app

    my $app = MyEndpoint->to_app;

Returns a PAGI-compatible async coderef.

=head1 SEE ALSO

L<PAGI::WebSocket>, L<PAGI::Endpoint::HTTP>, L<PAGI::Endpoint::SSE>

=cut
