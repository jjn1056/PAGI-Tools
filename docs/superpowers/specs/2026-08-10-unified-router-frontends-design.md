# Unified Router Frontends

**Date:** 2026-08-10

**Status:** Approved design; awaiting written-spec review

**Scope:** Rebuild `PAGI::App::Router` and `PAGI::Endpoint::Router` as mutable
and class-oriented frontends over the immutable `PAGI::Routing` model and its
single compiler

## 1. Decision

PAGI-Tools will have one routing model and one matching engine with three
public ways to describe an application:

1. `PAGI::Routing` is the immutable functional/declarative frontend.
2. `PAGI::App::Router` is a mutable imperative builder for that same model.
3. `PAGI::Endpoint::Router` is a class- and instance-method frontend over the
   mutable builder.

`PAGI::App::Router` will no longer compile or dispatch its own route table.
It records declarations and materializes a fresh immutable
`PAGI::Routing::Router` snapshot through `to_router`. Its `to_app` is
equivalent to:

```perl
sub to_app ($self) {
    return $self->to_router->to_app;
}
```

`PAGI::Endpoint::Router` will no longer add another matching or response-flow
layer. It binds local method names to ordinary Context handlers, builds the
same mutable declarations, and materializes through the same snapshot and
compiler boundary.

This is a breaking replacement of the two existing class-router contracts.
Neither API has been released in the form being designed here, and the small
number of existing users are better served by one direct migration than by a
compatibility layer that preserves a second matcher, dotted route names,
value-flow route middleware, or native-app-by-default handlers.

The root-level `UPGRADING.md` described in this specification is part of the
feature, not follow-up documentation.

## 2. Superseded designs

Where this specification conflicts with the following documents, this one
governs:

- the 2026-08-03 declarative-routing design's claim that
  `PAGI::App::Router` remains a separate matcher;
- the 2026-08-03 design's claim that `PAGI::Endpoint::Router` retains
  response-valued `$next` route middleware;
- the 2026-08-06 bare-middleware-shorthand design's restriction of bare
  middleware entries to coderefs and descriptors;
- the 2026-08-08 Router-mount design's public `namespace` spelling; and
- the deferred 2026-08-06 `PAGI::App` route-component base design where it
  assumes the older distinction among the routers.

The approved matching, HEAD, path constraint, reverse-routing, composed
Router-mount, metadata-isolation, and inline constraint-provider contracts of
`PAGI::Routing` otherwise remain in force. The deferred `PAGI::App` base must
be reconsidered against this implementation before anyone plans it.

The inline constraint-provider work is a prerequisite. Delayed mutable
declarations must retain their declaration package so an inline provider such
as `&Int` resolves in the user's package when the immutable Pattern is later
constructed.

## 3. Goals

- Have one implementation of path matching, FULL/PARTIAL decisions, mounts,
  constraints, metadata, HEAD handling, generated outcomes, and reverse
  routing.
- Preserve the concise mutable verb-based style of `PAGI::App::Router`.
- Make `$c` the safe and ordinary handler contract in every frontend.
- Make native three-channel PAGI applications explicit through `raw` or an
  opaque mount.
- Preserve declarations in exactly the order the programmer wrote them.
- Retain a useful Perlish class-based Endpoint style, including nested
  Endpoint objects and HTTP, WebSocket, and SSE method handlers.
- Replace Endpoint's response-valued `$next` layer with real PAGI middleware.
- Give every middleware position the same four accepted entry forms.
- Give App and Endpoint users the same slash-addressed, constraint-aware,
  percent-encoding reverse routing as declarative users.
- Provide fresh immutable snapshots with explicit reuse and cycle behavior.
- Publish a concrete migration guide with tested before/after examples.

## 4. Non-goals and deferred work

This work will not:

- redesign `not_found`, `method_not_allowed`, or cooperative 404/405 bubbling;
- add handled HTTP exception classes or status-specific response shortcuts;
- decide whether reverse-routing methods ultimately belong on
  `PAGI::Context`;
- define a universal route-discovery contract for third-party routers;
- change `PAGI::Endpoint::HTTP`, `PAGI::Endpoint::WebSocket`, or
  `PAGI::Endpoint::SSE`;
- implement the deferred `PAGI::App` base class;
- add package-name loading, controller discovery, string evaluation, or
  signature inspection;
- add a generalized value-flow `$next` tier under a new name;
- add mutable behavior to `PAGI::Routing` objects;
- cache a builder's latest immutable snapshot;
- add a `&{}` overload to any routing description or builder; or
- preserve behavior merely because the old class routers shipped it.

The existing first-party Context reverse-routing integration continues to work
because all three frontends compile through `PAGI::Routing`. Whether Context
should expose `path_for` and `url_for` when a third-party router may not support
them remains a separate design question.

## 5. Architectural boundary

