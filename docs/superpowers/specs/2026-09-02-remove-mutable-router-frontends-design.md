# Remove the Mutable Router Frontends Design

**Status:** Approved; implementation not started

**Date:** 2026-09-02

**Supersedes:** All public `PAGI::App::Router` and
`PAGI::Endpoint::Router` guidance in the current routing, Compose,
frontend-mounting, and application-valued-endpoint designs. The immutable
declarative Router and the route-level `PAGI::Endpoint::HTTP`,
`PAGI::Endpoint::WebSocket`, and `PAGI::Endpoint::SSE` designs remain in force,
subject to the lifecycle correction in section 5.

## 1. Decision

Before the next PAGI-Tools release:

1. repair the configured-instance lifecycle of the retained WebSocket and SSE
   endpoint classes;
2. settle how explicit Route methods interact with an HTTP endpoint's
   `allowed_methods` capability;
3. remove both mutable Router frontends:
   `PAGI::App::Router` and `PAGI::Endpoint::Router`;
4. remove their private Builder and Materializer machinery; and
5. convert maintained applications, examples, tests, and documentation to the
   immutable declarative `PAGI::Routing` API.

Do not preserve either frontend through a compatibility class, private bridge,
or forwarding alias. These APIs are unreleased, and 2026 is the project's
explicit breakage window.

The canonical routing shape becomes:

```perl
use PAGI::Compose qw(compose);
use PAGI::Routing qw(route mount router websocket sse);

my $people = router(
    routes => [
        route('/{person_id}' => \&show_person,
            name => 'show',
        ),
    ],
);

my $app = compose(
    routes => [
        route('/' => \&home, name => 'home'),
        mount('/people',
            app  => $people,
            name => 'people',
        ),
    ],
);
```

An immutable Router is both a PAGI application object and an inspectable route
collection. One value therefore supplies dispatch, nesting, names, and reverse
routing:

```perl
$app->path_for('/people/show', { person_id => 42 });
# /people/42
```

## 2. Why both frontends should go

PAGI-Tools currently exposes three ways to construct the same route topology:

1. `PAGI::Routing`: functional, declarative, and immutable;
2. `PAGI::App::Router`: mutable, imperative, and closure-oriented; and
3. `PAGI::Endpoint::Router`: mutable, method-bound, and class-oriented.

`PAGI::App::Router` has no unique routing capability. Ordinary Perl already
supports conditional and programmatic declarations:

```perl
my @routes;

push @routes, route('/one' => \&one);
push @routes, route('/two' => \&two, methods => ['POST'])
    if $config->{enable_two};

my $routing = router(routes => \@routes);
```

`PAGI::Endpoint::Router` does provide a different style, but it combines too
many responsibilities:

- dependency and configuration storage;
- an entire route subtree;
- a second Router declaration grammar;
- string-to-method binding;
- middleware and native-application adapters;
- mutable snapshot construction; and
- deployment as a PAGI application.

Its implementation crosses two builder layers before reaching the Router that
actually matters:

```text
Endpoint::Router
  -> Endpoint::Router::Builder
    -> App::Router::Builder
      -> App::Router::Materializer
        -> PAGI::Routing::Router
```

Now that the declarative Router is usable directly, preserving that pipeline
would retain complexity solely to produce a value users can construct without
it.

Class-based behavior still has value, but it belongs at one route leaf. This
matches the useful part of Starlette's endpoint-class model:

- an HTTP endpoint object owns verb dispatch for one resource;
- a WebSocket endpoint object owns one connection protocol;
- an SSE endpoint object owns one event-stream protocol; and
- declarative Route, Mount, Router, and Compose own topology.

## 3. Final responsibility boundaries

The final model is:

```text
PAGI::Endpoint::HTTP/WebSocket/SSE  optional behavior for one route
Route                               exact matching and method policy
Mount                               prefix ownership and app composition
Router                              ordered children and routing outcomes
Compose                             root middleware, lifespan, and safety
Future higher-level framework       app conventions and dependency assembly
```

