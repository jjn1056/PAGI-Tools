# Nested Endpoint Router Demo

This is the canonical nested `PAGI::Endpoint::Router` example. Three ordinary
objects declare a nested routing tree; the deployed root uses `PAGI::Compose`
to own mutable server state and lifecycle callbacks.

## Package tree

```text
app.pl
lib/MyApp/Main.pm
lib/MyApp/API.pm
lib/MyApp/API/Events.pm
public/
```

`app.pl` constructs the declaration tree explicitly:

```perl
my $events = MyApp::API::Events->new;
my $api    = MyApp::API->new(events => $events);
my $main   = MyApp::Main->new(api => $api);

my $app = compose(
    routes => [mount('/' => app => $main)],
    lifespan => { startup => \&startup, shutdown => \&shutdown },
);
```

`Main` is already a PAGI application and needs no root conversion. Main's own
compilation installs the resolver used by `home`. Main converts API because
`home` resolves `/api/index`; API converts Events so
`/api/events/stream` remains part of the inspectable tree. The outer Compose
Router does not need Main's descendant names merely to deploy it, so the root
mount keeps `$main` as the application boundary. Main's `to_router` remains
useful to tests and tools that inspect the whole tree. The selected Endpoint
Router therefore owns its negotiated 404 and 405 while Compose supplies
response-completion and application-error safeguards. See
[PAGI::Compose](../../lib/PAGI/Compose.pm) and
[PAGI::Routing::Mount](../../lib/PAGI/Routing/Mount.pm) for details.

Each package owns only its immutable configuration: `Main` keeps its `api`
child and `API` keeps its `events` child. The server creates the resource and
metrics hash in `Compose` startup; handlers read it through
`app_state($request)` or `app_state($protocol)`. Shutdown marks the mock
resource closed. No Endpoint object receives or mirrors that state.

## Route declarations and addresses

Each class implements `routes($r)`. Route names are local segments, and the
nested router produces these logical addresses:

| Owner | Declaration | Address |
| --- | --- | --- |
| `Main` | `home` | `/home` |
| `Main` | `status_socket` | `/status_socket` |
| `API` | `index` | `/api/index` |
| `API` | `show` | `/api/show` |
| `API` callback child | `status` | `/api/tools/status` |
| `Events` | `stream` | `/api/events/stream` |

`Main` generates the API link with `path_for($request, '/api/index')`. `API`
uses its local name, `path_for($request, 'show', { user_id => 1 })`, for
`/api/show/1`.

`Main` owns the home page, static-file mount, and root `/status` WebSocket.
It places the configured API object explicitly with
`app => $self->{api}->to_router`, so its descendant names remain discoverable.
`API` does the same with `app => $self->{events}->to_router` for its configured
Events object. Direct Endpoint objects are valid opaque applications, but the
parent deliberately does not guess their route names.

`API` also demonstrates the callback form of a structural child:

```perl
$r->mount('/tools', routes => sub {
    my ($tools) = @_;
    $tools->get('/status' => 'status')->name('status');
})->name('tools');
```

The callback receives an Endpoint-aware facade bound to the same API object,
so the method string calls `API::status`. No separate Router configuration is
needed for this child.

`Main` mounts its static files with:

```perl
$r->mount('/', app => PAGI::App::File->from_app_path('public'));
```

Because `MyApp::Main` lives under `lib/MyApp/Main.pm`, the constructor resolves
`public` from the example root.

## Middleware and protocol code

`API` attaches its method factory at declaration time:

```perl
$r->get('/index' => [$self->middleware_as('require_demo_token')] => 'index');
```

The factory is native PAGI middleware: it receives `($scope, $receive, $send)`
and returns an application. It uses `$self->new_request($scope, $receive)`
only there to inspect the request header. Its denial response is constructed
through `unauthorized(...)` and delegated through `invoke_app` with the full
`($scope, $receive, $send)` triplet, including the required
`WWW-Authenticate` challenge.

Compiled Endpoint HTTP methods receive `PAGI::Request` directly. The
missing-user branch demonstrates the other Pages form:
`not_found(...)` returns an application value, which the Endpoint adapter
invokes after the handler returns it. Reverse routes,
state, and responses come from their owning `PAGI::Routing::URL`,
`PAGI::State`, and `PAGI::Response` imports.

WebSocket and SSE methods receive `PAGI::WebSocket` and `PAGI::SSE` directly,
so they call `$websocket->accept`, `$websocket->send_json`, and
`$sse->send_event`. `app_state($protocol)` reads the same lifespan-owned state
without hiding that capability on a shared Context.

The API boundary configures its native default explicitly:

```perl
$r->http_default($self->app_as('api_not_found'));
```

`app_as` binds the API object to the native three-channel method. It renders
`No API Endpoint route matched` for HTTP NONE only; Router-generated 405,
selected handlers, WebSocket, and SSE retain their own outcomes.

## Running

```bash
cd examples/endpoint-router-demo
pagi-server --app app.pl --port 5000
```

Open <http://localhost:5000/>. API pages require the `X-Demo-Token:
demo-token` header; the integration test demonstrates it with
`PAGI::Test::Client`.
