# Compose as a Retained-Router Application Facade

**Date:** 2026-08-31

**Status:** Proposed design; awaiting review before implementation planning

**Scope:** Make `PAGI::Compose` consistently own and retain exactly one
`PAGI::Routing::Router`, remove its arbitrary-application mode, expose the
Router's inspection and reverse-routing surface through Compose, and preserve
Compose as the single root lifespan and safety boundary

## 1. Decision

`PAGI::Compose` will become an application facade around one retained
`PAGI::Routing::Router`.

It will accept exactly one of:

1. `routes => \@nodes`, from which it constructs and retains a Router; or
2. `router => $router`, which retains the supplied immutable Router by
   identity.

```perl
my $app = compose(
    routes => [
        route('/' => \&home, name => 'home'),
    ],
    middleware => [middleware('RequestId')],
    lifespan => {
        startup  => \&startup,
        shutdown => \&shutdown,
    },
);
```

```perl
my $routing = router(
    routes       => \@routes,
    http_default => not_found(detail => 'No matching page'),
    desc         => 'Public routes',
);

my $app = compose(
    router     => $routing,
    middleware => [middleware('RequestId')],
    lifespan   => { startup => \&startup },
);
```

`app => $application` is removed from Compose. Compose is no longer a generic
wrapper around an arbitrary PAGI application. Native applications remain
valid server applications and valid Mount targets, but a future general
application-boundary abstraction must have its own name and contract rather
than making Compose alternate between two identities.

Compose does not inherit from Router. It owns one, exposes it through
`router`, delegates Router-facing inspection methods, and wraps its compiled
application with root middleware, lifespan, error handling, response
completion guarding, and the final HEAD boundary.

Lifespan remains configured and executed by Compose. A bare Router remains a
routing application rather than a strict-lifespan-capable application root.

This is an intentional breaking cleanup of unreleased PAGI-Tools APIs. Tests,
examples, documentation, and upgrading guidance migrate together. No
compatibility alias or hidden application-to-Mount conversion is retained.

## 2. Work map

| Repository | Work item | Execution branch | Base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | Compose retained-Router redesign | `feature/compose-retained-router` | `558b14c` (`origin/main` at execution start) | Runtime, tests, examples, public documentation, upgrading guidance, and release notes required by this design | One unreleased PAGI-Tools distribution | `origin/feature/compose-retained-router` after authorization |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI` | PAGI application and lifespan contracts | Read-only reference | Published specification | None | Normative reference only | None |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server` | Object loading and strict lifespan behavior | Read-only reference | Released server | None | Integration reference only | None |

The design was originally drafted while unrelated work was active at
`7328835`. Before implementation, `main` and `origin/main` were reconciled at
`558b14c`, including the completed buffering and disconnect-settlement
campaign. The isolated execution branch starts from that exact commit. This
specification does not authorize changes to PAGI or PAGI::Server.

The retained-Router refactor must preserve that newer baseline's event-level
contracts. In particular it must not change ResponseGuard's failed-Future
rejection for body-before-start, its abnormal-disconnect exemption, its
terminal-body and trailer requirements, or the partial-body behavior owned by
`PAGI::Middleware::BufferedResponse` and the streaming middleware built on
that contract. Those are orthogonal settlement semantics, not Compose target
selection policy.

## 3. Governing and superseded designs

Where they conflict, this design supersedes:

- the `app` versus `routes` Compose modes in the 2026-08-05 Compose design;
- sections 6, 7.4, 13, 22, and 23 of the 2026-08-26 Starlette-aligned routing
  and composition design where they describe `compose(app => ...)`, a
  temporary Router created from a stored route list, or the absence of Router
  inspection on Compose;
- examples in later designs that use `compose(app => $router)`; and
- public documentation that describes Compose as accepting an arbitrary
  native application target.

These decisions remain in force:

- Route is a complete-path leaf;
- Mount consumes a prefix and composes an application;
- Router selects ordered Route and Mount nodes and owns HTTP NONE and PARTIAL
  outcomes;
- child Router ownership is final after a matching Mount;
- routing descriptions are immutable and every `to_app` call compiles a fresh
  executable graph;
