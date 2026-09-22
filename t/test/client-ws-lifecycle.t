use strict; use warnings; use Test2::V0; use Future::AsyncAwait;
use PAGI::Test::Client;
use PAGI::Pages;
use PAGI::Response qw(text_response);
use PAGI::WebSocket;

async sub try_send {
    my ($send, $event) = @_;
    my $err;
    eval { await $send->($event); 1 } or do { $err = $@ };
    return $err;
}

subtest 'peer close is clean, preserves Close metadata, and repeats the end event' => sub {
    my (@order, @received, $conn);
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $conn = $scope->{'pagi.connection'};
        $conn->on_complete(sub { push @order, 'complete' });
        $conn->on_disconnect(sub { push @order, 'disconnect' });
        await $receive->();
        await $send->({ type => 'websocket.accept' });

        # Explicit tripwire: exercise repeated end delivery without an
        # unbounded receive loop in case the implementation is still stale.
        for my $attempt (1 .. 2) {
            push @received, await $receive->();
            push @order, 'receive:' . ($conn->response_complete ? 'complete' : 'incomplete');
        }
    };

    my $ws = PAGI::Test::Client->new(app => $app)->websocket('/ws');
    $ws->close(1000, 'bye');

    is scalar(@received), 2, 'pending and subsequent receives both resolve';
    is $received[0], {
        type => 'websocket.disconnect', code => 1000, reason => 'bye',
    }, 'first receive carries peer Close metadata';
    is $received[1], $received[0], 'subsequent receive repeats the end event';
    is \@order, ['complete', 'receive:complete', 'receive:complete'],
        'clean state transition and callback happen before receives wake';
    is $conn->disconnect_reason, undef, 'peer Close is protocol metadata, not an abnormal reason';
    is $ws->close_code, 1000, 'client object preserves peer Close code';
    is $ws->close_reason, 'bye', 'client object preserves peer Close text';
};

subtest 'app close is complete before send returns and exposes the handshake end' => sub {
    my ($conn, @received);
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $conn = $scope->{'pagi.connection'};
        await $receive->();
        await $send->({ type => 'websocket.accept' });
        await $send->({ type => 'websocket.close', code => 4001, reason => 'done' });
        die 'terminal send did not complete scope' unless $conn->response_complete;
        push @received, await $receive->();
    };

    my $ws = PAGI::Test::Client->new(app => $app)->websocket('/ws');

    ok $ws->is_closed, 'connection reports closed';
    is $ws->close_code, 4001, 'client sees app close code';
    is $ws->close_reason, 'done', 'client sees app close reason';
    is $received[0], {
        type => 'websocket.disconnect', code => 4001, reason => 'done',
    }, 'receive after app close reports completed handshake';
};

subtest 'abnormal transport close updates state before every receive wakes' => sub {
    my ($conn, @order, @received);
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $conn = $scope->{'pagi.connection'};
        $conn->on_disconnect(sub { push @order, "callback:$_[0]" });
        await $receive->();
        await $send->({ type => 'websocket.accept' });
        for my $attempt (1 .. 2) {
            push @received, await $receive->();
            push @order, 'receive:' . ($conn->disconnect_reason // 'none');
        }
    };

    my $ws = PAGI::Test::Client->new(app => $app)->websocket('/ws');
    $ws->simulate_abnormal_close(code => 1006, reason => 'keepalive_timeout');

    is \@order, [
        'callback:keepalive_timeout',
        'receive:keepalive_timeout',
        'receive:keepalive_timeout',
    ], 'disconnect state and callback precede receive delivery';
    is $received[0], {
        type => 'websocket.disconnect', code => 1006, reason => 'keepalive_timeout',
    }, 'abnormal end event';
    is $received[1], $received[0], 'abnormal end event repeats';
    is $conn->response_complete, 0, 'abnormal end is incomplete';
};

subtest 'abort tears down the transport and wakes pending and later receives' => sub {
    my ($conn, @received);
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $conn = $scope->{'pagi.connection'};
        await $receive->();
        await $send->({ type => 'websocket.accept' });
        for my $attempt (1 .. 2) {
            push @received, await $receive->();
        }
    };

    my $ws = PAGI::Test::Client->new(app => $app)->websocket('/ws');
    $conn->abort('quota exceeded');

    ok $ws->is_closed, 'abort closes the test transport';
    is $conn->disconnect_reason, 'app_abort', 'abort reason';
    is $conn->disconnect_detail, 'quota exceeded', 'abort detail';
    is $received[0], {
        type => 'websocket.disconnect', code => 1006, reason => 'app_abort',
    }, 'pending receive wakes with app_abort';
    is $received[1], $received[0], 'later receive gets the same end event';
};

subtest 'send after peer close is a tolerated no-op' => sub {
    my ($sent_ok, $send_err);
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->();
        await $send->({ type => 'websocket.accept' });
        await $receive->();
        $send_err = await try_send($send, { type => 'websocket.send', text => 'after peer close' });
        $sent_ok = 1 unless $send_err;
    };

    my $ws = PAGI::Test::Client->new(app => $app)->websocket('/ws');
    $ws->close(1000, 'peer closed');

    ok $sent_ok, 'send Future resolved';
    ok !$send_err, 'send did not fail';
    is $ws->receive_text(0.1), undef, 'no message reached the closed client stream';
};

