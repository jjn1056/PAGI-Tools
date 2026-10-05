use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use PAGI::Test::Client;
use PAGI::Test::ConnectionState;

subtest 'terminal observers are isolated and see final peer metadata' => sub {
    for my $clean (0, 1) {
        my $c = PAGI::Test::ConnectionState->new;
        my ($a, $b) = ($c->end_future, $c->end_future);
        $a->cancel;
        my @seen;
        $c->on_end(sub { push @seen, [@_, $c->is_connected, $c->close_code, $c->close_reason] });
        $c->_set_peer_close(1001, 'away');
        $clean ? $c->_mark_complete : $c->_mark_disconnected('close_incomplete', 'unfinished');
        my $reason = $clean ? undef : 'close_incomplete';
        my $detail = $clean ? undef : 'unfinished';
        is [$b->get], [$reason], 'end Future resolves with exactly one reason';
        is \@seen, [[$reason, $detail, 0, 1001, 'away']], 'full terminal record';
        $c->_set_peer_close(1000, 'too late');
        $c->_mark_disconnected('read_error');
        $c->on_end(sub { push @seen, [@_, $c->is_connected, $c->close_code, $c->close_reason] });
        is scalar @seen, 2, 'once plus immediate late observer';
        is $seen[1], $seen[0], 'immutable terminal record';
        is [$c->end_future->get], [$reason], 'late Future';
    }
};

subtest 'abort callback cannot leak HTTP bytes' => sub {
    my ($c, $callback_send);
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $response = PAGI::Test::Client->new(app => async sub {
        my ($scope, $receive, $send) = @_;
        $c = $scope->{'pagi.connection'};
        await $send->({type => 'http.response.start', status => 200, headers => []});
        $c->on_disconnect(sub { $callback_send = $send->({type => 'http.response.body', body => 'leak'}); });
        $c->abort('stop');
    })->get('/');
    is $response->content, '', 'no response bytes after terminal publication';
    ok $callback_send->is_done, 'discarded send succeeds';
    is $c->disconnect_reason, 'app_abort', 'abort preserved';
    is \@warnings, [], 'already-ended return is not reported as incomplete';

    my $empty = PAGI::Test::Client->new(app => async sub {
        my ($scope) = @_;
        $c = $scope->{'pagi.connection'};
        $c->abort('before start');
    })->get('/');
    is $empty->content, '', 'pre-start abort does not synthesize a response body';
    ok !$c->response_started, 'pre-start abort remains unstarted';
    is \@warnings, [], 'pre-start abort does not warn about an incomplete response';
};

for my $protocol (qw(websocket sse)) {
    subtest "$protocol parked app is finalized on eventual return" => sub {
        my ($c, $receive);
        my $gate = Future->new;
        my $client = PAGI::Test::Client->new(app => async sub {
            my ($scope, $recv, $send) = @_;
            $c = $scope->{'pagi.connection'}; $receive = $recv;
            await $send->({type => $protocol eq 'sse' ? 'sse.start' : 'websocket.accept'});
            await $gate;
        });
        my $session = $client->$protocol('/');
        ok $c->is_connected, 'initially parked';
        $gate->done;
        is $c->disconnect_reason, 'server_error', 'actual return triggers backstop';
        ok $session->is_closed, 'client transport closed';
        is $receive->()->get->{reason}, 'server_error', 'pending/later receive terminal event';
    };
}

sub ws_app {
    my ($slot, $close_now) = @_;
    return async sub {
        my ($scope, $receive, $send) = @_;
        @$slot{qw(conn send receive)} = ($scope->{'pagi.connection'}, $send, $receive);
        await $receive->();
        await $send->({type => 'websocket.accept'});
        if ($close_now) { await $send->({type => 'websocket.close', code => 1001, reason => 'server'}); }
        else { await $receive->(); }
    };
}

subtest 'app close cooperative default and notification boundary' => sub {
    my ($c, @seen, $inside);
    my $ws = PAGI::Test::Client->new(app => async sub {
        my ($scope, $receive, $send) = @_;
        $c = $scope->{'pagi.connection'};
        $c->on_end(sub { push @seen, [$inside, $c->close_code, $c->close_reason] });
        await $send->({type => 'websocket.accept'});
        $inside = 1;
        await $send->({type => 'websocket.close', code => 1001, reason => 'server'});
        ok $c->response_complete, 'synchronous completion fact';
        is scalar @seen, 0, 'notification deferred beyond send';
        $inside = 0;
    })->websocket('/');
    is \@seen, [[0, 1001, 'server']], 'cooperative echo metadata before deferred callback';
};

