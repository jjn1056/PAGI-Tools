use strict; use warnings; use Test::More;
use Time::HiRes ();
use PAGI::Test::ConnectionState;

my $conn = PAGI::Test::ConnectionState->new;
is $conn->is_connected,     1, 'connected initially';
is $conn->response_started, 0, 'not started';
is $conn->disconnect_reason, undef, 'no reason';

$conn->_mark_response_started;
is $conn->response_started, 1, 'started after mark';

my @fired;
$conn->on_complete(sub { push @fired, 'complete' });
$conn->on_disconnect(sub { push @fired, 'disconnect' });
$conn->_mark_complete;
is_deeply \@fired, ['complete'], 'on_complete fires, on_disconnect does not';
is $conn->is_connected,      0, 'completion ends the request (matches production)';
is $conn->disconnect_reason, undef, 'clean completion is not a disconnect';

# on_complete registered after completion fires immediately:
my $late; $conn->on_complete(sub { $late = 1 });
is $late, 1, 'late on_complete fires immediately';
# on_disconnect registered after a clean completion is dropped (never fires, not stored):
my $never; $conn->on_disconnect(sub { $never = 1 });
is $never, undef, 'on_disconnect after clean completion does not fire';

# Abnormal disconnect: fires on_disconnect (with reason), not on_complete.
my $d = PAGI::Test::ConnectionState->new;
my @df;
$d->on_complete(sub { push @df, 'complete' });
$d->on_disconnect(sub { push @df, "disc:$_[0]" });
$d->_mark_disconnected('client_closed');
is_deeply \@df, ['disc:client_closed'], 'on_disconnect fires with reason; on_complete does not';
is $d->disconnect_reason, 'client_closed', 'reason recorded';
my $latecomplete; $d->on_complete(sub { $latecomplete = 1 });
is $latecomplete, undef, 'on_complete after abnormal disconnect is dropped';
is $d->response_started, 0, 'a disconnect before any send leaves response_started 0';

# ---------------------------------------------------------------------------
# B12: disconnect_future is modeled fully (not always undef), mirroring
# production PAGI::Server::ConnectionState -- and response_complete is added.
# ---------------------------------------------------------------------------

# deadline-poll (real wall-clock time, not a fixed number of turns): asserts
# $future is still un-resolved after $seconds have actually elapsed.
sub still_pending_after {
    my ($future, $seconds) = @_;
    my $deadline = Time::HiRes::time() + $seconds;
    while (Time::HiRes::time() < $deadline) {
        return 0 if $future->is_ready;
        Time::HiRes::sleep(0.01);
    }
    return $future->is_ready ? 0 : 1;
}

# (a) requested before any end: a pending Future that resolves with the
# reason on a later abnormal disconnect.
{
    my $c = PAGI::Test::ConnectionState->new;
    my $future = $c->disconnect_future;
    isa_ok $future, 'Future', 'disconnect_future returns a real Future';
    ok !$future->is_ready, 'pending before any end';
    ok still_pending_after($future, 0.2), 'stays pending absent a disconnect';

    $c->_mark_disconnected('client_closed');
    ok $future->is_ready, 'resolves once the abnormal disconnect occurs';
    is $future->get, 'client_closed', 'resolves with the disconnect reason';
}

# (b) requested after an abnormal disconnect already happened: an
# already-resolved Future.
{
    my $c = PAGI::Test::ConnectionState->new;
    $c->_mark_disconnected('server_error');
    my $future = $c->disconnect_future;
    ok $future->is_ready, 'already resolved when requested after the fact';
    is $future->get, 'server_error', 'carries the reason';
}

# (c) the sharpest break: requested for the FIRST time after a clean
# completion -- pending forever, not resolved. (A disconnect_future
# requested BEFORE the completion and left unawaited would, per production,
# also just stay pending -- this covers the first-request-after case, which
# is what the ruling calls out.)
{
    my $c = PAGI::Test::ConnectionState->new;
    $c->_mark_complete;
    my $future = $c->disconnect_future;
    ok !$future->is_ready, 'pending immediately after a clean completion';
    ok still_pending_after($future, 0.2),
        'stays pending forever -- on_complete is the signal for this case, not disconnect_future';
}

# response_complete: undef before terminal, true after.
{
    my $c = PAGI::Test::ConnectionState->new;
    is $c->response_complete, undef, 'undef before the response is complete';
    $c->_mark_response_complete;
    is $c->response_complete, 1, 'true once the response is complete';
}

{
    my $c = PAGI::Test::ConnectionState->new;
    is $c->response_complete, undef, 'undef while only started, not yet complete';
    $c->_mark_response_started;
    is $c->response_complete, undef, 'still undef after response_started alone';
}

done_testing;
