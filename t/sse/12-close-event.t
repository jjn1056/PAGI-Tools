#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use lib 't/lib';
use PAGI::SSE;
use PAGITest::Connected qw(sse_scope send_to);

# Step 4 of the sse.close rollout: the framework close() sends the sse.close
# send-event (the server, merged separately, acts on it), carries an optional
# server-side reason (on_close sees the connection's terminal outcome, not that
# reason), and wakes a parked run() so a close from deep in a helper actually
# ends the stream.

sub make_sse {
    my ($sent) = @_;
    my $scope = sse_scope();
    return PAGI::SSE->new(
        $scope,
        sub { Future->new },                         # receive: never resolves
        send_to($scope, $sent),                      # send: record events
    );
}

subtest 'close() sends an sse.close event carrying the reason' => sub {
    my @sent;
    my $sse = make_sse(\@sent);
    $sse->start->get;
    $sse->close(reason => 'job_done')->get;

    my ($ev) = grep { ($_->{type} // '') eq 'sse.close' } @sent;
    ok($ev, 'an sse.close event was sent');
    is($ev->{reason}, 'job_done', 'reason carried on the event');
};

subtest 'close() without a reason omits the reason field' => sub {
    my @sent;
    my $sse = make_sse(\@sent);
    $sse->start->get;
    $sse->close->get;

    my ($ev) = grep { ($_->{type} // '') eq 'sse.close' } @sent;
    ok($ev, 'an sse.close event was sent');
    ok(!exists $ev->{reason}, 'no reason key when none was given');
};

subtest 'on_close sees a clean completion, not the close reason' => sub {
    my @sent;
    my $sse = make_sse(\@sent);
    $sse->start->get;

    my ($called, $got);
    $sse->on_close(sub { my ($s, $reason) = @_; $called = 1; $got = $reason });
    $sse->close(reason => 'quota_exhausted')->get;

    ok($called, 'on_close ran once the stream completed');
    is($got, undef, 'the close reason is server-side metadata; on_close sees clean completion');
};

subtest 'run() returns when close() is called from elsewhere' => sub {
    my @sent;
    my $sse = make_sse(\@sent);
    $sse->start->get;

    my $run_f = $sse->run;                  # parks until the connection ends
    ok(!$run_f->is_ready, 'run() is parked');

    $sse->close(reason => 'app_closed')->get;   # close from "a helper"

    ok($run_f->is_ready, 'run() completed after close()');
};

done_testing;