The dependency direction is:

```text
PAGI::Endpoint::Router
          |
          v
PAGI::App::Router
          |
          v
PAGI::Routing descriptions
          |
          v
PAGI::Routing::Compiler + PAGI::Routing::Resolver
```

The arrows mean "describes through" or "materializes through," not runtime
delegation to another matcher. A compiled application has only the immutable
routing description and shared compiler graph. It contains no mutable App
builder and no Endpoint route builder.

The public immutable descriptions remain the neutral model. This design does
not add a second private route IR. Adding one would recreate the representation
drift this consolidation is intended to remove.

## 6. `PAGI::App::Router` lifecycle

### 6.1 Mutable declaration builder

`PAGI::App::Router->new` creates an empty mutable builder. Its declaration
methods append records and return the builder for chaining. A record contains
only the information needed to construct an equivalent public
`PAGI::Routing::Route` or `PAGI::Routing::Mount` later.

The constructor accepts the same top-level policy fields as an immutable
Router:

```perl
my $r = PAGI::App::Router->new(
    desc               => 'Public application routes',
    middleware         => [ ... ],
    not_found          => \&not_found,
    method_not_allowed => \&method_not_allowed,
);
```

No declaration performs protocol I/O or compiles middleware. Basic argument
shape errors fail at the declaration call. Errors that require constructing
the immutable graph, including composed name collisions, Pattern construction,
inline provider resolution, and effective path-parameter collisions, fail from
`to_router`/`to_app`.

### 6.2 Snapshot boundary

`to_router` returns a fresh immutable `PAGI::Routing::Router` every time:

```perl
my $first = $builder->to_router;

$builder->get('/later' => \&later);

my $second = $builder->to_router;
```

`$first` never gains `/later`; `$second` includes it. The two snapshots and
their nested immutable descriptions are independent objects. A later builder
mutation cannot affect either snapshot or an application compiled from one.

There is no implicit snapshot cache. Consequently:

- `to_router` repeats materialization and validation;
- `to_app` produces a fresh middleware graph on every call;
- reverse-routing or inspection code that needs stable object identity should
  retain one returned Router; and
- applications should call `to_app` once per intended application instance,
  not once per request.

Explicitly reused middleware objects and closures retain their ordinary
caller-chosen state sharing. Fresh compilation does not clone caller-owned
objects.

### 6.3 Builder inspection

The immutable snapshot is the canonical inspection surface:

```perl
my $routing = $builder->to_router;

my $nodes = $routing->routes;
my $index = $routing->named_routes;
my $node  = $routing->route_named('/person/show');
my $path  = $routing->path_for('/person/show', { person_id => 42 });
```

Convenience `named_routes`, `route_named`, and `path_for` methods on the
builder may delegate through a fresh snapshot. Their documentation must warn
that repeated calls rematerialize and that object identity is stable only on a
retained Router. The old `uri_for` method is removed; it is not an alias.

## 7. App builder declaration API

### 7.1 HTTP methods

The verb methods create normal Context-handler routes:

```perl
$r->get('/people' => \&index);
$r->post('/people' => \&create);
$r->put('/people/{person_id}' => \&replace);
$r->patch('/people/{person_id}' => \&update);
$r->delete('/people/{person_id}' => \&remove);
$r->head('/people/{person_id}' => \&head_person);
$r->options('/people' => \&options);
$r->any('/health' => \&health);
```

They materialize as `route(...)` nodes with the corresponding normalized
methods. `any` uses `methods => '*'`.

The generic method puts the path first and methods in an explicit option:

```perl
$r->route('/rpc' => \&rpc, methods => ['RPC']);
$r->route('/resource' => \&resource,
    methods => ['GET', 'POST']);
```

The old `route($method, $path, ...)` ordering is removed.

Immediate `PAGI::Response` values and Future-backed responses are both valid.
The shared compiler continues to normalize completion with
`Future->wrap(...)`; no frontend calls `await` directly on an arbitrary return
value.

### 7.2 Explicit raw HTTP routes

A native three-channel application is requested explicitly:

```perl
$r->get('/raw', raw => $raw_pagi_app);
$r->route('/raw-rpc', raw => $raw_rpc, methods => ['RPC']);
```

`raw` is preferred over `pure`: it says that the target receives the native
PAGI channels without implying that ordinary Context handlers are impure.

The distinction between a raw route and a mount must be prominent in the POD:

- a raw route is an exact route match, participates in its declared HTTP
  methods and 405 calculation, records leaf metadata, and does not rewrite
  `path` or `root_path`;
- an opaque mount is a prefix owner, rewrites the child scope's `path` and
  `root_path`, is not method-limited by the parent, and may serve HTTP,
  WebSocket, SSE, or extension scopes.

They are not interchangeable merely because both ultimately run a native PAGI
coderef.

### 7.3 WebSocket and SSE

