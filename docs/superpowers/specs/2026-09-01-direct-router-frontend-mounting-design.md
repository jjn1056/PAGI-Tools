# Direct Router Frontend Mounting Design

**Status:** Approved design; implementation not started

**Date:** 2026-09-01

**Supersedes:** The frontend-deployment guidance in sections 7.3 and 13.2 of
`docs/superpowers/specs/2026-09-01-compose-routes-and-explicit-router-mounting-design.md`.
The underlying application and inspection contracts from that design remain
unchanged.

## 1. Summary

`PAGI::App::Router` and `PAGI::Endpoint::Router` are already PAGI application
objects: both implement `to_app`. The ordinary way to place either frontend
behind a `Mount` is therefore to pass the object directly:

```perl
my $router = PAGI::App::Router->new;
$router->get('/' => \&home)->name('home');

my $app = compose(
    routes => [
        mount('/' => app => $router),
    ],
);
```

Calling `to_router` before every Mount is valid, but it is not ordinary
deployment syntax. It converts a mutable or method-oriented frontend into an
immutable, structurally inspectable `PAGI::Routing::Router`. That conversion
belongs only at a boundary that actually needs structural inspection, nested
name discovery, or a deliberately retained snapshot.

The public rule is:

> If a value is already a PAGI application, mount it directly. Call
> `to_router` only when the receiving router must inspect the value as routing
> structure.

This correction reduces syntax without adding inference, aliases, or hidden
conversion. `Mount` continues to accept PAGI applications, and `to_router`
continues to mean an explicit change of representation.

## 2. Problem

The previous composition campaign correctly removed `Compose`'s special
`router` option and made application composition explicit through `Mount`.
Its class-based examples then over-corrected by writing this form almost
everywhere:

```perl
compose(
    routes => [
        mount('/' => app => $router->to_router),
    ],
);
```

That form obscures a useful fact: `$router` already satisfies the PAGI
application contract. It also makes users remember an implementation detail
at the most common deployment boundary, even when no outer code inspects the
frontend's descendant names.

The extra call is especially distracting because the visible intent is only
"put this application at `/`". The minimal expression of that intent is:

```perl
mount('/' => app => $router)
```

The longer form remains necessary in some nested compositions. Treating every
frontend alike hides that distinction instead of teaching it.

## 3. Goals

1. Make the common App Router and Endpoint Router deployment forms use the
   least syntax that expresses the application boundary.
2. Give `to_router` one clear meaning: produce an immutable, inspectable
   routing snapshot.
3. Preserve nested reverse routing where a parent genuinely needs to discover
   a child's named routes.
4. Keep `Mount`, `Compose`, App Router, and Endpoint Router coherent with the
   existing PAGI application contract.
5. Correct examples, POD, generated README material, upgrade guidance, and
   tests together.
6. Keep snapshot-specific tests and documentation where they exercise actual
   snapshot behavior.

## 4. Non-goals

This work does not:

- remove or deprecate `to_router`;
- change `to_app` behavior;
- add `router =>` to `Compose` or `Mount`;
- make `Compose` or `Mount` call `to_router` automatically;
- add `include_router`, `to_routes`, a route-provider protocol, or capability
  guessing;
- make opaque application internals visible to a parent resolver;
- flatten a frontend's routes into the parent;
- change matching, middleware ordering, fallback ownership, lifespan, HEAD,
  WebSocket, or SSE semantics;
- convert tests whose purpose is immutable snapshot construction,
  materialization, cycle detection, or inspection; or
- redesign nested URL generation.

## 5. Existing contracts

### 5.1 PAGI application values

A Mount application is either:

- a native three-argument PAGI coderef; or
- an instantiated object implementing `to_app`.

Both `PAGI::App::Router` and `PAGI::Endpoint::Router` implement `to_app`.
Passing either object as `app` is ordinary application composition, not a
special frontend shortcut.

### 5.2 Direct frontend compilation

`PAGI::App::Router->to_app` constructs one fresh immutable Router snapshot and
compiles it. `PAGI::Endpoint::Router->to_app` does the same after binding the
Endpoint instance's declarations.

Therefore:

```perl
mount('/' => app => $frontend)
```

preserves the frontend's own:

- declared routes and declaration order;
- router middleware;
- HTTP default;
- description;
- HTTP 404 and 405 ownership;
- protocol miss behavior; and
- request-local resolver metadata inside the selected frontend.

