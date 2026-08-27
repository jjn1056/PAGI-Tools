# Starlette-Aligned Routing and Composition

**Date:** 2026-08-26

**Status:** Draft design; awaiting written-spec review

**Scope:** Simplify `PAGI::Routing`, `PAGI::Compose`,
`PAGI::App::Router`, and `PAGI::Endpoint::Router` around one clear separation
of route matching, application composition, middleware, and root lifecycle

## 1. Decision

PAGI-Tools will realign its routing surface with the separation of concerns
that made Starlette's original design attractive:

- a Route is a complete-path leaf;
- a Router selects among ordered Routes and Mounts;
- a Mount performs prefix-based application composition;
- middleware transforms an application; and
- Compose owns the application root, outer middleware, lifespan, and final
  safety boundaries.

The current implementation weakened those boundaries while solving reverse
routing and nested fallback policy. In particular, Mount acquired three target
modes (`target`, `routes`, and `router`), `group` became a second spelling for
structural nesting, and Router exhaustion became a trace consumed by automatic
Compose middleware. Each feature is individually explainable, but together
they make it difficult to answer basic questions such as whether a child Router
is a real application boundary, whether a parent may handle its miss, and when
to use `group` rather than `mount`.

This design removes those distinctions instead of documenting around them.
Mount always delegates to an application after a prefix match. Supplying
`routes` is only shorthand for constructing that mounted Router application.
Reverse lookup may inspect a mounted application's declared routes, but that
inspection never changes dispatch ownership.

Router once again completes HTTP routing outcomes itself. It invokes a normal
default application when no path matches and emits a compliant 405 when paths
match but methods do not. Compose no longer reconstructs those outcomes from a
routing trace. This makes a nested Router useful by itself and makes a matched
Mount's ownership final and unsurprising.

This is an intentional breaking redesign of unreleased PAGI-Tools APIs. No
compatibility aliases or dual semantic modes are required.

## 2. Work map

| Repository | Ticket | Branch | Base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | Starlette-aligned routing composition | `design/starlette-aligned-routing-composition` | `main@e4b2683e1b463e0c8bcff1198cd0c03d50f3caba` | This design specification only | Documentation/design; no runtime change | None unless separately authorized |

## 3. Governing and superseded designs

Where they conflict, this specification supersedes the following designs:

- the 2026-08-03 declarative-routing design's three-form Mount and
  nonterminal Router exhaustion;
- the 2026-08-05 Compose design's claim that routing fallback remains
  Router-owned through the then-current callback surface;
- the 2026-08-08 Router-mount reverse-routing design's special
  `router => $router` target mode;
- the 2026-08-10 unified-router-frontends design's `group` construct and
  routing-aware-versus-opaque Mount distinction;
- the 2026-08-13 routing fallback/error middleware design's routing trace,
  cooperative decline protocol, and automatic Compose NotFound and
  MethodNotAllowed layers; and
- the 2026-08-16 Starlette apples example design where it describes Compose
  as the owner of Router 404 and 405 outcomes.

The following existing decisions remain in force unless this document says
otherwise:

- immutable declarative descriptions and fresh `to_app` compilation;
- declaration-order matching and first FULL match ownership;
- automatic HEAD qualification for GET, with an earlier explicit HEAD route
  able to win;
- constraint validation without path-value coercion;
- the inline `&Provider` constraint channel;
- route-, Router-, Mount-, and Compose-level pure PAGI middleware;
- slash-addressed route names, relative reverse lookup, query parameters, and
  fragments;
- `PAGI::Pages` as the stock negotiated response factory;
- `PAGI::Compose` as the root lifespan owner; and
- the shared declarative compiler used by the functional, mutable, and
  method-oriented frontends.

## 4. Why change the current design

### 4.1 Mount has two meanings today

These current declarations look similar but have materially different
semantics:

```perl
mount('/api', routes => \@routes, name => 'api');
mount('/api', router => $router, name => 'api');
mount('/api' => $app);
```

The first is an inline structural subtree, the second is a routing-aware child
whose unanswered result can be interpreted outside it, and the third is an
opaque application. A programmer must know implementation history to predict
metadata, reverse discovery, and fallback behavior.

Starlette's Mount has one runtime meaning: after the prefix matches, it rewrites
the child scope and calls an application. Its `routes` argument simply builds a
Router to use as that application. PAGI should preserve that conceptual economy.

### 4.2 `group` competes with Mount

`group('/api' => sub { ... })` and `mount('/api', routes => [...])` both place a
route collection beneath a prefix. Their distinction is subtle enough that a
new user has to memorize which one creates a boundary and which one is
structural. Removing `group` makes the question disappear. A Mount with
`routes` is the one nested-route construct.

### 4.3 Trace-based fallback reverses ownership

The current Router records NONE or PARTIAL evidence and emits no HTTP response.
Compose later interprets that evidence through automatic middleware. This was
designed to let misses bubble across nested Routers, but a matched Mount is
already a composition decision. Letting a parent policy render a child's miss
makes the child only partly own its subtree.