```perl
$r->websocket('/chat/{room}' => \&chat);
$r->sse('/events' => \&events);
```

These materialize as the same public `websocket(...)` and `sse(...)` nodes used
by the functional frontend. Normal handlers receive the appropriate Context
subclass and use its imperative protocol helpers. Their immediate or
Future-backed completion is awaited and the resolved value is inert.

Explicit raw forms remain available:

```perl
$r->websocket('/raw-ws', raw => $raw_ws_app);
$r->sse('/raw-events', raw => $raw_sse_app);
```

Route middleware is supported uniformly for HTTP, WebSocket, and SSE because
it is native app-to-app middleware outside the Context adapter.

### 7.4 Positional route middleware

The concise existing route-level shape is retained, but its entries now mean
real PAGI middleware:

```perl
$r->get('/admin' => [
    'RequestId',
    \&with_logging,
    $configured_auth,
    middleware('Session', cookie_name => 'sid'),
] => \&admin);
```

The same optional array position is accepted for every App declaration that
has a local middleware layer, including raw routes, WebSocket, SSE, groups,
and mounts. The parser accepts these conceptual forms:

```text
($path => $handler)
($path => \@middleware => $handler)
($path, raw => $app)
($path => \@middleware, raw => $app)
```

The generic `route` form additionally requires `methods`. This specification
does not retain Endpoint's old interpretation of a string in this array as a
response-valued Endpoint method.

### 7.5 Annotations and last-declaration modifiers

One `name` vocabulary is used throughout. The mutable builder retains
chainable modifiers for the most recently declared addressable node:

```perl
$r->get('/{person_id}' => \&show)
    ->name('show')
    ->desc('Render one person')
    ->constraints(person_id => Int);
```

`name` applies to the last route, group, or routing-aware mount. It is one
local logical segment. It does not accept a dotted or slash-composed address.
The old `as` method is removed.

`desc` records human-readable metadata and changes no dispatch behavior.
`constraints` applies to the last pattern-bearing declaration and uses the
same constraint forms and normalization as the functional API.

The shared automatic-HEAD convention remains declaration-ordered. A custom
HEAD handler must be declared before its GET route:

```perl
$r->head('/expensive' => \&cheap_head);
$r->get('/expensive' => \&expensive_get);
```

For HEAD, the explicit route is the first FULL match. For GET, that route is a
PARTIAL and scanning continues to the GET route. Reversing the declarations
lets the GET route's automatic HEAD support win. App Router does not add an
`auto_head` option or associate the two declarations specially.

Calling `name`, `desc`, or `constraints` without a compatible preceding
declaration is a synchronous error that names both the modifier and the
required declaration kind.

## 8. Groups and mounts

### 8.1 Groups are structural children

```perl
$r->group('/api' => sub ($api) {
    $api->get('/people' => \&people)->name('people');
    $api->get('/health' => \&health)->name('health');
})->name('api');
```

The callback receives a fresh child `PAGI::App::Router`, not the parent. The
group occupies one position in the parent's declaration list and materializes
as a real inline structural subtree. It is not flattened into the parent and
is not an independently configured Router boundary.

Consequences:

- unnamed groups contribute only their path prefix;
- a named group contributes one logical address segment;
- group middleware wraps the subtree once rather than being copied onto every
  leaf;
- child declaration order is preserved within the group; and
- the group as a whole keeps its position relative to surrounding parent
  nodes.

The optional middleware spelling is:

```perl
$r->group('/api' => [\&audit] => sub ($api) {
    ...
});
```

The callback is synchronous configuration work. Its return value is ignored.
Package-name callbacks and package auto-loading are removed.

### 8.2 Opaque mounts

```perl
$r->mount('/static' => PAGI::App::File->new(root => $root));
$r->mount('/legacy' => $native_app);
$r->mount('/legacy' => [\&audit] => $native_app);
```

Opaque targets use the ordinary `PAGI::Utils::to_app` application contract.
The builder does not inspect them for routes or names. A class-name string is
not accepted as a package-loading shortcut; applications load packages and
construct targets explicitly.

An opaque mount cannot be named because its inner routing structure is not
known. It may still have `desc`, constraints on its prefix, and middleware.

### 8.3 Routing-aware mounts

```perl
$r->mount('/person', router => $people)->name('person');
```

Within the mutable frontends, `router =>` accepts an already constructed:

- immutable `PAGI::Routing::Router`;
- mutable `PAGI::App::Router`; or
- `PAGI::Endpoint::Router` instance.

The last two are materialized recursively in the same root snapshot operation.
The resulting public node is the existing routing-aware
`PAGI::Routing::Mount` containing an immutable Router.

The functional constructor remains stricter:

```perl
mount('/person', router => $immutable_router, name => 'person');
```

