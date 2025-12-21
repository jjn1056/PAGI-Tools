#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::WebSocket;

subtest 'constructor accepts scope, receive, send' => sub {
    my $scope = {
        type         => 'websocket',
        path         => '/ws',
        query_string => 'token=abc',
        headers      => [
            ['host', 'example.com'],
            ['sec-websocket-protocol', 'chat, echo'],
        ],
        subprotocols => ['chat', 'echo'],
        client       => ['127.0.0.1', 54321],
    };
    my $receive = sub { };
    my $send = sub { };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

    ok($ws, 'constructor returns object');
    isa_ok($ws, 'PAGI::WebSocket');

    # Verify internal state
    is($ws->{_state}, 'connecting', 'initial state is connecting');
    is($ws->{_close_code}, undef, 'close_code starts undefined');
    is($ws->{_close_reason}, undef, 'close_reason starts undefined');
    is($ws->{_on_close}, [], 'on_close callbacks start empty');
    is($ws->{scope}, $scope, 'scope is stored');
    is($ws->{receive}, $receive, 'receive is stored');
    is($ws->{send}, $send, 'send is stored');
};

subtest 'dies on non-websocket scope type' => sub {
    my $scope = { type => 'http', headers => [] };
    my $receive = sub { };
    my $send = sub { };

    like(
        dies { PAGI::WebSocket->new($scope, $receive, $send) },
        qr/websocket/i,
        'dies with message about websocket'
    );
};

subtest 'dies without required parameters' => sub {
    like(
        dies { PAGI::WebSocket->new() },
        qr/scope/i,
        'dies without scope'
    );

    my $scope = { type => 'websocket', headers => [] };
    like(
        dies { PAGI::WebSocket->new($scope) },
        qr/receive/i,
        'dies without receive'
    );

    my $receive = sub { };
    like(
        dies { PAGI::WebSocket->new($scope, $receive) },
        qr/send/i,
        'dies without send'
    );
};

subtest 'dies on invalid parameter types' => sub {
    like(
        dies { PAGI::WebSocket->new("not_a_hash", sub {}, sub {}) },
        qr/hashref/i,
        'dies when scope is not a hashref'
    );

    my $scope = { type => 'websocket', headers => [] };
    like(
        dies { PAGI::WebSocket->new($scope, "not_a_coderef", sub {}) },
        qr/receive.*coderef/i,
        'dies when receive is not a coderef'
    );

    like(
        dies { PAGI::WebSocket->new($scope, sub {}, "not_a_coderef") },
        qr/send.*coderef/i,
        'dies when send is not a coderef'
    );
};

done_testing;
