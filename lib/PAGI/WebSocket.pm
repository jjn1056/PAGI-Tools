package PAGI::WebSocket;
use strict;
use warnings;
use Carp qw(croak);
use PAGI::Utils::Scope ();
use Encode qw(decode FB_CROAK FB_DEFAULT LEAVE_SRC);
use Hash::MultiValue;
use Future::AsyncAwait;
use Future;
use JSON::MaybeXS ();
use PAGI::Headers ();
use PAGI::Common ();
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
    PAGI::Common::require_connection($scope, 'PAGI::WebSocket');

    # Return existing WebSocket object if one was already created for this scope
    # This ensures consistent state (is_connected, is_closed, callbacks) if
    # multiple code paths create WebSocket objects from the same scope.
    return $scope->{'pagi.websocket'} if $scope->{'pagi.websocket'};

    my $self = bless {
        scope   => $scope,
        receive => $receive,
        send    => $send,
        _state  => 'connecting',  # connecting -> connected -> closed
        _close_code   => undef,
        _close_reason => undef,
        _on_close     => [],
        _on_error     => [],
        _on_message   => [],
    }, $class;

    # Cache in scope for reuse (weakened to avoid circular reference leak)
    $scope->{'pagi.websocket'} = $self;
    Scalar::Util::weaken($scope->{'pagi.websocket'});

    $self->{_cleanup_future} = Future->new;
    # The connection owns this helper until end; the retained worker then
    # owns asynchronous cleanup until all registered hooks have settled.
    $scope->{'pagi.connection'}->on_end(sub {
        $self->_refresh_connection;
        # Nobody awaits cleanup here, so keep its Future until it settles
        # rather than dropping it while a hook is still suspended.
        $self->_run_close_callbacks->retain;
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

# Scope property accessors
sub scope        { shift->{scope} }
sub path         { shift->{scope}{path} }
sub raw_path      { PAGI::Utils::Scope::raw_path(shift->{scope}) }
sub request_uri   { PAGI::Utils::Scope::request_uri(shift->{scope}) }
sub raw_path_info { PAGI::Utils::Scope::raw_path_info(shift->{scope}) }
sub query_string { shift->{scope}{query_string} // '' }
sub scheme       { shift->{scope}{scheme} // 'ws' }
sub http_version { shift->{scope}{http_version} // '1.1' }
sub subprotocols { shift->{scope}{subprotocols} // [] }
sub client       { shift->{scope}{client} }
sub server       { shift->{scope}{server} }


# Application state (injected by PAGI::Lifespan, read-only)
sub has_state {
    my $self = shift;
    return 0 unless exists $self->{scope}{state};
    croak 'PAGI::WebSocket state must be a hashref'
        unless ref($self->{scope}{state}) eq 'HASH';
    return 1;
}

sub state {
    my $self = shift;
    require PAGI::State;
    return PAGI::State->new($self);
}

# Path parameter accessors - captured from URL path by router
# Stored in scope->{path_params} for router-agnostic access
sub path_params {
    my ($self) = @_;
    return $self->{scope}{path_params} // {};
}

sub path_param {
    my ($self, $name) = @_;
    my $params = $self->{scope}{path_params} // {};
    return $params->{$name};
}

# Internal: URL decode a string (handles + as space)
sub _url_decode {
    my ($str) = @_;
    return '' unless defined $str;
    $str =~ s/\+/ /g;
    $str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    return $str;
}

# Internal: Decode UTF-8 with replacement or croak in strict mode
sub _decode_utf8 {
    my ($str, $strict) = @_;
    return '' unless defined $str;
    my $flag = $strict ? FB_CROAK : FB_DEFAULT;
    $flag |= LEAVE_SRC;
    return decode('UTF-8', $str, $flag);
}

# Query params as Hash::MultiValue (cached in scope)
# Options: strict => 1 (croak on invalid UTF-8), raw => 1 (skip UTF-8 decoding)
sub query_params {
    my ($self, %opts) = @_;
    my $strict = delete $opts{strict} // 0;
    my $raw    = delete $opts{raw}    // 0;
    croak("Unknown options to query_params: " . join(', ', keys %opts)) if %opts;

    my $cache_key = $raw ? 'pagi.websocket.query.raw' : ($strict ? 'pagi.websocket.query.strict' : 'pagi.websocket.query');
    return $self->{scope}{$cache_key} if $self->{scope}{$cache_key};

    my $qs = $self->query_string;
    my @pairs;

    for my $part (split /[&;]/, $qs) {
        next unless length $part;
        my ($key, $val) = split /=/, $part, 2;
        $key //= '';
        $val //= '';

        # URL decode (handles + as space)
        my $key_decoded = _url_decode($key);
        my $val_decoded = _url_decode($val);

        # UTF-8 decode unless raw mode
        my $key_final = $raw ? $key_decoded : _decode_utf8($key_decoded, $strict);
        my $val_final = $raw ? $val_decoded : _decode_utf8($val_decoded, $strict);

        push @pairs, $key_final, $val_final;
    }

    $self->{scope}{$cache_key} = Hash::MultiValue->new(@pairs);
    return $self->{scope}{$cache_key};
}

# Raw query params (no UTF-8 decoding)
sub raw_query_params {
    my $self = shift;
    return $self->query_params(raw => 1);
}

# Shortcut for single query param
sub query {
    my ($self, $name, %opts) = @_;
    return $self->query_params(%opts)->get($name);
}

# Raw single query param
sub raw_query {
    my ($self, $name) = @_;
    return $self->query($name, raw => 1);
}

# Single header lookup (case-insensitive, returns last value)
sub header {
    my ($self, $name) = @_;
    return $self->headers->get($name);
}

# All headers as PAGI::Headers (cached in scope)
sub headers {
    my ($self) = @_;
    return $self->{scope}{'pagi.request.headers'}
        //= PAGI::Headers->new($self->{scope}{headers} // []);
}

# All values for a header
sub header_all {
    my ($self, $name) = @_;
    return $self->headers->get_all($name);
}

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
    croak 'Cannot register on_close after cleanup begins' if $self->{_close_callbacks_ran};
    push @{$self->{_on_close}}, $callback;
    return $self;
}

# Internal: run all on_close callbacks exactly once
sub _run_close_callbacks {
    my ($self) = @_;
    my $completion = $self->{_cleanup_future};
    return $completion->without_cancel if $self->{_close_callbacks_ran};
    $self->{_close_callbacks_ran} = 1;
    my $worker = $self->_close_callbacks_worker;
    $worker->on_ready(sub {
        my ($ready) = @_;
        $ready->is_failed ? $completion->fail($ready->failure) : $completion->done;
    });
    $worker->retain;
    return $completion->without_cancel;
}

async sub _close_callbacks_worker {
    my ($self) = @_;
    for my $cb (@{$self->{_on_close}}) {
        eval {
            my $result = $cb->($self->close_code, $self->close_reason, $self->disconnect_detail);
            await $result if blessed($result) && $result->isa('Future');
        };
        warn "PAGI::WebSocket on_close callback error: $@" if $@;
    }
    $self->{_on_close} = [];
    $self->{_on_error} = [];
    $self->{_on_message} = [];
    return;
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
    $event->{headers} = $opts{headers} if exists $opts{headers};

    await PAGI::Common::send_in_order($self, $event);
    $self->_set_state('connected') unless $self->is_closed;

    return $self;
}

# Close the WebSocket connection
sub close {
    my ($self, @args) = @_;
    return Future->done($self) if $self->_response_claimed_before_start;
    return $self->{_close_send}->without_cancel->then(sub { Future->done($self) })->retain
        if $self->{_close_send};
    return Future->done if $self->is_closed;
    # Before accept the scope is an HTTP exchange: refusing it is deny's job.
    croak 'WebSocket close is only valid after accept; use deny'
        if $self->{_state} eq 'connecting';
    croak "WebSocket close requires an active accepted/started connection"
        unless $self->is_connected;
    $self->{_state} = 'closing';
    my $settled = $self->{_close_send} = Future->new;
    my $send;
    my $ok = eval {
        my ($code, $reason) = @args;
        $send = Future->wrap(PAGI::Common::send_in_order($self, {type => 'websocket.close', code => $code // 1000, reason => $reason // ''}));
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
    return $settled->without_cancel->then(sub { Future->done($self) })->retain;
}

# Delegate the handshake refusal to a public PAGI application. Valid only
# before accept.
async sub deny {
    my ($self, @targets) = @_;
    my $app = PAGI::Common::prepare_refusal(
        $self->{scope}, 'WebSocket deny', @targets,
    );
    await PAGI::Utils::invoke_app(
        $app, $self->{scope}, $self->{receive}, $self->{send},
    );
    return $self;
}

# Send text message
async sub send_text {
    my ($self, $text) = @_;

    croak "Cannot send on closed WebSocket" if $self->_response_claimed_before_start || $self->is_closed || $self->connection_state eq 'closing';

    await PAGI::Common::send_in_order($self, {
        type => 'websocket.send',
        text => $text,
    });

    return $self;
}

# Send binary message
async sub send_bytes {
    my ($self, $bytes) = @_;

    croak "Cannot send on closed WebSocket" if $self->_response_claimed_before_start || $self->is_closed || $self->connection_state eq 'closing';

    await PAGI::Common::send_in_order($self, {
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

    await PAGI::Common::send_in_order($self, {
        type => 'websocket.send',
        text => $json,
    });

    return $self;
}

# Safe send methods - return bool instead of throwing

# Best-effort sends never throw, so broadcast loops may make one and drop
# the Future. Each keeps itself alive until it settles, so a send waiting
# its turn behind another still goes out and is not reported as lost.
sub try_send_text { my $self = shift; return $self->_try_send_text(@_)->retain }

async sub _try_send_text {
    my ($self, $text) = @_;
    return 0 if $self->_response_claimed_before_start || $self->is_closed || $self->connection_state eq 'closing';

    eval {
        await PAGI::Common::send_in_order($self, {
            type => 'websocket.send',
            text => $text,
        });
    };
    # A failed send is not a disconnect. A send after the app's OWN close is
    # already turned away above via is_closed; a send after the PEER already
    # closed is a tolerated no-op per spec (dropped, not delivered, but does
    # not fail the Future), so neither case reaches here as an error. This
    # eval only catches a genuine send failure, which per the try_* contract
    # still returns false without fabricating a 1006 close or mutating
    # connection state.
    return 0 if $@;
    return 1;
}

sub try_send_bytes { my $self = shift; return $self->_try_send_bytes(@_)->retain }

async sub _try_send_bytes {
    my ($self, $bytes) = @_;
    return 0 if $self->_response_claimed_before_start || $self->is_closed || $self->connection_state eq 'closing';

    eval {
        await PAGI::Common::send_in_order($self, {
            type => 'websocket.send',
            bytes => $bytes,
        });
    };
    # A failed send is not a disconnect. A send after the app's OWN close is
    # already turned away above via is_closed; a send after the PEER already
    # closed is a tolerated no-op per spec (dropped, not delivered, but does
    # not fail the Future), so neither case reaches here as an error. This
    # eval only catches a genuine send failure, which per the try_* contract
    # still returns false without fabricating a 1006 close or mutating
    # connection state.
    return 0 if $@;
    return 1;
}

sub try_send_json { my $self = shift; return $self->_try_send_json(@_)->retain }

async sub _try_send_json {
    my ($self, $data) = @_;
    return 0 if $self->_response_claimed_before_start || $self->is_closed || $self->connection_state eq 'closing';

    my $json = JSON::MaybeXS::encode_json($data);
    eval {
        await PAGI::Common::send_in_order($self, {
            type => 'websocket.send',
            text => $json,
        });
    };
    # A failed send is not a disconnect. A send after the app's OWN close is
    # already turned away above via is_closed; a send after the PEER already
    # closed is a tolerated no-op per spec (dropped, not delivered, but does
    # not fail the Future), so neither case reaches here as an error. This
    # eval only catches a genuine send failure, which per the try_* contract
    # still returns false without fabricating a 1006 close or mutating
    # connection state.
    return 0 if $@;
    return 1;
}

# Silent send methods - no-op when closed

async sub send_text_if_connected {
    my ($self, $text) = @_;
    return unless $self->is_connected;
    await $self->try_send_text($text);
    return;
}

async sub send_bytes_if_connected {
    my ($self, $bytes) = @_;
    return unless $self->is_connected;
    await $self->try_send_bytes($bytes);
    return;
}

async sub send_json_if_connected {
    my ($self, $data) = @_;
    return unless $self->is_connected;
    await $self->try_send_json($data);
    return;
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

    while (my $text = await $self->receive_text) {
        await $callback->($text);
    }

    return;
}

async sub each_bytes {
    my ($self, $callback) = @_;

    while (my $bytes = await $self->receive_bytes) {
        await $callback->($bytes);
    }

    return;
}

async sub each_json {
    my ($self, $callback) = @_;

    while (1) {
        my $text = await $self->receive_text;
        last unless defined $text;

        my $data = JSON::MaybeXS::decode_json($text);
        await $callback->($data);
    }

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

    await PAGI::Common::send_in_order($self, $event);

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
            my $user = $ws->query('user') // 'anonymous';
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

=item * Safe send methods for broadcast scenarios (try_send_*, send_*_if_connected)

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

B<Singleton pattern:> The WebSocket object is cached in C<< $scope->{'pagi.websocket'} >>.
If you call C<new()> multiple times with the same scope, you get the same
WebSocket object back. This ensures consistent state (is_connected, is_closed,
callbacks) across multiple code paths that may create WebSocket objects from
the same scope.

=head1 SCOPE ACCESSORS

=head2 scope, path, raw_path, query_string, scheme, http_version

    my $path = $ws->path;              # /chat/room1
    my $qs = $ws->query_string;        # token=abc
    my $scheme = $ws->scheme;          # ws or wss

Standard PAGI scope properties with sensible defaults.

C<raw_path> is the full path the client requested, percent-encoded as sent.
Mounts leave it unchanged, so inside a mount it still starts with the mount
prefix (see L<PAGI::Spec::Www/Paths, Mounts and Root Paths>). Without one in
the scope it is C<root_path> followed by C<path>, percent-encoded. Never use
it for authorization: different encodings reach the same C<path>.

=head2 request_uri

    my $here = $ws->request_uri;   # /app/admin/users?x=1

The path and query the client requested: C<raw_path>, then C<?> and
C<query_string> when there is one, with any byte a URI cannot hold
percent-encoded and a leading C<//> reduced to C</>. It is the URL to
redirect back to, at any mount depth and behind a server root path.

=head2 raw_path_info

    my $rest = $ws->raw_path_info;  # /a%2Fb inside mount('/files')

The part of C<raw_path> below C<root_path>, still encoded, for code that must
tell an encoded C</> from a separator. Returns C<undef> when it cannot be
found: an encoded C</> straddles the mount boundary, or C<path> was rewritten.

=head2 subprotocols

    my $protos = $ws->subprotocols;    # ['chat', 'json']

Returns arrayref of requested subprotocols.

=head2 client, server

    my $client = $ws->client;          # ['192.168.1.1', 54321]

Client and server address info.

=head2 header, headers, header_all

    my $origin = $ws->header('origin');
    my $all_cookies = $ws->header_all('cookie');
    my $headers = $ws->headers;        # PAGI::Headers

Case-insensitive header access through L<PAGI::Headers>.

=head2 Per-Connection Shared State

See L<PAGI::Stash> for per-connection shared state:

    use PAGI::Stash;
    my $stash = PAGI::Stash->new($ws);

=cut

=head2 state

    my $state = $websocket->state
        or die 'application requires lifespan state';
    my $db = $state->get('db');

Returns C<PAGI::State|undef> for application state injected by
L<PAGI::Lifespan>. Absent state returns C<undef>; present state must be a
hashref or this method croaks. The facade is read-oriented and catches
missing top-level keys through C<get>.

Repeated calls have equivalent behavior over the same backing state, but do
not promise facade object identity. C<< $state->data >> is the explicit escape
hatch when an integration genuinely requires the raw hashref.

Application state is distinct from L<PAGI::Stash>, which holds mutable
per-connection data, and from C<connection_state>, which reports this
WebSocket's protocol lifecycle.

=head2 has_state

    if ($websocket->has_state) {
        ...
    }

Returns true when lifespan application state is present and a hashref. Returns
false only when it is absent; malformed present state croaks.

=head2 path_param

    my $id = $ws->path_param('id');

Returns a path parameter by name. Path parameters are captured from the URL
path by a router and stored in C<< $scope->{path_params} >>.

    # Route: /chat/:room
    my $room = $ws->path_param('room');

=head2 path_params

    my $params = $ws->path_params;  # { room => 'general', id => '42' }

Returns hashref of all path parameters from scope.

=head2 query_params

    my $params = $ws->query_params;  # Hash::MultiValue
    my $params = $ws->query_params(strict => 1);  # Die on invalid UTF-8
    my $params = $ws->query_params(raw => 1);     # Skip UTF-8 decoding

Get query parameters as L<Hash::MultiValue>.

B<Options:>

=over 4

=item * C<strict> - If true, die on invalid UTF-8 sequences. Default: false
(invalid bytes replaced with U+FFFD).

=item * C<raw> - If true, skip UTF-8 decoding entirely and return raw bytes.
Default: false.

=back

=head2 query

    my $value = $ws->query('user');
    my $value = $ws->query('page', strict => 1);
    my $value = $ws->query('id', raw => 1);

Shortcut for C<< $ws->query_params(%opts)->get($name) >>. Accepts the same
C<strict> and C<raw> options as C<query_params>.

=head2 raw_query_params

    my $params = $ws->raw_query_params;

Returns query params without UTF-8 decoding. Equivalent to
C<< $ws->query_params(raw => 1) >>.

=head2 raw_query

    my $value = $ws->raw_query('user');

Returns a single query param without UTF-8 decoding. Equivalent to
C<< $ws->query($name, raw => 1) >>.

=head1 LIFECYCLE METHODS

=head2 accept

    await $ws->accept;
    await $ws->accept(subprotocol => 'chat');
    await $ws->accept(headers => [['x-custom', 'value']]);

Accepts the WebSocket connection. Optionally specify a subprotocol
to use and additional response headers.

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

Requests closing with code 1000 by default. Concurrent and repeated calls join
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

=head2 send_text, send_bytes, send_json

    await $ws->send_text("Hello!");
    await $ws->send_bytes("\x00\x01\x02");
    await $ws->send_json({ action => 'greet', name => 'Alice' });

Send a message. Dies if connection is closed.

B<Sends go out one at a time.> PAGI::Spec::Www requires that an application
not issue a send before the previous one has resolved. This object does that
for you: a send made while another is still in flight waits for it, whatever
its outcome, so several producers -- a reply racing a broadcast from another
connection, a server tick racing an echo -- can each call C<send_*> or
C<try_send_*> directly, with no queue of their own. A send whose caller
cancels it before it goes out is skipped; one already handed to the server is
never cancelled. Code that calls the raw C<$send> itself still owns the rule.

=head2 try_send_text, try_send_bytes, try_send_json

    my $sent = await $ws->try_send_json($data);

B<Best-effort send.> Attempts the send and B<never throws>, returning a boolean.
Intended for broadcast-style loops -- "send to many, skip the failures" -- where
one bad recipient must not abort the loop or corrupt shared connection state (a
failed send leaves C<is_closed>/C<close_code> untouched).

B<The boolean is a weak signal; do not treat it as a delivery receipt:>

=over 4

=item *

A B<false> return means the send definitely did not happen -- the socket is
already known-closed, or the underlying send raised. It tells you I<that> it
failed, not I<why>.

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

=item * B<Is the peer still there?> Use C<is_connected> (or the
C<send_*_if_connected> variants) and react to the C<websocket.disconnect> event.

=item * B<Is the connection backpressured?> Use C<is_writable> /
C<buffered_amount> and the watermark / C<on_drain> controls.

=back

=head2 send_text_if_connected, send_bytes_if_connected, send_json_if_connected

    await $ws->send_json_if_connected($data);

Silent no-op if connection is closed. Useful for fire-and-forget.

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

Receives text frame and decodes as JSON. Dies on invalid JSON.

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

Registers cleanup for the connection's terminal C<on_end> notification.
Arguments are C<($peer_code, $peer_reason, $disconnect_detail)> -- a callback
with a signature must accept all three; lifecycle
reason is available through C<disconnect_reason>. Register before awaited I/O:
registration after cleanup has begun (including constructor-time terminal
notification) croaks. A local C<close> request alone does not start cleanup.
Callbacks can be regular subs or async subs — async results are
automatically awaited. Multiple callbacks run in registration order.
Exceptions are caught and warned but don't prevent other callbacks.

Returns C<$self> for chaining.

B<Circular reference note:> If your callback captures C<$ws> in a
closure, use C<Scalar::Util::weaken> to avoid a memory leak:

    use Scalar::Util qw(weaken);
    my $weak_ws = $ws;
    weaken($weak_ws);
    $ws->on_close(sub { $weak_ws->... if $weak_ws });

The connection retains the helper until terminal notification. One retained
worker runs all hooks in order, survives handler return and cancellation of
cleanup observers, and releases hooks and helper references when cleanup
finishes. There is no background receive watcher.

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
handlers during C<run()>. Callbacks can be regular subs or async
subs — async results are automatically awaited. Multiple callbacks
run in registration order. Exceptions in callbacks are caught and
warned but do not prevent other callbacks.

After the callbacks run, C<run()> re-raises the error, so the server reports
it as an application error. With no error handlers registered, nothing else
is printed.

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
    }

    async sub broadcast {
        my ($data) = @_;
        for my $ws (values %connections) {
            await $ws->try_send_json($data);
        }
    }

=head1 SEE ALSO

L<PAGI::Request> - Similar convenience wrapper for HTTP requests

L<PAGI::Server> - PAGI protocol server

=head1 AUTHOR

PAGI Contributors

=cut
