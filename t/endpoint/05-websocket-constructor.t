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
        use Future::AsyncAwait;

        async sub on_connect {
            my ($self, $websocket) = @_;
            await $websocket->accept;
        }

        async sub on_receive {
            my ($self, $websocket, $data) = @_;
            await $websocket->send_text("echo: $data");
        }

        sub on_disconnect {
            my ($self, $websocket, $code) = @_;
            # cleanup
        }
    }

    my $endpoint = ChatEndpoint->new;
    isa_ok($endpoint, 'PAGI::Endpoint::WebSocket');
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
