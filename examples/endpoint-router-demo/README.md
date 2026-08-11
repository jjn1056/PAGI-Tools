# Nested Endpoint Router Demo

This is the canonical nested `PAGI::Endpoint::Router` example. Three ordinary
objects declare one immutable routing snapshot; the deployed root uses
`PAGI::Compose` to own mutable server state and lifecycle callbacks.

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

my $app = compose(app => $main->to_router, lifespan => { ... })->to_app;
```

Each package owns only its immutable configuration: `Main` keeps its `api`
child and `API` keeps its `events` child. The server creates the resource and
metrics hash in `Compose` startup; handlers read it through `$c->state`.
Shutdown marks the mock resource closed. No Endpoint object receives or mirrors
that state.

## Route declarations and addresses

Each class implements `routes($r)`. Route names are local segments, and the
nested router produces these logical addresses:

| Owner | Declaration | Address |
| --- | --- | --- |
| `Main` | `home` | `/home` |
| `Main` | `status_socket` | `/status_socket` |
| `API` | `index` | `/api/index` |
| `API` | `show` | `/api/show` |
| `Events` | `stream` | `/api/events/stream` |

`Main` generates the API link with `$c->path_for('/api/index')`. `API` uses
its local name, `$c->path_for('show', { user_id => 1 })`, for `/api/show/1`.

`Main` owns the home page, static-file mount, and root `/status` WebSocket.
`API` owns the protected HTTP pages. `Events` owns `/api/events/stream`.

## Middleware and protocol code

`API` attaches its method factory at declaration time:

```perl
$r->get('/index' => [$self->middleware_as('require_demo_token')] => 'index');
```

The factory is native PAGI middleware: it receives `($scope, $receive, $send)`
and returns an application. It uses `$self->new_context(...)` only there to
inspect the request header. Compiled Endpoint handlers receive the shared `$c`
Context directly; they do not select a `context_class`.

The WebSocket and SSE methods also receive their protocol-aware shared Context,
so they can call `$c->accept`, `$c->send_json`, and `$c->send_event` while
reading the same lifespan-owned `$c->state`.

## Running

```bash
cd examples/endpoint-router-demo
pagi-server --app app.pl --port 5000
```

Open <http://localhost:5000/>. API pages require the `X-Demo-Token:
demo-token` header; the integration test demonstrates it with
`PAGI::Test::Client`.
