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

The three endpoint objects are direct Compose route leaves. Their middleware is
wrapped explicitly with `middleware`, and the `/` static-file mount remains
last because the shared routing engine preserves written order and a matched
mount prefix owns dispatch immediately:

```perl
use PAGI::Routing qw(middleware mount route sse websocket);

compose(routes => [
    route('/api/messages' => MessageAPI->new,
        middleware => [middleware($access_log), middleware($require_json)]),
    websocket('/ws/echo' => EchoWS->new,
        middleware => [middleware($access_log), middleware($timing)]),
    sse('/events' => MessageEvents->new,
        middleware => [middleware($timing)]),
    mount('/' => app => PAGI::App::File->from_app_path('public')),
]);
```

`route`, `websocket`, and `sse` retain the endpoint objects until dispatch, so
HTTP methods and connection hooks continue to use their normal endpoint
lifecycle. There is no intermediate mutable Router or redundant root Mount.

## Routes

- `GET/POST /api/messages` - REST API
- `WS /ws/echo` - WebSocket echo
- `SSE /events` - Live notifications
- `GET /*` - Static files