It accepts an immutable `PAGI::Routing::Router`, not either mutable frontend.
This keeps immutable constructors free of hidden mutable compilation.

The public mount option formerly named `namespace` becomes `name`. There is no
compatibility alias. `logical_namespace` may remain an internal/computed term,
but `namespace` is not a public declaration accessor. At declaration, `name`
means one local segment; in matched metadata the derived route name is an
absolute slash address.

The routing-aware mount remains a true Router boundary with the ownership,
middleware, generated-outcome, root-path, and reverse-routing rules already
specified by the Router-mount design.

## 9. Declaration order is an invariant

### 9.1 Required behavior

Every frontend preserves the order in which nodes were declared. The builder
must use one ordered declaration list; it must not partition that list by
protocol or kind, sort it alphabetically, rank static routes above dynamic
routes, or reorder mounts by prefix length.

The immutable Router's direct `routes` accessor must return nodes in that exact
order. Recursive materialization must preserve parent order and each child
order independently.

Examples:

```perl
$r->get('/{slug}' => \&dynamic);
$r->get('/about'  => \&about);
```

`GET /about` reaches `dynamic`. Reversing the declarations reaches `about`.

```perl
$r->mount('/users' => $users_app);
$r->get('/users/special' => \&special);
```

The mount owns `/users/special` because it was encountered first. Reversing
the declarations lets the route win.

```perl
$r->mount('/'    => $general);
$r->mount('/api' => $api);
```

The root mount wins. A programmer who wants longest-prefix behavior writes the
more specific mount first.

### 9.2 FULL/PARTIAL qualification

Declaration order does not turn an HTTP path-only PARTIAL result into a winner
over a later FULL method match. The shared matching algorithm remains:

- scan applicable nodes in declaration order;
- dispatch the first FULL match;
- retain allowed methods from every PARTIAL path match;
- if no FULL exists but one or more PARTIAL matches exist, generate the 405
  with the deterministic first-seen Allow union; and
- otherwise generate the owning Router's 404.

Thus separate GET and POST declarations for the same path work naturally. A
GET PARTIAL encountered before a POST FULL does not prevent POST dispatch.
Among two FULL matches, the first declared wins.

A prefix-matching mount is a dispatch owner, not an HTTP method PARTIAL, and
therefore stops sibling scanning at its declaration position.

### 9.3 Current behavior being removed

The old App router happens to retain insertion order within each of its HTTP,
WebSocket, and SSE arrays, but it does not preserve the written application
graph. It:

- stores HTTP, WebSocket, SSE, and mounts in separate collections;
- checks protocol routes before mounts regardless of declaration order; and
- sorts mounts from longest prefix to shortest before dispatch.

Only the old 405 `Allow` construction is alphabetically sorted; ordinary route
paths are not. The upgrade guide must explain the actual change rather than
claim that all old routes were alphabetized.

### 9.4 Mandatory order tests

The implementation plan must include explicit tests proving creation order is
preserved. At minimum, tests cover:

- static and parameterized routes declared in both orders;
- two FULL routes for the same path and method;
- one earlier PARTIAL followed by a later FULL;
- method-only sibling routes and first-seen `Allow` ordering;
- a route and a prefix mount declared in both orders;
- broad and specific mounts declared in both orders;
- groups before, between, and after parent siblings;
- HTTP, WebSocket, and SSE nodes retaining their relative positions in
  inspection;
- nested builder materialization preserving every level's order; and
- `to_router->routes` returning the declaration sequence without reordering.

The tests must assert which handler actually ran, not merely compare a private
array or inspect source records.

## 10. Shared middleware contract

### 10.1 Four entry forms everywhere

Every declarative middleware list and every App/Endpoint positional middleware
array accepts the same four forms:

| Entry | Meaning |
|---|---|
| nonempty class-name string | middleware class description |
| coderef | synchronous factory called with `($inner_app)` |
| blessed object with `wrap` | configured object called as `->wrap($inner_app)` |
| `PAGI::Routing::Middleware` | existing normalized description |

This applies to Compose, Router, HTTP route, WebSocket route, SSE route, inline
group/mount, routing-aware mount, and opaque mount middleware.

String resolution follows the existing middleware-description rules:

```perl
'RequestId'                    # PAGI::Middleware::RequestId
'PAGI::Middleware::GZip'       # already fully qualified
'^MyApp::Middleware::Audit'    # caller-owned fully qualified class
```

A string in a middleware list always means a middleware class. It never means
an Endpoint method. Position, not coderef names or debug metadata, determines
the role.

### 10.2 Normalization

`PAGI::Routing::Middleware` owns the one normalization function. Every
frontend delegates to it. Public immutable descriptions store homogeneous
`PAGI::Routing::Middleware` objects regardless of input form.

Normalization:

- validates and copies the list;
- turns each class string, coderef, or object into a description;
- preserves an existing description by identity;
- performs no wrapping or request I/O; and
- produces direct diagnostics naming the middleware position and invalid
  entry.

