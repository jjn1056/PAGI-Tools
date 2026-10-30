package PAGI::SSE;
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

    croak "PAGI::SSE requires scope hashref"
        unless $scope && ref($scope) eq 'HASH';
    croak "PAGI::SSE requires receive coderef"
        unless $receive && ref($receive) eq 'CODE';
    croak "PAGI::SSE requires send coderef"
        unless $send && ref($send) eq 'CODE';
    croak "PAGI::SSE requires scope type 'sse', got '$scope->{type}'"
        unless ($scope->{type} // '') eq 'sse';
    # PAGI::Spec::Www 0.6: servers provide pagi.connection on every scope.
    PAGI::Utils::_ProtocolHelpers::require_connection($scope, 'PAGI::SSE');

    # One object per call: nothing is cached in the scope, so a handler
    # keeps the object it was given (SUBCLASSING).
    my $self = $class->SUPER::new($scope);
    $self->{receive} = $receive;
    $self->{send} = $send;
    $self->{_state} = 'pending';  # pending -> started -> closed
    $self->{_on_close} = [];
    $self->{_on_error} = [];
    $self->{_disconnect_reason} = undef;  # Set when disconnect received

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
    unless ($connection->is_connected) {
        $self->{_state} = 'closed';
        delete $self->{_pending_keepalive};
    }
    return;
}

# A helper drives only what it answered (PAGI::Utils::_ProtocolHelpers holds
# the claim rules): while its own refusal is in progress, or once another
# helper answered the open connection, it fails locally.
sub _refusing { PAGI::Utils::_ProtocolHelpers::refusing($_[0]) }
sub _answered_by_another { PAGI::Utils::_ProtocolHelpers::answered_by_another($_[0]) }

