use strict; use warnings; use Test::More;
use Future;
use Scalar::Util qw(refaddr);
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

subtest 'completion preserves WebSocket Close metadata and terminal outcome' => sub {
    my $http = PAGI::Test::ConnectionState->new;
    $http->_mark_complete;
    is_deeply [$http->close_code, $http->close_reason], [undef, undef],
        'ordinary non-WebSocket completion has no Close metadata';

    my $peer = PAGI::Test::ConnectionState->new(websocket => 1);
    $peer->_set_peer_close(1000, 'bye');
    $peer->_mark_complete;
    is_deeply [$peer->close_code, $peer->close_reason], [1000, 'bye'],
        'supplied peer Close survives clean completion';

    my $c = PAGI::Test::ConnectionState->new(websocket => 1);
    my ($complete, $end) = (0, 0);
    $c->on_complete(sub { ++$complete });
    $c->on_end(sub { ++$end });
    $c->_mark_disconnected('client_closed');
    $c->_mark_complete;
    $c->_mark_complete;
    is_deeply [$c->close_code, $c->close_reason, $c->disconnect_reason,
               $c->response_complete ? 1 : 0, $complete, $end],
              [1006, undef, 'client_closed', 0, 0, 1],
              'late completion cannot replace abnormal termination';

    my $refusal = PAGI::Test::ConnectionState->new(websocket => 1);
    my ($refusal_complete, $refusal_end) = (0, 0);
    $refusal->on_complete(sub { ++$refusal_complete });
    $refusal->on_end(sub { ++$refusal_end });
    $refusal->_mark_complete;
    $refusal->_mark_complete;
    is_deeply [$refusal->close_code, $refusal->close_reason,
               $refusal->disconnect_reason, $refusal->response_complete,
               $refusal_complete, $refusal_end],
              [1006, undef, undef, 1, 1, 1],
              'WebSocket completion records no-peer metadata and notifies once';
};

# (b) requested after an abnormal disconnect already happened: an
# already-resolved Future.
{
    my $c = PAGI::Test::ConnectionState->new;
    $c->_mark_disconnected('server_error');
    my $future = $c->disconnect_future;
    ok $future->is_ready, 'already resolved when requested after the fact';
    is $future->get, 'server_error', 'carries the reason';
}

# (c) every call returns a cancellation-isolated observer. A wait_any race
# cancels its losing observer; it must not cancel the connection's private
# disconnect signal or a later observer created for the next race.
{
    my $c = PAGI::Test::ConnectionState->new;
    my $work = Future->done('work');
    my $first_observer = $c->disconnect_future;

    is(Future->wait_any($work, $first_observer)->get, 'work',
        'work wins the race');
    ok $first_observer->is_cancelled,
        'wait_any cancels only its losing observer';

    my $fresh_observer = $c->disconnect_future;
    isnt refaddr($fresh_observer), refaddr($first_observer),
        'the next accessor call returns a fresh observer';
    ok !$fresh_observer->is_ready,
        'the fresh observer remains pending before disconnect';

    $c->_mark_disconnected('client_closed');
    is $fresh_observer->get, 'client_closed',
        'the later disconnect resolves the fresh observer';
    ok $first_observer->is_cancelled,
        'the first losing observer remains cancelled';
}

# (d) the sharpest break: requested for the FIRST time after a clean
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

# response_complete: this mock DOES track completion, so per Www.pod
# (definedness signals CAPABILITY, a constant property -- "undef if the
# server does not track completion" -- not a per-request lifecycle state),
# response_complete must be defined for the entire request: 0 before/while
# streaming, 1 once complete. It must never itself be undef.
{
    my $c = PAGI::Test::ConnectionState->new;
    ok defined $c->response_complete, 'defined before the response starts (this mock always tracks completion)';
    is $c->response_complete, 0, '0 before the response is complete';
    $c->_mark_complete;
    ok defined $c->response_complete, 'still defined once complete';
    is $c->response_complete, 1, '1 once the response is complete';
}

{
    my $c = PAGI::Test::ConnectionState->new;
    $c->_mark_response_started;
    ok defined $c->response_complete, 'defined while only started, not yet complete';
    is $c->response_complete, 0, 'still 0 after response_started alone (streaming, not complete)';
}

subtest 'disconnect_detail and two-argument on_disconnect' => sub {
    my $cs = PAGI::Test::ConnectionState->new;
    my @got;
    $cs->on_disconnect(sub { push @got, [@_] });
    is $cs->disconnect_detail, undef, 'undef while active';
    $cs->_mark_disconnected('keepalive_timeout', 'no pong within 10s');
    is $cs->disconnect_detail, 'no pong within 10s', 'accessor';
    is_deeply \@got, [['keepalive_timeout', 'no pong within 10s']],
        'callback arguments';
    my @late;
    $cs->on_disconnect(sub { push @late, [@_] });
    is_deeply \@late, [['keepalive_timeout', 'no pong within 10s']],
        'late registration';
};

subtest 'abort: hook once, app_abort with detail, idempotent, no-op after completion' => sub {
    my @hook;
    my $cs = PAGI::Test::ConnectionState->new(on_abort => sub { push @hook, [@_] });
    my @cb;
    $cs->on_disconnect(sub { push @cb, [@_] });
    my $f = $cs->disconnect_future;
    $cs->abort('quota');
    is scalar @hook, 1, 'hook once';
    is $hook[0][1], 'quota', 'hook detail';
    is $cs->disconnect_reason, 'app_abort', 'token';
    is $cs->disconnect_detail, 'quota', 'detail';
    is $cs->response_complete, 0, 'abnormal terminal is not response complete';
    ok $f->is_ready, 'future resolved';
    is_deeply \@cb, [['app_abort', 'quota']], 'callback';
    $cs->abort('again');
    is scalar @hook, 1, 'idempotent';

    my $done = PAGI::Test::ConnectionState->new(on_abort => sub { push @hook, 'never' });
    $done->_mark_complete;
    $done->abort('late');
    is scalar @hook, 1, 'no hook after completion';
    is $done->response_complete, 1, 'completion preserved';
    is $done->disconnect_reason, undef, 'clean outcome preserved';
    is $done->disconnect_detail, undef, 'clean completion has no detail';
};

done_testing;
