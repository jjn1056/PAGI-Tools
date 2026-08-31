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
(C<is_connected>, C<disconnect_reason>, C<disconnect_future>,
C<on_disconnect>, C<on_complete>) plus C<response_started> and
C<response_complete>, mirroring production C<PAGI::Server::ConnectionState>:
a clean completion ends the request and fires C<on_complete> but is not a
disconnect; exactly one of C<on_complete> / C<on_disconnect> fires.
C<disconnect_future> is modeled fully, not left always-C<undef> -- see
L</disconnect_future> below for how its behavior differs from production only
in that this test double can actually resolve it.

=cut

sub new {
    my ($class) = @_;
    return bless {
        _connected          => 1,
        _response_started   => 0,
        _response_complete  => 0,
        _completed          => 0,           # explicit terminal-state flag, like production
        _reason             => undef,
        _disc_cbs           => [],
        _comp_cbs           => [],
        _disconnect_master  => undef,       # private lazy signal; never exposed directly
    }, $class;
}

sub is_connected      { return $_[0]->{_connected} ? 1 : 0 }
sub response_started  { return $_[0]->{_response_started} ? 1 : 0 }
sub disconnect_reason { return $_[0]->{_reason} }

=head2 response_complete

    my $done = $conn->response_complete;   # 0 or 1, always defined

True (C<1>) once this request's HTTP response has reached its legal terminal
state (the terminal body chunk, or trailers if declared -- the same instant
L<PAGI::SendValidation/complete> reports true for the scope); false (C<0>)
before that (streaming, or not yet started). Per L<PAGI::Spec::Www>'s
"Connection State" section, C<undef> is not a per-request progress value --
it signals a fixed B<capability>: "C<undef> if the server does not track
completion" at all. This mock always tracks completion, so
C<response_complete> is B<always defined> for the whole request, unlike
production L<PAGI::Server::ConnectionState>, whose C<response_complete>
always returns C<undef> because a real socket server cannot always pin down
the exact instant the last byte reached the client -- production's C<undef>
there is exactly that capability signal, correctly constant across the
request. (Test C<defined> before relying on this against an arbitrary PAGI
server, since not every server tracks it -- but against this mock, it will
always be true.)

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

sub on_disconnect {
    my ($self, $cb) = @_;
    if (!$self->{_connected}) {                       # terminal: never store, fire only if abnormal
        _fire($cb, $self->{_reason}) unless $self->{_completed};
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
    _fire($_) for @{$self->{_comp_cbs}};
    @{$self->{_comp_cbs}} = ();
    @{$self->{_disc_cbs}} = ();
    return;
}

sub _mark_disconnected {
    my ($self, $reason) = @_;
    return unless $self->{_connected};
    $self->{_connected} = 0;
    $self->{_reason}    = $reason // 'unknown';   # coerce like production
    if ($self->{_disconnect_master} && !$self->{_disconnect_master}->is_ready) {
        $self->{_disconnect_master}->done($self->{_reason});
    }
    _fire($_, $self->{_reason}) for @{$self->{_disc_cbs}};
    @{$self->{_disc_cbs}} = ();
    @{$self->{_comp_cbs}} = ();
    return;
}

1;
