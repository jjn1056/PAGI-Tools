# Bare Middleware Factory Shorthand Design

## Status

Approved in conversation on 2026-08-06. This document fixes the exact public
surface, normalization boundary, compatibility rules, documentation work, and
example migration before implementation planning.

## 1. Goal

Every declarative PAGI middleware list should accept a bare synchronous
middleware factory coderef:

```perl
middleware => [\&with_logging]
```

This is shorthand for the existing explicit description:

```perl
middleware => [middleware(\&with_logging)]
```

Both spellings compile to the same immutable
`PAGI::Routing::Middleware` description and have identical runtime behavior.
The shorthand removes redundant ceremony without weakening introspection,
construction-time validation, compilation freshness, middleware ordering, or
the pure PAGI app-to-app contract.

## 2. Motivation

`middleware($factory)` is currently mandatory even when the enclosing
`middleware => [...]` position already tells PAGI exactly what the coderef
means. The duplication is especially visible at an application root:

```perl
compose(
    app => $router,
    middleware => [middleware(\&with_logging)],
)->to_app;
```

PAGI's declarative APIs already establish that coderef meaning comes from
argument position. A coderef in a route target position is a Context handler;
a coderef in `compose(app => ...)` is a native PAGI app; and a coderef inside a
`middleware` list can unambiguously be a synchronous app-to-app middleware
factory.

The older `PAGI::App::Router` already accepts bare middleware factories in its
middleware arrays. The new shorthand makes the immutable declarative family
at least as ergonomic while retaining its stronger description and inspection
model.

## 3. Public Scope

There are seven user-facing declarative positions, implemented by four
description constructors. All seven receive the same shorthand.

| Position | Current spelling | New shorthand |
|---|---|---|
| Compose application middleware | `middleware => [middleware(\&log)]` | `middleware => [\&log]` |
| Router middleware | `router(middleware => [middleware(\&log)])` | `router(middleware => [\&log])` |
| HTTP route middleware | `route(..., middleware => [middleware(\&log)])` | `route(..., middleware => [\&log])` |
| WebSocket route middleware | `websocket(..., middleware => [middleware(\&log)])` | `websocket(..., middleware => [\&log])` |
| SSE route middleware | `sse(..., middleware => [middleware(\&log)])` | `sse(..., middleware => [\&log])` |
| Opaque application mount middleware | `mount('/x' => $app, middleware => [middleware(\&log)])` | `mount('/x' => $app, middleware => [\&log])` |
| Inline subtree mount middleware | `mount('/x', routes => [...], middleware => [middleware(\&log)])` | `mount('/x', routes => [...], middleware => [\&log])` |

The affected constructors are:

- `PAGI::Compose->new` / `compose`;
- `PAGI::Routing::Router->new` / `router`;
- `PAGI::Routing::Route->new`, covering `route`, `websocket`, and `sse`;
- `PAGI::Routing::Mount->new`, covering opaque and inline mounts.

An individual list may mix bare factories and explicit descriptions:

```perl
middleware => [
    \&with_logging,
    middleware('RequestId', generator => \&make_id),
    $shared_auth_description,
]
```

The first listed entry remains the outermost middleware.

## 4. Accepted and Rejected Entry Forms

Each affected list accepts exactly two entry shapes:

1. a bare `CODE` reference, treated as a middleware factory; or
2. an existing object whose class is `PAGI::Routing::Middleware` or a subclass.

No other shorthand is introduced.

These remain invalid as direct list entries:

- unblessed scalar, array, or hash references;
- middleware class-name strings;
- blessed middleware objects with a `wrap` method;
- native PAGI application coderefs in place of factories;
- tuple or hash configuration mini-languages.

Class names and configured objects remain available through the explicit
constructor:

```perl
middleware('GZip', minimum_size => 1024)
middleware('^MyApp::Middleware::Audit', level => 'full')
middleware($configured_object)
```

A native PAGI app accidentally supplied as a bare middleware factory is called
with the inner app at compilation and fails the existing requirement that a
factory return a PAGI app coderef. This is the same error behavior as wrapping
that coderef explicitly with `middleware($code)`.

## 5. Normalization Boundary

`PAGI::Routing::Middleware` owns one shared private list-normalization helper,
named `_normalize_descriptors`. Its contract is:

```perl
my $normalized = PAGI::Routing::Middleware->_normalize_descriptors(
    $entries,
    $error_prefix,
);
```

It:

- requires `$entries` to be an array reference;
- converts each bare `CODE` entry with
  `PAGI::Routing::Middleware->new($entry)`;
