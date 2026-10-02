use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use PAGI::Utils qw(as_app_object);
use Scalar::Util qw(weaken);
use PAGI::WebSocket;
use PAGI::SSE;
use PAGI::Test::ConnectionState;
use PAGI::Response qw(response);

for my $kind (qw(websocket sse)) {
    my $class = $kind eq 'websocket' ? 'PAGI::WebSocket' : 'PAGI::SSE';
    subtest "$kind terminal facts precede retained ordered cleanup" => sub {
        my $conn = PAGI::Test::ConnectionState->new(websocket => $kind eq 'websocket');
        my @sent;
        my $scope = {type => $kind, 'pagi.connection' => $conn};
        my $helper = $class->new($scope, sub { die 'competing receive' }, sub {push @sent, $_[0]; Future->done});
        my $gate = Future->new;
        my @calls;
        $helper->on_close(sub { push @calls, [@_]; $gate });
        $helper->on_close(sub { push @calls, ['second']; });
        ($kind eq 'websocket' ? $helper->accept : $helper->start)->get;
        my $close = $kind eq 'websocket' ? $helper->close(1000, 'local') : $helper->close;
        is(scalar @calls, 0, 'local close does not publish terminal hooks');
        ok($close->is_ready, 'WS close settles at send') if $kind eq 'websocket';
        ok(!$helper->is_closed, 'local close is not terminal');
        is($helper->connection_state, 'closing', 'local progress stops data sends');
        {
            local $conn->{_defer_notifications} = 1;
            $conn->_set_peer_close(1001, 'peer') if $kind eq 'websocket';
            $conn->_mark_disconnected('server_shutdown', 'draining');
        }
        ok($helper->is_closed, 'terminal facts readable before delivery');
        is($helper->disconnect_reason, 'server_shutdown', 'lifecycle reason separate');
        is($helper->disconnect_detail, 'draining', 'detail synchronous');
        is($helper->close_code, 1001, 'peer code wins') if $kind eq 'websocket';
        is($helper->close_reason, 'peer', 'peer text wins') if $kind eq 'websocket';
        is(scalar @calls, 0, 'still no callback before delivery');
        my $weak = $helper; weaken($weak);
        undef $close;
        undef $helper;
        ok($weak, 'connection retains helper after handler references drop');
        $conn->_deliver_notifications;
        is(scalar @calls, 1, 'first callback pending');
        ok($weak, 'worker survives connection callback release');
        like(dies { $weak->on_close(sub {}) }, qr/on_close.*cleanup|cleanup.*on_close/, 'late registration rejected');
        my $join = $weak->_run_close_callbacks;
        $join->cancel;
        ok(!$gate->is_cancelled, 'observer cannot cancel owned cleanup');
        my $join2 = $weak->_run_close_callbacks;
        ok(!$join2->is_ready, 'repeat joins same pending cleanup');
        if ($kind eq 'websocket') { is($calls[0], [1001, 'peer', 'draining'], 'callback peer metadata and detail'); }
        else { is([@{$calls[0]}[1,2]], ['server_shutdown', 'draining'], 'SSE callback terminal reason/detail'); }
        @calls = (); # SSE callback arguments themselves retain the helper
        $gate->done;
        ok($join2->is_ready, 'join settles after cleanup');
        is(\@calls, [['second']], 'registration order maintained');
        undef $join; undef $join2;
        ok(!$weak, 'all helper ownership released after cleanup');
        is([map $_->{type}, @sent], ["$kind." . ($kind eq 'websocket' ? 'accept' : 'start'), "$kind.close"], 'only one local close');
    };
    subtest "$kind constructor terminal and send settlement cannot resurrect" => sub {
        my $conn = PAGI::Test::ConnectionState->new(websocket => $kind eq 'websocket');
        my $h = $class->new({type => $kind, 'pagi.connection' => $conn}, sub {die 'receive'}, sub {
            local $conn->{_defer_notifications} = 1;
            $conn->_mark_disconnected('peer_closed', 'gone');
            Future->done;
        });
        ($kind eq 'websocket' ? $h->accept : $h->start)->get;
        ok($h->is_closed, 'send settlement does not resurrect connection');
        is($h->close_code, 1006, 'no peer Close is 1006') if $kind eq 'websocket';
        is($h->close_reason, undef, 'no peer text') if $kind eq 'websocket';
        $conn->_deliver_notifications;
        undef $h;
        $h = $class->new({type => $kind, 'pagi.connection' => $conn}, sub {die 'receive'}, sub {die 'send'});
        ok($h->is_closed, 'constructor observes terminal connection');
        like(dies {$h->on_close(sub {})}, qr/on_close.*cleanup|cleanup.*on_close/, 'constructor-time end closes registration');
    };
}
subtest 'WebSocket concurrent close joins send and rejects every data form while closing' => sub {
    my $conn = PAGI::Test::ConnectionState->new(websocket => 1);
    my $pending = Future->new;
    my @sent;
    my $ws = PAGI::WebSocket->new({type => 'websocket', 'pagi.connection' => $conn}, sub {die 'receive'}, sub {
        push @sent, $_[0]{type};
        $_[0]{type} eq 'websocket.close' ? $pending : Future->done;
    });
    $ws->accept->get;
    my $one = $ws->close;
    my $two = $ws->close;
    ok(!$one->is_ready && !$two->is_ready, 'both callers join pending send');
    $one->cancel;
    ok(!$pending->is_cancelled, 'close observer does not cancel server send');
    for my $method (qw(send_text send_bytes send_json)) {
        like(dies {$ws->$method('data')->get}, qr/Cannot send/, "$method refuses after close request");
    }
    for my $method (qw(try_send_text try_send_bytes try_send_json)) {
        is($ws->$method('data')->get, 0, "$method refuses after close request");
    }
    $ws->accept->get;
    $ws->keepalive(10)->get;
    is($ws->connection_state, 'closing', 'accept cannot reopen locally closing socket');
    is(\@sent, [qw(websocket.accept websocket.close)], 'one send, no data or keepalive after close');
    $pending->done;
    ok($two->is_ready, 'second caller completes at send settlement');
    ok($two->get == $ws, 'close preserves helper return value');
    ok(!$ws->is_closed, 'pending peer remains nonterminal');
    $conn->_mark_disconnected('close_timeout', 'peer did not reply');
};

