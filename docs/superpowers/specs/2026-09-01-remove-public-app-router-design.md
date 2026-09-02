# Remove the Public App Router Design

**Status:** Draft for review; implementation not started

**Date:** 2026-09-01; revised 2026-09-02 after the Endpoint Router review

**Supersedes:** All public `PAGI::App::Router` guidance in the current routing,
Compose, frontend-mounting, and application-valued-endpoint designs. The
immutable declarative Router design remains in force. `PAGI::Endpoint::Router`
is now a condemned transitional frontend: this campaign keeps it working with
the smallest practical bridge, but does not preserve it as a long-term public
alternative.

## 1. Decision

Remove the public `PAGI::App::Router` class before the next PAGI-Tools release.
Convert its applications and examples to the immutable declarative
`PAGI::Routing` constructors, normally passed directly to `PAGI::Compose`:

```perl
use PAGI::Compose qw(compose);
use PAGI::Routing qw(route mount router);

my $people = router(
    routes => [
        route('/{id}' => \&show,
            name => 'show',
        ),
    ],
);

my $app = compose(
    routes => [
        route('/' => \&home,
            name => 'home',
        ),
        mount('/people',
            app  => $people,
            name => 'people',
        ),
    ],
);
```

The immutable `$people` Router is both a PAGI application object and an
inspectable routing collection. Parent reverse routing therefore works without
`to_router`, hidden frontend materialization, or separate opaque and structural
spellings:

```perl
$app->path_for('/people/show', { id => 42 });  # /people/42
```

Do not combine this removal with the larger `PAGI::Endpoint::Router` removal.
Make only the minimum internal change required for Endpoint Router to continue
using the existing private declaration builder after the public App Router
package is removed. Do not promote, redesign, or expand that bridge.

The existing private packages `PAGI::App::Router::Builder` and
`PAGI::App::Router::Materializer` remain temporarily only because Endpoint
Router still depends on them. Both are condemned with Endpoint Router and are
removed in the later Endpoint campaign. Their temporary survival is a
sequencing decision, not an endorsement of their design.

## 2. Why removal is better than another composition rule

PAGI-Tools currently exposes three Router construction styles:

1. `PAGI::Routing`: functional, declarative, immutable;
2. `PAGI::App::Router`: mutable, imperative, closure-oriented; and
3. `PAGI::Endpoint::Router`: class-oriented, method-bound.

The middle style has no unique routing capability. It exposes the same Route,
Mount, constraints, middleware, names, HTTP defaults, WebSocket, and SSE
features through a second grammar. Programmatic route construction is already
ordinary Perl:

```perl
my @routes;

push @routes, route('/one' => \&one);
push @routes, route('/two' => \&two, methods => ['POST'])
    if $config->{enable_two};

my $router = router(routes => \@routes);
```

The mutable frontend also creates a representation leak for nested
composition:

```perl
app => $people              # dispatches, but parent cannot discover names
app => $people->to_router   # dispatches and parent can discover names
```

Fixing that leak would require a new rule that makes selected `to_app` objects
structural inside only some parent frontends. Removing the duplicate public
frontend avoids that rule entirely. A declarative child is already a
`PAGI::Routing::Router`, so one value supplies execution, inspection, reverse
routing, and immutable identity.

The intended public model is smaller:

- `Route` owns one exact leaf;
- `Mount` composes one application under a prefix;
- `Router` owns one ordered routing collection and its outcomes;
- `Compose` owns root services and lifespan;
- `PAGI::Routing` is the routing construction API; and
- `PAGI::Endpoint::HTTP`, `PAGI::Endpoint::WebSocket`, and
  `PAGI::Endpoint::SSE` may provide class-based behavior for individual route
  leaves once their instance lifecycle has been aligned in the next campaign.

Endpoint Router remains loadable during this one transitional campaign, but it
is not part of that final model.

