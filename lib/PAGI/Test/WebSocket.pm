package PAGI::Test::WebSocket;

use strict;
use warnings;
use Future::AsyncAwait;
use Future;
use Carp qw(croak);

use PAGI::Utils::_SendValidation;
use PAGI::Test::Response;


sub new {
    my ($class, %args) = @_;

    croak "app is required" unless $args{app};
    croak "scope is required" unless $args{scope};

    croak "close_mode must be cooperative or manual"
        if defined $args{close_mode} && $args{close_mode} !~ /\A(?:cooperative|manual)\z/;
    return bless {
        app         => $args{app},
        scope       => $args{scope},
        send_queue  => [],      # Messages from test -> app
        recv_queue  => [],      # Messages from app -> test
        closed      => 0,
        accepted    => 0,
        close_mode  => $args{close_mode} // 'cooperative',
        close_code  => undef,
        close_reason => '',
        refused     => 0,
        response    => PAGI::Test::Response->new(events => []),
        _end_event  => undef,
        _pending_receives => [],  # Pending receive futures
    }, $class;
}

sub _start {
    my ($self) = @_;

    # extensions is the SAME hashref PAGI::Test::Client advertised on the
    # scope. Ordinary HTTP refusal events are core WWW 0.6 behavior and do
    # not require an extension.
    my $sv = PAGI::Utils::_SendValidation->new(
        scope_type => 'websocket',
        extensions => $self->{scope}{extensions} // {},
    );

    # Create receive coderef for the app
    my $receive = async sub {
        if ($self->{_end_event}) {
            return { %{$self->{_end_event}} };
        }

        # First call returns websocket.connect
        if (!$self->{_connect_sent}) {
            $self->{_connect_sent} = 1;
            return { type => 'websocket.connect' };
        }

        # Return queued message if available
        if (@{$self->{send_queue}}) {
            return shift @{$self->{send_queue}};
        }

        # Create a future that will be resolved when data arrives
        my $future = Future->new;
        push @{$self->{_pending_receives}}, $future;
        return await $future;
    };

    # Create send coderef for the app. Strict: illegal events (per
    # PAGI::Utils::_SendValidation's websocket rules) fail the returned Future --
    # a canonical test double must not accept what a real server would
    # reject -- and are never appended to the client's readable stream.
    my $send = async sub {
        my ($event) = @_;

        my $conn = $self->{scope}{'pagi.connection'};
        local $conn->{_defer_notifications} = 1;
        return if $conn && defined $conn->disconnect_reason && !$self->{_app_close};

        if (my $err = $sv->check($event)) {
            die $err->message . "\n";
        }

        my $type = $event->{type} // '';

        if ($type eq 'websocket.accept') {
            $self->{accepted} = 1;
            $conn->_mark_response_started if $conn;
        }
        elsif ($type eq 'websocket.send') {
            # If the peer (the test side) already closed -- not the app's
            # own websocket.close, which sv already rejected above -- a real
            # server just drops writes to a dead socket: tolerated no-op,
            # nothing reaches the client's readable stream.
            push @{$self->{recv_queue}}, $event unless $self->{closed} || $self->{_peer_close};
        }
        elsif ($type eq 'websocket.close') {
            $self->{_app_close} = 1;
            # The first app Close may race a peer Close already handled by
            # the test transport. Validation still records the terminal send.
            if ($conn->is_connected && !$self->{_peer_close}) {
                $self->{close_code} = $event->{code} // 1000;
                $self->{close_reason} = $event->{reason} // '';
                if ($self->{close_mode} eq 'cooperative') {
                    $self->close($self->{close_code}, $self->{close_reason});
                }
            }
        }
        elsif ($type =~ /^http\.response\./) {
            $self->{response}->_capture_event($event);
            $conn->_mark_response_started
                if $conn && $type eq 'http.response.start';

            if ($sv->complete) {
                $self->{closed} = 1;
                $self->{refused} = 1;
                $self->{_end_event} = { type => 'http.disconnect' };
                $conn->_mark_complete if $conn;
                $self->_wake_pending_receives;
            }
        }

        return;
    };

    # Start the app future but don't block on it
    $self->{app_future} = $self->{app}->($self->{scope}, $receive, $send);

    # Wait for acceptance (the first two awaits in the app should complete immediately)
    # This is a bit hacky but works: we need to let the app run until it accepts
    $self->pump;

    $self->{app_future}->on_ready(sub {
        my ($future) = @_;
        my $conn = $self->{scope}{'pagi.connection'};
        # Validator completion precedes body capture; a failed refusal read
        # is not delivery. Only an app Close or peer Close may keep an active
        # socket waiting for the manual transport outcome after app return.
        if ($conn->is_connected && !$self->{_app_close} && !$self->{_peer_close}) {
            my $detail = $future->is_failed ? scalar($future->failure) : undef;
            $self->_transport_closed(code => 1011, reason => 'server_error', detail => $detail);
        }
        $conn->_deliver_notifications;
    });
    $self->pump;

    unless ($self->{accepted} || $self->{refused}) {
        # Surface an application/send failure instead of replacing it with a
        # generic handshake error.
        $self->{app_future}->get if $self->{app_future}->is_ready;
        croak "WebSocket connection not accepted";
    }

    return $self;
}

