#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';

subtest 'can create websocket endpoint subclass' => sub {
    require PAGI::Endpoint::WebSocket;

    package ChatEndpoint {
        use parent 'PAGI::Endpoint::WebSocket';
        use v5.32;
        use feature 'signatures';
        no warnings 'experimental::signatures';
        use Future::AsyncAwait;

        async sub on_connect ($self, $ws) {
            await $ws->accept;
        }

        async sub on_receive ($self, $ws, $data) {
            await $ws->send_text("echo: $data");
        }

        sub on_disconnect ($self, $ws, $code) {
            # cleanup
        }
    }

    my $endpoint = ChatEndpoint->new;
    isa_ok($endpoint, 'PAGI::Endpoint::WebSocket');
};

subtest 'factory class method has default' => sub {
    require PAGI::Endpoint::WebSocket;

    is(PAGI::Endpoint::WebSocket->websocket_class, 'PAGI::WebSocket', 'default websocket_class');
};

subtest 'encoding attribute defaults to text' => sub {
    require PAGI::Endpoint::WebSocket;

    is(PAGI::Endpoint::WebSocket->encoding, 'text', 'default encoding is text');
};

subtest 'subclass can override encoding' => sub {
    package JSONEndpoint {
        use parent 'PAGI::Endpoint::WebSocket';
        sub encoding { 'json' }
    }

    is(JSONEndpoint->encoding, 'json', 'custom encoding');
};

done_testing;
