#!/usr/bin/env perl
#
# WebSocket Echo Server using PAGI::WebSocket
#
# This example demonstrates the clean PAGI::WebSocket API compared
# to the raw protocol. Compare with examples/04-websocket-echo/app.pl.
#
# Run: pagi-server --app examples/websocket-echo-v2/app.pl --port 5000
# Test: websocat ws://localhost:5000/
#
use strict;
use warnings;
use Future::AsyncAwait;
use lib 'lib';
use PAGI::WebSocket;

my $app = async sub {
    my ($scope, $receive, $send) = @_;

    # Handle lifespan events (server startup/shutdown)
    if ($scope->{type} eq 'lifespan') {
        while (1) {
            my $event = await $receive->();
            if ($event->{type} eq 'lifespan.startup') {
                print "Echo server starting...\n";
                await $send->({ type => 'lifespan.startup.complete' });
            }
            elsif ($event->{type} eq 'lifespan.shutdown') {
                print "Echo server shutting down...\n";
                await $send->({ type => 'lifespan.shutdown.complete' });
                last;
            }
        }
        return;
    }

    # Reject non-websocket connections
    die "Expected websocket, got $scope->{type}" if $scope->{type} ne 'websocket';

    #
    # This is the magic - compare to the raw protocol version!
    #
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

    # Accept the connection
    await $ws->accept;
    print "Client connected from ", ($ws->client->[0] // 'unknown'), "\n";

    # Optional: register cleanup
    $ws->on_close(async sub {
        my ($code, $reason) = @_;
        print "Client disconnected: $code",
              ($reason ? " ($reason)" : ""), "\n";
    });

    # Echo loop - just 4 lines!
    await $ws->each_text(async sub {
        my ($text) = @_;
        print "Received: $text\n";
        await $ws->send_text("echo: $text");
    });
};

$app;