Actual factories, constructors, and `wrap` methods run synchronously during
each `to_app` compilation. They must return a native PAGI app coderef
immediately. The returned app runs later with
`($scope, $receive, $send)`. Middleware is never a `$c, $next -> Response`
callback.

The first listed item remains outermost.

### 10.3 Purpose of `middleware(...)`

The explicit helper remains valuable but optional for unconfigured entries:

```perl
middleware => [
    'RequestId',
    \&with_logging,
    $configured_auth,
    middleware('Session', cookie_name => 'sid'),
];
```

`middleware(...)` is the description constructor used for configuration,
explicit normalization, deliberate descriptor reuse, and inspection. It does
not wrap an application when declared.

## 11. Coderef and method conventions

### 11.1 Coderefs are never inspected or rebound

Across all three frontends, a coderef is invoked exactly as supplied. The code
must not inspect its CV name, package, signature, glob aliases, role origin, or
whether it appears anonymous.

```perl
route('/admin' => \&show_admin);

route('/admin' => sub ($c) {
    return $controller->show_admin($c);
});

middleware => [\&with_logging];
```

The middleware coderef means `with_logging($inner_app)`. It never secretly
means `$self->with_logging($inner_app)`.

### 11.2 Endpoint handler strings

Only an Endpoint handler target position accepts a local method-name string:

```perl
$r->get('/admin' => 'admin');
$r->websocket('/chat' => 'chat');
$r->sse('/events' => 'events');
```

The name is an unqualified method name resolved with `$self->can`, so inherited
and role-provided methods work. It is bound to the exact Endpoint instance and
adapted to an ordinary Context-handler coderef before immutable materialization.

A handler coderef is not rebound:

```perl
$r->get('/admin' => sub ($c) {
    return $self->admin($c);
});
```

Package-qualified handler strings, package loading, `eval`, and method-name
inference from a coderef are forbidden.

## 12. `PAGI::Endpoint::Router`

### 12.1 Retained purpose

Endpoint Router remains a useful optional class-oriented frontend. A complete
shape is:

```perl
package MyApp::Root;

use v5.40;
use parent 'PAGI::Endpoint::Router';
use Future::AsyncAwait;
use MyApp::People ();

sub new ($class, %args) {
    return bless { config => $args{config} }, $class;
}

sub routes ($self, $r) {
    $r->get('/' => 'home')->name('home');
    $r->websocket('/ws/status' => 'status_socket')->name('status');
    $r->sse('/events/health' => 'health_events')->name('health_events');

    my $people = MyApp::People->new(config => $self->{config});
    $r->mount('/person', router => $people)->name('person');
}

sub home ($self, $c) {
    return $c->html('<h1>Home</h1>');
}

async sub status_socket ($self, $c) {
    await $c->accept;
    await $c->send_json({ status => 'ok' });
    await $c->close;
}

async sub health_events ($self, $c) {
    await $c->start;
    await $c->send_event(event => 'health', data => 'ok');
    await $c->close;
}
```

`MyApp::People` may mount another Endpoint object such as
`MyApp::People::Blogs` under `/{person_id}/blog`. Names, constraints, path
parameters, and reverse routing compose through the same immutable graph. No
Endpoint package is loaded implicitly.

### 12.2 Lifecycle and snapshots

Calling `to_router` on a class constructs one Endpoint instance for that root
snapshot. Calling it on an existing object uses that exact object. The
instance's `routes($builder)` hook runs synchronously during materialization.

`to_app` is equivalent to `to_router->to_app`. It does not wrap the compiled
application with Endpoint-owned state injection or a second Context adapter.

For one root snapshot, repeated placement of the same Endpoint object is
materialized once and reuses the resulting immutable child Router. Separate
top-level `to_router` calls remain fresh.

### 12.3 State

The current `$self->state` store and its conditional injection into
`$scope->{state}` are removed. Endpoint object fields hold ordinary
configuration and collaborators:

```perl
my $repository = $self->{repository};
```

Lifespan-owned application resources use the server-propagated state visible
through Context:

```perl
my $db = $c->state->{db};
```

Applications initialize and close those resources with Compose lifespan
callbacks. Endpoint Router must not create a competing worker-lifecycle
contract. If scope state is absent, the existing Context state contract
applies; Endpoint does not silently seed an empty hash.

### 12.4 No custom dispatch Context

The current `context_class` override is removed. The shared routing compiler
constructs the standard protocol-appropriate `PAGI::Context`, just as it does
for handlers declared functionally or through App Router.

Custom dispatch Context policy would require a core Context-factory seam and
must be designed for every frontend together. Endpoint Router must not retain
a private version of that policy.

## 13. Endpoint helpers

### 13.1 `middleware_as($method)`