It also requires considerable machinery:

- request-local trace frames and checkpoints;
- transparent versus opaque trace propagation;
- routing-aware NotFound and MethodNotAllowed middleware;
- Compose ordering rules for automatic fallback layers; and
- special treatment of applications that complete silently.

Router defaults remove this machinery. A Router is a complete routing
application; an arbitrary application that completes without starting a
response is an application error, not an implicit decline.

### 4.4 Closer concepts make examples and generated code better

The goal is not line-for-line Starlette compatibility. Perl and PAGI have
different handler and protocol conventions. The goal is that familiar names
carry familiar responsibilities. That makes the API easier to teach, easier to
inspect, and less likely to be misused by either a person or a code-generating
tool familiar with Starlette.

## 5. Conceptual model

```text
Compose
  root middleware + lifespan + safety boundaries
  |
  v
Router
  ordered selection + NONE default + PARTIAL 405
  |
  +-- Route ---------- exact leaf + methods + endpoint
  |
  `-- Mount ---------- prefix + rewritten scope + child application
                           |
                           `-- often another Router
```

Reverse-route inspection follows mounted `PAGI::Routing::Router` objects. The
runtime call graph remains the graph above. Inspection does not flatten it.

## 6. Shared application contract

Every option named `app`, every raw route target, and every Router `default`
accepts one of these values:

1. a native PAGI coderef; or
2. an instantiated object with a `to_app` method.

The object form is compiled once per enclosing `to_app` call. Its `to_app`
method must return a native PAGI coderef. Compilation never occurs per request.

A package-name string is not an application value. Callers instantiate the
object explicitly:

```perl
# Accepted
mount('/static', app => PAGI::App::File->app_path('static'));
compose(app => MyApp->new(config => $config));

# Rejected
mount('/static', app => 'PAGI::App::File');
compose(app => 'MyApp');
```

This matches the clarified PAGI application-loading boundary: servers and
composition points run a coderef or an instantiated object that can produce
one. It also prevents `app` from becoming an implicit package loader. Class
names remain valid in middleware positions where the middleware API explicitly
defines that convenience.

The public component boundaries use one shared validator/coercer so Route,
Mount, Router, and Compose cannot drift into different accepted application
shapes.

## 7. Public API at a glance

### 7.1 Route

```perl
route('/apples' => \&list_apples,
    methods     => ['GET'],
    name        => 'list',
    constraints => {},
    middleware  => [],
    desc        => 'List apples',
);

route('/raw', raw => $native_app,
    methods    => ['POST'],
    middleware => [],
);
```

| Parameter | Required | Meaning |
| --- | --- | --- |
| path | yes | Complete route pattern |
| handler or `raw` | exactly one | Context handler or native PAGI application |
| `methods` | no | HTTP methods; defaults to GET |
| `name` | no | One local reverse-route name segment |
| `constraints` | no | Additional path-parameter predicates |
| `middleware` | no | Middleware for this selected leaf only |
| `desc` | no | Human-readable annotation |

`websocket(...)` and `sse(...)` have the same path, target, name,
constraints, middleware, and description concepts, but do not accept HTTP
methods.

### 7.2 Mount

```perl
mount('/api',
    app         => $application,  # XOR routes
    name        => 'api',
    constraints => {},
    middleware  => [],
    desc        => 'API application',
);

mount('/api',
    routes      => \@routes,      # XOR app
    name        => 'api',
    constraints => {},
    middleware  => [],
    desc        => 'API routes',
);
```

| Parameter | Required | Meaning |
| --- | --- | --- |
| path | yes | Prefix pattern to consume |
| `app` or `routes` | exactly one | Child application or shorthand child Router |
| `name` | no | Logical namespace for discoverable child names |
| `constraints` | no | Additional prefix-parameter predicates |
| `middleware` | no | Middleware around this Mount occurrence |
| `desc` | no | Human-readable annotation |

There is no positional target, `router` option, `is_raw` mode, fallback option,
method list, lifespan option, or schema option.

A structural `routes` list contains Route and Mount nodes, never a bare Router
object. A Router is already an application and therefore belongs in
`app => $router`.

### 7.3 Router

```perl
router(
    routes     => \@routes,
    default    => PAGI::Pages->not_found,
    middleware => [],
    desc       => 'Public routes',
);
```

| Parameter | Required | Meaning |
| --- | --- | --- |
| `routes` | no | Ordered Routes and Mounts; defaults to `[]` |
| `default` | no | Native application invoked for NONE |
| `middleware` | no | Middleware around selection, 405, and default |
| `desc` | no | Human-readable Router annotation |

There is no `not_found`, `method_not_allowed`, lifespan, schema, or route-prefix
option. A Router is placement-free.

### 7.4 Compose

```perl
compose(
    app        => $application,   # XOR routes
    middleware => [],
    lifespan   => {
        startup  => \&startup,
        shutdown => \&shutdown,
    },
);

compose(
    routes     => \@routes,       # XOR app
    middleware => [],
    lifespan   => { ... },
);
```

