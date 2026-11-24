#!/usr/bin/env perl
# PAGI::Test::ConnectionState->run_until_end: the contract of
# PAGI::Spec::Www 0.7 "Connection Object Interface", through the test client,
# so an application that uses the method can be tested without a server.
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Future::IO;
use Time::HiRes qw(time);

use PAGI::Test::Client;

my $NOT_A_FUTURE = "run_until_end's callback must return a Future, the work to stop when the scope ends (an async sub returns one)\n";
my $CANCELLED    = "the work given to run_until_end was cancelled while the scope was still open\n";

sub start  { $_[0]->({ type => 'http.response.start', status => 200, headers => [['content-type', 'text/plain']] }) }
sub finish { $_[0]->({ type => 'http.response.body', body => $_[1] // "done\n", more => 0 }) }
sub caught { my ($f) = @_; return eval { $f->get; 1 } ? 'no error' : $@ }

# Runs Future::IO turns until $cond holds, or for at most $secs.
sub wait_for {
    my ($cond, $secs) = @_;
    my $deadline = time + ($secs // 5);
    Future::IO->sleep(0.01)->get until $cond->() || time > $deadline;
    return $cond->();
}

sub client_for {
    my ($app) = @_;
    return PAGI::Test::Client->new(app => async sub {
        my ($scope, $receive, $send) = @_;
        await $app->($scope->{'pagi.connection'}, $send);
    });
}

subtest 'the work finishes: its results come back' => sub {
    my $seen;
    my $res = client_for(async sub {
        my ($conn, $send) = @_;
        await start($send);
        $seen = [ await $conn->run_until_end(async sub { (7, 'seven') }) ];
        await finish($send);
    })->get('/');
    is $res->content, "done\n", 'response completed';
    is $seen, [ 7, 'seven' ], 'both results';
};

subtest 'the client leaves: the work is cancelled before the call resolves' => sub {
    my $seen;
    my $stream = client_for(async sub {
        my ($conn, $send) = @_;
        await start($send);
        await $send->({ type => 'http.response.body', body => "started\n", more => 1 });
        my $work;
        my @r = await $conn->run_until_end(sub { $work = Future::IO->sleep(30) });
        $seen = { result => \@r, cancelled => $work->is_cancelled ? 1 : 0,
                  connected => $conn->is_connected, reason => $conn->disconnect_reason };
    })->stream('/');
    is $stream->receive_chunk(timeout => 3), "started\n", 'the body began';
    $stream->close;
    ok wait_for(sub { $seen }), 'the call returned';
    is $seen, { result => [], cancelled => 1, connected => 0, reason => 'client_closed' },
        'empty list; the work already cancelled on the first line after await; the end reported';
};

# Through stream(): get() holds an end the app's own send made until the app
# returns (PAGI-Tools open issues, 2026-11-24), and this work waits past it.
subtest 'a clean end cancels pending work too' => sub {
    my $seen;
    my $stream = client_for(async sub {
        my ($conn, $send) = @_;
        await start($send);
        my $work;
        my @r = await $conn->run_until_end(sub {
            # the end arrives after the call is pending
            $work = (async sub { await Future::IO->sleep(0.05); await finish($send, "last\n"); await Future::IO->sleep(30) })->();
        });
        $seen = { result => \@r, cancelled => $work->is_cancelled ? 1 : 0,
                  connected => $conn->is_connected, reason => $conn->disconnect_reason };
    })->stream('/');
    is $stream->receive_chunk(timeout => 3), "last\n", 'the terminal body went';
    is $stream->receive_chunk(timeout => 3), undef, 'and the response is over';
    ok wait_for(sub { $seen }), 'the call returned';
    is $seen, { result => [], cancelled => 1, connected => 0, reason => undef },
        'empty list; cancelled on the first line after await; a clean end';
};

subtest 'failures keep their error' => sub {
    my %seen;
    my %code = (
        'work-fails'   => async sub { await Future::IO->sleep(0.01); die "database went away\n" },
        'code-dies'    => sub { die "no database handle\n" },
        'not-a-future' => sub { 42 },
    );
    for my $case (sort keys %code) {
        client_for(async sub {
            my ($conn, $send) = @_;
            await start($send);
            my $call = $conn->run_until_end($code{$case});
            await $call->else(sub { Future->done });
            $seen{$case} = caught($call);
            await finish($send);
        })->get('/');
    }
    is $seen{'work-fails'},   "database went away\n", 'the work failing';
    is $seen{'code-dies'},    "no database handle\n", '$code dying';
    is $seen{'not-a-future'}, $NOT_A_FUTURE,          'a non-Future';
};

subtest 'cancelled from outside while the scope is open: fails at once' => sub {
    my $seen;
    client_for(async sub {
        my ($conn, $send) = @_;
        await start($send);
        my $work = Future::IO->sleep(10);
        my $t0   = time;
        Future::IO->sleep(0.2)->on_done(sub { $work->cancel })->retain;
        my $call = $conn->run_until_end(sub { $work });
        await $call->else(sub { Future->done });
        $seen = { error => caught($call), secs => time - $t0 };
        await finish($send);
    })->get('/');
    is $seen->{error}, $CANCELLED, 'the cancellation, named';
    ok $seen->{secs} < 1, 'not left waiting for the end';
};

subtest 'the caller cancels: the work is cancelled, the scope stays open' => sub {
    my $seen;
    my $res = client_for(async sub {
        my ($conn, $send) = @_;
        await start($send);
        my $work;
        my $call = $conn->run_until_end(sub { $work = Future::IO->sleep(30) });
        await Future::IO->sleep(0.05);
        $call->cancel;
        $seen = { cancelled => $work->is_cancelled ? 1 : 0, connected => $conn->is_connected };
        await finish($send, "still serving\n");
    })->get('/');
    is $res->content, "still serving\n", 'the app answered afterwards';
    is $seen, { cancelled => 1, connected => 1 }, 'work cancelled; scope open';
};

subtest 'a call on an ended scope skips $code and resolves on a later turn' => sub {
    my $seen;
    client_for(async sub {
        my ($conn, $send) = @_;
        await start($send);
        await finish($send);
        my $ran  = 0;
        my $call = $conn->run_until_end(sub { $ran = 1; Future->done('ran') });
        my $ready_in_call = $call->is_ready ? 1 : 0;
        my @r = await $call;
        $seen = { ran => $ran, ready_in_call => $ready_in_call, result => \@r };
    })->get('/');
    ok wait_for(sub { $seen }), 'it resolved';
    is $seen, { ran => 0, ready_in_call => 0, result => [] }, 'skipped; later; empty';
};

subtest '$code ends its own scope' => sub {
    my %seen;
    my %code = (
        done    => sub { my ($conn) = @_; $conn->abort('stopping'); Future->done(42) },
        fail    => sub { my ($conn) = @_; $conn->abort('stopping'); Future->fail("database failed\n") },
        pending => sub { my ($conn, $w) = @_; $conn->abort('stopping'); $$w = Future::IO->sleep(30) },
    );
    for my $case (sort keys %code) {
        client_for(async sub {
            my ($conn, $send) = @_;
            await start($send);
            my $work;
            my $call = $conn->run_until_end(sub { $code{$case}->($conn, \$work) });
            await $call->else(sub { Future->done });
            $seen{$case} = $call->is_failed ? caught($call)
                : { result => [ $call->get ], ($work ? (cancelled => $work->is_cancelled ? 1 : 0) : ()) };
        })->get('/');
    }
    ok wait_for(sub { keys %seen == 3 }), 'all three resolved';
    is $seen{done},    { result => [42] }, 'a settled Future keeps its results';
    is $seen{fail},    "database failed\n", 'a settled failure keeps its error';
    is $seen{pending}, { result => [], cancelled => 1 }, 'a pending Future is cancelled by the end';
};

subtest 'a call from an on_end callback' => sub {
    my $seen;
    client_for(async sub {
        my ($conn, $send) = @_;
        $conn->on_end(sub {
            my $ran  = 0;
            my $call = $conn->run_until_end(sub { $ran = 1; Future->done });
            my $ready_in_call = $call->is_ready ? 1 : 0;
            $call->on_done(sub { $seen = { ran => $ran, ready_in_call => $ready_in_call, result => [@_] } })->retain;
        });
        await start($send);
        await finish($send);
    })->get('/');
    ok wait_for(sub { $seen }), 'it resolved';
    is $seen, { ran => 0, ready_in_call => 0, result => [] }, 'skipped; later; empty';
};

done_testing;