`middleware_as` adapts one local method into an ordinary middleware factory:

```perl
$r->get('/admin' => [
    $self->middleware_as('require_auth'),
] => 'admin');

sub require_auth ($self, $app) {
    return async sub ($scope, $receive, $send) {
        my $c = $self->new_context($scope, $receive, $send);

        unless ($c->state && $c->state->{user}) {
            my $response = $c->text('Unauthorized', status => 401);
            return await $c->respond($response);
        }

        return await $app->($scope, $receive, $send);
    };
}
```

The helper requires a nonempty unqualified method name that `$self->can`,
including inherited and role methods. It validates at helper invocation and
returns conceptually:

```perl
sub ($app) {
    return $method->($self, $app);
}
```

It creates no new middleware abstraction. The shared normalizer sees only a
coderef factory and validates the method's returned app through the ordinary
middleware compilation path.

For configuration, an explicit closure remains ordinary Perl:

```perl
sub ($app) {
    return $self->require_role($app, 'editor');
}
```

### 13.2 `app_as($method)`

`app_as` adapts one local method into a native three-channel PAGI app:

```perl
$r->get('/raw', raw => $self->app_as('raw_endpoint'));
$r->mount('/legacy' => $self->app_as('legacy_application'));

async sub raw_endpoint ($self, $scope, $receive, $send) {
    ...
}
```

It performs the same method-name validation and returns a coderef that forwards
`($scope, $receive, $send)` to the bound method. It does not construct a
Context, reinterpret the method's completion, or emit events.

### 13.3 `new_context(...)`

`new_context` is a convenience for native middleware and raw applications:

```perl
my $c = $self->new_context($scope, $receive, $send);
```

Its standard implementation returns:

```perl
PAGI::Context->new($scope, $receive, $send)
```

The result is the protocol-appropriate Context subclass. Construction only
creates a local interface over the supplied scope and channels. It does not
send an event, receive an event, copy the scope, seed state, or advance the
protocol lifecycle.

Regular Endpoint handlers already receive `$c` and should not construct a
second one. This method is not the compiler's Context-factory hook. Overriding
it changes only explicit calls made by application code; it does not change
the Context passed to normal route handlers.

### 13.4 Deliberately absent helpers

There is no `handler_as`: an Endpoint handler string already binds a local
method. There are no response, state, mount-discovery, or package-loading
helpers; those duplicate Context, Router, normal constructors, or lifespan.

The small adapter vocabulary is therefore:

```perl
'handler_name'                         # local method as Context handler
$self->middleware_as('authorize')      # local method as middleware factory
$self->app_as('native_application')    # local method as raw PAGI app
$self->new_context($scope, $r, $s)     # explicit Context in native code
```

## 14. Materialization, reuse, and cycles

One root `to_router` operation carries a private materialization context with:

- an active ancestry set keyed by mutable frontend object identity; and
- a completed map from mutable frontend identity to its immutable Router.

When it encounters a mutable App or Endpoint child:

1. a completed identity reuses that immutable Router in the same snapshot;
2. an identity in the active ancestry is a cycle and fails with a diagnostic
   showing the participating mount path/name chain;
3. otherwise it marks the object active, materializes it recursively, stores
   the result as completed, and clears the active mark.

This permits sibling reuse:

```perl
my $people = MyApp::People->new;

$root->mount('/people', router => $people)->name('people');
$root->mount('/staff',  router => $people)->name('staff');
```

Both placements share one child Router object within that snapshot while
remaining distinct resolver placements. It also makes real mutable cycles
detectable without manufacturing an impossible immutable Router cycle:

```perl
$a->mount('/b', router => $b)->name('b');
$b->mount('/a', router => $a)->name('a');
```

An immutable Router supplied directly is already complete. Existing immutable
Router ancestry guards remain defensive against pathological subclasses.

Compilation and request execution contain no builder-global current-route,
capture, frame, or Context state. One compiled application must safely handle
concurrent requests and repeated placement without cross-request leakage.

## 15. Names, metadata, and reverse routing

### 15.1 One naming system

All frontends produce the slash-address system already chosen for declarative
routing:

```text
/person/index
/person/show
/person/blog/index
/person/blog/show
```

A declared route `name` is one local leaf segment. A declared group or
routing-aware mount `name` is one local structural segment. Effective names in
resolver indexes and matched metadata are absolute slash addresses.

The distinction must be documented explicitly because the same field name is
observed at two stages:

- on the declaration object, `name` is local;
- in the request's match metadata, `name` is the effective absolute address.

Dotted effective names, `as`, public mount `namespace`, and copied App-router
name tables are removed.

### 15.2 Shared reverse routing

App and Endpoint users receive the immutable resolver's exact path behavior:

```perl
my $router = $builder->to_router;

$router->path_for(
    '/person/blog/show',
    { person_id => 7, blog_id => 12 },
    { tab => 'comments' },
    'latest',
);
```

