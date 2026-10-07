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
use lib 't/lib';
use PAGITest::Connected qw(ws_scope receive_from);

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

{
    package TextAdapterEndpoint;
    use parent 'PAGI::Endpoint::WebSocket';
    our @received;
    sub on_receive { push @received, $_[2] }
}

{
    package BytesAdapterEndpoint;
    use parent 'PAGI::Endpoint::WebSocket';
    our @received;
    sub encoding { 'bytes' }
    sub on_receive { push @received, $_[2] }
}

{
    package JSONAdapterEndpoint;
    use parent 'PAGI::Endpoint::WebSocket';
    our @received;
    sub encoding { 'json' }
    sub on_receive { push @received, $_[2] }
}

{
    package Local::ConfiguredWebSocket;
    use parent 'PAGI::Endpoint::WebSocket';
    our $NEW_CALLS = 0;
    our @SEEN_IDS;

    sub new {
        my ($class, @args) = @_;
        $NEW_CALLS++;
        return PAGI::Endpoint::WebSocket::new($class, @args);
    }

    sub on_connect {
        push @SEEN_IDS, Scalar::Util::refaddr($_[0]);
        return $_[1]->accept;
    }
}

{
    package Local::OverlappingConfiguredWebSocket;
    use parent 'PAGI::Endpoint::WebSocket';

    our (%GATES, @RECEIVER_IDS, @PROTOCOL_IDS, @SCOPE_IDS);

    async sub on_connect {
        my ($self, $websocket) = @_;
        my $path = $websocket->scope->{path};

        push @RECEIVER_IDS, Scalar::Util::refaddr($self);
        push @PROTOCOL_IDS, Scalar::Util::refaddr($websocket);
        push @SCOPE_IDS, Scalar::Util::refaddr($websocket->scope);

        await $GATES{$path};
        await $websocket->accept;
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
    my $scope   = ws_scope(path => '/ws/echo');
    my $receive = receive_from($scope, @events);

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

subtest 'configured endpoint to_app retains the exact object across connections' => sub {
    $Local::ConfiguredWebSocket::NEW_CALLS = 0;
    @Local::ConfiguredWebSocket::SEEN_IDS = ();

    my $hub = {};
    my $configured = Local::ConfiguredWebSocket->new(hub => $hub);
    my $app = $configured->to_app;

    for my $connection (1, 2) {
        my $scope = ws_scope(path => "/chat/$connection");
        $app->(
            $scope,
            receive_from($scope, { type => 'websocket.disconnect', code => 1000 }),
            sub { Future->done },
        )->get;
    }

    is $Local::ConfiguredWebSocket::NEW_CALLS, 1,
        'configured object was not reconstructed';
    is \@Local::ConfiguredWebSocket::SEEN_IDS,
        [refaddr($configured), refaddr($configured)],
        'connections use the exact configured object';
};

subtest 'overlapping connections retain the endpoint and isolate connection objects' => sub {
    my $first_gate = Future->new;
    my $second_gate = Future->new;
    %Local::OverlappingConfiguredWebSocket::GATES = (
        '/chat/first'  => $first_gate,
        '/chat/second' => $second_gate,
    );
    @Local::OverlappingConfiguredWebSocket::RECEIVER_IDS = ();
    @Local::OverlappingConfiguredWebSocket::PROTOCOL_IDS = ();
    @Local::OverlappingConfiguredWebSocket::SCOPE_IDS = ();

    my $endpoint = Local::OverlappingConfiguredWebSocket->new(hub => {});
    my $app = $endpoint->to_app;
    my $first_scope  = ws_scope(path => '/chat/first');
    my $second_scope = ws_scope(path => '/chat/second');
    my $disconnect   = { type => 'websocket.disconnect', code => 1000 };

    my $first = $app->($first_scope, receive_from($first_scope, $disconnect),
        sub { Future->done });
    ok(!$first->is_ready, 'the first connection is held inside on_connect');
    is scalar(@Local::OverlappingConfiguredWebSocket::RECEIVER_IDS), 1,
        'the first connection entered the endpoint before the second began';

    my $second = $app->($second_scope, receive_from($second_scope, $disconnect),
        sub { Future->done });
    ok(!$second->is_ready,
        'the second connection overlaps the first inside on_connect');
    is \@Local::OverlappingConfiguredWebSocket::RECEIVER_IDS,
        [refaddr($endpoint), refaddr($endpoint)],
        'both in-flight connections use the exact configured endpoint';
    isnt $Local::OverlappingConfiguredWebSocket::PROTOCOL_IDS[0],
        $Local::OverlappingConfiguredWebSocket::PROTOCOL_IDS[1],
        'overlapping connections receive distinct WebSocket objects';
    is \@Local::OverlappingConfiguredWebSocket::SCOPE_IDS,
        [refaddr($first_scope), refaddr($second_scope)],
        'each WebSocket retains its own exact connection scope';

    $first_gate->done;
    $second_gate->done;
    is $first->get, undef, 'the released first connection completes cleanly';
    is $second->get, undef, 'the released second connection completes cleanly';
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
    my $scope   = ws_scope(path => '/ws');
    my $receive = receive_from($scope, @events);

    $app->($scope, $receive, $send)->get;

    is(\@ImmediateEndpoint::seen, [
        'PAGI::WebSocket',
        'hello:PAGI::WebSocket',
    ], 'direct callbacks accept immediate return values');
};

subtest 'on_receive dispatches each declared message encoding' => sub {
    for my $case (
        {
            name     => 'text',
            endpoint => 'TextAdapterEndpoint',
            received => \@TextAdapterEndpoint::received,
            events   => [
                { type => 'websocket.receive', bytes => "\x00\xff" },
                { type => 'websocket.receive', text => 'plain text' },
                { type => 'websocket.disconnect', code => 1000 },
            ],
            want => ['plain text'],
        },
        {
            name     => 'bytes',
            endpoint => 'BytesAdapterEndpoint',
            received => \@BytesAdapterEndpoint::received,
            events   => [
                { type => 'websocket.receive', text => 'ignored text' },
                { type => 'websocket.receive', bytes => "\x00\xff" },
                { type => 'websocket.disconnect', code => 1000 },
            ],
            want => ["\x00\xff"],
        },
        {
            name     => 'json',
            endpoint => 'JSONAdapterEndpoint',
            received => \@JSONAdapterEndpoint::received,
            events   => [
                { type => 'websocket.receive', bytes => 'ignored bytes' },
                { type => 'websocket.receive', text => '{"kind":"notice","count":2}' },
                { type => 'websocket.disconnect', code => 1000 },
            ],
            want => [{ kind => 'notice', count => 2 }],
        },
    ) {
        subtest "$case->{name} adapter" => sub {
            @{$case->{received}} = ();
            my @sent;
            my $app = $case->{endpoint}->to_app;
            my $scope = ws_scope(path => '/ws');

            $app->(
                $scope,
                receive_from($scope, @{$case->{events}}),
                sub { push @sent, $_[0]; Future->done },
            )->get;

            is($case->{received}, $case->{want},
                "on_receive receives decoded $case->{name} frames only");
        };
    }
};

subtest 'no on_connect override accepts the connection automatically' => sub {
    my @sent;
    my $scope = ws_scope(path => '/ws');
    PAGI::Endpoint::WebSocket->to_app->(
        $scope,
        receive_from($scope, { type => 'websocket.disconnect', code => 1000 }),
        sub { push @sent, $_[0]; Future->done },
    )->get;

    is([map { $_->{type} } @sent], ['websocket.accept'],
        'the default on_connect implementation accepts once');
};

subtest 'failed callback Future propagates through the endpoint app' => sub {
    {
        package FailingReceiveEndpoint;
        use parent 'PAGI::Endpoint::WebSocket';

        sub on_connect { $_[1]->accept }
        sub on_receive { Future->fail("receive hook failed\n") }
    }

    my $scope = ws_scope(path => '/ws');
    like(dies {
        FailingReceiveEndpoint->to_app->(
            $scope,
            receive_from($scope, { type => 'websocket.receive', text => 'boom' }),
            sub { Future->done },
        )->get;
    }, qr/receive hook failed/, 'failed receive Future is not swallowed');
};

subtest 'on_disconnect Future is awaited by cleanup' => sub {
    {
        package SynchronousDisconnectEndpoint;
        use parent 'PAGI::Endpoint::WebSocket';
        our $returned = Future->new;
        our $called = 0;
        our $later_cleanup = 0;

        # Registered after the endpoint's own disconnect hook, so it runs
        # only once that hook's Future has settled.
        sub on_connect {
            $_[1]->on_close(sub { $later_cleanup++ });
            return $_[1]->accept;
        }
        sub on_disconnect {
            $called++;
            return $returned;
        }
    }

    $SynchronousDisconnectEndpoint::returned = Future->new;
    $SynchronousDisconnectEndpoint::called = 0;
    $SynchronousDisconnectEndpoint::later_cleanup = 0;
    my $scope = ws_scope(path => '/ws');
    my $running = SynchronousDisconnectEndpoint->to_app->(
        $scope,
        receive_from($scope, { type => 'websocket.disconnect', code => 1000 }),
        sub { Future->done },
    );
    ok(!$running->is_ready,
        'the endpoint call waits while connection-end cleanup continues');
    is($SynchronousDisconnectEndpoint::called, 1, 'disconnect hook was called');
    ok(!$SynchronousDisconnectEndpoint::returned->is_ready,
        'disconnect return Future is pending');
    is($SynchronousDisconnectEndpoint::later_cleanup, 0,
        'cleanup awaits disconnect hook');
    $SynchronousDisconnectEndpoint::returned->done;
    is($SynchronousDisconnectEndpoint::later_cleanup, 1,
        'cleanup continues after disconnect hook settles');
    ok($running->is_ready, 'then the endpoint call completes');
    is($running->get, undef, 'endpoint completes cleanly');
};

done_testing;
