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

subtest 'class to_app constructs its endpoint immediately and only once' => sub {
    {
        package Local::ConstructionCountingWebSocket;
        use parent 'PAGI::Endpoint::WebSocket';
        our $NEW_CALLS = 0;

        sub new {
            my ($class, @args) = @_;
            $NEW_CALLS++;
            return PAGI::Endpoint::WebSocket::new($class, @args);
        }

        sub on_connect { return $_[1]->accept }
    }

    $Local::ConstructionCountingWebSocket::NEW_CALLS = 0;
    my $app = Local::ConstructionCountingWebSocket->to_app;

    is $Local::ConstructionCountingWebSocket::NEW_CALLS, 1,
        'class to_app constructs the endpoint immediately';

    for my $connection (1, 2) {
        $app->(
            { type => 'websocket', path => "/ws/$connection", headers => [] },
            sub { Future->done({ type => 'websocket.disconnect', code => 1000 }) },
            sub { Future->done },
        )->get;
    }

    is $Local::ConstructionCountingWebSocket::NEW_CALLS, 1,
        'connections do not construct additional endpoint objects';
};

done_testing;
