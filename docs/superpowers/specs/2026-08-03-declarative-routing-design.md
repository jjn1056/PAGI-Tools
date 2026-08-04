# Declarative Routing and Context Contract

**Date:** 2026-08-03
**Status:** Approved in design discussion; pending written-spec review
**Scope:** PAGI-Tools declarative routing, middleware composition helpers, and
the Context/Response contract required by the new handler adapter

## 1. Summary

PAGI-Tools will gain a Starlette-inspired declarative routing API as an
additive alternative to `PAGI::App::Router`. It will describe an immutable
route tree with functions such as `router`, `route`, `websocket`, `sse`, and
`mount`. Normal handlers receive one `PAGI::Context` object (`$c`) and HTTP
handlers return a `PAGI::Response`; native three-channel PAGI applications
remain available through an explicit `raw` option.

The new API is not a replacement, facade, or compatibility layer for
`PAGI::App::Router`. The existing mutable router remains the traditional
choice. The declarative API is recommended where a decomposed, inspectable
route tree is clearer.

This design also finishes the Context/Response vocabulary required to make
`$c` the safe default. Methods that build local response state are named
differently from methods that emit protocol events, while backwards-compatible
aliases remain on `PAGI::Response` where required.

The router is intentionally narrower than Starlette's top-level `Starlette`
application object. A future PAGI application constructor may own lifespan,
application-wide exception policy, and global middleware. Those concerns do
not belong in this routing change.

## 2. Goals

- Provide a compact declarative route-tree API that is comfortable in Perl.
- Make the common handler contract `sub ($c) -> PAGI::Response` for HTTP and
  imperative `$c` handlers for WebSocket and SSE.
- Preserve native PAGI applications without making raw channels the default.
- Use only PAGI-spec middleware factories and components.
- Support route-, mount-, and router-level middleware.
- Preserve declaration-order routing, while correctly distinguishing no match
  from path-match/method-mismatch.
- Support named routes, mounted namespaces, request-independent path
  generation, and request-aware absolute URI generation.
- Support Perl regexes, synchronous predicates, and Type::Tiny-compatible path
  constraints without coercing captured values.
- Make the immutable route tree inspectable and allow descriptive annotations.
- Give every executable routing object a `to_app` boundary.
- Document whether every helper mutates local state, constructs a callback, or
  emits protocol events.

## 3. Non-goals and deferred work

The first release will not include:

- HTTP verb constructors such as `get`, `post`, or `any`.
- Automatic `OPTIONS` responses.
- Automatic trailing-slash normalization or redirection. Exact paths remain
  exact. Slash redirection may later be optional middleware.
- A top-level Starlette-like application constructor. Lifespan and
  application-wide exception policy belong there when it is designed.
- General handled-HTTP-exception types or 401/403/500 response helpers.
- A generalized value-flow `$next` middleware tier.
- Async or database-aware route constraints.
- Path-parameter coercion.
- String evaluation for package methods or a bound-method loader.
- A worker/thread pool for synchronous handlers.
- OpenAPI generation or schema-specific route options.
- Arbitrary structured route metadata. The first release provides only a
  human-readable `desc` field.
- A flattened `walk_routes` or compiled route-table API. The tree is directly
  inspectable; richer traversal can be added after a concrete consumer defines
  its requirements.

## 4. Public module and exports

The public functional API lives in `PAGI::Routing`:

```perl
use PAGI::Routing qw(:routes :middleware);
```

It exports nothing by default.

- `:routes` exports `router`, `route`, `websocket`, `sse`, and `mount`.
- `:middleware` exports `middleware`.
- `:ALL` exports every public constructor.
- `:all` is a lowercase alias for `:ALL`.

The absence of default exports prevents collisions with application functions
and leaves the source file explicit about the DSL it uses.

## 5. Canonical API shape

