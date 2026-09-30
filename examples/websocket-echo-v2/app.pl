#!/usr/bin/env perl
#
# WebSocket echo: the smallest PAGI-Tools WebSocket application.
#
# One route whose handler receives one PAGI::WebSocket. Compare the raw
# protocol version in the PAGI distribution's examples/04-websocket-echo.
#
# Run: pagi-server --app examples/websocket-echo-v2/app.pl --port 5000
# Test: websocat ws://localhost:5000/
#
use strict;
use warnings;
use Future::AsyncAwait;
use PAGI::Compose qw(compose);
use PAGI::Routing qw(websocket);

async sub echo {
    my ($ws) = @_;

    # Registered before accept, so it runs however the connection ends. The
    # peer's close code is undef when the client vanished without a Close.
    $ws->on_close(sub {
        my ($code) = @_;
        print STDERR 'Client disconnected: ', ($code // 'no close frame'), "\n";
    });

    await $ws->accept;
    await $ws->each_text(async sub {
        my ($text) = @_;
        await $ws->send_text("echo: $text");
    });
}

compose(routes => [websocket('/' => \&echo)]);