subtest 'manual close outcomes model peer and transport separately' => sub {
    for my $outcome (qw(clean timeout loss incomplete empty)) {
        my %slot;
        my $ws = PAGI::Test::Client->new(app => ws_app(\%slot, 1))->websocket('/', close_mode => 'manual');
        my $c = $slot{conn};
        ok $c->is_connected, "$outcome closing remains pending";
        is $c->close_code, undef, 'no peer Close yet';
        my @terminal;
        $c->on_end(sub { push @terminal, [@_, $c->close_code, $c->close_reason] });
        if ($outcome eq 'timeout') { $ws->simulate_close_timeout; }
        elsif ($outcome eq 'loss') { $ws->simulate_abnormal_close(reason => 'read_error'); }
        else {
            $outcome eq 'empty' ? $ws->close(undef, undef) : $ws->close(1008, 'peer');
            ok $c->is_connected, 'peer Close alone does not complete transport';
            $outcome eq 'clean' ? $ws->complete_close : $ws->simulate_abnormal_close(reason => 'close_incomplete');
        }
        my $reason = $outcome eq 'clean' ? undef : $outcome eq 'timeout' ? 'close_timeout' : $outcome eq 'loss' ? 'read_error' : 'close_incomplete';
        my $code = $outcome =~ /^(timeout|loss)$/ ? 1006 : $outcome eq 'empty' ? 1005 : 1008;
        my $text = $outcome =~ /^(timeout|loss|empty)$/ ? undef : 'peer';
        is $c->disconnect_reason, $reason, 'outcome token';
        is \@terminal, [[$reason, undef, $code, $text]], 'terminal metadata already populated';
        ok $slot{send}->({type => 'websocket.send', text => 'late'})->is_failed, 'app sends after own close still fail';
    }
};

subtest 'peer close permits first racing app close, rejects subsequent sends' => sub {
    my %slot;
    my $ws = PAGI::Test::Client->new(app => ws_app(\%slot, 0))->websocket('/');
    $ws->close(1008, 'peer');
    is $slot{conn}->close_code, 1008, 'peer metadata';
    ok $slot{send}->({type => 'websocket.close', code => 1000})->is_done, 'first racing Close succeeds';
    ok $slot{send}->({type => 'websocket.send', text => 'late'})->is_failed, 'later send rejected';
    ok $slot{conn}->response_complete, 'return after peer disconnect is clean';
};

for my $protocol (qw(websocket sse)) {
    subtest "$protocol externally resumed terminal send uses explicit pump" => sub {
        my ($conn, $inside, $end, $disconnect, $receive);
        my @seen;
        my $gate = Future->new;
        my $park = Future->new;
        my $client = PAGI::Test::Client->new(app => async sub {
            my ($scope, $recv, $send) = @_;
            $receive = $recv;
            $conn = $scope->{'pagi.connection'};
            $end = $conn->end_future;
            $disconnect = $conn->disconnect_future;
            $conn->on_complete(sub { push @seen, ['complete', $inside] });
            $conn->on_end(sub { push @seen, ['end', $inside, @_] });
            await $send->({type => $protocol eq 'sse' ? 'sse.start' : 'websocket.accept'});
            await $gate;
            $inside = 1;
            await $send->({type => "$protocol.close", code => 1000});
            is scalar @seen, 0, 'callbacks did not run during terminal send';
            ok !$end->is_ready, 'end Future also deferred';
            $inside = 0;
            await $park;
        });
        my $session = $client->$protocol('/');
        $gate->done;
        ok $conn->response_complete, 'facts immediately available';
        ok !$end->is_ready, 'external resume alone does not pump';
        my @late;
        $conn->on_end(sub { @late = @_ });
        is \@late, [undef, undef], 'late callback remains immediate';
        $session->pump;
        is \@seen, [['complete', 0], ['end', 0, undef, undef]], 'deferred observers in order';
        is [$end->get], [undef], 'clean end result';
        ok !$disconnect->is_ready, 'clean end leaves disconnect observer pending';
        is $receive->()->get->{type}, "$protocol.disconnect", 'later receive reports end';
        $session->pump;
        is scalar @seen, 2, 'pumping twice does not redeliver';
        $park->done;
    };
}

