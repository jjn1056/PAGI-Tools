package PAGI::Endpoint::WebSocket;

use strict;
use warnings;

use Future;
use Future::AsyncAwait;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use PAGI::WebSocket;
use PAGI::Utils::_ProtocolHelpers ();

# Encoding: 'text', 'bytes', or 'json'
sub encoding { 'text' }

sub to_app {
    my ($endpoint) = @_;
    croak "to_app is called on an endpoint object; use endpoint('$endpoint') or $endpoint->new->to_app"
        unless blessed($endpoint);

    return async sub {
        my ($scope, $receive, $send) = @_;

        my $type = $scope->{type} // '';
        croak "Expected websocket scope, got '$type'" unless $type eq 'websocket';

        my $websocket = PAGI::WebSocket->new($scope, $receive, $send);

        await Future->wrap($endpoint->handle($websocket));
        await $websocket->close if $websocket->is_connected;
        # The call ends with the scope and the helper's own cleanup.
        await $websocket->finished;
        return;
    };
}

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

async sub handle {
    my ($self, $websocket) = @_;

    # Register disconnect callback
    if ($self->can('on_disconnect')) {
        $websocket->on_close(sub {
            my ($code, $reason, $detail) = @_;
            return $self->on_disconnect($websocket, $code, $reason, $detail);
        });
    }

    # Call on_connect if defined
    if ($self->can('on_connect')) {
        await Future->wrap($self->on_connect($websocket));
    } else {
        # Default: accept the connection
        await $websocket->accept;
    }

    # A refusal (deny) is on_connect's answer: there are no messages to read,
    # even if the server has not yet reported the connection ended.
    return if $websocket->is_closed
        || PAGI::Utils::_ProtocolHelpers::refused($websocket);

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
    use PAGI::Routing qw(endpoint websocket);

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

    # Name the class; endpoint() loads and builds it.
    websocket('/chat' => endpoint('MyApp::Chat', hub => $hub));

=head1 DESCRIPTION

PAGI::Endpoint::WebSocket provides a Starlette-inspired class-based
approach to handling WebSocket connections with lifecycle hooks.

Named at a route with C<endpoint>, the class is built with C<new> for each
connection by default, and that object lives as long as the connection, so
connection state may live on C<$self>.

A class that shares one object across every connection says so with
C<BUILD_APP> (L<PAGI::Endpoint>). Configuration and long-lived dependencies
may then live on the object, but each C<PAGI::WebSocket> protocol object and all
connection-local state must stay local to C<handle>, because one endpoint
instance serves concurrent connections.

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

Called at terminal connection notification. The hook may return a Future;
cleanup awaits it and retains the endpoint until it settles. Arguments are
C<($self, $websocket, $peer_code, $peer_reason, $disconnect_detail)>.

=head1 METHODS

=head2 encoding

    sub encoding { 'json' }  # 'text', 'bytes', or 'json'

Controls how B<incoming> messages are decoded before being passed to
C<on_receive>. This does B<not> affect outgoing messages - you always
explicitly choose the send method (C<send_json>, C<send_text>, C<send_bytes>).

=over 4

=item C<text> - Messages passed as strings (default)

=item C<bytes> - Messages passed as raw bytes

=item C<json> - Messages automatically decoded from JSON to Perl data structures.
A message that is not JSON closes the socket with 1007, as
L<PAGI::WebSocket/"each_json and invalid JSON"> describes.

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

    my $app = endpoint('MyEndpoint', hub => $hub)->to_app;  # built as the class decides
    my $app = MyEndpoint->new(hub => $hub)->to_app;         # this one object

Returns a PAGI-compatible async coderef. C<to_app> is an instance
method: called on an endpoint object, it retains that exact object for
every connection. Calling it on a class name dies with "to_app is
called on an endpoint object; use endpoint('MyEndpoint') or
MyEndpoint->new->to_app". C<endpoint> builds the class as it decides,
once or per connection (L<PAGI::Endpoint>).

=head1 SEE ALSO

L<PAGI::WebSocket>, L<PAGI::Endpoint::HTTP>, L<PAGI::Endpoint::SSE>

=cut
