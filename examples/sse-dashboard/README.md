# SSE Dashboard Example

Live dashboard using PAGI::SSE for real-time metrics streaming.

## Run

```bash
pagi-server --app examples/sse-dashboard/app.pl --port 5000
```

Visit http://localhost:5000/

## Features

- Real-time server metrics streaming
- Automatic keepalive for proxy compatibility
- Reconnection support via `Last-Event-ID`
- Multiple event types (`connected`, `reconnected`, `metrics`)
- Subscriber tracking

## API

- `SSE /events` - Metrics stream (2-second updates)
- `GET /*` - Static files from `public/`

## Key Concepts

The application is one `compose`; the SSE route's handler receives one
`PAGI::SSE`:

```perl
async sub events {
    my ($sse) = @_;
    $sse->on_close(sub { ... });     # registered before any awaited I/O

    await $sse->start;
    return if $sse->is_closed;       # the client may leave at any await
    await $sse->keepalive(25);       # protocol keepalive for proxies
    await $sse->send_event(event => 'connected', data => {...});

    if (my $last_id = $sse->last_event_id) {    # a reconnect
        await $sse->send_event(event => 'reconnected', data => {...});
    }

    ...subscribe...
    await $sse->run;                 # until the client goes
}

compose(routes => [
    sse('/events' => \&events),
    route('/*path' => PAGI::App::File->from_app_path('public')),
]);
```

One broadcaster sends the same metrics, with the same event id, to every
subscriber. It sleeps with `Future::IO`, which `pagi-server` binds, so no
event loop is named in the application. Each client is sent with
`try_send_event`, which never dies; a failed send unsubscribes that client.

Static files sit on an HTTP catch-all `route`, not a `mount('/')`: a Route
is HTTP-only, so an SSE request to an unknown path still gets the Router's
404 instead of reaching the file application.