```perl
use Future::AsyncAwait;
use PAGI::Routing qw(:ALL);

async sub home {
    my ($c) = @_;
    return $c->html('<h1>Home</h1>');
}

async sub show_user {
    my ($c) = @_;
    return $c->json({ id => $c->path_param('id') });
}

my $routing = router(
    desc => 'Public application routes',

    middleware => [
        middleware('PAGI::Middleware::GZip'),
    ],

    routes => [
        route('/' => \&home,
            name => 'home',
            desc => 'HTML landing page',
        ),

        mount('/api',
            namespace => 'api',
            desc      => 'Versioned JSON API',
            routes    => [
                route('/users/{id}' => \&show_user,
                    name        => 'users.show',
                    methods     => ['GET'],
                    constraints => { id => qr/\d+/ },
                ),
            ],
        ),
    ],
);

my $app = $routing->to_app;
```

For compatibility with the distribution's minimum Perl, documentation uses
the portable named-sub form above. On a Perl version supporting signatures,
users may write `async sub home ($c) { ... }`. The invalid ordering
`async sub ($c) home` is never documented.

The canonical way to load handlers from another package is a normal compile-
time package load plus a fully qualified coderef:

```perl
use MyApp::Routes::Home ();

route('/' => \&MyApp::Routes::Home::home);
```

Strings such as `\'MyApp::Routes::Home->home'` are not evaluated. A bound-
method helper may be considered separately if real applications demonstrate a
need.

## 6. Immutable routing objects

Every constructor returns an immutable, inspectable object:

- `router(...)` returns a router object.
- `route(...)` returns an HTTP route node.
- `websocket(...)` returns a WebSocket route node.
- `sse(...)` returns an SSE route node.
- `mount(...)` returns a mount node.
- `middleware(...)` returns a middleware descriptor.

The constructor arguments are validated eagerly where possible. Objects do not
grow or mutate after construction. Accessors that return collections return new
arrayrefs/hashrefs or immutable child objects, never internal mutable storage.

Every executable routing object (`router`, `route`, `websocket`, `sse`, and
`mount`) implements `to_app`. Calling `to_app` on a single node compiles it as a
complete one-node router, preserving its path/method matching and default
not-found/method-not-allowed behavior. A middleware descriptor is not itself an
application and does not implement `to_app`.

Executable objects may overload `&{}` so this is convenient:

```perl
await $routing->($scope, $receive, $send);
```

The canonical server boundary remains:

```perl
my $app = $routing->to_app;
```

`PAGI::Server::Runner` requires an actual `CODE` reference; callable overload
does not change `ref($routing)` into `CODE`.

Each `to_app` call compiles a fresh application. Compilation never mutates the
source description. Middleware factories and component wrappers are applied
once per compiled application, not once per request.

## 7. Route-node grammar

### 7.1 HTTP routes

```perl
route('/users/{id}' => \&show_user,
    name        => 'users.show',
    desc        => 'Display one user by numeric ID',
    methods     => ['GET'],
    constraints => { id => qr/\d+/ },
    middleware  => [ ... ],
);
```

The positional target is a normal `$c` handler. Native PAGI is explicit:

```perl
route('/raw', raw => $raw_pagi_app);
```

Supplying both a positional handler and `raw`, or supplying neither, croaks.
`raw` accepts anything `PAGI::Utils::to_app` accepts.

`methods` accepts one method string, an arrayref of method strings, or the
explicit string `'*'`. Methods are normalized to uppercase and deduplicated.
An empty method collection is invalid.

When `methods` is omitted, the route accepts `GET` and automatically accepts
`HEAD`. Any route containing `GET` also contains `HEAD` in its normalized
method set. There is no automatic `OPTIONS` behavior. Handling all methods
must be explicit with `methods => '*'`.

### 7.2 WebSocket routes

```perl
websocket('/chat/{room}' => \&chat,
    name       => 'chat',
    desc       => 'Room-based WebSocket chat',
    middleware => [ ... ],
);

websocket('/raw-ws', raw => $raw_websocket_app);
```

`methods` is invalid on a WebSocket route. A normal handler receives a
WebSocket context and uses its imperative protocol helpers. Its return value is
inert.

### 7.3 SSE routes

```perl
sse('/events' => \&events,
    name       => 'events',
    desc       => 'Live application events',
    middleware => [ ... ],
);

sse('/raw-events', raw => $raw_sse_app);
```

`methods` is invalid on an SSE route. A normal handler receives an SSE context
and emits events through its imperative helpers. Its return value is inert.