| Parameter | Required | Meaning |
| --- | --- | --- |
| `app` or `routes` | exactly one | Root request target or shorthand root Router |
| `middleware` | no | Application-wide middleware |
| `lifespan` | no | Root startup and shutdown callbacks |

Compose does not accept Router defaults, route descriptions, route
constraints, OpenAPI schemas, or status-specific callbacks.

## 8. Route semantics

A Route is a leaf. It owns:

- compiling and matching its complete path pattern;
- validating path constraints;
- determining whether an HTTP method is accepted;
- constructing the matched `path_params` view;
- publishing selected-leaf metadata; and
- invoking route middleware and its endpoint after selection.

A normal HTTP endpoint receives one Context and returns an immediate or
Future-backed Response. WebSocket and SSE endpoints receive their protocol
Context and own their protocol event flow. A raw endpoint receives
`($scope, $receive, $send)` and owns events directly.

The compiler normalizes possible immediate values with `Future->wrap`; it does
not apply `await` directly to an arbitrary handler return.

GET continues to qualify HEAD. An explicit HEAD route written before a GET
route can provide a cheaper representation:

```perl
router(routes => [
    route('/report' => \&head_report, methods => ['HEAD']),
    route('/report' => \&get_report,  methods => ['GET']),
]);
```

The final HEAD boundary remains outside middleware so middleware calculates
the same representation headers for GET and HEAD before body and file events
are suppressed.

## 9. Mount semantics

### 9.1 One meaning: composition

After a Mount prefix matches, Mount:

1. merges prefix captures into a fresh child `path_params` hash;
2. appends the consumed prefix to `root_path`;
3. rewrites `path` to the unconsumed child path;
4. preserves `raw_path` under the existing PAGI contract;
5. records the selected mount occurrence for route metadata;
6. invokes Mount middleware; and
7. delegates to the child application.

The parent Router does not inspect the child's response status, interpret a
silent completion as a decline, or resume later sibling scanning.

A root Mount consumes no prefix and does not duplicate `/` in `root_path` or
the child path.

### 9.2 `routes` is exact shorthand

This:

```perl
mount('/api', routes => [
    route('/people' => \&people),
]);
```

is semantically equivalent to:

```perl
mount('/api', app => router(routes => [
    route('/people' => \&people),
]));
```

The child Router is a real application boundary. It owns its middleware,
default, 405 calculation, selected metadata, and compilation state. The
`routes` spelling does not create a transparent inline subtree.

The shorthand child uses the stock Router default and no child Router
middleware or description. A caller that needs those Router-level options
constructs it explicitly and supplies it through `app`. Mount-level
middleware and `desc` still describe the placement rather than the child.

### 9.3 Keep the base app separate from the wrapped app

Mount retains the original application value separately from the compiled and
middleware-wrapped coderef. Dispatch calls only the wrapped coderef. Reverse
inspection consults only the original value.

This mirrors the useful part of Starlette's `_base_app` design: middleware may
wrap behavior without hiding the route collection used for URL lookup.

### 9.4 Router inspection without a second dispatch mode

If the original mounted object is a `PAGI::Routing::Router`, Mount snapshots
its immutable routing nodes for reverse inspection. A coderef or any other app
object is opaque only to reverse discovery; it is not a different dispatch
mode.

The compiler never asks the child Router to match on the parent's behalf. It
still calls the Router as an application. The snapshot lets the root resolver
validate and find named descendants while preserving the child compilation
and middleware boundary.

This first version deliberately does not duck-type an arbitrary `routes`
method. In Perl that name is already a common declaration hook—most notably
`PAGI::Endpoint::Router::routes($builder)`—rather than necessarily a zero-arg
inspection accessor. Calling it speculatively would turn an unrelated method
collision into construction-time side effects or failure. Mutable App and
Endpoint Routers use `to_router` explicitly when their child names must be
discoverable. A future third-party route-provider contract requires its own
design and an unambiguous opt-in.

### 9.5 Named and unnamed Mounts

A named Mount adds one logical namespace segment to discoverable child route
names:

```perl
my $child = router(routes => [
    route('/{id}' => \&show, name => 'show'),
]);

my $root = router(routes => [
    mount('/people', app => $child, name => 'person'),
]);

$root->path_for('/person/show', { id => 42 }); # /people/42
```

An unnamed Mount exposes discoverable child names in the current namespace:

```perl
my $root = router(routes => [
    mount('/people', app => $child),
]);

$root->path_for('/show', { id => 42 }); # /people/42
```

Names remain slash-addressed. A Mount name is a namespace segment for child
routes, not a second dotted naming system. It is never inferred from an app's
class or description; omission always means an unnamed Mount.

This first version does not copy Starlette's special
`url_for(mount_name, path=...)` spelling for an opaque Mount. A Mount name by
itself does not claim that its child application handles the prefix root. A
future concrete static-asset requirement may add a separately designed
mount-target reverse operation without weakening exact named-leaf lookup.

