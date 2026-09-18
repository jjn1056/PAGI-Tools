#!/usr/bin/env perl
use strict;
use warnings;

use Test2::V0;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::SSE;
use PAGI::WebSocket;

subtest 'WebSocket uses the shared PAGI header container' => sub {
    my $scope = {
        type    => 'websocket',
        headers => [['X-Trace', 'one'], ['x-trace', 'two']],
    };
    my $websocket = PAGI::WebSocket->new(
        $scope,
        sub { die 'unexpected receive' },
        sub { die 'unexpected send' },
    );

    isa_ok($websocket->headers, ['PAGI::Headers'], 'one header container');
    is($websocket->headers->get('X-TRACE'), 'two', 'case-insensitive lookup');
    is([$websocket->header_all('x-TrAcE')], ['one', 'two'], 'repeated values');
    is(refaddr($scope->{'pagi.request.headers'}), refaddr($websocket->headers),
        'scope caches the public header container');
};

subtest 'SSE uses the shared PAGI header container' => sub {
    my $scope = {
        type    => 'sse',
        headers => [['X-Trace', 'one'], ['x-trace', 'two']],
    };
    my $sse = PAGI::SSE->new(
        $scope,
        sub { die 'unexpected receive' },
        sub { die 'unexpected send' },
    );

    isa_ok($sse->headers, ['PAGI::Headers'], 'one header container');
    is($sse->headers->get('X-TRACE'), 'two', 'case-insensitive lookup');
    is([$sse->header_all('x-TrAcE')], ['one', 'two'], 'repeated values');
    is(refaddr($scope->{'pagi.request.headers'}), refaddr($sse->headers),
        'scope caches the public header container');
};

done_testing;
