# Nested Endpoint Class Demo

This is the canonical nested class-based endpoint example. Ordinary objects
assemble immutable route descriptions, exact leaves use the HTTP, WebSocket,
and SSE endpoint classes where their protocol lifecycle earns a class, and
`PAGI::Compose` owns server state and lifespan callbacks.

## Package tree

```text
app.pl
lib/MyApp/Main.pm
lib/MyApp/API.pm
lib/MyApp/API/User.pm
lib/MyApp/API/Events.pm
lib/MyApp/StatusSocket.pm
public/
```

`app.pl` constructs dependencies and the root route list explicitly:

```perl
my @users = (
    { id => 1, name => 'Alice' },
    { id => 2, name => 'Bob' },
);
my $events = MyApp::API::Events->new;
my $api    = MyApp::API->new(events => $events, users => \@users);
my $main   = MyApp::Main->new(api => $api);

my $app = compose(
    routes => $main->routes,
    lifespan => { startup => \&startup, shutdown => \&shutdown },
);
```

`Main` is an ordinary assembler. Its `routes` method returns four immutable
descriptions: the home route, the named API mount, the status WebSocket leaf,
and the final static-file fallback. The root Compose Router therefore sees the
API Router as a configured child and retains its descendant names and custom
HTTP default without flattening that boundary.

## Route declarations and addresses

The API's `routing` method returns a configured `PAGI::Routing::Router`:

```perl
my $demo_token_middleware = middleware(sub {
    my ($inner) = @_;
    return $self->require_demo_token($inner);
});

return router(
    http_default => not_found(
        detail => 'No API endpoint route matched'),
    routes => [
        route('/index' => sub { return $self->index(@_) },
            name => 'index',
            middleware => [$demo_token_middleware]),
        route('/show/{user_id:&Int}' =>
            MyApp::API::User->new(users => $self->{users}),
            name => 'show',
            middleware => [$demo_token_middleware]),
        mount('/tools', routes => [
            route('/status' => sub { return $self->status(@_) },
                name => 'status'),
        ], name => 'tools'),
        mount('/events', routes => [
            sse('/stream' => $self->{events}, name => 'stream'),
        ], name => 'events'),
    ],
);
```

Here `$demo_token_middleware` is already the immutable description returned
by `middleware(...)`, so each route places that descriptor directly in its
`middleware` list:

```perl
my $demo_token_middleware = middleware(sub {
    my ($inner) = @_;
    return $self->require_demo_token($inner);
});

route('/one' => \&one, middleware => [$demo_token_middleware]);
route('/two' => \&two, middleware => [$demo_token_middleware]);
```

If a variable instead holds the undecorated middleware factory coderef, wrap
it when constructing the list:

```perl
my $require_demo_token = sub {
    my ($inner) = @_;
    return $self->require_demo_token($inner);
};

route('/one' => \&one,
    middleware => [middleware($require_demo_token)]);
```

In short, use `[$descriptor]` for a value already returned by
`middleware(...)`; use `[middleware($factory)]` when the value is still a
factory coderef. Reusing a descriptor does not reuse a compiled wrapper:
each application compilation invokes its factory for each placement.

The declarations form these canonical logical addresses:

| Owner | Declaration | Address |
| --- | --- | --- |
| `Main` | `home` | `/home` |
| `Main` | `status_socket` | `/status_socket` |
| `API` | `index` | `/api/index` |
| `API::User` | `show` | `/api/show` |
| `API` tools child | `status` | `/api/tools/status` |
| `API::Events` | `stream` | `/api/events/stream` |

`Main` generates the API link with
`path_for($request, '/api/index')`. `API` uses its local name,
`path_for($request, 'show', { user_id => 1 })`, for `/api/show/1`.

The named `/api` mount is an application boundary, not a flattened route
list. Consequently the configured API Router owns an unmatched API path and
returns `No API endpoint route matched`; it also owns automatic method
mismatches and their `Allow` header.

## Endpoint classes and middleware

`MyApp::API::User` subclasses `PAGI::Endpoint::HTTP`. Its configured instance
holds the shared user collection, advertises its `get` capability when the
route is constructed, and handles the exact `/show/{user_id}` leaf. Request
state stays on the `PAGI::Request`; the singleton endpoint holds only its
long-lived dependency.

`MyApp::StatusSocket` subclasses `PAGI::Endpoint::WebSocket` and selects JSON
input. `on_connect` accepts the connection and sends resource status;
`on_receive` increments the shared metric and echoes the decoded message. The
`PAGI::WebSocket` argument owns connection-local state.

`MyApp::API::Events` subclasses `PAGI::Endpoint::SSE`. The configured object is
the exact endpoint of the named `/events` child and named `/stream` leaf, so
both its effective path and logical address are `/api/events/stream`.
`on_connect` sends the initial event, and the base endpoint waits for
disconnect on that connection's `PAGI::SSE` object.

API authentication remains native PAGI middleware. Each protected route owns
an explicit middleware description whose factory receives the inner native
application. The returned application constructs `PAGI::Request` from the
native channels, accepts `X-Demo-Token: demo-token`, or invokes the negotiated
`unauthorized(...)` application with its `WWW-Authenticate` challenge.

## Files and lifespan state

The module that owns `public/` imports and calls `PAGI::Utils::app_path`
directly:

```perl
use PAGI::Utils qw(app_path);

sub public_root { return app_path('public') }

mount('/', app => PAGI::App::File->new(root => $self->public_root))
```

Because `MyApp::Main` lives under `lib/MyApp/Main.pm`, `app_path('public')`
resolves from the example's module-layout application root. The helper returns
the path string; `PAGI::App::File` owns file serving.

Compose startup creates the resource and metrics hashes, and shutdown marks the
mock resource closed. Lifespan callbacks receive those mutable hashrefs because
they initialize and clean up application state. Request-time handlers can use
either equivalent spelling: `app_state($request)` is the functional,
protocol-neutral helper form, while `$request->state`, `$websocket->state`, and
`$sse->state` are direct forms with the same `PAGI::State`-or-`undef` contract.
The WebSocket and SSE endpoint classes demonstrate the direct methods; the HTTP
handlers deliberately retain `app_state($request)`. The assembler and endpoint
objects neither receive nor mirror mutable lifespan state.

## Running

```bash
cd examples/endpoint-class-demo
pagi-server --app app.pl --port 5000
```

Open <http://localhost:5000/>. API pages require the `X-Demo-Token:
demo-token` header; the integration test demonstrates HTTP, WebSocket, SSE,
middleware, reverse routing, custom API 404, and lifespan behavior with
`PAGI::Test::Client`.
