# PAGI Compose

**Date:** 2026-08-05
**Status:** Approved
**Scope:** An optional Starlette-inspired top-level composition object for one
PAGI request target, application-wide middleware, and lifespan callbacks

## 1. Summary

PAGI-Tools will add `PAGI::Compose`, an optional high-level constructor that
combines one request target, application-wide pure PAGI middleware, and one
explicit startup/shutdown pair. The canonical functional constructor is
`compose(...)`; the equivalent object form is `PAGI::Compose->new(...)`. Both
return the same immutable description, and `to_app` remains the explicit
boundary that compiles it into a native PAGI coderef.

The common form accepts a declarative route list:

```perl
use Future::AsyncAwait;
use PAGI::Compose qw(compose);
use PAGI::Routing qw(:ALL);

my $composition = compose(
    routes => [
        route('/' => \&home),
    ],

    middleware => [
        middleware('PAGI::Middleware::RequestId'),
    ],

    lifespan => {
        startup => async sub {
            my ($state, $scope) = @_;
            $state->{db} = await connect_db();
        },

        shutdown => async sub {
            my ($state, $scope) = @_;
            await $state->{db}->disconnect;
        },
    },
);

my $app = $composition->to_app;
```

An existing router, component, class, or native PAGI coderef can instead be
the request target:

```perl
my $app = compose(
    app => $existing_component,
    middleware => [
        middleware('PAGI::Middleware::RequestId'),
    ],
)->to_app;
```

`routes` and `app` are mutually exclusive. `compose` owns lifespan and never
passes lifespan scopes to the configured request target. Application
middleware surrounds both request dispatch and the entire lifespan event
loop. One final HEAD wire boundary sits outside that middleware so every
middleware layer sees the complete representation before response-body events
are suppressed.

## 2. Why this is a separate optional abstraction

The declarative router intentionally does not own lifespan or
application-wide policy. Conversely, the new abstraction should not become a
base class for everything below `PAGI::App::*` or claim to be the central
application ontology of PAGI. `PAGI::App` and `PAGI::Application` were rejected
as names for those reasons.

`PAGI::Compose` describes the narrower operation being offered: combining an
already meaningful request target with outer middleware and lifecycle policy.
It is additive. Users remain free to return a router's `to_app`, use
`PAGI::Lifespan`, compose middleware manually, or write a native PAGI coderef.

The design is inspired by Starlette's compact top-level combination of routes,
middleware, and lifespan, but it follows the existing PAGI-Tools conventions:

- functional constructors return immutable descriptions;
- native PAGI coderefs appear only after `to_app`;
- middleware is strictly app-to-app event middleware;
- synchronous and Future-backed completion are both normalized explicitly;
- routing-specific fallback behavior remains on the router that owns it.

## 3. Goals

- Make a complete small PAGI application pleasant to declare in one place.
- Keep `compose(...)` an optional convenience rather than a framework base
  class or mutable application registry.
- Support both declarative route lists and existing PAGI components.
- Put startup and shutdown at the true application root rather than on a
  router.
- Give application middleware visibility into HTTP, WebSocket, SSE, lifespan,
  and extension scopes.
- Preserve correct HEAD representation headers by suppressing the body only at
  the final wire boundary.
- Follow the PAGI lifespan protocol, including server-owned state propagation
  and explicit startup/shutdown failure messages.
- Validate configuration before request I/O and compile dependencies once per
  `to_app` call.
- Keep the object immutable and safe to compile more than once.
- Document the lifecycle ownership rule for nested and mounted applications.

## 4. Non-goals and deferred work

The first release will not:

- Add or repurpose a `PAGI::App` base class.
- Add a central `PAGI::Application` abstraction.
- Replace, deprecate, or silently change `PAGI::Lifespan`,
  `PAGI::Utils::handle_lifespan`, or their existing nesting behavior.
- Change the PAGI lifespan specification or make server state support
  mandatory for native PAGI applications generally.
- Pass lifespan events to the configured `app` target or automatically run
  lifespan callbacks belonging to mounted/nested applications.
- Add mutable route, middleware, startup, shutdown, or exception registration
  methods.
