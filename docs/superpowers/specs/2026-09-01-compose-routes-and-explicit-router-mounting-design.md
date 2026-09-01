# Compose Routes and Explicit Router Mounting

**Date:** 2026-09-01

**Status:** Proposed corrective design; awaiting written review before
implementation planning

**Scope:** Make `routes` the only routing input to `PAGI::Compose`, remove the
public `router` constructor option, and require every already-constructed
Router to enter another routing table through an explicit Mount. Update the
runtime, tests, examples, generated documentation, upgrading guidance, and
release notes together.

## 1. Decision

`PAGI::Compose` constructs and owns exactly one root
`PAGI::Routing::Router` from an ordered `routes` arrayref:

```perl
my $app = compose(
    routes => [
        route('/' => \&home, name => 'home'),
        mount('/people', routes => [
            route('/' => \&list_people, name => 'list'),
        ], name => 'people'),
    ],
    http_default => not_found(
        detail => 'That page does not exist.',
    ),
    middleware => [middleware('RequestId')],
    lifespan => {
        startup  => \&startup,
        shutdown => \&shutdown,
    },
    desc => 'Public application',
);
```

`Compose` no longer accepts `router => $router`.

An already-constructed Router is an application. It is composed through
Mount, like every other application:

```perl
my $routing = router(
    routes       => \@routes,
    middleware   => [middleware(\&observe_routes)],
    http_default => not_found(detail => 'No matching route'),
    desc         => 'Existing routing application',
);

my $app = compose(
    routes => [
        mount('/' => app => $routing),
    ],
    middleware => [middleware('RequestId')],
    lifespan   => { startup => \&startup },
);
```

The root Mount is explicit. Compose does not create it secretly.

The following is not the replacement:

```perl
# Valid Perl and valid route nodes, but usually the wrong migration.
compose(routes => $routing->routes);
```

That spelling flattens the Router. It retains the child Route and Mount
objects but discards the Router boundary, Router middleware, `http_default`,
`desc`, identity, and Resolver. Flattening is allowed only when the caller
deliberately wants those semantics.

Compose remains an application facade rather than a Router subclass. It keeps
an internal `router` accessor because the application owns its root Router.
The removed API is the public constructor option for injecting a prebuilt
Router, not Compose's internal Router ownership.

No compatibility alias, hidden Mount, frontend guessing, or automatic route
extraction is retained. These APIs have not been released, and all live
callers migrate together.

## 2. Work map

| Repository | Ticket/work item | Branch | Base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | Compose routes-only correction; no external ticket | `feature/compose-retained-router` | corrective work starts from `5cc9731`; branch originally forked from `558b14c` | Runtime, tests, examples, POD, README, tutorial, cookbook, upgrading guidance, Changes, design and plan records | One unreleased PAGI-Tools distribution | `origin/feature/compose-retained-router` after authorization |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI` | PAGI application/lifespan contracts | read-only reference | published specification | None | Normative protocol reference only | None |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server` | Root object loading and lifespan behavior | read-only reference | released server | None | Integration reference only | None |

Before implementation and before any push, reconfirm that the PAGI-Tools
worktree is on `feature/compose-retained-router`, that its base and remote have
not moved unexpectedly, and that no sibling repository has entered write
scope. An architecture change that requires modifying PAGI or PAGI::Server
must stop and update this map before work continues.

## 3. Governing and superseded designs

This design supersedes the public `router => $router` constructor mode in
`2026-08-31-compose-retained-router-design.md` and every corresponding task in
`2026-08-31-compose-retained-router.md`.

It preserves the useful conclusions of that campaign:

- current Starlette is not a Router subclass;
- an application facade owns a root Router;
- Compose must retain the one root Router it constructs rather than retain a
  route list and reconstruct another Router during compilation;
- Compose owns root middleware, lifespan, ErrorHandler, ResponseGuard, and
  the outer HEAD wire boundary;
- Router owns ordered matching, routing middleware, reverse routing,
  descriptions, `http_default`, NONE, and PARTIAL outcomes; and
- arbitrary non-routing applications do not belong in a generic
  `compose(app => ...)` mode.

It changes one conclusion: retaining a Router through a special Compose
constructor mode is not necessary. Mount is already the application
composition abstraction and can preserve the complete Router at `/` without
rewriting its request path.

