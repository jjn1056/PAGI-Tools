#!/usr/bin/env perl
use strict;
use warnings;
use Future::AsyncAwait;
use Future::IO;    # pagi-server binds the implementation

# PAGI::Tools gathers compose (PAGI::Compose), response (PAGI::Response),
# the routing functions (PAGI::Routing) and path_for/url_for
# (PAGI::Routing::URL) in one import.
use PAGI::Tools qw(compose middleware path_for response route sse url_for websocket);

# The runnable companion to PAGI::Tools' QUICK TOUR, written as the tour is
# for Perl 5.24, PAGI-Tools' oldest supported Perl: no signatures, so each
# handler unpacks @_. Run with:
#   pagi-server --app examples/full-demo/app.pl --port 5000

# How the client's mistakes look: a catch entry gets the Request and the error
# (a PAGI::ErrorContext). Its Response sets no status, so ErrorHandler sends it
# with the error's (a 400 for a body that is not JSON). An HTTP error may carry
# headers (a Retry-After); the entry passes them on, as it answers in full.
# ErrorHandler adds a 405's Allow header if the entry sends none.
sub json_error {
    my ($request, $error) = @_;
    return response('JSON', { error => $error->message }, headers => $error->headers);
}

compose(
    # Routes match in source order.
    routes => [
        # Hello World endpoint
        route('/' => sub {
            return response('Text', 'Hello, World!');
        }, name => 'hello'),

        # POST Echo - echoes back the request body. PAGI::Response->new builds a
        # Response when no response() type fits: any body, any content type.
        route('/echo' => async sub {
            my ($request) = @_;
            my $body = await $request->body;

            return PAGI::Response->new(
                $body,
                content_type => $request->header('content-type')
                    // 'application/octet-stream',
                headers => ['X-Echoed-Length' => length($body)],
            );
        }, methods => ['POST'], name => 'echo'),

        # POST JSON - a body that is not JSON is the client's mistake: $request->json
        # raises a 400, which the ErrorHandler below answers in JSON.
        route('/notes' => async sub {
            my ($request) = @_;
            my $note = await $request->json;
            return response('JSON', { saved => $note }, status => 201);
        }, methods => ['POST'], name => 'notes'),

        # HTTP Streaming - sends chunks with delays, and stops if the client leaves.
        route('/stream' => sub {
            my ($request) = @_;
            # Change the shared container; each request's state is a shallow copy.
            my $counter = $request->state->get('stats')->{stream_requests}++;

            my @chunks = (
                "Stream started (request #$counter)\n",
                "Chunk 1: Processing...\n",
                "Chunk 2: Working...\n",
                "Chunk 3: Almost done...\n",
                "Stream complete!\n",
            );

            return response('Stream',
                async sub {
                    my ($writer) = @_;
                    for my $i (0 .. $#chunks) {
                        last if $writer->is_disconnected;
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
            return response('NDJSON', async sub {
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
            return response('JSON', {
                paths => {
                    map { $_ => path_for($request, $_) }
                        qw(hello echo notes http_stream export ws_echo sse_events)
                },
                export_url => url_for($request, 'export'),
            });
        }, name => 'routes'),

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

        # SSE - ten ticks a second apart, then a done event, stopping if the client
        # leaves. The route waits for the stream to finish once this returns.
        sse('/events' => async sub {
            my ($sse) = @_;
            await $sse->start;
            for my $n (1 .. 10) {
                last unless $sse->is_connected;
                await $sse->send_event(event => 'tick', id => $n, data => "Event #$n at " . time());
                await Future::IO->sleep(1) if $n < 10;
            }
            await $sse->send_event(event => 'done', data => 'Stream complete') if $sse->is_connected;
            await $sse->close;
        }, name => 'sse_events'),
    ],
    middleware => [
        # The client's mistakes (an HTTP error, a body that is not JSON
        # among them) answer in JSON like the rest of the API; anything else
        # gets the built-in plain-text 500, which the server also logs.
        middleware('ErrorHandler', catch => { 'PAGI::Exception::HTTP' => \&json_error }),
    ],
    lifespan => {
        startup => async sub {
            my ($state) = @_;
            warn "[STARTUP] Initializing application...\n";

            # Shared state. Each request gets a shallow copy of $state, so a
            # value requests change lives in a container stored once here.
            $state->{stats} = { stream_requests => 0 };
            $state->{started_at} = time();

            # Initialize resources here (DB connections, caches, etc.)
            warn "[STARTUP] Application ready!\n";
        },
        shutdown => async sub {
            my ($state) = @_;
            my $uptime = time() - $state->{started_at};
            warn "[SHUTDOWN] Shutting down after ${uptime}s, $state->{stats}{stream_requests} stream requests\n";

            # Cleanup resources here
            warn "[SHUTDOWN] Cleanup complete\n";
        },
    },
);