- Compose owns root middleware, lifespan, ErrorHandler, ResponseGuard, and
  the outer HEAD wire boundary;
- Router owns `http_default`, Router middleware, descriptions, matching,
  routing metadata, and reverse routing;
- Compose does not interpret routing outcomes or implement a decline trace;
- application positions accept a native three-argument coderef or an
  instantiated object with `to_app` unless a narrower position says
  otherwise;
- Route coderefs remain one-argument endpoint handlers, with `as_app` as the
  explicit bridge for a native coderef at a leaf; and
- middleware remains pure PAGI app-to-app wrapping.

## 4. Why the current shape is wrong

### 4.1 Compose has two semantic identities

Today these are both Compose objects:

```perl
compose(routes => \@routes);
compose(app => $application);
```

The first is a root routing facade in appearance but stores only an array of
nodes. The second is a generic application wrapper that knows nothing about
routing. Their accessors, available metadata, protocol behavior, and useful
configuration differ.

This is not harmless constructor convenience. It makes the meaning of the
object depend on which side of an XOR selected it.

### 4.2 Routes mode discards the object that owns routing

The current constructor builds a Router to validate `routes`, copies its route
array, and discards it. `Compose::Compiler` later constructs another Router.

Consequences include:

- no stable `router` identity;
- no Compose-level `path_for`, `named_routes`, or `route_named`;
- no retained Resolver before compilation;
- no direct access to Router `desc` or `http_default`; and
- two source shapes for the same deployed routing application.

An immutable Router already is the correct owner of these capabilities.
Compose should retain it rather than retain enough information to reconstruct
one later.

### 4.3 The compact form fails when applications become real

The small example can use:

```perl
compose(routes => [route('/' => \&home)]);
```

The larger examples need:

```perl
compose(
    app => router(
        routes       => \@routes,
        http_default => $not_found,
        desc         => 'Application routes',
    ),
    lifespan => {...},
);
```

The public API therefore teaches one form and makes users switch to another
as soon as they need a custom default, retained route metadata, Router
middleware, or construction-time reverse routing. The flagship apples
example exposes this feature cliff.

### 4.4 Generic root wrapping is a separate problem

Wrapping an arbitrary PAGI application with root ErrorHandler,
ResponseGuard, middleware, lifespan, and HEAD behavior is useful. It is not
the same abstraction as a Starlette-like application facade that owns a
Router.

Keeping both behind `compose(...)` makes the routing facade permanently
conditional. Silently expressing an arbitrary root app as
`mount('/', app => $app)` would be worse: it would introduce routing metadata,
prefix ownership, and protocol restrictions merely to reuse root wrappers.

This design removes the conflation. It does not invent the replacement before
a concrete general-boundary requirement is designed.

## 5. Starlette research and the deliberate lifespan divergence

Current Starlette does not subclass Router. `Starlette.__init__` constructs
and retains `self.router = Router(routes, lifespan=lifespan)`, exposes
`routes`, delegates `url_path_for`, and wraps the Router in application
middleware:

<https://github.com/Kludex/starlette/blob/main/starlette/applications.py>

Starlette's Router is a complete ASGI scope dispatcher. It handles HTTP,
WebSocket, and lifespan scopes, and it can be deployed directly with a
lifespan context:

<https://github.com/Kludex/starlette/blob/main/starlette/routing.py>

This placement supplies two useful properties:

1. a standalone Router can own startup and shutdown; and
2. Router middleware can observe lifespan scopes.

It does not cause nested lifecycle execution. Starlette Mount matches HTTP
and WebSocket only, so a mounted Router or Starlette application never
receives the server's root lifespan exchange. The root Router enters one
lifespan context and updates the server-provided lifespan state. Starlette's
own tests exercise standalone Router lifecycle and state behavior:

<https://github.com/Kludex/starlette/blob/main/tests/test_routing.py>

PAGI preserves the load-bearing behavior--one root lifecycle that never
cascades into mounted applications--without putting lifecycle configuration
on every Router.

The deliberate PAGI rules are:

- Compose owns the root lifespan exchange;
- Compose application middleware sees lifespan;
- the retained Router does not receive lifespan;
- Router middleware does not see lifespan;
- mounted Router and Compose applications do not run nested startup or
  shutdown callbacks; and
- lifecycle state is the server-provided state container, not state invented
  and injected independently by each nested application.

This avoids a misleading Router option that is silently inert when that
Router is mounted. It also lets this natural form retain the exact Router
identity:

```perl
compose(
    router   => $routing,
    lifespan => { startup => \&startup },
);
```

If lifespan belonged to the immutable Router, Compose would have to clone the
supplied Router, mutate it, or force lifecycle configuration into a nested
Router constructor. All three are worse than keeping root lifecycle on the
root facade.

The cost is explicit: a bare Router cannot configure lifespan and is not a
valid strict-lifespan deployment root. A user needing lifecycle wraps it in
Compose. Under an automatic lifespan server, an unconfigured bare Router may
decline lifespan according to the PAGI specification; strict mode treats that
decline as startup failure.

## 6. Conceptual model

```text
Compose
  retained Router identity
  root middleware
  lifespan
  ErrorHandler
  ResponseGuard
  outer HEAD boundary
  |
  v
Router
  ordered selection
  routing metadata and Resolver
  HTTP NONE default
  PARTIAL 405 + authoritative Allow
  Router middleware
  |
  +-- Route ----- exact leaf + methods + endpoint
  |
  `-- Mount ----- consumed prefix + child application
```

Compose is not a routing node and does not implement Route, Mount, or Router's
node-inspection protocol. It is an application facade that delegates selected
Router-facing operations.

## 7. Public Compose API

### 7.1 Functional and object construction

These remain equivalent:

```perl
my $app = compose(%options);
my $app = PAGI::Compose->new(%options);
```

Nothing is exported by default. `compose` remains an explicit export and part
of `:ALL`.

### 7.2 Exact constructor options

| Option | Routes form | Router form | Meaning |
| --- | --- | --- | --- |
| `routes` | required | forbidden | Ordered Route and Mount nodes |
| `router` | forbidden | required | Retained immutable Router instance |
| `http_default` | optional | forbidden | Passed to the Router constructed from `routes` |
| `desc` | optional | forbidden | Passed to the Router constructed from `routes` |
| `middleware` | optional | optional | Application-wide Compose middleware |
| `lifespan` | optional | optional | Root startup and shutdown callbacks |

Exactly one of `routes` and `router` is required.

`routes` must be an arrayref valid for `PAGI::Routing::Router`. The constructed
Router performs the existing shallow route-list copy and full Resolver
validation. Compose stores that Router, not another route array.

`router` must be an instantiated `PAGI::Routing::Router` object. A native
coderef, package name, arbitrary `to_app` object, `PAGI::App::Router`, or
`PAGI::Endpoint::Router` is rejected. Mutable and method-oriented frontends
cross the boundary explicitly:

```perl
compose(router => $builder->to_router);
compose(router => $endpoint_router->to_router);
```

In Router form, `http_default` and `desc` are forbidden even when explicitly
set to `undef`. The retained Router is authoritative; Compose never overlays
or reconstructs it.

Compose `middleware` remains application middleware. It is not passed into
the Router. A caller needing Router middleware constructs a Router and uses
`router => $router`:

```perl
my $routing = router(
    routes     => \@routes,
    middleware => [middleware(\&observe_selected_route)],
);