### 7.4 Unknown options

Every constructor rejects unknown option names. This catches spelling mistakes
at construction rather than silently changing routing behavior.

## 8. Mount grammar and boundaries

There are exactly two mount forms.

An inline declarative subtree:

```perl
mount('/api',
    namespace  => 'api',
    desc       => 'Public API subtree',
    middleware => [ ... ],
    routes     => [
        route('/users' => \&users),
    ],
);
```

An application/component mount:

```perl
mount('/static' => $static_app,
    desc       => 'Static assets',
    middleware => [ ... ],
);
```

Supplying both a positional target and `routes`, or supplying neither, croaks.
A positional target is always an application accepted by
`PAGI::Utils::to_app`; a coderef in that position is therefore a native PAGI
application, not a `$c` handler.

After a mount prefix matches, that mount owns the request. The parent does not
resume scanning later sibling routes based on the mounted application's
response status. Whatever an application mount sends is final; a 404 or 405 is
not inspected or rewritten by the parent router.

Inline subtrees are structural parts of one declarative router. They inherit
the nearest enclosing `not_found` and `method_not_allowed` handlers. Mount
middleware wraps the entire subtree once the prefix matches, including an
inherited not-found or method-not-allowed response.

A separately constructed router passed positionally is an application mount
and owns its configuration. Use the `routes => [...]` form when structural
inheritance is wanted.

Mounting adjusts `path` and `root_path` according to PAGI composition rules.
Reverse routing always includes the mount prefix.

## 9. Matching algorithm

Routes are evaluated strictly in declaration order. There is no specificity
sorting or hidden prioritization.

For HTTP:

1. Iterate nodes in declared order.
2. A path and method match is `FULL`; dispatch the first full match
   immediately.
3. A path match with the wrong method is `PARTIAL`. Record its allowed methods
   and continue looking for a later full match.
4. If no full match exists and one or more partial matches exist, invoke
   `method_not_allowed` with the union of all allowed methods.
5. If neither a full nor partial match exists, invoke `not_found`.

The 405 `Allow` header contains the normalized union, including automatic
`HEAD` wherever `GET` is allowed.

For WebSocket and SSE, only nodes for that protocol plus applicable mounts are
considered. Protocol-specific unmatched behavior is defined in section 13.

A constraint returning false converts that candidate to no match. Constraint
failure does not select a route and does not create a 405 partial match.

Because a later full match beats an earlier partial match, a true wildcard
route can supersede a 405. Catch-all routes belong last and their method sets
must be chosen deliberately.

Paths are exact. `/users` and `/users/` are different paths. The router performs
no redirection or normalization.

## 10. Path syntax and constraints

Canonical parameter syntax uses braces:

```perl
route('/users/{id}' => \&show_user);
```

A wildcard captures the remaining path:

```perl
route('/files/*path' => \&serve_file);
```

The existing `:id` and `{id:\d+}` spellings accepted by `PAGI::App::Router`
are also accepted for familiarity, but documentation uses braces plus explicit
Perl-native constraints:

```perl
constraints => {
    id => qr/\d+/,
}
```

A constraint may be:

- A `Regexp`. It must match the complete captured value.
- A synchronous unary predicate coderef. It receives exactly the captured
  string and returns truth for acceptance.
- A blessed Type::Tiny-compatible object with `check($value)`, plus optional
  `get_message($value)` diagnostics.

Constraint names must correspond to declared path parameters. Invalid names
croak during construction.

Constraints validate but never coerce. Captured path parameters remain the
original decoded strings. A constraint returning a `Future` is rejected with a
clear diagnostic. A thrown constraint exception propagates; false is the only
ordinary no-match result.

Type::Tiny support is protocol-based and does not require a hard runtime
dependency. Tests may use Type::Tiny as a recommended/test dependency.

Database or resource-existence checks do not belong in matching. Those checks
may be asynchronous, have side effects, and can turn selection into multiple
database queries. They belong in route middleware or the selected handler. A
missing resource after route selection returns a normal application 404; the
router does not continue scanning.

Constraints are also applied during reverse generation. Invalid values croak,
using `get_message` when a Type::Tiny-compatible object provides it.

