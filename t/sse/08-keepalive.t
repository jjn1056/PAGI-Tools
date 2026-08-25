#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::SSE;

# NOTE: these subtests call start() before keepalive() throughout. That's
# required, not incidental -- sse.keepalive is illegal before sse.start (see
# DEVIATION D-1 / t/sse/14-keepalive-deferred-arm.t), so keepalive() called
# pre-start defers (records, sends nothing) rather than sending immediately.
# These tests exercise the still-immediate post-start behavior; the deferred
# pre-start path has its own dedicated coverage.

my @sent;
my $send = sub { push @sent, $_[0]; Future->done };
my $receive = sub { Future->new };  # Never resolves

subtest 'keepalive method exists' => sub {
    my $sse = PAGI::SSE->new({ type => 'sse' }, $receive, $send);
    ok($sse->can('keepalive'), 'keepalive method exists');
};

subtest 'keepalive sends sse.keepalive event' => sub {
    @sent = ();
    my $sse = PAGI::SSE->new({ type => 'sse' }, $receive, $send);
    $sse->start->get;

    $sse->keepalive(30)->get;

    is(scalar @sent, 2, 'sse.start then sse.keepalive');
    is($sent[1]{type}, 'sse.keepalive', 'correct event type');
    is($sent[1]{interval}, 30, 'correct interval');
    ok(!exists $sent[1]{comment} || $sent[1]{comment} eq '', 'no comment or empty comment when not specified');
};

subtest 'keepalive with comment sends both interval and comment' => sub {
    @sent = ();
    my $sse = PAGI::SSE->new({ type => 'sse' }, $receive, $send);
    $sse->start->get;

    $sse->keepalive(30, 'ping')->get;

    is(scalar @sent, 2, 'sse.start then sse.keepalive');
    is($sent[1]{type}, 'sse.keepalive', 'correct event type');
    is($sent[1]{interval}, 30, 'correct interval');
    is($sent[1]{comment}, 'ping', 'correct comment');
};

subtest 'keepalive returns self for chaining' => sub {
    my $sse = PAGI::SSE->new({ type => 'sse' }, $receive, $send);
    $sse->start->get;
    my $result = $sse->keepalive(25)->get;
    is(ref($result), ref($sse), 'returns same type');
    ok($result == $sse, 'returns $self for chaining');
};

subtest 'keepalive with 0 interval disables keepalive' => sub {
    @sent = ();
    my $sse = PAGI::SSE->new({ type => 'sse' }, $receive, $send);
    $sse->start->get;

    $sse->keepalive(0)->get;

    is(scalar @sent, 2, 'sse.start then keepalive');
    is($sent[1]{type}, 'sse.keepalive', 'correct event type');
    is($sent[1]{interval}, 0, 'interval is 0 to disable');
};

done_testing;