`PAGI::Tools` does not gain an application-root base class in this campaign.
An application may place an ordinary `MyApp::Root` class under `lib/`, but
configuration, dependency injection, model lookup, and framework conventions
belong to application code or a future framework built on PAGI-Tools.

## 4. Current evidence and scope

At the design base, public App Router references span library modules, more
than twenty test files, and maintained examples. Endpoint Router references
span eleven library files, nine test files, and five example areas. The
dedicated `t/endpoint/` directory alone contains approximately 2,500 lines.
This is a large migration, but retaining an intermediate bridge would require
touching many of those surfaces twice.

The mutable implementation consists of:

- `PAGI::App::Router`, a thin public subclass over its Builder;
- `PAGI::App::Router::Builder`, the mutable declaration store;
- `PAGI::App::Router::Materializer`, the mutable identity/cycle snapshot
  machinery;
- `PAGI::Endpoint::Router`, the class frontend; and
- `PAGI::Endpoint::Router::Builder`, the method-binding facade.

The Endpoint facade calls App Builder's private `_add_route_from` and
`_mount_from` methods and its public-looking `http_default`, `name`, `desc`,
and `constraints` methods. This explains why a temporary bridge was possible;
it does not justify retaining any of these classes once both frontends are
removed.

Immutable declarative children must exist before their parent references them,
so the mutable Materializer's active-object cycle machinery is not part of the
final routing model.

## 5. Repair retained route-level endpoint classes first

The endpoint-class replacement must work before Endpoint Router examples are
migrated to it.

### 5.1 Confirmed WebSocket and SSE defect

`PAGI::Endpoint::HTTP->to_app` already resolves its receiver once:

```perl
my $endpoint = blessed($invocant) ? $invocant : $invocant->new;
```

The current WebSocket and SSE variants instead retain the invocant as if it
were always a class and call `$class->new` inside the async application. That
causes two defects:

- a configured object builds successfully but dies on its first connection
  with `Attempt to bless into a reference`; and
- a class invocation creates a new endpoint once per connection rather than
  once per compiled application.

Both classes must adopt the HTTP lifecycle:

- a class `to_app` call constructs exactly one endpoint immediately;
- an instance `to_app` call retains that exact configured instance;
- the retained endpoint serves every request or connection handled by that
  compiled application; and
- no endpoint constructor runs once per request or connection.

All three Endpoint classes must document that configuration and long-lived
services may live on the endpoint object, while request- or connection-local
state must not. One retained instance may serve concurrent work.

Tests must reproduce the current configured-object failure before the fix and
then prove direct and routed configured WebSocket/SSE instances work. They must
also count constructor calls for class invocation and prove one construction
per `to_app`, not per connection.

### 5.2 HTTP method capability contract

For an instantiated HTTP application endpoint that implements
`allowed_methods`:

1. Without explicit Route `methods`, call `allowed_methods` once in list
   context at Route construction and snapshot its normalized result.
2. With a finite explicit methods value, whether a single method string or an
   arrayref, call `allowed_methods` once and treat the explicit value as a
   restriction of the snapshotted endpoint capability. Every declared method
   must be advertised by `allowed_methods`; otherwise Route construction
   croaks with a diagnostic naming both the explicit methods option and the
   endpoint capability.
3. Scalar `methods => '*'` is the explicit escape hatch. It bypasses Router
   method qualification and lets the endpoint own all dispatch and 405
   outcomes.
4. WebSocket and SSE routes never consult `allowed_methods`.

An HTTP handler coderef or application object without this capability retains
the ordinary Route rules: finite explicit methods are accepted as declared,
and an omitted methods option defaults to GET plus automatic HEAD. Empty or
malformed capability results remain construction errors and must identify
`allowed_methods` rather than blaming an option the author did not supply.

This avoids contradictory claims such as a Route advertising POST while its
HTTP endpoint implements only GET. Without this validation, POST is a Router
FULL match followed by an endpoint-generated 405, bypassing sibling PARTIAL
collection and the Router's authoritative `Allow` union.

