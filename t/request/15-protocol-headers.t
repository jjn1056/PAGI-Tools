#!/usr/bin/env perl
use strict;
use warnings;

use Test2::V0;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::Request;
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

subtest 'Request and WebSocket share headers when Request reads first' => sub {
    my $scope = {
        type    => 'websocket',
        scheme  => 'ws',
        path    => '/socket',
        headers => [['X-Trace', 'one'], ['x-trace', 'two']],
    };
    my $receive = sub { die 'metadata must not receive' };
    my $request = PAGI::Request->new($scope, $receive);
    my $cached = $request->headers;
    my $websocket = PAGI::WebSocket->new(
        $scope, $receive, sub { die 'unexpected send' },
    );

    is(refaddr($request->scope), refaddr($scope), 'Request keeps original scope');
    is(refaddr($websocket->headers), refaddr($cached), 'WebSocket reuses Request cache');
    is($request->header('X-TRACE'), 'two', 'Request lookup uses shared snapshot');
};

subtest 'Request and WebSocket share headers when WebSocket reads first' => sub {
    my $scope = {
        type    => 'websocket',
        scheme  => 'wss',
        path    => '/socket',
        headers => [['X-Trace', 'one'], ['x-trace', 'two']],
    };
    my $receive = sub { die 'metadata must not receive' };
    my $websocket = PAGI::WebSocket->new(
        $scope, $receive, sub { die 'unexpected send' },
    );
    my $cached = $websocket->headers;
    my $request = PAGI::Request->new($scope, $receive);

    is(refaddr($request->scope), refaddr($scope), 'Request keeps original scope');
    is(refaddr($request->headers), refaddr($cached), 'Request reuses WebSocket cache');
    is($request->header('X-TRACE'), 'two', 'helper-first lookup remains last-value');
    is($request->method, undef, 'Request does not fabricate a WebSocket method');
    is($request->scheme, 'wss', 'Request preserves the native WebSocket scheme');
};

subtest 'Request and SSE share headers in both access orders' => sub {
    for my $request_first (0, 1) {
        my $scope = {
            type    => 'sse',
            scheme  => 'https',
            path    => '/events',
            headers => [['X-Trace', 'one'], ['x-trace', 'two']],
        };
        my $receive = sub { die 'metadata must not receive' };
        my $request = PAGI::Request->new($scope, $receive);
        my $sse = PAGI::SSE->new(
            $scope, $receive, sub { die 'unexpected send' },
        );
        my $first = $request_first ? $request->headers : $sse->headers;
        my $second = $request_first ? $sse->headers : $request->headers;

        is(refaddr($second), refaddr($first),
            ($request_first ? 'Request-first' : 'SSE-first') . ' access shares one cache');
        is($request->header('X-TRACE'), 'two', 'Request reads the shared SSE snapshot');
    }
};

done_testing;