- preserves an explicit middleware description by identity;
- rejects every other entry at description construction;
- returns a fresh array reference of normalized description objects; and
- never calls a factory, constructs a middleware class, wraps an app, or emits
  protocol events.

The four public description constructors call this helper once and store the
returned normalized list. Their accessors continue returning shallow array
copies containing only `PAGI::Routing::Middleware` objects.

The existing compiler method `_wrap_descriptors` remains strict and unchanged:
it consumes normalized descriptions only. Normalization does not move to
`to_app` or request time.

## 6. Identity, Copying, and Introspection

An explicit description retains its identity:

```perl
my $audit = middleware('Audit');
my $route = route('/' => \&home, middleware => [$audit]);

refaddr($route->middleware->[0]) == refaddr($audit);
```

A bare factory receives a fresh description for each declared occurrence:

```perl
my $factory = \&with_logging;
my $route = route('/' => \&home, middleware => [$factory, $factory]);
```

The two stored description objects are distinct, but both retain the same
factory coderef by identity. Lexical data captured by that factory therefore
has ordinary caller-chosen Perl sharing semantics.

Input arrays are still defensively copied. Middleware accessors still return
fresh top-level array references. Normalization makes inspection uniform:

```perl
my $description = $route->middleware->[0];

$description->factory; # original coderef
$description->config;  # {}
```

No public accessor returns the original heterogeneous input list.

## 7. Purpose of `middleware()` After the Change

`middleware()` remains the explicit constructor for an immutable middleware
description. It is not deprecated and is not renamed.

It remains necessary or useful for:

- middleware class names and constructor configuration;
- configured objects with a `wrap` method;
- descriptions retained for reuse in several declarations;
- code that wants to inspect `factory` and `config` before attaching the
  description to a router or composition;
- code that prefers an explicit declaration even for a coderef factory; and
- documentation that explains the description layer itself.

For a plain coderef factory inside a middleware list, the constructor becomes
optional:

```perl
middleware => [\&with_logging]
middleware => [middleware(\&with_logging)]
```

The documentation must call `middleware()` a middleware-description
constructor. It does not wrap an application when declared. Actual wrapping
happens synchronously during `to_app`.

## 8. Compilation and Runtime Semantics

The change is constructor-only. `PAGI::Compose::Compiler` and
`PAGI::Routing::Compiler` continue receiving homogeneous description lists and
require no behavioral changes.

All existing rules remain:

- factories run once for each occurrence in each newly compiled graph;
- a second `to_app` builds a fresh middleware graph;
- the first list entry is outermost;
- a factory must return a native PAGI app coderef synchronously;
- an accidentally async factory returning a `Future` is rejected;
- factory and wrapper exceptions propagate during `to_app`;
- request-time wrappers receive only `($scope, $receive, $send)`;
- short-circuiting and channel transformation are unchanged; and
- Compose's final HEAD boundary, lifecycle ownership, and state provenance are
  unchanged.

## 9. Compatibility Boundary

This is an additive source-compatible change. Existing explicit descriptions
retain their behavior and identity. Existing valid applications do not need to
change.

Three similarly named systems are deliberately outside scope:

### 9.1 `PAGI::App::Router`

The mutable router already accepts bare coderef factories and configured
objects with `wrap` directly in its route, group, mount, WebSocket, and SSE
middleware arrays. It does not use `PAGI::Routing::Middleware` descriptions.
No behavior or documentation change is required for the shorthand itself.

### 9.2 `PAGI::Endpoint::Router`

Its HTTP route middleware is the shipped value-flow `$next` system. Entries
are endpoint method-name strings, receive `($context, $next)`, and must return
a `PAGI::Response`. It deliberately rejects event-middleware coderefs and
objects. That behavior must not change.

### 9.3 `PAGI::Middleware::Builder`

Builder uses `enable`, `enable_if`, configured classes, and objects rather than
declarative `middleware => [...]` descriptions. It is unaffected.

The implementation and documentation must not suggest that these three APIs
have been unified.

## 10. Error Contract

Description construction continues to reject a non-array middleware value.
Invalid entries now report that lists accept middleware descriptions or
coderef factories. Error wording should distinguish the optional Compose
prefix where current public diagnostics do so, without maintaining two
independent normalization implementations.

Factory result and execution errors retain their current `to_app` boundary and
messages. In particular, normalization must not call a factory early merely to
validate it.

## 11. Documentation Work

The implementation must update every document that currently says entries
must already be descriptions or presents `middleware($code)` as the only
factory spelling:

- `lib/PAGI/Routing.pm` — code-position table, constructor forms, middleware
  section, introspection, and examples;
- `lib/PAGI/Compose.pm` — coderef-position table, middleware constructor
  section, accepted entry forms, and normalization/introspection behavior;
- `lib/PAGI/Routing/Middleware.pm` — clarify that this class represents the
  normalized description and document the purpose of `middleware()`;
- `lib/PAGI/Tools/Cookbook.pod` — show the bare factory form in the channel
  helper recipe while retaining an explicit configured-class example;
- `lib/PAGI/Tools/Tutorial.pod` — distinguish bare factory shorthand from the
  explicit constructor needed for configured middleware;
- `examples/declarative-routing/app.pl` and its README — use a bare route
  factory so the shorthand is executable and visible;
- `examples/10-chat-showcase/app.pl` and its README — use Compose as the
  application root and pass `\&with_logging` directly;
- `examples/README.md` — describe the chat example's Compose integration; and
- `Changes` — record the additive shorthand and chat example migration under
  the unreleased release.

If edits to `lib/PAGI/Tools.pm` are needed to keep the front-page explanation
consistent, regenerate `README.md` through the configured Dist::Zilla
`ReadmeAnyFromPod` workflow. Do not edit generated README text independently.

## 12. Chat Showcase Migration

`examples/10-chat-showcase` is the canonical realistic demonstration because
it already has:

- an existing `PAGI::App::Router` serving HTTP, WebSocket, and SSE;
- application-wide pure logging middleware; and
- explicit startup and shutdown callbacks.

The route declarations and handler packages remain unchanged. The root changes
from manual `PAGI::Lifespan` plus `with_logging(...)` nesting to:

```perl
compose(
    app => $router,
    middleware => [\&with_logging],
    lifespan => {
        startup  => async sub { ... },
        shutdown => async sub { ... },
    },
)->to_app;
```

This demonstrates incremental adoption rather than replacing the mutable
router. It complements `examples/compose`, which demonstrates Compose's direct
`routes => [...]` mode and retains `middleware('RequestId', ...)` as the
configured-class example.

The chat README must state that configured Compose callbacks require server
lifespan state support and that application middleware also surrounds lifespan
events. Existing HTTP, WebSocket, SSE, static asset, and chat behavior remains
unchanged.

## 13. Test Contract

Tests must prove all of the following:

1. bare factories are accepted and normalized at all seven public positions;
2. explicit descriptions are preserved by identity;
3. bare occurrences become description objects retaining factory identity;
4. repeated bare occurrences get distinct description objects;
5. constructor input and accessor arrays remain defensively copied;
6. mixed bare/explicit lists preserve declaration and wrapping order;
7. invalid scalars, unblessed containers, class strings, and bare configured
   objects remain rejected as direct entries;
8. bare factories execute at router, route, WebSocket, SSE, opaque mount,
   inline mount, and Compose boundaries;
9. generated router outcomes and Compose lifespan still pass through their
   respective middleware layers;
10. fresh `to_app` calls rebuild factory wrappers exactly as before;
11. invalid or async factory results retain existing compile-time failures;
12. legacy `PAGI::App::Router` bare middleware still works unchanged;
13. `PAGI::Endpoint::Router` still rejects coderef event middleware with its
    value-flow guidance; and
14. the converted declarative-routing and chat examples load and exercise
    their representative HTTP/lifecycle behavior.

The complete distribution suite, POD checks for all edited modules, and
Dist::Zilla packaging tests must pass.

## 14. Non-Goals

This change does not:

- accept bare class-name strings or configured objects in declarative lists;
- introduce tuple/hash middleware configuration syntax;
- make `middleware()` obsolete or deprecated;
- expose the private normalization helper as public API;
- change middleware order, lifecycle ownership, HEAD suppression, or protocol
  dispatch;
- alter the mutable `PAGI::App::Router` middleware representation;
- alter `PAGI::Endpoint::Router` value-flow middleware;
- unify Builder with the declarative API; or
- convert the chat application's router or handler packages to
  `PAGI::Routing`.

## 15. Acceptance Summary

The feature is complete when a caller may use `\&with_logging` directly in
every declarative middleware list, every description accessor still exposes
only inspectable `PAGI::Routing::Middleware` objects, explicit
`middleware(...)` declarations retain their existing power and identity, the
chat showcase demonstrates the shorthand through Compose, documentation names
the two equivalent coderef spellings, unrelated middleware systems remain
unchanged, and all focused and distribution verification gates pass.