Standalone or mounted HTTP endpoints still own their internal method dispatch,
automatic OPTIONS behavior, and 405 response because there is no method-aware
Route boundary outside them.

## 6. Public construction after removal

### 6.1 Function-oriented routes

```perl
use PAGI::Routing qw(route router middleware);

my $routing = router(
    routes => [
        route('/people' => \&list_people,
            name       => 'index',
            middleware => [middleware('RequestId')],
        ),
        route('/people' => \&create_person,
            methods => ['POST'],
            name    => 'create',
        ),
    ],
);
```

### 6.2 Class-based HTTP leaf

```perl
package MyApp::Person;

use v5.40;
use parent 'PAGI::Endpoint::HTTP';
use Future::AsyncAwait;
use PAGI::Response::JSON ();

sub new ($class, %args) {
    die 'repo is required' unless $args{repo};
    return bless \%args, $class;
}

async sub get ($self, $request) {
    return PAGI::Response::JSON->new(
        $self->{repo}->find($request->path_param('person_id')),
    );
}
```

The declaration package imports its inline constraint provider and places the
configured endpoint directly at one Route:

```perl
use Type::Standard qw(Int);

my $person = MyApp::Person->new(repo => $repo);

route('/people/{person_id:&Int}' => $person,
    name => 'person',
);
```

### 6.3 Class-based WebSocket and SSE leaves

After the lifecycle repair, configured instances are ordinary application
endpoints:

```perl
websocket('/chat' => MyApp::Chat->new(hub => $hub),
    name => 'chat',
),

sse('/events' => MyApp::Events->new(bus => $bus),
    name => 'events',
),
```

Each object owns one exact protocol leaf. It does not become a Router or own a
subtree merely because it implements `to_app`.

### 6.4 Ordinary classes that assemble a subtree

A component needing several paths may be an ordinary class with a `routing`
method. No PAGI base class is required:

```perl
package MyApp::People;

use v5.40;
use PAGI::Routing qw(route router);
use Type::Standard qw(Int);

sub new ($class, %args) {
    return bless \%args, $class;
}

sub routing ($self) {
    return router(
        routes => [
            route('/' => sub ($request) {
                return $self->list($request);
            }, name => 'index'),

            route('/{person_id:&Int}' =>
                MyApp::Person->new(repo => $self->{repo}),
                name => 'show',
            ),
        ],
    );
}
```

The parent mounts the returned Router directly:

```perl
my $people = MyApp::People->new(repo => $repo);

mount('/people',
    app  => $people->routing,
    name => 'people',
);
```

Because `routing` returns an inspectable Router, nested URL names remain
discoverable without `to_router` or automatic structural treatment of
arbitrary `to_app` objects.

### 6.5 Raw PAGI applications

Native three-channel coderefs remain valid Mount applications and server
roots. A native coderef used at a Route must retain the existing explicit
`as_app` wrapper so Route does not confuse it with a one-Request handler.
Removing either mutable frontend changes no PAGI protocol contract.

## 7. App Router migration

### 7.1 Route declarations

Before:

```perl
$router->get('/people/{id}' => \&show)
    ->name('show')
    ->desc('Show one person')
    ->constraints(id => qr/\A\d+\z/);
```

After:

```perl
route('/people/{id}' => \&show,
    name        => 'show',
    desc        => 'Show one person',
    constraints => { id => qr/\A\d+\z/ },
)
```

GET plus automatic HEAD remains the HTTP Route default. Other verbs use the
existing explicit option:

```perl
route('/people' => \&create,
    methods => ['POST'],
    name    => 'create',
),
route('/health' => \&health,
    methods => '*',
    name    => 'health',
),
```

Declaration order is literal array order. A dedicated HEAD Route must remain
before the GET Route for the same path when it should win.

### 7.2 Protocol routes and middleware

Before:

```perl
$router->websocket('/chat' => \&chat)->name('chat');
$router->sse('/events' => \&events)->name('events');
$router->get('/private' => [\&audit] => \&private)->name('private');
```