The following earlier decisions remain in force:

- Route matches one complete, method-aware leaf;
- Mount consumes a prefix and delegates finally to one application;
- Router selects ordered Route and Mount nodes;
- child ownership is final after a Mount prefix matches;
- Route coderefs are one-argument protocol handlers;
- native application coderefs use explicit application positions or
  `as_app` where a Route endpoint would otherwise be ambiguous;
- middleware is pure application-to-application wrapping;
- routing descriptions are immutable;
- every `to_app` call compiles a fresh executable graph; and
- lifespan executes once at the application root and never cascades through
  mounted applications.

## 4. Why the retained-Router constructor mode is wrong

### 4.1 It adds a second composition operation

The intended separation is:

```text
Route    selects a leaf
Router   selects ordered routes
Mount    composes an application under a path
Compose  constructs the application root
```

`compose(router => $router)` lets Compose compose an already-built routing
application without Mount. That is a second composition path whose only
special case is the nominal class of the child application.

The duplication is visible in application code:

```perl
my $router = PAGI::App::Router->new;
$router->get('/health' => \&health);

compose(
    router   => $router->to_router,
    lifespan => {...},
);
```

The variable called Router is converted into another Router and then passed
through a Router-only Compose option. This is internally explainable but does
not communicate the component boundary clearly.

### 4.2 It makes an advanced preservation case canonical

The `router` mode was added to preserve:

- Router middleware;
- Router `http_default`;
- Router `desc`;
- Router identity and its Resolver; and
- inspectable named descendants.

Those are legitimate requirements. They do not require a new Compose input.
An explicit Mount preserves the same Router as an application boundary.

### 4.3 Flattening is not preservation

This does not solve the problem:

```perl
compose(routes => $router->routes);
```

It builds a new root Router from the old Router's direct child nodes. The new
Router does not inherit the old Router's middleware, default, description, or
Resolver identity. Its NONE and PARTIAL outcomes occur at a different Router
boundary. A caller may choose that behavior, but documentation must call it
flattening rather than attaching or retaining a Router.

### 4.4 Explicit Mount already expresses the truth

This preserves the object and names the boundary:

```perl
compose(
    routes => [
        mount('/' => app => $router),
    ],
    lifespan => {...},
);
```

The outer root Router selects the root Mount. The Mount consumes nothing. The
child Router then owns its complete routing behavior. Root safety and lifespan
remain outside it in Compose.

## 5. Starlette comparison

Current Starlette constructs its root Router inside `Starlette.__init__`:

```python
self.router = Router(routes, lifespan=lifespan)
```

Its constructor accepts `routes`; it does not accept a prebuilt Router through
a `router` parameter.

An existing Router is an ASGI application. Starlette composes it through
Mount:

```python
user_router = Router(routes=[
    Route('/', endpoint=list_users),
])

app = Starlette(routes=[
    Mount('/users', app=user_router),
])
```

The imperative `app.mount('/users', app=user_router)` spelling creates the
same routing relationship in Starlette's mutable frontend.

Passing `router.routes` to `Starlette(routes=...)` is possible but does not add
the Router. It reconstructs a new root Router from the child's route objects
and therefore does not preserve Router-level configuration.

This PAGI design follows the same topology:

| Need | Starlette | PAGI-Tools |
| --- | --- | --- |
| Construct root routing application | `Starlette(routes=[...])` | `compose(routes => [...])` |
| Inspect root Router | `app.router` | `$app->router` |
| Attach existing Router under prefix | `Mount('/x', app=router)` | `mount('/x' => app => $router)` |
| Preserve existing Router at root | `Mount('/', app=router)` | `mount('/' => app => $router)` |
| Flatten child declarations deliberately | `routes=router.routes` | `routes => $router->routes` |

PAGI deliberately keeps lifespan on Compose instead of Router. This does not
change the composition rule. Compose consumes the root lifespan scope;
mounted Routers never receive or recursively execute it. Starlette likewise
does not send root lifespan scopes through Mount, although Starlette places
its root lifespan context on its internally owned Router.

## 6. Public Compose contract

### 6.1 Constructor

The exact constructor options are:

| Option | Required | Meaning |
| --- | --- | --- |
| `routes` | yes | Ordered arrayref of Route and Mount descriptions used to construct the root Router |
| `http_default` | no | Passed to the constructed root Router |
| `desc` | no | Passed to the constructed root Router |
| `middleware` | no | Compose application middleware outside root safety and routing according to the existing compiler order |
| `lifespan` | no | Root startup and shutdown callbacks |

`routes` must be an arrayref accepted by `PAGI::Routing::Router`. Compose
constructs one Router during Compose construction and retains that exact
Router for its lifetime.

The following options are rejected:

```perl
compose(router => $router);
compose(app    => $app);
```

The diagnostics are direct:

```text
compose no longer accepts 'router'; put an existing Router in mount('/' => app => $router)
compose no longer accepts 'app'; deploy the application directly or compose it through Mount
compose requires routes
compose routes must be an arrayref
```

The diagnostics may include normal Perl qualification but must name Mount for
the Router case and must not recommend `$router->routes`.

Compose does not accept:

- a Router object as the value of `routes`;
- a mutable Router frontend as the value of `routes`;
- a callback that populates a Router frontend;
- a package name;
- an arbitrary `to_app` object;
- `to_router` or `routes` capability guessing; or
- positional application arguments.

Higher-level frameworks may provide those conveniences under their own API.

### 6.2 Internal Router ownership

The public `router` accessor remains:

```perl
my $app = compose(routes => \@routes);
my $root_router = $app->router;
```

The returned object is the exact root Router constructed by Compose. Repeated
access returns the same identity. It is not an injected child Router.

These accessors continue to delegate to the root Router:

- `routes`
- `http_default`
- `desc`
- `named_routes`
- `route_named`
- `path_for`

When the root routes contain an inspectable mounted Router, the root Resolver
discovers that child's names through the Mount according to existing naming
rules.

### 6.3 Compilation

Each `Compose->to_app` call:

1. compiles the retained root Router once;
2. installs the existing Compose middleware and root safety boundaries;
3. consumes lifespan scopes in Compose without invoking the Router; and
4. forwards each non-lifespan scope to the compiled root Router.

There is no target-mode branch and no runtime distinction between a
routes-created Router and an injected Router, because injection no longer
exists.

Compose must not rebuild the root Router during `to_app`, clone it, copy its
fields, or inspect application arity.

## 7. Existing Router composition

### 7.1 Root Mount semantics

The canonical preservation form is:

```perl
compose(
    routes => [
        mount('/' => app => $routing),
    ],
    lifespan => {...},
);
```

The existing Mount contract supplies all required behavior:

- `/` consumes no prefix;
- `path`, `raw_path`, and `root_path` remain unchanged;
- parent path parameters are empty at a root Mount;
- the selected child Router owns FULL, PARTIAL, NONE, WebSocket, and SSE
  outcomes;
- the parent Router never resumes scanning after the root Mount matches;
- child Router middleware and `http_default` remain active;
- child 404 and 405 responses unwind through Mount, outer Router, and Compose
  middleware;
- Compose supplies the final root HEAD boundary;
- the child's Resolver remains owned by that child; and
- the outer Resolver composes placement-specific inspection without mutating
  the child.

A root Mount must not add an empty or duplicate slash to generated paths.

### 7.2 Naming and reverse routing

An unnamed root Mount contributes no logical namespace:

```perl
my $routing = router(routes => [
    route('/people/{id}' => \&show, name => 'show'),
]);

my $app = compose(routes => [
    mount('/' => app => $routing),
]);

$app->path_for('/show', { id => 42 }); # /people/42
```

A named root Mount deliberately creates a namespace:

```perl
my $app = compose(routes => [
    mount('/' => app => $routing, name => 'legacy'),
]);

$app->path_for('/legacy/show', { id => 42 });
```

Migration from `compose(router => $routing)` uses an unnamed Mount unless the
author intentionally wants to change the route address namespace.

The outer routing metadata gains an explicit Mount boundary. That is not an
accidental artifact: the application is now composed through Mount. Access
logging and diagnostics see the actual component chain.

### 7.3 Mutable and method-oriented frontends

An immutable snapshot is inspectable:

```perl
my $builder = PAGI::App::Router->new;
$builder->get('/people/{id}' => \&show)->name('show');

my $app = compose(routes => [
    mount('/' => app => $builder->to_router),
]);
```