## 11. Handler contracts and adaptation

### 11.1 HTTP

A normal HTTP handler receives one `$c` and returns `PAGI::Response`:

```perl
async sub create_user {
    my ($c) = @_;
    return $c->json({ id => 42 }, status => 201);
}
```

Both immediate responses from synchronous subs and Futures resolving to a
response are accepted. Dispatch normalizes the value, awaits when necessary,
validates the response type, and emits it exactly once through `$c->respond`.

A normal handler does not receive raw `$scope`, `$receive`, or `$send`. It does
not emit response events itself. Native channel ownership requires `raw`.

### 11.2 WebSocket and SSE

Normal WebSocket and SSE handlers receive the appropriate `$c` subclass and
use imperative protocol helpers. Dispatch awaits their completion. Their
resolved return values are inert and are never interpreted as messages or
responses.

### 11.3 Raw applications

A `raw` target receives `($scope, $receive, $send)`, owns protocol emission,
and follows the PAGI application contract directly. Its resolved value is
inert to the router and server.

### 11.4 No automatic worker pool

The route adapter does not move synchronous handlers into threads or workers.
An automatic pool would hide ordering, cancellation, shared-state, and
serialization semantics. A separate executor/pool abstraction may be designed
later for applications that require it.

## 12. Router-generated 404 and 405 handlers

`not_found` and `method_not_allowed` are ordinary HTTP `$c` handlers selected
by router control flow. They are not middleware, response-rewriting hooks, or
typed exceptions.

```perl
my $routing = router(
    routes => [ ... ],

    not_found => async sub {
        my ($c) = @_;
        return $c->html('<h1>Not Found</h1>');
    },

    method_not_allowed => async sub {
        my ($c) = @_;
        return $c->json({
            error => 'Method Not Allowed',
            allow => $c->response->header('Allow'),
        });
    },
);
```

Before invoking `not_found`, the router seeds `$c->response` with status 404.
Before invoking `method_not_allowed`, it seeds status 405 and the computed
`Allow` header. The normal `$c->text`, `$c->html`, and `$c->json` helpers mutate
that same accumulator and therefore preserve the seeded values.

The returned `PAGI::Response` is respected and sent unchanged. The router does
not reassert the status or headers after the handler returns. A handler that
intentionally redirects, changes the status, removes a header, or constructs a
separate response is responsible for that choice. Documentation recommends the
seeded `$c` helpers as the safe and concise path.

Defaults use ordinary handlers equivalent to:

```perl
my $default_not_found = sub {
    my ($c) = @_;
    return $c->text('Not Found');
};

my $default_method_not_allowed = sub {
    my ($c) = @_;
    return $c->text('Method Not Allowed');
};
```

There is no automatic content-negotiated default. An application can use the
existing request negotiation helpers:

```perl
async sub render_http_error {
    my ($c) = @_;
    my $status = $c->response->status;
    my $type = $c->request->preferred_type(
        'application/json',
        'text/html',
        'text/plain',
    ) // 'text/plain';

    $c->response->header('Vary' => 'Accept');

    return $c->json({ status => $status })
        if $type eq 'application/json';
    return $c->html("<h1>$status</h1>")
        if $type eq 'text/html';
    return $c->text("HTTP $status");
}

my $routing = router(
    routes             => [ ... ],
    not_found          => \&render_http_error,
    method_not_allowed => \&render_http_error,
);
```

A fully matched route's response is never examined or restyled. If a selected
handler or application deliberately returns 404 or 405, that response passes
through untouched.

Router middleware wraps these generated outcomes. Route middleware does not
run because no route was fully selected. Mount middleware wraps the generated
outcome of a matched inline subtree.

## 13. True catch-all routes

`not_found` is not shorthand for a wildcard route. Documentation includes
examples of real catch-all routes at different levels.

Application-level:

```perl
router(
    routes => [
        route('/api/users' => \&users),

        # A real route; keep it last.
        route('/*path' => \&spa, methods => ['GET']),
    ],
    not_found => \&not_found,
);
```

Subtree-level:

```perl
router(
    routes => [
        mount('/docs', routes => [
            route('/assets/*path' => \&asset),
            route('/*path' => \&docs_spa, methods => ['GET']),
        ]),
        route('/health' => \&health),
    ],
);
```

A true catch-all:

- Is a normal route and may return any status, including 200 or a redirect.
- Receives captured parameters.
- May have a name, description, constraints, and route middleware.
- Participates in declaration order and method matching.
- With `methods => '*'`, may supersede a 405 from a more-specific partial
  match because it is a full match.
- With GET-only methods, makes unknown non-GET paths partial matches and hence
  405 outcomes.
- Affects only its inline mounted subtree when declared inside that subtree.

By contrast, `not_found` runs only after no full or partial match and begins
with a seeded 404 response.

## 14. WebSocket, SSE, lifespan, and unknown-scope outcomes

- An unmatched HTTP path invokes `not_found`.
- An HTTP path with no acceptable method invokes `method_not_allowed`.
- An unmatched SSE route emits an `sse.http.response.*` 404 decline.
- An unmatched WebSocket route uses the optional WebSocket HTTP-denial
  extension when advertised. Without it, the router sends a pre-acceptance
  close and allows the server to supply the protocol-defined bare 403.
- A `lifespan` scope is ignored: the router returns without reading or sending
  lifespan events. `PAGI::Lifespan` wraps the completed routing application.
- A genuinely unknown scope type croaks with a diagnostic naming the type.

The declarative router has no `startup`, `shutdown`, or `lifespan` options.
A future top-level application object is the appropriate owner of those
features.

## 15. Middleware contract

The declarative API supports only PAGI-spec event middleware.

```perl
middleware($factory);
middleware($configured_instance);
middleware('PAGI::Middleware::GZip', %config);
```

A coderef is always a synchronous factory:

```perl
my $descriptor = middleware(sub {
    my ($app) = @_;

    return async sub {
        my ($scope, $receive, $send) = @_;
        await $app->($scope, $receive, $send);
    };
});
```

The factory is invoked once during `to_app` and must synchronously return a
native PAGI application coderef. An accidental async factory returns a Future
and croaks during compilation with a diagnostic such as "middleware factory
must return PAGI app coderef; got Future".

A middleware object supplies `wrap($app)`. A class-name descriptor resolves and
configures the class using the existing middleware conventions, then applies
`wrap($app)`.

There is no direct four-argument `($scope,$receive,$send,$next)` middleware
form. The previously removed form made `$next` ambiguously mean inherited
channels or replacement channels, blurred factory time and request time, and
diverged from the PAGI middleware specification. `$next` remains reserved for
a possible future value-flow abstraction.

The first middleware listed is outermost. Placement is:

```text
router middleware
  -> mount middleware
    -> child router middleware
      -> matched route middleware
        -> handler adapter
```

Router middleware observes router-generated not-found and method-not-allowed
responses. Mount middleware observes all responses under a matched prefix.
Route middleware runs only after that route fully matches.

Canonical middleware loading from another package is documented with a normal
coderef:

```perl
use MyApp::Middleware::RequestId ();

middleware => [
    middleware(\&MyApp::Middleware::RequestId::request_id),
]
```

`request_id` is a synchronous factory returning an async native PAGI app.

## 16. Middleware authoring helpers

`PAGI::Middleware` will offer explicit importable helpers through `:helpers`:

```perl
use PAGI::Middleware qw(:helpers);

my $child_scope    = clone_scope($scope, \%changes);
my $wrapped_send   = wrap_send($send, $interceptor);
my $wrapped_receive = wrap_receive($receive, $interceptor);
```

- `clone_scope` performs a shallow local clone plus requested changes. It does
  no I/O and returns immediately.
- `wrap_send` constructs a callback. Construction does no I/O. When the returned
  callback is later invoked, it runs/awaits the interceptor and downstream send
  according to the documented contract.
- `wrap_receive` likewise constructs a callback. Actual receive I/O happens only
  when the returned callback is invoked and awaited.
- Interceptors that delegate must await the downstream callback so completion,
  backpressure, and failure propagate.

