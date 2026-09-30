#!/usr/bin/env perl
use strict;
use warnings;
use Future::AsyncAwait;
use Future::IO;    # pagi-server binds the implementation

use PAGI::Compose qw(compose);
use PAGI::Response qw(json_response ndjson_response response stream_response text_response);
use PAGI::Routing qw(route websocket sse);
use PAGI::Routing::URL qw(path_for url_for);

# The runnable companion to PAGI::Tools' QUICK TOUR. Run with:
#   pagi-server --app examples/full-demo/app.pl --port 5000

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
                await Future::IO->sleep(0.5) if $i < $#chunks;
            }
        },
        content_type => 'text/plain; charset=utf-8',
    );
}, name => 'http_stream'),

# NDJSON - one JSON record per line, written as it is produced. Each write
# waits for the client to keep up, and the loop stops if the client leaves.
route('/export' => sub {
    my ($request) = @_;
    return ndjson_response(async sub {
        my ($writer) = @_;
        for my $n (1 .. 3) {
            last if $writer->is_disconnected;
            await $writer->write_item({ n => $n, at => time() });
        }
    });
}, name => 'export'),

# Route names at work: links are built from names, so each path is written
# in exactly one place.
route('/routes' => sub {
    my ($request) = @_;
    return json_response({
        paths => {
            map { $_ => path_for($request, $_) }
                qw(hello echo http_stream export ws_echo sse_events)
        },
        export_url => url_for($request, 'export'),
    });
}, name => 'routes'),

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

        await Future::IO->sleep(1);
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
);
