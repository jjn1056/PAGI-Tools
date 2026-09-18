package PAGI::Test::SSE;

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

    return bless {
        app        => $args{app},
        scope      => $args{scope},
        request_body => $args{request_body} // '',
        recv_queue => [],      # Events from app -> test
        closed     => 0,
        started    => 0,
        refused    => 0,
        response   => PAGI::Test::Response->new(events => []),
        close_reason => undef,
        _end_event => undef,
        _pending_receives => [],
    }, $class;
}

sub _start {
    my ($self) = @_;

    # extensions is the SAME hashref PAGI::Test::Client advertised on the
    # scope's `extensions` key -- one source of truth (B10), not a separately
    # hardcoded list. PAGI::Test::Client always sets this (currently to {}:
    # the mock implements no sse extensions); the // {} guards direct
    # construction of this class with a scope that omits the key.
    my $sv = PAGI::Utils::_SendValidation->new(
        scope_type => 'sse',
        extensions => $self->{scope}{extensions} // {},
    );

    # Create receive coderef for the app.
    my $receive = async sub {
        if ($self->{_end_event}) {
            return { %{$self->{_end_event}} };
        }

        if (!$self->{_request_sent}) {
            $self->{_request_sent} = 1;
            return {
                type => 'sse.request', body => $self->{request_body}, more => 0,
            };
        }

        # After the one request-body event, SSE receives only disconnects.
        my $future = Future->new;
        # This future will be resolved when close() is called
        push @{$self->{_pending_receives}}, $future;
        return await $future;
    };

    # Create send coderef for the app. Strict: illegal events (per
    # PAGI::Utils::_SendValidation's sse rules) fail the returned Future -- a
    # canonical test double must not accept what a real server would
    # reject -- and are never appended to the client's readable stream.
    my $send = async sub {
        my ($event) = @_;

        my $conn = $self->{scope}{'pagi.connection'};
        local $conn->{_defer_notifications} = 1;
        return if $conn && defined $conn->disconnect_reason;

        if (my $err = $sv->check($event)) {
            die $err->message . "\n";
        }

        my $type = $event->{type} // '';

        if ($type eq 'sse.start') {
            $self->{started} = 1;
            $self->{status} = $event->{status} // 200;
            $self->{headers} = $event->{headers} // [];
            $conn->_mark_response_started if $conn;
        }
        elsif ($type eq 'sse.send') {
            # If the peer (the test side) already closed, a real server
            # just drops writes to a dead connection: tolerated no-op,
            # nothing reaches the client's readable stream.
            push @{$self->{recv_queue}}, $event unless $self->{closed};
        }
        elsif ($type eq 'sse.close') {
            # Clean terminal sends also wake pending and later receives.
            $self->{closed} = 1;
            $self->{_end_event} = { type => 'sse.disconnect' };
            $conn->_mark_complete if $conn;
            $self->_wake_pending_receives;
        }
        elsif ($type =~ /^http\.response\./) {
            $self->{response}->_capture_event($event);
            $conn->_mark_response_started
                if $conn && $type eq 'http.response.start';

            if ($sv->complete) {
                $self->{closed} = 1;
                $self->{refused} = 1;
                $self->{_end_event} = { type => 'sse.disconnect' };
                $conn->_mark_complete if $conn;
                $self->_wake_pending_receives;
            }
        }

        return;
    };

    # Start the app future but don't block on it
    $self->{app_future} = $self->{app}->($self->{scope}, $receive, $send);

    # Wait for sse.start (this should complete immediately)
    # We need to let the app run until it starts
    $self->pump;

    $self->{app_future}->on_ready(sub {
        my ($future) = @_;
        my $conn = $self->{scope}{'pagi.connection'};
        # Successful close/refusal capture already ended the scope. A
        # validator-complete event whose body capture failed has not.
        if ($conn->is_connected) {
            my $detail = $future->is_failed ? scalar($future->failure) : undef;
            $self->_transport_closed(reason => 'server_error', detail => $detail);
        }
        $conn->_deliver_notifications;
    });
    $self->pump;

    unless ($self->{started} || $self->{refused}) {
        $self->{app_future}->get if $self->{app_future}->is_ready;
        croak "SSE connection not started";
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

# ---------------------------------------------------------------------------
# Internal accessors used by PAGI::Test::Client to build a PAGI::Test::Response
# when the app declines instead of starting a stream. Not part of the public
# API -- a declined connection is never handed back to test code as an SSE
# object at all (see PAGI::Test::Client's sse method).
# ---------------------------------------------------------------------------

sub refused { return $_[0]->{refused} ? 1 : 0 }

sub response {
    my ($self) = @_;
    return $self->{refused} ? $self->{response} : undef;
}

sub receive_event {
    my ($self, %opts) = @_;
    $self->pump;
    my $timeout = $opts{timeout} // 5;

    # Check if we have an event already waiting
    if (@{$self->{recv_queue}}) {
        my $event = shift @{$self->{recv_queue}};

        # Extract SSE event fields
        return {
            event => $event->{event},
            data  => $event->{data},
            id    => $event->{id},
            retry => $event->{retry},
        };
    }

    # Check if connection closed
    return undef if $self->{closed};

    # No event available yet
    croak "Timeout waiting for SSE event";
}

sub receive_json {
    my ($self, %opts) = @_;

    my $event = $self->receive_event(%opts);
    return undef unless defined $event;

    require JSON::MaybeXS;
    return JSON::MaybeXS::decode_json($event->{data});
}

sub close {
    my ($self, $reason) = @_;
    return $self->_transport_closed(reason => $reason // 'client_closed');
}

sub _transport_closed {
    my ($self, %opts) = @_;
    return $self if $self->{closed};

    $self->{closed} = 1;
    my $conn = $self->{scope}{'pagi.connection'};
    if ($conn && $conn->is_connected) {
        $conn->_mark_disconnected($opts{reason} // 'client_closed', $opts{detail});
    }
    my $reason = $conn ? $conn->disconnect_reason : undef;
    $reason //= $opts{reason} // 'client_closed';
    $self->{close_reason} = $reason;
    $self->{_end_event} = { type => 'sse.disconnect', reason => $reason };
    $self->_wake_pending_receives;

    return $self;
}

sub is_closed {
    my ($self) = @_;
    return $self->{closed};
}

1;

__END__

=head1 NAME

PAGI::Test::SSE - Server-Sent Events connection for testing PAGI applications

=head1 SYNOPSIS

    use PAGI::Test::Client;

    my $client = PAGI::Test::Client->new(app => $sse_app);

    # Callback style (auto-close)
    $client->sse('/events', sub {
        my ($sse) = @_;
        my $event = $sse->receive_event;
        is $event->{event}, 'connected';
        is $event->{data}, '{"subscriber_id":1}';
    });

    # Explicit style
    my $sse = $client->sse('/events');
    my $event = $sse->receive_event;
    is $event->{event}, 'update';
    $sse->close;

    # JSON convenience
    my $sse = $client->sse('/events');
    my $data = $sse->receive_json;
    is $data->{subscriber_id}, 1;
    $sse->close;

=head1 DESCRIPTION

PAGI::Test::SSE provides a test client for Server-Sent Events (SSE) connections
in PAGI applications. It handles the SSE protocol handshake and event reception,
making it easy to test SSE endpoints without starting a real server.

This module is typically used via L<PAGI::Test::Client>'s C<sse> method rather
than directly.

SSE is a unidirectional protocol where the server sends events to the client.
Unlike WebSocket, the client cannot send messages back (except for disconnect).

B<This module is a simplified in-process model of an SSE connection.> It is
well-suited to application-level event testing, but it does B<not> emulate
transport timing, buffering, or wire-format behavior.

If the app declines instead of starting a stream (C<http.response.*>),
L<PAGI::Test::Client>'s C<sse> method never hands you an SSE connection
object at all -- it returns a L<PAGI::Test::Response> instead, mirroring
the server. See L<PAGI::Test::Client/sse>.

=head1 SEND STRICTNESS

The C<$send> coderef given to your app is strict: it validates every event
against the PAGI sse send-sequencing rules via L<PAGI::Utils::_SendValidation> and
fails the returned Future (the app's C<await $send-E<gt>(...)> dies) for
anything a real server would reject -- a duplicate C<sse.start>, a decline
event after C<sse.start>, any stream event after a decline has started, or
any event once a decline is complete. A rejected event is never appended
to the client's readable stream. There is no lenient mode -- see
L<PAGI::Utils::_SendValidation/RULES> for the exact sse rule set.

C<sse.close> is recognized as legal for the app to send proactively (it
ends the stream from the server side; pending and later receives report
C<sse.disconnect> with no reason) and is idempotent once
C<closed>, matching the reference server.

An app that sends C<sse.send> after the peer (the test side, via L</close>)
has already closed sees the write silently dropped instead of failing: a
real server tolerates writes racing a peer that has already gone away.

=head1 CONSTRUCTOR

=head2 new

    my $sse = PAGI::Test::SSE->new(
        app   => $app,     # Required: PAGI app coderef
        scope => $scope,   # Required: SSE scope hashref
    );

Creates a new SSE test connection. Typically you don't call this directly;
use L<PAGI::Test::Client>'s C<sse> method instead.

=head1 METHODS

=head2 receive_event

    my $event = $sse->receive_event;
    my $event = $sse->receive_event(timeout => 10);

Waits for and returns the next event from the server. Returns a hashref with
the following fields:

=over 4

=item event

The event type (optional). If not specified in the server message, this will
be undef.

=item data

The event data (required). This is the raw string data sent by the server.

=item id

The event ID (optional). Can be used for reconnection logic.

=item retry

The retry time in milliseconds (optional). Indicates how long the client should
wait before reconnecting.

=back

Returns undef if the connection is closed. Throws an exception if timeout is
reached.

B<Current limitation:> this method does not actually block or wait for the
timeout duration. If no queued SSE event is immediately available, it throws
an exception right away.

Example:

    my $event = $sse->receive_event;
    if ($event->{event} eq 'update') {
        say "Received update: $event->{data}";
    }

=head2 receive_json

    my $data = $sse->receive_json;
    my $data = $sse->receive_json(timeout => 10);

Waits for an event, extracts the data field, decodes it as JSON, and returns
the resulting Perl data structure. Dies if the data is not valid JSON.

This is a convenience method equivalent to:

    my $event = $sse->receive_event;
    my $data = decode_json($event->{data});

=head1 LIMITATIONS

=over 4

=item *

This helper does not simulate real SSE wire formatting, chunking, buffering,
or transport timing.

=item *

The receive timeout arguments are advisory only at present; receive methods
check the current queue immediately rather than waiting asynchronously.

=item *

For keepalive behavior, disconnect timing, or full transport-level testing,
test against L<PAGI::Server>.

=back

Example:

    my $data = $sse->receive_json;
    is $data->{subscriber_id}, 1;

=head2 close

    $sse->close;
    $sse->close($reason);

Closes the SSE connection from the test (peer) side. Delivers a truthful
C<sse.disconnect> (carrying this reason, default C<client_closed>) to the
application on pending and later receives -- whether the app is already waiting on
C<receive> or calls it later. Idempotent: a second C<close> call is a
no-op.

=head2 is_closed

    if ($sse->is_closed) {
        say "Connection closed";
    }

Returns true if the SSE connection has been closed.

=head1 INTERNAL METHODS

=head2 _start

    $sse->_start;

Internal method called by L<PAGI::Test::Client> to start the SSE connection,
send the initial scope to the app, and wait for either the C<sse.start>
event or a completed decline (C<http.response.*>). Does not croak on a
decline; L<PAGI::Test::Client> checks C<refused> afterward and returns the
captured C<response> for an HTTP refusal.

=head2 pump

    $sse->pump;

Drains pending receives and deferred terminal notifications. Public client
operations and application Future completion do this automatically. If a test
resolves an external Future and the app then parks again after a terminal
send, call C<pump> to deliver its queued notifications. Terminal facts are
already readable before pumping. This in-process client has no event loop.

=head1 SSE PROTOCOL

This module implements the PAGI SSE protocol:

=over 4

=item 1. App sends C<sse.start> event with status and headers -- or, instead,
declines with C<http.response.start>/C<.body> (see L</SEND STRICTNESS>)

=item 2. App sends C<sse.send> events with event/data/id/retry fields

=item 3. Either side ends the connection: the test via L</close> (delivering
C<sse.disconnect> on pending and later receives to the app, carrying a truthful reason), or
the app via C<sse.close>

=back

=head1 EXAMPLE

    use Test2::V0;
    use PAGI::Test::Client;
    use Future::AsyncAwait;

    # Simple SSE app that sends a few events
    my $sse_app = async sub {
        my ($scope, $receive, $send) = @_;
        die "Expected sse scope" unless $scope->{type} eq 'sse';

        await $send->({
            type    => 'sse.start',
            status  => 200,
            headers => [],
        });

        await $send->({
            type  => 'sse.send',
            event => 'connected',
            data  => '{"subscriber_id":1}',
        });

        await $send->({
            type  => 'sse.send',
            event => 'update',
            data  => '{"count":42}',
            id    => 'msg-1',
        });
    };

    # Test it
    my $client = PAGI::Test::Client->new(app => $sse_app);
    $client->sse('/events', sub {
        my ($sse) = @_;

        my $event1 = $sse->receive_event;
        is $event1->{event}, 'connected', 'first event type';

        my $event2 = $sse->receive_event;
        is $event2->{event}, 'update', 'second event type';
        is $event2->{id}, 'msg-1', 'event id';
    });

=head1 SEE ALSO

L<PAGI::Test::Client>, L<PAGI::Test::Response>, L<PAGI::Test::WebSocket>

=head1 AUTHOR

PAGI Contributors

=cut