my $app = compose(
    router     => $routing,
    middleware => [middleware('RequestId')],
);
```

No `router_middleware` alias is added to Compose.

### 7.3 Removed constructor option

`app` is no longer a Compose option:

```perl
# Rejected
compose(app => $native_app);
compose(app => $router);
```

The diagnostic must name the replacement when the value is a Router:

```text
compose no longer accepts 'app'; pass a PAGI::Routing::Router with
router => $router, or deploy a non-routing PAGI application directly
```

No arity inspection, `to_app` capability guessing, package loading, or hidden
Mount is performed.

## 8. Compose accessors and delegation

Compose exposes:

| Method | Contract |
| --- | --- |
| `router` | Returns the retained Router by identity |
| `routes` | Delegates to `router->routes` and returns its shallow copy |
| `http_default` | Delegates to `router->http_default` |
| `desc` | Delegates to `router->desc` |
| `middleware` | Returns a shallow copy of Compose application middleware |
| `lifespan` | Returns the existing shallow callback-hash copy or `undef` |
| `named_routes` | Delegates to `router->named_routes` |
| `route_named` | Delegates to `router->route_named` |
| `path_for` | Delegates to `router->path_for` |
| `to_app` | Compiles the complete deployed application boundary |

The current `app` accessor is removed. There is no conditional `router`
accessor and no accessor returns `undef` because Compose happens to be in a
different target mode.

`path_for` remains application-relative and performs no protocol I/O.
Request-aware relative lookup and absolute URL construction remain in
`PAGI::Routing::URL`; Compose does not acquire `url_for` merely because it
retains the Router.

Compose does not duplicate Resolver data. All delegated operations use the
Resolver already owned by the retained Router.

## 9. Construction and compilation lifecycle

### 9.1 Routes form

Construction performs exactly one Router construction:

```perl
my $router = PAGI::Routing::Router->new(
    routes => $routes,
    (exists $opts{http_default}
        ? (http_default => $opts{http_default}) : ()),
    (exists $opts{desc}
        ? (desc => $opts{desc}) : ()),
);
```

The pseudocode expresses ownership, not required implementation syntax.
Compose does not construct one Router for validation and another for use.

### 9.2 Router form

Compose validates the supplied object once and stores its exact identity. It
does not call `to_app` during construction.

### 9.3 `to_app`

Each Compose `to_app` call:

1. invokes `to_app` once on the retained Router;
2. receives one freshly compiled native routing application;
3. builds one fresh Compose middleware and safety graph around it; and
4. returns the resulting native PAGI coderef.

Requests reuse that compiled graph. Router compilation never occurs per
request.

Calling Compose `to_app` twice creates two independent executable middleware
graphs around the same immutable Router description and Resolver. The Router
object's identity and declarations remain stable; runtime middleware
instances, counters, and request state are not shared unless their own
configuration deliberately shares them.

No cloning, hidden cache, dynamic Router reconstruction, or mutation snapshot
is introduced.

## 10. Runtime ownership and middleware order

The existing HTTP order remains:

```text
Compose HEAD wire boundary
  Compose emergency ErrorHandler
    Compose ResponseGuard
      first Compose middleware (outermost author middleware)
        remaining Compose middleware
          Router public application boundary
            Router middleware
              Mount middleware
                child Router middleware
                  Route middleware
                    endpoint
```

Router-generated 404 and 405 responses unwind through Router middleware and
then Compose middleware. Selected endpoint responses and exceptions follow
the same outer Compose boundary.

The shared HEAD marker remains an implementation detail making the retained
Router's standalone HEAD boundary idempotent under Compose's outer boundary.
This redesign does not restructure the proven HEAD implementation merely to
remove an internal no-op. Any later simplification requires its own evidence
that direct Router and Compose deployments preserve identical GET-derived
headers and suppress body, file, and trailer events correctly.

Compose continues to install ErrorHandler and ResponseGuard only for HTTP.
WebSocket, SSE, and lifespan retain their existing protocol behavior.

## 11. Lifespan contract

### 11.1 Root-only ownership

Compose consumes every lifespan scope before the retained Router is invoked.
The Router receives HTTP, WebSocket, and SSE scopes only.

With no configured callbacks, Compose still completes a valid startup and
shutdown exchange. With callbacks, it requires the existing verified
server-provided state hash and runs:

```text
receive lifespan.startup
  run and await startup callback
  send lifespan.startup.complete
receive lifespan.shutdown
  run and await shutdown callback
  send lifespan.shutdown.complete
