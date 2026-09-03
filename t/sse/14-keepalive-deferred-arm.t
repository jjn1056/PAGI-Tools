#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Response::Text;
use PAGI::SSE;

# DEVIATION D-1 (signed off by John 2026-08-25): sse.keepalive sent before
# sse.start is illegal (both PAGI::Utils::_SendValidation and the reference server's
# EventValidator reject it from the pre-start state). keepalive() called
# before the stream has started must RECORD the desired interval/comment
# instead of sending; start() then arms the recorded keepalive immediately
# after sending sse.start, where it is legal. See t/endpoint/14-sse-keepalive-
# ordering.t for the end-to-end reproduction through the strict Test::Client.

subtest 'keepalive before start records but sends nothing' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub { Future->new }, $send);

    $sse->keepalive(25)->get;

    is(scalar @sent, 0, 'nothing sent yet -- sse.keepalive would be illegal before sse.start');
    ok(!$sse->is_started, 'still not started');
};

subtest 'start() arms a pending keepalive immediately after sse.start' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub { Future->new }, $send);

    $sse->keepalive(25, 'ping')->get;
    $sse->start->get;

    is(scalar @sent, 2, 'two events sent by the time start() resolves');
    is($sent[0]{type}, 'sse.start', 'sse.start sent first');
    is($sent[1]{type}, 'sse.keepalive', 'sse.keepalive sent second -- after sse.start');
    is($sent[1]{interval}, 25, 'recorded interval was armed');
    is($sent[1]{comment}, 'ping', 'recorded comment was armed');
};

subtest 'keepalive(0) before start clears any pending record -- start() arms nothing' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub { Future->new }, $send);

    $sse->keepalive(25)->get;   # record interval 25
    $sse->keepalive(0)->get;    # explicitly disable -- clears the record
    $sse->start->get;

    is(scalar @sent, 1, 'only sse.start was sent -- no keepalive, armed or otherwise');
    is($sent[0]{type}, 'sse.start', 'sse.start');
};

subtest 'start() with no keepalive ever requested arms nothing' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub { Future->new }, $send);

    $sse->start->get;

    is(scalar @sent, 1, 'only sse.start');
};

subtest 'keepalive after start still sends immediately (unchanged: legal from the streaming state)' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub { Future->new }, $send);

    $sse->start->get;
    $sse->keepalive(30)->get;

    is(scalar @sent, 2, 'sse.start then sse.keepalive');
    is($sent[1]{type}, 'sse.keepalive', 'sent immediately, no deferral once started');
    is($sent[1]{interval}, 30, 'correct interval');
};

subtest 'decline clears a recorded-but-never-armed pending keepalive' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub { Future->new }, $send);

    $sse->keepalive(25)->get;               # recorded, not yet sent (pre-start)
    $sse->decline(PAGI::Response::Text->new('Unauthorized', status => 401))->get;

    # No sse.keepalive ever reaches the wire -- it was never armed, so
    # there is nothing to disarm either.
    my @keepalive_events = grep { $_->{type} eq 'sse.keepalive' } @sent;
    is(scalar @keepalive_events, 0, 'no keepalive event at all -- recorded state was simply dropped');

    is(scalar @sent, 2, 'only the decline response events were sent');
    is($sent[0]{type}, 'sse.http.response.start', 'decline start');
    is($sent[1]{type}, 'sse.http.response.body', 'decline body');
};

subtest 'start() after decline does not resurrect a cleared pending keepalive' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub { Future->new }, $send);

    $sse->keepalive(25)->get;
    $sse->decline(PAGI::Response::Text->new('Unauthorized', status => 401))->get;
    my $before = scalar @sent;

    $sse->start->get;   # safe no-op per Task 8 -- must not arm anything either

    is(scalar @sent, $before, 'start() after decline is still a full no-op');
};

done_testing;
