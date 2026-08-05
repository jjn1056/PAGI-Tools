# Declarative Routing

**Date:** 2026-08-03
**Status:** Approved
**Scope:** PAGI-Tools declarative routing and middleware composition using the
currently shipped Context and Response contracts

## 1. Summary

PAGI-Tools will gain a Starlette-inspired declarative routing API as an
additive alternative to `PAGI::App::Router`. It will describe an immutable
route tree with functions such as `router`, `route`, `websocket`, `sse`, and
`mount`. Normal handlers receive one `PAGI::Context` object (`$c`) and HTTP
handlers return a `PAGI::Response`; native three-channel PAGI applications
remain available through an explicit `raw` option.

The new API is not a replacement, facade, or compatibility layer for
`PAGI::App::Router`. The existing mutable router remains the traditional
native-PAGI choice. `PAGI::Endpoint::Router` also remains supported as the
class-based `$c` handler and value-flow middleware layer built over
`PAGI::App::Router`; it is not a separate matching engine. `PAGI::Routing`
introduces a second matcher with deliberately different declaration-ordered
semantics and is recommended where an immutable, decomposed, inspectable route
tree is clearer. The documentation compares all three public APIs and
identifies which matching engine and middleware contract each uses.

This design does not change the semantics of shipped `PAGI::Context` or
`PAGI::Response` methods. Normal `$c` handlers use their existing APIs, while
explicit `raw` routes bypass the Context adapter. The additive Context reverse
routing methods and scope integration are defined below. Potential vocabulary
changes to existing Context and Response methods are tracked in a separate
compatibility design and are not prerequisites for declarative routing.

The approved `PAGI::Authority` design is a prerequisite. It provides the
validated Host and server-fallback authority consumed by request-aware reverse
routing. `PAGI::Routing` does not duplicate its header cardinality, authority
grammar, or fallback implementation.

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
  generation, and request-aware absolute URL generation.
- Generate absolute URLs from normalized request-scope scheme and authority
  without parsing proxy headers in the router.
- Support Perl regexes, synchronous predicates, and Type::Tiny-compatible path
  constraints without coercing captured values.
- Make the immutable route tree inspectable and allow descriptive annotations.
- Give every executable routing object a `to_app` boundary.
- Document whether every helper mutates local state, constructs a callback, or
  emits protocol events.

## 3. Non-goals and deferred work

The first release will not include:

- HTTP verb constructors such as `get`, `post`, or `any`. They are
  intentionally omitted from the core functional API: `get` and `post`
  commonly collide with application handler names, while `delete` collides
  with Perl's core builtin. One `route` constructor keeps standard, extension,
  and application-defined methods uniform:

  ```perl
  route('/users' => \&create_user, methods => ['POST']);
  route('/rpc'   => \&rpc,         methods => ['RPC']);
  route('/any'   => \&catch_all,   methods => '*');
  ```

  The existing class-based routers retain their verb methods. A higher-level
  application framework may add convenience shortcuts later without expanding
  the core routing vocabulary.
- Automatic `OPTIONS` responses.
- Automatic trailing-slash normalization or redirection. Exact paths remain
  exact. Slash redirection may later be optional middleware.
- A top-level Starlette-like application constructor. Lifespan and
  application-wide exception policy belong there when it is designed.
- General handled-HTTP-exception types or 401/403/500 response helpers.
- Adding value-flow route middleware to `PAGI::Routing`, or unifying the two
  existing middleware models. `PAGI::Endpoint::Router` continues to support its
  shipped `async sub ($c, $next) -> PAGI::Response` route-middleware contract.
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

The absence of default exports prevents collisions with application functions
and leaves the source file explicit about the DSL it uses.

`PAGI::Middleware::Builder` also exports a different `mount` function by
default. A compilation unit must not import both symbols under the same name or
rely on module load order to choose one. A declarative-routing application
normally does not need Builder. In the occasional outer composition layer that
uses both APIs, import the Builder functions selectively:

```perl
use PAGI::Middleware::Builder qw(builder enable enable_if);
use PAGI::Routing qw(:routes :middleware);
```

Alternatively, use the object-oriented Builder API without imports:

```perl
use PAGI::Middleware::Builder ();
my $builder = PAGI::Middleware::Builder->new;
```

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
            routes => [
                route('/users/{id}' => \&show_user,
                    name        => 'users.show',
                    methods     => ['GET'],
                    constraints => { id => qr/\d+/ },
                ),
            ],
            namespace => 'api',
            desc      => 'Versioned JSON API',
        ),
    ],
);

