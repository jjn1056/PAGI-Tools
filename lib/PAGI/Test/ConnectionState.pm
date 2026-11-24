package PAGI::Test::ConnectionState;
use strict;
use warnings;
use Future;
use Scalar::Util qw(blessed refaddr weaken);
use PAGI::Test::_Drive;

=head1 NAME

PAGI::Test::ConnectionState - the pagi.connection object provided by PAGI::Test

=head1 DESCRIPTION

PAGI::Test provides the per-scope C<pagi.connection> interface defined by
L<PAGI::Spec::Www/"Connection Object Interface">. Clean completion and abnormal
disconnection are mutually exclusive; C<on_end> observes either outcome.
Terminal facts, including peer WebSocket metadata, are immutable and readable
before notification delivery. HTTP and SSE have no Close metadata.

Client send calls defer terminal callbacks and Future resolution until the
client's next scheduling boundary. The streaming clients expose C<pump> for
tests that drive external Futures without finishing their application.
Standalone state transitions deliver immediately. Late callbacks always run
immediately; each Future observer is cancellation-isolated.

=cut

=head2 new

    my $conn = PAGI::Test::ConnectionState->new(
        websocket => 1,
        on_abort  => sub {
            my ($conn, $detail) = @_;
            ...
        },
    );

Creates a connection state object. Pass a true C<websocket> for a
C<websocket> scope, so that an ending without a peer Close reports close code
1006 as L<PAGI::Spec::Www> requires; omit it for C<http> and C<sse> scopes.
C<on_abort> is an optional test-client transport teardown hook; L</abort>
invokes it at most once, after recording the abnormal outcome required by
L<PAGI::Spec::Www/"Connection Object Interface">.

A scope built by hand for L<PAGI::WebSocket> or L<PAGI::SSE> must carry one
of these as C<pagi.connection>.

=cut

sub new {
    my ($class, %args) = @_;
    return bless {
        _connected          => 1,
        _websocket          => $args{websocket} ? 1 : 0,
        _response_started   => 0,
        _completed          => 0,           # explicit terminal-state flag, like production
        _reason             => undef,
        _detail             => undef,
        _on_abort           => $args{on_abort},
        _disc_cbs           => [],
        _end_cbs            => [],
        _comp_cbs           => [],
        _disconnect_master  => undef,       # private lazy signal; never exposed directly
        _until_end          => {},          # run_until_end calls still pending, by refaddr
    }, $class;
}

sub is_connected      { return $_[0]->{_connected} ? 1 : 0 }
sub response_started  { return $_[0]->{_response_started} ? 1 : 0 }
sub disconnect_reason { return $_[0]->{_reason} }

=head2 disconnect_detail

    my $detail = $conn->disconnect_detail;   # String or undef

Returns the free-text diagnostic for an abnormal end, or C<undef>. The value
is diagnostic only and is never a branching key. See
L<PAGI::Spec::Www/"Connection Object Interface">.

=cut

sub disconnect_detail { return $_[0]->{_detail} }

=head2 response_complete

    my $done = $conn->response_complete;   # 0 or 1, always defined

True (C<1>) once this request reaches its clean completed terminal state;
false (C<0>) while active and after an abnormal end. This mock always tracks
completion and therefore always returns a defined boolean. See
L<PAGI::Spec::Www/"Connection Object Interface">.

=cut

sub response_complete { return $_[0]->{_completed} ? 1 : 0 }

# Server-internal: the test client installs the teardown hook after the
# handler that owns the transport exists.
sub _set_abort_hook { $_[0]->{_on_abort} = $_[1]; return }

=head2 disconnect_future

    my $future = $conn->disconnect_future;  # always a Future
    my $reason = await $future;

Returns a fresh cancellation-isolated Future observer that resolves, with the
reason, on an B<abnormal> disconnect; stays pending forever after a B<clean>
completion (use C<end_future> to observe that case instead). One private
master Future is created lazily on first call, exactly like production
L<PAGI::Server::ConnectionState>, and every call returns a new
C<without_cancel> observer so cancelling one race cannot cancel the master or
later observers:

=over 4

=item * B<connected> -- a fresh, pending Future is returned; it resolves
later if C<_mark_disconnected> occurs.

=item * B<disconnected (abnormal)> -- a Future already resolved with the
disconnect reason is returned.

=item * B<completed (clean)> -- a Future is returned and left pending
forever; the completion already happened and was not a disconnect, so there
is nothing for it to resolve with. This is the sharpest divergence from a
naive "always returns a Future" implementation: calling this for the first
time after a clean completion does B<not> retroactively synthesize a
disconnect.

=back

=cut

sub disconnect_future {
    my ($self) = @_;

    my $master = $self->{_disconnect_master} ||= Future->new;

    # Resolve immediately only for an already-abnormal end. A clean
    # completion leaves this pending forever -- on_complete is the signal
    # for that case.
    if (!$self->{_connected} && !$self->{_completed} && !$self->{_notifications_pending} && !$master->is_ready) {
        $master->done($self->{_reason});
    }

    return $master->without_cancel;
}