The same rule applies to `PAGI::Endpoint::Router`:

```perl
my $endpoint = MyApp::Root->new(repository => $repository);

my $app = compose(
    routes => [
        mount('/' => app => $endpoint->to_router),
    ],
    lifespan => { startup => \&startup },
);
```

Mounting the frontend object directly is a valid but opaque application
boundary because those objects implement `to_app`:

```perl
mount('/' => app => $builder);
mount('/' => app => $endpoint);
```

Opaque mounting dispatches correctly but the parent does not guess route
names or declarations. Documentation uses `to_router` when parent inspection
or reverse routing matters and explains why.

No `to_routes`, `include_router`, `routes_provider`, or frontend-specific
Compose option is added in this release.

### 7.4 Direct deployment remains valid

A Router can still be deployed directly when Compose root services are not
needed:

```perl
my $app = $routing->to_app;
```

Or the Router object may be handed to a server that accepts instantiated
`to_app` applications.

A bare Router has its documented application semantics. It does not gain
Compose lifespan, ErrorHandler, ResponseGuard, or application middleware.
Under automatic lifespan negotiation it may decline an unsupported lifespan
scope; a strict-lifespan server rejects that deployment. Authors needing those
root services use Compose plus an explicit root Mount.

## 8. Router and Mount contracts remain narrow

This correction does not add a Router field to Router. A
`PAGI::Routing::Router` continues to contain:

- its direct ordered route nodes;
- Router middleware;
- Router `http_default`;
- Router `desc`; and
- its Resolver.

It does not contain Compose, lifespan, ErrorHandler, ResponseGuard, or a
second Router.

Mount continues to accept exactly one of:

```perl
mount('/x' => app    => $application);
mount('/x' => routes => \@child_nodes);
```

`app => $router` preserves an existing Router application. `routes =>
@child_nodes` constructs a new child Router from those declarations. These
forms are not interchangeable:

| Mount form | Child Router identity | Child Router middleware/default/desc | Parent inspection |
| --- | --- | --- | --- |
| `app => $router` | preserved | preserved | inspectable for an immutable Router |
| `routes => $router->routes` | replaced | discarded | rebuilt from supplied nodes |
| `routes => \@nodes` | newly constructed | configured by the Mount's child-Router rules | inspectable |
| `app => $opaque` | application identity preserved | application-owned | opaque |

No special root-Mount shortcut is added. The explicit spelling is short
enough and keeps application composition visible.

## 9. Middleware and lifecycle order

For an immutable Router preserved under an unnamed root Mount, the effective
request order is:

```text
Compose outer HEAD boundary
  Compose ErrorHandler
    Compose ResponseGuard
      Compose middleware
        outer root Router middleware (normally none)
          root Mount middleware (normally none)
            child Router middleware
              nested Mount middleware
                Route middleware
                  endpoint/application
```

The implementation must preserve the repository's already-ratified exact
ordering, including whichever safety wrappers are outside or inside user
middleware. The diagram communicates ownership, not permission to reorder
existing boundaries.

For lifespan:

```text
server lifespan scope
  Compose lifespan dispatcher
    Compose application middleware as already specified
      startup/shutdown callbacks

root Router and mounted child Router are not invoked
```

The correction must not make child Router middleware observe lifespan or run
nested child startup/shutdown callbacks.

## 10. HTTP and protocol outcomes

An explicit root Mount is a FULL prefix match for every routable request path.
After selection, the child owns the outcome:

| Child result | Owner |
| --- | --- |
| HTTP Route FULL | child Router and selected Route |
| HTTP PARTIAL | child Router 405 and authoritative `Allow` |
| HTTP NONE | child Router `http_default` or stock 404 |
| WebSocket FULL/miss | child Router protocol behavior |
| SSE FULL/miss | child Router protocol behavior |
| Handler exception | existing Compose ErrorHandler boundary |
| Silent/incomplete child | existing Compose ResponseGuard boundary |

The outer Router's `http_default` is unreachable when its first and only node
is a matching root Mount. The API does not add a special prohibition because
an outer routing table may legitimately place other nodes before a root Mount
or construct a different topology. Documentation must not configure an outer
`http_default` in the simple preservation example, because doing so implies it
handles child misses when it does not.