my $app = $routing->to_app;
```

Coderef meaning is determined only by its documented argument position. The
router does not inspect signatures or guess intent:

| Form | Coderef meaning | Called with | Required result |
|---|---|---|---|
| `route('/x' => $code)` | Normal HTTP handler | `($c)` | `PAGI::Response` |
| `websocket('/x' => $code)` | Normal WebSocket handler | `($c)` | Inert; completion is awaited |
| `sse('/x' => $code)` | Normal SSE handler | `($c)` | Inert; completion is awaited |
| `route('/x', raw => $code)` | Native PAGI application | `($scope, $receive, $send)` | Inert |
| `mount('/x' => $code)` | Native PAGI application/component | `($scope, $receive, $send)` after coercion | Inert |
| `middleware($code)` | Synchronous build-time factory | `($inner_app)` | Native PAGI app coderef |

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

Executable routing objects are intentionally not callable. `to_app` is the
single compilation boundary and returns an actual PAGI application coderef:

```perl
my $app = $routing->to_app;
await $app->($scope, $receive, $send);
```

This coderef is accepted by `PAGI::Server::Runner` and native PAGI composition
points. Routing objects may also be passed directly to composition helpers that
explicitly support `PAGI::Utils::to_app`.

Each `to_app` call builds a fresh wrapper graph. Middleware factories and
class-name descriptors are resolved once for that compiled application, so
their ordinary internal state is independent from applications produced by
other `to_app` calls. Applications should therefore call `to_app` once per
intended application instance, not once per request, and retain the resulting
coderef. Compilation never mutates the source description.

One compiled application handles concurrent in-flight requests. Compiled
routing structures contain no request-specific mutable state; request data
remains in the request scope, Context, or invocation-local lexicals.

Reusing an explicitly constructed middleware/component instance, or a factory
closure that captures external state, still shares that caller-owned state.
Fresh compilation does not clone arbitrary user objects or closure captures.

If the same declarative subtree is mounted twice, each mount occurrence
receives its own compiled middleware wrapper graph unless both occurrences
explicitly reference shared instances or captured state.

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

When `methods` is omitted, the route accepts `GET`. Every route containing GET
also automatically accepts HEAD; there is no opt-out that can leave a GET
resource without HEAD support. By default, the same handler runs for GET and
HEAD.

For an expensive GET, the canonical custom-HEAD form is two ordinary routes
with the explicit HEAD route declared first:

```perl
route('/report' => \&head_report,
    methods => ['HEAD'],
),