```

Startup or shutdown failure retains the existing failed-event and propagation
contract. This design does not change callback arguments, state proof,
Future normalization, environment handling, or error text except where a
test must stop referring to Compose app mode.

### 11.2 Middleware visibility

Compose application middleware wraps the lifespan dispatcher and therefore
sees lifespan scopes. Router, Mount, and Route middleware do not.

Protocol-specific application middleware must continue passing unrelated
scope types through. A middleware that elects to participate in lifespan must
obey the PAGI lifespan event contract.

### 11.3 Nested applications

A mounted Router never receives root lifespan. A mounted Compose object is a
PAGI application value but does not receive lifespan through Mount, so its
callbacks do not run. Documentation should discourage mounting Compose when a
Router or ordinary application is the intended reusable component:

```perl
# Preferred reusable routing component
mount('/admin', app => MyApp::Admin->routing);

# Valid application composition, but nested Compose lifespan does not run
mount('/admin', app => MyApp::Admin->composed_app);
```

Reusable components consume resources placed in server state by the one root
Compose lifecycle or accept resources explicitly at construction.

### 11.4 Direct Router deployment

A bare Router continues to decline lifespan. It may be used directly where:

- the server's lifespan mode is automatic and a decline is acceptable; or
- no lifecycle exchange is performed.

It is not a valid strict-lifespan root. The documented deployment for a
Router requiring startup or shutdown is Compose:

```perl
compose(
    router   => $router,
    lifespan => {
        startup  => \&startup,
        shutdown => \&shutdown,
    },
);
```

No `lifespan` option is added to Router in this work.

## 12. Router construction options in routes form

`http_default` and `desc` are the only Router-owned options flattened onto
Compose's routes form.

They exist because they are common root declarations and because omitting
them recreates the current feature cliff:

```perl
compose(
    routes       => \@routes,
    http_default => not_found(detail => 'No matching page'),
    desc         => 'Public application',
);
```

Router middleware is deliberately not flattened. Compose middleware and
Router middleware occupy different runtime boundaries, and one `middleware`
option must not change meaning depending on another option. Authors needing
the inner Router boundary construct it explicitly.

Schema/OpenAPI metadata, slash redirects, exception handlers, route mutation,
host routing, and other Starlette constructor options are not added here.

## 13. `PAGI::App::Router` and other frontends

`PAGI::App::Router` remains a mutable declaration frontend for the immutable
Router. Its `to_router` behavior does not change.

Its `to_app` continues to mean “compile a bare Router application,” not
“construct a Compose root.” This distinction must be prominent:

```perl
my $routing_app = $builder->to_app;  # no Compose safety or lifespan

my $root = compose(
    router   => $builder->to_router,
    lifespan => {...},
);
```

`PAGI::Endpoint::Router` follows the same explicit boundary through
`to_router`. No frontend is admitted to `router =>` merely because it has
`to_app`, `routes`, or a similarly named method.

This prevents Compose from becoming a materializer registry and keeps
frontend conversion under the frontend's control.

## 14. Arbitrary PAGI applications after removal of app mode

An arbitrary PAGI application remains directly deployable:

```perl
my $app = async sub ($scope, $receive, $send) {
    ...
};

