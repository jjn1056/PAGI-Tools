package PAGI::WebSocket;
use strict;
use warnings;
use parent 'PAGI::HTTPConnection';
use Carp qw(croak);
use PAGI::Utils ();
use Future::AsyncAwait;
use Future;
use JSON::MaybeXS ();
use PAGI::Utils::_ProtocolHelpers ();
use PAGI::FutureOwner;
use Scalar::Util qw(blessed);


sub new {
    my ($class, $scope, $receive, $send) = @_;

    croak "PAGI::WebSocket requires scope hashref"
        unless $scope && ref($scope) eq 'HASH';
    croak "PAGI::WebSocket requires receive coderef"
        unless $receive && ref($receive) eq 'CODE';
    croak "PAGI::WebSocket requires send coderef"
        unless $send && ref($send) eq 'CODE';
    croak "PAGI::WebSocket requires scope type 'websocket', got '$scope->{type}'"
        unless ($scope->{type} // '') eq 'websocket';
    # PAGI::Spec::Www 0.6: servers provide pagi.connection on every scope.
    PAGI::Utils::_ProtocolHelpers::require_connection($scope, 'PAGI::WebSocket');

    # One object per call: nothing is cached in the scope, so a handler
    # keeps the object it was given (SUBCLASSING).
    my $self = $class->SUPER::new($scope);
    $self->{receive} = $receive;
    $self->{send} = $send;
    $self->{_state} = 'connecting';  # connecting -> connected -> closed
    $self->{_close_code} = undef;
    $self->{_close_reason} = undef;
    $self->{_on_close} = [];
    $self->{_on_error} = [];
    $self->{_on_message} = [];

    $self->{_cleanup_future} = Future->new;
    $self->{_owner} = PAGI::FutureOwner->new;
    $self->{_ended} = Future->new;
    # The connection owns this helper until end. Cleanup then belongs to the
    # helper's owner, so whoever awaits finished waits for it too.
    $scope->{'pagi.connection'}->on_end(sub {
        $self->_refresh_connection;
        $self->_start_close_callbacks;
        $self->{_ended}->done;
        return;
    });
    $self->_refresh_connection;
    return $self;
}

sub _refresh_connection {
    my ($self) = @_;
    my $connection = $self->{scope}{'pagi.connection'};
    $self->{_disconnect_reason} = $connection->disconnect_reason;
    $self->{_disconnect_detail} = $connection->disconnect_detail;
    $self->{_close_code} = $connection->close_code;
    $self->{_close_reason} = $connection->close_reason;
    $self->{_state} = 'closed' unless $connection->is_connected;
    return;
}

# An initial helper cannot claim a response slot already used by an application.
# Accepted/started helpers continue to use their established protocol.
sub _response_claimed_before_start {
    my ($self) = @_;
    $self->_refresh_connection;
    return $self->{_state} eq 'connecting'
        && $self->{scope}{'pagi.connection'}->response_started;
}

sub disconnect_detail {
    my ($self) = @_;
    $self->_refresh_connection;
    return $self->{_disconnect_detail};
}

# What the scope holds is read through PAGI::HTTPConnection; the
# subprotocols the client offered are WebSocket's own.
sub subprotocols { shift->{scope}{subprotocols} // [] }

# State accessors
sub connection_state { my $self = shift; $self->_refresh_connection; return $self->{_state} }

sub is_connected {
    my $self = shift;
    return $self->connection_state eq 'connected';
}

sub is_closed {
    my $self = shift;
    return $self->connection_state eq 'closed';
}

sub close_code { my $self = shift; $self->_refresh_connection; return $self->{_close_code} }
sub close_reason { my $self = shift; $self->_refresh_connection; return $self->{_close_reason} }
sub disconnect_reason { my $self = shift; $self->_refresh_connection; return $self->{_disconnect_reason} }

# Outbound flow-control introspection (delegates to the pagi.transport handle)
sub buffered_amount {
    my $self = shift;
    my $t = $self->{scope}{'pagi.transport'};
    return 0 unless $t;
    return $t->buffered_amount;
}

sub high_water_mark {
    my $self = shift;
    my $t = $self->{scope}{'pagi.transport'};
    return undef unless $t;
    return $t->high_water_mark;
}

sub low_water_mark {
    my $self = shift;
    my $t = $self->{scope}{'pagi.transport'};
    return undef unless $t;
    return $t->low_water_mark;
}

sub on_high_water {
    my ($self, $cb) = @_;
    my $t = $self->{scope}{'pagi.transport'};
    $t->on_high_water($cb) if $t && $t->can('on_high_water');
    return $self;
}

sub on_drain {
    my ($self, $cb) = @_;
    my $t = $self->{scope}{'pagi.transport'};
    $t->on_drain($cb) if $t && $t->can('on_drain');
    return $self;
}

sub is_writable {
    my $self = shift;
    my $t = $self->{scope}{'pagi.transport'};
    return 1 unless $t;
    my $high = $t->high_water_mark;
    return 1 unless defined $high;
    return $t->buffered_amount < $high ? 1 : 0;
}

# Internal state setter
sub _set_state {
    my ($self, $state) = @_;
    $self->{_state} = $state;
}

# Register callback to run on disconnect/close
sub on_close {
    my ($self, $callback) = @_;
    # Once the connection has ended, a callback runs now, after any still
    # running, as the spec's on_end does.
    return $self->_run_late_close_callback($callback) if $self->{_close_callbacks_ran};
    push @{$self->{_on_close}}, $callback;
    return $self;
}

sub _run_late_close_callback {
    my ($self, $callback) = @_;
    $self->{_close_chain} = $self->{_owner}->adopt(
        $self->_late_close_worker($self->{_close_chain}, $callback));
    return $self;
}

# A late callback's failure fails finished while the handler can still see
# it; once finished has resolved there is nothing left to fail, so it warns.
async sub _late_close_worker {
    my ($self, $previous, $callback) = @_;
    # The callbacks before it report their own failures.
    eval { await $previous->without_cancel };
    my $ok = eval {
        my $result = $callback->($self->close_code, $self->close_reason, $self->disconnect_detail);
        await $result if blessed($result) && $result->isa('Future');
        1;
    };
    return if $ok;
    die $@ unless $self->{_finished};
    warn ref($self) . " on_close callback failed after the handler finished: $@";
    return;
}

# Internal: run all on_close callbacks exactly once, as work the helper owns
sub _run_close_callbacks {
    my ($self) = @_;
    $self->_start_close_callbacks;
    return $self->{_cleanup_future}->without_cancel;
}

sub _start_close_callbacks {
    my ($self) = @_;
    return if $self->{_close_callbacks_ran};
    $self->{_close_callbacks_ran} = 1;
    my $completion = $self->{_cleanup_future};
    my $worker = $self->{_owner}->adopt($self->_close_callbacks_worker);
    $self->{_close_chain} = $worker;
    # The cleanup Future means the callbacks have run; a callback's failure
    # is reported once, through finished.
    $worker->on_ready(sub { $completion->done unless $completion->is_ready });
    return;
}

async sub _close_callbacks_worker {
    my ($self) = @_;
    my @failures;
    for my $cb (@{$self->{_on_close}}) {
        my $ok = eval {
            my $result = $cb->($self->close_code, $self->close_reason, $self->disconnect_detail);
            await $result if blessed($result) && $result->isa('Future');
            1;
        };
        push @failures, $@ unless $ok;
    }
    $self->{_on_close} = [];
    $self->{_on_error} = [];
    $self->{_on_message} = [];
    # Every callback has run; the first failure is the helper's to report.
    die $failures[0] if @failures;
    return;
}

# Resolves to the helper once its scope has ended and all the work it
# started -- its on_close callbacks included -- has settled; fails with the
# first on_close failure.
async sub finished {
    my ($self) = @_;
    # A scope never accepted (or started) ends only when the application
    # returns, so waiting for its end would wait for the caller itself.
    await $self->{_ended}->without_cancel if $self->_ends_without_application;
    my $settled = eval { await $self->{_owner}->settled; 1 };
    my $error = $@;
    $self->{_finished} = 1;
    die $error unless $settled;
    return $self;
}

sub _ends_without_application {
    my ($self) = @_;
    return $self->connection_state ne 'connecting';
}

# Internal: a disconnect event arrived off the wire. The connection already
# recorded the terminal outcome (and runs on_close from its on_end), so only
# the helper's view of it is refreshed. Sends nothing: the peer is gone.
async sub _note_disconnected {
    my ($self) = @_;
    $self->_refresh_connection;
    return;
}

# Register callback to run on errors
sub on_error {
    my ($self, $callback) = @_;
    push @{$self->{_on_error}}, $callback;
    return $self;
}

# Register callback to run on message receive
sub on_message {
    my ($self, $callback) = @_;
    push @{$self->{_on_message}}, $callback;
    return $self;
}

# Generic event registration (Socket.IO style)
sub on {
    my ($self, $event, $callback) = @_;

    if ($event eq 'message') {
        return $self->on_message($callback);
    }
    elsif ($event eq 'close') {
        return $self->on_close($callback);
    }
    elsif ($event eq 'error') {
        return $self->on_error($callback);
    }
    else {
        croak "Unknown event type: $event (expected message, close, or error)";
    }
}

# Internal: trigger error callbacks
async sub _trigger_error {
    my ($self, $error) = @_;

    for my $cb (@{$self->{_on_error}}) {
        eval {
            my $r = $cb->($error);
            if (blessed($r) && $r->isa('Future')) {
                await $r;
            }
        };
        if ($@) {
            warn "PAGI::WebSocket on_error callback error: $@";
        }
    }
}

# Accept the WebSocket connection
async sub accept {
    my ($self, %opts) = @_;
    return $self if $self->_response_claimed_before_start || $self->connection_state eq 'closing';

    return $self if $self->is_closed;

    my $event = {
        type => 'websocket.accept',
    };
    $event->{subprotocol} = $opts{subprotocol} if exists $opts{subprotocol};
    if (exists $opts{headers}) {
        my ($headers, $refused) = PAGI::Utils::_sendable_headers('PAGI::WebSocket accept', $opts{headers});
        croak $refused if $refused;
        $event->{headers} = $headers;
    }

    await PAGI::Utils::_ProtocolHelpers::forward_send($self, $event);
    $self->_set_state('connected') unless $self->is_closed;

    return $self;
}

# Keeps a Future the helper returned to its caller until it settles, so
# finished waits for it. Its failure is the caller's to see: the owner keeps
# only its completion. The callback also holds the caller's Future, so a
# caller may drop it.
sub _keep {
    my ($self, $future) = @_;
    my $completion = $future->else_done;
    my $held = $future;
    $completion->on_ready(sub { undef $held });
    $self->{_owner}->adopt($completion);
    return $future;
}

# Close the WebSocket connection
sub close {
    my ($self, @args) = @_;
    return Future->done($self) if $self->_response_claimed_before_start;
    return $self->_keep($self->{_close_send}->without_cancel->then(sub { Future->done($self) }))
        if $self->{_close_send};
    return Future->done if $self->is_closed;
    # Before accept the scope is an HTTP exchange: refusing it is deny's job.
    croak 'WebSocket close is only valid after accept; use deny'
        if $self->{_state} eq 'connecting';
    croak "WebSocket close requires an active accepted/started connection"
        unless $self->is_connected;
    my ($code, $reason) = @args;
    if (defined $reason) {
        defined($reason = PAGI::Utils::_string_value($reason))
            or croak 'close reason must be a string or an object that overloads stringification';
    }
    $self->{_state} = 'closing';
    my $settled = $self->{_close_send} = Future->new;
    my $send;
    my $ok = eval {
        $send = Future->wrap(PAGI::Utils::_ProtocolHelpers::forward_send($self, {type => 'websocket.close', code => $code // 1000, reason => $reason // ''}));
        1;
    };
    if (!$ok) { $settled->fail($@) }
    else {
        $send->on_ready(sub {
            my ($ready) = @_;
            if ($ready->is_failed) { $settled->fail($ready->failure) }
            elsif ($ready->is_cancelled) { $settled->fail("Close send was cancelled\n") }
            else { $settled->done }
        });
    }
    return $self->_keep($settled->without_cancel->then(sub { Future->done($self) }));
}

# Delegate the handshake refusal to a public PAGI application. Valid only
# before accept.
async sub deny {
    my ($self, @targets) = @_;
    my $app = PAGI::Utils::_ProtocolHelpers::prepare_refusal(
        $self->{scope}, 'WebSocket deny', @targets,
    );
    await PAGI::Utils::invoke_app(
        $app, $self->{scope}, $self->{receive}, $self->{send},
    );
    return $self;
}

# End the socket however its state allows: refuse the handshake before
# accept, close an accepted socket, and do nothing once the connection is
# gone -- a client that hung up is not the application's error.
async sub close_or_deny {
    my ($self, $code, $reason, $response) = @_;
    return $self if $self->_response_claimed_before_start;
    if ($self->connection_state eq 'connecting') {
        require PAGI::Response::Text;
        await $self->deny($response // PAGI::Response::Text->new(
            (defined($reason) && length($reason) ? $reason : 'Forbidden'), status => 403,
        ));
        return $self;
    }
    await $self->close($code, $reason);
    return $self;
}

# Send text message
async sub send_text {
    my ($self, $text) = @_;

    croak "Cannot send on closed WebSocket" if $self->_response_claimed_before_start || $self->is_closed || $self->connection_state eq 'closing';
    defined($text = PAGI::Utils::_string_value($text))
        or croak 'send_text requires a string or an object that overloads stringification';

    await PAGI::Utils::_ProtocolHelpers::forward_send($self, {
        type => 'websocket.send',
        text => $text,
    });

    return $self;
}

# Send binary message
async sub send_bytes {
    my ($self, $bytes) = @_;

    croak "Cannot send on closed WebSocket" if $self->_response_claimed_before_start || $self->is_closed || $self->connection_state eq 'closing';
    defined($bytes = PAGI::Utils::_string_value($bytes))
        or croak 'send_bytes requires a string or an object that overloads stringification';
    defined($bytes = PAGI::Utils::_byte_string($bytes))
        or croak 'send_bytes must be encoded bytes: it contains a character above 0xFF; encode text first, or use send_text';

    await PAGI::Utils::_ProtocolHelpers::forward_send($self, {
        type  => 'websocket.send',
        bytes => $bytes,
    });

    return $self;
}

# Send JSON-encoded message
async sub send_json {
    my ($self, $data) = @_;

    croak "Cannot send on closed WebSocket" if $self->_response_claimed_before_start || $self->is_closed || $self->connection_state eq 'closing';

    my $json = JSON::MaybeXS::encode_json($data);

    await PAGI::Utils::_ProtocolHelpers::forward_send($self, {
        type => 'websocket.send',
        text => $json,
    });

    return $self;
}

# Safe send methods - return bool instead of throwing

# Best-effort sends never throw, so broadcast loops may make one and drop
# the Future. The helper keeps each until it settles, so a send waiting its
# turn behind another still goes out and is not reported as lost, and
# finished waits for it.
sub try_send_text { my $self = shift; return $self->_keep($self->_try_send_text(@_)) }

async sub _try_send_text {
    my ($self, $text) = @_;
    return 0 if $self->_response_claimed_before_start || !$self->is_connected;

    eval {
        defined($text = PAGI::Utils::_string_value($text))
            or croak 'send_text requires a string or an object that overloads stringification';
        await PAGI::Utils::_ProtocolHelpers::forward_send($self, {
            type => 'websocket.send',
            text => $text,
        });
    };
    # A failed send is not a disconnect. A send after the app's OWN close is
    # already turned away above; a send after the PEER already
    # closed is a tolerated no-op per spec (dropped, not delivered, but does
    # not fail the Future), so neither case reaches here as an error. This
    # eval only catches a genuine send failure, which per the try_* contract
    # still returns false without fabricating a 1006 close or mutating
    # connection state, and is reported to on_error, as PAGI::SSE's try_send*
    # report theirs.
    if (my $err = $@) {
        await $self->_trigger_error($err);
        return 0;
    }
    return 1;
}

sub try_send_bytes { my $self = shift; return $self->_keep($self->_try_send_bytes(@_)) }

async sub _try_send_bytes {
    my ($self, $bytes) = @_;
    return 0 if $self->_response_claimed_before_start || !$self->is_connected;

    eval {
        defined($bytes = PAGI::Utils::_string_value($bytes))
            or croak 'send_bytes requires a string or an object that overloads stringification';
        defined($bytes = PAGI::Utils::_byte_string($bytes))
            or croak 'send_bytes must be encoded bytes: it contains a character above 0xFF; encode text first, or use send_text';
        await PAGI::Utils::_ProtocolHelpers::forward_send($self, {
            type => 'websocket.send',
            bytes => $bytes,
        });
    };
    # A failed send is not a disconnect. A send after the app's OWN close is
    # already turned away above; a send after the PEER already
    # closed is a tolerated no-op per spec (dropped, not delivered, but does
    # not fail the Future), so neither case reaches here as an error. This
    # eval only catches a genuine send failure, which per the try_* contract
    # still returns false without fabricating a 1006 close or mutating
    # connection state, and is reported to on_error, as PAGI::SSE's try_send*
    # report theirs.
    if (my $err = $@) {
        await $self->_trigger_error($err);
        return 0;
    }
    return 1;
}

sub try_send_json { my $self = shift; return $self->_keep($self->_try_send_json(@_)) }

async sub _try_send_json {
    my ($self, $data) = @_;
    return 0 if $self->_response_claimed_before_start || !$self->is_connected;

    my $json = JSON::MaybeXS::encode_json($data);
    eval {
        await PAGI::Utils::_ProtocolHelpers::forward_send($self, {
            type => 'websocket.send',
            text => $json,
        });
    };
    # A failed send is not a disconnect. A send after the app's OWN close is
    # already turned away above; a send after the PEER already
    # closed is a tolerated no-op per spec (dropped, not delivered, but does
    # not fail the Future), so neither case reaches here as an error. This
    # eval only catches a genuine send failure, which per the try_* contract
    # still returns false without fabricating a 1006 close or mutating
    # connection state, and is reported to on_error, as PAGI::SSE's try_send*
    # report theirs.
    if (my $err = $@) {
        await $self->_trigger_error($err);
        return 0;
    }
    return 1;
}

# Receive methods

async sub receive {
    my ($self) = @_;

    return undef if $self->is_closed || $self->_response_claimed_before_start;

    while (1) {
        my $event = await $self->{receive}->();

        if (!defined($event) || $event->{type} eq 'websocket.disconnect' || $event->{type} eq 'http.disconnect') {
            await $self->_note_disconnected;
            return undef;
        }

        # websocket.connect is a handshake event, not application data, so it is
        # filtered out of the message stream here. PAGI's handshake contract: the
        # server sends websocket.connect and waits for the app's reply; the app
        # replies by sending accept()/close(). The app does not need to consume
        # the connect event itself — this filter makes a stray one a no-op rather
        # than surfacing it as a message. See accept() for the contract.
        next if $event->{type} eq 'websocket.connect';

        return $event;
    }
}

async sub receive_text {
    my ($self) = @_;

    while (1) {
        my $event = await $self->receive;
        return undef unless $event;

        # Skip non-receive events and binary frames
        next unless $event->{type} eq 'websocket.receive';
        next unless exists $event->{text};

        return $event->{text};
    }
}

async sub receive_bytes {
    my ($self) = @_;

    while (1) {
        my $event = await $self->receive;
        return undef unless $event;

        # Skip non-receive events and text frames
        next unless $event->{type} eq 'websocket.receive';
        next unless exists $event->{bytes};

        return $event->{bytes};
    }
}

async sub receive_json {
    my ($self) = @_;

    my $text = await $self->receive_text;
    return undef unless defined $text;

    return JSON::MaybeXS::decode_json($text);
}

# Iteration helpers. A callback that dies propagates; on_close runs when the
# connection ends.

async sub each_message {
    my ($self, $callback) = @_;

    while (my $event = await $self->receive) {
        next unless $event->{type} eq 'websocket.receive';
        await $callback->($event);
    }

    return;
}

async sub each_text {
    my ($self, $callback) = @_;

    while (defined(my $text = await $self->receive_text)) {
        await $callback->($text);
    }

    return;
}

async sub each_bytes {
    my ($self, $callback) = @_;

    while (defined(my $bytes = await $self->receive_bytes)) {
        await $callback->($bytes);
    }

    return;
}

# A message that is not JSON goes to the caller's on_invalid_json, else to
# handle_invalid_json. The loop ends once the connection is no longer
# connected: after our Close the peer may still send data (RFC 6455), and
# none of it reaches the callback.
async sub each_json {
    my ($self, $callback, %opts) = @_;
    my $on_invalid = $opts{on_invalid_json};
    while (1) {
        my $text = await $self->receive_text;
        last unless defined $text;
        my $data;
        unless (eval { $data = JSON::MaybeXS::decode_json($text); 1 }) {
            my $error = $@;
            await Future->wrap($on_invalid
                ? $on_invalid->($text, $error)
                : $self->handle_invalid_json($text, $error));
            last unless $self->is_connected;
            next;
        }
        await Future->wrap($callback->($data));
        last unless $self->is_connected;
    }
    return;
}

# A client's invalid JSON is its error, not the server's: close with 1007.
async sub handle_invalid_json {
    my ($self, $text, $error) = @_;
    await $self->close(1007, 'invalid JSON');
    return;
}

# Callback-based event loop (alternative to each_* iteration)
async sub run {
    my ($self) = @_;

    while (1) {
        my $event = await $self->receive;
        last unless $event;

        next unless $event->{type} eq 'websocket.receive';

        my $data = $event->{text} // $event->{bytes};

        for my $cb (@{$self->{_on_message}}) {
            eval {
                my $r = $cb->($data, $event);
                # Await if callback returns a Future
                if (blessed($r) && $r->isa('Future')) {
                    await $r;
                }
            };
            if (my $err = $@) {
                await $self->_trigger_error($err);
                die $err;
            }
        }
    }

    return;
}

# Keepalive support using WebSocket protocol-level ping/pong (RFC 6455)
# Sends websocket.keepalive event to server - loop-agnostic, server handles timers
async sub keepalive {
    my ($self, $interval, $timeout) = @_;
    return $self if $self->is_closed || $self->_response_claimed_before_start || $self->connection_state eq 'closing';

    $interval //= 0;

    my $event = {
        type     => 'websocket.keepalive',
        interval => $interval,
    };
    $event->{timeout} = $timeout if defined $timeout;

    await PAGI::Utils::_ProtocolHelpers::forward_send($self, $event);

    return $self;
}

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::WebSocket - Convenience wrapper for PAGI WebSocket connections

=head1 SYNOPSIS

    use Future::AsyncAwait;
    use PAGI::Compose qw(compose);
    use PAGI::Routing qw(websocket);

    our %online;    # user => PAGI::WebSocket, shared by every connection

    my $app = compose(routes => [
        # A websocket route's handler receives one PAGI::WebSocket.
        websocket('/echo' => async sub {
            my ($ws) = @_;
            await $ws->accept;
            await $ws->each_text(async sub {
                my ($text) = @_;
                await $ws->send_text("Echo: $text");
            });
        }),

        # A JSON protocol with cleanup. on_close is registered before
        # accept, so it runs however the connection ends.
        websocket('/json' => async sub {
            my ($ws) = @_;
            my $user = $ws->query_param('user') // 'anonymous';
            $online{$user} = $ws;
            $ws->on_close(sub {
                my ($code, $reason) = @_;    # the peer's, when it sent a Close
                # Only if a newer connection for this user has not replaced it.
                delete $online{$user} if ($online{$user} // 0) == $ws;
            });

            await $ws->accept;
            await $ws->each_json(async sub {
                my ($data) = @_;
                await $ws->send_json({ type => 'pong' })
                    if $data->{type} eq 'ping';
            });
        }),

        # Callback style, an alternative to the each_* loops.
        websocket('/callbacks' => async sub {
            my ($ws) = @_;
            $ws->on(message => async sub {
                my ($text) = @_;
                await $ws->send_text("Echo: $text");
            });
            $ws->on(error => sub {
                my ($error) = @_;
                warn "WebSocket error: $error";
            });

            await $ws->accept;
            await $ws->run;
        }),
    ]);

    # pagi-server --app app.pl, with $app as the file's last value.

=head1 DESCRIPTION

PAGI::WebSocket wraps the raw PAGI WebSocket protocol to provide a clean,
high-level API inspired by Starlette's WebSocket class. It eliminates
protocol boilerplate and provides:

=over 4

=item * Typed send/receive methods (text, bytes, JSON)

=item * Connection state tracking (is_connected, is_closed, close_code)

=item * Cleanup and error callback registration (on_close, on_error)

=item * Safe send methods for broadcast scenarios (try_send_*)

=item * Message iteration helpers (each_text, each_json)

=item * Callback-based event handling (on, run)

=item * Per-connection storage (via L<PAGI::Stash>)

=back

=head1 CONSTRUCTOR

=head2 new

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

Creates a new WebSocket wrapper. Requires:

=over 4

=item * C<$scope> - PAGI scope hashref with C<< type => 'websocket' >> and the
C<pagi.connection> object that L<PAGI::Spec::Www> 0.6 requires servers to
provide

=item * C<$receive> - Async coderef returning Futures for events

=item * C<$send> - Async coderef for sending events

=back

Dies if scope type is not 'websocket', or if C<pagi.connection> is missing or
lacks a required method (C<PAGI::WebSocket requires pagi.connection
capabilities ...>, naming the server's advertised C<spec_version>). A scope
built by hand, as in tests, supplies one with L<PAGI::Test::ConnectionState>:

    my $scope = {
        type              => 'websocket',
        headers           => [],
        'pagi.connection' => PAGI::Test::ConnectionState->new(websocket => 1),
    };

Each call builds a new object and stores nothing in the scope, so build one
per connection and pass it on (see L</SUBCLASSING>).

An application that constructs the helper itself should
C<await $ws-E<gt>finished> before it returns; see L</finished>. Routes and the
Endpoint classes do this for you.

=head1 INHERITED FROM PAGI::HTTPConnection

A PAGI::WebSocket is a L<PAGI::HTTPConnection>: what can be read from the
scope alone comes from the methods it inherits, documented there. Each parse
(headers, query, cookies) is kept on the object; nothing is written to the
scope.

=over 4

=item * Scope properties: C<scope>, C<connection>, C<client>, C<server>,
C<scheme> (C<ws> unless the scope says otherwise), C<http_version>, C<path>,
C<raw_path>, C<raw_path_info>, C<request_uri>, C<query_string>

=item * Headers: C<headers>, C<header>, C<header_all>

=item * Query parameters: C<query_params>, C<query_param>,
C<raw_query_params>, C<raw_query_param>

=item * Path parameters: C<path_params>, C<path_param> (strict: a name the
route did not capture dies, naming the ones it did; pass C<< strict => 0 >>
for C<undef>), and the subclass hook C<_default_path_param_strict_opt>

=item * Cookies: C<cookies>, C<cookie>

=item * Application state: C<state>, C<has_state>

=back

C<path> dies C<this scope has no path> on a scope without one.

=head1 SCOPE ACCESSORS

=head2 subprotocols

    my $protos = $ws->subprotocols;    # ['chat', 'json']

Returns arrayref of requested subprotocols.

=head2 Per-Connection Shared State

See L<PAGI::Stash> for per-connection shared state, which
L<PAGI::Middleware::Stash> stacked above the handler provides:

    use PAGI::Stash;
    my $stash = PAGI::Stash->new($ws);

=cut

=head1 LIFECYCLE METHODS

=head2 accept

    await $ws->accept;
    await $ws->accept(subprotocol => 'chat');
    await $ws->accept(headers => [['x-custom', 'value']]);
    await $ws->accept(headers => ['x-custom' => 'value']);

Accepts the WebSocket connection. Optionally specify a subprotocol
to use and additional response headers. C<headers> is a flat
C<[name =E<gt> value, ...]> list, C<[[name, value], ...]> pairs as the PAGI
spec writes headers, or a L<PAGI::Headers> object (copied); it is sent as
C<[[name, value], ...]> pairs. Names and values follow L<PAGI::Response/metadata>:
a name is an HTTP token; an object that overloads stringification is sent as
its string, and a value must be bytes; anything else croaks, naming the
header. Any other shape croaks.

B<Handshake contract.> The server sends a C<websocket.connect> event and waits
for the application's reply before completing the handshake; the reply is
C<accept> (this method) or C<close>/C<deny>. The application does B<not> need to
receive the C<websocket.connect> event itself — C<accept> sends the reply
directly, and any C<websocket.connect> in the receive stream is filtered out by
L</receive> rather than surfaced as a message. This matches ASGI, whose
normative requirements bind only the server (the application is never required
to consume C<connect> before accepting); the reference server, RFC 6455, and
other frameworks (e.g. Mojolicious, which auto-upgrades) impose no such app-side
ordering either.

=head2 close

    await $ws->close;
    await $ws->close(1000, 'Normal closure');
    await $ws->close(4000, 'Custom reason');

Requests closing with code 1000 by default. The reason may be an object that
stringifies (L<PAGI::Response/VALUES FROM OTHER CODE>); another non-string
reason croaks before anything changes. Concurrent and repeated calls join
one close-send operation and return when that send settles. They do not await
the peer's Close or terminal cleanup. State is C<closing> until the connection
records its terminal outcome; further data sends are rejected. Cancelling a
close observer does not cancel the server's send.

Before C<accept>, the scope is still an HTTP exchange, so C<close> croaks
C<WebSocket close is only valid after accept; use deny> and sends nothing;
refuse the handshake with L</deny>.

The router and endpoint C<to_app> boundary send a missing close on successful
handler return only for an accepted, still-active socket. Handler exceptions
propagate to the server without publishing a synthetic terminal outcome.

=head2 deny

    use Future::AsyncAwait;
    use PAGI::Response qw(response);

    async sub unavailable {
        my ($ws) = @_;
        await $ws->deny(response('Text', 'Unavailable', status => 503));
        return;
    }

    async sub unavailable_for_request {
        my ($ws) = @_;
        await $ws->deny(sub {
            my ($request) = @_;
            return response('Text', 'Unavailable: ' . $request->path, status => 503);
        });
        return;
    }

Delegates the WebSocket handshake refusal to exactly one Request handler or
instantiated application object with C<to_app>, before C<accept>. Concrete
L<PAGI::Response> values, L<PAGI::Pages> applications, and custom application
objects are accepted directly. A bare coderef receives exactly one
L<PAGI::Request>; its immediate or Future-backed result must be an application
object or native C<($scope, $receive, $send)> coderef. Use
L<PAGI::Utils/as_app_object> to pass a native coderef directly.

The application receives the original scope, receive, and send channels.
The scope type stays unchanged. Applications own their protocol compatibility;
this method neither inspects response contents nor substitutes a response for
application errors. The current public C<pagi.connection> capabilities are
required for every target, including buffered Responses. Missing capabilities
fail before factories, handlers, or C<to_app> execute.

Await the returned Future. Success resolves to this helper and means the
application finished, not that the connection completed. The helper retains
its initial protocol state until normal protocol progress or connection end;
that state does not promise that a response slot is available. A settled
attempt on a live connection with no response start permits sequential retry;
after response start or termination another refusal fails. Application errors
propagate through the returned Future.
Applications must sequence answering operations; overlapping refusal and
acceptance/start calls are unsupported.

Cancelling the returned Future follows the invoked application's cancellation
behavior; the helper does not keep abandoned application work running.
Buffered Responses protect submitted server sends but stop subsequent
emission, and Stream retains its own abort and cleanup behavior. Connection
C<on_end> owns close callbacks, including asynchronous cleanup after application
return.

A successfully delivered HTTP refusal completes the PAGI scope normally:
C<on_complete> runs and C<disconnect_reason> is undefined. Its WebSocket
C<close_code> is nevertheless C<1006>, with an undefined C<close_reason>,
because no peer Close frame was received. This value is local metadata; no
WebSocket Close frame is sent. Use scope completion to distinguish successful
refusal delivery from an interrupted response.

    use PAGI::Response qw(response);
    my $connection = $scope->{'pagi.connection'};
    $connection->on_complete(sub {
        # The HTTP refusal completed successfully.
    });
    $ws->on_close(sub {
        my ($code, $reason, $detail) = @_;
        # After this refusal: 1006, undef, undef.
    });
    await $ws->deny(response('Text', 'Access denied', status => 403));

The sending environment requires WebSocket refusal status 300 or greater.
Request metadata is available, but WebSocket Request body APIs reject access
without consuming protocol events.

See L<PAGI::Tools::Cookbook/Refusing WebSocket and SSE with applications> for
complete synchronous and async handlers, direct Pages applications, custom
application objects, and wrapped native applications, with matching SSE call
sites.

See L<PAGI::Spec::Www/"WebSocket Denial Response">.

=head2 close_or_deny

    await $ws->close_or_deny(1011, 'Internal Server Error');
    await $ws->close_or_deny(4004, 'Not Found',
        response('Text', 'Not Found', status => 404));

Ends the socket however its state allows, for code that cannot know
whether the handshake was accepted -- an error handler, a framework's
dispatch. Before L</accept> it refuses with L</deny>: the given Response,
or a C<403 text/plain> whose body is C<$reason> (C<Forbidden> when there
is none), as ASGI answers a close before accept. After accept it calls
L</close> with C<$code> and C<$reason>. Once the connection is closed --
the client hung up, or the socket was already ended -- it sends nothing and
does not die, so a client that left is not reported as an application
error.

=head1 STATE ACCESSORS

=head2 is_connected, is_closed, connection_state

    if ($ws->is_connected) { ... }
    if ($ws->is_closed) { ... }
    my $state = $ws->connection_state; # connecting, connected, closing, closed

These are the complete protocol phase values. The former C<denying> phase is
retired: invoking L</deny> does not mutate helper state. The initial
C<connecting> value describes WebSocket progress, not availability of the HTTP
response slot; refusal admission also reads the public connection facts.

=head2 close_code, close_reason

    my $code = $ws->close_code;        # 1000, 1001, etc.
    my $reason = $ws->close_reason;    # 'Normal closure'

On a connection-backed scope these read the peer's Close metadata directly
from C<pagi.connection>, including before deferred callback delivery. They
never substitute the application's outgoing Close. A peer Close with no code
is C<1005>/C<undef>; a terminal scope without a peer Close is C<1006>/C<undef>,
including refusal. Peer Close metadata is meaningful as a peer handshake
result only on an accepted socket.
See L</deny> for successful refusal completion metadata.

=head2 disconnect_reason, disconnect_detail

Read the connection's lifecycle token and diagnostic detail, separately from
peer Close text. Both are C<undef> for a clean end. Terminal accessors are
synchronous and do not consume receive events.

=head2 buffered_amount, high_water_mark, low_water_mark

    my $pending = $ws->buffered_amount;   # bytes queued, not yet on the wire
    my $ceiling = $ws->high_water_mark;    # backpressure ceiling (or undef)
    my $floor   = $ws->low_water_mark;     # backpressure floor (or undef)

Outbound flow-control introspection, delegated to the server-provided
C<pagi.transport> handle (see L<PAGI::Spec::Www/"Transport Flow Control">). Use
C<buffered_amount> to conflate, coalesce, shed load, or disconnect a slow client
instead of only blocking on drain; when the server does not provide the handle,
C<buffered_amount> returns C<0> and the watermarks return C<undef>.

=head2 on_high_water, on_drain, is_writable

    $ws->on_high_water(sub { $source->pause });    # backpressure engaged
    $ws->on_drain(sub      { $source->resume });    # backpressure cleared
    last unless $ws->is_writable;                    # below the high mark?

Backpressure controls delegated to the C<pagi.transport> handle. C<on_high_water>
and C<on_drain> register edge-triggered callbacks (the Node/Mojo C<drain> model)
for producers that cannot self-pace with a blocking send; each returns the
object for chaining. C<is_writable> is true when the outbound buffer is below the
high mark. When the server provides no transport handle (or only the read
methods), the callbacks are quiet no-ops and C<is_writable> is true.

=head1 SEND METHODS

Text and bytes may be given as an object that stringifies
(L<PAGI::Response/VALUES FROM OTHER CODE>). C<send_bytes> takes bytes as
L<PAGI::Response/BYTES AND CHARACTERS> defines them: Perl's UTF-8 flag does
not matter, and a character above 0xFF is refused. A value that is neither a string
nor such an object makes C<send_text> and C<send_bytes> fail, and the
C<try_send_*> methods return false without sending and report it to
L</on_error>. C<send_json> encodes
data as JSON and does not stringify.

=head2 send_text, send_bytes, send_json

    await $ws->send_text("Hello!");
    await $ws->send_bytes("\x00\x01\x02");
    await $ws->send_json({ action => 'greet', name => 'Alice' });

Send a message. Dies if the connection is closing or closed; see
L</HANDLERS AND DISCONNECTS>.

B<Several producers, no queue.> Each send goes to the server at once, and a
server implementing PAGI::Spec::Www 0.7 keeps a connection's sends in the
order they were called ("Sends Are Sequential"), so several producers -- a
reply racing a broadcast from another connection, a server tick racing an
echo -- can each call C<send_*> or C<try_send_*> directly, with no queue of
their own. Cancelling a send's Future never cancels the send the server
holds. On a server reporting an earlier C<spec_version>, sends must not
overlap: serialize the producers yourself.

=head2 try_send_text, try_send_bytes, try_send_json

    my $sent = await $ws->try_send_json($data);

B<Best-effort send.> Sends only while the socket is connected and B<never
throws>, returning a boolean. Before C<accept>, while closing and after close
it sends nothing and returns false. Intended for broadcast-style loops --
"send to many, skip the failures" -- where one bad recipient must not abort
the loop or corrupt shared connection state (a failed send leaves
C<is_closed>/C<close_code> untouched).

B<The boolean is a weak signal; do not treat it as a delivery receipt:>

=over 4

=item *

A B<false> return means the send definitely did not happen -- the socket is
not connected (not yet accepted, closing or closed), or the value or the
underlying send raised. The return tells you I<that> it failed; the error
itself goes to L</on_error>, as PAGI::SSE's C<try_send*> report theirs. A
false before C<accept>
is as quiet as any other, so while developing use C<send_*>: a send before
C<accept> fails loudly there.

=item *

A B<true> return does B<not> guarantee delivery. Per the spec, a send to a peer
that has disconnected is a silent no-op, so if the client has vanished but the
server has not yet surfaced the C<websocket.disconnect> event, the send no-ops
and this still returns true. "Sent" means "the send call did not fail," not "the
client received it."

=back

You may make one and drop the returned Future -- the usual shape of a
broadcast loop. The send keeps itself alive until it settles, so it still goes
out even when it must wait behind a send already in flight.

If you need more than best-effort, reach for the right tool instead of inspecting
this return value:

=over 4

=item * B<Why did it fail?> Use C<send_text>/C<send_bytes>/C<send_json>, which
throw the underlying error.

=item * B<Is the peer still there?> Use C<is_connected> and react to the
C<websocket.disconnect> event.

=item * B<Is the connection backpressured?> Use C<is_writable> /
C<buffered_amount> and the watermark / C<on_drain> controls.

=back

=head1 RECEIVE METHODS

=head2 receive

    my $event = await $ws->receive;

Returns raw PAGI event hashref, or undef on disconnect.

=head2 receive_text, receive_bytes

    my $text = await $ws->receive_text;
    my $bytes = await $ws->receive_bytes;

Waits for specific frame type, skipping others. Returns undef on disconnect.

=head2 receive_json

    my $data = await $ws->receive_json;

Receives text frame and decodes as JSON. Dies on invalid JSON: the
primitives raise, and the loop, C<each_json>, owns the policy for a client's
bad JSON.

=head1 ITERATION HELPERS

=head2 each_message, each_text, each_bytes, each_json

    await $ws->each_text(async sub {
        my ($text) = @_;
        await $ws->send_text("Got: $text");
    });

    await $ws->each_json(async sub {
        my ($data) = @_;
        if ($data->{type} eq 'ping') {
            await $ws->send_json({ type => 'pong' });
        }
    });

Loops until disconnect, calling callback for each message.
Exceptions in callback propagate to caller.

=head2 each_json and invalid JSON

    await $ws->each_json(\&on_message);    # bad JSON: close 1007, return

    await $ws->each_json(\&on_message, on_invalid_json => async sub {
        my ($text, $error) = @_;
        await $ws->send_json({ error => 'expected JSON' });    # and keep reading
    });

A message that is not JSON is the client's error, not the server's. Without
C<on_invalid_json>, C<each_json> calls C<handle_invalid_json>, which closes
the socket with 1007 C<invalid JSON>; the loop then ends and C<each_json>
returns normally.

C<on_invalid_json>, sync or async, receives C<($text, $error)> and replaces
C<handle_invalid_json> for that call. To keep the default and add to it, call
C<handle_invalid_json> inside it:

    await $ws->each_json(\&on_message, on_invalid_json => async sub {
        my ($text, $error) = @_;
        $metrics->count('invalid_json');
        await $ws->handle_invalid_json($text, $error);    # still close 1007
    });

A subclass overrides C<handle_invalid_json> instead.

The loop ends as soon as the socket is no longer connected, checked after the
invalid-JSON handler and after each callback: after our Close the peer may
still send data (RFC 6455), and none of it reaches the callback. A handler or
callback that dies propagates as an application error, which the client sees
as 1011.

C<$error> is the JSON backend's wording (Cpanel::JSON::XS, JSON::XS or
JSON::PP): use it for diagnostics only; do not match on it or send it to the
client. C<$text> can be as large as the largest message the server accepts,
so do not log it raw. Under the default nothing is logged: watch for it in
C<on_close>, which sees 1007, or with C<on_invalid_json>.

C<receive_json> still dies on invalid JSON: primitives raise, loops own the
policy.

=head2 handle_invalid_json

    package My::WebSocket;
    use parent 'PAGI::WebSocket';

    async sub handle_invalid_json {
        my ($self, $text, $error) = @_;
        await $self->send_json({ error => 'expected JSON' });
    }

What C<each_json> does with a message that is not JSON when the call passes no
C<on_invalid_json>. The default closes the socket with 1007 C<invalid JSON>.

=head1 EVENT CALLBACKS

=head2 on_close

    # Simple sync callback
    $ws->on_close(sub {
        my ($code, $reason) = @_;
        print "Disconnected: $code\n";
    });

    # Async callback for cleanup that needs await
    $ws->on_close(async sub {
        my ($code, $reason) = @_;
        await cleanup_resources();
    });

Registers cleanup to run once, however the connection ends. Register it
when the thing it cleans up exists, before or after C<accept>: if the
connection has already ended (a client can leave during the handshake, and
C<accept> still returns), the callback runs at once, after any callbacks
still running. Arguments are C<($peer_code, $peer_reason, $disconnect_detail)>
-- a callback with a signature must accept all three; lifecycle reason is
available through C<disconnect_reason>. A local C<close> request alone does
not start cleanup.

Callbacks can be regular subs or async subs — async results are
automatically awaited. Multiple callbacks run in registration order. A
callback that dies does not stop the others; once all have run, the first
failure is reported through L</finished>. A callback that runs after
C<finished> has already resolved has nowhere to report, so its failure is
warned.

Returns C<$self> for chaining.

B<Circular reference note:> If your callback captures C<$ws> in a
closure, use C<Scalar::Util::weaken> to avoid a memory leak:

    use Scalar::Util qw(weaken);
    my $weak_ws = $ws;
    weaken($weak_ws);
    $ws->on_close(sub { $weak_ws->... if $weak_ws });

The connection retains the helper until terminal notification. The helper's
own L<PAGI::FutureOwner> then holds the worker that runs all hooks in order;
it survives handler return and cancellation of cleanup observers, and
releases hooks and helper references when cleanup finishes. There is no
background receive watcher.

=head2 connection

    my $conn = $ws->connection;

Returns the server-supplied object under C<pagi.connection>. Its interface is
defined by the PAGI specification (L<PAGI::Spec::Www>); callers use those
public methods rather than requiring a particular server's connection class.

For cleanup, use L</on_close>, which runs whenever you register it. The
connection object is there for what the helper does not wrap: the spec's
C<end_future>, C<abort>, and the rest of its interface.

=head2 finished

    await $ws->finished;

Resolves to C<$ws> once the scope has ended and everything the helper started
-- its C<on_close> callbacks, a C<close>, best-effort sends -- has settled. It
fails with the first C<on_close> failure. Routes and
L<PAGI::Endpoint::WebSocket> await it for you, so their call ends only after the
cleanup has finished, and a shutting-down server waits for it. An application
that constructs the helper itself should C<await $ws-E<gt>finished> before it
returns; otherwise its cleanup is not part of its call, and an C<on_close>
failure is reported nowhere. For a helper never accepted, C<finished> does
not wait for the scope to end, since that end waits for the application;
its C<on_close> callbacks then run after the application returns.

If the handler dies, C<finished> is not reached: the call fails, and the
server then ends the scope as C<server_error>. The C<on_close> callbacks still
run, but outside the call, so a server shutting down does not wait for them.

=head2 on_error

    $ws->on_error(sub {
        my ($error) = @_;
        warn "WebSocket error: $error";
    });

    # Async callback — return value is awaited automatically
    $ws->on_error(async sub {
        my ($error) = @_;
        await log_error_async($error);
    });

Registers error callback. Called when exceptions occur in message
handlers during C<run()>, and with the error when a C<try_send_*> fails. Callbacks can be regular subs or async
subs — async results are automatically awaited. Multiple callbacks
run in registration order. Exceptions in callbacks are caught and
warned but do not prevent other callbacks.

After the callbacks run, C<run()> re-raises the error, so the server reports
it as an application error. With no error handlers registered, nothing else
is printed.

A C<try_send_*> failure is not re-raised: after the callbacks run, the method
returns false.

Returns C<$self> for chaining.

=head2 on_message

    $ws->on_message(sub {
        my ($data, $event) = @_;
        # $data is text or bytes, $event is the raw PAGI event hashref
        # Check $event->{text} vs $event->{bytes} to distinguish frame type
    });

Registers a message callback for use with C<run()>. Multiple callbacks
can be registered and all will be called for each message.

Returns C<$self> for chaining.

=head2 on

    # Generic Socket.IO-style event registration
    $ws->on(message => sub { my ($data, $event) = @_; ... });
    $ws->on(close   => sub { my ($code, $reason) = @_; ... });
    $ws->on(error   => sub { my ($error) = @_; ... });

    # Methods return $self, so calls can be chained
    $ws->on(message => sub { ... })
       ->on(close   => sub { ... })
       ->on(error   => sub { ... });

Generic event registration. Dispatches to C<on_message>, C<on_close>,
or C<on_error> based on the event name. Dies for unknown event types.

Returns C<$self> for chaining.

=head2 run

    # Register callbacks first
    $ws->on(message => sub { my ($data) = @_; ... });
    $ws->on(close => sub { ... });

    # Enter event loop
    await $ws->run;

Callback-based event loop (alternative to C<each_*> iteration).
Runs until disconnect, dispatching messages to registered callbacks.
Errors in callbacks are passed to error handlers and, on connection-backed
scopes, propagate so the server can determine the terminal outcome.

=head1 HANDLERS AND DISCONNECTS

A client can leave at any C<await>, and nothing interrupts your handler when
it does. Choose the send by what a lost message means:

=over 4

=item * B<Strict sends for messages that must arrive.> C<send_text>,
C<send_bytes> and C<send_json> die once the connection is closing or closed,
and the failure is reported like any other. They also die after a refused
handshake: that is a programming error, not a disconnect.

=item * B<C<try_send_*> for setup steps and broadcasts.> They return false
instead of dying unless the socket is connected, so a handler can stop
quietly when its client has gone:

    await $ws->accept;
    return unless await $ws->try_send_json({ type => 'welcome' });

Before C<accept> they return false just as quietly, so while developing use
the strict sends. A broadcast to many sockets uses C<try_send_*> for the same
reason as setup: a departed client cannot end the loop. A true return is not
a delivery receipt (see L</"try_send_text, try_send_bytes, try_send_json">),
so cleanup still belongs in C<on_close>.

=item * B<C<accept> and C<keepalive> are already safe.> Once the connection
is closing or closed, or a refusal has started, they return without sending.

=item * B<Cleanup belongs in C<on_close>.> Register it once the thing it
cleans up exists, before or after C<accept>; it runs however the connection
ends, and at once if the client has already gone, so nothing is left behind.

=back

=head1 KEEPALIVE

WebSocket keepalive uses protocol-level ping/pong frames (RFC 6455). The server
sends ping frames automatically; clients respond with pong frames without any
application code needed.

=head2 keepalive

    await $ws->keepalive(30);       # Ping every 30 seconds
    await $ws->keepalive(30, 20);   # Ping every 30s, expect pong within 20s
    await $ws->keepalive(0);        # Disable keepalive

Enables or disables WebSocket protocol-level keepalive by sending a
C<websocket.keepalive> event to the server. The server handles the timer
and ping/pong frames.

Arguments:

=over 4

=item C<$interval> - Seconds between ping frames. Use C<0> to disable.

=item C<$timeout> - (Optional) Seconds to wait for pong response. If no pong is
received within this time, the connection is closed with code 1006 and the
application receives a disconnect event with C<reason =E<gt> 'keepalive timeout'>.

=back

Common intervals:

=over 4

=item C<25> - Safe for most proxies (30s timeout common)

=item C<55> - Safe for aggressive proxies (60s timeout)

=back

Returns C<$self> for chaining.

=head1 COMPLETE EXAMPLE

    use PAGI::WebSocket;
    use Future::AsyncAwait;

    my %connections;

    async sub chat_app {
        my ($scope, $receive, $send) = @_;

        my $ws = PAGI::WebSocket->new($scope, $receive, $send);
        my $user_id = generate_id();
        $connections{$user_id} = $ws;

        $ws->on_close(async sub {
            delete $connections{$user_id};
            await broadcast({ type => 'leave', user => $user_id });
        });

        await $ws->accept;
        return if $ws->is_closed;
        await broadcast({ type => 'join', user => $user_id });

        await $ws->each_json(async sub {
            my ($data) = @_;
            $data->{from} = $user_id;
            await broadcast($data);
        });

        await $ws->finished;    # its on_close cleanup is part of this call
    }

    async sub broadcast {
        my ($data) = @_;
        for my $ws (values %connections) {
            await $ws->try_send_json($data);
        }
    }

=head1 SUBCLASSING

A framework may subclass PAGI::WebSocket (Thunderhorse does). The contract:

=over 4

=item * B<State.> The object holds C<scope>, C<receive> and C<send>, and its
private connection state, every field of which starts with C<_> (C<_state>
and the C<_close_*> fields and the callbacks among them). A subclass adds fields under any other name.

=item * B<One object per scope.> Build it once the scope is final, after
the route match and inside the innermost middleware, from the channels the
handler receives, and never replace its C<scope>, C<receive> or C<send>: its
state machine (accept, send and receive, close, disconnect) assumes the
same channels for its whole life. C<new> builds a new object on every call
and stores nothing in the scope, so a second C<new> does not find the first:
pass the one object on. Successive route matches over one scope reuse the
object, reading their path parameters live from the scope, written there in
place (see L<PAGI::Request/SUBCLASSING>); a middleware's copy of the scope is
a new scope, and gets a new object. Nothing rebinds an object to another
scope. State a framework gathers earlier in a dispatch belongs on its own
context or in the scope, not on this object.

=item * B<The pattern.> Starlette builds one C<WebSocket(scope, receive,
send)> per connection after routing; PAGI-FastAPI builds
C<< PAGI::WebSocket->new($scope, $receive, $send) >> per connection and hands it to
the handler.

=back

=head1 SEE ALSO

L<PAGI::Request> - Similar convenience wrapper for HTTP requests

L<PAGI::Server> - PAGI protocol server

=head1 AUTHOR

PAGI Contributors

=cut