After:

```perl
websocket('/chat' => \&chat, name => 'chat'),
sse('/events' => \&events, name => 'events'),
route('/private' => \&private,
    name       => 'private',
    middleware => [middleware(\&audit)],
),
```

The declarative middleware list remains strict and contains explicit
`middleware(...)` descriptions.

### 7.3 Mounts and configured Router boundaries

Before:

```perl
$router->mount('/api', app => $api)->name('api')->desc('API');
```

After:

```perl
mount('/api',
    app  => $api,
    name => 'api',
    desc => 'API',
)
```

A callback-built child becomes a `routes` array or an explicit Router:

```perl
mount('/api',
    routes => [
        route('/users' => \&users, name => 'users'),
    ],
    name => 'api',
)
```

An App Router used only to feed an unnamed root Mount should disappear into
`compose(routes => [...])`. A reusable Router that owns middleware,
`http_default`, description, identity, or an independent outcome boundary must
remain a Router and be mounted directly. Do not flatten configured Router
boundaries merely to reduce syntax.

## 8. Endpoint Router migration

### 8.1 Replace the class frontend with ordinary assembly

Before:

```perl
package MyApp::API;
use parent 'PAGI::Endpoint::Router';

sub routes ($self, $r) {
    $r->get('/people' => 'list_people')->name('index');
    $r->get('/people/{id}' => 'show_person')->name('show');
}
```

After:

```perl
package MyApp::API;
use PAGI::Routing qw(route router);

sub routing ($self) {
    return router(
        routes => [
            route('/people' => sub ($request) {
                return $self->list_people($request);
            }, name => 'index'),

            route('/people/{id}' => sub ($request) {
                return $self->show_person($request);
            }, name => 'show'),
        ],
    );
}
```

The closures make method binding ordinary, visible Perl. The toolkit does not
replace string method names with another reflective convention.

When several verbs describe one exact resource, a route-level
`PAGI::Endpoint::HTTP` subclass may be cleaner than several binding closures.
WebSocket and SSE endpoint subclasses provide the equivalent protocol-specific
option after section 5 is implemented.

### 8.2 Nested Endpoint Routers

Before:

```perl
$r->mount('/people', app => $self->{people}->to_router)
    ->name('people');
```

After:

```perl
mount('/people',
    app  => $self->{people}->routing,
    name => 'people',
)
```

The returned immutable Router supplies dispatch and structural discovery in
one value.

### 8.3 Removed convenience methods

Remove these with Endpoint Router:

- `middleware_as`;
- `app_as`;
- `new_request`;
- `app_path`; and
- `to_router`.

Use explicit closures for local middleware and native applications, the public
Request constructor where raw construction is genuinely required, and
`PAGI::Utils::app_path` for application paths. Do not move a helper merely for
compatibility; retain or relocate it only if the final design demonstrates
value independent of Endpoint Router.

`PAGI::Utils::app_path` resolves its origin from the importing/calling package,
whereas Endpoint's helper derives it from the endpoint class module. Migration
examples must call the exported helper directly in the module that owns the
assets. Add a test for that placement; do not assume an inherited base-class
wrapper is equivalent.

## 9. Files and distribution surface

Delete:

- `lib/PAGI/App/Router.pm`;
- `lib/PAGI/App/Router/Builder.pm`;
- `lib/PAGI/App/Router/Materializer.pm`;
- `lib/PAGI/Endpoint/Router.pm`; and
- `lib/PAGI/Endpoint/Router/Builder.pm`.

Retain and repair:

- `lib/PAGI/Endpoint/HTTP.pm`;
- `lib/PAGI/Endpoint/WebSocket.pm`; and
- `lib/PAGI/Endpoint/SSE.pm`.

Do not leave stubs, aliases, deprecation warnings, forwarding constructors, or
private copies under new names. Remove deleted modules from load tests,
metadata, distribution contents, public cross-links, and generated README
material.

## 10. Documentation and upgrading guide

Update all live public guidance, including:

- `lib/PAGI/Tools.pm` and generated `README.md`;
- `lib/PAGI/Routing.pm`, Route, Mount, and Router POD;
- `lib/PAGI/Compose.pm`;
- retained Endpoint class POD;
- `lib/PAGI/Tools/Tutorial.pod`;
- `lib/PAGI/Tools/Cookbook.pod`;
- `lib/PAGI/Lifespan.pm` and other live cross-links;
- `examples/README.md` and maintained example READMEs;
- `UPGRADING.md`; and
- `Changes`.

The front page must present `PAGI::Routing` as the sole routing construction
API. Endpoint classes are optional route-level applications, not another
Router frontend.

The upgrading guide must contain complete before/after examples for:

- App Router verbs, modifiers, middleware, mounts, protocol routes, defaults,
  descriptions, and nested URL generation;
- Endpoint Router `routes`, string method targets, nested `to_router`,
  `middleware_as`, `app_as`, `new_request`, and `app_path`;
- choosing closures versus route-level Endpoint objects;
- the WebSocket/SSE configured-instance lifecycle correction; and
- explicit HTTP methods, `allowed_methods`, and the `methods => '*'` escape
  hatch.

State plainly that no compatibility layer exists because these APIs have not
been released.

Every Cookbook and Tutorial example must be reviewed as a complete program.
Do not mechanically replace constructors while leaving stale imports, unused
root Mounts, old method syntax, or prose describing removed concepts. Update
documentation tests to require representative final forms rather than merely
checking that removed package names disappeared.

## 11. Maintained examples

Convert every maintained example using either mutable Router frontend. This
includes the known App Router examples and the Endpoint Router demonstrations,
including `examples/endpoint-router-demo` and any Endpoint-based application
under another example name.

For each example:

1. preserve its observable HTTP, WebSocket, SSE, middleware, lifespan, URL
   generation, and application-state behavior;
2. use direct `compose(routes => [...])` when no independent Router boundary is
   required;
3. return an immutable `router(...)` from an ordinary component when it owns a
   reusable subtree;
4. use route-level Endpoint objects only when class-based protocol behavior is
   genuinely clearer than an explicit closure;
5. preserve configured boundaries whose middleware, `http_default`, names, or
   routing outcomes are meaningful; and
6. update the example README and integration test in the same task.

Do not simply delete the Endpoint demo. Convert it into a focused demonstration
of class-based route endpoints composed by the declarative Router, if that
remains clear after implementation. If it becomes artificial or repetitive,
pause for review rather than inventing ceremony to justify the retained
classes.

The Starlette comparison/apple application is the canary for the final style.
It must remain concise, use declarative routing directly, and contain neither
mutable Router frontend.

## 12. Tests

### 12.1 Endpoint lifecycle repair

Tests must prove:

- configured WebSocket and SSE instances no longer fail at connection time;
- instance `to_app` retains exact object identity;
- class `to_app` constructs once per application, not per connection;
- repeated and concurrent connections use the retained instance safely;
- direct and declarative-route placement behave consistently; and
- HTTP retains its existing one-instance lifecycle.

### 12.2 HTTP method policy

Tests must prove:

- absent Route methods snapshot `allowed_methods` once;
- an explicit method string or arrayref may narrow the advertised capability;
- either finite form containing unsupported methods croaks during construction;
- scalar `methods => '*'` delegates unrestricted method ownership;
- Router PARTIAL outcomes retain the complete first-seen `Allow` union; and
- WebSocket/SSE routes ignore HTTP method capabilities.

### 12.3 Frontend removal and behavior migration

Delete tests whose only subject is the mutable frontend grammar or
materialization machinery. Convert fixtures that used a mutable Router merely
to reach shared routing behavior. Do not delete coverage of:

- declaration order;
- Route FULL/PARTIAL/NONE behavior;
- Router 404/405 and `Allow` handling;
- constraints and provider resolution;
- route, Router, Mount, and Compose middleware ordering;
- nested names and reverse URL generation;
- HTTP, WebSocket, and SSE dispatch;
- lifespan and Compose boundaries; or
- maintained example behavior.

