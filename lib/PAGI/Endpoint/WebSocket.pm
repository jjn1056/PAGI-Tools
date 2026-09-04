package PAGI::Endpoint::WebSocket;

use strict;
use warnings;

use Future;
use Future::AsyncAwait;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use PAGI::Utils::Scope ();
use PAGI::WebSocket;

# Encoding: 'text', 'bytes', or 'json'
sub encoding { 'text' }

sub to_app {
    my ($invocant) = @_;
    my $endpoint = blessed($invocant) ? $invocant : $invocant->new;

    return async sub {
        my ($scope, $receive, $send) = @_;

        my $type = $scope->{type} // '';
        croak "Expected websocket scope, got '$type'" unless $type eq 'websocket';

        PAGI::Utils::Scope::_compatible_cached_scope_object(
            $scope, 'pagi.websocket', 'PAGI::WebSocket',
        );
        my $websocket = PAGI::WebSocket->new($scope, $receive, $send);

        await Future->wrap($endpoint->handle($websocket));
        return;
    };
}

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

async sub handle {
    my ($self, $websocket) = @_;

    # Call on_connect if defined
    if ($self->can('on_connect')) {
        await Future->wrap($self->on_connect($websocket));
    } else {
        # Default: accept the connection
        await $websocket->accept;
    }

    # Register disconnect callback
    if ($self->can('on_disconnect')) {
        $websocket->on_close(sub {
            my ($code, $reason) = @_;
            $self->on_disconnect($websocket, $code, $reason);
            return;
        });
    }

    # Handle messages based on encoding
    eval {
        if ($self->can('on_receive')) {
            my $encoding = $self->encoding;

            if ($encoding eq 'json') {
                await $websocket->each_json(async sub {
                    my ($data) = @_;
                    await Future->wrap($self->on_receive($websocket, $data));
                });
            } elsif ($encoding eq 'bytes') {
                await $websocket->each_bytes(async sub {
                    my ($data) = @_;
                    await Future->wrap($self->on_receive($websocket, $data));
                });
            } else {
                # Default: text
                await $websocket->each_text(async sub {
                    my ($data) = @_;
                    await Future->wrap($self->on_receive($websocket, $data));
                });
            }
        } else {
            # No on_receive, just wait for disconnect
            await $websocket->run;
        }
    };
    die $@ if $@;
}

1;

__END__

=head1 NAME

PAGI::Endpoint::WebSocket - Class-based WebSocket endpoint handler

=head1 SYNOPSIS

    package MyApp::Chat;
    use parent 'PAGI::Endpoint::WebSocket';
    use Future::AsyncAwait;
    use PAGI::Routing qw(websocket);

    sub encoding { 'json' }  # or 'text', 'bytes'

    async sub on_connect {
        my ($self, $websocket) = @_;
        await $websocket->accept;
        await $websocket->send_json({ type => 'welcome' });
    }

    async sub on_receive {
        my ($self, $websocket, $data) = @_;
        await $websocket->send_json({ type => 'echo', message => $data });
    }

    sub on_disconnect {
        my ($self, $websocket, $code) = @_;
        cleanup_user($websocket->scope->{user_id});
    }

    # Place one configured object at one exact protocol Route.
    websocket('/chat' => MyApp::Chat->new(hub => $hub));

=head1 DESCRIPTION

PAGI::Endpoint::WebSocket provides a Starlette-inspired class-based
approach to handling WebSocket connections with lifecycle hooks.

C<to_app> constructs a class receiver once immediately, or retains an
instance receiver exactly as supplied. Configuration and long-lived
dependencies may therefore live on the endpoint object. Each
C<PAGI::WebSocket> protocol object and all connection-local state must stay
local to C<handle>, because one endpoint instance can serve concurrent
connections.

=head1 LIFECYCLE METHODS

=head2 on_connect

    async sub on_connect {
        my ($self, $websocket) = @_;
        await $websocket->accept;
    }

Called when a client connects. You should call C<< $websocket->accept >>
to accept the connection. If not defined, connection is auto-accepted.

=head2 on_receive

    async sub on_receive {
        my ($self, $websocket, $data) = @_;
        await $websocket->send_text("Got: $data");
    }

Called for each message received. The C<$data> format depends on
the C<encoding()> setting.

=head2 on_disconnect

    sub on_disconnect {
        my ($self, $websocket, $code, $reason) = @_;
        # Cleanup
    }

Called when connection closes. This is synchronous (not async).

=head1 CLASS METHODS

=head2 encoding

    sub encoding { 'json' }  # 'text', 'bytes', or 'json'

Controls how B<incoming> messages are decoded before being passed to
C<on_receive>. This does B<not> affect outgoing messages - you always
explicitly choose the send method (C<send_json>, C<send_text>, C<send_bytes>).

=over 4

=item C<text> - Messages passed as strings (default)

=item C<bytes> - Messages passed as raw bytes

=item C<json> - Messages automatically decoded from JSON to Perl data structures

=back

B<Example - JSON encoding:>

    package MyEndpoint;
    use parent 'PAGI::Endpoint::WebSocket';

    sub encoding { 'json' }  # Incoming messages auto-decoded from JSON

    async sub on_receive {
        my ($self, $websocket, $data) = @_;
        # $data is already a Perl hashref/arrayref (decoded from JSON)
        my $name = $data->{name};

        # For sending, you still explicitly choose the method:
        await $websocket->send_json({ greeting => "Hello, $name" });
        await $websocket->send_text("Raw text message");
    }

B<Example - Text encoding:>

    sub encoding { 'text' }  # Incoming messages as raw strings

    async sub on_receive {
        my ($self, $websocket, $text) = @_;
        # $text is a plain string, decode JSON yourself if needed
        my $data = JSON::MaybeXS::decode_json($text);
        await $websocket->send_text("Echo: $text");
    }

This follows the same pattern as L<Starlette's WebSocketEndpoint|https://www.starlette.io/endpoints/>.

=head2 to_app

    my $app = MyEndpoint->to_app;

    my $endpoint = MyEndpoint->new(hub => $hub);
    my $app = $endpoint->to_app;

Returns a PAGI-compatible async coderef. Calling it on a class constructs one
endpoint immediately; calling it on an instance retains that exact instance
for every connection.

=head1 SEE ALSO

L<PAGI::WebSocket>, L<PAGI::Endpoint::HTTP>, L<PAGI::Endpoint::SSE>

=cut