### 9.6 Reuse and collisions

The same child Router may be mounted more than once:

```perl
router(routes => [
    mount('/left',  app => $child, name => 'left'),
    mount('/right', app => $child, name => 'right'),
]);
```

Relative Context lookup uses the selected occurrence; absolute lookup can use
`/left/show` or `/right/show`. No parent path or name is written onto the
placement-free child object.

Duplicate canonical addresses and repeated path-parameter names in one
inspectable effective ancestry fail during Router construction:

```perl
mount('/person/{id}', app => router(routes => [
    route('/blog/{id}' => \&blog, name => 'blog'),
]));
# dies: duplicate effective path parameter 'id'
```

The application instead uses distinct names such as `person_id` and
`blog_id`. Parameter remapping is deferred. If a coderef intentionally hides
an external router, the parent cannot validate names or parameter collisions
inside that opaque boundary.

## 10. Router matching and outcomes

### 10.1 Declaration-order scan

For HTTP, a Router scans direct children in declaration order:

1. A Route whose path and method match is FULL and wins immediately.
2. A Route whose path matches but method does not is PARTIAL. Its normalized
   methods join the first-seen `Allow` union, and scanning continues.
3. A matching Mount prefix is FULL and wins immediately because composition
   has selected the child application.
4. If no FULL child exists and at least one PARTIAL exists, the Router emits
   405 with the unioned `Allow` header.
5. If no FULL or PARTIAL child exists, the Router invokes its default app.

Routes are never sorted by path, specificity, name, kind, or mount-prefix
length.

For WebSocket and SSE, the Router likewise scans in declaration order for the
first Mount prefix or same-protocol Route match. There is no method PARTIAL for
those protocols. If nothing matches, the Router invokes the same configured
default application or its stock protocol-specific default.

### 10.2 Default application

`default` is a native PAGI application, not a Context-handler callback. It is
invoked only after a complete direct Router search finds NONE. The stock
default uses `PAGI::Pages` to produce the normal negotiated HTTP 404 and the
existing safe protocol-specific miss for WebSocket and SSE.

```perl
my $api = router(
    routes => \@api_routes,
    default => PAGI::Pages->not_found(
        detail => 'No API route matched this request path.',
    ),
);
```

A custom default must support each scope type that can reach that Router. A
Pages endpoint is HTTP-only; use a small multiprotocol application when the
same Router also needs custom WebSocket or SSE miss behavior.

Router middleware surrounds both the default and normal selections, so it can
add subsystem headers, logging, or presentation policy to a custom default.

### 10.3 Method Not Allowed

PARTIAL is a routing result, not a default-app call. The Router creates a stock
`PAGI::Pages->method_not_allowed` response with the deterministic unioned
`Allow` value. It reasserts `Allow` if necessary before the 405 is sent.

There is no `method_not_allowed` Router option in this design. Applications
that need a different representation apply ordinary Router or Mount
middleware that transforms the 405 response. This keeps response
customization in middleware without retaining a trace interpreter or adding a
second callback API.

### 10.4 Nested ownership

```perl
my $child = router(routes => [
    route('/item' => \&item, methods => ['GET']),
]);

my $root = router(routes => [
    mount('/api', app => $child),
    route('/api/item' => \&later, methods => ['PUT']),
]);
```

`PUT /api/item` selects the Mount before the later parent Route. The child
emits its own 405 with `Allow: GET, HEAD`. The parent does not resume and does
not add PUT. `GET /api/missing` receives the child's default 404, not the
parent's default.

An explicit 404 or 405 produced by a selected endpoint or mounted application
passes through untouched except for normal surrounding middleware.

### 10.5 Silent completion is not decline

Once a Route or Mount selects an app, normal completion without a complete
response is an application contract failure. Compose's response guard turns
that into a safe 500. There is no scope flag, exception sentinel, or hidden
`$next` operation that resumes routing.

## 11. Middleware ownership and order

Every middleware list keeps the existing four accepted forms:

- a nonempty middleware class-name string;
- a synchronous factory coderef receiving the inner app;
- a configured object with `wrap($inner_app)`; or
- an explicit `PAGI::Routing::Middleware` description.

The first listed entry remains outermost. Middleware is always native
app-to-app PAGI middleware. It never receives a response-valued `$next`.

For one selected leaf, the effective request path is:

```text
final HEAD wire boundary
  Compose safety layers
    Compose middleware
      root Router middleware
        Mount middleware
          child Router middleware
            Route middleware
              endpoint
```

The child Router default and 405 pass through child Router middleware, Mount
middleware, root Router middleware, and Compose middleware. They do not pass
through Route middleware because no Route was selected.

Mount middleware sees every protocol delegated through that Mount. It is not
silently HTTP-only; middleware that only handles HTTP must explicitly pass
other scope types through.

## 12. Reverse routing and request metadata

