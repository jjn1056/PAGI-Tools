package PAGI::Test::WebSocket;

use strict;
use warnings;
use Future::AsyncAwait;
use Future;
use Carp qw(croak);

use PAGI::SendValidation;


sub new {
    my ($class, %args) = @_;

    croak "app is required" unless $args{app};
    croak "scope is required" unless $args{scope};

    return bless {
        app         => $args{app},
        scope       => $args{scope},
        send_queue  => [],      # Messages from test -> app
        recv_queue  => [],      # Messages from app -> test
        closed      => 0,
        accepted    => 0,
        close_code  => undef,
        close_reason => '',
        _pending_receives => [],  # Pending receive futures
        _disconnect_delivered => 0,
    }, $class;
}

sub _start {
    my ($self) = @_;

    # websocket.http.response is always available on this path, mirroring
    # the reference server: the extension denial is a portable escape hatch
    # from an in-process test double, not something a test opts into.
    my $sv = PAGI::SendValidation->new(
        scope_type => 'websocket',
        extensions => { 'websocket.http.response' => {} },
    );

    # Create receive coderef for the app
    my $receive = async sub {
        # First call returns websocket.connect
        if (!$self->{_connect_sent}) {
            $self->{_connect_sent} = 1;
            return { type => 'websocket.connect' };
        }

        # Return queued message if available
        if (@{$self->{send_queue}}) {
            return shift @{$self->{send_queue}};
        }

        # Deliver the synthesized disconnect exactly once (truthful code and
        # reason). Any receive after that stays pending forever -- matching
        # a real transport that has gone silent; a hang is the correct
        # diagnosis for an app that keeps calling receive() past disconnect.
        if ($self->{closed} && !$self->{_disconnect_delivered}) {
            $self->{_disconnect_delivered} = 1;
            return {
                type   => 'websocket.disconnect',
                code   => $self->{close_code} // 1000,
                reason => $self->{close_reason} // 'client_closed',
            };
        }

        # Create a future that will be resolved when data arrives
        my $future = Future->new;
        push @{$self->{_pending_receives}}, $future;
        return await $future;
    };

    # Create send coderef for the app. Strict: illegal events (per
    # PAGI::SendValidation's websocket rules) fail the returned Future --
    # a canonical test double must not accept what a real server would
    # reject -- and are never appended to the client's readable stream.
    my $send = async sub {
        my ($event) = @_;

        if (my $err = $sv->check($event)) {
            die $err->message . "\n";
        }

        my $type = $event->{type} // '';

        if ($type eq 'websocket.accept') {
            $self->{accepted} = 1;
        }
        elsif ($type eq 'websocket.send') {
            # If the peer (the test side) already closed -- not the app's
            # own websocket.close, which sv already rejected above -- a real
            # server just drops writes to a dead socket: tolerated no-op,
            # nothing reaches the client's readable stream.
            push @{$self->{recv_queue}}, $event unless $self->{closed};
        }
        elsif ($type eq 'websocket.close') {
            $self->{closed} = 1;
            $self->{close_code} = $event->{code} // 1000;
            $self->{close_reason} = $event->{reason} // '';
        }
        elsif ($type eq 'websocket.http.response.start' || $type eq 'websocket.http.response.body') {
            # Extension denial (websocket.http.response extension): the app
            # rejects the handshake with a real HTTP response instead of a
            # close frame. No RFC6455 close code applies here; the
            # connection is closed once the denial's terminal body chunk
            # lands (sv tracks completion for us).
            $self->{closed} = 1 if $sv->complete;
        }

        return;
    };

    # Start the app future but don't block on it
    $self->{app_future} = $self->{app}->($self->{scope}, $receive, $send);

    # Wait for acceptance (the first two awaits in the app should complete immediately)
    # This is a bit hacky but works: we need to let the app run until it accepts
    $self->_pump_app;

    unless ($self->{accepted}) {
        # A denial (portable close-before-accept, or a completed extension
        # denial) is not an error -- it moves straight to a legal terminal
        # state without ever accepting. Only an app that neither accepted
        # nor reached a legal terminal state is a real bug.
        croak "WebSocket connection not accepted" unless $sv->complete;
    }

    return $self;
}