- Add application decorators, coderef overloads, implicit `to_app` calls per
  request, or a value-flow `$next` middleware tier.
- Add `debug`, exception-handler maps, HTTP exception classes, redirect-slash
  policy, automatic `OPTIONS`, server configuration, or worker-pool APIs.
- Add shortcut HTTP status helpers such as 401, 404, or 500 responses.
- Duplicate reverse-routing methods on the composition object.
- Change `PAGI::Middleware::Head` from its shipped explicit HEAD-to-GET
  rewriting behavior.

The ownership and shape of router-level `not_found` and
`method_not_allowed` remain an explicit deferred design question. They stay on
`router(...)` for this work. `compose(...)` does not duplicate them.

## 5. Public module and exports

The functional API lives in `PAGI::Compose`:

```perl
use PAGI::Compose qw(compose);
```

Nothing is exported by default. `compose` is available through `@EXPORT_OK`.
For consistency with `PAGI::Routing`, uppercase `:ALL` also exports every
public constructor (currently only `compose`); lowercase `:all` is not an
alias.

The function is a thin constructor:

```perl
sub compose {
    return PAGI::Compose->new(@_);
}
```

The object has no `&{}` overload. The two supported spellings are equivalent:

```perl
my $one = compose(%options);
my $two = PAGI::Compose->new(%options);
```

## 6. Constructor contract

The constructor accepts exactly four top-level keys:

```perl
compose(
    routes     => \@routing_nodes,     # mutually exclusive with app
    app        => $component,          # mutually exclusive with routes
    middleware => \@descriptors,       # optional; defaults to []
    lifespan   => {                     # optional
        startup  => $coderef,           # either callback may be omitted
        shutdown => $coderef,
    },
);
```

Exactly one of `routes` or `app` is required. An intentionally empty
route-based application spells that intent as `routes => []`; omission is
treated as a configuration error rather than an implicit empty router.

### 6.1 `routes`

`routes` must be an arrayref accepted by `PAGI::Routing::Router->new`. Its
elements are the immutable values returned by `route`, `websocket`, `sse`, and
`mount`. Construction shallow-copies the list and performs the same structural
validation as a root declarative router.

In routes mode, `to_app` constructs/compiles a fresh root declarative router
from that stored route list. Router defaults, including its current default
404 and 405 behavior, remain router-owned.

`compose` does not accept `not_found`, `method_not_allowed`, `desc`, route
constraints, or router middleware as top-level options. A caller that needs
those controls constructs the router explicitly:

```perl
my $routing = router(
    routes             => \@routes,
    not_found          => \&not_found,
    method_not_allowed => \&method_not_allowed,
    desc               => 'Public API',
);

my $composition = compose(app => $routing);
```

### 6.2 `app`

`app` accepts the same component forms as `PAGI::Utils::to_app`: a native
coderef, an object with `to_app`, or a loadable class with `to_app`. A supplied
coderef is a native three-channel PAGI application, not a one-argument Context
handler. Component coercion and class loading occur once during each `to_app`
compilation, not per request.

The value must be defined. Construction rejects reference kinds that cannot be
components; final object capability and class loading are validated at the
`to_app` boundary so construction itself performs no dynamic loading.

The configured app is a request/connection target. It receives every
non-lifespan scope unchanged apart from ordinary outer middleware scope
transformation and the private HEAD-boundary marker. It never receives the
lifespan scope owned by `compose`.

### 6.3 `middleware`

`middleware` defaults to an empty arrayref. Every element must be a
`PAGI::Routing::Middleware` description returned by the existing
`middleware(...)` helper. The list is shallow-copied at construction.

This is application middleware, not root-router middleware. It sees all scope
types and surrounds generated routing outcomes. A caller that specifically
needs router middleware can use `app => router(middleware => [...], ...)`.

### 6.4 `lifespan`

`lifespan` is optional. When present it must be a hashref with at least one of
the exact keys `startup` and `shutdown`; each present value must be a coderef.
An empty hashref, unknown keys, non-hash value, or non-coderef callback is a
construction error. The top-level hash is shallow-copied.

The callbacks remain distinct, but grouping them under `lifespan` keeps the
top-level composition surface to three concepts: target, surrounding
middleware, and lifecycle.