# Give $app directly to a conforming PAGI server.
```

An instantiated object with `to_app` likewise remains directly deployable.
Mount and other native application positions continue accepting both forms.

This design does not claim that direct deployment supplies Compose's private
ErrorHandler, ResponseGuard, HEAD boundary, or lifecycle callbacks. Those are
Compose root features for the retained routing application.

If a future MCP or other custom-scope application needs a generic root safety
and lifecycle wrapper, that is a real requirement for a separately named
application-boundary abstraction. This design deliberately does not route an
unknown protocol through an HTTP/WebSocket/SSE Router, infer a target from
coderef arity, or preserve `compose(app => ...)` as an undocumented escape
hatch.

`PAGI::Lifespan` remains an independent existing component and is not removed,
endorsed as a complete Compose replacement, or redesigned by this work.

## 15. Flagship apples application

The current ending:

```perl
compose(
    app => router(
        routes => [
            route('/' => file_response($manager_file, inline => 1),
                name => 'home'),
            route('/welcome' => welcome(),
                name => 'welcome'),
            mount('/apples',
                routes => [
                    route('/' => \&list_apples,
                        methods => ['GET'], name => 'list'),
                    route('/' => \&create_apple,
                        methods => ['POST'], name => 'create'),
                    route('/{apple_id:&Int}' => \&read_apple,
                        methods => ['GET'], name => 'read'),
                ],
                name       => 'apples',
                middleware => [middleware(\&with_apples_api_header)],
            ),
        ],
        http_default => not_found(
            detail => 'That page does not exist in the Apple demo.',
        ),
    ),
    middleware => [middleware('RequestId')],
    lifespan   => { startup => \&startup },
);
```

becomes:

```perl
compose(
    routes => [
        route('/' => file_response($manager_file, inline => 1),
            name => 'home'),
        route('/welcome' => welcome(),
            name => 'welcome'),
        mount('/apples',
            routes => [
                route('/' => \&list_apples,
                    methods => ['GET'], name => 'list'),
                route('/' => \&create_apple,
                    methods => ['POST'], name => 'create'),
                route('/{apple_id:&Int}' => \&read_apple,
                    methods => ['GET'], name => 'read'),
            ],
            name       => 'apples',
            middleware => [middleware(\&with_apples_api_header)],
        ),
    ],
    http_default => not_found(
        detail => 'That page does not exist in the Apple demo.',
    ),
    middleware => [middleware('RequestId')],
    lifespan   => { startup => \&startup },
    desc       => 'Starlette apples comparison application',
);
```

The route tree is once again a direct property of the application facade, as
in Starlette. PAGI retains explicit response factories, middleware
descriptions, Type::Tiny constraints, first-class SSE, and its own reverse
addressing rules.

The README's Starlette source remains unchanged as a comparison artifact. Its
commentary must explain that Starlette stores the lifespan context on its
Router while PAGI Compose owns the root exchange deliberately.

## 16. Large application shape

Component packages continue returning Routers:

```perl
sub routing($class) {
    return router(
        routes => [
            route('/' => \&home, name => 'home'),
            mount('/person',
                app  => MyApp::Person->routing,
                name => 'person'),
        ],
        http_default => not_found(detail => 'No root route matched'),
        desc         => 'MyApp root routes',
    );
}

sub to_app($class) {
    return compose(
        router   => $class->routing,
        lifespan => {
            startup  => \&startup,
            shutdown => \&shutdown,
        },
    );
}
```

There is no need for a package to return both a route list and a Router.
Packages that want reusable route metadata return the Router. Small single-file
applications may use Compose's `routes` form directly.

## 17. Validation and diagnostics

Construction fails synchronously for:

- an odd option list;
- an unknown option;
- neither or both of `routes` and `router`;
- a non-arrayref `routes` value;
- an invalid route-list member;
- a non-Router `router` value;
- `http_default` or `desc` in Router form;
- a malformed `http_default`, description, middleware list, or lifespan
  declaration; and
- the removed `app` option.

Diagnostics identify the placement and remedy. At minimum:

```text
compose requires exactly one of routes or router
compose router must be an instantiated PAGI::Routing::Router
compose http_default cannot be combined with router; configure the retained Router
compose desc cannot be combined with router; configure the retained Router
compose no longer accepts 'app'; use router => $router or deploy the PAGI app directly
```

No diagnostic suggests converting an arbitrary application into a root Mount.

## 18. Documentation and migration

### 18.1 Mandatory whole-repository implementation scope

This is not a `PAGI::Compose`-only edit. Implementation owns every live
PAGI-Tools consequence of the contract change. The campaign must update all
code, examples, documentation, and tests needed to leave the repository on
one coherent API. An implementer must not retain an obsolete spelling because
the file is “only an example,” “only POD,” or outside the focused Compose test
directory.

The owned runtime surface includes at least:

- `lib/PAGI/Compose.pm`;
- `lib/PAGI/Compose/Compiler.pm`;
- Router compilation or shared utilities where needed to compile the retained
  Router without reconstructing it;
- `PAGI::App::Router` and `PAGI::Endpoint::Router` integration points;
- application components whose POD or code constructs a Compose root,
  including Cascade and ErrorHandler examples; and
- any loader, test client, or helper whose assumptions about Compose target
  modes fail under the new contract.

The owned test surface includes the complete `t/compose/` family plus every
integration, frontend, upgrading, POD-example, and application-boundary test
affected by the removed `app` form or new delegated Router surface. Existing
tests are rewritten to assert the new behavior; they are not weakened,
skipped, or left testing an unavailable compatibility path merely to keep the
suite green.

The owned example surface is every live application under `examples/`, not
only examples currently found by a textual `compose(app => ...)` search. At a
minimum the implementation must inspect and update:

- `starlette-apples`;
- `15-large-application`;
- `compose`;
- `declarative-routing`;
- `endpoint-demo` and `endpoint-router-demo`;
- `pages`;
- `process-streaming`;
- `background-tasks`;
- `full-demo`; and
- both chat examples and their library modules.

For each example, its application file, supporting packages, README, launch
command, and focused tests must agree. The apples example remains the primary
readability canary, but passing that one example is not completion.

The owned documentation surface includes public module POD, Tutorial,
Cookbook, top-level README material where relevant, `UPGRADING.md`, and
`Changes`. Documentation examples must be executable or covered by the
existing POD-example validation where practical. Historical design and plan
documents under `docs/superpowers/` remain historical records and are not
mechanically rewritten; this specification's supersession section records
which earlier decisions are no longer governing.

Any additional live file discovered by compilation, tests, POD validation, or
repository search is in scope when changing it is necessary to make the new
contract truthful. This permission does not extend to unrelated cleanup.

### 18.2 Public documentation changes

Update:

- `PAGI::Compose` POD;
- `PAGI::Routing` and `PAGI::Routing::Router` cross-links;
- `PAGI::App::Router` and `PAGI::Endpoint::Router` root-deployment examples;
- `PAGI::Tools`, Tutorial, and Cookbook documentation;
- `UPGRADING.md`;
- all examples under `examples/`, especially `starlette-apples`,
  `15-large-application`, `endpoint-router-demo`, `full-demo`,
  `background-tasks`, `pages`, `declarative-routing`, and chat examples; and
- tests and inline comments referring to Compose routes mode as temporary
  Router reconstruction or Compose app mode.

The upgrading guide includes at least:

```perl
# Before: Router hidden in generic app mode
compose(app => $router);

