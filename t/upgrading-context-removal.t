#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::App::Router;
use PAGI::Endpoint::HTTP;
use PAGI::Endpoint::SSE;
use PAGI::Endpoint::WebSocket;
use PAGI::Middleware::ErrorHandler;
use PAGI::Response;
use PAGI::Stash qw(stash);
use PAGI::Test::Client;

{
    package Local::UpgradeStatusError;

    sub new { return bless { status => $_[1] }, $_[0] }
    sub status_code { return $_[0]{status} }
}

subtest 'Context hooks and modules are removed' => sub {
    ok(!PAGI::Endpoint::HTTP->can('context_class'),
        'HTTP Endpoint has no context_class hook');
    ok(!PAGI::Endpoint::WebSocket->can('context_class'),
        'WebSocket Endpoint has no context_class hook');
    ok(!PAGI::Endpoint::SSE->can('context_class'),
        'SSE Endpoint has no context_class hook');

    for my $path (
        'lib/PAGI/Context.pm',
        'lib/PAGI/Context/HTTP.pm',
        'lib/PAGI/Context/WebSocket.pm',
        'lib/PAGI/Context/SSE.pm',
    ) {
        ok(!-e $path, "$path is absent");
    }
};

subtest 'direct routes receive their protocol objects' => sub {
    my ($request_seen, $websocket_seen, $sse_seen);
    my $router = PAGI::App::Router->new;

    $router->get('/request/{name}' => sub {
        my ($request) = @_;
        $request_seen = $request;
        return PAGI::Response->text('hello ' . $request->path_param('name'));
    });

    $router->websocket('/socket' => async sub {
        my ($websocket) = @_;
        $websocket_seen = $websocket;
        await $websocket->accept;
        await $websocket->send_text('direct websocket');
        await $websocket->run;
    });

    $router->sse('/events' => async sub {
        my ($sse) = @_;
        $sse_seen = $sse;
        stash($sse)->set(upgrade_example => 'direct sse');
        await $sse->send_event(
            event => 'upgrade',
            data  => stash($sse)->get('upgrade_example'),
        );
        await $sse->run;
    });

    my $client = PAGI::Test::Client->new(app => $router);
    my $response = $client->get('/request/world');
    is($response->text, 'hello world', 'HTTP callback returns a Response');
    isa_ok($request_seen, 'PAGI::Request');

    $client->websocket('/socket', sub {
        my ($socket) = @_;
        is($socket->receive_text, 'direct websocket',
            'WebSocket callback uses the direct protocol object');
    });
    isa_ok($websocket_seen, 'PAGI::WebSocket');

    $client->sse('/events', sub {
        my ($events) = @_;
        is($events->receive_event, {
            event => 'upgrade',
            data  => 'direct sse',
            id    => undef,
            retry => undef,
        }, 'SSE callback and stash helper use the direct protocol object');
    });
    isa_ok($sse_seen, 'PAGI::SSE');
};

subtest 'ErrorHandler receives Request and preserves explicit status' => sub {
    my ($request_seen, $error_seen);
    my $error = Local::UpgradeStatusError->new(503);
    my $app = PAGI::Middleware::ErrorHandler->new(
        handler => sub {
            ($request_seen, $error_seen) = @_;
            return PAGI::Response->text('custom error', status => 409);
        },
    )->wrap(sub { die $error });

    my $response = PAGI::Test::Client->new(app => $app)->get('/');
    isa_ok($request_seen, 'PAGI::Request');
    is($error_seen, exact_ref($error), 'callback receives the original error');
    is($response->status, 409,
        'explicit response status wins over exception status');
    is($response->text, 'custom error', 'custom response is emitted');
};

done_testing;
