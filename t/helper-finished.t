use strict;
use warnings;
use Test2::V0;
use Future;

use lib 't/lib';
use PAGITest::Connected qw(ws_scope sse_scope);
use PAGI::WebSocket;
use PAGI::SSE;

# A helper's finished resolves once its scope has ended and the work it
# started -- on_close cleanup first of all -- has settled.

# Each case builds an accepted/started helper; send completes at once.
my @cases = (
    [ 'PAGI::WebSocket', sub {
        my $scope = ws_scope();
        my $h = PAGI::WebSocket->new($scope, sub { Future->new }, sub { Future->done });
        $h->accept->get;
        return ($h, $scope);
    } ],
    [ 'PAGI::SSE', sub {
        my $scope = sse_scope();
        my $h = PAGI::SSE->new($scope, sub { Future->new }, sub { Future->done });
        $h->start->get;
        return ($h, $scope);
    } ],
);

for my $case (@cases) {
    my ($class, $build) = @$case;

    subtest "$class: finished waits for an asynchronous on_close" => sub {
        my ($h, $scope) = $build->();
        my $gate = Future->new;
        $h->on_close(sub { $gate });
        my $finished = $h->finished;
        ok(!$finished->is_ready, 'not while the scope is open');
        $scope->{'pagi.connection'}->_mark_disconnected('server_shutdown');
        ok(!$finished->is_ready, 'not while on_close is running');
        $gate->done;
        ok($finished->is_done, 'done once it has finished');
        is($finished->get, exact_ref($h), 'resolving to the helper');
    };

    subtest "$class: every on_close runs, then finished fails with the first failure" => sub {
        my ($h, $scope) = $build->();
        my $second_ran = 0;
        $h->on_close(sub { die "first\n" });
        $h->on_close(sub { $second_ran = 1; return });
        $h->on_close(sub { die "third\n" });
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $scope->{'pagi.connection'}->_mark_disconnected('client_closed');
        my $finished = $h->finished;
        ok($second_ran, 'the callbacks after a failure still ran');
        ok($finished->is_failed, 'finished failed');
        is(scalar $finished->failure, "first\n", 'with the first failure');
        is(\@warnings, [], 'and nothing was warned');
    };
}

for my $case (@cases) {
    my ($class, $build) = @$case;
    subtest "$class: finished means the connection is over, even with no on_close" => sub {
        my ($h, $scope) = $build->();
        my $closing = $h->close;
        my $finished = $h->finished;
        ok(!$finished->is_ready, 'not after the application closes, while the scope is open');
        $scope->{'pagi.connection'}->_mark_complete;
        ok($finished->is_done, 'done once the scope has ended');
        ok($closing->is_ready, 'and the close completed');
    };
}

subtest 'PAGI::SSE: an on_close failure does not fail close() or run()' => sub {
    my ($sse, $scope) = $cases[1][1]->();
    $sse->on_close(sub { die "cleanup broke\n" });
    my $closing = $sse->close;
    $scope->{'pagi.connection'}->_mark_complete;
    ok($closing->is_done, 'close() completed');
    ok($sse->run->is_done, 'run() completed');
    ok($sse->finished->is_failed, 'finished carries the failure');
};

subtest 'finished does not wait while the application has not acted' => sub {
    my $ws = PAGI::WebSocket->new(ws_scope(), sub { Future->new }, sub { Future->done });
    ok($ws->finished->is_done, 'a WebSocket never accepted: done at once');
    my $sse = PAGI::SSE->new(sse_scope(), sub { Future->new }, sub { Future->done });
    ok($sse->finished->is_done, 'an SSE never started: done at once');
};

subtest 'a helper built after its scope ended still finishes' => sub {
    my $scope = ws_scope();
    $scope->{'pagi.connection'}->_mark_disconnected('client_closed');
    my $ws = PAGI::WebSocket->new($scope, sub { Future->new }, sub { Future->done });
    ok($ws->finished->is_done, 'done');
};

subtest 'finished waits for a best-effort send still in flight' => sub {
    my @issued;
    my $send = sub { push @issued, Future->new; return $issued[-1] };
    my $scope = ws_scope();
    my $ws = PAGI::WebSocket->new($scope, sub { Future->new }, $send);
    my $accepting = $ws->accept;
    $issued[0]->done;
    $accepting->get;
    $ws->try_send_text('to a slow client');    # dropped, still pending
    $scope->{'pagi.connection'}->_mark_disconnected('client_closed');
    my $finished = $ws->finished;
    ok(!$finished->is_ready, 'not while the send is pending');
    $_->done for grep { !$_->is_ready } @issued;
    ok($finished->is_done, 'done once it settled');
};

subtest 'a dropped close() still completes, and nothing complains' => sub {
    my @issued;
    my $send = sub { push @issued, [$_[0], Future->new]; return $issued[-1][1] };
    my $scope = ws_scope();
    my $ws = PAGI::WebSocket->new($scope, sub { Future->new }, $send);
    my $accepting = $ws->accept;
    $issued[0][1]->done;
    $accepting->get;
    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $ws->close;                              # Future dropped
        $_->[1]->done for grep { !$_->[1]->is_ready } @issued;
        $scope->{'pagi.connection'}->_mark_complete;
    }
    is([map { $_->[0]{type} } @issued], ['websocket.accept', 'websocket.close'], 'the Close went out');
    ok($ws->finished->is_done, 'finished');
    is(\@warnings, [], 'no lost-Future warnings');
};

subtest "a failing close() is the caller's, not finished's" => sub {
    my $scope = ws_scope();
    my $calls = 0;
    my $send = sub { return $calls++ ? Future->fail("wire broke\n") : Future->done };
    my $ws = PAGI::WebSocket->new($scope, sub { Future->new }, $send);
    $ws->accept->get;
    my $closing = $ws->close;
    ok($closing->is_failed, 'close() reports the failure to its caller');
    $scope->{'pagi.connection'}->_mark_disconnected('write_error');
    ok($ws->finished->is_done, 'finished does not repeat it');
};

subtest 'an SSE helper built after its scope ended still finishes' => sub {
    my $scope = sse_scope();
    $scope->{'pagi.connection'}->_mark_disconnected('client_closed');
    my $sse = PAGI::SSE->new($scope, sub { Future->new }, sub { Future->done });
    ok($sse->finished->is_done, 'done');
};

done_testing;