The parent compiles the Mount application once as part of its own compiled
application graph. Requests do not call `to_router` or `to_app` repeatedly.

### 5.3 Opaque parent boundary

The parent treats a directly mounted frontend as an application. It does not
inspect the frontend's declarations or add its descendant names to the
parent's reverse index.

This does not prevent handlers inside the frontend from resolving their own
names. Once the Mount dispatches into the frontend, the frontend's compiled
Router installs its own resolver frame. For example, a handler declared by an
App Router may continue to use a local route name through
`PAGI::Routing::URL`.

What does not work through an opaque boundary is parent-side discovery:

```perl
my $child = PAGI::App::Router->new;
$child->get('/show/{id}' => \&show)->name('show');

$parent->mount('/child', app => $child)->name('child');

# The parent cannot inspect /child/show through the opaque child app.
$parent->path_for('/child/show', { id => 1 });  # unknown name
```

That behavior remains deliberate.

### 5.4 Explicit immutable snapshot

`to_router` changes the value from a frontend application into an immutable
Router application with public route inspection:

```perl
my $child = PAGI::App::Router->new;
$child->get('/show/{id}' => \&show)->name('show');

$parent->mount(
    '/child',
    app => $child->to_router,
)->name('child');

$parent->path_for('/child/show', { id => 1 });  # /child/show/1
```

The parent can discover names because immutable Router applications implement
the routing inspection contract. The same rule applies to an Endpoint Router
child.

An author may also retain a snapshot because stable immutable identity matters
independently of parent inspection:

```perl
my $snapshot = $builder->to_router;

inspect($snapshot);
mount('/api' => app => $snapshot);
```

Those are explicit reasons to call `to_router`; ordinary root deployment is
not.

## 6. Canonical forms

### 6.1 App Router at the Compose root

Before:

```perl
my $router = PAGI::App::Router->new;
$router->get('/' => \&home)->name('home');

compose(
    routes => [
        mount('/' => app => $router->to_router),
    ],
    lifespan => { startup => \&startup },
);
```

After:

```perl
my $router = PAGI::App::Router->new;
$router->get('/' => \&home)->name('home');

compose(
    routes => [
        mount('/' => app => $router),
    ],
    lifespan => { startup => \&startup },
);
```

The unnamed root Mount still consumes no path and adds no route-name
namespace. Compose supplies its root services; the mounted App Router owns its
own routing outcomes.

### 6.2 Endpoint Router at the Compose root

Before:

```perl
my $root = MyApp::Root->new(repository => $repository);

compose(
    routes => [
        mount('/' => app => $root->to_router),
    ],
    lifespan => { startup => \&startup },
);
```

After:

```perl
my $root = MyApp::Root->new(repository => $repository);

compose(
    routes => [
        mount('/' => app => $root),
    ],
    lifespan => { startup => \&startup },
);
```

The Endpoint object is already an application. Its own `to_app` binds and
compiles its declarations.

### 6.3 Nested parent discovery

The Endpoint Router demo intentionally keeps this boundary:

```perl
sub routes {
    my ($self, $router) = @_;

    $router->get('/' => 'home')->name('home');
    $router->mount(
        '/api',
        app => $self->{api}->to_router,
    )->name('api');
}
```

`home` resolves `/api/index`. The Main Router therefore needs the API Router's
named descendants while constructing Main's reverse index. Directly mounting
`$self->{api}` would dispatch correctly but would not publish `/api/index` to
Main.

The application entry point does not need another conversion:

```perl
compose(
    routes => [
        mount('/' => app => $main),
    ],
    lifespan => {...},
);
```

Main's own compilation retains the inspectable API snapshot declared inside
Main. The outer Compose Router does not need to inspect Main's names merely to
deploy it.

### 6.4 Functional immutable Router

A value already returned by `router(...)` is an immutable
`PAGI::Routing::Router`, so it remains directly mountable:

```perl
my $routing = router(routes => [...]);

compose(
    routes => [
        mount('/' => app => $routing),
    ],
);
```

There is no `to_router` step because the value is already the immutable
Router.

## 7. Decision table

| Value at the Mount | Canonical spelling | Parent sees descendant names? | Use when |
|---|---|---:|---|
| Native PAGI coderef | `app => $app` | No | Mounting an opaque native application |
| Arbitrary `to_app` object | `app => $app` | No | Mounting an application component |
| `PAGI::App::Router` frontend | `app => $builder` | No | Ordinary App Router deployment |
| `PAGI::Endpoint::Router` instance | `app => $endpoint` | No | Ordinary Endpoint deployment |
| Immutable `PAGI::Routing::Router` | `app => $router` | Yes | Functional Router or retained structure |
| Frontend converted explicitly | `app => $frontend->to_router` | Yes | Parent inspection or stable snapshot |