## 7. Immutability and inspection

`PAGI::Compose` stores configuration only. It never stores a request scope,
server-provided state, lifecycle phase, middleware instance, compiled target,
or response event on the source object.

Public accessors return the declared values:

- `routes` returns a shallow arrayref copy in routes mode and `undef` in app
  mode.
- `app` returns the original component in app mode and `undef` in routes mode.
- `middleware` returns a shallow arrayref copy.
- `lifespan` returns a shallow hashref copy or `undef`.

The first release deliberately does not delegate `path_for`, `route_named`, or
other target-specific methods. A caller needing router inspection retains an
explicit router and passes it through `app` as shown above. This avoids a
partial API whose capabilities change according to the target type.

`to_app` may be called repeatedly. Each call creates fresh middleware
instances and lifecycle bookkeeping and calls a component target's `to_app`
again. A native coderef and the configured callback coderefs cannot be cloned;
lexicals intentionally captured by those coderefs retain normal Perl sharing
semantics.

## 8. Compilation model

`to_app` is a synchronous build boundary. It performs no request or lifespan
I/O. It:

1. Compiles a fresh root router in routes mode, or resolves the configured
   component once with `PAGI::Utils::to_app` in app mode.
2. Builds the compose dispatcher that owns lifespan and delegates all other
   scope types to the target.
3. Wraps that dispatcher in the declared application middleware, in list
   order.
4. Returns a final native PAGI coderef that records server-provided lifespan
   state provenance and establishes the shared HEAD wire boundary before
   invoking the middleware stack.

Any target-coercion, class-loading, middleware-factory, or middleware-wrap
failure aborts `to_app` synchronously. The returned application does not retry
compilation on a later request.

The first listed application middleware is outermost:

```perl
middleware => [
    middleware('RequestId'),
    middleware('ErrorHandler'),
],
```

has this application-call order:

```text
HEAD wire boundary
  RequestId
    ErrorHandler
      compose dispatcher
        lifespan driver
        or request target
```

On the response/send path, events travel back through the inverse middleware
order and reach the HEAD boundary last.

## 9. Dispatch and protocol ownership

The compose dispatcher reserves only a scope whose `type` is `lifespan`. Every
other scope is delegated to the compiled target. `compose` itself does not
restrict delegated types to HTTP, WebSocket, and SSE; an app-mode component may
support a future or application-defined PAGI protocol. A routes-mode target
retains the declarative router's own supported-type checks.

The target's return is normalized with `Future->wrap`, so both immediate and
Future-backed native app completion work. Its return value is ignored. Event
I/O remains the native PAGI result channel.

The target never receives lifespan scope or events. This single-owner rule
prevents two applications from consuming the same lifecycle receive stream or
sending duplicate completion events.

Consequently, only the outermost `compose` in a deployed application owns
lifecycle. Passing one composition as another composition's `app`, or mounting
a composition below a router, is valid for request dispatch but does not run
the inner or mounted composition's callbacks. Applications must lift required
resource initialization into the root composition. This is a documented
convention, not automatic route-tree discovery.

## 10. Application middleware semantics

Application middleware is the existing pure PAGI app-to-app contract. No
request-time value-flow `$next` abstraction is introduced.

Middleware sees lifespan and every delegated scope. It may shallow-clone and
modify scope, wrap receive, wrap send, short-circuit, or deliberately own a
scope according to the PAGI middleware specification. In particular:

- Scope changes made by middleware are visible to lifecycle callbacks and the
  configured target.
- Receive wrappers affect the lifespan events consumed by the compose driver.
- Send wrappers see startup/shutdown completion and failure events.
- A middleware that does not call its inner application owns that scope; if it
  does so for lifespan, compose callbacks do not run.
- Protocol-specific middleware must pass unrelated scope types through.
- Middleware exceptions are not reclassified as callback failures by
  `compose`; they follow ordinary PAGI middleware exception behavior.

At the outer application boundary, compose records whether the original
server-provided lifespan scope contains a valid state hashref and, when it
does, records that reference's identity under an unforgeable private marker on
a shallow scope clone. The inner lifespan driver validates that provenance
after middleware has run. Ordinary shallow-cloning middleware preserves both
the private marker and the state reference.