A root Mount is a catch-all application boundary when the Router scan reaches
it. Any later siblings are unreachable for routable scopes. An application
that deliberately combines ordinary outer routes with a root-mounted child
must place every outer route that may win before the root Mount, and the root
Mount then acts as the final application delegation boundary. Construction
does not reject later siblings because declaration order and final Mount
ownership are general Router semantics, but POD must warn that such siblings
cannot be selected.

Method evidence does not cross the selected Mount boundary. A child PARTIAL
uses the child's ordered `Allow` union; the parent neither adds sibling
methods nor resumes scanning.

## 11. Inspection consequences

Before this correction:

```perl
my $root = compose(router => $routing);
$root->router == $routing; # identity true
```

After this correction:

```perl
my $root = compose(routes => [
    mount('/' => app => $routing),
]);

$root->router == $routing; # false: this is the outer root Router
```

This is intentional. `Compose->router` means the Router owned by Compose, as
`Starlette.router` means the Router owned by Starlette. The mounted child
remains available from the Mount description's `app` accessor.

The following still work through the outer Resolver when the child is an
immutable Router:

- `named_routes`
- `route_named`
- `path_for`
- request-aware `url_for` and `path_for`
- effective route metadata and mount-chain inspection

`Compose->routes` returns the direct children of Compose's root Router. In the
preservation form that is the root Mount description, not the mounted
Router's flattened child list. Callers that need the child description obtain
it through `$compose->routes->[0]->app` or retain their original Router
reference; they must not infer that Compose has erased the Mount boundary.

Tests must not assert child identity through `Compose->router`. They must
assert:

1. stable identity of the new root Router;
2. stable identity of the child through the Mount's `app`;
3. correct placement-aware name discovery; and
4. unchanged child Router configuration.

## 12. Migration rules

### 12.1 Small declarative applications

Before:

```perl
my $routing = router(
    routes       => \@routes,
    http_default => $not_found,
    desc         => 'Application routes',
);

compose(
    router   => $routing,
    lifespan => {...},
);
```

After, when no separately reusable Router is needed:

```perl
compose(
    routes       => \@routes,
    http_default => $not_found,
    desc         => 'Application routes',
    lifespan     => {...},
);
```

This is the preferred Starlette-like application shape.

### 12.2 Reusable or prebuilt Router

Before:

```perl
compose(
    router   => $routing,
    lifespan => {...},
);
```

After:

```perl
compose(
    routes => [
        mount('/' => app => $routing),
    ],
    lifespan => {...},
);
```

### 12.3 Mutable App Router

Before:

```perl
compose(router => $builder->to_router);
```

After:

```perl
compose(routes => [
    mount('/' => app => $builder->to_router),
]);
```

### 12.4 Endpoint Router

Before:

```perl
compose(
    router   => $endpoint->to_router,
    lifespan => {...},
);
```

After:

```perl
compose(
    routes => [
        mount('/' => app => $endpoint->to_router),
    ],
    lifespan => {...},
);
```

### 12.5 Nested Router already using Mount

No conceptual change:

```perl
mount('/api' => app => $api_router);
```

### 12.6 Intentional flattening

This remains possible but is documented as a different operation:

```perl
compose(
    routes       => $routing->routes,
    http_default => $new_default,
    desc         => 'New root description',
);
```

The caller is constructing a new Router from the child's direct declarations.
It is responsible for replacing every discarded Router-level policy
explicitly.

## 13. Examples are part of the contract

Every live example under `examples/` must be reviewed, not merely searched and
mechanically changed.

### 13.1 Preferred examples

Examples already capable of expressing their complete root as declarative
nodes use direct Compose routes:

```perl
compose(
    routes => [
        route(...),
        mount(...),
    ],
    lifespan => {...},
);
```

The Starlette apples example is the primary readability canary. It must remain
in this direct form and its README must compare it accurately with:

```python
Starlette(routes=[...], lifespan=...)
```

It must not introduce a temporary root Router merely to demonstrate Mount.

The declarative-routing and Pages examples should likewise prefer direct
routes when that retains their intended behavior without duplication.

### 13.2 Class-based examples

Examples whose purpose is to demonstrate `PAGI::App::Router` or
`PAGI::Endpoint::Router` preserve the materialized Router explicitly:

```perl
compose(
    routes => [
        mount('/' => app => $router->to_router),
    ],
    lifespan => {...},
);
```

Their README files must explain:

- the frontend materializes an immutable Router;
- Mount is the ordinary application-composition boundary;
- `/` consumes nothing;
- the unnamed Mount preserves route addresses;
- using `->routes` would flatten and discard Router-level policy; and
- mounting the frontend object directly is valid but opaque to the parent.

This applies at minimum to:

- `examples/background-tasks`;
- `examples/endpoint-demo`;
- `examples/endpoint-router-demo`;
- `examples/full-demo`;
- `examples/10-chat-showcase`;
- `examples/15-large-application`; and
- any additional example found by the final repository search.

### 13.3 Example verification

Use the PAGI-Tools Test Client for live example behavior. Tests must cover
real links and routed requests rather than compare only source strings.

For each migrated example, preserve as applicable:

- startup state;
- shutdown behavior;
- root page;
- named link generation;
- nested route dispatch;
- custom 404;
- 405 plus `Allow`;
- middleware headers or logging evidence;
- static/file responses;
- WebSocket behavior; and
- SSE behavior.

Example-only source changes do not require unrelated full-suite repetitions,
but implementation changes to Compose, Mount, Router, or Resolver require the
normal focused and full verification gates.

## 14. Documentation migration

The implementation must update all current documentation that teaches or
mentions Compose target selection, including:

- `README.md` and its generated-source POD;
- `lib/PAGI/Compose.pm`;
- `lib/PAGI/Routing.pm`;
- `lib/PAGI/Routing/Router.pm`;
- `lib/PAGI/Routing/Mount.pm`;
- `lib/PAGI/App/Router.pm`;
- `lib/PAGI/Endpoint/Router.pm`;
- `lib/PAGI/Tools.pm`;
- `lib/PAGI/Tools/Tutorial.pod`;
- `lib/PAGI/Tools/Cookbook.pod`;
- middleware POD containing Compose examples;
- every live `examples/*/README.md` affected by the migration;
- `UPGRADING.md`; and
- `Changes`.

Documentation must distinguish these operations explicitly:

```perl
# Construct a new root Router.
compose(routes => \@nodes);

# Preserve a Router as a child application at root.
compose(routes => [mount('/' => app => $router)]);

# Deliberately discard the Router boundary and reuse only direct nodes.
compose(routes => $router->routes);

# Deploy without Compose root services.
$router->to_app;
```

The Mount POD must contain a dedicated `mount` versus flattening comparison.
The Compose POD must explain that its `router` accessor does not imply a
`router` constructor option.

Historical files under `docs/superpowers/specs/` and
`docs/superpowers/plans/` are not rewritten as if they had always made this
decision. This spec supersedes them explicitly. Live generated documentation,
examples, `UPGRADING.md`, and `Changes` must contain no stale recommendation.

Regenerate `README.md` through the repository's documented tool rather than
editing generated prose independently. Verify the generated file is stable.

## 15. Runtime changes

### 15.1 Compose constructor

Remove:

- `router` from allowed options;
- the `routes`/`router` XOR;
- retained-child validation;
- Router-form `http_default` and `desc` conflict branches; and
- diagnostics recommending `router =>`.

Require and validate `routes`, then construct one root Router with:

```perl
PAGI::Routing::Router->new(
    routes => $opts{routes},
    (exists $opts{http_default}
        ? (http_default => $opts{http_default}) : ()),
    (exists $opts{desc} ? (desc => $opts{desc}) : ()),
);
```

Retain the resulting object in Compose's internal `router` slot.

### 15.2 Compose compiler

The compiler continues to compile `Compose->router`. It must have no injected
Router mode, arbitrary app mode, route-list reconstruction, or frontend
special case.

Root safety, HEAD handling, settlement, and lifespan behavior are unchanged.
This campaign must not reopen the recently settled buffering, disconnect,
send-Future, Stream, File, denial, or decline contracts.

### 15.3 Router and Mount compiler

Root Mount behavior already exists and is tested. The implementation should
reuse it. If a new test exposes a defect in that general behavior, fix the
general Mount/Router implementation rather than introduce a Compose-only
branch.