=head2 close_code / close_reason

The peer's WebSocket Close metadata, undefined until observed. An empty peer
Close is 1005 with undefined reason; an abnormal accepted WebSocket end
without a peer Close is 1006 with undefined reason.

=head2 on_end

    $conn->on_end(sub { my ($reason, $detail) = @_; ... });

Runs once for either terminal outcome. Both arguments are undefined after
clean completion. Exceptions are isolated just as for C<on_disconnect>.

=head2 end_future

    my $reason = await $conn->end_future;

Resolves with one value: the abnormal reason token, or C<undef> for a clean
end. Each call returns an independent cancellation-isolated observer.

=cut

sub close_code { return $_[0]->{_close_code} }
sub close_reason { return $_[0]->{_close_reason} }

sub _set_peer_close {
    my ($self, $code, $reason) = @_;
    return unless $self->{_connected};
    $self->{_close_code} = $code;
    $self->{_close_reason} = $reason;
}

# A send the scope could no longer carry. Run in run_until_end, work makes at
# most one send after the end before it is cancelled, so the third warns,
# once: the work was not run that way and kept going after the client left.
sub _discarded_send {
    my ($self) = @_;
    return if ++$self->{_discarded_sends} != 3;
    warn "PAGI application kept sending after the scope ended; run its work in "
        . "\$scope->{'pagi.connection'}->run_until_end (PAGI::Spec::Www, "
        . "\"Example: Work That Stops When the Client Leaves\")\n";
    return;
}

sub end_future {
    my ($self) = @_;
    my $master = $self->{_end_master} ||= Future->new;
    $master->done($self->{_reason})
        if !$self->{_connected} && !$self->{_notifications_pending} && !$master->is_ready;
    return $master->without_cancel;
}

=head2 run_until_end

    my ($finished) = await $conn->run_until_end(async sub {
        ...;            # the work
        return 1;
    });
    return unless $finished;    # the client left first

Runs the work C<$code> returns while the scope is open, as
L<PAGI::Spec::Www/"Connection Object Interface"> defines it. It resolves with
the work's results when the work finishes, and with an empty list when the
scope ends first, the work cancelled before it resolves. It fails with the
work's failure, with the exception when C<$code> dies, when C<$code> returns
something that is not a Future, and when something other than the scope's end
cancels the work. On a scope that has already ended, C<$code> is not called
and the call resolves on a later turn. If C<$code> ends the scope itself, a
Future it returns already settled keeps its outcome. Cancelling the returned
Future cancels the work and leaves the scope alone.

=cut

my $UNTIL_END_NOT_A_FUTURE = "run_until_end's callback must return a Future, the work to stop when the scope ends (an async sub returns one)\n";
my $UNTIL_END_CANCELLED    = "the work given to run_until_end was cancelled while the scope was still open\n";

sub run_until_end {
    my ($self, $code) = @_;
    return _until_end_later() unless $self->{_connected};

    my $work;
    eval { $work = $code->(); 1 } or return Future->fail($@);
    return Future->fail($UNTIL_END_NOT_A_FUTURE) unless blessed($work) && $work->isa('Future');

    # Work already settled keeps its outcome, even when $code ended the scope.
    return _until_end_outcome($work) if $work->is_ready;

    # $code ended the scope and left the work pending: the end cancels it.
    unless ($self->{_connected}) {
        $work->cancel;
        return _until_end_later();
    }

    my $result = Future->new;
    my $id     = refaddr $result;
    $self->{_until_end}{$id} = { work => $work, result => $result };

    weaken(my $weak_self = $self);
    $work->on_ready(sub {
        return unless $weak_self && delete $weak_self->{_until_end}{$id};
        _until_end_outcome($work)->on_ready($result);
    });
    $result->on_cancel(sub {
        return unless $weak_self && delete $weak_self->{_until_end}{$id};
        $work->cancel;
    });
    return $result;
}

sub _until_end_outcome {
    my ($work) = @_;
    return Future->fail($UNTIL_END_CANCELLED) if $work->is_cancelled;
    return Future->fail($work->failure)        if $work->is_failed;
    return Future->done($work->get);
}

# An empty list on a later turn, as a server resolves it.
sub _until_end_later { return PAGI::Test::_Drive::next_turn()->then(sub { Future->done }) }

sub on_end {
    my ($self, $cb) = @_;
    if (!$self->{_connected}) {
        _fire($cb, $self->{_reason}, $self->{_detail});
        return;
    }
    push @{$self->{_end_cbs}}, $cb;
    return;
}

