#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use JSON::MaybeXS;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::Endpoint::WebSocket;

package EchoEndpoint {
    use parent 'PAGI::Endpoint::WebSocket';
    use Future::AsyncAwait;

    our @log;
    our ($seen_connect, $seen_receive, $seen_disconnect);

    async sub on_connect {
        my ($self, $websocket) = @_;
        push @log, 'connect';
        $seen_connect = $websocket;
        await $websocket->accept;
    }

    async sub on_receive {
        my ($self, $websocket, $data) = @_;
        push @log, "receive:$data";
        $seen_receive //= $websocket;
        await $websocket->send_text("echo:$data");
    }

    sub on_disconnect {
        my ($self, $websocket, $code, $reason) = @_;
        $seen_disconnect = $websocket;
        push @log, "disconnect:$code";
    }
}

subtest 'lifecycle via to_app' => sub {
    @EchoEndpoint::log = ();
    ($EchoEndpoint::seen_connect, $EchoEndpoint::seen_receive,
        $EchoEndpoint::seen_disconnect) = ();

    my $app = EchoEndpoint->to_app;
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };

    # Simulate: connect, send "hello", send "world", disconnect
    my @events = (
        { type => 'websocket.receive', text => 'hello' },
        { type => 'websocket.receive', text => 'world' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };

    my $scope = {
        type    => 'websocket',
        path    => '/ws/echo',
        headers => [],
    };

    $app->($scope, $receive, $send)->get;

    is($EchoEndpoint::log[0], 'connect', 'on_connect called');
    is($EchoEndpoint::log[1], 'receive:hello', 'first message');
    is($EchoEndpoint::log[2], 'receive:world', 'second message');
    like($EchoEndpoint::log[3], qr/disconnect/, 'on_disconnect called');
    is(ref($EchoEndpoint::seen_connect), 'PAGI::WebSocket',
        'connect receives direct channel');
    is(refaddr($EchoEndpoint::seen_connect), refaddr($EchoEndpoint::seen_receive),
        'receive sees the exact connection object');
    is(refaddr($EchoEndpoint::seen_connect), refaddr($EchoEndpoint::seen_disconnect),
        'disconnect sees the exact connection object');
    is(refaddr($EchoEndpoint::seen_connect->scope), refaddr($scope),
        'channel owns the exact selected scope');

    # Check accept was sent
    ok((grep { ($_->{type} // '') eq 'websocket.accept' } @sent), 'accept sent');
};

subtest 'immediate on_connect and on_receive results are normalized' => sub {
    {
        package ImmediateEndpoint;
        use parent 'PAGI::Endpoint::WebSocket';

        our @seen;

        sub on_connect {
            my ($self, $websocket) = @_;
            push @seen, ref($websocket);
            $websocket->accept;
            return 'immediate connect result';
        }

        sub on_receive {
            my ($self, $websocket, $data) = @_;
            push @seen, "$data:" . ref($websocket);
            return 'immediate receive result';
        }
    }

    my $app = ImmediateEndpoint->to_app;
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my @events = (
        { type => 'websocket.receive', text => 'hello' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $receive = sub { Future->done(shift @events) };

    $app->({ type => 'websocket', path => '/ws', headers => [] },
           $receive, $send)->get;

    is(\@ImmediateEndpoint::seen, [
        'PAGI::WebSocket',
        'hello:PAGI::WebSocket',
    ], 'direct callbacks accept immediate return values');
};

subtest 'failed callback Future propagates through the endpoint app' => sub {
    {
        package FailingReceiveEndpoint;
        use parent 'PAGI::Endpoint::WebSocket';

        sub on_connect { $_[1]->accept }
        sub on_receive { Future->fail("receive hook failed\n") }
    }

    like(dies {
        FailingReceiveEndpoint->to_app->(
            { type => 'websocket', path => '/ws', headers => [] },
            sub { Future->done({ type => 'websocket.receive', text => 'boom' }) },
            sub { Future->done },
        )->get;
    }, qr/receive hook failed/, 'failed receive Future is not swallowed');
};

subtest 'on_disconnect remains synchronous and its return is not awaited' => sub {
    {
        package SynchronousDisconnectEndpoint;
        use parent 'PAGI::Endpoint::WebSocket';
        our $returned = Future->new;
        our $called = 0;

        sub on_connect { $_[1]->accept }
        sub on_disconnect {
            $called++;
            return $returned;
        }
    }

    $SynchronousDisconnectEndpoint::returned = Future->new;
    $SynchronousDisconnectEndpoint::called = 0;
    my $running = SynchronousDisconnectEndpoint->to_app->(
        { type => 'websocket', path => '/ws', headers => [] },
        sub { Future->done({ type => 'websocket.disconnect', code => 1000 }) },
        sub { Future->done },
    );
    is($running->get, undef, 'endpoint completes without disconnect return');
    is($SynchronousDisconnectEndpoint::called, 1, 'disconnect hook was called');
    ok(!$SynchronousDisconnectEndpoint::returned->is_ready,
        'disconnect return Future was not awaited');
};

done_testing;
