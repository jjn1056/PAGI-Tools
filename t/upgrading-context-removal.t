#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Endpoint::HTTP;
use PAGI::Endpoint::SSE;
use PAGI::Endpoint::WebSocket;
use PAGI::Middleware::ErrorHandler;
use PAGI::Response qw(
    html_response json_response redirect_response text_response
);
use PAGI::Routing qw(route router sse websocket);
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

subtest 'declarative Router callbacks remain direct protocol objects' => sub {
    my ($request_seen, $websocket_seen, $sse_seen);
    my $routing = router(routes => [
    route('/request/{name}' => sub {
        my ($request) = @_;
        $request_seen = $request;
        return text_response('hello ' . $request->path_param('name'));
    }),

    websocket('/socket' => async sub {
        my ($websocket) = @_;
        $websocket_seen = $websocket;
        await $websocket->accept;
        await $websocket->send_text('direct websocket');
        await $websocket->run;
    }),

    sse('/events' => async sub {
        my ($sse) = @_;
        $sse_seen = $sse;
        stash($sse)->set(upgrade_example => 'direct sse');
        await $sse->send(stash($sse)->get('upgrade_example'));
        await $sse->run;
    }),
    ]);

    my $client = PAGI::Test::Client->new(app => $routing);
    my $response = $client->get('/request/world');
    is($response->text, 'hello world',
        'Router HTTP callback remains Request-first and returns a Response');
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
            event => undef,
            data  => 'direct sse',
            id    => undef,
            retry => undef,
        }, 'SSE send and stash helper use the direct protocol object');
    });
    isa_ok($sse_seen, 'PAGI::SSE');
};

subtest 'native applications call the lexical raw send channel' => sub {
    my $send_seen;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $send_seen = $send;
        await $send->({
            type    => 'http.response.start',
            status  => 202,
            headers => [['content-type' => 'text/plain; charset=utf-8']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'lexical raw send',
        });
    };

    my $response = PAGI::Test::Client->new(app => $app)->get('/');
    is(ref($send_seen), 'CODE', 'native callback receives lexical send coderef');
    is([$response->status, $response->text], [202, 'lexical raw send'],
        'calling lexical send emits the native response');
};

subtest 'direct Response factories replace the four HTTP shortcuts' => sub {
    my $text = PAGI::Test::Client->new(
        app => text_response('Created', status => 201),
    )->get('/');
    is([$text->status, $text->text], [201, 'Created'],
        'text constructs the complete response directly');

    my $html = PAGI::Test::Client->new(
        app => html_response('<h1>Created</h1>', status => 201),
    )->get('/');
    is([$html->status, $html->text], [201, '<h1>Created</h1>'],
        'html constructs the complete response directly');

    my $json = PAGI::Test::Client->new(
        app => json_response({ created => 1 }, status => 201),
    )->get('/');
    is([$json->status, $json->json], [201, { created => 1 }],
        'json constructs the complete response directly');

    my $redirect = PAGI::Test::Client->new(
        app => redirect_response('/items'),
    )->get('/');
    is([$redirect->status, $redirect->header('location')], [302, '/items'],
        'redirect constructs the complete response directly');
};

subtest 'ErrorHandler receives Request and preserves explicit status' => sub {
    my ($request_seen, $error_seen);
    my $error = Local::UpgradeStatusError->new(503);
    my $app = PAGI::Middleware::ErrorHandler->new(
        handler => sub {
            ($request_seen, $error_seen) = @_;
            return text_response('custom error', status => 409);
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