sub _pump_app {
    my ($self) = @_;

    # This pumps the app future by checking if it's waiting on a receive
    # If there are pending receives and we have data, resolve them
    while (@{$self->{_pending_receives}} && @{$self->{send_queue}}) {
        my $future = shift @{$self->{_pending_receives}};
        my $event = shift @{$self->{send_queue}};
        $future->done($event);
    }

    # If closed, resolve exactly one pending receive with the synthesized
    # disconnect (truthful code and reason). Any later receive stays
    # pending forever -- see the exactly-once contract on the receive
    # coderef in _start.
    if ($self->{closed} && !$self->{_disconnect_delivered} && @{$self->{_pending_receives}}) {
        my $future = shift @{$self->{_pending_receives}};
        $self->{_disconnect_delivered} = 1;
        $future->done({
            type   => 'websocket.disconnect',
            code   => $self->{close_code} // 1000,
            reason => $self->{close_reason} // 'client_closed',
        });
    }
}

sub send_text {
    my ($self, $text) = @_;

    croak "Cannot send on closed WebSocket" if $self->{closed};

    push @{$self->{send_queue}}, {
        type => 'websocket.receive',
        text => $text,
    };

    # Pump the app to process this message
    $self->_pump_app;

    return $self;
}

sub send_bytes {
    my ($self, $bytes) = @_;

    croak "Cannot send on closed WebSocket" if $self->{closed};

    push @{$self->{send_queue}}, {
        type => 'websocket.receive',
        bytes => $bytes,
    };

    # Pump the app to process this message
    $self->_pump_app;

    return $self;
}

sub send_json {
    my ($self, $data) = @_;

    require JSON::MaybeXS;
    my $text = JSON::MaybeXS::encode_json($data);

    return $self->send_text($text);
}

sub receive_text {
    my ($self, $timeout) = @_;
    $timeout //= 5;

    # Check if we have a text message already waiting
    for my $i (0 .. $#{$self->{recv_queue}}) {
        my $event = $self->{recv_queue}[$i];
        if ($event->{type} eq 'websocket.send' && exists $event->{text}) {
            splice @{$self->{recv_queue}}, $i, 1;
            return $event->{text};
        }
    }

    # Check if connection closed
    return undef if $self->{closed};

    # No message available yet
    croak "Timeout waiting for WebSocket text message";
}

sub receive_bytes {
    my ($self, $timeout) = @_;
    $timeout //= 5;

    # Check if we have a bytes message waiting
    for my $i (0 .. $#{$self->{recv_queue}}) {
        my $event = $self->{recv_queue}[$i];
        if ($event->{type} eq 'websocket.send' && exists $event->{bytes}) {
            splice @{$self->{recv_queue}}, $i, 1;
            return $event->{bytes};
        }
    }

    # Check if connection closed
    return undef if $self->{closed};

    # No message available yet
    croak "Timeout waiting for WebSocket bytes message";
}

sub receive_json {
    my ($self, $timeout) = @_;

    my $text = $self->receive_text($timeout);
    return undef unless defined $text;

    require JSON::MaybeXS;
    return JSON::MaybeXS::decode_json($text);
}