An inspectable mounted Router must continue to compile as a child routing
boundary without calling an opaque public application seam or installing a
second public root HEAD adapter inside the outer one.

## 16. Required tests

### 16.1 Compose construction

Test that:

1. `routes` is required;
2. `routes` must be an arrayref;
3. `router` is rejected with the root-Mount diagnostic;
4. `app` remains rejected;
5. unknown options fail;
6. Compose constructs one root Router at construction;
7. repeated `router` accessor calls return that root Router by identity;
8. `routes`, `http_default`, `desc`, and reverse-routing accessors delegate to
   the root Router; and
9. each `to_app` call compiles a fresh executable graph without reconstructing
   the description Router.

### 16.2 Root-mounted Router preservation

Using an immutable child Router with middleware, `http_default`, `desc`, and
named routes, test that:

1. the Mount retains child identity;
2. HTTP FULL reaches the child endpoint;
3. HTTP PARTIAL produces the child's 405 and ordered `Allow`;
4. HTTP NONE invokes the child's custom default;
5. the outer Router does not resume sibling scanning;
6. child Router middleware runs exactly once;
7. Compose middleware remains outside child Router middleware;
8. GET and HEAD retain header parity and HEAD emits no body/file/trailers;
9. WebSocket success and miss behavior remain child-owned;
10. SSE success and miss behavior remain child-owned;
11. handler exceptions reach the Compose ErrorHandler;
12. incomplete responses reach ResponseGuard; and
13. concurrent requests share no request-local routing metadata.

### 16.3 Path and scope arithmetic

For root paths `''`, `'/'`, and a nonempty deployment root, and request paths
`'/'` plus nested paths, verify that root Mount preserves:

- `path`;
- `raw_path`;
- `root_path`;
- decoded captures; and
- request-local state and transport references.

No clone, defensive copy, or scope reconstruction may be added merely to make
these tests pass. Existing shallow child-scope semantics remain authoritative.

### 16.4 Inspection and names

Test that:

1. an unnamed root Mount exposes child names without a new namespace;
2. a named root Mount adds exactly one namespace segment;
3. generated paths contain no added slash;
4. reused child Routers remain placement-aware;
5. required path parameters across ancestry remain validated;
6. duplicate effective names and parameter collisions retain existing
   diagnostics;
7. Compose's root Router identity differs from the child identity; and
8. the child is still retrievable from the Mount description.

### 16.5 Frontends

For both App Router and Endpoint Router, test:

1. `to_router` plus root Mount is inspectable;
2. mounting the frontend object directly remains valid and opaque;
3. route names work through the inspectable form;
4. root Router configuration survives the inspectable form; and
5. no Compose code calls a frontend `routes` or `to_router` method
   implicitly.

### 16.6 Lifespan

Test that:

1. Compose startup and shutdown run once;
2. server-provided lifespan state is preserved;
3. no root or child Router endpoint sees a lifespan scope;
4. mounted child lifecycle does not run automatically;
5. startup failure and shutdown failure retain existing PAGI events; and
6. direct bare Router strict-lifespan behavior remains documented and
   unchanged.

### 16.7 Migration and documentation

Add exercised upgrade examples for every migration shape in section 12.
Compile or run every public code example covered by the repository's existing
POD/example harness. Final searches over `lib/`, `t/`, `examples/`,
`README.md`, `UPGRADING.md`, and `Changes` must find no live
`compose(router => ...)` recommendation.

Negative tests may contain the spelling to assert its diagnostic. Historical
superpowers records may contain it as superseded history.

## 17. Adversarial review and rejected alternatives

### 17.1 Keep `router =>` as an advanced form

**Benefit:** shortest preservation spelling and direct identity through
`Compose->router`.

**Rejection:** it leaves two public construction grammars and makes Compose a
second Router-composition abstraction beside Mount. The supposedly advanced
form already spread through more than twenty live code and documentation
locations, demonstrating that it will become canonical rather than remain an
escape hatch.

### 17.2 Flatten with `$router->routes`

**Benefit:** closest superficial spelling to `Starlette(routes=router.routes)`
and avoids an extra runtime routing layer.

**Rejection:** it silently discards Router policy and changes outcome
ownership. It is available for deliberate flattening but cannot be the
upgrade rule.