### 12.1 Recursive discovery, not transparent dispatch

The root Router builds one immutable reverse index by walking direct Routes
and mounted `PAGI::Routing::Router` base applications. This is analogous to
Starlette recursively asking a Mount's base application's routes for a named
target, narrowed to an explicit first-party Router type to avoid Perl method
collisions.

That walk is construction-time inspection only. The dispatcher keeps the
Mount and child Router as separate compiled applications with separate
middleware state.

### 12.2 Existing URL surface remains

The following behavior remains:

```perl
$router->path_for('/person/blog/show',
    { person_id => 7, blog_id => 9 },
    { view => 'full' },
    'comments',
);

$c->url_for('../index',
    {},
    { page => 2 },
    'recent',
);
```

- `path_for` returns an application-relative path plus optional query and
  fragment.
- `url_for` adds request scheme and validated authority.
- leading `/` means an absolute logical address;
- otherwise resolution starts from the selected Router namespace;
- `.` and `..` normalize exactly;
- relative Context lookup may inherit required captures from the selected
  ancestry;
- explicit params override inherited captures;
- constraints validate reverse-rendered values without coercion; and
- malformed, unknown, namespace-only, ambiguous, missing, or extra values
  croak rather than guessing.

### 12.3 Root resolver with selected placement

The current `pagi.routing` versioned frame concept remains the first-party
Context integration seam, but its purpose is narrowed to reverse lookup and
selected-route metadata. A separately compiled child Router mounted directly
as a Router object retains the root resolver and enters with the logical
namespace, prefix captures, `root_path`, and Mount chain for that selected
occurrence. It does not replace root lookup with a child-only resolver.

This is how a child handler can generate both:

```perl
$c->path_for('show');          # relative to this mounted occurrence
$c->path_for('/home');         # absolute from the application root
```

An opaque application that contains its own separately compiled Router may
install its own resolver and support local lookup, but the enclosing Router
cannot promise cross-boundary names it could not inspect.

### 12.4 Publish only selected metadata

The compiler continues to publish request-local metadata needed by logging,
metrics, diagnostics, and Context reverse routing:

- root resolver identity;
- selected Mount chain;
- current logical namespace;
- immutable capture snapshot;
- effective route pattern;
- canonical selected leaf name, when named;
- route kind and description; and
- root-path boundary.

Inline Router entry replaces leaf match information only when a leaf is
selected. Middleware may inspect the selected result after awaiting downstream.
No mutable metadata container is shared between concurrent requests.

### 12.5 Remove fallback trace machinery

`pagi.routing.trace`, `PAGI::Routing::Trace`, Recorder, Snapshot, candidate
attempt records, checkpoints, opaque trace shielding, and trace-consuming
routing fallback middleware are removed.

The selected metadata above is not a decline protocol. Third-party apps do not
write to it to request parent routing, and Compose does not interpret it as an
HTTP status.

## 13. Compose after the change

Compose keeps its narrow root role:

- exactly one of `app` or `routes`;
- application-wide middleware;
- startup and shutdown callbacks;
- the final HEAD boundary;
- application exception handling; and
- the response-completion guard.

In `routes` mode it constructs an ordinary root Router. That Router owns 404
and 405 exactly as a Router passed through `app` does.

Compose removes automatic `PAGI::Middleware::Routing::NotFound` and
`PAGI::Middleware::Routing::MethodNotAllowed`. It does not inspect routing
frames. Its ErrorHandler remains the final exception failsafe, and its response
guard still diagnoses a selected native app that emits no complete response.

Compose's `lifespan` remains root-only. A mounted application does not receive
the server's root lifespan exchange, and mounting another Compose object does
not cause its startup or shutdown callbacks to run. Reusable components that
need parent-managed resources consume `scope->{state}` or an explicit
application contract; they do not own nested lifespan implicitly.

Because PAGI servers accept instantiated `to_app` objects, an app file may end
with the Compose description itself:

```perl
compose(
    routes   => \@routes,
    lifespan => { startup => \&startup, shutdown => \&shutdown },
);
```

Programmatic callers may still call `to_app` explicitly when they need the
native coderef.

## 14. Class frontends

### 14.1 `PAGI::App::Router`

The mutable builder continues to materialize the same immutable Router model.
Its root configuration accepts `default`, `middleware`, and `desc`.

`group` is removed. `mount` uses the same two concepts as declarative Mount:

```perl
my $r = PAGI::App::Router->new(
    default => PAGI::Pages->not_found,
    desc    => 'Public application',
);

$r->mount('/api',
    routes => sub ($api) {
        $api->get('/people' => \&people)->name('people');
        $api->post('/people' => \&create)->name('create');
    },
)->name('api')->desc('People API');

$r->mount('/static',
    app => PAGI::App::File->app_path('static'),
)->desc('Static files');
```

For the mutable frontend, `routes` accepts either an arrayref of immutable
routing nodes or a synchronous builder callback. The callback receives a fresh
child App Router, returns no runtime value, and is invoked only while building
the immutable snapshot. It is Perlish declaration convenience, not another
routing abstraction.

