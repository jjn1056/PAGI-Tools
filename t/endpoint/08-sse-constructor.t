#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';

subtest 'can create SSE endpoint subclass' => sub {
    require PAGI::Endpoint::SSE;

    package NotificationEndpoint {
        use parent 'PAGI::Endpoint::SSE';
        use v5.32;
        use feature 'signatures';
        no warnings 'experimental::signatures';
        use Future::AsyncAwait;

        async sub on_connect ($self, $sse) {
            await $sse->send_event(event => 'welcome', data => { time => time() });
        }

        sub on_disconnect ($self, $sse) {
            # cleanup subscriber
        }
    }

    my $endpoint = NotificationEndpoint->new;
    isa_ok($endpoint, 'PAGI::Endpoint::SSE');
};

subtest 'factory class method has default' => sub {
    require PAGI::Endpoint::SSE;

    is(PAGI::Endpoint::SSE->sse_class, 'PAGI::SSE', 'default sse_class');
};

subtest 'keepalive_interval has default' => sub {
    require PAGI::Endpoint::SSE;

    is(PAGI::Endpoint::SSE->keepalive_interval, 0, 'default keepalive_interval is 0 (disabled)');
};

subtest 'subclass can override keepalive' => sub {
    package LiveEndpoint {
        use parent 'PAGI::Endpoint::SSE';
        sub keepalive_interval { 30 }
    }

    is(LiveEndpoint->keepalive_interval, 30, 'custom keepalive_interval');
};

done_testing;
