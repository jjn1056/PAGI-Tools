# PAGI Full Demo

A comprehensive example demonstrating all major PAGI features in a single
application -- the runnable companion to the QUICK TOUR in `PAGI::Tools`.

## Features

- **Lifespan Management** - Startup/shutdown hooks with shared state
- **HTTP GET** - Hello World endpoint
- **HTTP POST** - Request body echo
- **HTTP Streaming** - Chunked response with delays
- **NDJSON** - One JSON record per line, written as produced
- **Route names** - Links built with `path_for` / `url_for`
- **WebSocket** - Bidirectional echo server
- **SSE** - Server-Sent Events stream

## Running the Server

```bash
pagi-server --app examples/full-demo/app.pl --port 5000
```

## Endpoints

| Endpoint | Method/Type | Description |
|----------|-------------|-------------|
| `/` | GET | Returns "Hello, World!" |
| `/echo` | POST | Echoes back the request body |
| `/stream` | GET | Streams 5 chunks with 0.5s delays |
| `/export` | GET | NDJSON: three records, one per line |
| `/routes` | GET | Every route's path, looked up by name |
| `/ws/echo` | WebSocket | Echoes text and binary frames |
| `/events` | SSE | Sends 10 tick events, 1 per second |

## Testing

### Hello World

```bash
curl http://localhost:5000/
# Hello, World!
```

### POST Echo

```bash
curl -X POST -d "Hello PAGI" http://localhost:5000/echo
# Hello PAGI

curl -X POST -H "Content-Type: application/json" \
     -d '{"message":"test"}' http://localhost:5000/echo
# {"message":"test"}
```

### HTTP Streaming

```bash
curl http://localhost:5000/stream
# Stream started (request #0)
# Chunk 1: Processing...
# Chunk 2: Working...
# Chunk 3: Almost done...
# Stream complete!
```

### NDJSON and route names

```bash
curl http://localhost:5000/export
# {"at":1704384000,"n":1}
# {"at":1704384000,"n":2}
# {"at":1704384000,"n":3}

curl http://localhost:5000/routes
# {"export_url":"http://localhost:5000/export","paths":{"echo":"/echo",...}}
```

### Server-Sent Events

SSE requires the `Accept: text/event-stream` header:

```bash
curl -N -H "Accept: text/event-stream" http://localhost:5000/events
# event: tick
# id: 1
# data: Event #1 at 1704384000
#
# event: tick
# id: 2
# data: Event #2 at 1704384001
# ...
# event: done
# data: Stream complete
```

### WebSocket

Using [websocat](https://github.com/vi/websocat):

```bash
websocat ws://localhost:5000/ws/echo
> Hello
< Echo: Hello
> Test message
< Echo: Test message
```

Using JavaScript:

```javascript
const ws = new WebSocket('ws://localhost:5000/ws/echo');
ws.onmessage = (e) => console.log('Received:', e.data);
ws.onopen = () => ws.send('Hello from browser!');
```

## Code Structure

```perl
# Routing with immutable declarations
my @routes = (
    route('/' => sub { return text_response('Hello, World!') },
        name => 'hello'),
    route('/echo' => async sub {
        my ($request) = @_;
        return response(await $request->body);
    }, methods => ['POST'], name => 'echo'),
    websocket('/ws/echo' => async sub {
        my ($ws) = @_;
        await $ws->accept;
        await $ws->each_message(async sub { ... });
    }),
    sse('/events' => async sub {
        my ($sse) = @_;
        await $sse->send_event(...);
    }),
);

# Complete application and lifespan callbacks
compose(
    routes => \@routes,
    lifespan => {
        startup  => async sub { ... },
        shutdown => async sub { ... },
    },
);
```

The demo uses the ordinary high-level handler contracts: HTTP receives a
`PAGI::Request` and returns a Response application, while WebSocket and SSE
receive their protocol objects and use the objects' send and lifecycle methods.
Raw three-channel applications remain available through `as_app_object`, but are not
needed here. The declarations run in exactly the order shown. Compose keeps the
same callbacks and state identity while its immutable Router owns the 404 and
405 outcomes. See
[PAGI::Compose](../../lib/PAGI/Compose.pm) and
[PAGI::Routing](../../lib/PAGI/Routing.pm) for the complete routing model.

## Lifespan State

The lifespan startup hook initializes shared state accessible to all requests:

```perl
startup => async sub {
    my ($state) = @_;
    $state->{stats} = { requests => 0 };
    $state->{started_at} = time();
    # Initialize DB connections, caches, etc. here
}
```

The handlers' pauses use `Future::IO->sleep`; `pagi-server` binds the
Future::IO implementation before it loads the application, so the example
names no event loop.

Access in HTTP handlers through the Request's state facade:

```perl
my $counter = $request->state->data->{stats}{requests}++;
```

Each request receives a *shallow copy* of the lifespan state (see
`PAGI::Spec::Lifespan`, "Lifespan State"). Changing a top-level key --
`$request->state->data->{request_counter}++` -- would change only that
request's copy, so every request would report `#0`. Values requests change
live in a container stored once at startup and are changed through its
reference.

## See Also

- [PAGI::Routing](../../lib/PAGI/Routing.pm) - Immutable routing documentation
- [PAGI::Compose](../../lib/PAGI/Compose.pm) - Application boundaries and lifespan callbacks
- [examples/](../) - Other example applications