The builder also exposes `default($app)` for method-oriented construction. A
Router default may be configured once, either in the constructor or through
that method; a second configuration croaks rather than silently overriding
policy.

Positional application mounts and `router =>` are removed:

```perl
# Before
$r->mount('/legacy' => $legacy);
$r->mount('/people', router => $people)->name('people');
$r->group('/admin' => sub ($admin) { ... })->name('admin');

# After
$r->mount('/legacy', app => $legacy);
$r->mount('/people', app => $people)->name('people');
$r->mount('/admin', routes => sub ($admin) { ... })->name('admin');
```

If `$people` is mutable, the caller takes an explicit snapshot before placing
it where immutable route inspection matters:

```perl
$r->mount('/people', app => $people->to_router)->name('people');
```

This keeps Mount's `app` contract honest: it receives an application object,
not a special mutable-router category.

### 14.2 `PAGI::Endpoint::Router`

The Endpoint facade follows the same declarations. Local method names remain
valid only in handler positions. Native app and middleware methods still use
the explicit `app_as` and `middleware_as` helpers.

```perl
sub routes ($self, $r) {
    $r->default($self->app_as('not_found'));

    $r->get('/' => 'index')->name('index');

    $r->mount('/admin', routes => sub ($admin) {
        $admin->get('/users' => 'users')->name('users');
    })->name('admin');

    $r->mount('/legacy', app => $self->app_as('legacy_app'));
}
```

Nested Endpoint instances that need discoverable child names are materialized
to an immutable Router and supplied through `app`:

```perl
$r->mount('/people', app => $people_endpoint->to_router)->name('people');
```

There is no Endpoint-only group, Router target mode, value-flow middleware, or
fallback protocol.

## 15. Complete declarative example

The Starlette apples comparison becomes:

```perl
#!/usr/bin/env perl
use v5.40;

use Future::AsyncAwait;
use List::Util qw(max);
use Types::Standard qw(Int);

use PAGI::Compose qw(compose);
use PAGI::Pages;
use PAGI::Routing qw(route mount);

my %apples_db = (
    1 => { id => 1, name => 'Gala',       color => 'Red/Yellow' },
    2 => { id => 2, name => 'Honeycrisp', color => 'Rosy Red' },
);

async sub list_apples ($c) {
    my @ids = sort { $a <=> $b } keys %apples_db;
    return $c->json([map { $apples_db{$_} } @ids]);
}

async sub read_apple ($c) {
    my $id = $c->path_param('apple_id');
    return $c->json($apples_db{$id}) if $apples_db{$id};
    return $c->json({ error => 'Apple not found' }, status => 404);
}

async sub create_apple ($c) {
    my $data = await $c->request->json;
    my $id = max(0, keys %apples_db) + 1;
    return $c->json($apples_db{$id} = { id => $id, %$data }, status => 201);
}

async sub update_apple ($c) {
    my $id = $c->path_param('apple_id');
    return $c->json({ error => 'Apple not found' }, status => 404)
        unless $apples_db{$id};
    my $data = await $c->request->json;
    return $c->json($apples_db{$id} = { %{$apples_db{$id}}, %$data });
}

async sub delete_apple ($c) {
    my $id = $c->path_param('apple_id');
    return $c->json({ error => 'Apple not found' }, status => 404)
        unless $apples_db{$id};
    return $c->json({ success => \1, deleted => delete $apples_db{$id} });
}

compose(
    routes => [
        route('/' => PAGI::Pages->welcome,
            name => 'home', desc => 'PAGI welcome page'),

        mount('/apples',
            name => 'apples',
            desc => 'Apples API',
            routes => [
                route('/' => \&list_apples,
                    methods => ['GET'], name => 'list'),
                route('/' => \&create_apple,
                    methods => ['POST'], name => 'create'),
                route('/{apple_id:&Int}' => \&read_apple,
                    methods => ['GET'], name => 'read'),
                route('/{apple_id:&Int}' => \&update_apple,
                    methods => ['PUT'], name => 'update'),
                route('/{apple_id:&Int}' => \&delete_apple,
                    methods => ['DELETE'], name => 'delete'),
            ],
        ),
    ],
);
```

Compared with the current PAGI example:

- there is no separate `$apples = router(...)` solely to use `router =>`;
- `mount(routes => ...)` visibly means “construct and mount a child Router”;
- the child automatically owns `/apples` 404 and 405 outcomes;
- Compose is no longer involved in interpreting routing evidence; and
- the app file returns a Compose object directly to a conforming PAGI server.

A custom application-wide 404 is an explicit root Router default, not a final
wildcard Route:

```perl
compose(app => router(
    routes  => \@routes,
    default => PAGI::Pages->not_found(
        detail => 'The application has no route for this path.',
    ),
));
```

A wildcard remains available when the author truly wants a Route that owns a
path family. It is not documented as the ordinary fallback because it is a
FULL/PARTIAL candidate and can intentionally affect 405 selection.