This is closer to the Starlette model that inspired the declarative work and
is easier for users, documentation, and code-generating tools to learn.

## 3. Current scope and evidence

At the design base, `PAGI::App::Router` appears in:

- 13 files under `lib/`;
- 23 test files; and
- 10 example files.

The public `PAGI::App::Router` package itself contributes only a thin subclass
over the private Builder: it adds `named_routes`, `route_named`, and `path_for`
delegation plus public documentation. The substantial Builder and Materializer
code is also used by Endpoint Router and therefore cannot simply be deleted in
this campaign. That dependency is temporary. The Endpoint facade calls the App
Builder's private `_add_route_from` and `_mount_from` seams and its
public-looking `http_default`, `name`, `desc`, and `constraints` methods. Those
exact seams must survive the bridge; unrelated App-frontend conveniences need
not be treated as retained public value.

The Endpoint family also has a confirmed defect that this campaign must not
hide or accidentally build upon. `PAGI::Endpoint::HTTP->to_app` retains a
configured instance or constructs one class instance at compilation. The
WebSocket and SSE variants instead call `new` inside the request application.
An instantiated WebSocket or SSE endpoint therefore builds successfully but
dies on the first connection with `Attempt to bless into a reference`, while a
class endpoint constructs once per connection. This blocks the later Endpoint
replacement design, but it does not block removing the independent public App
Router frontend. Section 16 fixes the sequence.

The affected examples are straightforward declarations, not applications that
depend on runtime route mutation. Converting them to `route`, `websocket`,
`sse`, `mount`, `router`, and `compose` preserves their behavior without adding
a replacement abstraction.

`PAGI::Nano` is known to use `PAGI::App::Router` and will break. It is an
external toy project owned by the same author and is explicitly out of scope.
It can migrate after PAGI-Tools settles. No compatibility shim is justified for
it.

## 4. Goals

1. Remove `PAGI::App::Router` as a public, loadable PAGI-Tools class.
2. Establish immutable declarative routing as the sole function/closure-based
   Router API.
3. Keep Endpoint Router operational through a minimal, explicitly temporary
   private bridge without redesigning its public contract.
4. Convert every maintained App Router example to declarative construction.
5. Preserve HTTP, WebSocket, SSE, middleware, URL generation, constraints,
   defaults, declaration order, and lifespan behavior in converted examples.
6. Remove public documentation that presents three routing frontends.
7. Give users a concrete upgrade path from verb methods and chained modifiers
   to declarative options.
8. Remove obsolete public tests while retaining only the focused coverage
   needed to prove the temporary Endpoint bridge was not broken.

## 5. Non-goals

This campaign does not:

- redesign, remove, or substantially clean up `PAGI::Endpoint::Router`;
- repair `PAGI::Endpoint::WebSocket` or `PAGI::Endpoint::SSE` instance
  lifecycle;
- settle the explicit Route `methods` versus Endpoint `allowed_methods`
  contract;
- rename `PAGI::App::Router::Builder` or
  `PAGI::App::Router::Materializer`;
- add a replacement mutable Router class;
- add verb-named declarative constructors such as `get()` or `post()`;
- implement the deferred compact Route syntax;
- add `include_router`, `router =>`, `group`, or another Mount target;
- change `PAGI::Routing::Router`, Route, Mount, Resolver, or compiler semantics;
- make arbitrary `to_app` objects structurally inspectable;
- change Compose's root ownership or lifespan behavior;
- provide a deprecation period or compatibility stub;
- modify PAGI::Nano or any sibling repository; or
- preserve App Router merely as an undocumented or internal alias; or
- establish the temporary Builder or Materializer as supported internal APIs.

## 6. Public surface after removal

### 6.1 Functional applications

Function/closure-oriented applications use:

```perl
use PAGI::Compose qw(compose);
use PAGI::Routing qw(router route websocket sse mount middleware);
```

Small applications normally construct the Compose root directly:

```perl
my $app = compose(
    routes => [
        route('/' => \&home, name => 'home'),
        route('/items' => \&create,
            methods => ['POST'],
            name    => 'create_item',
        ),
        websocket('/chat' => \&chat, name => 'chat'),
        sse('/events' => \&events, name => 'events'),
    ],
    middleware => [middleware('RequestId')],
    lifespan   => {
        startup  => \&startup,
        shutdown => \&shutdown,
    },
);
```

A reusable or independently configured subtree uses `router(...)` and is
mounted directly:

```perl
my $api = router(
    routes => [
        route('/users/{id}' => \&show_user,
            name        => 'show',
            constraints => { id => qr/\A\d+\z/ },
        ),
    ],
    middleware   => [middleware(\&api_logging)],
    http_default => $api_not_found,
    desc         => 'User API',
);

my $app = compose(
    routes => [
        mount('/api',
            app  => $api,
            name => 'api',
        ),
    ],
);
```

Because `$api` is already immutable, the parent can discover `/api/show`
without conversion.

### 6.2 Transitional Endpoint Router applications

`PAGI::Endpoint::Router` remains loadable only so this campaign does not mix
two router removals. Existing Endpoint applications retain their current
syntax temporarily:

```perl
package MyApp::People;
use parent 'PAGI::Endpoint::Router';

sub routes {
    my ($self, $r) = @_;
    $r->get('/{id}' => 'show')->name('show');
}
```

Do not present this as the recommended class-oriented choice in newly written
front-page or tutorial material. New class-based behavior belongs in the
route-level `PAGI::Endpoint::HTTP`, `PAGI::Endpoint::WebSocket`, and
`PAGI::Endpoint::SSE` family after the configured-instance blocker is repaired.

This campaign does not make nested Endpoint children direct structural
providers. Existing Endpoint `to_router` composition remains unchanged until
the separate Endpoint removal campaign converts it to declarative Routers.

### 6.3 Raw PAGI applications

Native three-channel PAGI applications remain valid Route applications through
`as_app`, valid Mount applications directly, and valid server roots. Removing
App Router changes no protocol contract.

## 7. Canonical syntax migration

### 7.1 GET

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

GET plus automatic HEAD is already the default for an HTTP Route, so the
ordinary GET conversion does not need `methods => ['GET']`.

### 7.2 Other HTTP methods

Before:

```perl
$router->post('/people' => \&create)->name('create');
$router->put('/people/{id}' => \&replace)->name('replace');
$router->patch('/people/{id}' => \&update)->name('update');
$router->delete('/people/{id}' => \&remove)->name('remove');
$router->head('/people/{id}' => \&head_person)->name('head');
$router->options('/people' => \&options)->name('options');
$router->any('/health' => \&health)->name('health');
```

After:

```perl
route('/people' => \&create,
    methods => ['POST'], name => 'create'),
route('/people/{id}' => \&replace,
    methods => ['PUT'], name => 'replace'),
route('/people/{id}' => \&update,
    methods => ['PATCH'], name => 'update'),
route('/people/{id}' => \&remove,
    methods => ['DELETE'], name => 'remove'),
route('/people/{id}' => \&head_person,
    methods => ['HEAD'], name => 'head'),
route('/people' => \&options,
    methods => ['OPTIONS'], name => 'options'),
route('/health' => \&health,
    methods => '*', name => 'health'),
```

Declaration order remains literal array order. A dedicated HEAD declaration
must remain before a GET declaration for the same path when it should win.

### 7.3 WebSocket and SSE

Before:

```perl
$router->websocket('/chat/{room}' => \&chat)->name('chat');
$router->sse('/events' => \&events)->name('events');
```

After:

```perl
websocket('/chat/{room}' => \&chat, name => 'chat'),
sse('/events' => \&events, name => 'events'),
```

Direct protocol handler contracts do not change.

### 7.4 Route middleware

Before:

```perl
$router->get('/private' => [\&audit] => \&private)->name('private');
```

After:

```perl
route('/private' => \&private,
    name       => 'private',
    middleware => [middleware(\&audit)],
)
```

The core declarative list remains strict: every entry is an explicit
`middleware(...)` description. This is intentional and must not be weakened to
imitate App Router sugar.

### 7.5 Mounts

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

A closure-built child becomes an explicit child Router or a `routes` array:

```perl
mount('/api',
    routes => [
        route('/users' => \&users, name => 'users'),
    ],
    name => 'api',
)
```

### 7.6 Router options and Compose root options

An App Router used only as a disposable Compose root should normally disappear:

```perl
my $app = compose(
    routes       => \@routes,
    middleware   => \@middleware,
    http_default => $not_found,
    desc         => 'Application root',
    lifespan     => $lifespan,
);
```

A reusable Router that owns middleware, `http_default`, `desc`, identity, or a
separate outcome boundary becomes an immutable `router(...)` and remains behind
a Mount:

```perl
my $routing = router(
    routes       => \@routes,
    middleware   => \@middleware,
    http_default => $not_found,
    desc         => 'Reusable API',
);

my $app = compose(
    routes => [mount('/' => app => $routing)],
    lifespan => $lifespan,
);
```

Do not flatten a configured reusable Router merely to shorten the conversion.

## 8. Temporary Endpoint Router bridge

`PAGI::Endpoint::Router::_materialize_with` currently constructs a public
`PAGI::App::Router` and passes it through the private Endpoint facade. Replace
only that construction:

```text
require PAGI::App::Router::Builder
construct PAGI::App::Router::Builder directly
pass it to PAGI::Endpoint::Router::Builder
materialize through the existing root-local Materializer
```

The bridge depends on these App Builder seams and they must be named explicitly
so a cleanup does not remove half of the contract:

- construction and `_materialize_with`;
- private `_add_route_from` and `_mount_from`, called by the Endpoint facade;
- `http_default`;
- `name`;
- `desc`; and
- `constraints`.

App Builder's own verb methods and other App-Router-facing conveniences are not
therefore declared valuable to Endpoint. Do not trim them speculatively in this
campaign when doing so would expand the diff; equally, do not create or rewrite
tests merely to preserve them as a future contract.

No Endpoint Router user syntax or runtime semantics change. Existing class and
instance materialization, local method binding, route middleware helpers,
callback children, snapshots, HTTP/WebSocket/SSE handlers, and nested
`to_router` examples remain untouched except where the removed public App
Router constructor must be replaced.

Update private POD only enough to say that the Endpoint facade receives a
temporary internal ordered declaration builder. Both private packages are
unsupported, condemned implementation details scheduled for deletion with
Endpoint Router. Do not market, rename, generalize, or extensively redocument
them.

## 9. Files and public documentation

### 9.1 Remove the public module

Delete:

- `lib/PAGI/App/Router.pm`.

Do not leave a stub, alias, deprecation warning, or forwarding constructor.
Remove it from load tests and distribution documentation.

Retain as private Endpoint dependencies:

- `lib/PAGI/App/Router/Builder.pm`;
- `lib/PAGI/App/Router/Materializer.pm`.

Their POD must clearly say they are internal and unsupported for application
construction.

### 9.2 Correct the public routing model

Update all current public guidance, including:

- `lib/PAGI/Tools.pm` and generated `README.md`;
- `lib/PAGI/Routing.pm`;
- `lib/PAGI/Routing/Router.pm` where frontends are compared;
- `lib/PAGI/Compose.pm`;
- `lib/PAGI/Endpoint/Router.pm` only where it references the public App Router;
- `lib/PAGI/Tools/Tutorial.pod`;
- `lib/PAGI/Tools/Cookbook.pod`;
- `lib/PAGI/Lifespan.pm`;
- `lib/PAGI/Request.pm`;
- `examples/README.md`;
- `UPGRADING.md`; and
- `Changes`.

