#!/usr/bin/env perl
#
# Bidirectional WebSocket -- send AND receive at once.
#
# One handler, one PAGI::WebSocket, two concurrent branches:
#
#   - incoming: $ws->each_text(...) echoes every client message, uppercased.
#     It is a Future that completes when the client disconnects.
#   - outgoing: an unprompted server tick every second, guarded by
#     $ws->is_connected and sent with try_send_text, which sends nothing
#     once the socket is closing.
#
# Future->wait_any joins them: a disconnect ends `incoming`, and wait_any then
# cancels the idle `outgoing` loop. Both branches send on the same socket at
# will: a PAGI server keeps a connection's sends in the order they were
# called (PAGI::Spec::Www 0.7), so no queue is needed.
#
# Run:  pagi-server --app examples/websocket-bidirectional/app.pl --port 5000
# Test: websocat ws://localhost:5000/
#
use strict;
use warnings;
use Future;
use Future::AsyncAwait;
use Future::IO;
use PAGI::Compose qw(compose);
use PAGI::Routing qw(websocket);

async sub duplex {
    my ($ws) = @_;
    await $ws->accept;

    my $incoming = $ws->each_text(async sub {
        my ($text) = @_;
        await $ws->try_send_text("you said: \U$text");
    });

    my $outgoing = (async sub {
        my $n = 0;
        while ($ws->is_connected) {
            await Future::IO->sleep(1);
            await $ws->try_send_text('server tick #' . ++$n);
        }
    })->();

    await Future->wait_any($incoming, $outgoing);
}

compose(routes => [websocket('/' => \&duplex)]);