subtest 'SSE first close joins cleanup but calls after cleanup starts settle without joining themselves' => sub {
    my $conn = PAGI::Test::ConnectionState->new;
    my $gate = Future->new;
    my ($hook_close, $calls);
    my @sent;
    my $sse = PAGI::SSE->new({type => 'sse', 'pagi.connection' => $conn}, sub {die 'receive'}, sub {push @sent, $_[0]{type}; Future->done});
    $sse->on_close(sub { ++$calls; $hook_close = $sse->close; return $gate });
    $sse->start->get;
    my $first = $sse->close;
    my $second = $sse->close;
    ok(!$first->is_ready && !$second->is_ready, 'ordinary concurrent callers await shared cleanup');
    $conn->_mark_complete;
    ok($hook_close->is_ready, 'close from cleanup does not await itself');
    my $later = $sse->close;
    ok($later->is_ready, 'external close after cleanup begins follows same idempotent rule');
    ok(!$first->is_ready, 'initial close still awaits cleanup');
    $second->cancel;
    ok(!$gate->is_cancelled, 'joiner cancellation preserves cleanup');
    $gate->done;
    ok($first->is_ready, 'first close awaits completed cleanup');
    ok($first->get == $sse, 'close preserves helper return value');
    is($calls, 1, 'one cleanup');
    is(\@sent, [qw(sse.start sse.close)], 'one close');
};

subtest 'SSE run waits for terminal cleanup without consuming receive' => sub {
    my $conn = PAGI::Test::ConnectionState->new;
    my $gate = Future->new;
    my $sse = PAGI::SSE->new({type => 'sse', 'pagi.connection' => $conn}, sub {die 'receive'}, sub {Future->done});
    my @args;
    $sse->on_close(sub { @args = @_; $gate });
    my $run = $sse->run;
    $conn->_mark_complete;
    ok(!$run->is_ready, 'run joins pending async cleanup');
    is([@args[1,2]], [undef, undef], 'clean end has no fabricated reason or detail');
    $gate->done;
    ok($run->is_ready, 'run completes after cleanup');
};