Existing OO helpers such as `modify_scope` and `intercept_send` remain
compatibility surfaces and delegate to the functional helpers.
`buffer_request_body` remains a separate higher-level operation.

Every helper's documentation states:

- Whether it runs at compile time or request time.
- Whether it changes local state or performs protocol I/O.
- Which event families it may observe or emit.
- Its return type.
- Whether it starts any work automatically.
- Its short-circuit and error-propagation semantics.

## 17. Context and Response vocabulary

The normal `$c` contract must be sufficient so raw-channel access is genuinely
exceptional.

### 17.1 Raw callbacks

`$c->raw_send` and `$c->raw_receive` are the canonical raw channel accessors.
The base Context no longer uses `send` or `receive` as raw accessors.

Protocol-specific high-level methods retain names that describe actions. In
particular, SSE `$c->send(...)` remains an actual SSE event emission method;
WebSocket uses its typed send/receive methods; HTTP uses `respond`.

This is an intentional Context cleanup. Documentation, tests, and examples are
updated together so `send` no longer sometimes means "return a callback" and
sometimes means "emit an event".

### 17.2 `PAGI::Response`

A Response is a detached local value. Canonical methods are:

- `body($bytes)` sets a raw byte body locally.
- `text($characters, charset => ...)` encodes and sets a text body locally.
- `html`, `json`, `empty`, `stream`, and related builders modify local response
  state.
- `respond($send)` emits the accumulated HTTP response events and returns a
  Future for their completion.

For backwards compatibility:

- Existing `send` remains a documented compatibility alias to `text`.
- Existing `send_raw` remains a documented compatibility alias to `body`.

The aliases are explicitly described as local body setters, not event-emission
methods. Examples prefer the canonical names.

### 17.3 Query data

HTTP, WebSocket, and SSE contexts expose the same query API backed by one parser
and cache over `scope->{query_string}`:

- `query_param`
- `query_params`
- `raw_query_param`
- `raw_query_params`
- `raw_query`

Existing protocol-specific compatibility aliases remain, but delegate to the
shared implementation so parsing and caching are not duplicated.

### 17.4 Headers

Shared Context header access is:

- `header($name)` for the last value or `undef`.
- `header_all($name)` for every value.
- `headers()` for a `PAGI::Headers` snapshot/object.
- `raw_headers()` for the original wire-pair representation.

Changing `$c->headers` from raw pairs to `PAGI::Headers` is intentional and is
documented as a migration. `raw_headers` is the explicit escape hatch.

### 17.5 State and stash

`$c->state` returns the scope's application state hashref when it exists and
`undef` when it does not. It does not silently allocate or return an unrelated
empty hashref. `$c->has_state` distinguishes presence explicitly.

Application lifespan state and per-request `stash` remain separate concepts.
Documentation explains their ownership and lifetime.

### 17.6 Scope selection

A missing scope type continues to default to HTTP for compatibility. An
explicit, unrecognized scope type croaks instead of silently constructing an
HTTP context.

## 18. Names, namespaces, and reverse routing

Each HTTP, WebSocket, and SSE route may have `name`. A mount may have
`namespace`. Mount path prefixes and name namespaces are independent:

- The mount path is always included in generated paths.
- A namespace changes only lookup names.
- An unnamed mount leaves child names unprefixed.

```perl
mount('/api/users', routes => [
    route('/{id}' => \&show, name => 'show'),
]);

# Name is still "show"; generated path includes /api/users.
```

The same child tree can be mounted more than once with explicit namespaces:

```perl
mount('/api/v1', namespace => 'v1', routes => $routes);
mount('/api/v2', namespace => 'v2', routes => $routes);

$routing->path_for('v1.show', { id => 42 });
$routing->path_for('v2.show', { id => 42 });
```

Namespaces are not derived from URL paths; changing a deployment prefix must
not silently rename logical routes.

Effective route names must be unique. Duplicate names or collisions caused by
unnamed mounts croak during construction/compilation with both conflicting
paths and guidance to add a namespace.

Reverse APIs are:

```perl
$routing->path_for($name, \%path_params, \%query_params);
$c->path_for($name, \%path_params, \%query_params);
$c->uri_for($name, \%path_params, \%query_params);
```