This provides the same:

- absolute and relative logical references;
- required/extra parameter validation;
- repeated-parameter collision checks;
- inline and explicit constraint validation;
- UTF-8 percent encoding;
- query ordering; and
- fragment handling.

The old App `uri_for` path-only implementation, unescaped interpolation, and
copied mount prefixes are deleted. The upgrade guide gives direct equivalents.

Compiled App and Endpoint routes publish only the shared `pagi.routing`
request metadata. The old `pagi.router` record is not populated.

### 15.3 Declaration package

Every public pattern-bearing mutable declaration records the package from
which the user called that frontend method. It threads that package through
group builders and Endpoint route-builder forwarding into the immutable
Pattern constructor.

For example:

```perl
package MyApp::People;

use Types::Standard 'Int';

sub routes ($self, $r) {
    $r->get('/{person_id:&Int}' => 'show')->name('show');
}
```

`&Int` resolves in `MyApp::People`, not
`PAGI::Endpoint::Router::RouteBuilder`, `PAGI::App::Router`, or
`PAGI::Routing::Route`.

The declaration-package rules for wrappers, re-exports, roles, qualified
providers, and symbol-table lookup remain those of the inline provider design.

## 16. Upgrade guide

The feature adds a root-level `UPGRADING.md`. It is written so it can be handed
directly to existing users without requiring them to reconstruct behavior from
`Changes` or internal design documents.

It contains tested before/after examples for at least:

1. native three-channel App handlers becoming `$c`/Response handlers;
2. retaining native handlers with explicit `raw`;
3. old `route($method, $path, ...)` becoming path-first `route(..., methods)`;
4. `uri_for` becoming shared `path_for` and gaining validation/encoding;
5. dotted names becoming slash addresses;
6. `as` and mount `namespace` becoming one local `name`;
7. old parent-reusing groups becoming fresh-child structural groups;
8. removal of package-string group/mount loading;
9. declaration-order dispatch replacing routes-first and longest-mount-first;
10. middleware strings, coderefs, objects, and descriptors;
11. Endpoint `$c, $next -> Response` middleware becoming native factories;
12. adapting an Endpoint middleware method with `middleware_as`;
13. Endpoint `$self->state` becoming lifespan-managed `$c->state`;
14. removal of `context_class` and the limited purpose of `new_context`;
15. nested Endpoint object mounts;
16. WebSocket and SSE route middleware;
17. `pagi.router` metadata becoming `pagi.routing`;
18. snapshot behavior and retaining `to_router` for stable inspection;
19. path constraints now validating generated paths as well as dispatch; and
20. raw route versus opaque mount semantics.

The guide explicitly calls out that declaration order is now authoritative.
It advises users who relied on longest-prefix mounts to reorder declarations
from most specific to least specific.

`README.md`, `Changes`, the App Router POD, and Endpoint Router POD link to the
guide. The Endpoint Cookbook examples are migrated rather than merely marked
legacy.

## 17. Documentation requirements

Documentation presents the APIs as three frontends, one engine:

| Frontend | Best fit | Mutable? | Handler convenience |
|---|---|---:|---|
| `PAGI::Routing` | decomposed immutable route trees | no | coderef `$c` handlers |
| `PAGI::App::Router` | imperative route construction | yes | verb methods |
| `PAGI::Endpoint::Router` | class/role-oriented applications | object configuration | local handler methods |

Every middleware example states both phases:

1. the factory or `wrap` method runs synchronously at compilation with the
   inner app; and
2. its returned app runs per request with the three native channels.

Every helper documents whether it constructs local state, wraps an app, runs
per request, or emits protocol events. In particular:

- `middleware_as` creates a factory closure and emits nothing;
- `app_as` creates a bound application closure and emits nothing itself;
- `new_context` creates a local object and emits/receives nothing; and
- `$c` protocol methods retain their own documented lifecycle behavior.

The docs include examples using normal imports and explicitly constructed
nested objects. They do not demonstrate string package loading or coderef
introspection.

## 18. Validation and diagnostics

Diagnostics distinguish:

- malformed declaration argument shape;
- missing or invalid route target;
- invalid raw target;
- invalid middleware entry and its position;
- an Endpoint handler method that does not exist;
- an Endpoint adapter method that does not exist;
- applying `name`, `desc`, or `constraints` without a compatible last
  declaration;
- naming an opaque mount;
- passing an unsupported object to `router =>`;
- a mutable frontend cycle, with placement ancestry;
- an inline provider failure in the original declaration package; and
- immutable Router construction errors such as duplicate addresses or path
  parameter collisions.

No error should expose a stringified coderef/object as an alleged option name.
Declaration parsers validate positional shape before building option hashes.

## 19. Test requirements