Middleware may mutate the server-provided state hash, but it may not fabricate
state when the server omitted it or replace the state reference. Adding or
replacing the key would create a disconnected hash the server will not
shallow-copy into requests. Dropping the private marker is likewise invalid;
middleware must preserve unknown scope keys when cloning. A middleware that
fully owns lifespan without calling inward remains responsible for its own
state behavior and never reaches this validation.

## 11. Lifespan callback contract

Both callbacks receive:

```perl
my ($state, $scope) = @_;
```

`$state` is the exact hashref in the middleware-adjusted lifespan scope.
`$scope` is that same raw scope and is the explicit advanced escape hatch for
PAGI/spec version data, worker identity, and extensions. Most callbacks need
only `$state`.

Callback return values are ignored. The driver normalizes both immediate and
Future-backed completion:

```perl
my $returned = $callback->($state, $scope);
await Future->wrap($returned);
```

This normalization is required for plain `sub` callbacks that return `undef`
as well as `async sub` callbacks that return a Future.

### 11.1 Server-owned state

The PAGI lifespan specification makes `scope->{state}` an optional namespace
provided by the server. When supported, the server shallow-copies it into
subsequent request scopes. `compose` does not create a fallback state hash and
does not inject or copy state into request scopes.

When a `lifespan` option is configured, the high-level compose contract
requires state support. On `lifespan.startup`, after application middleware,
the driver verifies all of the following:

- the original server scope supplied an unblessed state hashref;
- the private provenance marker survived middleware scope cloning; and
- the current `scope->{state}` is the identical hashref supplied by the
  server.

If any check fails, the driver does not call either configured callback. It
sends:

```perl
{
    type    => 'lifespan.startup.failed',
    message => 'PAGI::Compose lifespan requires server state support',
}
```

and returns.

This avoids repetitive callback checks, Perl autovivification of a local undef
argument into a disconnected hash, and unsafe private state shared across
multiple worker/event-loop lifespans. The deliberate cost is that even a
stateless configured callback requires server state. Native PAGI applications
remain free to implement optional-state lifespan behavior themselves.

When no `lifespan` option is configured, no state support is required. The
compose driver still answers normal startup and shutdown events successfully,
making a no-hook composition uniformly lifespan-capable.

### 11.2 Startup

On `lifespan.startup`:

1. Validate state support when callbacks were configured.
2. Invoke `startup` if present and await its normalized completion.
3. On success, send `lifespan.startup.complete`.
4. If the callback throws synchronously or its Future fails, send
   `lifespan.startup.failed` with the exception text and return.

A startup failure does not run `shutdown`; a callback that allocates several
resources before failing remains responsible for cleaning up its own partial
startup.

### 11.3 Shutdown

After successful startup, the driver continues awaiting lifecycle events. On
`lifespan.shutdown`:

1. Invoke `shutdown` if present and await its normalized completion.
2. On success, send `lifespan.shutdown.complete`.
3. If the callback throws synchronously or its Future fails, send
   `lifespan.shutdown.failed` with the exception text.
4. Return after the shutdown response.

With no matching callback, the relevant completion event is sent immediately.
Unrecognized receive-event types are ignored while waiting for the standard
startup or shutdown event.

An error from the server-provided receive or send callback propagates; compose
does not attempt a second protocol response on a failed channel.

### 11.4 Decline versus failure

The PAGI specification treats a clean return or exception before an explicit
startup result as declining lifespan support, in which case the server
continues. A configured composition explicitly supports lifespan, so
configuration/state/callback failures are converted into
`lifespan.startup.failed`; they must not accidentally look like a decline.

An application-middleware exception remains middleware behavior rather than a
callback failure. Middleware that wants to own or translate lifecycle failure
can do so with the same native event contract.

## 12. HEAD wire boundary

The declarative router already guarantees that router and route middleware see
the complete representation for a HEAD request while the final wire receives
no body. `compose` must preserve that guarantee for application middleware as
well.

The compiled composition therefore establishes one outer wire-send adapter
before calling application middleware. For HTTP HEAD only, it:

- passes `http.response.start` and other non-body events unchanged;
- drops every nonterminal `http.response.body` event;
- treats both byte-body and sendfile/file body events as body events;
- emits one empty terminal `http.response.body` event when the inner response
  reaches its terminal body event (missing `more` is terminal);
- drops HTTP trailers;
- never rewrites the request method from HEAD to GET.

All application, router, mount, and route middleware therefore sees the full
body and can compute the same `Content-Length`, compression metadata, ETag, or
other representation headers as GET. A custom HEAD route still sees method
`HEAD` and may avoid an expensive GET operation.

The existing private routing HEAD marker and send adapter will be extracted
into one shared internal routing utility used by both
`PAGI::Routing::Compiler` and `PAGI::Compose`. The outer composition installs
the marker on a shallow scope clone. A nested declarative router detects it and
does not install a second suppressor. Middleware must preserve unknown scope
keys when shallow-cloning, as required by the existing scope-cloning
convention.

`PAGI::Middleware::Head` is not silently removed or reinterpreted. It remains
an explicit older middleware that rewrites HEAD to GET before its inner app.
It is unnecessary under `compose` and can bypass a custom HEAD route, so the
Compose documentation must warn against enabling it accidentally.

## 13. Error boundaries

Configuration and compilation errors are synchronous:

- odd or unknown constructor arguments;
- missing/both `routes` and `app`;
- invalid routing nodes or middleware descriptors;
- invalid or empty lifespan configuration;
- target coercion/class loading;
- middleware construction or wrap failures.

Request-time target and middleware failures propagate normally. `compose`
does not synthesize HTTP 500 responses; application-wide error middleware is
the policy boundary for those failures.

Only errors owned by the lifespan driver are converted into lifespan failure
events: missing required state and configured callback failure. This keeps the
protocol response deterministic without turning unrelated middleware behavior
into hidden policy.

## 14. Relationship to existing APIs

### 14.1 Declarative routing

`compose(routes => [...])` is a convenience for a root declarative router plus
application-wide middleware and lifespan. It does not change route matching,
mount rewriting, generated Allow handling, route metadata, reverse routing, or
router-local middleware.

When advanced routing configuration or inspection is required, users build
and retain the router explicitly and pass it through `app`.

### 14.2 Existing routers and native apps

The app form works with `PAGI::App::Router`, `PAGI::Endpoint::Router`, a
declarative router, component objects/classes, and native PAGI coderefs through
the existing coercion boundary. Their request behavior is unchanged. Compose
adds only the outer middleware/lifecycle/HEAD boundary.

### 14.3 `PAGI::Lifespan`

`PAGI::Lifespan` and `PAGI::Utils::handle_lifespan` remain shipped and
unchanged. Compose does not expose a `PAGI::Lifespan` object and does not simply
wrap its target with `PAGI::Lifespan->wrap`; the required middleware, state,
ownership, and HEAD ordering are different.

Documentation will compare the APIs:

- use `compose` for a single explicit application root containing target,
  application middleware, and lifecycle;
- use existing low-level lifespan helpers when hand-building a native app or
  when their shipped hook-registration behavior is specifically required;
- never wrap the same deployed root in two independent lifespan consumers.

Any future consolidation or deprecation of the older lifespan layer requires
a separate compatibility design.

## 15. Documentation

Documentation must include:

- the routes and app canonical examples;
- the distinction between a composition description and its compiled coderef;
- all constructor validation and accessor behavior;
- the three conceptual layers: target, application middleware, lifespan;
- middleware ordering across HTTP, WebSocket, SSE, lifespan, and extension
  scopes;
- server-owned state and the automatic state-support startup failure;
- callback arguments, synchronous/Future completion, and ignored return
  values;
- startup/shutdown failure messages and partial-startup cleanup ownership;
- root-only lifecycle ownership for nested and mounted compositions;
- custom router fallback configuration through `app => router(...)`;
- HEAD ordering, sendfile/trailer suppression, and the warning about
  `PAGI::Middleware::Head`;
- the bare-coderef distinction: route handler under `route`, native app under
  `compose(app => ...)`, and middleware factory under `middleware`;