### 17.3 Let `routes` accept a Router or frontend object

**Benefit:** compact spelling such as `compose(routes => $router)`.

**Rejection:** `routes` would mean either a sequence or an application
provider, require capability guessing, and obscure whether policy is
preserved or flattened. Higher-level frameworks may offer such sugar.

### 17.4 Hide a root Mount inside Compose

**Benefit:** preserve the short `router` form while using Mount internally.

**Rejection:** routing metadata would contain a component boundary absent from
source, and Compose would still own special Router composition logic. The
Mount must be explicit.

### 17.5 Add `include_router`

**Benefit:** familiar to FastAPI users and convenient for mutable assembly.

**Rejection:** inclusion is flattening with a new name, while this problem
requires preservation. Starlette itself uses Mount rather than
`include_router`. A higher-level framework can add inclusion semantics later.

### 17.6 Put lifespan on Router and remove Compose

**Benefit:** closer to Starlette's internal placement and makes a standalone
Router a strict-lifespan root.

**Rejection for this campaign:** the placement was reviewed separately.
Compose owns PAGI root safety in addition to lifespan, while mounted Router
lifespans would remain inert. Reopening that decision is a different
architecture project and is not necessary to restore composition clarity.

### 17.7 Performance objection

An existing Router preserved at root now runs through one outer Router and one
root Mount before entering the child. This is a real but bounded cost. The
class-based form is explicitly choosing composition and preservation. Small
applications avoid it by supplying direct routes to Compose.

Do not add a compiler shortcut that erases the Mount from metadata or changes
middleware/outcome ownership merely to avoid this layer. Optimize only after
measurement and under a semantics-preserving compiler design.

## 18. Stop conditions

Pause implementation and return to design review if any task appears to
require:

- cloning or copying a Router to alter its configuration;
- copying or mutating endpoint, Response, Header, or scope objects defensively;
- a Compose-only root-Mount matcher;
- frontend-specific branches in Compose;
- arity detection or package loading;
- hidden route extraction;
- replaying request bodies or lifespan events;
- multiple HEAD boundaries with conflicting behavior;
- special reverse-routing aliases for root Mount;
- resuming parent scanning after the root Mount selected its child;
- weakening Mount's final-ownership rule;
- changing the PAGI specification or PAGI::Server; or
- several successive hacks needed to keep examples passing.

When root Mount behavior is wrong, first determine whether the general Mount
contract is defective. Fix the general rule cleanly or stop; do not accumulate
exceptions around Compose.

## 19. Implementation sequencing constraints

The later implementation plan must use test-driven steps and keep the branch
reviewable. At minimum it should separate:

1. Compose constructor/API tests and implementation;
2. root Mount preservation and inspection tests;
3. compiler and lifespan verification;
4. frontend migration;
5. live example migration;
6. public POD, tutorial, cookbook, README, upgrading, and Changes migration;
7. focused integration verification; and
8. full distribution verification and final stale-surface search.

Each task must update the campaign tracking file with status, commit SHA, real
test counts, and verification evidence in the same commit as the completed
task. Deviations receive an ID, rationale, and owner approval before later
tasks build on them.

The implementation must not rewrite the already-correct Starlette apples
example into a root-mounted temporary Router. It is the canary for the direct
`compose(routes => [...])` shape.

## 20. Completion criteria

The work is complete only when:

- Compose accepts `routes` as its sole routing input;
- Compose constructs and retains one root Router;
- `Compose->router` is documented unambiguously as an accessor, not a
  constructor mode;
- an existing Router is preserved only through explicit Mount;
- root Mount preserves all path, protocol, outcome, middleware, and reverse
  routing behavior described here;
- `$router->routes` is documented as flattening rather than preservation;
- App Router and Endpoint Router examples use explicit root Mount where they
  require Compose services;
- small declarative examples, especially Starlette apples, use direct Compose
  routes;
- all live documentation and examples have migrated;
- upgrade guidance contains complete before/after examples;
- generated README content is synchronized;
- focused tests pass;
- the full distribution test suite passes once at the final integrated HEAD;
- packaging checks pass or any pre-existing unrelated failure is recorded
  with evidence; and
- no stale positive `compose(router => ...)` usage remains outside historical
  design records and negative diagnostic tests.