The table is descriptive, not a new dispatch mechanism. Mount still sees only
native coderefs and instantiated `to_app` objects. Immutable Router
inspectability is an existing routing contract.

## 8. Why opacity is acceptable at the root

Application deployment and route inspection are different responsibilities.
The server needs only a PAGI application. Compose needs only to invoke the
selected Mount application. Neither needs the child declarations merely to
dispatch requests.

Reverse routing inside the child uses the child's resolver. Parent inspection
is needed only when code outside the child wants to address the child's names
as part of the parent's namespace. Requiring `to_router` at every root confuses
that exceptional structural requirement with ordinary application execution.

This distinction follows the project's recent separation rules:

- Route owns exact leaf matching;
- Mount owns application composition and prefix rewriting;
- Router owns ordered child selection and its routing outcomes;
- Compose owns root services; and
- `to_router` materializes inspectable routing structure.

Each spelling now names the responsibility it actually uses.

## 9. Runtime changes

No runtime change is expected. Existing code already supports direct frontend
mounts and tests already establish that they:

- dispatch as PAGI applications;
- compile once per parent application graph;
- preserve their own Router behavior; and
- remain opaque to parent route inspection.

Implementation should begin with characterization tests or strengthen the
existing ones before changing examples and documentation. If a direct root
mount fails to preserve documented behavior, stop and treat that as a contract
bug rather than adding frontend-specific conversion to Compose or Mount.

## 10. Migration scope

### 10.1 Convert ordinary root mounts

The repository audit must convert root deployment examples whose outer Router
does not inspect descendant names. At minimum, inspect and update as
applicable:

- `examples/background-tasks/app.pl`;
- `examples/endpoint-demo/app.pl`;
- `examples/endpoint-router-demo/app.pl`;
- `examples/full-demo/app.pl`;
- `examples/10-chat-showcase/app.pl`;
- `examples/10-chat-showcase/lib/ChatApp/HTTP.pm`;
- their README files;
- the top-level README source in `lib/PAGI/Tools.pm`;
- generated `README.md`;
- `lib/PAGI/Compose.pm`;
- `lib/PAGI/App/Router.pm`;
- `lib/PAGI/Endpoint/Router.pm`;
- `lib/PAGI/Tools/Tutorial.pod`;
- `lib/PAGI/Tools/Cookbook.pod`; and
- `UPGRADING.md`.

The final repository search may find additional live guidance. Historical
design and plan files are records and must not be mechanically rewritten.

### 10.2 Preserve structural conversions

Do not replace `to_router` when the surrounding code:

- calls `named_routes`, `route_named`, or `path_for` on the resulting
  snapshot;
- expects a parent Router to discover nested descendant names;
- asserts immutable snapshot identity or freshness;
- tests materialization or callback-child freezing;
- tests cycle detection;
- reuses an immutable Router at multiple named placements;
- inspects Route or Mount metadata; or
- deliberately contrasts opaque application mounting with inspectable Router
  mounting.

This includes the nested `Main -> API` and `API -> Events` boundaries in the
Endpoint Router demo if their parent namespace or tests consume the descendant
names. Each nested boundary must be justified by a concrete consumer rather
than retained by habit.

### 10.3 Tests are not prose examples

Many test-local `to_router` calls construct the subject under test. They are
not deployment ceremony and should remain. Only change a test call when the
test is specifically pinning an outdated public example or root-deployment
convention.

## 11. Documentation requirements

### 11.1 Lead with the common form

App Router and Endpoint Router POD must show direct mounting first:

```perl
compose(routes => [
    mount('/' => app => $router),
]);
```

The `to_router` sections should then explain the inspectable form with a
parent/child reverse-routing example. Do not lead with snapshot retention at a
root that has no consumer for the snapshot.

### 11.2 Explain the boundary without fear language

Documentation should describe direct mounting as "application composition"
and explicit conversion as "inspectable routing composition." It should not
imply that opacity is broken, unsafe, or second-class. An opaque component is
the normal result of respecting an application boundary.

### 11.3 Upgrade guidance

The upgrade guide should distinguish two migrations:

```perl
# Ordinary deployment
mount('/' => app => $builder)

# Parent must discover child names
mount('/child' => app => $child->to_router, name => 'child')
```

Older migration entries that say every mutable frontend must "cross the
immutable boundary" before Mount must be corrected. Existing entries that
teach snapshot inspection should remain, but their motivating requirement
must be explicit.

### 11.4 README generation

`README.md` is generated project documentation. Edit its authoritative POD
source and regenerate it through the repository's documented author workflow;
do not hand-maintain divergent examples.

## 12. Verification

### 12.1 Contract tests

Tests must establish:

1. a directly mounted App Router dispatches HTTP routes;
2. a directly mounted Endpoint Router dispatches HTTP routes;
3. direct root mounting preserves frontend middleware and `http_default`;
4. direct root mounting preserves HTTP 405 and `Allow` behavior;
5. handlers inside a directly mounted frontend can resolve their own names;
6. the outer Compose Router cannot inspect names behind the opaque frontend;
7. converting the same frontend with `to_router` exposes its names to the
   parent;
8. a nested parent can resolve a converted child's slash-addressed name; and
9. parent compilation does not invoke the mounted frontend per request.

Existing tests may already cover several outcomes. Prefer strengthening or
consolidating those tests rather than creating redundant suites.

### 12.2 Example tests

Use `PAGI::Test::Client` to verify affected executable examples. Preserve, as
applicable:

- root pages;
- generated links;
- nested links;
- custom 404 and 405 responses;
- middleware behavior;
- lifespan state;
- WebSocket behavior; and
- SSE behavior.

The Endpoint Router demo must continue to prove that Main generates the API
link and API generates its local item link after the root is mounted directly.

### 12.3 Documentation tests

Update executable POD and source-pattern tests so they require the new
canonical direct form where appropriate and continue to require explicit
snapshots in parent-inspection examples.

### 12.4 Final search

Search live distribution surfaces for `->to_router` and classify every hit:

- structural conversion retained with a concrete reason;
- test subject construction;
- historical migration example; or
- unnecessary deployment ceremony to remove.

The final report should list the retained user-facing conversions and their
reasons. A raw zero-hit target is incorrect because `to_router` remains a
public and useful API.

## 13. Work map

| Repository | Ticket | Branch | Base | Owned changes | Deployment boundary | Push target |
|---|---|---|---|---|---|---|
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/.worktrees/compose-retained-router` | none | `feature/compose-retained-router` | current branch head after the Compose retained-Router campaign | PAGI-Tools tests, examples, POD, README source/generated README, upgrade guide, design and plan records; runtime only if characterization exposes a contract bug | unreleased PAGI-Tools composition APIs | existing `origin/feature/compose-retained-router` PR branch |

No PAGI specification, PAGI::Server, or other repository is in scope.
Reconfirm this map before implementation and before pushing.

## 14. Rejected alternatives

### 14.1 Keep `to_router` at every frontend Mount

This is valid but makes immutable materialization look mandatory for
application deployment. It adds syntax without supplying value at an opaque
root and weakens the meaning of `to_router`.

### 14.2 Make Mount call `to_router` automatically

This would make a generic application boundary guess that some objects are
really route providers. It would expose mutable frontend structure through
magic, create class-specific behavior, and blur Mount's composition role.

### 14.3 Restore `compose(router => ...)`

This recreates two root composition modes and makes Compose understand a
frontend-specific concept. The explicit root Mount already represents the
relationship.

### 14.4 Flatten `$frontend->to_router->routes`

Flattening discards the child Router's middleware, default, description,
identity, Resolver, and routing boundary. It is not equivalent to mounting the
application or its immutable Router.

### 14.5 Remove `to_router`

Parent discovery, stable snapshot inspection, metadata consumers, and cycle
tests all need the immutable representation. The problem is overuse, not the
API.

## 15. Acceptance criteria

The correction is complete when:

1. ordinary root App Router and Endpoint Router examples mount the frontend
   object directly;
2. `to_router` remains only where immutable structure has a named consumer;
3. nested reverse-routing examples still resolve across intentionally
   inspectable child boundaries;
4. POD and README material lead with the minimal direct form;
5. upgrade guidance clearly distinguishes application composition from
   inspectable routing composition;
6. no runtime frontend guessing or automatic conversion is added;
7. focused and full repository tests pass, apart from any independently
   documented pre-existing gate;
8. the generated README matches its authoritative source; and
9. the final retained-usage inventory explains every user-facing
   `to_router` call.
