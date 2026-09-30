package PAGI::SSE;
use strict;
use warnings;
use Carp qw(croak);
use Hash::MultiValue;
use Future::AsyncAwait;
use Future;
use JSON::MaybeXS ();
use PAGI::Headers ();
use PAGI::Common ();
use Scalar::Util qw(blessed);
use Encode qw(decode FB_CROAK FB_DEFAULT LEAVE_SRC);


sub new {
    my ($class, $scope, $receive, $send) = @_;

    croak "PAGI::SSE requires scope hashref"
        unless $scope && ref($scope) eq 'HASH';
    croak "PAGI::SSE requires receive coderef"
        unless $receive && ref($receive) eq 'CODE';
    croak "PAGI::SSE requires send coderef"
        unless $send && ref($send) eq 'CODE';
    croak "PAGI::SSE requires scope type 'sse', got '$scope->{type}'"
        unless ($scope->{type} // '') eq 'sse';
    # PAGI::Spec::Www 0.6: servers provide pagi.connection on every scope.
    PAGI::Common::require_connection($scope, 'PAGI::SSE');

    # Return existing SSE object if one was already created for this scope
    # This ensures consistent state (is_started, is_closed, callbacks) if
    # multiple code paths create SSE objects from the same scope.
    return $scope->{'pagi.sse'} if $scope->{'pagi.sse'};

    my $self = bless {
        scope             => $scope,
        receive           => $receive,
        send              => $send,
        _state            => 'pending',  # pending -> started -> closed
        _on_close         => [],
        _on_error         => [],
        _disconnect_reason => undef,     # Set when disconnect received
    }, $class;

    # Cache in scope for reuse (weakened to avoid circular reference leak)
    $scope->{'pagi.sse'} = $self;
    Scalar::Util::weaken($scope->{'pagi.sse'});

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
    unless ($connection->is_connected) {
        $self->{_state} = 'closed';
        delete $self->{_pending_keepalive};
    }
    return;
}

# An initial helper cannot claim a response slot already used by an application.
# Accepted/started helpers continue to use their established protocol.
sub _response_claimed_before_start {
    my ($self) = @_;
    $self->_refresh_connection;
    return $self->{_state} eq 'pending'
        && $self->{scope}{'pagi.connection'}->response_started;
}

sub disconnect_detail {
    my ($self) = @_;
    $self->_refresh_connection;
    return $self->{_disconnect_detail};
}

# Scope property accessors
sub scope        { shift->{scope} }
sub path         { shift->{scope}{path} // '/' }
sub raw_path     { my $s = shift; $s->{scope}{raw_path} // $s->{scope}{path} // '/' }
sub query_string { shift->{scope}{query_string} // '' }

# URL decode helper (handles + as space per application/x-www-form-urlencoded)
sub _url_decode {
    my ($str) = @_;
    return '' unless defined $str;
    $str =~ s/\+/ /g;
    $str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    return $str;
}

# UTF-8 decode helper with strict/lenient mode
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

    my $cache_key = $raw ? 'pagi.sse.query.raw' : ($strict ? 'pagi.sse.query.strict' : 'pagi.sse.query');
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

# Single query param accessor
sub query_param {
    my ($self, $name, %opts) = @_;
    return $self->query_params(%opts)->get($name);
}

# Raw single query param
sub raw_query_param {
    my ($self, $name) = @_;
    return $self->query_param($name, raw => 1);
}

sub scheme       { shift->{scope}{scheme} // 'http' }
sub http_version { shift->{scope}{http_version} // '1.1' }
sub client       { shift->{scope}{client} }
sub server       { shift->{scope}{server} }


# Application state (injected by PAGI::Lifespan, read-only)
sub has_state {
    my $self = shift;
    return 0 unless exists $self->{scope}{state};
    croak 'PAGI::SSE state must be a hashref'
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

# Connection state accessors
sub connection_state { my $self = shift; $self->_refresh_connection; return $self->{_state} }

sub is_started {
    my $self = shift;
    return $self->connection_state eq 'started';
}

sub is_closed {
    my $self = shift;
    return $self->connection_state eq 'closed';
}

# True while the stream is live (started and not yet closed/disconnected).
# Synchronous connection facts take precedence over local protocol progress.
sub is_connected {
    my $self = shift;
    return $self->connection_state eq 'started';
}

# Disconnect reason - why the connection closed
# Common values: 'client_closed', 'write_error', 'write_timeout', 'idle_timeout',
# 'read_error', 'protocol_error', 'server_shutdown', 'server_error'
sub disconnect_reason {
    my $self = shift;
    $self->_refresh_connection;
    return $self->{_disconnect_reason};
}

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

# Start the SSE stream
# Calls made while the stream is starting share that start, so sends from
# several producers before the first sse.start goes out issue it once.
sub start {
    my ($self, %opts) = @_;
    return $self->{_starting} if $self->{_starting};
    my $starting = $self->_start(%opts);
    return $starting if $starting->is_ready;
    $self->{_starting} = $starting;
    $starting->on_ready(sub { delete $self->{_starting} });
    return $starting;
}

async sub _start {
    my ($self, %opts) = @_;
    if ($self->_response_claimed_before_start) {
        delete $self->{_pending_keepalive};
        return $self;
    }

    # Idempotent - don't start twice
    return $self if $self->is_started || $self->is_closed || $self->connection_state eq 'closing';

    my $event = {
        type   => 'sse.start',
        status => $opts{status} // 200,
    };
    $event->{headers} = $opts{headers} if exists $opts{headers};

    await PAGI::Common::send_in_order($self, $event);
    $self->_set_state('started') unless $self->is_closed;
    return $self if $self->is_closed;

    # Arm any keepalive requested before the stream started (see
    # keepalive()'s deferred-arm note below) -- illegal before sse.start,
    # now legal immediately after it.
    if (my $pending = delete $self->{_pending_keepalive}) {
        await PAGI::Common::send_in_order($self, {
            type     => 'sse.keepalive',
            interval => $pending->{interval},
            comment  => $pending->{comment},
        });
        $self->{_keepalive_armed} = 1;
    }

    return $self;
}

# Enable keepalive - sends sse.keepalive event to server
# Server handles the timer; this is loop-agnostic
#
# DEFERRED ARM: sse.keepalive is illegal before sse.start (both
# PAGI::Utils::_SendValidation and the reference server's EventValidator reject it
# from the pre-start state -- see DEVIATION D-1). Calling this before the
# stream has started does not send anything; it records the interval/comment
# and start() arms it (sends the real event) immediately afterward, where
# it is legal. This is what lets PAGI::Endpoint::SSE configure
# keepalive_interval before on_connect runs without violating the protocol.
async sub keepalive {
    my ($self, $interval, $comment) = @_;

    # Safe no-op once closed (including via decline) -- there is no live
    # connection left for the server to time a ping against.
    if ($self->_response_claimed_before_start) {
        delete $self->{_pending_keepalive};
        return $self;
    }
    return $self if $self->is_closed || $self->connection_state eq 'closing';

    $interval //= 0;
    $comment  //= '';

    unless ($self->is_started) {
        if ($interval > 0) {
            $self->{_pending_keepalive} = { interval => $interval, comment => $comment };
        } else {
            delete $self->{_pending_keepalive};
        }
        return $self;
    }

    await PAGI::Common::send_in_order($self, {
        type     => 'sse.keepalive',
        interval => $interval,
        comment  => $comment,
    });

    $self->{_keepalive_armed} = $interval > 0 ? 1 : 0;

    return $self;
}

# Delegate to a public PAGI application instead of starting SSE.
# See PAGI::Spec::Www "SSE Response Denial".
async sub decline {
    my ($self, @targets) = @_;
    my $app = PAGI::Common::prepare_refusal(
        $self->{scope}, 'SSE decline', @targets,
    );
    await PAGI::Utils::invoke_app(
        $app, $self->{scope}, $self->{receive}, $self->{send},
    );
    return $self;
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

# Get Last-Event-ID header from client (for reconnection)
sub last_event_id {
    my ($self) = @_;
    return $self->header('last-event-id');
}

# Send data-only event
async sub send {
    my ($self, $data) = @_;

    return $self if $self->_response_claimed_before_start;
    croak "Cannot send on closed SSE connection" if $self->is_closed || $self->connection_state eq 'closing';

    # Auto-start if not started
    await $self->start unless $self->is_started;

    await PAGI::Common::send_in_order($self, {
        type => 'sse.send',
        data => $data,
    });

    return $self;
}

# Send JSON-encoded data
async sub send_json {
    my ($self, $data) = @_;

    return $self if $self->_response_claimed_before_start;
    croak "Cannot send on closed SSE connection" if $self->is_closed || $self->connection_state eq 'closing';

    await $self->start unless $self->is_started;

    my $json = JSON::MaybeXS::encode_json($data);

    await PAGI::Common::send_in_order($self, {
        type => 'sse.send',
        data => $json,
    });

    return $self;
}

# Send full SSE event with all fields
async sub send_event {
    my ($self, %opts) = @_;

    return $self if $self->_response_claimed_before_start;
    croak "Cannot send on closed SSE connection" if $self->is_closed || $self->connection_state eq 'closing';
    croak "send_event requires 'data' parameter" unless exists $opts{data};

    await $self->start unless $self->is_started;

    # Auto-encode hashref/arrayref data as JSON
    my $data = $opts{data};
    if (ref $data) {
        $data = JSON::MaybeXS::encode_json($data);
    }

    my $event = {
        type => 'sse.send',
        data => $data,
    };

    $event->{event} = $opts{event} if defined $opts{event};
    $event->{id}    = "$opts{id}"  if defined $opts{id};
    $event->{retry} = int($opts{retry}) if defined $opts{retry};

    await PAGI::Common::send_in_order($self, $event);

    return $self;
}

# Safe send - returns bool instead of throwing
async sub try_send {
    my ($self, $data) = @_;
    return 0 if $self->_response_claimed_before_start || $self->is_closed || $self->connection_state eq 'closing';

    eval {
        await $self->start unless $self->is_started;
        await PAGI::Common::send_in_order($self, {
            type => 'sse.send',
            data => $data,
        });
    };
    if (my $err = $@) {
        await $self->_trigger_error($err);
        return 0;
    }
    return 1;
}

async sub try_send_json {
    my ($self, $data) = @_;
    return 0 if $self->_response_claimed_before_start || $self->is_closed || $self->connection_state eq 'closing';

    eval {
        await $self->start unless $self->is_started;
        my $json = JSON::MaybeXS::encode_json($data);
        await PAGI::Common::send_in_order($self, {
            type => 'sse.send',
            data => $json,
        });
    };
    if (my $err = $@) {
        await $self->_trigger_error($err);
        return 0;
    }
    return 1;
}

# Send SSE comment (doesn't trigger onmessage in browser)
async sub send_comment {
    my ($self, $comment) = @_;

    return $self if $self->_response_claimed_before_start;
    croak "Cannot send on closed SSE connection" if $self->is_closed || $self->connection_state eq 'closing';

    await $self->start unless $self->is_started;

    await PAGI::Common::send_in_order($self, {
        type    => 'sse.comment',
        comment => $comment,
    });

    return $self;
}

async sub try_send_comment {
    my ($self, $comment) = @_;
    return 0 if $self->_response_claimed_before_start || $self->is_closed || $self->connection_state eq 'closing';

    eval {
        await $self->start unless $self->is_started;
        await PAGI::Common::send_in_order($self, {
            type    => 'sse.comment',
            comment => $comment,
        });
    };
    if (my $err = $@) {
        await $self->_trigger_error($err);
        return 0;
    }
    return 1;
}

async sub try_send_event {
    my ($self, %opts) = @_;
    return 0 if $self->_response_claimed_before_start || $self->is_closed || $self->connection_state eq 'closing';

    eval {
        await $self->start unless $self->is_started;

        my $data = $opts{data} // '';
        if (ref $data) {
            $data = JSON::MaybeXS::encode_json($data);
        }

        my $event = {
            type => 'sse.send',
            data => $data,
        };
        $event->{event} = $opts{event} if defined $opts{event};
        $event->{id}    = "$opts{id}"  if defined $opts{id};
        $event->{retry} = int($opts{retry}) if defined $opts{retry};

        await PAGI::Common::send_in_order($self, $event);
    };
    if (my $err = $@) {
        await $self->_trigger_error($err);
        return 0;
    }
    return 1;
}

# Internal: trigger error callbacks
async sub _trigger_error {
    my ($self, $error) = @_;

    for my $cb (@{$self->{_on_error}}) {
        eval {
            my $r = $cb->($self, $error);
            if (blessed($r) && $r->isa('Future')) {
                await $r;
            }
        };
        if ($@) {
            warn "PAGI::SSE on_error callback error: $@";
        }
    }
}

# Register close callback
sub on_close {
    my ($self, $callback) = @_;
    croak 'Cannot register on_close after cleanup begins' if $self->{_close_callbacks_ran};
    push @{$self->{_on_close}}, $callback;
    return $self;
}

# Register error callback
sub on_error {
    my ($self, $callback) = @_;
    push @{$self->{_on_error}}, $callback;
    return $self;
}

# Generic event dispatcher - dispatches to on_close or on_error
sub on {
    my ($self, $event, $callback) = @_;
    if ($event eq 'close') {
        return $self->on_close($callback);
    }
    elsif ($event eq 'error') {
        return $self->on_error($callback);
    }
    else {
        croak "Unknown event type: $event (expected close or error)";
    }
}

# Internal: run all on_close callbacks
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
            my $result = $cb->($self, $self->disconnect_reason, $self->disconnect_detail);
            await $result if blessed($result) && $result->isa('Future');
        };
        warn "PAGI::SSE on_close callback error: $@" if $@;
    }
    $self->{_on_close} = [];
    $self->{_on_error} = [];
    return;
}

# Close the connection
sub close {
    my ($self, @args) = @_;
    return Future->done($self) if $self->_response_claimed_before_start;
    if ($self->{_close_callbacks_ran}) {
        return $self->{_close_send}
            ? $self->{_close_send}->without_cancel->then(sub { Future->done($self) })->retain
            : Future->done($self);
    }
    return $self->{_close_operation}->without_cancel->then(sub { Future->done($self) })->retain
        if $self->{_close_operation};
    return $self->{_close_send}->without_cancel->then(sub { Future->done($self) })->retain
        if $self->{_close_send};
    return Future->done($self) if $self->is_closed;
    croak "SSE close requires an active accepted/started connection"
        unless $self->is_started;
    $self->{_state} = 'closing';
    my $settled = $self->{_close_send} = Future->new;
    my $send;
    my $ok = eval {
        my %opts = @args;
        $send = Future->wrap(PAGI::Common::send_in_order($self, {type => 'sse.close', (defined $opts{reason} ? (reason => $opts{reason}) : ())}));
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
    my $operation = (async sub {
        await $settled->without_cancel;
        await $self->{_cleanup_future}->without_cancel;
        return;
    })->();
    $self->{_close_operation} = $operation;
    $operation->on_ready(sub { delete $self->{_close_operation} });
    return $operation->without_cancel->then(sub { Future->done($self) })->retain;
}

# Wait until the connection ends. Disconnect is learned from the connection,
# never by reading receive.
async sub run {
    my ($self) = @_;
    if ($self->_response_claimed_before_start) {
        delete $self->{_pending_keepalive};
        return;
    }
    await $self->start unless $self->is_started || $self->is_closed;
    await $self->{_cleanup_future}->without_cancel;
    return;
}

# Iterate over items and send events
async sub each {
    my ($self, $source, $callback) = @_;
    return $self if $self->_response_claimed_before_start;

    await $self->start unless $self->is_started;

    my $index = 0;

    # Handle arrayref
    if (ref $source eq 'ARRAY') {
        for my $item (@$source) {
            last if $self->is_closed;

            my $result = await $callback->($item, $index++);

            # If callback returns a hashref, treat as event spec
            if (ref $result eq 'HASH') {
                await $self->send_event(%$result);
            }
        }
    }
    # Handle coderef iterator
    elsif (ref $source eq 'CODE') {
        while (!$self->is_closed) {
            my $item = $source->();
            last unless defined $item;

            my $result = await $callback->($item, $index++);

            if (ref $result eq 'HASH') {
                await $self->send_event(%$result);
            }
        }
    }
    else {
        croak "each() requires arrayref or coderef, got " . ref($source);
    }

    return $self;
}

# Periodic callback execution with interval delay
# Requires Future::IO to be installed
async sub every {
    my ($self, $interval, $callback) = @_;
    return $self if $self->_response_claimed_before_start;

    croak "every() requires interval" unless defined $interval && $interval > 0;
    croak "every() requires callback coderef" unless ref $callback eq 'CODE';

    # Future::IO is required for every() - fail clearly if not available
    eval { require Future::IO; 1 }
        or croak "every() requires Future::IO to be installed. "
               . "Install it with: cpanm Future::IO";

    # Future::IO must be configured with a backend
    no warnings 'once';
    croak "every() needs a Future::IO implementation, and none is configured.\n"
        . "Binding one is the job of the program that starts the event loop --\n"
        . "not a module, and not your application:\n"
        . "  * under pagi-server: it binds one at startup, before loading your\n"
        . "    application. Seeing this there is a bug in the server.\n"
        . "  * writing your own runner around PAGI::Server -- a custom stack,\n"
        . "    other things attached to ->loop: your runner IS that program.\n"
        . "    Bind one there, before it loads the application.\n"
        . "  * outside a server entirely (a test, a one-off script): likewise,\n"
        . "    bind one in the script.\n"
        . "    use Future::IO::Impl::IOAsync;   # or ::UV, ::Glib\n"
        . "Bind it before anything calls Future::IO: the first call latches an\n"
        . "implementation permanently, and a later bind cannot replace it.\n"
        unless $Future::IO::IMPL;

    await $self->start unless $self->is_started;

    my $connection = $self->{scope}{'pagi.connection'};

    while (!$self->is_closed) {
        # A callback that dies propagates, as in each(); on_close runs when
        # the connection ends.
        await $callback->();

        # Race the interval against the connection ending.
        my $sleep_future = Future::IO->sleep($interval);
        await Future->wait_any($sleep_future, $connection->end_future);

        if ($self->is_closed) {
            $sleep_future->cancel if $sleep_future->can('cancel') && !$sleep_future->is_ready;
            last;
        }
    }

    return $self;
}

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::SSE - Convenience wrapper for PAGI Server-Sent Events connections

=head1 SYNOPSIS

    use Future::AsyncAwait;
    use PAGI::Compose qw(compose);
    use PAGI::Routing qw(sse);

    our @history;        # every event published, for reconnecting clients
    our %subscribers;    # open streams, shared by every connection

    sub publish {
        my (%event) = @_;
        push @history, { %event, id => scalar(@history) + 1 };
        $_->try_send_event(%{ $history[-1] }) for values %subscribers;
    }

    my $app = compose(routes => [
        # An sse route's handler receives one PAGI::SSE.
        sse('/events' => async sub {
            my ($sse) = @_;

            # Comment lines keep idle proxies from closing the stream.
            await $sse->keepalive(25);

            $sse->on_close(sub {
                my ($sse, $reason) = @_;    # undef after an explicit close
                delete $subscribers{"$sse"};
            });

            # Replay what a reconnecting client missed, then go live.
            my $seen = $sse->last_event_id // 0;
            for my $event (@history[$seen .. $#history]) {
                await $sse->send_event(%$event);
            }
            $subscribers{"$sse"} = $sse;

            await $sse->run;    # until the client disconnects
        }),
    ]);

    # Elsewhere: publish(event => 'news', data => { title => 'Hello' });

=head1 DESCRIPTION

PAGI::SSE wraps the raw PAGI SSE protocol to provide a clean,
high-level API inspired by Starlette. It eliminates protocol
boilerplate and provides:

=over 4

=item * Multiple send methods (send, send_json, send_event)

=item * Declining a request with a real HTTP response instead of streaming (decline)

=item * Connection state tracking (is_started, is_closed, is_connected)

=item * Cleanup callback registration (on_close)

=item * Safe send methods for broadcast scenarios (try_send_*)

=item * Reconnection support (last_event_id)

=item * Keepalive timer for proxy compatibility

=item * Iteration helper (each)

=item * Per-connection storage (via L<PAGI::Stash>)

=back

=head1 CONSTRUCTOR

=head2 new

    my $sse = PAGI::SSE->new($scope, $receive, $send);

Creates a new SSE wrapper. Requires:

=over 4

=item * C<$scope> - PAGI scope hashref with C<< type => 'sse' >> and the
C<pagi.connection> object that L<PAGI::Spec::Www> 0.6 requires servers to
provide

=item * C<$receive> - Async coderef returning Futures for events

=item * C<$send> - Async coderef for sending events

=back

Dies if scope type is not 'sse', or if C<pagi.connection> is missing or lacks
a required method (C<PAGI::SSE requires pagi.connection capabilities ...>,
naming the server's advertised C<spec_version>). A scope built by hand, as in
tests, supplies one with L<PAGI::Test::ConnectionState>:

    my $scope = {
        type              => 'sse',
        headers           => [],
        'pagi.connection' => PAGI::Test::ConnectionState->new,
    };

B<Cached per scope (while referenced):> The SSE object is cached in
C<< $scope->{'pagi.sse'} >>, so calling C<new()> again with the same scope
returns the B<same object> — preserving state (is_started, is_closed,
callbacks) across code paths that build an SSE object from the same scope —
B<as long as you hold a strong reference to it>. The cache is deliberately
B<weak> (to avoid a C<< $scope >> <-> SSE reference cycle), so it is B<not> a
guaranteed singleton: if every strong reference is dropped the object may be
garbage-collected, and a later C<new()> will build a fresh one with reset
state. In normal use a handler keeps C<$sse> alive for the life of the
connection, so this does not arise.

=head1 SCOPE ACCESSORS

=head2 scope, path, raw_path, query_string, scheme, http_version

    my $path = $sse->path;              # /events
    my $qs = $sse->query_string;        # token=abc

=head2 header, headers, header_all

    my $auth = $sse->header('authorization');
    my @cookies = $sse->header_all('cookie');
    my $headers = $sse->headers;        # PAGI::Headers

Case-insensitive header access through L<PAGI::Headers>.

=head2 last_event_id

    my $id = $sse->last_event_id;       # From Last-Event-ID header

Returns the Last-Event-ID header sent by reconnecting clients.
Use this to replay missed events.

=head2 Per-Connection Shared State

See L<PAGI::Stash> for per-connection shared state:

    use PAGI::Stash;
    my $stash = PAGI::Stash->new($sse);

=cut

=head2 path_param

    my $channel = $sse->path_param('channel');

Returns a path parameter by name. Path parameters are captured from the URL
path by a router and stored in C<< $scope->{path_params} >>.

=head2 path_params

    my $params = $sse->path_params;

Returns hashref of all path parameters from scope.

=head2 query_params

    my $params = $sse->query_params;
    my $params = $sse->query_params(strict => 1);
    my $params = $sse->query_params(raw => 1);

Returns query string parameters as a L<Hash::MultiValue>. Handles URL decoding
and UTF-8 decoding automatically.

Options:

=over 4

=item strict => 1

Croak on invalid UTF-8 sequences instead of replacing with substitution character.

=item raw => 1

Skip UTF-8 decoding, return raw bytes after URL decoding.

=back

=head2 raw_query_params

    my $params = $sse->raw_query_params;

Shortcut for C<< query_params(raw => 1) >>.

=head2 query_param

    my $value = $sse->query_param('name');
    my $value = $sse->query_param('name', strict => 1);

Returns a single query parameter value by name. Accepts same options as
C<query_params>.

=head2 raw_query_param

    my $value = $sse->raw_query_param('name');

Shortcut for C<< query_param($name, raw => 1) >>.

=head2 state

    my $state = $sse->state
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
per-connection data, and from C<connection_state>, which reports this SSE
stream's protocol lifecycle.

=head2 has_state

    if ($sse->has_state) {
        ...
    }

Returns true when lifespan application state is present and a hashref. Returns
false only when it is absent; malformed present state croaks.

=head1 LIFECYCLE METHODS

=head2 start

    await $sse->start;
    await $sse->start(status => 200, headers => [...]);

Starts the SSE stream. Called automatically on first send.
Idempotent - only sends sse.start once. A call made while the stream is
starting returns the same Future, so several sends made before the stream
starts produce one sse.start.

If L</keepalive> was called before C<start> (for example
L<PAGI::Endpoint::SSE>'s C<keepalive_interval>, which is configured before
C<on_connect> runs), C<start> arms it immediately after sending C<sse.start>
-- see L</keepalive>'s B<DEFERRED ARM> note.

=head2 decline

    use Future::AsyncAwait;
    use PAGI::Response qw(text_response);

    async sub unavailable {
        my ($sse) = @_;
        await $sse->decline(text_response('Unavailable', status => 503));
        return;
    }

    async sub unavailable_for_request {
        my ($sse) = @_;
        await $sse->decline(sub {
            my ($request) = @_;
            return text_response('Unavailable: ' . $request->path, status => 503);
        });
        return;
    }

Delegates the SSE request refusal to exactly one Request handler or
instantiated application object with C<to_app>, before C<start>. Concrete
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

SSE refusals may use ordinary HTTP statuses including 200 and 204. Request
body APIs consume the actual C<sse.request> body stream. Once HTTP refusal
starts, protocol sends and C<start> cannot reopen it, and deferred keepalive
is discarded. A live attempt that settles before response start preserves
pending keepalive for a later ordinary C<start>.

See L<PAGI::Tools::Cookbook/Refusing WebSocket and SSE with applications> for
complete synchronous and async handlers, direct Pages applications, custom
application objects, and wrapped native applications, with matching WebSocket
call sites.

See L<PAGI::Spec::Www/"SSE Response Denial">.

=head2 close

    await $sse->close;
    await $sse->close(reason => 'job_complete');

Requests stream completion with one C<sse.close> event. State becomes
C<closing>, which stops new data sends; only the connection can make it
C<closed>. The optional C<reason> is outgoing server-side metadata and does
not replace the authoritative terminal reason/detail.

The first close and concurrent calls before cleanup starts await send
settlement and the shared asynchronous cleanup. Once terminal cleanup has
begun, C<close> is idempotent and returns on close-send settlement (or
immediately if no send was needed). This rule also applies to unrelated later
callers: it allows an C<on_close> hook to call C<close> without waiting on
itself. Cleanup itself always has one shared completion; cancelling an
observer cannot cancel the worker or server I/O.

The router and endpoint C<to_app> boundary send a missing close on successful
handler return only if a stream is started and active. Exceptions propagate
without creating a clean terminal outcome.

=head2 run

    await $sse->run;

Waits for connection end and its asynchronous cleanup without reading the
receive queue. Use this to keep a live stream handler open.

Safe no-op after L</decline>, where no live stream was opened. For a started
stream that has ended, it joins the same cleanup completion.

=head1 CONNECTION STATE ACCESSORS

=head2 is_started, is_closed, connection_state

    if ($sse->is_started) { ... }
    if ($sse->is_closed) { ... }
    my $state = $sse->connection_state;    # pending, started, closing, closed

These are the complete protocol phase values. The former C<declining> phase is
retired: invoking L</decline> does not mutate helper state. The initial
C<pending> value describes SSE progress, not availability of the HTTP response
slot; refusal admission also reads the public connection facts. After terminal
notification, a declined helper is an ordinary closed helper.

=head2 is_connected

    if ($sse->is_connected) { ... }

True while the stream is live: started and not yet closed or disconnected
(equivalently, C<connection_state eq 'started'>). This is a synchronous,
non-destructive check that does not consume the receive queue. Mirrors
L<PAGI::WebSocket/is_connected>.

Every modern SSE scope supplies C<pagi.connection>. Synchronous terminal
facts take precedence over local progress, including before deferred callback
delivery. A send settling successfully or failing does not establish liveness.

=head2 disconnect_reason, disconnect_detail

Return the connection's lifecycle reason token and diagnostic detail. Both
are C<undef> on a clean end; the helper does not invent an application-close
or client-close reason. See L<PAGI::Spec::Www/"Standard Disconnect Reasons">.

=head2 buffered_amount, high_water_mark, low_water_mark

    my $pending = $sse->buffered_amount;   # bytes queued, not yet on the wire
    my $ceiling = $sse->high_water_mark;    # backpressure ceiling (or undef)
    my $floor   = $sse->low_water_mark;     # backpressure floor (or undef)

Outbound flow-control introspection, delegated to the server-provided
C<pagi.transport> handle (see L<PAGI::Spec::Www/"Transport Flow Control">). Use
C<buffered_amount> to conflate, coalesce, shed load, or disconnect a slow client
instead of only blocking on drain; when the server does not provide the handle,
C<buffered_amount> returns C<0> and the watermarks return C<undef>.

=head2 on_high_water, on_drain, is_writable

    $sse->on_high_water(sub { $source->pause });   # backpressure engaged
    $sse->on_drain(sub      { $source->resume });   # backpressure cleared
    last unless $sse->is_writable;                   # below the high mark?

Backpressure controls delegated to the C<pagi.transport> handle. C<on_high_water>
and C<on_drain> register edge-triggered callbacks (the Node/Mojo C<drain> model)
for producers that cannot self-pace with a blocking send; each returns the
object for chaining. C<is_writable> is true when the outbound buffer is below the
high mark. When the server provides no transport handle (or only the read
methods), the callbacks are quiet no-ops and C<is_writable> is true.

=head1 SEND METHODS

=head2 send

    await $sse->send("Hello world");

Sends a data-only event.

B<Sends go out one at a time.> PAGI::Spec::Www requires that an application
not issue a send before the previous one has resolved. This object does that
for you: a send made while another is still in flight waits for it, whatever
its outcome, so several producers -- a live broadcast racing a periodic
C<every> callback -- can each call C<send*> or C<try_send*> directly, with no
queue of their own. A send whose caller cancels it before it goes out is
skipped; one already handed to the server is never cancelled. Code that calls
the raw C<$send> itself still owns the rule.

=head2 send_json

    await $sse->send_json({ type => 'update', data => $payload });

JSON-encodes data before sending.

=head2 send_event

    await $sse->send_event(
        data  => $data,              # Required (auto JSON-encodes refs)
        event => 'notification',     # Optional event type
        id    => 'msg-123',          # Optional event ID
        retry => 5000,               # Optional reconnect hint (ms)
    );

Sends a full SSE event with all fields.

C<send>, C<send_json>, and C<send_event> croak (C<"Cannot send on closed SSE
connection">) after terminal notification, including after L</decline>. While
a refusal response has started but the connection is still live, these methods
return C<$self> without emitting an SSE start or data event.

=head2 try_send, try_send_json, try_send_event

    my $ok = await $sse->try_send_json($data);
    if (!$ok) {
        # Client disconnected
    }

Returns true on success, false on failure. Does not throw.
Useful for broadcasting to multiple clients.

=head1 KEEPALIVE

=head2 keepalive

    await $sse->keepalive(30);              # Ping every 30 seconds
    await $sse->keepalive(30, 'ping');      # Custom comment text
    await $sse->keepalive(0);               # Disable

Sends an C<sse.keepalive> event to the server, which then handles sending
periodic SSE comments to keep the connection alive and prevent proxy timeouts.
The server manages the timer internally - this method is loop-agnostic.

Safe no-op once the connection is closed (including by L</decline>) -- there
is no live connection left for the server to time a ping against, so the
call returns C<$self> without sending anything.

B<DEFERRED ARM:> C<sse.keepalive> is illegal before C<sse.start> -- both
L<PAGI::Utils::_SendValidation> and the reference server's C<EventValidator> reject
it from the pre-start state. Calling C<keepalive> before L</start> does
B<not> send anything: it records the interval/comment, and C<start> arms
the recording (sends the real event) immediately afterward, where it is
legal. A subsequent pre-start call with C<< interval => 0 >> clears the
recording instead of arming anything. This is transparent to callers --
C<< await $sse->keepalive($n) >> still "just works" whether called before or
after C<start> -- and it's specifically what lets
L<PAGI::Endpoint::SSE/keepalive_interval> be configured before C<on_connect>
runs without violating the protocol. If C<on_connect> then calls
L</decline>, the recording (never having been sent) is simply dropped --
see L</decline>.

=head1 ITERATION

=head2 each

    # Simple iteration
    await $sse->each(\@items, async sub {
        my ($item) = @_;
        await $sse->send_json($item);
    });

    # With transformer - return event spec
    await $sse->each(\@items, async sub {
        my ($item, $index) = @_;
        return {
            data  => $item,
            event => 'item',
            id    => $index,
        };
    });

    # Coderef iterator
    await $sse->each($iterator_sub, async sub { ... });

Iterates over items, calling callback for each.
If callback returns a hashref, sends it as an event.

=head2 every

    # Send metrics every 2 seconds
    await $sse->every(2, async sub {
        await $sse->send_event(
            event => 'metrics',
            data  => get_current_metrics(),
        );
    });

Periodically executes a callback with a delay between iterations.
The loop continues until the connection closes or the callback throws.

B<Requires Future::IO> with an implementation bound. This method C<croak>s if
Future::IO is not installed, or if no implementation has been configured.

B<Do not bind one in your application.> Naming an implementation in
application code ties that application to one event loop, which is exactly
what PAGI's protocol exists to avoid. Binding belongs in the program that
starts the event loop:

=over 4

=item * B<Running under C<pagi-server>>

Nothing to do. The runner binds an implementation at startup, before it loads
your application.

=item * B<Writing your own runner around L<PAGI::Server>>

Your runner is that program -- this is the usual case when you are building a
custom stack, or attaching other things to the server's C<< ->loop >>. Bind an
implementation there, before the runner loads the application:

    # my-runner.pl
    use Future::IO::Impl::IOAsync;   # matches PAGI::Server's loop
    use PAGI::Server;

    my $server = PAGI::Server->new(app => $app, ...);
    # ... attach your own things to $server->loop ...
    $server->run;

=item * B<Running outside a server>

A test, or a one-off script. Same rule: bind one in the script.

    use Future::IO::Impl::IOAsync;   # or ::UV, ::Glib

=back

B<Bind before anything calls Future::IO.> The first call latches an
implementation permanently. If any code reaches Future::IO before you bind
one, the blocking default is installed and your later bind is refused with
C<Unable to set Future::IO implementation ...> -- after which awaiting a
Future::IO future under an external event loop hangs, because nothing drives
the default implementation.

Parameters:

=over 4

=item * C<$interval> - Seconds between iterations (required, must be > 0)

=item * C<$callback> - Async coderef to execute (required)

=back

The callback is executed first, then the method sleeps for the interval
before the next iteration. Every timer race gets a fresh cancellation-isolated
connection end observer; it never starts a receive watcher on a connection-backed
scope. Callback exceptions propagate to the server; terminal cleanup waits for
the connection outcome.

=head1 EVENT CALLBACKS

=head2 on_close

    $sse->on_close(sub {
        my ($sse, $reason) = @_;
        if (!defined $reason) {
            cleanup_resources();
        } else {
            log_error("Unexpected disconnect: $reason");
        }
    });

    # Async callback — return value is awaited automatically
    $sse->on_close(async sub {
        my ($sse, $reason) = @_;
        await cleanup_async($reason);
    });

Registers cleanup for the connection's terminal C<on_end> notification.
Register before awaited I/O. Registration after cleanup has started or
finished (including constructor-time terminal notification) croaks.
Callbacks can be regular subs or async subs — async results are
automatically awaited. Multiple callbacks run in registration order.
Exceptions are caught and warned but do not prevent other callbacks.

Callbacks receive three arguments:

=over 4

=item * C<$sse> - The SSE connection object (same as C<$self>)

=item * C<$reason> - Lifecycle token, or C<undef> for clean completion

=item * C<$detail> - Diagnostic detail, or C<undef>

=back

Returns C<$self> for chaining.

B<Circular reference note:> If your callback captures the C<$sse> object
in a closure, use the C<$sse> argument instead — it is the same object
but does not create an additional reference cycle. If you must capture
it, use C<Scalar::Util::weaken>:

    use Scalar::Util qw(weaken);
    my $weak_sse = $sse;
    weaken($weak_sse);
    $sse->on_close(sub { $weak_sse->... if $weak_sse });

The connection retains the helper until terminal notification. A single
retained worker then owns asynchronous hooks, surviving handler return until
cleanup settles and releases the hooks and helper.

=head2 on_error

    $sse->on_error(sub {
        my ($sse, $error) = @_;
        warn "SSE error: $error";
    });

    # Async callback — return value is awaited automatically
    $sse->on_error(async sub {
        my ($sse, $error) = @_;
        await log_error_async($error);
    });

Registers error callback. Called when a C<try_send*> method fails
(e.g., because the client disconnected mid-write). Callbacks can be
regular subs or async subs — async results are automatically awaited.
Multiple callbacks run in registration order. Exceptions are caught
and warned but do not prevent other callbacks.

Callbacks receive two arguments:

=over 4

=item * C<$sse> - The SSE connection object

=item * C<$error> - The error string

=back

If no error handlers are registered, nothing is printed: the C<try_send*>
method's false return value is the signal, and a failed send is usually a
routine client disconnect.

Returns C<$self> for chaining.

=head2 on

    $sse->on(close => sub { my ($sse, $reason) = @_; ... });
    $sse->on(error => sub { my ($sse, $error)  = @_; ... });

    # Chaining
    $sse->on(close => sub { ... })
        ->on(error => sub { ... });

Generic event dispatcher. Dispatches to C<on_close> or C<on_error>
based on the event name. Dies if an unknown event name is given.

Returns C<$self> for chaining.

=head1 EXAMPLE: LIVE DASHBOARD

    async sub dashboard_sse {
        my ($scope, $receive, $send) = @_;

        my $sse = PAGI::SSE->new($scope, $receive, $send);

        my $sub_id;
        $sse->on_close(sub {
            my ($sse, $reason) = @_;
            unsubscribe_metrics($sub_id) if defined $sub_id;
            # Log abnormal disconnects for debugging
            warn "SSE client disconnected: $reason"
                if defined $reason;
        });

        await $sse->keepalive(25);

        # Send initial state
        await $sse->send_event(
            event => 'connected',
            data  => { time => time() },
        );

        return if $sse->is_closed;

        # Subscribe to metrics
        $sub_id = subscribe_metrics(sub {
            my ($metrics) = @_;
            $sse->try_send_event(
                event => 'metrics',
                data  => $metrics,
            );
        });

        await $sse->run;
    }

=head1 SEE ALSO

L<PAGI::WebSocket> - Similar wrapper for WebSocket connections

L<PAGI::Server> - PAGI protocol server

=head1 AUTHOR

PAGI Contributors

=cut
