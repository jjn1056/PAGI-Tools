#!/usr/bin/env perl
use strict;
use warnings;

use Test2::V0;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::Request;
use PAGI::SSE;
use PAGI::WebSocket;
use lib 't/lib';
use PAGITest::Connected qw(ws_scope sse_scope);

subtest 'WebSocket uses the shared PAGI header container' => sub {
    my $scope = ws_scope(
        headers => [['X-Trace', 'one'], ['x-trace', 'two']],
    );
    my $websocket = PAGI::WebSocket->new(
        $scope,
        sub { die 'unexpected receive' },
        sub { die 'unexpected send' },
    );

    isa_ok($websocket->headers, ['PAGI::Headers'], 'one header container');
    is($websocket->headers->get('X-TRACE'), 'one, two', 'case-insensitive lookup (D1: repeated fields join)');
    is([$websocket->header_all('x-TrAcE')], ['one', 'two'], 'repeated values');
    is(refaddr($scope->{'pagi.request.headers'}), refaddr($websocket->headers),
        'scope caches the public header container');
};

subtest 'SSE uses the shared PAGI header container' => sub {
    my $scope = sse_scope(
        headers => [['X-Trace', 'one'], ['x-trace', 'two']],
    );
    my $sse = PAGI::SSE->new(
        $scope,
        sub { die 'unexpected receive' },
        sub { die 'unexpected send' },
    );

    isa_ok($sse->headers, ['PAGI::Headers'], 'one header container');
    is($sse->headers->get('X-TRACE'), 'one, two', 'case-insensitive lookup (D1: repeated fields join)');
    is([$sse->header_all('x-TrAcE')], ['one', 'two'], 'repeated values');
    is(refaddr($scope->{'pagi.request.headers'}), refaddr($sse->headers),
        'scope caches the public header container');
};

subtest 'Request and WebSocket each parse headers, Request first' => sub {
    my $scope = ws_scope(
        scheme  => 'ws',
        path    => '/socket',
        headers => [['X-Trace', 'one'], ['x-trace', 'two']],
    );
    my $receive = sub { die 'metadata must not receive' };
    my $request = PAGI::Request->new($scope, $receive);
    my $cached = $request->headers;
    my $websocket = PAGI::WebSocket->new(
        $scope, $receive, sub { die 'unexpected send' },
    );

    is(refaddr($request->scope), refaddr($scope), 'Request keeps original scope');
    isnt(refaddr($websocket->headers), refaddr($cached), 'WebSocket parses its own');
    is($websocket->header('X-TRACE'), 'one, two', 'to the same value (D1: repeated fields join)');
    is($request->header('X-TRACE'), 'one, two', 'Request lookup uses its own snapshot');
};

subtest 'Request and WebSocket each parse headers, WebSocket first' => sub {
    my $scope = ws_scope(
        scheme  => 'wss',
        path    => '/socket',
        headers => [['X-Trace', 'one'], ['x-trace', 'two']],
    );
    my $receive = sub { die 'metadata must not receive' };
    my $websocket = PAGI::WebSocket->new(
        $scope, $receive, sub { die 'unexpected send' },
    );
    my $cached = $websocket->headers;
    my $request = PAGI::Request->new($scope, $receive);

    is(refaddr($request->scope), refaddr($scope), 'Request keeps original scope');
    isnt(refaddr($request->headers), refaddr($cached), 'Request parses its own');
    is($request->header('X-TRACE'), 'one, two', 'helper-first lookup joins (D1)');
    is($request->method, undef, 'Request does not fabricate a WebSocket method');
    is($request->scheme, 'wss', 'Request preserves the native WebSocket scheme');
};

subtest 'Request and SSE each parse headers in both access orders' => sub {
    for my $request_first (0, 1) {
        my $scope = sse_scope(
            scheme  => 'https',
            path    => '/events',
            headers => [['X-Trace', 'one'], ['x-trace', 'two']],
        );
        my $receive = sub { die 'metadata must not receive' };
        my $request = PAGI::Request->new($scope, $receive);
        my $sse = PAGI::SSE->new(
            $scope, $receive, sub { die 'unexpected send' },
        );
        my $first = $request_first ? $request->headers : $sse->headers;
        my $second = $request_first ? $sse->headers : $request->headers;

        isnt(refaddr($second), refaddr($first),
            ($request_first ? 'Request-first' : 'SSE-first') . ': each parses its own');
        is($request->header('X-TRACE'), 'one, two', 'Request reads its own snapshot (D1: joined)');
        is($sse->header('X-TRACE'), 'one, two', 'SSE reads the same value');
    }
};

done_testing;