# After
compose(router => $router);
```

```perl
# Before: mutable frontend treated as a generic app
compose(app => $builder);

# After: explicit immutable routing boundary
compose(router => $builder->to_router);
```

```perl
# Before: generic native app with Compose safety
compose(app => $native_app, lifespan => {...});

# After
# No direct Compose equivalent. Deploy the app directly or choose an explicitly
# designed native boundary; do not hide it under a root Mount.
```

The guide must call out that bare Router deployment declines lifespan and is
incompatible with strict lifespan mode.

### 18.3 Final migration searches

Before completion, search the live distribution surface--`lib/`, `t/`,
`examples/`, `README.md`, `UPGRADING.md`, and `Changes`--for:

- `compose(app =>` across ordinary and multiline formatting;
- claims that Compose accepts an arbitrary application;
- claims that routes mode stores or reconstructs a temporary Router;
- conditionally absent Compose `app` or `router` accessors;
- deployment examples that pass a mutable or Endpoint frontend directly
  instead of crossing `to_router`; and
- lifespan documentation implying that mounted Router or Compose callbacks
  run automatically.

Remaining matches must be limited to explicit before/after migration prose or
negative tests. The implementation report records each intentional match.

## 19. Test requirements

The implementation plan must cover these outcomes without reproducing every
assertion here as a task list:

1. routes form constructs and retains one Router;
2. router form preserves exact Router identity and defers `to_app`;
3. all delegated accessors use the retained Router Resolver;
4. two Compose `to_app` calls create fresh executable graphs while retaining
   one immutable Router identity;
5. routes-form `http_default` and `desc` reach that Router;
6. router form rejects Compose overrides;
7. `app` and arbitrary `to_app` objects are rejected by Compose;
8. application middleware, Router middleware, Mount middleware, and Route
   middleware preserve their documented order;
9. Router 404, authoritative 405/Allow, selected responses, exceptions,
   incomplete responses, and HEAD behavior remain unchanged under Compose;
10. HTTP, WebSocket, and SSE routing remain unchanged;
11. no-hook, startup, shutdown, failure, state-proof, and concurrent lifespan
    behavior remain unchanged;
12. Compose middleware sees lifespan while Router middleware does not;
13. mounted Router and Compose callbacks do not run nested lifespan;
14. direct Router lifespan decline is documented and tested against the
    relevant Test Client/server mode;
15. App Router and Endpoint Router examples cross `to_router` explicitly;
16. every migrated example loads and its focused integration tests pass;
17. the apples SPA/API and large application link generation still work; and
18. a final repository search finds no live `compose(app => ...)` outside
    migration documentation and negative tests.

Tests for Compose's ErrorHandler and ResponseGuard must route to selected
silent or throwing applications through the retained Router. They must not
retain arbitrary app mode merely to make those tests convenient.

## 20. Adversarial findings and accepted trade-offs

### 20.1 Why not subclass Router?

Current Starlette does not do so, and PAGI Compose has root-only behavior that
does not belong on a reusable routing collection. Inheritance would imply that
Compose itself is a mountable routing node and should expose every Router
mutation or node accessor. Ownership and delegation express the real
relationship.

### 20.2 Why not add lifespan to Router?

It would make standalone Router roots more capable, but it would also put
silent lifecycle configuration on mounted Routers and complicate exact
retention in `compose(router => $router, lifespan => ...)`. One explicit root
owner is easier to reason about in Perl and preserves Starlette's actual
non-cascading lifecycle behavior.

### 20.3 Why flatten `http_default` and `desc`, but not middleware?

The first two describe the root Router and have no competing Compose meaning.
`middleware` already names a distinct application-wide boundary. Reusing that
key for Router middleware would make runtime placement depend on constructor
mode. The explicit Router form handles the less common inner boundary.

### 20.4 Why retain both `routes` and `router`?

Both normalize to one known type and one stable semantic identity. `routes`
is the concise application form; `router` preserves modular construction,
custom Router policy, and inspection identity. This differs from the removed
`routes`/`app` split, whose branches represented different abstractions and
different protocol capabilities.

### 20.5 Custom protocols become less convenient

Removing arbitrary app mode means Compose no longer wraps an MCP or other
custom-scope root application. This is deliberate narrowing, not an accidental
omission. Routing currently recognizes HTTP, WebSocket, and SSE; forcing a
custom protocol through it would be incorrect. A future generic application
boundary should be designed from the custom protocol's actual lifecycle,
error, and completion requirements.

### 20.6 Compose remains optional

A Router can still be compiled directly. A native PAGI app can still be
deployed directly. Compose is the conventional routed application root, not a
mandatory base class or universal wrapper.

## 21. Non-goals

This work does not add:

- Router inheritance;
- Router lifespan callbacks;
- a generic replacement for Compose app mode;
- schema/OpenAPI support;
- slash redirects;
- exception-driven 404 or 405 control flow;
- application or Router mutation after construction;
- package-name application loading;
- automatic frontend materialization;
- custom-protocol routing;
- nested lifecycle aggregation;
- a `router_middleware` Compose option; or
- compatibility aliases for `app`.

## 22. Acceptance criteria

The redesign is complete when:

- every Compose owns one retained immutable Router;
- `routes` and `router` are the only mutually exclusive target forms;
- `compose(app => ...)` is absent from live library, example, and test code;
- routes form supports the common root Router options without nested
  `app => router(...)` ceremony;
- router form retains exact identity and all reverse-routing metadata;
- Compose delegates the documented Router inspection surface;
- root lifespan, middleware, ErrorHandler, ResponseGuard, and HEAD behavior
  remain intact;
- bare and mounted Router lifespan behavior is explicit and tested;
- no hidden cloning, caching, Mount conversion, or target inference is used;
- all examples use the new shape, with the apples example as the primary
  readability canary;
- the upgrading guide is sufficient for current GitHub users; and
- focused and full distribution tests pass.

The public documentation should end with one stable summary:

> Route matches a complete URL leaf. Mount composes an application under a
> prefix. Router selects and owns routing outcomes. Compose owns one Router and
> adds the application root, lifespan, and safety boundaries.