- Router `path_for` is request-independent and returns the application path.
- Context `path_for` includes request `root_path`.
- Context `uri_for` returns an absolute request-aware URI.

`uri_for` uses the normalized scope scheme and authority. It prefers a valid
Host header and falls back to server information where possible. HTTP and SSE
use HTTP(S); WebSocket reverse targets map HTTP/HTTPS to WS/WSS as appropriate.
If no usable authority exists, `uri_for` croaks rather than inventing one.

The router does not parse `Forwarded` or `X-Forwarded-*` itself.
`PAGI::Middleware::ReverseProxy` validates trusted proxy information and clones
the normalized scheme/host/server into scope; `uri_for` consumes that scope.
`PAGI::Middleware::TrustedHosts` validates authority. Documentation includes
the proxy/host ordering and warns that trusting arbitrary forwarded hosts
creates host-header poisoning vulnerabilities.

Path and query values are URI-escaped. Wildcard generation preserves path
separators while escaping each component. Missing/extra path parameters and
constraint failures croak with route-name-specific diagnostics.

At compilation the router is injected into request scope so Context reverse
lookups use the selected route tree. Calling Context `path_for`/`uri_for`
without a router croaks clearly.

## 19. Description and introspection

`desc` is an optional human-readable string accepted by `router`, `route`,
`websocket`, `sse`, and `mount`. It has no routing or schema behavior. It exists
for notes, route listings, documentation tools, and large-application
orientation.

The immutable tree is the initial introspection API:

```perl
my $nodes = $routing->routes;       # direct children; arrayref copy
my $named = $routing->named_routes; # effective name => node; hashref copy
my $node  = $routing->route_named('api.users.show');
```

`route_named` returns `undef` when no name exists. Reverse generation continues
to croak for an unknown name.

Common read-only node accessors are:

```perl
$node->kind;        # route, websocket, sse, or mount
$node->path;
$node->name;        # undef when unnamed
$node->desc;        # undef when absent
$node->middleware;  # arrayref copy
$node->is_raw;
$node->target;      # original handler/application target
```

HTTP route accessors additionally expose `methods` and `constraints`. Mounts
expose `namespace`, `routes` for inline child nodes, and `target` for an
application mount. A method that is inapplicable to a node returns `undef`
rather than exposing internal hashes.

Users can recursively traverse `router->routes` and inline `mount->routes` in
declaration order. Application mounts are opaque leaves. A future flattened
route-table API is deferred until a concrete OpenAPI/debugging consumer defines
whether it needs effective mounted paths, namespaces, middleware stacks, or
compiled matcher information.

## 20. Validation, compilation, and failures

Construction or compilation rejects:

- Missing or conflicting handler/`raw` targets.
- Missing or conflicting mount target/`routes` forms.
- Unknown options.
- Invalid paths or wildcard placement.
- Constraints for undeclared parameters.
- Empty/invalid method sets.
- `methods` on WebSocket or SSE nodes.
- Invalid middleware descriptors.
- Middleware factories that do not synchronously return an app coderef.
- Duplicate effective names and namespace collisions.

Handler and middleware exceptions propagate. The router does not turn ordinary
exceptions into 500 responses; `PAGI::Middleware::ErrorHandler`, and later a
top-level application object, own that policy.

Compilation resolves handlers, native app components, path matchers, reverse
indexes, middleware chains, and inherited inline-subtree defaults. Per-request
dispatch performs only request-specific matching, constraint checking, Context
construction, and handler invocation.

## 21. Testing strategy

Implementation follows test-driven development. The test matrix covers:

### Constructors and objects

- Export tags and no default exports.
- Every valid constructor form and every conflicting/unknown option.
- Immutability and collection-copy behavior.
- `desc` and all node accessors.
- `to_app` for a router and every individual executable node.
- Callable overload convenience versus the real-CODE `to_app` boundary.
- Fresh independent compilation on repeated `to_app` calls.

### Matching

- Strict declaration order.
- Full match after an earlier partial match.
- GET default, automatic HEAD, scalar/array methods, explicit `'*'`.
- No automatic OPTIONS.
- Unioned `Allow` for multiple partial matches.
- Exact trailing-slash behavior.
- Regex, predicate, and Type::Tiny-compatible constraints.
- False, throwing, and Future-returning constraint outcomes.
- Wildcard routes and their documented 405 interactions.