# Test-client scheduling: facts change immediately; client boundaries drain
# notifications deferred while an application send is on the stack.
sub _deliver_notifications {
    my ($self) = @_;
    return if $self->{_defer_notifications};
    return unless delete $self->{_notifications_pending};

    # Pending run_until_end work is cancelled before anyone resumes; the calls
    # resolve last, with an empty list.
    my @until_end = values %{ $self->{_until_end} };
    $self->{_until_end} = {};
    $_->{work}->cancel for @until_end;

    my @disc = @{delete $self->{_disc_cbs} || []};
    my @comp = @{delete $self->{_comp_cbs} || []};
    my @end = @{delete $self->{_end_cbs} || []};
    if (!$self->{_completed}) {
        $self->{_disconnect_master}->done($self->{_reason})
            if $self->{_disconnect_master} && !$self->{_disconnect_master}->is_ready;
        $self->{_end_master}->done($self->{_reason})
            if $self->{_end_master} && !$self->{_end_master}->is_ready;
        _fire($_, $self->{_reason}, $self->{_detail}) for @disc;
    }
    else { _fire($_) for @comp; }
    _fire($_, $self->{_reason}, $self->{_detail}) for @end;
    $self->{_end_master}->done($self->{_reason})
        if $self->{_end_master} && !$self->{_end_master}->is_ready;
    $_->{result}->done for @until_end;
    return;
}

# Late registration fires immediately for the terminal state that occurred —
# distinguished by _completed (clean) vs a set _reason (abnormal), like production.
# Invoke a callback the way production does: isolate failures so one bad
# callback does not prevent the others from running.
sub _fire {
    my ($cb, @args) = @_;
    eval { $cb->(@args); 1 } or warn "pagi.connection callback error: $@";
    return;
}

=head2 on_disconnect

    $conn->on_disconnect(sub {
        my ($reason, $detail) = @_;
        ...
    });

Registers a callback for an abnormal end. It receives the stable reason token
and the diagnostic L</disconnect_detail>, including when registered after the
transition. A callback registered after clean completion does not run. See
L<PAGI::Spec::Www/"Connection Object Interface">.

=cut

sub on_disconnect {
    my ($self, $cb) = @_;
    if (!$self->{_connected}) {                       # terminal: never store, fire only if abnormal
        _fire($cb, $self->{_reason}, $self->{_detail}) unless $self->{_completed};
        return;
    }
    push @{$self->{_disc_cbs}}, $cb;                   # still in flight: register
    return;
}

sub on_complete {
    my ($self, $cb) = @_;
    if (!$self->{_connected}) {                       # terminal: never store, fire only if clean
        _fire($cb) if $self->{_completed};
        return;
    }
    push @{$self->{_comp_cbs}}, $cb;
    return;
}

# Server-internal (the test client, acting as server, calls these).
sub _mark_response_started { $_[0]->{_response_started} = 1; return }

sub _mark_complete {
    my ($self) = @_;
    return unless $self->{_connected};
    if ($self->{_websocket} && !defined $self->{_close_code}) {
        $self->{_close_code} = 1006;
        $self->{_close_reason} = undef;
    }
    $self->{_connected} = 0;
    $self->{_completed} = 1;                 # clean completion (distinguishes from disconnect)
    delete $self->{_on_abort};
    $self->{_notifications_pending} = 1;
    $self->_deliver_notifications;
    return;
}

sub _mark_disconnected {
    my ($self, $reason, $detail) = @_;
    return unless $self->{_connected};
    $self->{_connected}         = 0;
    $self->{_reason}            = $reason // 'unknown';   # coerce like production
    $self->{_detail}            = $detail;
    # A WebSocket without a peer Close ends with RFC 6455 1006.
    if ($self->{_websocket} && !defined $self->{_close_code}) {
        $self->{_close_code} = 1006;
        $self->{_close_reason} = undef;
    }
    delete $self->{_on_abort};
    $self->{_notifications_pending} = 1;
    $self->_deliver_notifications;
    return;
}

=head2 abort

    $conn->abort($detail);

Ends this test scope abnormally with reason C<app_abort>, records C<$detail>
as L</disconnect_detail>, and invokes the optional constructor C<on_abort>
hook as C<< $hook->($conn, $detail) >>. It is synchronous, idempotent, and a
no-op after either terminal outcome. See
L<PAGI::Spec::Www/"Connection Object Interface">.

=cut

sub abort {
    my ($self, $detail) = @_;
    return unless $self->{_connected};

    my $hook = delete $self->{_on_abort};
    $self->_mark_disconnected('app_abort', $detail);
    $hook->($self, $detail) if $hook;
    return;
}


# A failure's detail, as PAGI::Server records it: the first line, without
# Perl's " at FILE line N." tail.
sub _detail_from_error {
    my ($error) = @_;
    my ($first) = split /\n/, ($error // '');
    return undef unless defined $first;
    $first =~ s/ at \S+ line \d+\.?\s*\z//;
    $first =~ s/\s+\z//;
    return length $first ? $first : undef;
}

1;