- why `PAGI::App` and `PAGI::Application` were not used as names;
- comparison with direct router `to_app` and `PAGI::Lifespan` composition.

The declarative-routing documentation that currently calls this abstraction a
future application constructor must be updated to link to `PAGI::Compose`.

## 16. Verification requirements

Tests must cover at least:

- no default exports, explicit `compose`, uppercase `:ALL`, and rejected
  lowercase `:all`;
- functional/OO constructor equivalence and every validation failure;
- defensive copies from every collection accessor;
- routes-mode HTTP, WebSocket, and SSE dispatch;
- app-mode coderef, component object, and class coercion;
- delegation of an unknown non-lifespan scope in app mode;
- proof that the inner target never receives lifespan;
- no-hook lifespan success without a state key;
- configured-lifespan startup failure when state is missing or malformed;
- proof that middleware cannot fabricate missing state or replace the
  server-provided state reference;
- proof that ordinary middleware scope cloning preserves state provenance;
- synchronous and Future-backed startup/shutdown callbacks;
- callback argument identity for state and middleware-adjusted scope;
- startup and shutdown callback failure events and messages;
- startup failure not invoking shutdown;
- receive/send failures propagating without a second response;
- first-listed-outermost application middleware for requests and lifespan;
- middleware short-circuit/ownership behavior for lifespan;
- fresh middleware and target compilation on separate `to_app` calls;
- concurrent requests through one compiled app without cross-request control
  state leakage;
- two independent lifespan scopes through one compiled app without shared
  lifecycle phase state;
- application middleware seeing complete GET-equivalent body data for HEAD;
- final suppression of byte, streaming, sendfile/file, and trailer events;
- custom HEAD routes retaining method HEAD;
- one shared boundary when a declarative router is nested under compose;
- explicit behavior when `PAGI::Middleware::Head` is deliberately configured;
- POD syntax, load tests, canonical example compilation, focused tests, and
  the complete distribution test suite.

## 17. Alternatives rejected

### 17.1 `PAGI::App` or `PAGI::Application`

Both names occupy more architectural space than this optional composition
helper should. `PAGI::App` also looks like the base class for the existing
`PAGI::App::*` namespace and is reserved for possible separate work.

### 17.2 Top-level `startup` and `shutdown`

This is compact but turns the constructor into a flat option bag. Grouping the
distinct callbacks under `lifespan` preserves their separate roles while
making lifecycle one top-level concern.

### 17.3 Direct `not_found` and `method_not_allowed`

These duplicate router policy, make routes mode inconsistent with app mode,
and start turning compose into another router constructor. Explicit
`app => router(...)` is the supported advanced form. Their longer-term router
ownership remains deferred.

### 17.4 Private fallback state

Creating a private hash when the server omits lifespan state cannot safely
associate later request scopes with the correct worker/event-loop lifespan and
duplicates a server responsibility. Passing undef is also unsafe because Perl
can autovivify the callback's local copy into a disconnected hash. Compose
instead fails startup clearly whenever configured lifecycle requires missing
state.

### 17.5 Arbitrary inner lifespan delegation

Two nested apps cannot independently consume one receive stream without
coordinating events and completion ownership. Automatic route-tree discovery
would couple the generic composition layer to every target implementation.
One root lifespan owner is explicit and matches the intended deployment model.

### 17.6 Returning a coderef directly from `compose`

That would make the functional and OO forms differ, hide the compile boundary,
and prevent safe inspection or multiple deliberate compilations. The existing
declarative API consistently uses immutable values followed by `to_app`.

## 18. Deferred decision ledger

The following questions are intentionally not answered by this design:

1. Should router-level `not_found` and `method_not_allowed` remain direct
   router options, move to another policy layer, or be expressible through a
   true route/middleware abstraction?
2. Should a future compatibility project consolidate `PAGI::Lifespan` and the
   compose lifespan driver?
3. Should a future lifecycle-specific Context object replace the raw
   `($state, $scope)` callback pair?
4. Should higher-order frameworks add status helpers, verb shortcuts, or
   mutable registration on top of these immutable core descriptions?

None is a prerequisite for implementing the approved Compose surface.