sub close {
    my ($self, $code, $reason) = @_;
    return $self->_deliver_disconnect($code // 1000, $reason // 'client_closed');
}

sub simulate_abnormal_close {
    my ($self, %opts) = @_;
    return $self->_deliver_disconnect($opts{code} // 1006, $opts{reason} // 'client_closed');
}

# Shared by close() and simulate_abnormal_close(): marks the connection
# closed with the given code/reason and lets the app observe it exactly
# once, whichever way it's currently waiting (see the exactly-once
# contract in _start/_pump_app).
sub _deliver_disconnect {
    my ($self, $code, $reason) = @_;

    return $self if $self->{closed};

    $self->{closed} = 1;
    $self->{close_code} = $code;
    $self->{close_reason} = $reason;

    # Let the app process the disconnect if it's already waiting on receive
    $self->_pump_app;

    return $self;
}

sub close_code {
    my ($self) = @_;
    return $self->{close_code};
}

sub close_reason {
    my ($self) = @_;
    return $self->{close_reason};
}

sub is_closed {
    my ($self) = @_;
    return $self->{closed};
}

1;

__END__

=head1 NAME

PAGI::Test::WebSocket - WebSocket connection for testing PAGI applications

=head1 SYNOPSIS

    use PAGI::Test::Client;

    my $client = PAGI::Test::Client->new(app => $ws_app);

    # Callback style (auto-close)
    $client->websocket('/ws', sub {
        my ($ws) = @_;
        $ws->send_text('hello');
        is $ws->receive_text, 'echo: hello';
    });

    # Explicit style
    my $ws = $client->websocket('/ws');
    $ws->send_text('hello');
    is $ws->receive_text, 'echo: hello';
    $ws->close;

    # JSON convenience
    $ws->send_json({ action => 'ping' });
    my $data = $ws->receive_json;

=head1 DESCRIPTION

PAGI::Test::WebSocket provides a test client for WebSocket connections in
PAGI applications. It handles the WebSocket protocol handshake and message
exchange, making it easy to test WebSocket endpoints without starting a
real server.

This module is typically used via L<PAGI::Test::Client>'s C<websocket>
method rather than directly.

B<This module is a simplified in-process model of a WebSocket connection.>
It is useful for testing application-level message flow, but it does B<not>
fully emulate transport timing or network buffering.

=head1 SEND STRICTNESS

The C<$send> coderef given to your app is strict: it validates every event
against the PAGI websocket send-sequencing rules via
L<PAGI::SendValidation> and fails the returned Future (the app's C<await
$send-E<gt>(...)> dies) for anything a real server would reject -- a
C<websocket.send>/C<websocket.keepalive> before C<websocket.accept>, any
event once C<websocket.close> has been sent, a second C<websocket.accept>,
or a C<websocket.http.response.*> event out of place. A rejected event is
never appended to the client's readable stream. There is no lenient mode --
see L<PAGI::SendValidation/RULES> for the exact websocket rule set.

C<websocket.close> before C<websocket.accept> is a legal portable denial
(no croak; the connection object reports the closed state -- see
L</close_code>/L</close_reason>). The C<websocket.http.response> extension
denial (C<websocket.http.response.start>/C<.body>) is always recognized by
this test double, mirroring the reference server: the app can reject the
handshake with a full HTTP response instead of a close frame, without
opting into anything. A completed extension denial likewise sets
L</is_closed> true without a croak, but -- unlike a portable denial -- does
B<not> populate L</close_code> (there is no RFC 6455 close code for an HTTP
response).

An app that sends C<websocket.send> after the peer (the test side, via
L</close> or L</simulate_abnormal_close>) has already closed sees the write
silently dropped instead of failing: a real server tolerates writes racing
a peer that has already gone away. A send after the B<app>'s own
C<websocket.close>, by contrast, fails the Future -- the app closed the
connection itself and knows it.

=head1 CONSTRUCTOR

=head2 new

    my $ws = PAGI::Test::WebSocket->new(
        app   => $app,     # Required: PAGI app coderef
        scope => $scope,   # Required: WebSocket scope hashref
    );

Creates a new WebSocket test connection. Typically you don't call this
directly; use L<PAGI::Test::Client>'s C<websocket> method instead.

=head1 METHODS

=head2 send_text

    $ws->send_text('Hello, server!');

Sends a text message to the WebSocket application.

=head2 send_bytes

    $ws->send_bytes("\x00\x01\x02\x03");

Sends a binary message to the WebSocket application.

=head2 send_json

    $ws->send_json({ action => 'ping', id => 123 });

Encodes a Perl data structure as JSON and sends it as a text message.

=head2 receive_text

    my $text = $ws->receive_text;
    my $text = $ws->receive_text($timeout);  # custom timeout in seconds

Waits for and returns the next text message from the server. Returns undef
if the connection is closed.

B<Current limitation:> this method does not actually block or wait for the
timeout duration. If no queued text message is immediately available, it
throws an exception right away.

Only returns text messages; binary messages are skipped.

=head2 receive_bytes

    my $bytes = $ws->receive_bytes;
    my $bytes = $ws->receive_bytes($timeout);

Waits for and returns the next binary message from the server. Returns undef
if the connection is closed.

B<Current limitation:> this method does not actually block or wait for the
timeout duration. If no queued binary message is immediately available, it
throws an exception right away.

Only returns binary messages; text messages are skipped.

=head2 receive_json

    my $data = $ws->receive_json;
    my $data = $ws->receive_json($timeout);

Waits for a text message, decodes it as JSON, and returns the resulting
Perl data structure. Dies if the message is not valid JSON.

=head1 LIMITATIONS

=over 4

=item *

This helper does not simulate real WebSocket framing, network buffering,
backpressure, or wire-level timing behavior.

=item *

The receive timeout arguments are advisory only at present; receive methods
check the current queue immediately rather than waiting asynchronously.

=item *

For protocol-compliance, keepalive timing, or transport-level edge cases,
test against L<PAGI::Server> and a real WebSocket client.

=back

=head2 close

    $ws->close;
    $ws->close($code);
    $ws->close($code, $reason);

Closes the WebSocket connection from the test (peer) side. Default close
code is 1000 (normal closure); default reason is C<client_closed>. Delivers
a truthful C<websocket.disconnect> (carrying this code and reason) to the
app exactly once -- whether the app is already waiting on C<receive> or
calls it later. Idempotent: a second C<close> call is a no-op. See
L</simulate_abnormal_close> to inject an abnormal close instead.

=head2 simulate_abnormal_close

    $ws->simulate_abnormal_close;
    $ws->simulate_abnormal_close(code => 1006, reason => 'keepalive_timeout');

Simulates the transport disappearing abruptly (a TCP reset, a keepalive
timeout, or similar), rather than the test cleanly closing the connection.
Mechanically identical to L</close> -- the app sees exactly one
C<websocket.disconnect> carrying the given code and reason -- but defaults
C<code> to C<1006> (RFC 6455 "abnormal closure") instead of C<1000>, and
its default C<reason> is likewise C<client_closed>. This is the only way to
exercise an app's handling of a specific abnormal-close reason token
through this test double. Idempotent, like C<close>.

=head2 close_code

    my $code = $ws->close_code;

Returns the WebSocket close code if the connection has been closed, or
undef if still open.

=head2 close_reason

    my $reason = $ws->close_reason;

Returns the WebSocket close reason if the connection has been closed, or
an empty string if still open.

=head2 is_closed

    if ($ws->is_closed) {
        say "Connection closed";
    }

Returns true if the WebSocket connection has been closed.

=head1 INTERNAL METHODS

=head2 _start

    $ws->_start;

Internal method called by L<PAGI::Test::Client> to start the WebSocket
connection, send the initial connect event, and wait for acceptance.

=head1 WEBSOCKET PROTOCOL

This module implements the PAGI WebSocket protocol:

=over 4

=item 1. Test sends C<websocket.connect> event

=item 2. App sends C<websocket.accept> event

=item 3. Test sends C<websocket.receive> events with C<text> or C<bytes>

=item 4. App sends C<websocket.send> events with C<text> or C<bytes>

=item 5. Either side ends the connection: the test via L</close> or
L</simulate_abnormal_close> (delivering exactly one C<websocket.disconnect>
to the app, carrying a truthful code and reason -- see L</SEND
STRICTNESS>), or the app via C<websocket.close>

=back

A denial -- C<websocket.close> before C<websocket.accept>, or a completed
C<websocket.http.response.*> extension denial -- ends the connection
without ever reaching step 2; see L</SEND STRICTNESS>.

=head1 EXAMPLE

    use Test2::V0;
    use PAGI::Test::Client;
    use Future::AsyncAwait;

    # Simple echo WebSocket app
    my $ws_app = async sub {
        my ($scope, $receive, $send) = @_;
        return unless $scope->{type} eq 'websocket';

        my $event = await $receive->();
        return unless $event->{type} eq 'websocket.connect';

        await $send->({ type => 'websocket.accept' });

        while (1) {
            my $msg = await $receive->();
            last if $msg->{type} eq 'websocket.disconnect';

            if (defined $msg->{text}) {
                await $send->({
                    type => 'websocket.send',
                    text => "echo: $msg->{text}"
                });
            }
        }
    };

    # Test it
    my $client = PAGI::Test::Client->new(app => $ws_app);
    $client->websocket('/ws', sub {
        my ($ws) = @_;
        $ws->send_text('hello');
        is $ws->receive_text, 'echo: hello', 'echoed text';
    });

=head1 SEE ALSO

L<PAGI::Test::Client>, L<PAGI::Test::Response>, L<PAGI::WebSocket>

=head1 AUTHOR

PAGI Contributors

=cut
