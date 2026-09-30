#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;

use lib 'lib';
use lib 't/lib';
use PAGI::WebSocket;
use PAGITest::Connected qw(ws_scope receive_from);

subtest 'initial state is connecting' => sub {
    my $scope = ws_scope();
    my $ws = PAGI::WebSocket->new($scope, sub {}, sub {});

    ok(!$ws->is_connected, 'not connected initially');
    ok(!$ws->is_closed, 'not closed initially');
    is($ws->connection_state, 'connecting', 'connection_state is connecting');
    is($ws->close_code, undef, 'close_code is undef');
    is($ws->close_reason, undef, 'close_reason is undef');
};

subtest 'state transitions' => sub {
    my $scope = ws_scope();
    my $ws = PAGI::WebSocket->new($scope, sub {}, sub { Future->done });

    $ws->accept->get;
    ok($ws->is_connected, 'is_connected after transition');
    ok(!$ws->is_closed, 'not closed after connect');
    is($ws->connection_state, 'connected', 'connection_state is connected');

    # The peer closes and the server completes the connection.
    my $connection = $scope->{'pagi.connection'};
    $connection->_set_peer_close(1000, 'Normal closure');
    $connection->_mark_complete;
    ok(!$ws->is_connected, 'not connected after close');
    ok($ws->is_closed, 'is_closed after close');
    is($ws->connection_state, 'closed', 'connection_state is closed');
    is($ws->close_code, 1000, 'close_code is set');
    is($ws->close_reason, 'Normal closure', 'close_reason is set');
};

subtest 'close_code defaults' => sub {
    my $scope = ws_scope();
    my $receive = receive_from($scope, { type => 'websocket.disconnect' });
    my $ws = PAGI::WebSocket->new($scope, $receive, sub { Future->done });
    $ws->accept->get;

    # The peer's Close carried no status code.
    is($ws->receive->get, undef, 'receive returns undef on disconnect');
    is($ws->close_code, 1005, 'close_code defaults to 1005 (no status)');
    is($ws->close_reason, undef, 'close_reason is undef when the Close had no status');
};

done_testing;