The front page must no longer say there are three public routing frontends. It
must present declarative routing as the sole routing construction API without
implying every application needs a Router wrapper:

```text
PAGI::Routing          immutable functional declarations
```

Existing Endpoint Router-specific documentation may remain for this
transitional release only where removing it would force the later Endpoint
migration into this campaign. It must not be newly elevated in overview prose,
and any text touched by this campaign must not describe it as the intended
long-term alternative. Likewise, do not advertise configured WebSocket or SSE
endpoint objects as replacements before campaign B makes that use valid.

### 9.3 Upgrade guide

Add a focused migration section with complete before/after examples for:

- GET and non-GET declarations;
- names, descriptions, and constraints;
- route, Router, and Compose middleware;
- `http_default` and `desc`;
- WebSocket and SSE;
- callback child mounts;
- reusable child Routers and reverse generation;
- programmatically assembled route arrays; and
- retained immutable snapshots.

State plainly that the class is removed with no compatibility layer because
the API is unreleased. Mention PAGI::Nano only as an external consumer that
must migrate later; do not modify it from this repository.

### 9.4 Cookbook and Tutorial quality gate

The Cookbook is a primary migration surface, not a repository-search cleanup.
Review every complete recipe that currently constructs an App Router and
rewrite the entire example coherently. Do not replace only the constructor and
leave imperative declarations, obsolete imports, unused root Mounts, stale
prose, or old output descriptions around it.

For each migrated Cookbook recipe:

- imports contain only the declarative constructors actually used;
- Route methods, names, descriptions, constraints, and middleware remain
  visible in the example;
- configured Router boundaries are preserved where behavior requires them;
- `compose(...)` is the returned application object unless the recipe
  deliberately demonstrates bare Router deployment;
- prose describes the declarative shape shown directly above it;
- internal links point to `PAGI::Routing`, Route, Mount, Router, or the
  relevant route-level Endpoint class rather than the removed class; Endpoint
  Router links may remain only in recipes that this campaign deliberately does
  not migrate; and
- extracted code continues to compile or pass the repository's existing
  Cookbook example test strategy.

Apply the same consistency review to the Tutorial's narrative flow. Remove
transitional wording such as "three frontends", "mutable App Router", or
"convert the App Router" rather than leaving concepts with no loadable class.

Update `t/00-pod/cookbook-examples.t` and related documentation tests so they
require representative declarative forms and reject stale App Router imports,
constructors, verb-method declarations, and manual root wrapping. A passing
POD syntax check alone is insufficient.

## 10. Maintained example migration

Every maintained example using `PAGI::App::Router` must be converted. The
known set includes:

- `examples/10-chat-showcase/app.pl`;
- `examples/10-chat-showcase/lib/ChatApp/HTTP.pm`;
- `examples/background-tasks/app.pl`;
- `examples/endpoint-demo/app.pl`;
- `examples/full-demo/app.pl`; and
- their README excerpts and index descriptions.

Use the smallest declarative shape that preserves behavior:

1. If the Router exists only to feed one unnamed root Mount, remove both and
   place its nodes directly in `compose(routes => [...])`.
2. If a module returns a reusable subtree with its own middleware, default,
   description, Resolver, or identity, return `router(...)` and mount that
   Router directly.
3. If the root owns middleware/default/description, move those options to
   Compose only after verifying runtime ordering and outcome ownership remain
   equivalent.
4. Preserve explicit Router boundaries when flattening would change middleware,
   404/405, name resolution, or protocol miss behavior.

Do not perform unrelated example modernization. Each converted example must
continue to load and its existing exercised HTTP, WebSocket, SSE, middleware,
and lifespan behavior must pass.

The Starlette comparison/apple example already uses declarative routing and is
the canary for the intended final style. It must remain free of
`PAGI::App::Router`.

## 11. Tests

