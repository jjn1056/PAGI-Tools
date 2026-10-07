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

done_testing;
