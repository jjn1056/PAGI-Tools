#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Time::HiRes ();

use PAGI::Test::Client;

# Simple SSE app
my $sse_app = async sub {
    my ($scope, $receive, $send) = @_;
    die "Expected sse scope" unless ($scope->{type} // '') eq 'sse';

    await $send->({
        type    => 'sse.start',
        status  => 200,
        headers => [],
    });

    await $send->({
        type  => 'sse.send',
        event => 'connected',
        data  => '{"subscriber_id":1}',
    });

    await $send->({
        type => 'sse.send',
        data => 'plain message',
    });

    await $send->({
        type  => 'sse.send',
        event => 'update',
        data  => '{"count":42}',
        id    => 'msg-1',
    });
};

subtest 'sse receive events' => sub {
    my $client = PAGI::Test::Client->new(app => $sse_app);
    $client->sse('/events', sub {
        my ($sse) = @_;

        my $event = $sse->receive_event;
        is $event->{event}, 'connected', 'first event type';
        is $event->{data}, '{"subscriber_id":1}', 'first event data';

        my $plain = $sse->receive_event;
        is $plain->{data}, 'plain message', 'plain message data';
        ok !defined $plain->{event}, 'no event type for plain';

        my $update = $sse->receive_event;
        is $update->{event}, 'update', 'update event type';
        is $update->{id}, 'msg-1', 'event id';
    });
};

subtest 'sse receive_json convenience' => sub {
    my $client = PAGI::Test::Client->new(app => $sse_app);
    $client->sse('/events', sub {
        my ($sse) = @_;
        my $data = $sse->receive_json;
        is $data->{subscriber_id}, 1, 'json parsed';
    });
};

subtest 'sse explicit style' => sub {
    my $client = PAGI::Test::Client->new(app => $sse_app);
    my $sse = $client->sse('/events');
    my $event = $sse->receive_event;
    is $event->{event}, 'connected', 'explicit style works';
    $sse->close;
};

subtest 'receive_event waits for an event sent after real I/O' => sub {
    require Future::IO;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'sse.start', status => 200, headers => [] });
        await Future::IO->sleep(0.2);
        await $send->({ type => 'sse.send', data => 'after sleep' });
        while (1) {    # until the client closes
            my $event = await $receive->();
            last if ($event->{type} // '') eq 'sse.disconnect';
        }
    };
    my $sse = PAGI::Test::Client->new(app => $app)->sse('/events');
    is($sse->receive_event(timeout => 2)->{data}, 'after sleep', 'the event arrives');

    my $started = Time::HiRes::time();
    like(dies { $sse->receive_event(timeout => 0.5) }, qr/Timeout waiting for SSE event/,
        'a later receive still times out');
    ok(Time::HiRes::time() - $started >= 0.4, 'after its timeout, not at once');
    $sse->close;
};

subtest 'a handler that awaits real I/O before start connects' => sub {
    require Future::IO;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await Future::IO->sleep(0.1);
        await $send->({ type => 'sse.start', status => 200, headers => [] });
        await $send->({ type => 'sse.send', data => 'hello' });
        while (1) {    # until the client closes
            my $event = await $receive->();
            last if ($event->{type} // '') eq 'sse.disconnect';
        }
    };
    my $sse = PAGI::Test::Client->new(app => $app)->sse('/events');
    is($sse->receive_event(timeout => 2)->{data}, 'hello', 'the stream is started');
    $sse->close;
};

subtest 'a stream start that times out is abandoned' => sub {
    require Future::IO;
    local $PAGI::Test::_Drive::TIMEOUT = 0.2;
    my $resumed = 0;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await Future::IO->sleep(0.4);
        $resumed = 1;
        await $send->({ type => 'sse.start', status => 200, headers => [] });
    };
    like(dies { PAGI::Test::Client->new(app => $app)->sse('/events') },
        qr/SSE stream did not start within 0\.2 seconds/, 'it says it timed out');
    Future::IO->sleep(0.4)->get;    # drive the loop past the handler's wake-up
    is($resumed, 0, 'and the handler does not resume later');
};

done_testing;