### 11.1 Remove obsolete public-contract tests

Delete or rewrite tests whose only subject is the public App Router class,
including public constructor, public inspection delegation, and public POD
expectations. Do not retain negative tests that accidentally keep the removed
module loadable.

### 11.2 Retain focused temporary Endpoint bridge coverage

Do not create a preservation campaign for the condemned Builder and
Materializer. Keep existing tests unchanged when they still pass and adapt only
the coverage that necessarily refers to the removed public class. Focused
bridge coverage must prove that Endpoint Router can still:

- materialize a class or configured instance;
- preserve declaration order;
- construct representative Route and Mount nodes;
- apply `http_default`, `name`, `desc`, and `constraints` through the surviving
  App Builder seams; and
- produce a working immutable Router snapshot.

Existing deeper identity, rollback, callback, and cycle tests may remain until
the Endpoint removal campaign deletes their subject. Do not rewrite or expand
them merely to canonize the temporary machinery, and do not move these private
packages into a new namespace.

### 11.3 Convert shared behavioral fixtures

Tests that currently use `PAGI::App::Router` merely to construct a routing
subject must use declarative `PAGI::Routing` nodes instead. Preserve the
behavior being tested; do not delete coverage of Router middleware, URL
generation, constraints, mounts, protocol dispatch, or ordering merely because
the fixture used the removed class.

### 11.4 Required verification

Tests must prove:

1. `use PAGI::App::Router` no longer succeeds from the distribution.
2. Declarative replacements preserve declaration order and HTTP method
   behavior.
3. Named nested immutable Routers remain discoverable through Mount.
4. Converted examples load and their focused integrations pass.
5. The focused Endpoint bridge test proves class and configured Endpoint
   Router instance materialization, declaration order, representative
   Route/Mount output, the four surviving modifiers, and a usable immutable
   snapshot.
6. Existing Endpoint suites remain green without being expanded into a new
   long-term contract for Builder or Materializer.
7. No live public POD or maintained example recommends the removed class.
8. Historical Before blocks in `UPGRADING.md` are clearly labelled and are the
   only allowed public textual examples.
9. Generated README content matches its source POD.
10. Cookbook and Tutorial regression tests require the final declarative code
    forms, not merely the absence of the removed package name.
11. Public POD cross-links contain no dead `PAGI::App::Router` target.

Run focused suites during migration, the complete suite once at the final
candidate HEAD, and one distribution build without rerunning the suite through
Dist::Zilla.

## 12. Distribution and repository audit

At the final candidate, search the complete live distribution surface for:

```text
PAGI::App::Router
PAGI/App/Router.pm
App Router
->get(
->post(
->websocket(
->sse(
```

Classify every surviving hit. Allowed hits are limited to:

- private `PAGI::App::Router::Builder` or Materializer implementation/tests;
- clearly labelled historical upgrade examples;
- explicit removal assertions; and
- internal Endpoint documentation explaining its temporary private dependency.

Also search public documentation for stale concepts that may survive without
the exact package name:

```text
three public frontends
mutable App Router
imperative Router
convert the frontend
frontend->to_router
mount the mutable frontend
```

Inspect each hit in context. Historical upgrade prose may remain only when its
Before/After role is unmistakable. Current Cookbook, Tutorial, README, module
POD, Changes, and example README prose must describe only the final public
model.

The built archive must exclude `lib/PAGI/App/Router.pm` and include the private
Builder/Materializer modules required by Endpoint Router. Verify Endpoint
Router loads from the built distribution rather than only from the repository.

## 13. Compatibility and release stance

No backward compatibility is required. The routing surface is unreleased and
the repository is already in an announced breaking-change window.

Do not provide:

- a deprecated constructor;
- an import-time warning;
- an alias to Endpoint Router;
- automatic translation of method calls; or
- a dependency that restores the removed class.

The upgrade guide is the compatibility aid.