sub pump {
    my ($self) = @_;
    $self->_pump_app;
    $self->{scope}{'pagi.connection'}->_deliver_notifications;
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

    $self->_wake_pending_receives if $self->{_end_event};
}

sub _wake_pending_receives {
    my ($self) = @_;
    return unless $self->{_end_event};

    while (my $future = shift @{$self->{_pending_receives}}) {
        $future->done({ %{$self->{_end_event}} }) unless $future->is_ready;
    }

    return;
}

sub send_text {
    my ($self, $text) = @_;

    croak "Cannot send on closed WebSocket" if $self->{closed};

    push @{$self->{send_queue}}, {
        type => 'websocket.receive',
        text => $text,
    };

    # Pump the app to process this message
    $self->pump;

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
    $self->pump;

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
    $self->pump;
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
    $self->pump;
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
    my ($self, @args) = @_;
    my $conn = $self->{scope}{'pagi.connection'};
    return $self->pump unless $conn->is_connected;
    return $self->pump if $self->{_peer_close};

    # No arguments is an ordinary 1000 Close; explicit undef models an
    # empty Close payload, whose peer metadata is 1005/undef.
    my ($code, $reason) = @args ? @args : (1000, '');
    $reason = defined $code ? ($reason // '') : undef;
    $code //= 1005;
    $self->{_peer_close} = 1;
    $conn->_set_peer_close($code, $reason);
    $self->{close_code} = $code;
    $self->{close_reason} = $reason;
    $self->{_end_event} = {
        type => 'websocket.disconnect', code => $code,
        (defined $reason ? (reason => $reason) : ()),
    };
    # A peer-initiated Close is answered by the test server automatically.
    # Manual mode holds only transport completion for explicit resolution.
    return $self->complete_close if $self->{close_mode} eq 'cooperative';
    $self->_wake_pending_receives;
    return $self->pump;
}

sub complete_close {
    my ($self) = @_;
    my $conn = $self->{scope}{'pagi.connection'};
    return $self->pump unless $conn->is_connected;
    croak "Cannot complete closing handshake without a peer Close" unless $self->{_peer_close};
    $self->{closed} = 1;
    $conn->_mark_complete;
    $self->_wake_pending_receives;
    return $self->pump;
}

sub simulate_close_timeout {
    my ($self) = @_;
    return $self->pump unless $self->{scope}{'pagi.connection'}->is_connected;
    croak "Close timeout requires an app Close awaiting a peer" unless $self->{_app_close} && !$self->{_peer_close};
    return $self->_transport_closed(reason => 'close_timeout');
}

sub simulate_abnormal_close {
    my ($self, %opts) = @_;
    croak "close_incomplete requires a peer Close"
        if ($opts{reason} // '') eq 'close_incomplete'
            && $self->{scope}{'pagi.connection'}->is_connected
            && !$self->{_peer_close};
    return $self->_transport_closed(%opts);
}

sub _transport_closed {
    my ($self, %opts) = @_;
    return $self->pump if $self->{closed};
    $self->{closed} = 1;
    my $conn = $self->{scope}{'pagi.connection'};
    # This accessor is peer data, independent of a server-generated event.
    $conn->_set_peer_close(1006, undef) unless defined $conn->close_code;
    $conn->_mark_disconnected($opts{reason} // 'client_closed', $opts{detail})
        if $conn->is_connected;
    my $reason = $conn->disconnect_reason // $opts{reason} // 'client_closed';
    unless ($self->{_peer_close}) {
        $self->{close_code} = $opts{code} // 1006;
        $self->{close_reason} = $reason;
        $self->{_end_event} = {
            type => 'websocket.disconnect', code => $self->{close_code}, reason => $reason,
        };
    }
    $self->_wake_pending_receives;
    return $self->pump;
}

sub refused { return $_[0]->{refused} ? 1 : 0 }

sub response {
    my ($self) = @_;
    return $self->{refused} ? $self->{response} : undef;
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
L<PAGI::Utils::_SendValidation> and fails the returned Future (the app's C<await
$send-E<gt>(...)> dies) for anything a real server would reject -- a
C<websocket.send>/C<websocket.keepalive> before C<websocket.accept>, any
event once C<websocket.close> has been sent, a second C<websocket.accept>,
or a C<http.response.*> refusal event out of place. A rejected event is
never appended to the client's readable stream. There is no lenient mode --
see L<PAGI::Utils::_SendValidation/RULES> for the exact websocket rule set.

C<websocket.close> before C<websocket.accept> is rejected. Refuse a handshake
with ordinary C<http.response.start> and C<http.response.body> events.
A completed refusal sets C<refused> and C<is_closed>; C<response> returns the
captured L<PAGI::Test::Response>. It has no WebSocket Close metadata.

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

Supplies a Close from the test peer. With no arguments the code is 1000
and reason is an empty string. C<close(undef, undef)> models an empty Close
payload (peer metadata C<1005>/C<undef>). Pending and later application
receives report the Close. Repeated peer Close calls are harmless.

=head2 Close outcome controls

    my $ws = $client->websocket('/ws', close_mode => 'manual');
    $ws->close(1008, 'peer policy');
    $ws->complete_close;

The default C<close_mode> is C<cooperative>: the simulated peer echoes an
application Close and transport completion follows immediately. C<manual>
holds closure open so a test can supply peer Close and transport outcomes
separately. An application Close alone leaves the connection active and its
peer metadata undefined. C<close> supplies peer metadata; the simulated
server answers a peer-initiated Close automatically. C<complete_close>
requires a peer Close and completes the transport cleanly.

C<simulate_close_timeout> ends an application Close waiting for a peer with
C<close_timeout>, peer code 1006 and undefined peer reason. It requires an
application Close with no peer reply. No real timer runs.

=head2 simulate_abnormal_close

    $ws->simulate_abnormal_close(reason => 'read_error');
    $ws->simulate_abnormal_close(reason => 'close_incomplete');

Models a transport failure, preserving any observed peer Close metadata;
without one the connection object reports 1006 and an undefined peer reason.
Use C<close_incomplete> after a peer Close when transport closure cannot
complete. The default reason is C<client_closed>. The optional C<code>
controls a server-generated disconnect event, not peer metadata. Outcomes
are immutable after completion. These controls model outcomes, not sockets,
buffering, deadlines, or server configuration.

=head2 pump

    $ws->pump;

Drains pending receives and deferred terminal notifications. Public client
operations and application Future completion do this automatically. If a test
resolves an external Future and the app then parks again after a terminal
send, call C<pump> to deliver its queued notifications. Terminal facts are
already readable before pumping. This in-process client has no event loop.

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

A refusal uses ordinary C<http.response.*> events and is exposed through
C<refused> and C<response>. A C<websocket.close> before acceptance is illegal.
After a completed refusal, pending and later receives report C<http.disconnect>.

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
