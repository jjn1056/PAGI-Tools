use strict; use warnings; use Test2::V0; use Future::AsyncAwait;
use Time::HiRes ();
use PAGI::Test::Client;

# ---------------------------------------------------------------------------
# B5: PAGI::Test::WebSocket delivers the synthesized websocket.disconnect
# exactly once (carrying truthful code AND reason), then leaves further
# receive() calls permanently pending -- a hang is the correct diagnosis for
# an app that keeps calling receive() after disconnect, exactly like a real
# transport gone silent.
# ---------------------------------------------------------------------------

# helper: await a send, trapping a failure without dying the app
async sub try_send {
    my ($send, $event) = @_;
    my $err;
    eval { await $send->($event); 1 } or do { $err = $@ };
    return $err;
}

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

subtest 'B5(a): peer(test) close delivers exactly one disconnect, then hangs' => sub {
    my (@received, $pending_future);
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->(); # websocket.connect
        await $send->({ type => 'websocket.accept' });
        push @received, await $receive->();     # resolves once close() runs
        $pending_future = $receive->();          # must NOT be awaited: would hang forever
    };

    my $client = PAGI::Test::Client->new(app => $app);
    my $ws = $client->websocket('/ws');
    $ws->close(1000, 'bye');

    is scalar(@received), 1, 'exactly one disconnect delivered to the app';
    is $received[0]{type}, 'websocket.disconnect', 'disconnect event type';
    is $received[0]{code}, 1000, 'disconnect carries the close code';
    is $received[0]{reason}, 'bye', 'disconnect carries the close reason';

    ok defined $pending_future, 'app captured a second receive Future';
    ok !$pending_future->is_ready, 'second receive is not ready immediately';
    ok still_pending_after($pending_future, 0.2),
        'second receive stays pending after a deadline-poll budget';
};

subtest 'B5(b): app-initiated close echoes the app\'s own code/reason' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->(); # websocket.connect
        await $send->({ type => 'websocket.accept' });
        await $receive->(); # trigger message from the test
        await $send->({ type => 'websocket.close', code => 4001, reason => 'app decided to close' });
    };

    my $client = PAGI::Test::Client->new(app => $app);
    my $ws = $client->websocket('/ws');
    $ws->send_text('trigger');

    ok $ws->is_closed, 'connection reports closed';
    is $ws->close_code, 4001, 'close_code echoes the app\'s own value';
    is $ws->close_reason, 'app decided to close', 'close_reason echoes the app\'s own value';
};

subtest 'B5(b): simulate_abnormal_close delivers exactly the injected code/reason, once' => sub {
    my (@received, $pending_future);
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->(); # websocket.connect
        await $send->({ type => 'websocket.accept' });
        push @received, await $receive->();
        $pending_future = $receive->();
    };

    my $client = PAGI::Test::Client->new(app => $app);
    my $ws = $client->websocket('/ws');
    $ws->simulate_abnormal_close(code => 1006, reason => 'keepalive_timeout');

    is scalar(@received), 1, 'exactly one disconnect delivered';
    is $received[0]{type}, 'websocket.disconnect', 'disconnect event type';
    is $received[0]{code}, 1006, 'injected code delivered';
    is $received[0]{reason}, 'keepalive_timeout', 'injected reason delivered';
    ok !$pending_future->is_ready, 'further receive stays pending';

    ok $ws->is_closed, 'connection object reports closed';
    is $ws->close_code, 1006, 'close_code reflects the injected abnormal close';
    is $ws->close_reason, 'keepalive_timeout', 'close_reason reflects the injected abnormal close';
};

# ---------------------------------------------------------------------------
# B6: post-app-close sends fail the send Future (server-shaped) and never
# reach the client's readable stream; a send after the PEER (test) closed is
# a tolerated no-op instead -- both halves of the spec split.
# ---------------------------------------------------------------------------

subtest 'B6: send after app-sent close fails the Future, never reaches the client' => sub {
    my $send_err;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->(); # websocket.connect
        await $send->({ type => 'websocket.accept' });
        await $send->({ type => 'websocket.close', code => 1000, reason => 'done' });
        $send_err = await try_send($send, { type => 'websocket.send', text => 'too late' });
    };

    my $client = PAGI::Test::Client->new(app => $app);
    my $ws = $client->websocket('/ws');

    ok $send_err, 'send after app-sent close failed the Future';
    like $send_err, qr/close/i, 'error names the close';
    is $ws->receive_text(0.1), undef, 'nothing reached the client stream';
};

subtest 'B6: send after peer(test)-close is a tolerated no-op, not a Future failure' => sub {
    my ($sent_ok, $send_err);
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->(); # websocket.connect
        await $send->({ type => 'websocket.accept' });
        await $receive->(); # resolves with the peer's disconnect
        $send_err = await try_send($send, { type => 'websocket.send', text => 'after peer close' });
        $sent_ok = 1 unless $send_err;
    };

    my $client = PAGI::Test::Client->new(app => $app);
    my $ws = $client->websocket('/ws');
    $ws->close(1000, 'peer closed');

    ok $sent_ok, 'the send Future resolved (no-op), did not fail';
    ok !$send_err, 'no error raised';
    is $ws->receive_text(0.1), undef, 'nothing reached the client stream: the write was silently dropped';
};

# ---------------------------------------------------------------------------
# B8: app sends close-before-accept -- treated as a portable denial, not a
# crash: no croak, connection object reports the denied/closed state.
# ---------------------------------------------------------------------------

subtest 'B8: close-before-accept is treated as a portable denial, not a crash' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->(); # websocket.connect
        await $send->({ type => 'websocket.close', code => 4003, reason => 'denied' });
    };

    my $client = PAGI::Test::Client->new(app => $app);
    my $ws;
    ok lives { $ws = $client->websocket('/ws') }, 'no croak for close-before-accept denial'
        or note $@;
    ok $ws->is_closed, 'connection object reports the denied state';
    is $ws->close_code, 4003, 'denial close code recorded';
    is $ws->close_reason, 'denied', 'denial close reason recorded';
};

done_testing;