Required final assertions include:

1. none of the five deleted modules load or ship;
2. no live code instantiates either removed frontend;
3. declarative replacements preserve route order and behavior;
4. named nested Routers remain discoverable through Mount;
5. converted examples load and pass focused integration tests;
6. the apple canary remains free of removed syntax;
7. retained Endpoint classes pass their lifecycle and protocol suites;
8. Cookbook and Tutorial tests exercise final declarative forms;
9. generated README content matches its source POD; and
10. all public POD cross-links resolve to retained modules.

Run focused tests after each migration unit. A half-translated branch may have
known failures whose cause is the active removal, but unrelated failures must
be investigated. Run the complete suite once at the final candidate HEAD and
build the distribution once without asking Dist::Zilla to rerun the suite.

## 13. Repository audit

At the final candidate, search the complete live distribution surface for:

```text
PAGI::App::Router
PAGI/App/Router
PAGI::Endpoint::Router
PAGI/Endpoint/Router
Endpoint::Router::Builder
App::Router::Builder
App::Router::Materializer
->to_router
middleware_as
app_as
```

Allowed hits are limited to unmistakably labelled historical Before examples
in `UPGRADING.md` and explicit negative removal assertions. Historical design
documents under `docs/superpowers` are records and need not be rewritten, but
the new specification and plan must describe the final decision.

Also inspect likely method-DSL remnants such as `->get`, `->post`,
`->websocket`, and `->sse` in live routing examples. Class endpoint verb methods
are valid and must not be removed merely because their names match the old
Router DSL.

The built archive must exclude all five removed modules and include the three
retained Endpoint classes.

## 14. Compatibility and release stance

No backward compatibility is required. Do not provide:

- deprecated constructors;
- import-time warnings;
- aliases between the removed frontends;
- automatic translation of string handler names;
- hidden mutable Router materialization; or
- a dependency that restores either frontend.

The upgrading guide is the compatibility aid.

`PAGI::Nano` is a known external consumer of `PAGI::App::Router` and will
break. It is an external toy project owned by the same author and is explicitly
out of scope. Record its migration as a follow-up after PAGI-Tools settles.

## 15. Risks and adversarial findings

### 15.1 Larger campaign

Removing both frontends is substantially larger than deleting App Router
alone. The cost is accepted because a temporary bridge would require disposable
implementation, tests, and documentation followed by a second migration. The
execution plan must use small commits and focused verification so size does not
turn into an uncontrolled rewrite.

### 15.2 Replacement endpoint classes currently fail

Configured WebSocket and SSE objects are not viable replacements until section
5 passes. Repair and verify them before migrating any Endpoint Router example.
Do not paper over the failure with cloning, deferred construction, or special
Router cases.

### 15.3 Class proliferation

One endpoint class per exact resource may be excessive for simple handlers.
Examples should use closures when they are clearer and endpoint subclasses when
verb dispatch, connection lifecycle, reusable behavior, or dependency holding
earns the class. Removing Endpoint Router does not require turning every method
into a new class.

### 15.4 Explicit method disagreement

Without construction-time validation, Route and `Endpoint::HTTP` can claim
different method sets and produce two different 405 paths. Section 5.2 makes
finite explicit method strings and arrays restrictions and reserves `'*'` as
the deliberate endpoint-owned escape hatch.

### 15.5 Filesystem-origin behavior

Endpoint `app_path` and exported `PAGI::Utils::app_path` are caller-sensitive
in different ways. Migration must use and test the documented direct-import
placement rather than assuming they are interchangeable through inheritance.

### 15.6 Flattening changes boundaries

Moving children from a configured Router directly into Compose can lose Router
middleware, `http_default`, description, identity, or an outcome boundary.
Preserve an explicit immutable Router whenever one of those behaviors matters.

### 15.7 Documentation churn can hide lost behavior

Examples and recipes must be converted, not casually deleted. Each migration
must identify the behavior it preserves and keep focused integration coverage.