PAGI::Nano is knowingly broken until it migrates. Record it in the campaign
ledger as an external follow-up, not a blocker or repository change.

## 14. Risks and adversarial findings

### 14.1 Declarative syntax can be longer

Non-GET routes require `methods => [...]`, and strict middleware requires
`middleware(...)`. This is real. The cost buys one grammar, explicit metadata,
and direct alignment with the immutable Router model. Do not add verb helpers
inside this removal campaign to hide the difference.

### 14.2 Endpoint temporarily retains condemned mutable machinery

Yes. This is a sequencing compromise, not a claim that Endpoint Router needs
or should keep the machinery. Removing it here would combine a narrow public
frontend deletion with a substantially larger Endpoint migration touching its
API, protocol endpoint lifecycle, examples, documentation, and thousands of
lines of tests. Keep the bridge small, avoid improvements, and delete it in the
separate Endpoint campaign.

### 14.3 Private modules remain under `PAGI::App::Router::*`

This namespace is inelegant after removing the parent package. Renaming it now
would create churn in code already scheduled for deletion. Minimal private POD
and absence from public recommendations are sufficient temporarily. The later
Endpoint project removes these packages rather than finding them a permanent
home.

### 14.4 Removing examples could hide feature coverage

Examples must be converted, not deleted, unless an example exists solely to
demonstrate App Router syntax. Preserve each example's actual PAGI behavior and
exercise it through focused integration tests.

### 14.5 Root flattening can change semantics

Moving nodes from a configured Router into Compose can lose Router middleware,
defaults, description, identity, or an outcome boundary. Apply the decision
rule in section 10 rather than mechanically replacing every root Mount.

### 14.6 External users may exist

The API is unreleased, and the known external consumer is explicitly accepted.
Carrying a third frontend indefinitely would cost more than an upgrade now.

## 15. Rejected alternatives

### 15.1 Make App Router children automatically structural

Rejected. It repairs one symptom while retaining the duplicate public grammar
and introducing a special materialization rule for selected application
objects.

### 15.2 Keep App Router but demote its documentation

Rejected. The loadable package remains discoverable by users and tooling and
continues to impose maintenance and consistency costs.

### 15.3 Deprecate it gradually

Rejected. This surface has not been released, so a deprecation cycle provides
cost without protecting a supported contract.

### 15.4 Replace it with verb helper functions

Rejected for this campaign. That would substitute a second declarative grammar
while the existing `route(..., methods => ...)` contract is adequate.

### 15.5 Remove Endpoint Router in this same campaign

Rejected as sequencing, not as direction. Endpoint Router is also scheduled
for removal, but combining it here would block the well-understood App Router
deletion behind a larger redesign and migration. The route-level Endpoint
classes first need a separate configured-instance repair, and existing
Endpoint Router applications then need deliberate conversion to declarative
Routers. Section 16 records the ordered campaigns.

## 16. Ordered follow-up campaigns

This design is the first of three separately specified, planned, tracked, and
reviewed campaigns. Do not merge their scopes merely because later deletion
makes some temporary code uninteresting.

### 16.1 Campaign A: remove public App Router

Execute this specification first. Remove the public frontend, convert its
applications and documentation to declarative routing, and retain only the
minimal Endpoint bridge in section 8. Do not fix Endpoint protocol classes or
migrate Endpoint Router applications here.

### 16.2 Campaign B: repair retained route-level Endpoint classes

Before presenting route-level endpoint objects as the Endpoint Router
replacement, write and execute a separate design that aligns
`PAGI::Endpoint::HTTP`, `PAGI::Endpoint::WebSocket`, and
`PAGI::Endpoint::SSE`:

- a class `to_app` call constructs exactly one instance at application
  compilation;
- an instance `to_app` call retains that exact configured instance;
- no endpoint constructs once per request or connection;
- all three document that the retained instance is shared and must not hold
  request- or connection-local state;