### Handlers and protocols

- Synchronous Response and Future-resolved Response HTTP handlers.
- Wrong HTTP handler return type diagnostics.
- Respond exactly once.
- Imperative WebSocket and SSE completion with inert return values.
- Raw HTTP, WebSocket, and SSE applications.
- HTTP, SSE, WebSocket, lifespan, and unknown-scope fallbacks.

### Defaults and mounts

- Default and customized `not_found`/`method_not_allowed`.
- Seeded status and `Allow` when using `$c` response helpers.
- An explicitly returned replacement response remains untouched.
- A matched handler's custom 404/405 remains untouched.
- Inline inheritance and mount middleware coverage.
- Application-mount ownership and opacity.
- Prefix/root-path rewriting and declaration-order mount ownership.

### Middleware

- Factory/object/class descriptor resolution.
- Factory/wrap invoked once per compiled app and state retained across requests.
- First-listed-outermost ordering.
- Short circuit and error propagation.
- Router, mount, child-router, and route placement.
- Compile-time rejection of accidental async factories and old four-argument
  middleware.
- Functional authoring helpers' local-versus-I/O lifecycle.

### Reverse routing and inspection

- Direct, mounted, namespaced, and multiply mounted names.
- Duplicate-name diagnostics.
- Constraint validation and URI escaping during generation.
- `root_path`, scheme/authority, HTTP-to-WebSocket scheme mapping.
- Trusted proxy/host integration and missing-authority failure.
- Direct and recursive route-tree inspection without mutation.

### Context/Response migration

- `raw_send`/`raw_receive` and removal of raw base `send`/`receive` meanings.
- SSE `send` remains actual event emission.
- `body`/`text` local state versus `respond` event emission.
- `Response->send` and `send_raw` compatibility aliases.
- Unified query cache/API across protocols.
- `headers` object and `raw_headers` wire pairs.
- Missing `state` returns `undef`; `has_state` distinguishes presence.

The full distribution suite must pass. Intentional failures capture diagnostics
without noisy test output.

## 22. Documentation requirements

Documentation is part of the feature, not follow-up work. It includes:

- A small single-file declarative application.
- Canonical named handlers loaded from other packages.
- Inline mounts versus application mounts.
- Route, mount, child-router, and router middleware ordering.
- Middleware factory examples using the authoring helpers.
- Negotiated `not_found` and `method_not_allowed` handlers.
- True catch-all routes at root and mounted-subtree levels, including method
  matching consequences.
- HTTP, WebSocket, SSE, and explicit raw applications.
- Regex, predicate, and Type::Tiny constraints.
- Route names, optional namespaces, duplicate-name errors, `path_for`, and
  proxy-safe `uri_for`.
- Route descriptions and recursive inspection.
- Lifecycle composition with `PAGI::Lifespan` around the router object.
- A comparison explaining when declarative routing or `PAGI::App::Router` is
  the clearer choice.
- Migration notes for every breaking Context name and every Response
  compatibility alias.

Every helper documents where it sits in the request cycle and explicitly says
whether it only changes local state, constructs a callback for later, or emits
and awaits protocol events.

POD examples used as canonical recipes should be exercised by the existing
cookbook/example test infrastructure where practical.

## 23. Implementation sequencing

The implementation plan will separate the work into three ordered phases:

1. **Context and Response contract cleanup.** Establish the handler-facing
   vocabulary, compatibility aliases, unified query/header/state behavior, and
   migration documentation.
2. **Declarative routing core.** Implement immutable nodes, matching,
   constraints, handler adapters, mounts, defaults, reverse routing,
   descriptions, inspection, and `to_app`/overload behavior.
3. **Middleware helpers and integration documentation.** Implement descriptors
   and authoring helpers, verify placement/lifecycle behavior, and complete the
   tutorial/cookbook/reference material.

The phases may be delivered as separate commits or reviewable changes, but the
public routing release is not complete until all required documentation and
cross-protocol tests are present.
