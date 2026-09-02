#!/usr/bin/env perl
use strict;
use warnings;
use Future::AsyncAwait;
use PAGI::Compose qw(compose);
use PAGI::Response qw(response stream_response text_response);
use PAGI::Routing qw(route websocket sse);

# Safe sleep that works even without Future::IO backend
my $HAS_FUTURE_IO = eval { require Future::IO; 1 };
sub maybe_sleep {
    my ($seconds) = @_;
    return $HAS_FUTURE_IO ? Future::IO->sleep($seconds) : Future->done;
}

# Declare routes in source order
my @routes = (

# ============================================================================
# HTTP Routes
# ============================================================================

# Hello World endpoint
route('/' => sub {
    return text_response('Hello, World!');
}, name => 'hello'),

# POST Echo - echoes back the request body
route('/echo' => async sub {
    my ($request) = @_;
    my $body = await $request->body;

    return response(
        $body,
        content_type => $request->header('content-type')
            // 'application/octet-stream',
        headers => ['X-Echoed-Length' => length($body)],
    );
}, methods => ['POST'], name => 'echo'),

# HTTP Streaming - sends chunks with delays
route('/stream' => sub {
    my ($request) = @_;
    my $counter = $request->state->data->{request_counter}++;

    my @chunks = (
        "Stream started (request #$counter)\n",
        "Chunk 1: Processing...\n",
        "Chunk 2: Working...\n",
        "Chunk 3: Almost done...\n",
        "Stream complete!\n",
    );

    return stream_response(
        async sub {
            my ($writer) = @_;
            for my $i (0 .. $#chunks) {
                await $writer->write($chunks[$i]);
                await maybe_sleep(0.5) if $i < $#chunks;
            }
        },
        content_type => 'text/plain; charset=utf-8',
    );
}, name => 'http_stream'),

# ============================================================================
# WebSocket Route
# ============================================================================

websocket('/ws/echo' => async sub {
    my ($ws) = @_;
    await $ws->accept;
    await $ws->each_message(async sub {
        my ($frame) = @_;
        if (defined $frame->{text}) {
            await $ws->send_text("Echo: $frame->{text}");
        }
        elsif (defined $frame->{bytes}) {
            await $ws->send_bytes($frame->{bytes});
        }
    });
}, name => 'ws_echo'),

# ============================================================================
# SSE Route
# ============================================================================

sse('/events' => async sub {
    my ($sse) = @_;
    await $sse->start;
    my $disconnect = $sse->run;

    # Send events
    my $count = 0;
    while ($count < 10) {
        last if $disconnect->is_ready;

        $count++;
        await $sse->send_event(
            event => 'tick',
            id    => $count,
            data  => "Event #$count at " . time(),
        );

        await maybe_sleep(1);
    }

    # Final event
    unless ($disconnect->is_ready) {
        await $sse->send_event(
            event => 'done',
            data  => 'Stream complete',
        );
        await $sse->close;
    }
    await $disconnect unless $disconnect->is_ready;
}, name => 'sse_events'),
);

# ============================================================================
# Main Application with Lifespan
# ============================================================================

compose(
    routes => \@routes,
    lifespan => {
        startup => async sub {
            my ($state) = @_;
            warn "[STARTUP] Initializing application...\n";

            # Initialize shared state
            $state->{request_counter} = 0;
            $state->{started_at} = time();

            # Initialize resources here (DB connections, caches, etc.)
            warn "[STARTUP] Application ready!\n";
        },
        shutdown => async sub {
            my ($state) = @_;
            my $uptime = time() - ($state->{started_at} // time());
            my $requests = $state->{request_counter} // 0;
            warn "[SHUTDOWN] Shutting down after ${uptime}s, handled $requests requests\n";

            # Cleanup resources here
            warn "[SHUTDOWN] Cleanup complete\n";
        },
    },
)->to_app;