Implementation planning must divide the work so the shared model is tested
before deleting the older behavior. Tests must cover at least:

### 19.1 App-to-declarative equivalence

- equivalent functional and App declarations produce equivalent immutable
  node trees and matching behavior;
- HTTP Context handlers return immediate and Future-backed Responses;
- WebSocket and SSE Context handlers run through their imperative helpers;
- raw HTTP, WebSocket, and SSE routes retain all three channels;
- generic/custom methods and `any` normalize correctly;
- group, opaque mount, and routing-aware mount semantics match the functional
  model; and
- `to_app` is behaviorally equivalent to `to_router->to_app`.

### 19.2 Declaration order

Every mandatory case in section 9.4 is a behavioral regression test. A test
must create nodes through the public builder in the asserted order and observe
the winning handler. Tests also inspect the immutable snapshot order. No
implementation may satisfy this section by sorting expected test data.

### 19.3 Middleware

- all four entry forms work in every supported middleware position;
- all frontends normalize to middleware descriptions;
- the first listed entry is outermost;
- factories and `wrap` run once per compiled occurrence, not per request;
- middleware can call downstream, short-circuit, wrap send/receive, and modify
  a cloned scope;
- route middleware works for HTTP, WebSocket, and SSE;
- middleware sees a complete GET representation before the final HEAD boundary
  suppresses body and sendfile events;
- string entries always mean classes, including in Endpoint route lists; and
- configured objects/descriptors retain documented identity and reuse.

### 19.4 Endpoint

- class and existing-object compilation;
- immediate and Future-backed HTTP method handlers;
- WebSocket and SSE method handlers;
- coderef handlers receive only their documented arguments and are never
  rebound;
- inherited and role-provided handler methods;
- nested Endpoint objects across HTTP, WebSocket, and SSE routes;
- `middleware_as`, `app_as`, and `new_context`, including missing-method
  diagnostics;
- absence of Endpoint state injection;
- lifespan `$c->state` use;
- removal of response-valued `$next` behavior; and
- removal of `context_class` dispatch customization.

### 19.5 Snapshots and safety

- builder mutation after a snapshot does not affect that snapshot;
- two top-level snapshots are fresh;
- same-child sibling placement reuses one immutable child per root snapshot;
- a real two-builder or two-Endpoint cycle fails;
- one compiled app handles concurrent requests without match/capture/metadata
  leakage;
- mounting the same subtree twice does not leak placement metadata; and
- repeated `to_app` creates independent middleware graphs except for
  deliberately reused caller-owned state.

### 19.6 Reverse routing and metadata

- App and Endpoint paths use slash addresses and relative references;
- generated paths validate constraints and encode values;
- query and fragment compact/named forms remain supported;
- nested route parameters compose without silent overwrites;
- declaration packages survive App and Endpoint forwarding;
- matched metadata uses `pagi.routing` and the absolute effective name; and
- old `pagi.router`, dotted names, `as`, `namespace`, and `uri_for` are absent.

### 19.7 Documentation

- POD examples compile where practical;
- the Endpoint Cookbook examples are exercised;
- every `UPGRADING.md` before/after code pair is syntax-checked or covered by a
  focused behavior test; and
- the large-application example continues to follow generated links with the
  PAGI-Tools test client.

## 20. Implementation boundaries

The implementation should proceed in these conceptual layers:

1. expand the shared middleware normalizer to four forms and migrate every
   declarative consumer;
2. introduce the mutable App declaration records and immutable
   materialization context;
3. implement the verb/group/mount API and declaration-order snapshots;
4. switch App execution, inspection, names, and reverse routing to the shared
   Router;
5. rebuild Endpoint as the method-binding frontend, including its three
   helpers;
6. migrate examples, Cookbook, metadata consumers, and upgrade documentation;
7. remove the old App matcher, copied name tables, Endpoint value-flow chain,
   state injection, and custom Context path; and
8. run focused, full-suite, concurrency, documentation, and distribution
   verification.

This sequence is descriptive, not the implementation plan. The written plan
must break the work into reviewable test-first commits, maintain the repository
tracking/deviation log required for multi-task execution, and attach real test
counts and evidence to each completed task.

## 21. Acceptance criteria

The design is complete when:

- all three frontends compile through one immutable model and compiler;
- App and Endpoint contain no independent route matching;
- all public declarations preserve written order, proven behaviorally;
- all middleware positions share the four-form contract;
- `$c` is the default handler API and raw applications are explicit;
- Endpoint class/method ergonomics work for nested HTTP, WebSocket, and SSE
  applications without value-flow middleware;
- App and Endpoint reverse routing is the shared declarative resolver;
- snapshot identity, reuse, and cycle behavior are documented and tested;
- the standalone upgrade guide covers every intentional break; and
- the complete suite and documentation verification pass without retaining
  compatibility code for the displaced contracts.