## 16. Additional examples

### 16.1 Separate mounted Router with local default

```perl
my $admin = router(
    routes => [
        route('/users' => \&users, name => 'users'),
    ],
    default => PAGI::Pages->not_found(
        detail => 'No admin route matched this request path.',
    ),
);

my $root = router(routes => [
    mount('/admin', app => $admin,
        name => 'admin', middleware => [\&require_admin]),
]);
```

`/admin/missing` uses the admin default and passes through the Mount's
authorization middleware. A missing path outside `/admin` uses the root
default.

### 16.2 Static application

```perl
mount('/static',
    app  => PAGI::App::File->app_path('static'),
    desc => 'Application static files',
);
```

Mount is correct because the file app owns a prefix and the remaining child
path. A raw Route would instead own one exact path and participate in methods.

### 16.3 Raw exact endpoint

```perl
route('/metrics', raw => $metrics_app,
    methods    => ['GET'],
    middleware => [\&internal_only],
);
```

This matches only `/metrics`, contributes GET and HEAD to `Allow`, does not
rewrite `path` or `root_path`, and records leaf metadata. It is not
interchangeable with `mount('/metrics', app => $metrics_app)`.

### 16.4 Middleware at distinct boundaries

```perl
compose(
    app => router(
        middleware => [\&router_metrics],
        routes => [
            mount('/api',
                app        => $api,
                middleware => [\&tenant_scope],
            ),
        ],
    ),
    middleware => [\&request_id, \&access_log],
);
```

Compose middleware sees the whole application. Router middleware sees every
Router outcome. Mount middleware sees only the selected `/api` occurrence,
including its child's default and 405. Route middleware sees only one selected
leaf.

## 17. Removed public surface

The implementation and migration guide remove or replace:

| Removed | Replacement |
| --- | --- |
| `mount('/x' => $app)` | `mount('/x', app => $app)` |
| `mount('/x', router => $router)` | `mount('/x', app => $router)` |
| `group('/x' => sub { ... })` | `mount('/x', routes => sub { ... })` in mutable frontends |
| transparent inline Mount dispatch | a real child Router app created by `routes` |
| `Mount->router` | `Mount->app` / base application accessor |
| `Mount->target` for positional apps | `Mount->app` |
| `Mount->is_raw` | no mode flag; every Mount composes an app |
| Router HTTP silent decline | Router default or built-in 405 |
| `PAGI::Routing::Trace` family | selected `pagi.routing` metadata only |
| `PAGI::Middleware::Routing::NotFound` | Router `default` |
| `PAGI::Middleware::Routing::MethodNotAllowed` | Router's compliant 405 plus ordinary response middleware |
| Compose automatic routing fallback middleware | root Router outcomes |
| package-name values in `app` positions | instantiate the object explicitly |

References throughout `lib/`, tests, examples, README, Cookbook, Tutorial,
Changes, and `UPGRADING.md` must be updated. Historical design documents remain
historical and are not rewritten.

## 18. OpenAPI and schema support

No `schema` option is added to Compose, Router, Mount, or Route in this work.
The current Starlette application constructor does not accept `schema`, and
the earlier Starlette `SchemaGenerator` example that prompted this question
exposes its schema through an ordinary Route. Schema generation is therefore
not a `Starlette(...)` constructor concern to copy here.

PAGI will follow that separation when it has a concrete OpenAPI consumer. This
design preserves the necessary future seam:

- immutable Routes and Mounts remain inspectable;
- mounted `PAGI::Routing::Router` objects expose their routes;
- names, methods, patterns, constraints, and descriptions remain available;
  and
- a future schema generator can be mounted or routed like any other app.

`include_in_schema`, arbitrary route metadata, schema registries, and document
generation remain deferred. No placeholder option is reserved merely to
anticipate them.

## 19. Adversarial review findings

The implementation must resist recreating the complexity this design removes.

### 19.1 Do not infer dispatch mode from app type

A mounted `PAGI::Routing::Router` is still called as an application. It is not
inlined because the compiler recognizes its class. Route visibility affects
reverse inspection only.

### 19.2 Do not let parent fallback inherit child misses

The parent has already selected the Mount. Child 404 and 405 responses flow
outward normally. Child silence is an error. There is no resume token.

### 19.3 Do not let middleware hide route inspection

Mount must retain the original app separately. Inspecting the post-middleware
coderef would make named URLs change when middleware is added.

### 19.4 Do not create a global mutable URL map

Reverse indexes belong to an immutable root Router compilation/description.
The same child may appear in multiple roots or placements without sharing
parent state. Request placement is request-local.

### 19.5 Do not compile per request

Application coercion, child Router construction, middleware factories,
provider route snapshots, collision checks, and reverse indexes are all
construction or `to_app` work. One compiled app supports concurrent requests
without shared request metadata.

### 19.6 Do not call arbitrary `routes` methods

