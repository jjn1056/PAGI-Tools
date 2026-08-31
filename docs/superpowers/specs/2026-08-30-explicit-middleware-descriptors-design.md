# Explicit Middleware Descriptors Design

**Status:** Approved for implementation planning on 2026-08-30.

## 1. Purpose

PAGI-Tools currently lets every `middleware => [...]` list contain four
different shapes: a short or qualified class-name string, a bare factory
coderef, a configured object with `wrap`, or an explicit
`PAGI::Routing::Middleware` description returned by `middleware(...)`.
Constructors silently normalize the first three shapes into the fourth.

The four accepted inputs are disjoint Perl shapes, so the old normalization
was deterministic type dispatch rather than signature inference. The problem
was representational: immutable composition nodes accepted several input
forms and silently converted them into one stored description. Requiring an
explicit description gives the core one inspectable configuration value and
makes deferred construction visible, while higher-level frontends retain the
same unambiguous convenience dispatch.

This design makes the immutable composition layer explicit:

```perl
route('/items' => \&items,
    middleware => [
        middleware('RequestId'),
        middleware('GZip', minimum_size => 1024),
        middleware('+MyApp::Middleware::Authorization', role => 'admin'),
        middleware(\&audit_factory, label => 'items'),
        middleware($configured_object),
    ],
);
```

Higher-level frontends may retain concise forms, but they must materialize the
same explicit descriptions before constructing immutable routing nodes.

## 2. Design influences

Starlette's `Middleware(...)` is a construction description. It stores a
middleware factory plus positional and keyword arguments; Route, Mount, and
Router later fold those descriptions around an inner ASGI application.

Plack supplies the familiar Perl naming convention: a short name resolves
under the framework middleware namespace, while a leading `+` selects an
exact caller-owned package. PAGI adopts that convention rather than its
current unfamiliar `^` escape.

The resulting PAGI contract combines:

- Starlette's explicit middleware descriptions;
- Plack's short-name and leading-`+` package convention; and
- PAGI's pure native application-to-application middleware model.

## 3. Scope

This design governs middleware descriptions used by:

- `PAGI::Routing::Route`;
- `PAGI::Routing::Mount`;
- `PAGI::Routing::Router`; and
- `PAGI::Compose`.

Route, Mount, and Router are the three routing boundaries. Compose uses the
same list contract because a separate application-root grammar would create
an unnecessary exception.

The existing higher-level frontends may continue to accept concise entries:

- `PAGI::App::Router`;
- `PAGI::Endpoint::Router`; and
- `PAGI::Middleware::Builder`.

Those frontends own the sugar. Their output must use the same immutable
`PAGI::Routing::Middleware` descriptions.

## 4. Core list contract

Every immutable/core `middleware => [...]` value must be an array reference
containing only `PAGI::Routing::Middleware` objects.

These are valid:

```perl
middleware => [
    middleware('RequestId'),
    middleware(\&audit_factory),
    middleware($configured_object),
]
```

These fail during construction:

```perl
middleware => ['RequestId']
middleware => [\&audit_factory]
middleware => [$configured_object]
middleware => [{}]
```

The diagnostic identifies the middleware list, the failing index, and the
requirement for a `middleware(...)` description.

Constructors shallow-copy the descriptor array. Explicit descriptor identity
is retained. Accessors return fresh array references containing the original
immutable descriptions.

## 5. `middleware(...)` descriptor constructor

`middleware($target, %config)` returns one immutable
`PAGI::Routing::Middleware` description. It performs validation and stores
configuration but does not load a class, construct middleware, call `wrap`,
or perform protocol I/O.

### 5.1 Class target

```perl
middleware('RequestId', header => 'X-Request-ID')
middleware('Auth::Basic', realm => 'private')
middleware('+MyApp::Middleware::Authorization', role => 'admin')
middleware('PAGI::Middleware::RequestId')
```

Resolution rules are:

- `RequestId` becomes `PAGI::Middleware::RequestId`;
- `Auth::Basic` becomes `PAGI::Middleware::Auth::Basic`;
- `+MyApp::Middleware::Authorization` becomes the exact package
  `MyApp::Middleware::Authorization`;
- an already `PAGI::Middleware::`-qualified name remains exact; and
- the retired `^MyApp::Middleware` spelling is invalid.

At each enclosing `to_app`, the description loads the class, calls
`$class->new(%config)`, verifies that the result is a blessed object with
`wrap`, and calls `$object->wrap($inner_app)`.

Each compilation therefore receives a fresh class-constructed middleware
instance.

### 5.2 Factory coderef target

```perl
middleware(\&audit_factory, label => 'items')
```

At each enclosing `to_app`, the factory is called synchronously as:

```perl
my $wrapped = audit_factory($inner_app, label => 'items');
```

The configuration hash is shallow-copied into the descriptor and supplied as
a flat key/value list in unspecified hash order; factories must treat it as
named configuration, not positional ordering.

A factory with no configuration continues to receive only `$inner_app`.

### 5.3 Configured object target

```perl
middleware($configured_object)
```

The object must be blessed and provide `wrap`. Additional descriptor
configuration is rejected because the object is already configured. At each
compilation, the exact object receives:

```perl
my $wrapped = $configured_object->wrap($inner_app);
```

Reusing an object intentionally shares whatever state that object owns.

## 6. Wrapper result contract

A factory or `wrap` method returns a PAGI application value synchronously:

- a native three-argument PAGI coderef; or
- an instantiated object with `to_app`.

The descriptor immediately normalizes the result through
`PAGI::Utils::to_app` during stack construction. A returned `Future`, package
name, unblessed reference, middleware-only object, or undefined value fails
synchronously with a diagnostic naming either the middleware factory or
middleware `wrap` result.

This is a compile-time application-value contract. It does not create
response-valued middleware. Once invoked for a request, the wrapped native app
owns protocol events and its return is application completion.

## 7. Runtime semantics

Middleware remains pure:

```text
native PAGI app -> native PAGI app
```

It receives an already compiled inner application coderef and may:

- pass through or shallowly modify scope;
- wrap receive or send;
- short-circuit by emitting or invoking a complete response application;
- act before and after downstream completion; or
- decline to call the inner application.

There is no one-Request middleware signature, response-valued `$next`, arity
inspection, or runtime factory construction.

Descriptions are folded in reverse declaration order so the first listed
middleware executes outermost. Route middleware runs only after a FULL Route
selection; it does not run for that Route's path miss or method mismatch.
Mount and Router middleware retain their existing routing-boundary ownership,
and Compose middleware retains its application-root placement.

The same native middleware contract applies to HTTP, WebSocket, and SSE.

## 8. Higher-level frontend sugar

`PAGI::App::Router` and `PAGI::Endpoint::Router` may continue accepting bare
class names, factories, objects, and descriptions in their convenient public
declaration forms. They normalize every occurrence into an explicit
description before materializing `PAGI::Routing::Route`, `Mount`, or `Router`.

Their class-name sugar uses the same naming convention:

```perl
'RequestId'                         # PAGI::Middleware::RequestId
'+MyApp::Middleware::Authorization' # exact package
```

`PAGI::Endpoint::Router::middleware_as($name)` remains a local-method factory
adapter. The Endpoint frontend may accept that returned factory directly and
materialize `middleware($factory)` internally.

`PAGI::Middleware::Builder` remains a higher-level builder and may retain
`enable 'RequestId'`. Its exact-package escape changes from `^` to the Plack-
familiar `+` so middleware naming is consistent throughout the distribution.

### 8.1 Deliberate grammar and naming tradeoff

The distribution intentionally ends with two public grammars. Immutable core
lists accept only descriptions; App Router, Endpoint Router, and Middleware
Builder accept disjoint concise values and materialize descriptions before
entering the core. This is more total surface, not a claim that all middleware
syntax was simplified.

The cost falls most visibly on zero-configuration declarative middleware:
`middleware => [middleware('RequestId')]`. PAGI keeps that spelling because the
inner function constructs a middleware description and remains searchable and
self-documenting. `mw(...)` is too cryptic, `use_middleware(...)` incorrectly
suggests immediate wrapping, and `Middleware(...)` is class-like rather than
idiomatic Perl. The repeated noun is an accepted cost of the explicit core
boundary.

## 9. Documentation and examples

Primary declarative documentation must show only explicit descriptions:

```perl
middleware => [
    middleware('RequestId'),
    middleware(\&with_logging),
]
```

It must explain separately that App Router, Endpoint Router, and Middleware
Builder are higher-level convenience APIs that may accept shorter spellings.

Examples using declarative Route, Mount, Router, or Compose middleware must be
migrated to `middleware(...)`. Examples deliberately demonstrating a higher-
level frontend may retain its documented sugar.

The upgrading guide must cover:

- bare core entries becoming explicit descriptions;
- `^MyApp::Middleware` becoming `+MyApp::Middleware`;
- coderef factories receiving optional `%config`;
- factory/`wrap` results accepting complete application values; and
- the unchanged first-listed-outermost and native runtime semantics.

## 10. Non-goals

This change does not:

- add Request middleware;
- add response-valued middleware or a generalized `$next`;
- infer coderef signatures;
- alter Route/Mount/Router/Compose ownership or ordering;
- change endpoint adaptation;
- make middleware construction asynchronous;
- auto-load application values outside explicit middleware descriptions; or
- remove higher-level frontend sugar.

## 11. Acceptance criteria

1. Core Route, Mount, Router, and Compose reject every non-description entry.
2. `middleware(...)` supports short, already-PAGI-qualified, and leading-`+`
   class names, factory coderefs with optional configuration, and configured
   `wrap` objects without extra configuration.
3. `^` exact-package syntax is rejected everywhere public.
4. Factory and `wrap` results normalize CODE and instantiated `to_app`
   objects exactly once per compiled stack.
5. Future-backed construction remains rejected.
6. First-listed-outermost order, short-circuiting, metadata visibility,
   protocol behavior, and compilation lifetime remain unchanged.
7. App Router, Endpoint Router, and Middleware Builder retain documented
   higher-level sugar while materializing the same core descriptions.
8. Live documentation and examples contain no bare middleware entries at core
   declarative boundaries.