subtest 'connection-backed receive and handler errors stay errors until server ends scope' => sub {
    for my $kind (qw(websocket sse)) {
        my $conn = PAGI::Test::ConnectionState->new(websocket => $kind eq 'websocket');
        my $class = $kind eq 'websocket' ? 'PAGI::WebSocket' : 'PAGI::SSE';
        my $h = $class->new({type => $kind, 'pagi.connection' => $conn}, sub {Future->fail("receive failed\n")}, sub {Future->done});
        my $calls = 0;
        $h->on_close(sub {++$calls});
        if ($kind eq 'websocket') {
            like(dies {$h->run->get}, qr/receive failed/, 'run preserves receive exception');
        } else {
            like(dies {$h->each([1], sub {Future->fail("callback failed\n")})->get}, qr/callback failed/, 'each preserves callback exception');
        }
        is($calls, 0, 'exception is not terminal cleanup');
        ok(!$h->is_closed, 'exception is not a connection fact');
        $conn->_mark_disconnected('server_error', 'handler failed');
        is($calls, 1, 'server outcome triggers cleanup');
    }
};
for my $kind (qw(websocket sse)) {
    subtest "$kind committed refusal remains nonterminal until connection end" => sub {
        my $conn = PAGI::Test::ConnectionState->new(websocket => $kind eq 'websocket');
        my $body = Future->new;
        my @events;
        my $class = $kind eq 'websocket' ? 'PAGI::WebSocket' : 'PAGI::SSE';
        my $h = $class->new({type => $kind, 'pagi.connection' => $conn}, sub {die 'receive'}, sub {
            $conn->_mark_response_started if $_[0]{type} eq 'http.response.start';
            push @events, $_[0]{type};
            $_[0]{type} eq 'http.response.body' ? $body : Future->done;
        });
        my @calls;
        $h->on_close(sub {push @calls, [@_]});
        my $response = as_app_object(async sub {
            my ($scope, $receive, $send) = @_;
            await $send->({type => 'http.response.start', status => 403, headers => []});
            await $send->({type => 'http.response.body', body => 'refused', more => 1});
        });
        my $f = $kind eq 'websocket' ? $h->deny($response) : $h->decline($response);
        ok($conn->response_started, 'committed refusal body still in progress');
        ok(!$h->is_closed, 'refusal start is not terminal');
        is($h->receive->get, undef, 'committed refusal never reads message queue') if $kind eq 'websocket';
        $body->done;
        ok($f->is_ready, 'refusal return observes send settlement');
        is(scalar @calls, 0, 'refusal return does not publish hooks');
        ok(!$h->is_closed, 'successful refusal return still awaits connection terminal');
        $conn->_mark_complete;
        ok($h->is_closed, 'terminal completion closes helper');
        is(scalar @calls, 1, 'one terminal cleanup');
        is($h->close_code, 1006, 'refusal does not override authoritative no-peer code') if $kind eq 'websocket';
        is($h->disconnect_reason, undef, 'clean refusal has no lifecycle reason');
    };
}
subtest 'WebSocket message callback error remains an application failure' => sub {
    my $conn = PAGI::Test::ConnectionState->new(websocket => 1);
    my $calls = 0;
    my $ws = PAGI::WebSocket->new({type => 'websocket', 'pagi.connection' => $conn}, sub {
        return ++$calls == 1 ? Future->done({type => 'websocket.receive', text => 'hello'}) : Future->new;
    }, sub {Future->done});
    my ($cleanup, $errors) = (0, 0);
    $ws->on_close(sub {++$cleanup});
    $ws->on_error(sub {++$errors});
    $ws->on_message(sub {die "message failed\n"});
    my $run = $ws->run;
    ok($run->is_failed, 'callback exception fails run');
    like($run->failure, qr/message failed/, 'original message error') if $run->is_failed;
    is($errors, 1, 'error hook still observes failure');
    is($cleanup, 0, 'application error waits for server outcome');
    $conn->_mark_disconnected('server_error', 'message handler failed');
    is($cleanup, 1, 'server outcome owns terminal cleanup');
};
subtest 'receive sees authoritative metadata before deferred terminal notification' => sub {
    my $conn = PAGI::Test::ConnectionState->new(websocket => 1);
    my $calls = 0;
    my $ws = PAGI::WebSocket->new({type => 'websocket', 'pagi.connection' => $conn}, sub {
        local $conn->{_defer_notifications} = 1;
        $conn->_set_peer_close(1001, 'peer text');
        $conn->_mark_disconnected('close_incomplete', 'reply write failed');
        Future->done({type => 'websocket.disconnect', code => 1006, reason => 'close_incomplete'});
    }, sub {Future->done});
    $ws->on_close(sub {++$calls});
    $ws->accept->get;
    is($ws->receive->get, undef, 'terminal receive returns no data');
    is($ws->close_code, 1001, 'peer code rather than receive-event code');
    is($ws->close_reason, 'peer text', 'peer text rather than lifecycle token');
    is($calls, 0, 'receive does not independently publish cleanup');
    $conn->_deliver_notifications;
    is($calls, 1, 'deferred terminal callback alone publishes cleanup');
};
for my $case (
    [websocket => send_text => ['data'], 'throws'],
    [websocket => send_bytes => ['bytes'], 'throws'],
    [websocket => send_json => [{message => 'data'}], 'throws'],
    [websocket => try_send_text => ['data'], 'false'],
    [websocket => try_send_bytes => ['bytes'], 'false'],
    [websocket => try_send_json => [{message => 'data'}], 'false'],
    [sse => try_send => ['data'], 'false'],
    [sse => try_send_json => [{message => 'data'}], 'false'],
    [sse => try_send_comment => ['comment'], 'false'],
    [sse => try_send_event => [data => 'data', event => 'update'], 'false'],
) {
    my ($kind, $method, $args, $outcome) = @$case;
    subtest "$kind $method cannot send into a committed refusal body" => sub {
        my $conn = PAGI::Test::ConnectionState->new(websocket => $kind eq 'websocket');
        my $body = Future->new;
        my @events;
        my $class = $kind eq 'websocket' ? 'PAGI::WebSocket' : 'PAGI::SSE';
        my $helper = $class->new({type => $kind, 'pagi.connection' => $conn}, sub {die 'receive'}, sub {
            $conn->_mark_response_started if $_[0]{type} eq 'http.response.start';
            push @events, $_[0]{type};
            return $_[0]{type} eq 'http.response.body' ? $body : Future->done;
        });
        my ($cleanup, $errors) = (0, 0);
        $helper->on_close(sub {++$cleanup});
        $helper->on_error(sub {++$errors});
        my $response = as_app_object(async sub {
            my ($scope, $receive, $send) = @_;
            await $send->({type => 'http.response.start', status => 403, headers => []});
            await $send->({type => 'http.response.body', body => 'refused', more => 1});
        });
        my $refusal = $kind eq 'websocket' ? $helper->deny($response) : $helper->decline($response);
        ok(!$refusal->is_ready, 'committed refusal body is pending');
        if ($outcome eq 'throws') {
            like(dies {$helper->$method(@$args)->get}, qr/Cannot send/, 'throwing method rejects locally');
        } else {
            is($helper->$method(@$args)->get, 0, 'boolean method rejects with false');
        }
        is(\@events, [qw(http.response.start http.response.body)], 'no protocol send reaches the committed HTTP response');
        is($errors, 0, 'guard does not invoke send-error hooks');
        ok($conn->response_started, 'local guard preserves refusal progress');
        ok($conn->is_connected && !$helper->is_closed, 'local rejection does not fabricate terminal state');
        is($cleanup, 0, 'local rejection does not start terminal cleanup');
        $body->done;
        ok($refusal->is_ready && !$refusal->is_failed, 'refusal still finishes normally');
        is($cleanup, 0, 'body settlement alone does not publish cleanup');
        $conn->_mark_complete;
        ok($helper->is_closed, 'connection completion supplies terminal fact');
        is($cleanup, 1, 'connection end runs cleanup once');
        $conn->_mark_complete;
        is($cleanup, 1, 'repeated terminal observation cannot repeat cleanup');
    };
}
done_testing;