Only a mounted `PAGI::Routing::Router` contributes child declarations in this
version. The resolver never guesses names from an arbitrary app, introspects
closures, calls an Endpoint declaration hook, or calls `path_for` as a
discovery protocol.

### 19.7 Do not make default an exception handler

Router default handles NONE only. Handler exceptions continue outward to
ErrorHandler. A selected handler-returned 404 is not replaced. PARTIAL remains
the Router's 405 path.

### 19.8 Do not add schema placeholders

Route inspection is sufficient future-proofing. An unconsumed `schema` field
would create surface without semantics and would likely be wrong once a real
OpenAPI design confronts mounted apps and custom constraints.

## 20. Testing requirements

The eventual implementation plan must cover at least:

1. constructor validation for the exact Route, Mount, Router, and Compose
   option sets;
2. `app` acceptance of coderefs and instantiated `to_app` objects, and
   rejection of package strings;
3. exact declaration-order FULL/PARTIAL/Mount selection;
4. deterministic 405 `Allow` union, GET/HEAD behavior, and custom HEAD
   precedence;
5. default invocation only for NONE across HTTP, WebSocket, and SSE;
6. child Router ownership of nested 404 and 405 without parent resumption;
7. selected app silence becoming a guarded 500 rather than fallback;
8. `routes` shorthand behaving as a real mounted Router application;
9. middleware visibility and onion order for normal leaves, child default,
   child 405, and exceptions;
10. named and unnamed mounted Router reverse lookup through base-app
    inspection;
11. reuse of one child Router at multiple named placements;
12. duplicate name, duplicate effective parameter, and Router-cycle failures;
13. request-local metadata isolation under concurrent in-flight requests;
14. absolute and relative Context `path_for`/`url_for`, capture inheritance,
    query, and fragment behavior from a separately compiled child Router;
15. opaque mounted apps remaining dispatchable but undiscoverable;
16. App Router and Endpoint Router parity, including removal of `group` and
    use of `mount(routes => sub { ... })`;
17. Compose lifespan, ErrorHandler, ResponseGuard, and outer HEAD behavior
    after routing fallback layers are removed;
18. removal of Trace and routing fallback modules from load tests and the
    distribution;
19. migrated apples, large-application, Endpoint Router, static-file, and
    Pages examples; and
20. a complete `UPGRADING.md` section with every before/after form in section
    17.

The tests must include two requests concurrently in one compiled application
and the same child Router mounted twice. These are the cases most likely to
expose accidental placement mutation or shared metadata.

## 21. Deferred work and non-goals

This work does not add:

- OpenAPI generation, `schema`, or `include_in_schema`;
- automatic OPTIONS or slash redirects;
- path-parameter coercion;
- async constraints;
- parameter remapping across an external router collision;
- a universal third-party route-provider protocol;
- Starlette's special reverse operation for an opaque Mount plus arbitrary
  child path;
- nested lifespan execution;
- route decorators or package scanning;
- package-name app loading;
- value-flow `$next` middleware;
- a general HTTP exception hierarchy;
- per-route 404 or 405 callbacks; or
- compatibility modes for removed APIs.

`PAGI::App::URLMap`, Cascade, and other generic application coordinators remain
separate composition tools. They do not become Router decline mechanisms.

## 22. Documentation outcome

The public documentation should lead with one rule per abstraction:

> Route matches a complete URL leaf. Mount composes an application under a
> prefix. Router selects and owns routing outcomes. Middleware wraps behavior.
> Compose owns the application root and lifespan.

The docs must include the complete apples application, a mutable App Router
version, an Endpoint Router version, a separately mounted Router, static files,
custom defaults at root and child boundaries, middleware at every level,
`route(raw => ...)` versus `mount(app => ...)`, named and unnamed reverse
lookup, and nested 404/405 ownership.

The comparison with Starlette must identify deliberate differences rather
than imply API identity:

- PAGI has explicit Context handlers versus raw three-channel apps;
- PAGI constraints validate without coercion;
- PAGI retains slash logical names and relative lookup;
- PAGI supports SSE as a first-class scope;
- PAGI middleware is pure PAGI app-to-app wrapping;
- PAGI Compose separates root lifespan from Router; and
- schema generation remains deferred until a real consumer is designed.

## 23. Acceptance criteria

The redesign is complete when:

- every public example makes the Route/Mount distinction obvious from syntax;
- Mount has one dispatch mode and exactly one of `app` or `routes`;
- `group`, `router =>`, positional Mount apps, and `is_raw` are gone;
- nested Routers render their own NONE and PARTIAL outcomes;
- Compose contains no routing trace or routing fallback interpretation;
- selected metadata and cross-mount reverse routing still work from Context;
- the functional, mutable, and Endpoint frontends materialize identical
  semantics;
- the apples example is shorter and closer in shape to its Starlette source;
- the upgrade guide covers every breaking spelling and behavior; and
- focused, integration, concurrency, and full distribution tests pass without
  retaining compatibility branches.