route('/report' => \&get_report,
    methods => ['GET'],
),
```

This is declaration-order behavior, not a special relationship between the two
nodes. For a HEAD request, the first route is a full explicit match. For a GET
request, the HEAD route is partial, scanning continues, and the GET route is a
full match. If the custom HEAD route's constraints reject a value, scanning
continues and the GET route's automatic HEAD support remains the fallback.

The router does not associate, reorder, or otherwise recognize the pair. If the
GET route is declared first, its automatic HEAD match wins immediately and a
later custom HEAD handler is not invoked. Documentation keeps the two routes
adjacent, puts HEAD first, and calls out the ordering requirement wherever the
pattern is taught.

`methods => '*'` explicitly includes HEAD. There is no automatic `OPTIONS`
behavior. Handling all methods must be explicit with `methods => '*'`.

The compiled router owns HTTP HEAD semantics; `PAGI::Middleware::Head` is not
required. At the router's outer dispatch boundary, a HEAD request retains
`method => 'HEAD'` for matching and handlers, while `$send` is wrapped to:

- Forward `http.response.start` unchanged, preserving calculated headers such
  as `Content-Length`.
- Never forward an original `http.response.body` event. This suppresses both
  ordinary `body` bytes and the `file`, `offset`, and `length` sendfile variant.
- Drop streaming body events whose `more` value is true.
- Treat a false or absent `more` value as terminal. On the first terminal body
  event, including a sendfile event with no `more` field, emit exactly one
  replacement `{ type => 'http.response.body', body => '', more => 0 }`.
- Suppress response trailers and never open or transfer a referenced file.

This applies to matched routes, generated 404/405 responses, inline subtrees,
and application mounts. The selected handler still constructs the corresponding
full response so its status and headers match the equivalent GET response. A
custom HEAD route can instead avoid the expensive GET work, but its wire body
is suppressed in the same way.

Separately compiled declarative routers coordinate with an unforgeable private
marker propagated only through shallow request-scope copies. Only the
outermost participating compiled router installs the wire suppressor. Parent
router, application-mount, and raw-route middleware therefore see the full
child representation, and no incoming scope or shared mutable matcher state is
changed.

`PAGI::Middleware::Head` remains available for applications outside this
router. Wrapping this router with it is redundant and changes the method
observed by inner handlers from HEAD to GET.

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
mount('/tenants/{tenant_id}',
    routes     => [
        route('/users/{user_id}' => \&user),
    ],
    namespace  => 'tenant',
    desc       => 'Tenant API subtree',
    middleware => [ ... ],
    constraints => {
        tenant_id => qr/[a-z0-9-]+/,
    },
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

Mount prefixes accept the same single-segment parameter syntax and constraint
types as routes. A wildcard is invalid in a mount prefix because every mount
already has an implicit remainder. A failed mount constraint is no match, so
the parent continues scanning later siblings. Mount captures validate but do
not coerce.

A mount prefix begins with `/`. A trailing slash is removed except for the root
mount, so `/api` and `/api/` describe the same boundary. A root mount `/`
matches every path and consumes zero path characters. It leaves both `path` and
`root_path` unchanged; in particular, it never changes an empty `root_path` to
`/`. `raw_path` also remains the original on-the-wire bytes.

For example, these values are identical before and inside `mount('/' => $app)`:

```perl
{
    path      => '/users/42',
    root_path => '/outer',
    raw_path  => '/outer/users/42',
}
```

A request whose path exactly equals a non-root mount prefix matches that mount
directly, and the child receives `/` as its `path`, never an empty string.

This exact-prefix behavior deliberately differs from Starlette. Starlette's
`Mount('/api', ...)` matches `/api/`; its default slash-redirect behavior sends
`/api` to `/api/`, while disabling slash redirects leaves `/api` unmatched.
`PAGI::Routing` instead follows the shipped `PAGI::App::Router` behavior: both
spellings enter the mount directly, with no redirect. Applications that want a
canonical slash form may add separate redirect middleware.

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

On a match, the actual consumed prefix is appended to `root_path`, named mount
captures are merged into `path_params`, and `path` becomes the unconsumed
remainder. `raw_path` remains the original on-the-wire path bytes. These child
scope values are installed before mount middleware and the mounted app or
inline child router run. Reverse routing always includes the mount prefix.
The incoming decoded `root_path` and decoded consumed prefix are joined with
exactly one boundary slash. Their other slashes and characters are retained.

For example, `/tenants/acme/users/42` under the inline mount above reaches the
child route with the effective scope:

```perl
{
    path      => '/users/42',
    root_path => '/tenants/acme',
    raw_path  => '/tenants/acme/users/42',
    path_params => {
        tenant_id => 'acme',
        user_id   => '42',
    },
}
```

An existing `root_path` is retained and extended. Reusing a path-parameter name
across a known inline mount/route ancestry is rejected at compilation rather
than silently overwriting an outer capture.

An application mount and a raw HTTP route both accept native PAGI apps, but
they are not interchangeable:

| Behavior | `route(..., raw => $app)` | `mount(... => $app)` |
|---|---|---|
| Path selection | Matches its exact route pattern; a wildcard must be declared explicitly | Matches a possibly parameterized path prefix at a segment boundary; the remainder is implicit |
| HTTP methods | Participates in the route method set, automatic HEAD, partial matching, and `Allow` | Applies no method filter; the mounted app owns method handling |
| Protocol | HTTP only; use raw `websocket` or `sse` nodes for those protocols | Delegates applicable HTTP, WebSocket, and SSE scopes to the mounted app |
| Child scope | Keeps the routed path and `root_path`, adding captured path parameters | Removes the matched prefix from `path`, appends the actual match to `root_path`, and merges mount captures into `path_params` |
| Parent behavior | A nonmatching route lets scanning continue; a method mismatch contributes a partial match | A matching prefix immediately owns the request; child 404/405 outcomes do not resume the parent scan |
| Reverse routing | May be named and generated as an ordinary route | An opaque application mount exposes no child names or routes to its parent |

For example, given a request for `/files/a.txt`, a raw wildcard route such as
`route('/files/*path', raw => $app)` calls the application with the routed path
still `/files/a.txt` and `path_params->{path}` equal to `a.txt`. In contrast,
`mount('/files' => $app)` calls it with `path` equal to `/a.txt` and
`root_path` extended by `/files`. Use a raw route to select a native app as one
route endpoint; use a mount to give an application ownership of a URL subtree.

## 9. Matching algorithm

Routes are evaluated strictly in declaration order. There is no specificity
sorting or hidden prioritization.

For HTTP:

1. Iterate nodes in declaration order with an initially empty set of allowed
   methods.
2. For an ordinary HTTP route, a path-and-method match is `FULL`; dispatch it
   immediately. A path match with the wrong method is `PARTIAL`; add its
   normalized methods to the allowed set and continue.
3. For a mount, first test its prefix at a path-segment boundary: `/api` matches
   `/api` and `/api/...`, but not `/apix`. If it does not match, continue. If it
   matches and its constraints pass, select the mount immediately; do not
   examine later siblings. A failed constraint is no match.
4. An application mount receives the rewritten scope and owns the result. An
   inline mount recursively runs its child router with a fresh allowed-method
   set and its inherited `not_found` and `method_not_allowed` handlers.
5. A child subtree's partial matches are resolved inside that subtree. They do
   not join partial matches previously accumulated by the parent. Likewise, a
   child not-found result does not resume the parent scan.
6. After all nodes have been examined, invoke `method_not_allowed` with the
   allowed-method union if it is non-empty; otherwise invoke `not_found`.

The 405 `Allow` header contains the normalized union from every partial match
at the current routing level, not merely the first route with that path.
Methods retain deterministic first-seen order across route declarations and
within each declared method list; an automatically added HEAD appears
immediately after its GET. For example, separate GET and POST routes for one
path produce `Allow: GET, HEAD, POST` for a PUT request. A later full match
still dispatches normally and discards the accumulated partial-match set.

This ordering deliberately differs from `PAGI::App::Router`, which
alphabetically sorts the deduplicated method set. `Allow` represents a set, so
its ordering does not express routing priority. `PAGI::Routing` nevertheless
preserves declaration order to avoid hidden reordering and to make generated
output deterministic. For example, POST followed by GET produces
`Allow: POST, GET, HEAD`. A custom HEAD route declared before its GET route
produces `Allow: HEAD, GET` when both are partial matches. An automatically
derived HEAD is inserted after GET only when HEAD has not already been seen;
deduplication never moves an earlier method.

This deliberately differs from `PAGI::App::Router`, which evaluates routes
before mounts regardless of declaration order and then checks mounts
longest-prefix-first. `PAGI::Routing` treats mounts as declared nodes: an
earlier matching mount can preempt a later sibling route, and an earlier
broader mount can preempt a later narrower mount. Applications must therefore
declare narrower mounts first when both prefixes may match.

For WebSocket and SSE, only nodes for that protocol plus applicable mounts are
considered. Protocol-specific unmatched behavior is defined in section 14.

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

A wildcard occupies one complete terminal path segment and captures the
remaining decoded path:

```perl
route('/files/*path' => \&serve_file);
```

- A route may contain at most one wildcard, and it must be terminal.
- The wildcard may match an empty remainder.
- The separating slash is not part of the capture; internal slashes are.
- `/files/*path` matches `/files/` with `path => ''` and `/files/a/b` with
  `path => 'a/b'`. It does not match `/files`, because paths remain exact.
- `/*path` matches `/` with `path => ''`, making it a real root-level
  catch-all.
- Reverse generation accepts an empty value and values containing `/`,
  preserving those internal separators while escaping each path component.
- Forms such as `/files/*path/more`, `/files/prefix*path`, and multiple
  wildcards are invalid.

This intentionally differs from `PAGI::App::Router`, whose `(.+)` wildcard
requires at least one captured character.

Wildcard captures are untrusted decoded request input. The router intentionally
preserves values such as `.`, `..`, repeated separators, backslashes, and other
filesystem-significant characters; validation and non-coercion do not make
them safe paths. Never concatenate a wildcard capture directly with a document
root. File-serving code must canonicalize the resulting path and verify, at a
path-component boundary, that the resolved target remains beneath the
configured root. Prefer a dedicated file-serving component over implementing
this policy in a route handler, but verify that component's containment and
symlink policy for the deployment.

The existing `:id` and `{id:\d+}` spellings accepted by `PAGI::App::Router`
are also accepted for familiarity, but documentation uses braces plus explicit
Perl-native constraints:

```perl
constraints => {
    id => qr/\d+/,
}
```

An inline `{name:pattern}` constraint is syntax sugar for a regex constraint on
that captured segment. It is compiled through the same matcher as
`constraints => { name => qr/.../ }`, using `\A(?:$pattern)\z` for both request
matching and reverse generation. There is no separate `^...$` inline-constraint
path. Consequently, both spellings reject trailing newlines and other partial
matches identically.

Inline tokenization recognizes escaped braces, character classes, quantifier
braces, and ordinary `(?#...)` regex comments, but it is intentionally not a
complete Perl regex parser. Complex regexes, especially extended-mode comments,
use the explicit `constraints => { name => qr/.../ }` form.

A constraint may be:

- A `Regexp`. The router evaluates it as `\A(?:$pattern)\z` against the decoded
  captured value, preserving the pattern's embedded flags. `\A` and `\z` are
  mandatory implementation semantics; `^` and `$` are not substitutes because
  `$` may match before a trailing newline. Consequently, `qr/\d+/` accepts
  `"12"` but rejects `"12\n"`.
- A synchronous unary predicate coderef. It receives exactly the captured
  string and returns truth for acceptance.
- A blessed Type::Tiny-compatible object with `check($value)`, plus optional
  `get_message($value)` diagnostics.

Constraint names must correspond to parameters declared by that route or
mount. Invalid names croak during construction.

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

Constraints are also applied during reverse generation using the same wrapped
matcher. Invalid values croak, using `get_message` when a Type::Tiny-compatible
object provides it.

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
response are accepted. Dispatch normalizes the returned value, awaits it when
necessary, and requires the resolved value to be a `PAGI::Response`. Any other
value, including `undef`, croaks with the established diagnostic `handler did
not return a response`. Dispatch then emits that Response exactly once through
`$c->respond`.

A normal handler does not receive raw `$scope`, `$receive`, or `$send`. It does
not emit response events itself. In particular, it must not call `$c->respond`
itself. Manually responding and returning `undef` still produces `handler did
not return a response`; manually responding and returning a Response produces
the existing `response already sent` error when dispatch attempts
framework-owned emission. Native response-event ownership requires `raw`.

Documentation presents `raw` as the explicit escape hatch for advanced cases
that must emit events manually, and contrasts the two complete lifecycles:

```perl
# Normal: build local state, return it, let routing emit once.
route('/normal' => async sub {
    my ($c) = @_;
    return $c->text('Hello');
});

# Raw: own all three PAGI channels and emit protocol events directly.
route('/raw', raw => async sub {
    my ($scope, $receive, $send) = @_;
    await $send->({
        type => 'http.response.start', status => 200, headers => [],
    });
    await $send->({
        type => 'http.response.body', body => 'Hello', more => 0,
    });
});
```

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

The returned `PAGI::Response` is final except for one protocol invariant. After
invoking `method_not_allowed`, if the returned response still has status 405
and lacks an `Allow` header, the router adds the computed `Allow` value before
emission. An existing `Allow` header is preserved. If the handler changes the
status, redirects, or otherwise returns a non-405 response, the router adds
nothing. `not_found` responses and responses from fully matched routes remain
entirely untouched. Documentation recommends the seeded `$c` helpers as the
safe and concise path.

This safety rule also covers a detached response that did not retain the seeded
accumulator:

```perl
return PAGI::Response->json(
    { error => 'Method Not Allowed' },
    status => 405,
);
```

The router adds only the missing computed `Allow`; it does not restyle the
status, body, content type, or other headers.

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

Nonempty descriptor configuration is accepted only for class names. A coderef
factory captures configuration in its closure; passing `%config` beside it
croaks rather than silently discarding options. Configured objects likewise
take no additional descriptor configuration.

A middleware object supplies `wrap($app)`. A class-name descriptor resolves and
configures the class using the existing middleware conventions, then applies
`wrap($app)`.

`PAGI::Routing` supports only PAGI-spec event middleware factories. At build
time a factory maps one native PAGI app to another; at request time the wrapped
app receives only `($scope, $receive, $send)`. There is no direct four-argument
`($scope,$receive,$send,$next)` middleware form. The previously removed form
made `$next` ambiguously mean inherited channels or replacement channels,
blurred factory time and request time, and diverged from the PAGI middleware
specification.

This is distinct from `PAGI::Endpoint::Router`'s shipped value-flow route
middleware, where `$next->()` resolves to a `PAGI::Response` that middleware
may inspect, decorate, or replace. That specialized class-based contract
remains supported, but no attempt is made here to generalize or unify it with
declarative event middleware.

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

`PAGI::Middleware::Helpers` is a standalone, non-inherited Exporter module with
no default exports:

```perl
use PAGI::Middleware::Helpers qw(
    clone_scope
    wrap_send
    wrap_receive
);

my $child_scope    = clone_scope($scope, \%changes);
my $wrapped_send   = wrap_send($send, $interceptor);
my $wrapped_receive = wrap_receive($receive, $interceptor);
```

- `clone_scope` performs a shallow local clone plus requested changes. It does
  no I/O and returns immediately.
- `wrap_send($send, $interceptor)` returns an async send callback. When invoked
  with an event, it calls the interceptor with
  `($event, $downstream_send)`. The interceptor owns delegation and may forward,
  replace, suppress, or expand the event into multiple downstream sends.
- `wrap_receive($receive, $interceptor)` returns an async receive callback.
  When invoked, it calls the interceptor with `($downstream_receive)`. The
  interceptor may receive once or repeatedly, filter or replace an event, or
  synthesize an event without reading downstream.
- Wrapper construction performs no I/O and starts no work. Receive I/O occurs
  only if the returned callback is invoked and its interceptor calls the
  downstream receive callback.
- Interceptors may return an immediate value or a Future. The wrapper resolves
  to that result and propagates failures. Interceptors that delegate must await
  or return the downstream Future so completion, backpressure, and failure are
  not detached.
- The scope, changes, channel, and interceptor arguments are validated as the
  appropriate hashrefs or coderefs when each helper is constructed. The helpers
  do not inspect event types, invent return-value conventions, or delegate
  automatically.

For example:

```perl
my $wrapped_send = wrap_send($send, async sub {
    my ($event, $downstream_send) = @_;
    return if should_drop($event);
    await $downstream_send->($event);
});

my $wrapped_receive = wrap_receive($receive, async sub {
    my ($downstream_receive) = @_;
    while (1) {
        my $event = await $downstream_receive->();
        next if $event->{type} eq 'app.heartbeat';
        return $event;
    }
});
```

The downstream callbacks are the real PAGI channels with fixed signatures;
they are not an application continuation or another `$next` abstraction.

`PAGI::Middleware` remains an OO base class and does not install utility
functions into subclasses. Its existing `modify_scope` and `intercept_send`
methods remain unchanged compatibility surfaces. Their implementations may
delegate internally where the functional contracts are identical, but that is
not part of the public promise. `wrap_receive` is initially functional-only;
no OO counterpart is added. `buffer_request_body` remains a separate
higher-level operation.

Every helper's documentation states:

- Whether it runs at compile time or request time.
- Whether it changes local state or performs protocol I/O.
- Which event families it may observe or emit.
- Its return type.
- Whether it starts any work automatically.
- Its short-circuit and error-propagation semantics.

## 17. Names, namespaces, and reverse routing

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
mount('/api/v1', routes => $routes, namespace => 'v1');
mount('/api/v2', routes => $routes, namespace => 'v2');

$routing->path_for('v1.show', { id => 42 });
$routing->path_for('v2.show', { id => 42 });
```

Dynamic inline mount parameters participate in reverse generation alongside
child-route parameters:

```perl
mount('/tenants/{tenant_id}', routes => [
    route('/users/{user_id}' => \&show, name => 'user.show'),
], namespace => 'tenant');

$routing->path_for('tenant.user.show', {
    tenant_id => 'acme',
    user_id   => 42,
});
# /tenants/acme/users/42
```

An application mount receives its captured parameters in scope but remains an
opaque reverse-routing leaf.

Namespaces are not derived from URL paths; changing a deployment prefix must
not silently rename logical routes.

Effective route names must be unique. Duplicate names or collisions caused by
unnamed mounts croak during construction/compilation with both conflicting
paths and guidance to add a namespace.

Reverse APIs are:

```perl
$routing->path_for($name, \%path_params, \%query_params);
$c->path_for($name, \%path_params, \%query_params);
$c->url_for($name, \%path_params, \%query_params);
```

- Router `path_for` is request-independent and returns the application path.
- Context `path_for` includes the `root_path` captured at the selected compiled
  router's entry boundary. Older or manually constructed version-1 frames that
  omit the additive field fall back to the current request `root_path`.
- Context `url_for` returns an absolute request-aware URL string.

Scope `root_path` is decoded Unicode. Context reverse routing percent-encodes
it component-wise while preserving `/`, then joins that boundary to the
resolver's already encoded application path and query without encoding either
part a second time.

`url_for` obtains authority from `PAGI::Authority->from_scope($scope)`. A valid
Host is preferred; server information is used only when Host is absent. A
malformed or duplicate Host croaks rather than falling back, and no usable
source also croaks rather than inventing one. HTTP and SSE use HTTP(S);
WebSocket reverse targets map HTTP/HTTPS to WS/WSS as appropriate.

`PAGI::Routing` does not introduce another `uri_for`. The shipped
`PAGI::App::Router->uri_for` and `PAGI::Endpoint::Router->uri_for` remain
unchanged as legacy path-returning APIs.

The router does not parse `Forwarded` or `X-Forwarded-*`. `url_for` consumes the
scheme, authority, and server information present in the normalized request
scope.

The shipped `PAGI::Middleware::ReverseProxy` and
`PAGI::Middleware::TrustedHosts` currently process only HTTP scopes. Extending
either middleware to WebSocket or SSE is not part of this routing design and is
not a prerequisite for declarative routing. Those extensions are tracked in a
separate cross-protocol compatibility design because they change the behavior
of existing middleware for scopes that currently pass through untouched.

For HTTP deployments using the shipped middleware, the canonical order remains:

```text
ReverseProxy
  -> TrustedHosts
    -> PAGI::Routing
```

WebSocket and SSE deployments are responsible for supplying correctly
normalized and validated scope information until protocol-aware middleware
behavior is separately designed and released. Documentation warns that
trusting arbitrary forwarded hosts creates host-header poisoning
vulnerabilities.

Path and query values are URI-escaped. Wildcard generation preserves path
separators while escaping each component. Missing/extra path parameters and
constraint failures croak with route-name-specific diagnostics.

`PAGI::Routing` reserves the complete `pagi.routing` scope key. It does not
read, replace, or repurpose the existing `pagi.router` metadata used by
`PAGI::App::Router`; the two keys remain independent when applications combine
the routers.

The value is a versioned stack of request-local routing frames:

```perl
{
    version => 1,
    frames  => [
        {
            resolver  => $resolver,
            root_path => '/proxy', # optional additive version-1 field
            mounts    => [],
            match     => undef,
        },
    ],
}
```

The router installs its frame before invoking router middleware. Each compiled
router publishes a scalar `root_path` captured before any of that router's
inline mounts rewrite the scope. This prevents reverse generation from adding
inline prefixes twice while allowing a separately compiled child to retain its
parent application-mount prefix. The field is an additive version-1 extension:
older or manually constructed frames may omit it, and Context reverse routing
then falls back to the current scope `root_path`. If present it must be a
defined non-reference scalar. The frame is shared through that router's shallow
internal scope clones. Consumers may inspect it but must treat it as read-only;
dispatch and reverse routing do not accept consumer mutation as configuration.

When an inline mount matches, the router appends a descriptor containing its
declared path, namespace, and description to the current frame's `mounts`
before invoking that mount's middleware. Nested inline mounts update the same
frame. When a leaf route matches, `match` becomes:

```perl
{
    kind  => 'route', # or websocket / sse
    route => '/tenants/{tenant_id}/users/{user_id}',
    name  => 'tenant.user.show',
    desc  => 'Display one tenant user',
}
```

`route` is the effective mounted pattern and `name` is the effective namespaced
name. Unnamed routes have `name => undef`. This metadata is installed before
route middleware and the handler run. A selected application mount records
`kind => 'mount'` and its effective mount pattern, but cannot publish
information about the opaque child application. Router-generated 404 and 405
outcomes leave `match` undefined; an inline mount chain may still be present.

Because the frame is a shared request-local reference, router and mount
middleware can inspect the final match after awaiting downstream execution.
Middleware outside the compiled routing boundary receives its original scope
and must not assume downstream top-level scope additions propagate upward.

A separately compiled `PAGI::Routing` application receives a new shallow scope
containing a new `pagi.routing` container with its frame appended to the prior
frames. It never overwrites an ancestor frame. Context `path_for` and `url_for`
always use the last frame's resolver and router-entry `root_path`. This covers
routers, individual routing nodes compiled with `to_app`, raw routes targeting
another compiled router, and application mounts containing a separately
compiled router. Parent middleware retains its own terminal mount metadata,
while middleware inside the child can inspect the complete routing ancestry.

If an existing `pagi.routing` value does not have the supported version and
frame-stack shape, request dispatch croaks with a scope-key collision diagnostic
rather than silently overwriting foreign data. The key and frame schema are
public scope integration surfaces and are documented alongside the PAGI
scope-extension conventions.

## 18. Description and introspection

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
expose `namespace`, `constraints`, `routes` for inline child nodes, and `target`
for an application mount. A method that is inapplicable to a node returns
`undef` rather than exposing internal hashes.

Users can recursively traverse `router->routes` and inline `mount->routes` in
declaration order. Application mounts are opaque leaves. A future flattened
route-table API is deferred until a concrete OpenAPI/debugging consumer defines
whether it needs effective mounted paths, namespaces, middleware stacks, or
compiled matcher information.

## 19. Validation, compilation, and failures

Construction or compilation rejects:

- Missing or conflicting handler/`raw` targets.
- Missing or conflicting mount target/`routes` forms.
- Unknown options.
- Invalid paths or wildcard placement.
- Constraints for undeclared parameters.
- Duplicate parameter names across known inline mount/route ancestry.
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

## 20. Testing strategy

Implementation follows test-driven development. The test matrix covers:

### Constructors and objects

- Export tags and no default exports.
- Every valid constructor form and every conflicting/unknown option.
- Immutability and collection-copy behavior.
- `desc` and all node accessors.
- `to_app` for a router and every individual executable node.
- Routing objects are not callable; `to_app` returns a real `CODE` reference.
- State persistence within one compiled app and ordinary isolation across two
  `to_app` results, including explicitly shared instance/closure exceptions.
- Concurrent in-flight requests do not leak request-specific state.

### Matching

- Strict declaration order.
- Full match after an earlier partial match.
- GET default, automatic HEAD, custom HEAD-before-GET override ordering,
  reversed-order behavior, constraint fallback, scalar/array methods, and
  explicit `'*'`.
- No automatic OPTIONS.
- Unioned `Allow` for multiple partial matches, first-seen ordering, automatic
  HEAD placement/deduplication, and the shipped router's alphabetical-order
  divergence.
- Exact trailing-slash behavior.
- Explicit and inline regex constraints with the same absolute whole-value
  anchoring, including literal and percent-decoded trailing newlines; predicate
  and Type::Tiny-compatible constraints.
- False, throwing, and Future-returning constraint outcomes.
- Empty and non-empty wildcard captures, invalid wildcard placement, reverse
  generation, documented 405 interactions, and preservation of decoded
  traversal-like input without filesystem interpretation.

### Handlers and protocols

- Synchronous Response and Future-resolved Response HTTP handlers.
- Wrong HTTP handler return type diagnostics, including `undef` after a manual
  `$c->respond` attempt.
- Respond exactly once.
- Imperative WebSocket and SSE completion with inert return values.
- Raw HTTP, WebSocket, and SSE applications.
- HTTP, SSE, WebSocket, lifespan, and unknown-scope fallbacks.
- HEAD preserves the request method while suppressing buffered, streamed, and
  mounted response bodies and trailers, including generated 404/405 outcomes.
- HEAD suppresses the `file`, `offset`, and `length` sendfile body variant,
  treats an absent `more` as terminal, and emits one empty terminal body event.

### Defaults and mounts

- Default and customized `not_found`/`method_not_allowed`.
- Seeded status and `Allow` when using `$c` response helpers.
- A detached 405 response receives a missing computed `Allow`; an existing
  `Allow` and a returned non-405 status remain untouched.
- A matched handler's custom 404/405 remains untouched.
- Inline inheritance and mount middleware coverage.
- Application-mount ownership and opacity.
- Prefix/root-path rewriting and declaration-order mount ownership.
- Static, root, and parameterized mount prefixes; mount constraints and
  inherited path parameters; exact-prefix child `/`; original `raw_path`
  preservation.
- Root mounts leave `path`, `raw_path`, and both empty and non-empty incoming
  `root_path` values unchanged.
- Mounting the same subtree twice produces independent compiled middleware
  wrappers unless sharing is explicit.

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
- Versioned `pagi.routing` frame creation, inline updates, effective route/name
  metadata, and current-frame reverse resolution.
- Nested compiled routers preserve frame ancestry without overwriting
  `pagi.router`, parent frames, or malformed foreign values.
- HTTP trusted proxy/host integration, middleware ordering, and
  missing-authority failure.
- WebSocket and SSE URL generation from already-normalized scopes without
  changing the shipped HTTP-only proxy/Host middleware behavior.
- Direct and recursive route-tree inspection without mutation.

The full distribution suite must pass. Intentional failures capture diagnostics
without noisy test output.

## 21. Documentation requirements

Documentation is part of the feature, not follow-up work. It includes:

- A small single-file declarative application.
- Canonical named handlers loaded from other packages.
- Inline mounts versus application mounts.
- Dynamic mount captures across child handlers, middleware, scope rewriting,
  and reverse generation.
- Exact mount-prefix behavior, including the deliberate difference from
  Starlette's default trailing-slash redirect.
- Route, mount, child-router, and router middleware ordering.
- Middleware factory examples using the authoring helpers.
- Negotiated `not_found` and `method_not_allowed` handlers.
- True catch-all routes at root and mounted-subtree levels, including method
  matching consequences.
- The explicit-HEAD-before-GET convention for inexpensive custom HEAD handlers,
  including why reversing the declarations invokes the GET handler instead.
- HTTP, WebSocket, SSE, and explicit raw applications.
- Normal Response-returning HTTP lifecycle versus the explicit `raw` escape
  hatch for manual channel ownership.
- Regex, predicate, and Type::Tiny constraints.
- Wildcard security, including decoded traversal input, canonical containment
  checks, symlink policy, and why route matching is not filesystem sanitization.
- Route names, optional namespaces, duplicate-name errors, `path_for`, and
  proxy-safe `url_for`.
- The `pagi.routing` scope schema, matched-route metadata lifecycle, nested
  frame behavior, and visibility from each middleware level.
- HTTP trusted-proxy and Host-validation ordering, plus the current
  cross-protocol pass-through limitation.
- Route descriptions and recursive inspection.
- Lifecycle composition with `PAGI::Lifespan` around the router object.
- A comparison explaining the roles, matching engines, and middleware contracts
  of declarative routing, `PAGI::App::Router`, and `PAGI::Endpoint::Router`,
  including their observable `Allow` ordering difference.

Every helper documents where it sits in the request cycle and explicitly says
whether it only changes local state, constructs a callback for later, or emits
and awaits protocol events.

POD examples used as canonical recipes should be exercised by the existing
cookbook/example test infrastructure where practical.

## 22. Implementation sequencing

The implementation plan will separate the work into two ordered phases:

1. **Declarative routing core.** Implement immutable nodes, matching,
   constraints, handler adapters, mounts, defaults, reverse routing,
   descriptions, inspection, and `to_app` behavior.
2. **Middleware helpers and integration documentation.** Implement descriptors
   and authoring helpers, verify placement/lifecycle behavior, and complete the
   tutorial/cookbook/reference material. Cross-protocol changes to the shipped
   proxy and Host middleware remain outside this routing release.

The phases may be delivered as separate commits or reviewable changes, but the
public routing release is not complete until all required documentation and
cross-protocol tests are present.
