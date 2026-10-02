#!/usr/bin/env perl
#
# Explicit SSE close with PAGI::SSE->close(reason => ...)
#
# Streams a few "job progress" events, then ends the stream EXPLICITLY with
# close() instead of just returning. Demonstrates:
#
#   - close() from the handler, with a reason that is server-side metadata
#     only -- SSE has no close frame on the wire
#   - a client-facing "done" sentinel event so the browser stops reconnecting
#   - on_close cleanup that runs however the stream ends (client gone OR close())
#
# The pauses use Future::IO->sleep; pagi-server binds the implementation, so
# the application names no event loop.
#
# Run:  pagi-server --app examples/sse-close/app.pl --port 5000
# Open: http://localhost:5000/
#
use strict;
use warnings;
use Future::AsyncAwait;
use Future::IO;

use PAGI::Compose qw(compose);
use PAGI::Response qw(response);
use PAGI::Routing qw(route sse);

my $PAGE = <<'HTML';
<!doctype html>
<meta charset="utf-8">
<title>PAGI SSE close demo</title>
<h1>Job progress</h1>
<pre id="log"></pre>
<script>
  const log = (m) => (document.getElementById('log').textContent += m + "\n");
  const es = new EventSource('/jobs');
  es.addEventListener('progress', (e) => log('progress ' + JSON.parse(e.data).pct + '%'));
  // The server cannot tell the browser "don't reconnect" on the wire, so we use
  // a sentinel event: on 'done', WE close -- which suppresses auto-reconnect.
  es.addEventListener('done', () => { log('done -- closing'); es.close(); });
  es.onerror = () => log('(connection error; would auto-reconnect unless closed)');
</script>
HTML

async sub jobs {
    my ($sse) = @_;

    # Runs once, however the stream ends. $reason is undef when the stream
    # completed -- our close() below -- or a token such as 'client_closed'
    # if the client left first.
    $sse->on_close(async sub {
        my ($sse, $reason) = @_;
        print STDERR 'SSE stream closed: ', ($reason // 'completed'), "\n";
    });

    await $sse->start;

    for my $pct (25, 50, 75, 100) {
        await $sse->send_event(event => 'progress', data => { pct => $pct });
        await Future::IO->sleep(0.5);
    }

    # Tell the CLIENT we are done (an in-band sentinel it listens for), then
    # end the stream explicitly. close() ends it now and runs on_close before
    # resolving. Its reason is metadata for the server's logging and metrics;
    # it is never sent to the client, which is why 'done' exists.
    await $sse->send_event(event => 'done', data => { ok => 1 });
    await $sse->close(reason => 'job_complete');
}

compose(routes => [
    route('/' => response('HTML', $PAGE)),    # a Response is a reusable value
    sse('/jobs' => \&jobs),
]);