- configured WebSocket and SSE objects work both directly and as declarative
  route targets; and
- focused tests reproduce and close the current connection-time `Attempt to
  bless into a reference` failures.

That campaign must also settle the two HTTP 405 ownership paths. Without
explicit Route `methods`, snapshot the endpoint's `allowed_methods` capability.
An explicit methods array is a restriction and must not advertise a method the
endpoint does not support; contradictory declarations should fail during Route
construction. Scalar `methods => '*'` is the explicit escape hatch by which
the endpoint owns all method dispatch and method failures. Standalone and
mounted Endpoint applications continue to own their internal 405 behavior.

### 16.3 Campaign C: remove Endpoint Router and mutable materialization

After campaign B establishes working route-level class endpoints, write and
execute a separate Endpoint removal design that:

- removes `PAGI::Endpoint::Router` and
  `PAGI::Endpoint::Router::Builder`;
- removes the remaining `PAGI::App::Router::Builder` and
  `PAGI::App::Router::Materializer` packages;
- converts Endpoint Router examples and tests to declarative Routers,
  route-level Endpoint objects, or explicit closures;
- removes string method targets, `middleware_as`, `app_as`, `new_request`, and
  `to_router` with the obsolete frontend;
- moves no helper merely for compatibility; a helper survives only if the new
  design demonstrates value independent of Endpoint Router;
- updates the Cookbook, Tutorial, overview documentation, upgrading guide,
  examples, tests, load lists, and distribution contents; and
- leaves application-root classes to ordinary application code or a future
  higher-level framework rather than inventing one in PAGI-Tools.

When replacing Endpoint's `app_path`, call the exported
`PAGI::Utils::app_path` directly in the module that owns the assets. Its origin
is the importing/calling package, unlike Endpoint's class-derived helper, so a
test must cover the documented placement and an inherited base-class wrapper
must not be assumed equivalent.

Inline provider examples in that campaign must import their providers in the
declaration package, for example:

```perl
use Type::Standard qw(Int);

route('/people/{person_id:&Int}' => $endpoint);
```

## 17. Stop conditions

Pause and revisit the design if implementation requires:

- changing Route, Mount, Router, Resolver, or compiler runtime semantics;
- adding a compatibility class or hidden mutable Router alias;
- adding method-specific declarative constructors;
- redesigning Endpoint Router's public API;
- repairing route-level Endpoint lifecycle or 405 policy in this campaign;
- rewriting examples beyond their routing construction;
- weakening strict declarative middleware descriptions;
- flattening configured Routers and losing outcome or middleware boundaries;
- deleting protocol/integration coverage instead of converting its fixture; or
- modifying PAGI::Nano or another sibling repository.

These indicate the removal has expanded beyond eliminating one redundant
public frontend.

## 18. Work map for implementation

- **Repository:** `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools`
- **Ticket:** none
- **Working branch:** `feature/remove-public-app-router`
- **Spec base:** `b9cd32528a053190e9c560098f4323c78d7999bb`, the merge commit
  for PR #27
- **Owned changes:** public App Router removal; minimal condemned Endpoint
  bridge adjustment; declarative conversion of maintained App Router examples;
  focused bridge verification; POD; generated README; Changes; and upgrade
  guidance
- **Deployment boundary:** unreleased PAGI-Tools distribution
- **Push target:** a new remote `feature/remove-public-app-router` branch and
  pull request, only after authorization; PR #27 is merged and closed
- **Required PAGI-Tools follow-ups:** separately spec and execute route-level
  Endpoint instance repair, then Endpoint Router and mutable materializer
  removal, in that order
- **External follow-up:** migrate PAGI::Nano after PAGI-Tools settles
- **Out of scope:** PAGI specification, PAGI::Server, PAGI::Nano, sibling
  repositories, route-level Endpoint lifecycle repair, and Endpoint Router
  removal

Reconfirm the map before implementation and again before any push.