subtest 'end observer exceptions do not block later observers' => sub {
    my $c = PAGI::Test::ConnectionState->new;
    my (@seen, @warnings);
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    $c->on_end(sub { die "observer failure\n" });
    $c->on_end(sub { push @seen, [@_] });
    $c->_mark_disconnected('read_error');
    is \@seen, [['read_error', undef]], 'next callback ran';
    like $warnings[0], qr/observer failure/, 'exception reported';
    is [$c->end_future->get], ['read_error'], 'Future still settles';
};

for my $protocol (qw(websocket sse)) {
    subtest "$protocol failed refusal capture publishes an abnormal end" => sub {
        my ($conn, $end);
        my @ended;
        my $error = dies {
            PAGI::Test::Client->new(app => async sub {
                my ($scope, $receive, $send) = @_;
                $conn = $scope->{'pagi.connection'};
                $end = $conn->end_future;
                $conn->on_end(sub { push @ended, [@_] });
                await $send->({type => 'http.response.start', status => 403, headers => []});
                # This existing source file cannot also be a directory.
                await $send->({type => 'http.response.body', file => __FILE__ . '/missing-body'});
            })->$protocol('/');
        };
        like $error, qr/Cannot open file response/, 'capture error is preserved';
        ok !$conn->is_connected, 'failed capture ends the scope';
        is $conn->disconnect_reason, 'server_error', 'failed delivery is abnormal';
        ok !$conn->response_complete, 'validated framing alone is not successful delivery';
        ok $end->is_ready, 'terminal Future settles';
        is [$end->get], ['server_error'], 'end observer reason' if $end->is_ready;
        is scalar @ended, 1, 'terminal callback delivered once';
        is $ended[0][0], 'server_error', 'callback sees abnormal outcome';
    };
}

subtest 'manual peer-first Close keeps peer metadata across racing app Close' => sub {
    my %slot;
    my $ws = PAGI::Test::Client->new(app => ws_app(\%slot, 0))->websocket('/', close_mode => 'manual');
    $ws->close(1008, 'peer');
    ok $slot{send}->({type => 'websocket.close', code => 1000, reason => 'app'})->is_done,
        'first racing application Close succeeds';
    $ws->complete_close;
    is [$ws->close_code, $ws->close_reason], [1008, 'peer'], 'public client metadata stays peer data';
    is [$slot{conn}->close_code, $slot{conn}->close_reason], [1008, 'peer'], 'connection metadata agrees';
    my $event = $slot{receive}->()->get;
    is [$event->{code}, $event->{reason}], [1008, 'peer'], 'receive metadata agrees';
};

subtest 'manual peer Close: the app hears it when transport completes; racing data is discarded' => sub {
    my %slot;
    my $ws = PAGI::Test::Client->new(app => ws_app(\%slot, 0))->websocket('/', close_mode => 'manual');
    $ws->close(1000, 'peer');
    ok $slot{conn}->is_connected, 'transport completion is still pending';
    my $pending = $slot{receive}->();
    ok !$pending->is_ready, 'no disconnect while transport completion is pending (as PAGI::Server)';
    ok $slot{send}->({type => 'websocket.send', text => 'after Close'})->is_done,
        'racing data send may be discarded successfully';
    $ws->complete_close;
    ok $pending->is_ready, 'the disconnect arrives when the transport completes';
    is $pending->get->{type}, 'websocket.disconnect', 'it is the peer Close';
    ok !$slot{conn}->is_connected, 'with the scope already ended';
    is $ws->receive_text, undef, 'post-Close application data was never delivered';
};

subtest 'close_incomplete requires peer Close without mutating a pending scope' => sub {
    my %slot;
    my $ws = PAGI::Test::Client->new(app => ws_app(\%slot, 1))->websocket('/', close_mode => 'manual');
    my $end = $slot{conn}->end_future;
    like dies { $ws->simulate_abnormal_close(reason => 'close_incomplete') },
        qr/close_incomplete requires a peer Close/, 'impossible outcome rejected';
    ok $slot{conn}->is_connected, 'connection remains pending';
    ok !$end->is_ready, 'invalid control did not publish terminal state';
    is $slot{conn}->close_code, undef, 'invalid control did not invent peer metadata';
    $ws->close(undef, undef);
    $ws->simulate_abnormal_close(reason => 'close_incomplete');
    is $slot{conn}->disconnect_reason, 'close_incomplete', 'valid empty-peer outcome still works';
    is [$slot{conn}->close_code, $slot{conn}->close_reason], [1005, undef], 'empty peer metadata preserved';
};

done_testing;