## 16. Rejected alternatives

### 16.1 Preserve Endpoint Router through a private App Builder bridge

Rejected. The bridge is technically small but retains four condemned classes,
temporary documentation, and mutable-materialization tests solely to delete
them in the next campaign. With no released compatibility requirement, it buys
little.

### 16.2 Keep App Router but demote its documentation

Rejected. A loadable package remains discoverable and continues to impose a
second grammar and maintenance burden.

### 16.3 Keep Endpoint Router as the class-oriented frontend

Rejected. Class-oriented behavior is useful at route leaves, but a class that
also owns a second Router topology and builder grammar conflates separate
concerns.

### 16.4 Make arbitrary `to_app` objects structural

Rejected. A parent cannot safely infer an arbitrary application's route tree.
An ordinary component that wants structural discovery returns an immutable
Router explicitly from `routing`.

### 16.5 Add an application-root base class

Rejected for PAGI-Tools. A root class may eventually belong in a higher-level
framework, but it is not required to remove duplicate routing frontends.

### 16.6 Add replacement verb or string-method sugar

Rejected. Higher-level frameworks may add concise conventions. Core keeps one
declarative routing grammar and ordinary Perl closures.

### 16.7 Deprecate gradually

Rejected. The affected APIs have not been released, so a deprecation cycle
adds complexity without protecting a supported contract.

## 17. Stop conditions

Pause and revisit the design if implementation requires:

- cloning endpoint objects or mutable application configuration;
- deferred per-request/per-connection endpoint construction to make instances
  work;
- hidden Router inspection of arbitrary `to_app` objects;
- a new mutable Builder or Materializer under another name;
- automatic string-to-method binding;
- an application-root base class or dependency-injection framework;
- weakening strict declarative middleware descriptions;
- flattening configured Routers and losing observable boundaries;
- protocol-specific hacks in Route or Mount for one endpoint class;
- deleting behavior coverage merely to make the removal pass; or
- modifying PAGI::Nano or another sibling repository.

These are signs that the implementation is forcing the design rather than
cleanly applying it.

## 18. Required execution order

The implementation plan must use this order:

1. record a fresh repository work map and baseline relevant tests;
2. add failing configured-instance and constructor-count tests for WebSocket
   and SSE;
3. align their lifecycle with HTTP and make those tests pass;
4. add and implement the explicit methods/`allowed_methods` contract;
5. convert Endpoint Router examples and behavior-bearing fixtures to
   declarative routing and retained endpoint classes;
6. convert App Router examples and behavior-bearing fixtures;
7. delete both public frontends and all Builder/Materializer packages;
8. remove obsolete tests and repair live documentation and upgrading guidance;
9. regenerate README material and run the repository audits;
10. run final focused tests, the complete suite once, and one distribution
    build; and
11. request code review before integration.

Each step must be small enough to review independently. When the branch is
temporarily half-translated, the task ledger must distinguish expected
transition failures from unrelated regressions.

## 19. Work map for implementation

- **Repository:** `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools`
- **Ticket:** none
- **Working branch:** `feature/remove-mutable-router-frontends`
- **Base:** `b9cd32528a053190e9c560098f4323c78d7999bb`, the merge commit for
  PR #27
- **Owned changes:** retained Endpoint lifecycle and HTTP method-policy repair;
  removal of both mutable Router frontends and all Builder/Materializer
  machinery; declarative conversion of maintained examples and tests; POD;
  generated README; Changes; and upgrading guidance
- **Deployment boundary:** unreleased PAGI-Tools distribution
- **Push target:** a new remote `feature/remove-mutable-router-frontends`
  branch and pull request, only after authorization
- **External follow-up:** migrate PAGI::Nano after PAGI-Tools settles
- **Out of scope:** PAGI specification, PAGI::Server, PAGI::Nano, sibling
  repositories, application-root framework design, broader Response redesign,
  and unrelated Endpoint behavior

Reconfirm this map before implementation and again before any push.
