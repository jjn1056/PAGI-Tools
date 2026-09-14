package PAGI::Test::ConnectionState;
use strict;
use warnings;
use Future;

=head1 NAME

PAGI::Test::ConnectionState - the pagi.connection object provided by PAGI::Test

=head1 DESCRIPTION

PAGI::Test is a test server, so it provides the per-request C<pagi.connection>
object. It implements the full connection surface to which L<PAGI::Request>
delegates
(C<is_connected>, C<disconnect_reason>, C<disconnect_detail>,
C<disconnect_future>, C<on_disconnect>, C<on_complete>, C<abort>) plus
C<response_started> and C<response_complete>, mirroring production
C<PAGI::Server::ConnectionState>:
a clean completion ends the request and fires C<on_complete> but is not a
disconnect; exactly one of C<on_complete> / C<on_disconnect> fires.
C<disconnect_future> is modeled fully, not left always-C<undef> -- see
L</disconnect_future> below for how its behavior differs from production only
in that this test double can actually resolve it.

=cut

=head2 new

    my $conn = PAGI::Test::ConnectionState->new(
        on_abort => sub {
            my ($conn, $detail) = @_;
            ...
        },
    );

Creates a connection state object. C<on_abort> is an optional test-client
transport teardown hook; L</abort> invokes it at most once, after recording
the abnormal outcome required by
L<PAGI::Spec::Www/"Connection Object Interface">.

=cut

sub new {
    my ($class, %args) = @_;
    return bless {
        _connected          => 1,
        _response_started   => 0,
        _response_complete  => 0,
        _completed          => 0,           # explicit terminal-state flag, like production
        _reason             => undef,
        _detail             => undef,
        _on_abort           => $args{on_abort},
        _disc_cbs           => [],
        _comp_cbs           => [],
        _disconnect_master  => undef,       # private lazy signal; never exposed directly
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

sub response_complete { return $_[0]->{_response_complete} ? 1 : 0 }

# Server-internal: called from the send path once the response reaches its
# legal terminal state (mirrors _mark_response_started's shape).
sub _mark_response_complete { $_[0]->{_response_complete} = 1; return }

=head2 disconnect_future

    my $future = $conn->disconnect_future;  # always a Future
    my $reason = await $future;

Returns a fresh cancellation-isolated Future observer that resolves, with the
reason, on an B<abnormal> disconnect; stays pending forever after a B<clean>
completion (use C<on_complete> to observe that case instead). One private
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
    if (!$self->{_connected} && !$self->{_completed} && !$master->is_ready) {
        $master->done($self->{_reason});
    }

    return $master->without_cancel;
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
    $self->{_connected} = 0;
    $self->{_completed} = 1;                 # clean completion (distinguishes from disconnect)
    $self->{_response_complete} = 1;
    _fire($_) for @{$self->{_comp_cbs}};
    @{$self->{_comp_cbs}} = ();
    @{$self->{_disc_cbs}} = ();
    delete $self->{_on_abort};
    return;
}

sub _mark_disconnected {
    my ($self, $reason, $detail) = @_;
    return unless $self->{_connected};
    $self->{_connected}         = 0;
    $self->{_reason}            = $reason // 'unknown';   # coerce like production
    $self->{_detail}            = $detail;
    $self->{_response_complete} = 0;
    if ($self->{_disconnect_master} && !$self->{_disconnect_master}->is_ready) {
        $self->{_disconnect_master}->done($self->{_reason});
    }
    _fire($_, $self->{_reason}, $self->{_detail}) for @{$self->{_disc_cbs}};
    @{$self->{_disc_cbs}} = ();
    @{$self->{_comp_cbs}} = ();
    delete $self->{_on_abort};
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

1;
