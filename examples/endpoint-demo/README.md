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

The JSON-validation middleware is a raw PAGI application, so its terminal
branch constructs a stock response from the request scope and sends it
explicitly:

```perl
my $response = PAGI::Pages->unsupported_media_type($scope,
    as     => 'json',
    detail => 'Content-Type must be application/json');
return await $response->respond($scope, $receive, $send);
```

Successful endpoint payloads remain application-owned JSON. `PAGI::Pages`
handles only the generic HTTP failure.

The three Endpoint applications are compiled native PAGI components at their
explicit `app =>` positions, with Mount middleware declared by name. The `/`
static-file mount is last because the shared routing engine preserves written
order and a matched mount prefix owns dispatch immediately.

Only the root Router is wrapped in `compose(app => $router)`. The returned
Compose description is accepted directly by conforming servers and test
clients; it is not compiled merely to make `app.pl` load. The HTTP,
WebSocket, and SSE Endpoint applications remain opaque at their existing mount
boundaries; the root Compose supplies the deployed application's outer safety
boundary without changing their protocol ownership. If one selected opaque
HTTP child were to complete silently, the outer response guard would treat it
as incomplete output (500), not as a trusted routing 404.

```perl
$router->mount('/', app => PAGI::App::File->from_app_path('public'));
```

## Routes

- `GET/POST /api/messages` - REST API
- `WS /ws/echo` - WebSocket echo
- `SSE /events` - Live notifications
- `GET /*` - Static files
