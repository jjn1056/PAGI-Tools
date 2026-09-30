#!/usr/bin/env perl
use strict;
use warnings;

use FindBin qw($Bin);
use Test2::V0;

use lib "$Bin/../lib";
use PAGI::Test::Client;

my $file = "$Bin/../examples/protocol-refusal/app.pl";
my $app = do $file;
my $load_error = $@ || $!;

ok(!$load_error, 'protocol refusal example loads cleanly')
    or diag($load_error);
ok($app && ref($app) && $app->can('to_app'),
    'example returns an application object');

my $client = PAGI::Test::Client->new(app => $app);

my @cases = (
    {
        form => 'response',
        ws   => sub {
            my ($response) = @_;
            is($response->content_type, 'text/plain; charset=utf-8',
                'WebSocket response form is text');
            is($response->text, 'Scheduled maintenance',
                'WebSocket response form body');
        },
        sse  => sub {
            my ($response) = @_;
            is($response->content_type, 'application/json',
                'SSE response form is JSON');
            is($response->json, {
                error => 'Unavailable',
                form  => 'response',
            }, 'SSE response form body');
        },
    },
    {
        form => 'handler',
        ws   => sub {
            my ($response) = @_;
            is($response->json, {
                error => 'Unavailable',
                path  => '/ws/handler',
            }, 'WebSocket handler receives request metadata');
        },
        sse  => sub {
            my ($response) = @_;
            is($response->json, {
                error => 'Unavailable',
                path  => '/events/handler',
            }, 'SSE handler receives request metadata');
        },
    },
    {
        form => 'async-handler',
        ws   => sub {
            my ($response) = @_;
            is($response->json, {
                error  => 'Unavailable',
                notice => 'notice-service:/ws/async-handler',
            }, 'WebSocket async handler awaits its notice service');
        },
        sse  => sub {
            my ($response) = @_;
            is($response->json, {
                error  => 'Unavailable',
                notice => 'notice-service:/events/async-handler',
            }, 'SSE async handler awaits its notice service');
        },
    },
    {
        form      => 'pages',
        ws_accept => 'text/html',
        sse_accept => 'application/problem+json',
        ws   => sub {
            my ($response) = @_;
            is($response->content_type, 'text/html; charset=utf-8',
                'direct Pages application negotiates HTML');
            like($response->text, qr/Service Unavailable/, 'Pages HTML title');
            like($response->text, qr/Protocol refusal example/, 'Pages HTML detail');
        },
        sse  => sub {
            my ($response) = @_;
            is($response->content_type, 'application/problem+json',
                'handler-returned Pages application negotiates JSON');
            is($response->json->{status}, 503, 'Pages JSON status');
            is($response->json->{detail}, 'Protocol refusal example',
                'Pages JSON detail');
        },
    },
    {
        form => 'object',
        ws   => sub {
            my ($response) = @_;
            is($response->text, 'Custom application: /ws/object',
                'custom object receives the original WebSocket scope');
        },
        sse  => sub {
            my ($response) = @_;
            is($response->text, 'Custom application: /events/object',
                'custom object receives the original SSE scope');
        },
    },
    {
        form => 'native',
        ws   => sub {
            my ($response) = @_;
            is($response->text, 'Scheduled maintenance',
                'wrapped native WebSocket response body');
        },
        sse  => sub {
            my ($response) = @_;
            is($response->text, 'Scheduled maintenance',
                'wrapped native SSE response body');
        },
    },
);

for my $case (@cases) {
    my $form = $case->{form};

    subtest "WebSocket $form refusal" => sub {
        my %options = $case->{ws_accept}
            ? (headers => {Accept => $case->{ws_accept}})
            : ();
        my $socket = $client->websocket("/ws/$form", %options);
        ok($socket->refused, 'handshake was refused instead of accepted');
        ok($socket->is_closed, 'refused handshake is terminal');
        my $response = $socket->response;
        isa_ok($response, ['PAGI::Test::Response']);
        is($response->status, 503, 'HTTP refusal status');
        $case->{ws}->($response);
    };

    subtest "SSE $form refusal" => sub {
        my %options = $case->{sse_accept}
            ? (headers => {Accept => $case->{sse_accept}})
            : ();
        my $response = $client->sse("/events/$form", %options);
        isa_ok($response, ['PAGI::Test::Response'],
            'decline returned an HTTP response instead of an SSE stream');
        is($response->status, 503, 'HTTP refusal status');
        $case->{sse}->($response);
    };
}

done_testing;
