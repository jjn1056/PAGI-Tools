# Endpoint Demo

Showcases all three PAGI endpoint types with middleware.

## Run

```bash
pagi-server -I lib --app examples/endpoint-demo/app.pl --port 5000
```

Visit http://localhost:5000/

## Features

### HTTP Endpoint (REST API)

```perl
package MessageAPI;
use parent 'PAGI::Endpoint::HTTP';
use PAGI::Response::JSON;

async sub get {
    my ($self, $request) = @_;
    return PAGI::Response::JSON->new(\@messages);
}

async sub post {
    my ($self, $request) = @_;
    my $data = await $request->json;
    ...
    return PAGI::Response::JSON->new($message, status => 201);
}
```

### WebSocket Endpoint (Echo)

```perl
package EchoWS;
use parent 'PAGI::Endpoint::WebSocket';

async sub on_connect {
    my ($self, $websocket) = @_;
    await $websocket->accept;
}

async sub on_receive {
    my ($self, $websocket, $data) = @_;
    await $websocket->send_json({ type => 'echo', original => $data });
}
```

### SSE Endpoint (Notifications)

```perl
package MessageEvents;
use parent 'PAGI::Endpoint::SSE';

async sub on_connect {
    my ($self, $sse) = @_;
    stash($sse)->set(sub_id => $id);
    await $sse->send_event(...);
}

sub on_disconnect {
    my ($self, $sse) = @_;
    delete $subscribers{stash($sse)->get('sub_id', 'unknown')};
}
```

Endpoint callbacks receive their protocol object directly: HTTP methods receive a
`PAGI::Request`, WebSocket hooks receive a `PAGI::WebSocket`, and SSE hooks
receive a `PAGI::SSE`. The SSE example imports `PAGI::Stash qw(stash)` to keep
connection-local subscriber state with the stream that owns it; the route's
`middleware('Stash')` gives each stream that stash.

### Middleware Examples

- `PAGI::Middleware::AccessLog` - Request logging
- Coderef middleware - Request timing, JSON validation
- `PAGI::Middleware::Stash` - the SSE stream's stash

The JSON-validation middleware reads the request through
`PAGI::HTTPConnection`, which reads the scope without touching the body, so
the endpoint still gets the whole body. `content_type` is the parsed media
type -- lowercased, parameters dropped, and undef when the Content-Type field
is missing or sent twice -- so the check is an exact comparison:

```perl
my $type = PAGI::HTTPConnection->new($scope)->headers->content_type // '';
unless ($type eq 'application/json') { ... }
```

`application/json; charset=utf-8` passes; `text/plain`, or two Content-Type
fields in either order, gets the 415.

The middleware is a native PAGI application, so its terminal
branch constructs a source-free stock application and delegates the exact
channels explicitly:

```perl
my $response = PAGI::Pages->unsupported_media_type(
    as     => 'json',
    detail => 'Content-Type must be application/json');
return await invoke_app($response, $scope, $receive, $send);
```

Successful endpoint payloads remain application-owned JSON. `PAGI::Pages`
handles only the generic HTTP failure.

The three endpoint classes are named at their routes with `endpoint`, which
builds each once. Their middleware is wrapped explicitly with `middleware`,
and the static-file route comes last because the shared routing engine
preserves written order:

```perl
use PAGI::Routing qw(endpoint middleware route sse websocket);

compose(routes => [
    route('/api/messages' => endpoint('MessageAPI'),
        middleware => [middleware($access_log), middleware($require_json)]),
    websocket('/ws/echo' => endpoint('EchoWS'),
        middleware => [middleware($timing)]),
    sse('/events' => endpoint('MessageEvents'),
        middleware => [middleware('Stash'), middleware($timing)]),
    route('/*path' => PAGI::App::File->from_app_path('public')),
]);
```

`PAGI::Middleware::AccessLog` logs HTTP requests only, so it sits on the HTTP
route; the timing middleware works for any protocol. Static files use an HTTP
catch-all `route` rather than `mount('/')`: a Route is HTTP-only, so a
WebSocket or SSE request to an unknown path gets the Router's refusal instead
of reaching the file application, which serves HTTP only.

`endpoint` builds each class once, and that object serves the route for the
compiled application's lifetime. The same object may serve concurrent work,
so shared configuration stays on the endpoint while request and connection
state stays on the protocol object. The HTTP Route snapshots
`MessageAPI->allowed_methods` once during construction; the Router therefore
owns method mismatch and its `Allow` union. There is no intermediate mutable
Router or redundant root Mount.

## Routes

- `GET/POST /api/messages` - REST API
- `WS /ws/echo` - WebSocket echo
- `SSE /events` - Live notifications
- `GET /*` - Static files
