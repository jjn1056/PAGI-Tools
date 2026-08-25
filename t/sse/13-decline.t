#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::SSE;

# A2: PAGI::SSE::decline -- lets an app reject an SSE request with a real
# HTTP response (an auth-gate 401, a 404, etc.) instead of streaming.
# Parity with PAGI::WebSocket::deny. Ratified: John 2026-08-24, A2 ruling in
# .pagi-0.4-alignment-tools-rulings.md -- "server has to be right -- nothing
# may follow the response terminal except declared trailers".

subtest 'decline sends sse.http.response.start + sse.http.response.body(more=>0)' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };

    my $sse = PAGI::SSE->new({ type => 'sse' }, sub { Future->new }, $send);
    $sse->decline(
        status  => 401,
        headers => [['content-type', 'text/plain'], ['www-authenticate', 'Bearer']],
        body    => 'Unauthorized',
    )->get;

    is(scalar @sent, 2, 'exactly two events sent');
    is($sent[0]{type}, 'sse.http.response.start', 'first event type');
    is($sent[0]{status}, 401, 'status passed through');
    is($sent[0]{headers}, [['content-type', 'text/plain'], ['www-authenticate', 'Bearer']], 'headers passed through');
    is($sent[1]{type}, 'sse.http.response.body', 'second event type');
    is($sent[1]{body}, 'Unauthorized', 'body passed through');
    is($sent[1]{more}, 0, 'single terminal chunk: more => 0');
};

subtest 'decline defaults: status 403, empty headers, empty body' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };

    my $sse = PAGI::SSE->new({ type => 'sse' }, sub { Future->new }, $send);
    $sse->decline->get;

    is($sent[0]{status}, 403, 'default status 403 (parity with $ws->deny)');
    is($sent[0]{headers}, [], 'default empty headers');
    is($sent[1]{body}, '', 'default empty body');
};

subtest 'decline marks the connection closed' => sub {
    my $send = sub { Future->done };
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub { Future->new }, $send);

    ok(!$sse->is_closed, 'not closed before decline');
    $sse->decline(status => 401)->get;
    ok($sse->is_closed, 'is_closed true after decline');
    ok(!$sse->is_started, 'is_started stays false -- the stream never started');
};

subtest 'start after decline sends nothing (safe no-op)' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub { Future->new }, $send);

    $sse->decline(status => 401)->get;
    my $before = scalar @sent;
    $sse->start->get;

    is(scalar @sent, $before, 'start after decline sent nothing further');
};

subtest 'run after decline returns immediately and sends nothing (safe no-op)' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    # receive would hang forever if run() ever tried to wait on it.
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub { Future->new }, $send);

    $sse->decline(status => 401)->get;
    my $before = scalar @sent;

    ok(lives { $sse->run->get }, 'run after decline returns without hanging or dying')
        or note $@;
    is(scalar @sent, $before, 'run after decline sent nothing further');
};

subtest 'send_event after decline is a safe no-op (no croak, nothing sent)' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub { Future->new }, $send);

    $sse->decline(status => 401)->get;
    my $before = scalar @sent;

    my $result;
    ok(lives { $result = $sse->send_event(data => 'x')->get }, 'send_event after decline does not croak')
        or note $@;
    is(scalar @sent, $before, 'send_event after decline sent nothing');
    ok($result == $sse, 'send_event after decline still returns $self for chaining');
};

# DEVIATION D-1 (signed off by John 2026-08-25): keepalive() called before
# the stream has started now defers -- it records the interval/comment
# instead of sending (sse.keepalive is illegal pre-start), and start() arms
# it afterward. So a keepalive requested before decline() is only ever a
# pending record, never something actually on the wire -- decline() drops
# it rather than disarming it. See t/sse/14-keepalive-deferred-arm.t for the
# full deferred-arm behavior; these subtests cover decline()'s side of it.

subtest 'a pending (pre-start) keepalive is dropped by decline, never sent at all' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub { Future->new }, $send);

    $sse->keepalive(25)->get;
    is(scalar @sent, 0, 'keepalive() pre-start recorded, did not send');

    $sse->decline(status => 401, body => 'no')->get;

    my @keepalive_events = grep { $_->{type} eq 'sse.keepalive' } @sent;
    is(scalar @keepalive_events, 0, 'no sse.keepalive ever reaches the wire -- nothing to disarm');
    is(scalar @sent, 2, 'only the decline response events were sent');

    # Once declined, keepalive() itself becomes a safe no-op -- calling it
    # again must not put a live timer on the wire.
    my $before = scalar @sent;
    $sse->keepalive(10)->get;
    is(scalar @sent, $before, 'keepalive after decline sent nothing');
};

subtest 'decline with no keepalive ever requested sends no keepalive event' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub { Future->new }, $send);

    $sse->decline(status => 401)->get;

    my @keepalive_events = grep { $_->{type} eq 'sse.keepalive' } @sent;
    is(scalar @keepalive_events, 0, 'no keepalive event when none was ever requested');
};

subtest 'a keepalive explicitly disabled (interval 0) before decline stays quiet' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub { Future->new }, $send);

    $sse->keepalive(0)->get;
    $sse->decline(status => 401)->get;

    my @keepalive_events = grep { $_->{type} eq 'sse.keepalive' } @sent;
    is(scalar @keepalive_events, 0, 'interval=>0 never sends pre-start either -- decline has nothing to drop');
};

subtest 'keepalive after ordinary close (not decline) is a safe no-op too' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub { Future->new }, $send);
    $sse->_set_closed;

    ok(lives { $sse->keepalive(30)->get }, 'keepalive after closed does not die');
    is(scalar @sent, 0, 'keepalive after closed sends nothing');
};

done_testing;