# This helper answered: its start completed, or it was issued -- still
# pending, or rejected by the server (D6: the helper keeps its claim and is
# still treated as the answerer). Either way it drives the connection as a
# started stream and never issues a second sse.start; the server keeps a
# scope's sends in call order. Once the connection has ended, no helper has
# answered it.
sub _answered {
    my ($self) = @_;
    return $self->is_started
        || (($self->{_claim} // '') eq 'answering' && $self->connection_state eq 'pending');
}

# A keepalive saved for a start this helper may not make is dropped.
sub _require_ownership {
    my ($self) = @_;
    my $refused = PAGI::Utils::_ProtocolHelpers::ownership_refusal($self);
    return unless $refused;
    delete $self->{_pending_keepalive};
    croak $refused;
}

sub disconnect_detail {
    my ($self) = @_;
    $self->_refresh_connection;
    return $self->{_disconnect_detail};
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
    $self->_require_ownership;

    # Idempotent - don't start twice
    return $self if $self->_answered || $self->is_closed || $self->connection_state eq 'closing';

    my $event = {
        type   => 'sse.start',
        status => $opts{status} // 200,
    };
    if (exists $opts{headers}) {
        my ($headers, $refused) = PAGI::Utils::_sendable_headers('PAGI::SSE start', $opts{headers});
        croak $refused if $refused;
        $event->{headers} = $headers;
    }

    # The helper owns the connection from the moment its start is issued.
    $self->{_claim} = 'answering';
    await PAGI::Utils::_ProtocolHelpers::forward_send($self, $event);
    # A close made while the start was pending stands, and no saved
    # keepalive is armed after it.
    $self->_set_state('started') if $self->connection_state eq 'pending';
    return $self unless $self->is_started;

    # Arm any keepalive requested before the stream started (see
    # keepalive()'s deferred-arm note below) -- illegal before sse.start,
    # now legal immediately after it.
    if (my $pending = delete $self->{_pending_keepalive}) {
        await PAGI::Utils::_ProtocolHelpers::forward_send($self, {
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

    # Safe no-op once closed or while declining -- there is no stream for
    # the server to time a ping against.
    if ($self->_refusing) {
        delete $self->{_pending_keepalive};
        return $self;
    }
    $self->_require_ownership;
    return $self if $self->is_closed || $self->connection_state eq 'closing';

    $interval //= 0;
    $comment  //= '';

    unless ($self->_answered) {
        if ($interval > 0) {
            $self->{_pending_keepalive} = { interval => $interval, comment => $comment };
        } else {
            delete $self->{_pending_keepalive};
        }
        return $self;
    }

    # Sent now, after the issued start, so a saved one is not armed later.
    delete $self->{_pending_keepalive};
    await PAGI::Utils::_ProtocolHelpers::forward_send($self, {
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
    my $app = PAGI::Utils::_ProtocolHelpers::prepare_refusal(
        $self, 'SSE decline', @targets,
    );
    await PAGI::Utils::_ProtocolHelpers::refuse($self, $app);
    return $self;
}

# Get Last-Event-ID header from client (for reconnection)
sub last_event_id {
    my ($self) = @_;
    return $self->header('last-event-id');
}

# Send data-only event
async sub send {
    my ($self, $data) = @_;

    croak "Cannot send on closed SSE connection" if $self->is_closed || $self->connection_state eq 'closing';
    $self->_require_ownership;
    defined($data = PAGI::Utils::_string_value($data))
        or croak 'send requires a string or an object that overloads stringification';

    # Auto-start if not started
    await $self->start unless $self->is_started;

    await PAGI::Utils::_ProtocolHelpers::forward_send($self, {
        type => 'sse.send',
        data => $data,
    });

    return $self;
}

# Send JSON-encoded data
async sub send_json {
    my ($self, $data) = @_;

    croak "Cannot send on closed SSE connection" if $self->is_closed || $self->connection_state eq 'closing';
    $self->_require_ownership;

    await $self->start unless $self->is_started;

    my $json = JSON::MaybeXS::encode_json($data);

    await PAGI::Utils::_ProtocolHelpers::forward_send($self, {
        type => 'sse.send',
        data => $json,
    });

    return $self;
}

# Send full SSE event with all fields
async sub send_event {
    my ($self, %opts) = @_;

    croak "Cannot send on closed SSE connection" if $self->is_closed || $self->connection_state eq 'closing';
    $self->_require_ownership;
    croak "send_event requires 'data' parameter" unless exists $opts{data};

    my $event = _send_event_for(%opts);
    await $self->start unless $self->is_started;

    await PAGI::Utils::_ProtocolHelpers::forward_send($self, $event);

    return $self;
}

# Safe send - returns bool instead of throwing
# Best-effort sends never throw, so broadcast loops may make one and drop
# the Future. The helper keeps each until it settles, so a send waiting its
# turn behind another still goes out and is not reported as lost, and
# finished waits for it.
sub try_send { my $self = shift; return $self->_keep($self->_try_send(@_)) }

async sub _try_send {
    my ($self, $data) = @_;
    return 0 if $self->_refusing || $self->_answered_by_another || $self->is_closed || $self->connection_state eq 'closing';

    eval {
        defined($data = PAGI::Utils::_string_value($data))
            or croak 'send requires a string or an object that overloads stringification';
        await $self->start unless $self->is_started;
        await PAGI::Utils::_ProtocolHelpers::forward_send($self, {
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

sub try_send_json { my $self = shift; return $self->_keep($self->_try_send_json(@_)) }

async sub _try_send_json {
    my ($self, $data) = @_;
    return 0 if $self->_refusing || $self->_answered_by_another || $self->is_closed || $self->connection_state eq 'closing';

    eval {
        await $self->start unless $self->is_started;
        my $json = JSON::MaybeXS::encode_json($data);
        await PAGI::Utils::_ProtocolHelpers::forward_send($self, {
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

    croak "Cannot send on closed SSE connection" if $self->is_closed || $self->connection_state eq 'closing';
    $self->_require_ownership;
    defined($comment = PAGI::Utils::_string_value($comment))
        or croak 'send_comment requires a string or an object that overloads stringification';

    await $self->start unless $self->is_started;

    await PAGI::Utils::_ProtocolHelpers::forward_send($self, {
        type    => 'sse.comment',
        comment => $comment,
    });

    return $self;
}

sub try_send_comment { my $self = shift; return $self->_keep($self->_try_send_comment(@_)) }

async sub _try_send_comment {
    my ($self, $comment) = @_;
    return 0 if $self->_refusing || $self->_answered_by_another || $self->is_closed || $self->connection_state eq 'closing';

    eval {
        defined($comment = PAGI::Utils::_string_value($comment))
            or croak 'send_comment requires a string or an object that overloads stringification';
        await $self->start unless $self->is_started;
        await PAGI::Utils::_ProtocolHelpers::forward_send($self, {
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

sub try_send_event { my $self = shift; return $self->_keep($self->_try_send_event(@_)) }

async sub _try_send_event {
    my ($self, %opts) = @_;
    return 0 if $self->_refusing || $self->_answered_by_another || $self->is_closed || $self->connection_state eq 'closing';

    eval {
        my $event = _send_event_for(%opts);
        await $self->start unless $self->is_started;

        await PAGI::Utils::_ProtocolHelpers::forward_send($self, $event);
    };
    if (my $err = $@) {
        await $self->_trigger_error($err);
        return 0;
    }
    return 1;
}

# The sse.send event for send_event and try_send_event. An object that
# overloads "" is text; other data references are encoded as JSON; undef
# data is refused. event and id are strings, never HASH(0x...).
sub _send_event_for {
    my (%opts) = @_;
    my $data = $opts{data};
    if (ref $data) {
        my $string = PAGI::Utils::_stringified($data);
        $data = ref($string) ? JSON::MaybeXS::encode_json($data) : $string;
    }
    defined $data
        or croak 'send_event data must be a string, a reference to encode as JSON, or an object that overloads stringification';
    my $event = { type => 'sse.send', data => $data };
    for my $field (qw(event id)) {
        next unless defined $opts{$field};
        defined($event->{$field} = PAGI::Utils::_string_value($opts{$field}))
            or croak "send_event $field must be a string or an object that overloads stringification";
    }
    $event->{retry} = int($opts{retry}) if defined $opts{retry};
    return $event;
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
        my $result = $callback->($self, $self->disconnect_reason, $self->disconnect_detail);
        await $result if blessed($result) && $result->isa('Future');
        1;
    };
    return if $ok;
    die $@ unless $self->{_finished};
    warn ref($self) . " on_close callback failed after the handler finished: $@";
    return;
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
            my $result = $cb->($self, $self->disconnect_reason, $self->disconnect_detail);
            await $result if blessed($result) && $result->isa('Future');
            1;
        };
        push @failures, $@ unless $ok;
    }
    $self->{_on_close} = [];
    $self->{_on_error} = [];
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
    return $self->connection_state ne 'pending';
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

# Close the connection
sub close {
    my ($self, @args) = @_;
    # A refusal is already this helper's answer.
    return Future->done($self) if $self->_refusing;
    $self->_require_ownership;
    if ($self->{_close_callbacks_ran}) {
        return $self->{_close_send}
            ? $self->_keep($self->{_close_send}->without_cancel->then(sub { Future->done($self) }))
            : Future->done($self);
    }
    return $self->_keep($self->{_close_operation}->without_cancel->then(sub { Future->done($self) }))
        if $self->{_close_operation};
    return $self->_keep($self->{_close_send}->without_cancel->then(sub { Future->done($self) }))
        if $self->{_close_send};
    return Future->done($self) if $self->is_closed;
    croak "SSE close requires an active accepted/started connection"
        unless $self->_answered;
    $self->{_state} = 'closing';
    my $settled = $self->{_close_send} = Future->new;
    my $send;
    my $ok = eval {
        my %opts = @args;
        $send = Future->wrap(PAGI::Utils::_ProtocolHelpers::forward_send($self, {type => 'sse.close', (defined $opts{reason} ? (reason => $opts{reason}) : ())}));
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
    return $self->_keep($operation->without_cancel->then(sub { Future->done($self) }));
}

# Wait until the connection ends. Disconnect is learned from the connection,
# never by reading receive.
async sub run {
    my ($self) = @_;
    $self->_require_ownership;
    await $self->start unless $self->is_started || $self->is_closed;
    await $self->{_cleanup_future}->without_cancel;
    return;
}

# Iterate over items and send events
async sub each {
    my ($self, $source, $callback) = @_;
    $self->_require_ownership;

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
    $self->_require_ownership;

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

    use Future;
    use Future::AsyncAwait;
    use Scalar::Util qw(refaddr);
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
            await $sse->start;

            # Replay what a reconnecting client missed, then go live. Sends go
            # out in the order they are made, so making the replay sends and
            # subscribing in one step (no await between) puts anything
            # published meanwhile after the replay: nothing missed or reordered.
            my $seen = $sse->last_event_id // 0;
            my @replay = map { $sse->send_event(%$_) } @history[$seen .. $#history];
            my $id = refaddr $sse;
            $subscribers{$id} = $sse;

            # Unsubscribe however the stream ends, at once if the client has
            # already gone.
            $sse->on_close(sub { delete $subscribers{$id} });
            await Future->needs_all(@replay);

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

Each call builds a new object and stores nothing in the scope, so build one
per connection and pass it on (see L</SUBCLASSING>).

An application that constructs the helper itself should
C<await $sse-E<gt>finished> before it returns; see L</finished>. Routes and the
Endpoint classes do this for you.

=head1 INHERITED FROM PAGI::HTTPConnection

A PAGI::SSE is a L<PAGI::HTTPConnection>: what can be read from the
scope alone comes from the methods it inherits, documented there. Each parse
(headers, query, cookies) is kept on the object; nothing is written to the
scope.

=over 4

=item * Scope properties: C<scope>, C<connection>, C<client>, C<server>,
C<scheme> (C<http> unless the scope says otherwise), C<http_version>, C<path>,
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

=head2 last_event_id

    my $id = $sse->last_event_id;       # From Last-Event-ID header

Returns the Last-Event-ID header sent by reconnecting clients.
Use this to replay missed events.

=head2 Per-Connection Shared State

See L<PAGI::Stash> for per-connection shared state, which
L<PAGI::Middleware::Stash> stacked above the handler provides:

    use PAGI::Stash;
    my $stash = PAGI::Stash->new($sse);

=cut

=head1 LIFECYCLE METHODS

=head2 start

    await $sse->start;
    await $sse->start(status => 200, headers => ['x-custom' => 'value']);

Starts the SSE stream. Called automatically on first send.
C<headers> takes the same three shapes and name and value rules as
L<PAGI::WebSocket/accept>, and is sent as C<[[name, value], ...]> pairs.
Idempotent - only sends sse.start once. A call made while the stream is
starting returns the same Future, so several sends made before the stream
starts produce one sse.start.

If L</keepalive> was called before C<start> (for example
L<PAGI::Endpoint::SSE>'s C<keepalive_interval>, which is configured before
C<on_connect> runs), C<start> arms it immediately after sending C<sse.start>
-- see L</keepalive>'s B<DEFERRED ARM> note.

=head2 decline

    use Future::AsyncAwait;
    use PAGI::Response qw(response);

    async sub unavailable {
        my ($sse) = @_;
        await $sse->decline(response('Text', 'Unavailable', status => 503));
        return;
    }

    async sub unavailable_for_request {
        my ($sse) = @_;
        await $sse->decline(sub {
            my ($request) = @_;
            return response('Text', 'Unavailable: ' . $request->path, status => 503);
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

After a L</decline> that completed, where no live stream was opened, it
returns once cleanup is done; while the decline's response is still in
progress it croaks (see L</WHICH HELPER ANSWERS>). For a started stream that
has ended, it joins the same cleanup completion.

=head1 WHICH HELPER ANSWERS

A connection has one answer, and a helper drives only the answer it gave.
Building a second helper over the same scope (C<new> always builds a new
object) gives a helper that did not answer, so which helper answered
decides what each can do. C<sse.start> is this helper's accept.

B<This helper answered.> From the moment this helper issues its C<start>,
before the server's send completes, it owns the connection: sends,
iteration, C<run>, C<keepalive> and C<close> work as on a started stream.
A send made while the start is still pending joins that start and goes out
after it; a C<close> made then goes out after the start, in call order, and
the completed start does not reopen the stream; a C<keepalive> made then is
sent after the start. If the server rejects the start, the error raises at
its C<await>; the helper keeps the claim it recorded when it sent the start
and is still treated as the connection's answerer: its sends,
C<try_send*>, C<keepalive> and C<close> go to the server as on a started
stream (which the server may reject in turn), no second C<sse.start> is
sent, and code that keeps using it gets no protection from the rules below.
After a failed start, build a new helper if the connection is still live
and unanswered, or use the helper that answered if another did.

B<This helper is refusing.> Once the response of this helper's L</decline>
has started and the connection is still open, the refusal is its answer.
Its C<start>, a second C<decline>, C<send>, C<send_json>, C<send_event>,
C<send_comment>, C<each>, C<every> and C<run> croak
C<this helper is refusing the connection>, sending nothing and reading
nothing; C<try_send*> return 0; C<close> and C<keepalive> return quietly.
The refusal itself completes as usual. A refusal that settles with no
response started answered nothing, and the helper may try again.

B<Another helper answered.> While the connection is open and its response
was started by another helper, every operation of this one croaks
C<this connection was answered by another helper; use that one>, sending
nothing and reading nothing, except C<try_send*>, which return 0. That
includes C<close> and C<keepalive>: ending a stream another helper owns is
that helper's call. A middleware that must act on the connection's data
wraps C<$send> or C<$receive> instead.

B<The connection has ended.> Every helper behaves as it does for an ended
connection: sends croak C<Cannot send on closed SSE connection>, and
C<start>, C<close>, C<keepalive> and C<run> do nothing more.

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

Data, comments and an event's C<event> and C<id> may be given as an object
that stringifies (L<PAGI::Response/VALUES FROM OTHER CODE>). A value that is
neither a string nor such an object makes the sending method fail, and the
C<try_send*> methods return false without sending; C<send_json> encodes data
as JSON and does not stringify.

=head2 send

    await $sse->send("Hello world");

Sends a data-only event.

B<Several producers, no queue.> Each send goes to the server at once, and a
server implementing PAGI::Spec::Www 0.7 keeps a stream's sends in the order
they were called ("Sends Are Sequential"), so several producers -- a live
broadcast racing a periodic C<every> callback -- can each call C<send*> or
C<try_send*> directly, with no queue of their own. Cancelling a send's Future
never cancels the send the server holds. On a server reporting an earlier
C<spec_version>, sends must not overlap: serialize the producers yourself.

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

Sends a full SSE event with all fields. C<data> that is an object that
stringifies is sent as its string; any other reference is encoded as JSON;
undef data is refused.

=head2 send_comment

    await $sse->send_comment('heartbeat');

Sends an SSE comment line (C<: heartbeat>). Clients ignore comments, so they
carry no data; they keep an idle connection open through proxies. For
periodic comments, L</keepalive> asks the server to send them for you.

C<send>, C<send_json>, C<send_event>, and C<send_comment> croak (C<"Cannot send
on closed SSE connection">) after terminal notification, including after
L</decline>. While a refusal response has started but the connection is still
live, these methods return C<$self> without emitting an SSE start or data
event.

=head2 try_send, try_send_json, try_send_comment, try_send_event

    my $ok = await $sse->try_send_json($data);
    if (!$ok) {
        # Client disconnected
    }

    $_->try_send_event(event => 'news', data => $item) for @subscribers;

Returns true on success, false on failure. Does not throw.
Useful for broadcasting to multiple clients. Before C<start>, a C<try_send*>
starts the stream, as C<send> does.

A true return is not a delivery receipt. Per the spec, a send to a client
that has disconnected is a silent no-op, so if the client has gone but the
server has not yet noticed, the send no-ops and this still returns true.
"Sent" means "the send call did not fail", not "the client received it".
Clean up in C<on_close>, which runs however the client leaves.

You may make one and drop the returned Future -- the usual shape of a
broadcast loop. The send keeps itself alive until it settles, so it still goes
out even when it must wait behind a send already in flight.

=head1 HANDLERS AND DISCONNECTS

A client can leave at any C<await>, and nothing interrupts your handler when
it does. Choose the send by what a lost message means:

=over 4

=item * B<Strict sends for messages that must arrive.> C<send>, C<send_json>,
C<send_event> and C<send_comment> die once the connection is closing or
closed, and the failure is reported like any other. Use them where a send
that cannot happen is an error worth hearing about.

=item * B<C<try_send*> for setup steps and broadcasts.> They return false
instead of dying once the connection is closing or closed, so a handler can
stop quietly when its client has gone:

    await $sse->start;
    await $sse->keepalive(25);
    return unless await $sse->try_send_event(event => 'welcome', data => $state);

A broadcast to many streams uses them for the same reason: a departed client
cannot end the loop. A true return is not a delivery receipt (see
L</"try_send, try_send_json, try_send_comment, try_send_event">), so cleanup
still belongs in C<on_close>.

=item * B<C<start> and C<keepalive> are already safe.> Once the connection is
closing or closed, or after L</decline>, they return without sending, so they
need no check.

=item * B<Cleanup belongs in C<on_close>.> Register it once the thing it
cleans up exists, before or after C<start>; it runs however the connection
ends, and at once if the client has already gone, so nothing is left behind.

=back

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
it from the pre-start state. Calling C<keepalive> before L</start> is
called does B<not> send anything: it records the interval/comment, and
C<start> arms the recording (sends the real event) once its C<sse.start>
has been sent, where it is legal. A subsequent pre-start call with an
interval of 0 clears the recording instead of arming anything. Once
C<start> has been called -- its C<sse.start> still pending, completed, or
rejected by the server -- C<keepalive> sends at once, after the start in
call order, and drops any recording; a recording made before a start the
server rejected is never armed, so call C<keepalive> again if the helper
carries on. This is transparent to callers --
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
        cleanup_resources();
        log_error("Unexpected disconnect: $reason") if defined $reason;
    });

    # Async callback — return value is awaited automatically
    $sse->on_close(async sub {
        my ($sse, $reason) = @_;
        await cleanup_async($reason);
    });

Registers cleanup to run once, however the connection ends. Register it
when the thing it cleans up exists, before or after C<start>: if the
connection has already ended (a client can leave during C<start>, and it
still returns), the callback runs at once, after any callbacks still running.
Callbacks can be regular subs or async subs — async results are
automatically awaited. Multiple callbacks run in registration order. A
callback that dies does not stop the others; once all have run, the first
failure is reported through L</finished>. A callback that runs after
C<finished> has already resolved has nowhere to report, so its failure is
warned.

Its arguments differ from L<PAGI::WebSocket>'s C<on_close>, which receives
the peer's close code and reason instead of the helper.

Callbacks receive three arguments:

=over 4

=item * C<$sse> - The SSE connection object (same as C<$self>)

=item * C<$reason> - Lifecycle token, or C<undef> for clean completion

=item * C<$detail> - Diagnostic detail, or C<undef>

=back

A callback with a signature must accept all three, for example
C<sub ($sse, $reason, $detail = undef) { ... }>.

Returns C<$self> for chaining.

B<Circular reference note:> If your callback captures the C<$sse> object
in a closure, use the C<$sse> argument instead — it is the same object
but does not create an additional reference cycle. If you must capture
it, use C<Scalar::Util::weaken>:

    use Scalar::Util qw(weaken);
    my $weak_sse = $sse;
    weaken($weak_sse);
    $sse->on_close(sub { $weak_sse->... if $weak_sse });

The connection retains the helper until terminal notification. The helper's
own L<PAGI::FutureOwner> then holds the single worker that runs the hooks,
surviving handler return until cleanup settles and releases the hooks and
helper.

=head2 connection

    my $conn = $sse->connection;

Returns the server-supplied object under C<pagi.connection>. Its interface is
defined by the PAGI specification (L<PAGI::Spec::Www>); callers use those
public methods rather than requiring a particular server's connection class.

For cleanup, use L</on_close>, which runs whenever you register it. The
connection object is there for what the helper does not wrap: the spec's
C<end_future>, C<abort>, and the rest of its interface.

=head2 finished

    await $sse->finished;

Resolves to C<$sse> once the scope has ended and everything the helper started
-- its C<on_close> callbacks, a C<close>, best-effort sends -- has settled. It
fails with the first C<on_close> failure. Routes and
L<PAGI::Endpoint::SSE> await it for you, so their call ends only after the
cleanup has finished, and a shutting-down server waits for it. An application
that constructs the helper itself should C<await $sse-E<gt>finished> before it
returns; otherwise its cleanup is not part of its call, and an C<on_close>
failure is reported nowhere. For a helper never started, C<finished> does
not wait for the scope to end, since that end waits for the application;
its C<on_close> callbacks then run after the application returns.

If the handler dies, C<finished> is not reached: the call fails, and the
server then ends the scope as C<server_error>. The C<on_close> callbacks still
run, but outside the call, so a server shutting down does not wait for them.

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

        await $sse->keepalive(25);

        # Send initial state
        await $sse->send_event(
            event => 'connected',
            data  => { time => time() },
        );

        # Subscribe to metrics
        my $sub_id = subscribe_metrics(sub {
            my ($metrics) = @_;
            $sse->try_send_event(
                event => 'metrics',
                data  => $metrics,
            );
        });

        # Unsubscribe however the stream ends, at once if the client has
        # already gone.
        $sse->on_close(sub {
            my ($sse, $reason) = @_;
            unsubscribe_metrics($sub_id);
            # Log abnormal disconnects for debugging
            warn "SSE client disconnected: $reason"
                if defined $reason;
        });

        await $sse->run;
    }

=head1 SUBCLASSING

A framework may subclass PAGI::SSE (Thunderhorse does). The contract:

=over 4

=item * B<State.> The object holds C<scope>, C<receive> and C<send>, and its
private connection state, every field of which starts with C<_> (C<_state>,
C<_claim>, and the callbacks and the disconnect reason among them). A subclass adds fields under any other name.

=item * B<One object per scope.> Build it once the scope is final, after
the route match and inside the innermost middleware, from the channels the
handler receives, and never replace its C<scope>, C<receive> or C<send>: its
state machine (start, send, close, disconnect) assumes the
same channels for its whole life. C<new> builds a new object on every call
and stores nothing in the scope, so a second C<new> does not find the first:
pass the one object on. Successive route matches over one scope reuse the
object, reading their path parameters live from the scope, written there in
place (see L<PAGI::Request/SUBCLASSING>); a middleware's copy of the scope is
a new scope, and gets a new object. Nothing rebinds an object to another
scope. State a framework gathers earlier in a dispatch belongs on its own
context or in the scope, not on this object.

=item * B<The pattern.> PAGI-FastAPI builds
C<< PAGI::SSE->new($scope, $receive, $send) >> once per connection, after
routing, as Starlette builds its C<WebSocket> (see
L<PAGI::WebSocket/SUBCLASSING>).

=back

=head1 SEE ALSO

L<PAGI::WebSocket> - Similar wrapper for WebSocket connections

L<PAGI::Server> - PAGI protocol server

=head1 AUTHOR

PAGI Contributors

=cut
