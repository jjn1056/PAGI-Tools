#!/usr/bin/env perl
#
# Bidirectional WebSocket with PAGI::Context -- send AND receive at once.
#
# The same full-duplex demo as the raw-protocol examples/18-bidirectional-websocket
# in the PAGI distribution, but written with PAGI::Context. Context unifies the
# protocol behind one object and hands you exactly the pieces this needs:
#
#   - $ctx->each_text(...)            the receive-loop, as a Future that completes
#                                     when the client disconnects
#   - $ctx->send_text_if_connected   a send that is a no-op once the socket is
#                                     closing -- so the concurrent send-loop never
#                                     races the teardown
#   - $ctx->is_connected             a clean loop guard
#
# After accepting, run two concurrent branches and join them with wait_any: a
# client disconnect ends `incoming`, and the idle `outgoing` tick-loop is then
# cancelled. (Contrast the receive-multiplex in PAGI's examples 14/17, where the
# raced future is the live $receive and must NOT be cancelled.)
#
# THE QUEUE: `incoming` and `outgoing` are two independent producers writing
# to the SAME socket at once. PAGI leaves overlapping in-flight sends
# unspecified -- a second send issued before the first is awaited is exactly
# what the development Lint middleware's overlap check warns about -- so
# every producer routes its sends through one small serializing queue rather
# than calling $ctx->send_text_if_connected directly. This is the canonical
# shape for a full-duplex handler with more than one send-producer; the other
# examples that face the same problem (sse-dashboard, endpoint-demo,
# background-tasks, 10-chat-showcase, websocket-chat-v2) reference this
# pattern instead of inventing their own variant.
#
# Run:  pagi-server --app examples/websocket-bidirectional/app.pl --port 5000
# Test: websocat ws://localhost:5000/
#
use strict;
use warnings;
use Future::AsyncAwait;
use Future::IO;
use PAGI::Context;

my $app = async sub {
    my ($scope, $receive, $send) = @_;
    die "Unsupported scope type: $scope->{type}" if ($scope->{type} // '') ne 'websocket';

    my $ctx = PAGI::Context->new($scope, $receive, $send);
    await $ctx->accept;

    # A serializing send queue: every send -- from either producer below --
    # is chained after the one before it, so only one is ever in flight on
    # this socket at a time. Queue a send with $queue_send->(...); await the
    # returned Future both to know it has gone out and to naturally pace a
    # producer against a slow or backpressured connection.
    my $send_queue = Future->done;
    my $queue_send = sub {
        my (@text) = @_;
        my $prev = $send_queue;
        $send_queue = (async sub {
            await $prev;
            await $ctx->send_text_if_connected(@text);
        })->();
        return $send_queue;
    };

    # incoming: echo each client message back, uppercased.
    # each_text returns a Future that completes when the client disconnects.
    my $incoming = $ctx->each_text(async sub {
        my ($text) = @_;
        await $queue_send->("you said: \U$text");
    });

    # outgoing: push a server tick every second, unprompted.
    my $outgoing = (async sub {
        my $n = 0;
        while ($ctx->is_connected) {
            await Future::IO->sleep(1);
            await $queue_send->("server tick #" . (++$n));
        }
    })->();

    # Run both directions at once; a disconnect ends `incoming`, and wait_any then
    # cancels the still-looping `outgoing`.
    await Future->wait_any($incoming, $outgoing);
};

$app;
