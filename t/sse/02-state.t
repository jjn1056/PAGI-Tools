#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;

use lib 'lib';
use lib 't/lib';
use PAGI::SSE;
use PAGITest::Connected qw(sse_scope);

subtest 'initial state is pending' => sub {
    my $sse = PAGI::SSE->new(sse_scope(), sub {}, sub {});

    is($sse->connection_state, 'pending', 'initial connection_state is pending');
    ok(!$sse->is_started, 'is_started is false');
    ok(!$sse->is_closed, 'is_closed is false');
    ok(!$sse->is_connected, 'pending SSE is not connected');
};

subtest 'state transitions' => sub {
    my $scope = sse_scope();
    my $sse = PAGI::SSE->new($scope, sub {}, sub { Future->done });

    $sse->start->get;
    is($sse->connection_state, 'started', 'connection_state is started');
    ok($sse->is_started, 'is_started is true');
    ok(!$sse->is_closed, 'is_closed is false');
    ok($sse->is_connected, 'started SSE is connected');

    $scope->{'pagi.connection'}->_mark_disconnected('client_closed');
    is($sse->connection_state, 'closed', 'connection_state is closed');
    ok(!$sse->is_started, 'is_started is false after close');
    ok($sse->is_closed, 'is_closed is true');
    ok(!$sse->is_connected, 'closed SSE is not connected');
};

done_testing;