subtest 'ordinary HTTP refusal returns a WebSocket object with a decoded response' => sub {
    my ($conn, @after_end);
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $conn = $scope->{'pagi.connection'} or die 'no connection object';
        await $receive->();
        await $send->({
            type => 'http.response.start',
            status => 401,
            headers => [['www-authenticate', 'Bearer']],
        });
        await $send->({ type => 'http.response.body', body => 'nope', more => 0 });
        die 'terminal refusal send did not complete scope' unless $conn->response_complete;
        for my $attempt (1 .. 2) {
            push @after_end, await $receive->();
        }
    };

    my $ws = PAGI::Test::Client->new(app => $app)->websocket('/ws');

    ok $ws->refused, 'refused';
    isa_ok $ws->response, ['PAGI::Test::Response'];
    is $ws->response->status, 401, 'status';
    is $ws->response->header('www-authenticate'), 'Bearer', 'headers';
    is $ws->response->content, 'nope', 'body';
    is $ws->close_code, undef, 'client wire Close accessor remains unset for an HTTP refusal';
    is \@after_end, [
        { type => 'http.disconnect' },
        { type => 'http.disconnect' },
    ], 'receives after completed refusal report the HTTP end';
};

subtest 'production helper observes clean refusal completion metadata' => sub {
    my ($conn, @closed, @complete, @ended);
    my $disconnected = 0;
    my $client = PAGI::Test::Client->new(app => async sub {
        my ($scope, $receive, $send) = @_;
        $conn = $scope->{'pagi.connection'};
        $conn->on_complete(sub { push @complete, $conn->close_code });
        $conn->on_end(sub { push @ended, $conn->close_code });
        $conn->on_disconnect(sub { ++$disconnected });
        my $ws = PAGI::WebSocket->new($scope, $receive, $send);
        $ws->on_close(sub { push @closed, [@_]; return });
        await $ws->deny(text_response('Access denied', status => 403));
    });
    my $session = $client->websocket('/ws');
    ok $session->refused, 'handshake refused';
    is $session->response->status, 403, 'HTTP status preserved';
    is $session->response->content, 'Access denied', 'body preserved';
    is \@complete, [1006], 'complete observer sees code';
    is \@ended, [1006], 'end observer sees code';
    is \@closed, [[1006, undef, undef]], 'production helper reads supplied metadata';
    is $disconnected, 0, 'successful refusal is not a disconnect failure';
    ok $conn->response_complete, 'response complete';
    is $conn->disconnect_reason, undef, 'no abnormal outcome';
    is $conn->end_future->get, undef, 'successful end future';
};

subtest 'direct Pages application denies a WebSocket handshake' => sub {
    my ($seen_scope, @events, $cleanup);
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $seen_scope = $scope;
        my $ws = PAGI::WebSocket->new($scope, $receive, async sub {
            my ($event) = @_;
            push @events, $event->{type};
            return await $send->($event);
        });
        $ws->on_close(sub { ++$cleanup; return });
        return await $ws->deny(PAGI::Pages->service_unavailable(
            detail => 'Scheduled maintenance', as => 'text',
        ));
    };

    my $ws = PAGI::Test::Client->new(app => $app)->websocket('/ws');

    ok $ws->refused, 'handshake refused';
    is $ws->response->status, 503, 'Pages status';
    like $ws->response->content, qr/Scheduled maintenance/,
        'Pages text body';
    is $seen_scope->{type}, 'websocket', 'original WebSocket scope remains in use';
    is $cleanup, 1, 'terminal callback runs once';
    is \@events, ['http.response.start', 'http.response.body'],
        'denial emits no websocket.accept';
};

subtest 'refusal response uses the captured response decoder for fh bodies and trailers' => sub {
    my $bytes = 'prefix-refusal-bytes-suffix';
    open my $fh, '<', \$bytes or die "open scalar fh: $!";
    my ($conn, @snapshots);

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $conn = $scope->{'pagi.connection'};
        await $receive->();
        await $send->({
            type => 'http.response.start', status => 403, headers => [], trailers => 1,
        });
        await $send->({
            type => 'http.response.body', fh => $fh, offset => 7, length => 13,
        });
        push @snapshots, [$conn->close_code, $conn->close_reason, $conn->response_complete];
        await $send->({
            type => 'http.response.trailers', headers => [['x-finished', 'yes']],
        });
        push @snapshots, [$conn->close_code, $conn->close_reason, $conn->response_complete];
    };

    my $ws = PAGI::Test::Client->new(app => $app)->websocket('/ws');
    is $ws->response->content, 'refusal-bytes', 'fh window decoded by Test::Response';
    ok $ws->response->body_complete, 'captured terminal body is complete';
    is \@snapshots, [[undef, undef, 0], [1006, undef, 1]],
        'refusal metadata appears only on terminal trailer completion';
};

subtest 'websocket.close before accept is rejected by strict send validation' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->();
        await $send->({ type => 'websocket.close', code => 1008 });
    };

    like dies { PAGI::Test::Client->new(app => $app)->websocket('/ws') },
        qr/before websocket\.accept/, 'strict send rejects close before accept';
};

done_testing;
