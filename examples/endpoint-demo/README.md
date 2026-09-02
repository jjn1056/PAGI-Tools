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
connection-local subscriber state with the stream that owns it.

### Middleware Examples

- `PAGI::Middleware::AccessLog` - Request logging
- Coderef middleware - Request timing, JSON validation

The JSON-validation middleware is a native PAGI application, so its terminal
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

The three Endpoint applications are compiled native PAGI components at their
explicit `app =>` positions, with Mount middleware declared by name. The `/`
static-file mount is last because the shared routing engine preserves written
order and a matched mount prefix owns dispatch immediately.

`PAGI::App::Router` already implements `to_app`, so Compose mounts the
endpoint-demo frontend directly:

```perl
compose(routes => [mount('/' => app => $router)]);
```

The unnamed root Mount consumes no path and keeps the Router's middleware,
default, and routing outcomes. The outer Compose Router treats the frontend as
an application boundary and does not inspect its descendant names. The frontend
already implements `to_app`: mount it directly for ordinary deployment. Use
`to_router` only when a parent must discover those names or retain an immutable
snapshot; this application has no such parent-side consumer. The
HTTP, WebSocket, and SSE applications remain opaque at their existing mounts;
see
[PAGI::Compose](../../lib/PAGI/Compose.pm) and
[PAGI::Routing::Mount](../../lib/PAGI/Routing/Mount.pm) for the boundary model.

```perl
$router->mount('/', app => PAGI::App::File->from_app_path('public'));
```

## Routes

- `GET/POST /api/messages` - REST API
- `WS /ws/echo` - WebSocket echo
- `SSE /events` - Live notifications
- `GET /*` - Static files
