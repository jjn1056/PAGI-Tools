# Compose Retained-Router Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every `PAGI::Compose` own one retained immutable Router, replace `app` mode with explicit `routes` or `router` construction, preserve root lifespan and safety behavior, and migrate the entire live repository to the coherent API.

**Architecture:** `PAGI::Compose` stores a `PAGI::Routing::Router` in both construction forms and delegates routing inspection to it. `PAGI::Compose::Compiler` compiles that exact Router once per `to_app`, then applies the existing application middleware, lifespan dispatcher, ErrorHandler, ResponseGuard, and outer HEAD boundary without reconstructing routing. Mutable and Endpoint frontends cross through `to_router`; arbitrary native applications are no longer Compose targets.

**Tech Stack:** Perl 5.18-compatible distribution code, Perl 5.40+ example syntax where already declared, Future::AsyncAwait, Test2::V0, Dist::Zilla, PAGI Test Client, immutable `PAGI::Routing` descriptions.

**Spec:** `docs/superpowers/specs/2026-08-31-compose-retained-router-design.md`

## Global Constraints

- Repository: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools`.
- Ticket: none; this is the approved Compose retained-Router redesign.
- Execution branch: `feature/compose-retained-router` in the isolated `.worktrees/compose-retained-router` worktree.
- Base: `558b14c282a38051bd8c1bb712290fe1df398330`, which was both local `main` and `origin/main` when the execution worktree was created on 2026-09-01. Reconfirm it before Task 1 and record any later upstream movement without silently rebasing the campaign.
- Owned changes: all PAGI-Tools runtime code, tests, examples, README/POD, Tutorial, Cookbook, `UPGRADING.md`, and `Changes` required by the approved Compose contract.
- Deployment boundary: one unreleased PAGI-Tools distribution. PAGI and PAGI::Server are read-only normative/integration references.
- Push target: `origin/feature/compose-retained-router`, only after implementation, task reviews, final verification, and user authorization.
- Breaking changes to unreleased PAGI-Tools APIs are allowed. Do not retain aliases, warnings, hidden Mount conversion, arity inference, or compatibility parsing for `compose(app => ...)`.
- Compose requires exactly one of `routes` or `router`. Both forms always produce one retained `PAGI::Routing::Router`.
- `router` accepts only an instantiated `PAGI::Routing::Router` (including a genuine subclass). `PAGI::App::Router` and `PAGI::Endpoint::Router` cross explicitly through `to_router`.
- Routes form may accept `http_default` and `desc`; Router form rejects those keys because the retained Router is authoritative.
- Compose `middleware` remains application middleware. Do not add `router_middleware` or reinterpret `middleware` based on constructor mode.
- Compose retains root lifespan ownership. Do not add Router lifespan callbacks or send lifespan into the retained Router.
- Preserve Router 404/405/Allow, routing metadata, reverse routing, HTTP/WebSocket/SSE matching, ErrorHandler, ResponseGuard, middleware order, and HEAD behavior.
- Preserve the `558b14c` settlement baseline: ResponseGuard rejects body-before-start through the returned send Future, re-raises that protocol fault after completion even when an application swallows the rejection, exempts a defined abnormal disconnect from incomplete-response errors, and still requires terminal bodies and declared trailers. Do not alter `request_ended_abnormally`, `BufferedResponse`, GZip streaming, or any other buffering/disconnect behavior in this campaign.
- Preserve the existing shallow-copy contract. Do not add cloning, freezing, hidden caches, mutation snapshots, or defensive copies beyond those already made by Router and Compose accessors.
- Do not design a generic replacement for Compose app mode in this campaign. Native applications remain directly deployable.
- All live examples under `examples/` are in scope. The Starlette apples example is the primary readability canary, not the only migration target.
- Historical files under `docs/superpowers/specs/` and `docs/superpowers/plans/` remain historical records. Do not mechanically rewrite them.
- Use TDD for runtime changes. Run focused suites after each task and the complete distribution test suite once, at final candidate HEAD.
- Run project Perl commands through `perlbrew exec --with perl-5.42.2@default ...` unless execution-time repository instructions name a newer authoritative environment.
- Before production changes, create and force-add `.superpowers/sdd/2026-08-31-compose-retained-router/progress.md`. Give every task one row with status, implementation commit SHA, real test counts, and evidence. Commit each implementation first, then immediately update the ledger in a task-local tracking commit.
- Record deviations as `DEV-NN` with the conflicting requirement, evidence, proposed resolution, rationale, and explicit user approval before another task depends on the deviation.

---

## File Structure

| File or family | Responsibility after this campaign | Task |
| --- | --- | --- |
| `lib/PAGI/Compose.pm` | Owns one Router, constructor validation, accessors, and Router delegation | 1 |
| `lib/PAGI/Compose/Compiler.pm` | Compiles the retained Router and applies root runtime boundaries | 2 |
| `t/compose/01-description.t` | Constructor, identity, delegation, and diagnostics contract | 1 |
| `t/compose/02-dispatch.t`, `06-failsafes.t`, `07-response-guard.t` | Retained-Router dispatch and root safety behavior | 2 |
| `t/compose/03-lifespan.t`, `04-middleware.t`, `05-head-concurrency.t` | Root-only lifecycle and middleware/HEAD ordering | 3 |
| `lib/PAGI/App/Router.pm`, `lib/PAGI/Endpoint/Router.pm`, related integration tests | Explicit frontend-to-Router boundary | 4 |
| `examples/starlette-apples/`, `examples/15-large-application/` | Flagship functional and modular examples | 5 |
| Remaining `examples/` and their integration tests | Complete live example migration | 6 |
| Public POD, Tutorial, Cookbook, `UPGRADING.md`, `Changes` | User-facing contract and migration guide | 7 |
| Repository-wide searches and distribution verification | Proves no live old mode or stale claims remain | 8 |

---

### Task 1: Make Compose Own One Retained Router

**Files:**

- Modify: `lib/PAGI/Compose.pm`
- Modify: `t/compose/01-description.t`
- Create: `.superpowers/sdd/2026-08-31-compose-retained-router/progress.md`

**Interfaces:**

- Consumes: `PAGI::Routing::Router->new(routes => ..., http_default => ..., desc => ...)` and an instantiated `PAGI::Routing::Router` supplied through `router`.
- Produces: `PAGI::Compose->router`, `routes`, `http_default`, `desc`, `named_routes`, `route_named`, `path_for`, existing `middleware`, existing `lifespan`, and `to_app`; removes `app`.

- [ ] **Step 1: Verify the execution worktree, branch, base, and ledger.**

Use `superpowers:using-git-worktrees` before implementation. The isolated
worktree was created from `origin/main` at `558b14c`. Verify rather than
recreate it, fetch `origin`, and record the exact output of:

```bash
git branch --show-current
git rev-parse HEAD
git status --short
```

Create the ledger with the exact observed base SHA:

```markdown
# SDD ledger — plan: docs/superpowers/plans/2026-08-31-compose-retained-router.md

## Compose Retained-Router Execution

| Task | Status | Implementation commit | Tests | Evidence |
|---|---|---|---|---|
| 1. Retained description | in progress | — | — | — |
| 2. Compiler and safety | pending | — | — | — |
| 3. Lifespan and ordering | pending | — | — | — |
| 4. Router frontends | pending | — | — | — |
| 5. Flagship examples | pending | — | — | — |
| 6. Remaining examples | pending | — | — | — |
| 7. Public docs and upgrade | pending | — | — | — |
| 8. Final verification | pending | — | — | — |

Work map: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools`, ticket none,
branch `feature/compose-retained-router`, deployment boundary PAGI-Tools
distribution, push target `origin/feature/compose-retained-router` after
authorization. Add a `Base:` field containing the exact 40-character output
of `git rev-parse HEAD` from this worktree before committing the ledger.

## Deviations

None.
```

The approved design and plan are intentionally ignored working artifacts in
the primary checkout, which also contains user-owned untracked material that
must remain untouched. Copy these exact files from the primary checkout into
the isolated execution worktree before the campaign-start commit:

```bash
cp /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/docs/superpowers/specs/2026-08-31-compose-retained-router-design.md docs/superpowers/specs/2026-08-31-compose-retained-router-design.md
cp /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/docs/superpowers/plans/2026-08-31-compose-retained-router.md docs/superpowers/plans/2026-08-31-compose-retained-router.md
```

Verify both copied files match their source with `cmp`. Then force-add and
commit the approved design, plan, and ledger so every worker and reviewer sees
the governing artifacts:

```bash
git add -f \
  docs/superpowers/specs/2026-08-31-compose-retained-router-design.md \
  docs/superpowers/plans/2026-08-31-compose-retained-router.md \
  .superpowers/sdd/2026-08-31-compose-retained-router/progress.md
git commit -m "docs: start retained router campaign"
```

- [ ] **Step 2: Replace description tests with the new construction matrix.**

In `t/compose/01-description.t`, retain import and no-overload tests, then construct one named leaf and one Router:

```perl
use Scalar::Util qw(refaddr);
use PAGI::Pages ();
use PAGI::Routing qw(router route middleware);

my $leaf = route('/' => sub {
    return PAGI::Response::Text->new('home');
}, name => 'home');

my $default = PAGI::Pages->not_found(detail => 'No root route');
my $routing = router(
    routes       => [$leaf],
    http_default => $default,
    desc         => 'Retained root',
);

my $composition = compose(
    router     => $routing,
    middleware => [middleware('RequestId')],
    lifespan   => { startup => sub { return } },
);
```

Assert:

```perl
is(refaddr($composition->router), refaddr($routing),
    'router form retains exact Router identity');
is($composition->routes, [$leaf], 'routes delegates to retained Router');
is(refaddr($composition->http_default), refaddr($default),
    'http_default delegates by identity');
is($composition->desc, 'Retained root', 'desc delegates');
is($composition->path_for('/home'), '/', 'path_for delegates');
is(refaddr($composition->route_named('/home')), refaddr($leaf),
    'route_named delegates');
ok(exists $composition->named_routes->{'/home'},
    'named_routes delegates');
ok(!$composition->can('app'), 'retired app accessor is absent');
```

Add routes-form assertions:

```perl
my $from_routes = compose(
    routes       => [$leaf],
    http_default => $default,
    desc         => 'Constructed root',
);

isa_ok($from_routes->router, 'PAGI::Routing::Router');
is($from_routes->routes, [$leaf], 'routes form retains constructed Router');
is(refaddr($from_routes->http_default), refaddr($default),
    'routes form passes http_default to Router');
is($from_routes->desc, 'Constructed root',
    'routes form passes desc to Router');
```

Keep the existing shallow middleware/lifespan accessor mutation checks. Route list mutation tests now verify Router's existing shallow list copy rather than a second Compose-owned copy.

- [ ] **Step 3: Add the complete failing validation matrix.**

Require these failures:

```perl
my @invalid = (
    ['missing target', [], qr/exactly one of routes or router/],
    ['both targets', [routes => [], router => $routing],
        qr/exactly one of routes or router/],
    ['retired app Router', [app => $routing],
        qr/no longer accepts 'app'.*router =>/s],
    ['retired native app', [app => sub { return }],
        qr/no longer accepts 'app'.*deploy.*directly/s],
    ['router undef', [router => undef],
        qr/instantiated PAGI::Routing::Router/],
    ['router coderef', [router => sub { return }],
        qr/instantiated PAGI::Routing::Router/],
    ['router generic to_app object',
        [router => DeferredComponentCheck->new],
        qr/instantiated PAGI::Routing::Router/],
    ['router with http_default',
        [router => $routing, http_default => $default],
        qr/http_default cannot be combined with router/],
    ['router with desc', [router => $routing, desc => 'override'],
        qr/desc cannot be combined with router/],
    ['routes not array', [routes => {}],
        qr/routes must contain PAGI::Routing nodes/],
);
```

Retain the odd-list, unknown-option, invalid middleware, and invalid lifespan cases, changing only their target setup from `routes`/`app` to the new valid forms. Explicit `http_default => undef` and `desc => undef` in Router form must fail because presence, not truthiness, is the conflict.

- [ ] **Step 4: Run the description test and confirm RED.**

Run:

```bash
perlbrew exec --with perl-5.42.2@default prove -lv t/compose/01-description.t
```

Expected: failures name the absent `router` constructor/accessor/delegations and the still-accepted `app` option.

- [ ] **Step 5: Implement one retained Router in `PAGI::Compose`.**

Import `blessed` from `Scalar::Util`. Replace target validation with:

```perl
my %allowed = map { $_ => 1 }
    qw(routes router http_default desc middleware lifespan);

if (exists $opts{app}) {
    my $hint = blessed($opts{app})
        && $opts{app}->isa('PAGI::Routing::Router')
        ? "pass it with router => \$router"
        : 'deploy a non-routing PAGI application directly';
    croak "compose no longer accepts 'app'; $hint";
}

my $has_routes = exists $opts{routes};
my $has_router = exists $opts{router};
croak 'compose requires exactly one of routes or router'
    unless $has_routes != $has_router;

my $router;
if ($has_routes) {
    $router = PAGI::Routing::Router->new(
        routes => $opts{routes},
        (exists $opts{http_default}
            ? (http_default => $opts{http_default}) : ()),
        (exists $opts{desc} ? (desc => $opts{desc}) : ()),
    );
}
else {
    croak 'compose router must be an instantiated PAGI::Routing::Router'
        unless blessed($opts{router})
            && $opts{router}->isa('PAGI::Routing::Router');
    croak 'compose http_default cannot be combined with router; configure the retained Router'
        if exists $opts{http_default};
    croak 'compose desc cannot be combined with router; configure the retained Router'
        if exists $opts{desc};
    $router = $opts{router};
}
```

The `app` diagnostic check must occur before the generic unknown-option loop so users get the migration message. Store only `router`, Compose middleware, and lifespan. Add direct delegation:

```perl
sub router       { $_[0]->{router} }
sub routes       { $_[0]->{router}->routes }
sub http_default { $_[0]->{router}->http_default }
sub desc         { $_[0]->{router}->desc }
sub named_routes { $_[0]->{router}->named_routes }
sub route_named  { $_[0]->{router}->route_named($_[1]) }
sub path_for     { my $self = shift; return $self->{router}->path_for(@_) }
```

Delete `app`. Do not add `url_for`, node accessors, or conditional return values.

- [ ] **Step 6: Run focused constructor and Router tests.**

Run:

```bash
perlbrew exec --with perl-5.42.2@default prove -lv t/compose/01-description.t t/routing/01-constructors.t t/routing/03-reverse-inspection.t t/routing/13-url-helper.t
```

Expected: PASS. Record actual files, tests, and assertions from the harness output.

- [ ] **Step 7: Commit Task 1 and record evidence.**

```bash
git add lib/PAGI/Compose.pm t/compose/01-description.t
git commit -m "refactor: make Compose retain one Router"
```

Run `git rev-parse HEAD`, update Task 1's ledger row with the real SHA and focused test totals, set Task 2 to `in progress`, then commit the ledger alone:

```bash
git add -f .superpowers/sdd/2026-08-31-compose-retained-router/progress.md
git commit -m "docs: record retained description evidence"
```

---

### Task 2: Compile the Retained Router and Preserve Root Safety

**Files:**

- Modify: `lib/PAGI/Compose/Compiler.pm`
- Modify: `t/compose/02-dispatch.t`
- Modify: `t/compose/06-failsafes.t`
- Modify: `t/compose/07-response-guard.t`
- Modify: `.superpowers/sdd/2026-08-31-compose-retained-router/progress.md`

**Interfaces:**

- Consumes: `PAGI::Compose->router`, whose `to_app` returns a fresh native PAGI coderef.
- Produces: one retained Router compilation per Compose `to_app`; no `_compile_target`, no routes reconstruction, and unchanged HTTP safety boundaries.

- [ ] **Step 1: Add a counting Router test double.**

In `t/compose/02-dispatch.t`, define:

```perl
{
    package Local::CountingRouter;
    use parent 'PAGI::Routing::Router';
    our $TO_APP_CALLS = 0;

    sub to_app {
        my ($self) = @_;
        ++$TO_APP_CALLS;
        return $self->SUPER::to_app;
    }
}
```

Construct it with one route, then assert:

```perl
local $Local::CountingRouter::TO_APP_CALLS = 0;
my $routing = Local::CountingRouter->new(routes => [
    route('/' => sub { return PAGI::Response::Text->new('home') }),
]);
my $description = compose(router => $routing);
is($Local::CountingRouter::TO_APP_CALLS, 0,
    'Compose construction does not compile Router');
my $app_one = $description->to_app;
is($Local::CountingRouter::TO_APP_CALLS, 1,
    'first Compose to_app compiles retained Router once');
my $app_two = $description->to_app;
is($Local::CountingRouter::TO_APP_CALLS, 2,
    'second Compose to_app creates one fresh Router graph');
```

Run both compiled apps and assert they dispatch independently.

- [ ] **Step 2: Migrate dispatch tests away from app mode.**

For request dispatch, use `compose(routes => [...])` or
`compose(router => router(...))`. Delete the tests claiming Compose delegates an
unknown extension scope to an arbitrary app: after this redesign Compose is a
routed HTTP/WebSocket/SSE root, not a generic extension-scope boundary.

Retain immediate and Future-backed completion normalization by putting
`as_app` targets behind a selected Route or root Mount. Each fixture must emit
a complete response so ResponseGuard is testing completion shape rather than
turning intentional silence into a 500:

```perl
my $app = compose(routes => [
    route('/native' => as_app(async sub {
        my ($scope, $receive, $send) = @_;
        await Future->wrap($send->({
            type => 'http.response.start', status => 204, headers => [],
        }));
        await Future->wrap($send->({
            type => 'http.response.body', body => '', more => 0,
        }));
        return;
    })),
])->to_app;
```

For object compilation, mount or route an application object and continue
asserting its `to_app` runs once per enclosing compilation, not per request.

- [ ] **Step 3: Reframe failsafe tests through selected routing applications.**

Replace generic target cases such as `compose(app => sub { return })` with
selected applications:

```perl
my $silent = compose(routes => [
    route('/silent' => as_app(sub { return })),
])->to_app;

my $throwing = compose(routes => [
    route('/explode' => as_app(sub { die "DB connection lost\n" })),
])->to_app;
```

Preserve assertions that:

- selected silence becomes one safe 500;
- synchronous throws and failed Futures become one safe 500;
- explicit matched 404/405/406/415/500 responses pass unchanged;
- Router NONE and PARTIAL remain ordinary 404/405 outcomes and do not warn;
- a selected opaque Mount that completes silently is guarded; and
- routing metadata is not reinterpreted by Compose.

Keep direct `PAGI::Compose::ResponseGuard->wrap(...)` unit tests direct where
they exercise event-level guard behavior. Only Compose integration fixtures
that formerly depended on `compose(app => ...)` should route selected native
applications through the retained Router. Preserve, without semantic rewrite:

- body-before-start failing the send Future rather than throwing synchronously;
- the post-completion re-raise when an application swallows that rejection;
- the abnormal-disconnect exemption based on `request_ended_abnormally`;
- terminal-body and declared-trailer requirements; and
- the distinction between an abnormal disconnect and clean completion.

The current baseline emits a void-context warning from the test that
deliberately swallows `else_done`. Remove that warning with a lexical holding
the returned Future; do not change the guard or the behavior the test covers.

- [ ] **Step 4: Run the focused tests and confirm RED.**

Run:

```bash
perlbrew exec --with perl-5.42.2@default prove -lv t/compose/02-dispatch.t t/compose/06-failsafes.t t/compose/07-response-guard.t
```

Expected: the counting test shows the compiler still reads nonexistent
`routes`/`app` modes or reconstructs a Router; migrated request cases fail
until compiler access is changed.

- [ ] **Step 5: Compile the exact retained Router.**

In `PAGI::Compose::Compiler`, replace `_compile_target` and its mode branch
with:

```perl
my $target = $description->router->to_app;
```

Delete `_compile_target`. Keep `PAGI::Utils` because ErrorHandler environment
resolution still calls `is_development`. Do not call `router->routes`, create
a second Router, or special-case Router subclasses.

Keep the existing runtime layers and order unchanged:

```perl
my $author_app = PAGI::Routing::Middleware->_wrap_descriptors(
    $description->middleware,
    $dispatcher,
);
my $http_app = PAGI::Compose::ResponseGuard->wrap($author_app);
$http_app = PAGI::Middleware::ErrorHandler->_new_compose_failsafe(...)
    ->wrap($http_app);
```

The dispatcher still consumes lifespan before `$target` and invokes the
retained Router for every non-lifespan scope.

- [ ] **Step 6: Run focused Compose safety tests.**

Run:

```bash
perlbrew exec --with perl-5.42.2@default prove -lv t/compose/02-dispatch.t t/compose/06-failsafes.t t/compose/07-response-guard.t t/routing/06-head.t t/utils/request-ended-abnormally.t t/middleware/buffered-response.t t/middleware/disconnect-laundering.t
```

Expected: PASS with one Router compile per Compose `to_app`, all safety
responses intact, and no application-mode tests remaining.

- [ ] **Step 7: Commit Task 2 and record evidence.**

```bash
git add lib/PAGI/Compose/Compiler.pm \
  t/compose/02-dispatch.t t/compose/06-failsafes.t \
  t/compose/07-response-guard.t
git commit -m "refactor: compile the retained Compose Router"
```

Record the real SHA and focused totals, set Task 3 to `in progress`, and make
the immediate ledger commit.

---

### Task 3: Pin Root-Only Lifespan and Boundary Ordering

**Files:**

- Modify: `t/compose/03-lifespan.t`
- Modify: `t/compose/04-middleware.t`
- Modify: `t/compose/05-head-concurrency.t`
- Modify: `lib/PAGI/Compose.pm` only if the current POD beside code must be corrected for a test
- Modify: `.superpowers/sdd/2026-08-31-compose-retained-router/progress.md`

**Interfaces:**

- Consumes: retained Router target from Tasks 1-2 and existing Compose lifespan dispatcher.
- Produces: executable proof that Compose middleware sees lifespan, Router middleware does not, nested lifecycle never runs, and direct Router strict lifespan fails explicitly.

- [ ] **Step 1: Migrate lifecycle fixtures to retained Routers.**

Replace every `compose(app => $never_target, lifespan => ...)` with a Router
whose HTTP leaf would die if incorrectly invoked:

```perl
my $routing = router(routes => [
    route('/' => as_app(sub {
        die "request endpoint received lifespan\n";
    })),
]);

my $app = compose(
    router   => $routing,
    lifespan => {...},
)->to_app;
```

Retain exact-state-identity, callback awaiting, startup failure, shutdown
failure, malformed state, concurrent lifespan, and send/receive failure
assertions.

- [ ] **Step 2: Add the middleware visibility test.**

Create one Compose middleware and one Router middleware that record scope
types before delegating:

```perl
my (@compose_types, @router_types);
my $routing = router(
    routes => [],
    middleware => [middleware(sub {
        my ($inner) = @_;
        return sub {
            my ($scope) = @_;
            push @router_types, $scope->{type};
            return $inner->(@_);
        };
    })],
);

my $app = compose(
    router => $routing,
    middleware => [middleware(sub {
        my ($inner) = @_;
        return sub {
            my ($scope) = @_;
            push @compose_types, $scope->{type};
            return $inner->(@_);
        };
    })],
)->to_app;
```

Run startup/shutdown and assert `@compose_types` contains one `lifespan` while
`@router_types` is empty. Then make an HTTP request and assert both contain
`http` in outer-Compose/inner-Router order.

- [ ] **Step 3: Pin mounted Compose and Router behavior.**

Construct an inner Compose with its own callbacks and one route, mount it
under an outer Compose Router, run only the outer lifespan exchange, and
assert:

- outer callbacks each run once;
- inner callbacks remain zero;
- neither inner Router nor inner endpoint receives lifespan; and
- an HTTP request under the Mount still reaches the inner route.

Also mount a plain child Router and assert it receives HTTP but no lifespan.

- [ ] **Step 4: Pin strict direct-Router failure.**

Using `PAGI::Test::Client`:

```perl
my $bare = router(routes => [])->to_app;
my $client = PAGI::Test::Client->new(app => $bare, lifespan => 1);
like dies { $client->start },
    qr/lifespan.*returned without sending.*startup/s,
    'bare Router is not a strict-lifespan root';
```

Then construct `compose(router => router(routes => []))`, enable Test Client
lifespan, and assert start/shutdown complete successfully with no callbacks.

- [ ] **Step 5: Run lifecycle and ordering tests.**

Run:

```bash
perlbrew exec --with perl-5.42.2@default prove -lv t/compose/03-lifespan.t t/compose/04-middleware.t t/compose/05-head-concurrency.t t/routing/10-head-boundary.t
```

Expected: PASS. If direct Router strict failure hangs instead of producing the
Test Client's immediate “returned without sending” diagnostic, stop and record
a deviation; do not add sleeps, timeouts, or synthetic lifespan events to
force the test.

- [ ] **Step 6: Commit Task 3 and record evidence.**

```bash
git add t/compose/03-lifespan.t t/compose/04-middleware.t \
  t/compose/05-head-concurrency.t
git commit -m "test: pin Compose root lifespan ownership"
```

Include `lib/PAGI/Compose.pm` only if changed. Record the real SHA and totals,
set Task 4 to `in progress`, and commit the ledger update.

---

### Task 4: Move Router Frontends and Library Integrations to `router =>`

**Files:**

- Modify: `lib/PAGI/Endpoint/Router.pm` POD only
- Modify: `lib/PAGI/App/Router.pm` POD only
- Modify: `lib/PAGI/App/Cascade.pm`
- Modify: `lib/PAGI/Middleware/ErrorHandler.pm`
- Modify: `lib/PAGI/Routing.pm`
- Modify: `lib/PAGI/Tools.pm`
- Modify: `lib/PAGI/Tools/Tutorial.pod`
- Modify: `lib/PAGI/Tools/Cookbook.pod`
- Modify: `t/app-router.t`
- Modify: `t/app-router/03-composition-order.t`
- Modify: `t/integration-router-application-boundaries.t`
- Modify: `t/upgrading-router-frontends.t`
- Modify: `t/upgrading-routing-composition.t`
- Modify: `.superpowers/sdd/2026-08-31-compose-retained-router/progress.md`

**Interfaces:**

- Consumes: `compose(router => $immutable_router)` from Tasks 1-3.
- Produces: every framework frontend and live library example crosses the immutable Router boundary explicitly; bare frontend `to_app` remains bare Router compilation.

- [ ] **Step 1: Add frontend boundary assertions.**

In the frontend/upgrading tests, assert:

```perl
my $builder = PAGI::App::Router->new;
$builder->get('/' => \&home)->name('home');

like dies { compose(router => $builder) },
    qr/instantiated PAGI::Routing::Router/,
    'Compose does not guess mutable frontend materialization';

my $routing = $builder->to_router;
my $root = compose(router => $routing);
is(refaddr($root->router), refaddr($routing),
    'explicit App Router snapshot is retained');
```

Add the same assertion for `PAGI::Endpoint::Router->to_router`. Keep tests
proving `$builder->to_app` is still a bare Router app with Router 404/405 but no
Compose ResponseGuard/lifespan.

- [ ] **Step 2: Run frontend tests and confirm RED.**

Run:

```bash
perlbrew exec --with perl-5.42.2@default prove -lv t/app-router.t t/app-router/03-composition-order.t t/integration-router-application-boundaries.t t/upgrading-router-frontends.t t/upgrading-routing-composition.t
```

Expected: failures identify live `compose(app => ...)` code and stale upgrade
expectations.

- [ ] **Step 3: Preserve bare frontend compilation and change root call sites.**

Do not change `PAGI::Endpoint::Router->to_app` or
`PAGI::App::Router::Builder->to_app`; both currently and deliberately compile
a bare Router through the equivalent of:

```perl
my $router = $self->to_router;
return $router->to_app;
```

Update executable root integration elsewhere that passes a Router through
Compose app mode. Do not make Compose call `to_router` itself, and do not
silently change either frontend's `to_app` into a Compose root.

- [ ] **Step 4: Migrate live module examples and assertions.**

Change every current `compose(app => $routing)` in the listed library files to
`compose(router => $routing)`. When the value is a mutable/Endpoint frontend,
use its explicit `to_router`. Preserve examples of directly deployed native
apps rather than wrapping them in Compose.

At this task, update only the minimum adjacent prose required for focused POD
or upgrading tests. Task 7 performs the complete editorial pass.

- [ ] **Step 5: Run focused frontend and POD-example tests.**

Run:

```bash
perlbrew exec --with perl-5.42.2@default prove -lv t/app-router.t t/app-router/03-composition-order.t t/integration-router-application-boundaries.t t/upgrading-router-frontends.t t/upgrading-routing-composition.t t/00-pod/cookbook-examples.t
```

Expected: PASS with explicit `to_router` crossings and unchanged Router
declaration order, nested Mount ownership, and frontend method behavior.

- [ ] **Step 6: Commit Task 4 and record evidence.**

```bash
git add lib/PAGI/Endpoint/Router.pm lib/PAGI/App/Router.pm \
  lib/PAGI/App/Cascade.pm lib/PAGI/Middleware/ErrorHandler.pm \
  lib/PAGI/Routing.pm lib/PAGI/Tools.pm \
  lib/PAGI/Tools/Tutorial.pod lib/PAGI/Tools/Cookbook.pod \
  t/app-router.t t/app-router/03-composition-order.t \
  t/integration-router-application-boundaries.t \
  t/upgrading-router-frontends.t t/upgrading-routing-composition.t
git commit -m "refactor: compose explicit Router frontends"
```

Record evidence, set Task 5 to `in progress`, and commit the ledger update.

---

### Task 5: Migrate the Apples and Large-Application Canaries

**Files:**

- Modify: `examples/starlette-apples/app.pl`
- Modify: `examples/starlette-apples/README.md`
- Modify: `t/integration-starlette-apples.t`
- Modify: `examples/15-large-application/lib/MyApp/Root.pm`
- Modify: `examples/15-large-application/README.md`
- Modify: `examples/15-large-application/GAPS.md` only if it contains a now-resolved Compose gap
- Modify: `t/integration-large-application.t`
- Modify: `.superpowers/sdd/2026-08-31-compose-retained-router/progress.md`

**Interfaces:**

- Consumes: routes-form Compose with `http_default`/`desc`, and Router-form Compose for modular packages.
- Produces: two complete, executable canaries demonstrating both approved construction forms.

- [ ] **Step 1: Add source-shape assertions before editing examples.**

In `t/integration-starlette-apples.t`, require the app source to contain:

```perl
like($app_source, qr/compose\s*\(\s*routes\s*=>/s,
    'apples uses direct routes-form Compose');
like($app_source, qr/http_default\s*=>\s*not_found/s,
    'apples configures its root default without nested router ceremony');
unlike($app_source, qr/compose\s*\(\s*app\s*=>/s,
    'apples has no retired Compose app mode');
unlike($app_source, qr/compose\s*\(\s*router\s*=>\s*router\s*\(/s,
    'apples does not construct a redundant nested Router expression');
```

In `t/integration-large-application.t`, require `MyApp::Root->routing` to remain
a Router and `to_app` to contain `compose(router => $class->routing, ...)`.
Retain all existing link-following, nested 404/405, static file, and lifecycle
assertions.

- [ ] **Step 2: Run both integrations and confirm RED.**

Run:

```bash
perlbrew exec --with perl-5.42.2@default prove -lv t/integration-starlette-apples.t t/integration-large-application.t
```

Expected: source-shape assertions fail against the old `compose(app =>
router(...))` and `compose(app => $class->routing)` spellings.

- [ ] **Step 3: Flatten the apples root Router into Compose.**

Replace only the outer construction shape:

```perl
compose(
    routes => [
        route('/' => file_response($manager_file, inline => 1),
            name => 'home',
            desc => 'Apple manager SPA'),
        route('/welcome' => welcome(),
            name => 'welcome',
            desc => 'PAGI welcome page'),
        mount('/apples',
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

Remove the now-unused `router` import. Do not change the model, endpoint,
response, SPA, or middleware design in this campaign.

- [ ] **Step 4: Update the apples README comparison.**

Keep the original Python application verbatim. Replace the PAGI source excerpt
with the new routes-form ending and add one factual paragraph:

```markdown
Starlette retains a Router inside the Starlette application object and stores
its lifespan context on that Router. PAGI Compose likewise retains one Router,
but keeps the root lifespan exchange on Compose so mounted Routers cannot
silently carry lifecycle callbacks that never run.
```

Do not claim API identity or Router inheritance.

- [ ] **Step 5: Migrate the modular large application.**

Keep `MyApp::Root->routing` returning its configured immutable Router. Change
only the root boundary:

```perl
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

Update the README architecture explanation to distinguish reusable Router
components from the one root Compose. Remove or rewrite a GAPS entry only if
it specifically records the now-fixed inability of Compose to retain Router
identity; leave unrelated gaps untouched.

- [ ] **Step 6: Run canary integrations.**

Run:

```bash
perlbrew exec --with perl-5.42.2@default prove -lv t/integration-starlette-apples.t t/integration-large-application.t
```

Expected: PASS, including actual apple CRUD behavior, SPA links, custom root
404, large-app nested URLs, component-local 404/405, static files, and
lifespan state.

- [ ] **Step 7: Commit Task 5 and record evidence.**

```bash
git add examples/starlette-apples/app.pl examples/starlette-apples/README.md \
  t/integration-starlette-apples.t \
  examples/15-large-application/lib/MyApp/Root.pm \
  examples/15-large-application/README.md \
  t/integration-large-application.t
git commit -m "docs: simplify retained Router application examples"
```

Before committing, inspect `git diff --cached --name-only`. If `GAPS.md`
changed for the precise resolved gap described in Step 5, stage that exact
file with a separate `git add examples/15-large-application/GAPS.md`; otherwise
leave it unstaged. Record evidence, set Task 6 to `in progress`, and commit the
ledger update.

---

### Task 6: Migrate Every Remaining Live Example

**Files:**

- Modify: `examples/compose/app.pl`, `examples/compose/README.md`
- Modify: `examples/declarative-routing/app.pl`, `examples/declarative-routing/README.md`
- Modify: `examples/endpoint-demo/app.pl`, `examples/endpoint-demo/README.md`
- Modify: `examples/endpoint-router-demo/app.pl`, `examples/endpoint-router-demo/README.md`
- Modify: `examples/pages/app.pl`, `examples/pages/README.md`
- Modify: `examples/process-streaming/app.pl` and its README if present
- Inspect and preserve: `examples/sse-close/`, `examples/sse-dashboard/`, and every WebSocket example, including their explicit protocol termination behavior
- Modify: `examples/background-tasks/app.pl`, `examples/background-tasks/README.md`
- Modify: `examples/full-demo/app.pl`, `examples/full-demo/README.md`
- Modify: `examples/10-chat-showcase/app.pl`, `examples/10-chat-showcase/lib/ChatApp/HTTP.pm`, `examples/10-chat-showcase/README.md`
- Inspect and modify: every other `examples/*` application or README that mentions Compose
- Modify: corresponding `t/integration-*.t` and `t/integration/*.t` files
- Modify: `.superpowers/sdd/2026-08-31-compose-retained-router/progress.md`

**Interfaces:**

- Consumes: `compose(routes => ...)` for direct small apps and `compose(router => $router)` for retained modular routing.
- Produces: no live example using or teaching Compose app mode; every example still loads and retains its prior behavior.

- [ ] **Step 1: Build and record the execution-time example inventory.**

Run:

```bash
rg -l 'PAGI::Compose|compose\(' examples | sort
rg -n -U 'compose\(\s*app\s*=>' examples
```

Paste the first list into Task 6's ledger evidence cell or an adjacent
“Example inventory” section before edits. The list, not this plan's snapshot,
is authoritative if another merged session added an example.
`process-streaming` is known to contain retired Compose app mode and must
migrate. `sse-close`, `sse-dashboard`, and WebSocket examples may require no
source change, but their protocol-specific close, disconnect, and
terminal-event behavior must remain intact.

- [ ] **Step 2: Add or update source-shape assertions in focused integration tests.**

For each maintained example with an integration test, add the relevant
assertion:

```perl
unlike($source, qr/compose\s*\(\s*app\s*=>/s,
    'example does not use retired Compose app mode');
```

For direct declarative examples, require `routes =>`. For App Router or
Endpoint Router examples, require `router => ...->to_router` or a previously
materialized immutable Router. Do not require one style where the example's
purpose calls for the other.

- [ ] **Step 3: Run the maintained-example integrations and confirm RED.**

Run the focused set discovered from the inventory, including at minimum:

```bash
perlbrew exec --with perl-5.42.2@default prove -lv t/integration-compose-demo.t t/integration-declarative-routing-demo.t t/integration-endpoint-router-demo.t t/integration-pages-example.t t/integration-router-application-boundaries.t t/integration-chat-compose.t t/integration-maintained-examples-load.t t/integration/process-streaming-end-to-end.t
```

Expected: source-shape failures identify every remaining old Compose target.
Behavioral failures beyond those expected from the spelling change must be
investigated before editing around them.

- [ ] **Step 4: Apply the style rule consistently.**

Use:

```perl
compose(
    routes     => [...],
    middleware => [...],
    lifespan   => {...},
);
```

when the example declares its route list at the root and needs no separately
retained Router configuration.

Use:

```perl
my $routing = router(...);
compose(
    router     => $routing,
    middleware => [...],
    lifespan   => {...},
);
```

when the Router is modular, inspected, configured with Router middleware, or
returned by another package.

Use:

```perl
compose(router => $builder->to_router, lifespan => {...});
```

for mutable/Endpoint frontends. Never change it to `compose(router =>
$builder)`.

If an example truly used Compose around a non-routing native application,
deploy that application directly and document the loss of Compose root
features, or stop and record `DEV-NN` if those features are essential. Do not
invent a wrapper in the example.

- [ ] **Step 5: Keep each README executable and aligned.**

Update complete source excerpts, launch commands, architecture explanations,
and expected behavior. Do not leave `compose(app => ...)` in prose as a
“simpler alternative.” Preserve the purpose of each example; this task is not
authorization to redesign its domain behavior.

- [ ] **Step 6: Run all focused example integrations.**

Run the exact maintained-example set recorded in Step 3 plus any additional
test found during inventory. Expected: PASS with every example loading and its
existing HTTP/WebSocket/SSE/lifespan behavior intact.

- [ ] **Step 7: Commit Task 6 and record evidence.**

Stage only the example, README, and integration-test files actually changed:

```bash
git add \
  examples/compose examples/declarative-routing \
  examples/endpoint-demo examples/endpoint-router-demo \
  examples/pages examples/process-streaming examples/background-tasks \
  examples/full-demo examples/10-chat-showcase \
  t/integration-compose-demo.t t/integration-declarative-routing-demo.t \
  t/integration-endpoint-router-demo.t t/integration-pages-example.t \
  t/integration-router-application-boundaries.t \
  t/integration-chat-compose.t t/integration-maintained-examples-load.t \
  t/integration/process-streaming-end-to-end.t
git diff --cached --name-only
git commit -m "docs: migrate examples to retained Router Compose"
```

Inspect the staged list before commit so unrelated example work is not
absorbed. Record the real SHA, full focused-example totals, and inventory; set
Task 7 to `in progress`, then commit the ledger update.

---

### Task 7: Rewrite the Public Contract and Upgrade Guide

**Files:**

- Modify: `lib/PAGI/Compose.pm` POD
- Modify: `lib/PAGI/Routing.pm` POD
- Modify: `lib/PAGI/Routing/Router.pm` POD
- Modify: `lib/PAGI/App/Router.pm` POD
- Modify: `lib/PAGI/Endpoint/Router.pm` POD
- Modify: `lib/PAGI/Tools.pm`
- Modify: `lib/PAGI/Tools/Tutorial.pod`
- Modify: `lib/PAGI/Tools/Cookbook.pod`
- Modify: `README.md` if it contains Compose examples or architecture prose
- Modify: `UPGRADING.md`
- Modify: `Changes`
- Modify: `t/00-pod/cookbook-examples.t`
- Modify: upgrading tests that validate exact prose/examples
- Modify: `.superpowers/sdd/2026-08-31-compose-retained-router/progress.md`

**Interfaces:**

- Consumes: completed runtime and example behavior from Tasks 1-6.
- Produces: one truthful public API description, complete migration recipes, and executable documentation examples.

- [ ] **Step 1: Replace Compose's public synopsis and constructor reference.**

Lead with the direct form:

```perl
use PAGI::Compose qw(compose);
use PAGI::Routing qw(route middleware);

my $app = compose(
    routes => [route('/' => \&home, name => 'home')],
    middleware => [middleware('RequestId')],
    lifespan => {
        startup  => \&startup,
        shutdown => \&shutdown,
    },
);
```

Then show modular Router form. Document every constructor key, conflict,
accessor, delegation, compilation boundary, middleware order, and exact
lifespan ownership from the spec. Remove the `app` accessor and every generic
application-target claim.

- [ ] **Step 2: Document the Starlette comparison accurately.**

Include these facts without implying source identity:

- current Starlette owns `self.router`; it does not subclass Router;
- Starlette stores lifespan handling on Router, which makes a standalone
  Router lifecycle-capable;
- mounted Starlette Routers do not receive lifespan;
- PAGI preserves one non-cascading root lifecycle but keeps it on Compose;
- bare PAGI Router deployment declines lifespan and strict mode rejects it.

Link to the official Starlette application, routing, and routing-test sources
listed in the design spec.

- [ ] **Step 3: Add complete upgrading recipes.**

`UPGRADING.md` must include exact before/after sections for:

```perl
compose(app => $router)
compose(router => $router)
```

```perl
compose(app => $builder)
compose(router => $builder->to_router)
```

```perl
compose(
    app => router(routes => \@routes, http_default => $default),
    lifespan => {...},
)

compose(
    routes       => \@routes,
    http_default => $default,
    lifespan     => {...},
)
```

For arbitrary native apps, state plainly that Compose has no direct
replacement in this release. Explain direct deployment, the absent root
safety/lifespan features, and why a root Mount is not presented as an
equivalent conversion.

- [ ] **Step 4: Update Router/frontend cross-links and Changes.**

Router POD must say Compose retains it by identity but does not add Router
lifespan. App Router and Endpoint Router POD must distinguish `to_app` bare
Router compilation from root Compose deployment. Tutorial and Cookbook must
use the same forms as examples.

Add a `Changes` entry covering:

- retained Router identity;
- routes/router constructor forms;
- delegated inspection and reverse routing;
- removal of arbitrary app mode;
- flattened routes-form `http_default`/`desc`; and
- unchanged root-only lifespan behavior.

Append beneath the existing `0.002003 - UNRELEASED` heading. Preserve the
buffering middleware and disconnect-settlement notes already present on
`main`; do not consolidate or rewrite them as part of this campaign.
Likewise, when editing Tutorial examples, retain the baseline's explicit
`more => 0` on originated terminal body events.

- [ ] **Step 5: Run documentation and upgrading tests.**

Run:

```bash
perlbrew exec --with perl-5.42.2@default prove -lv t/00-pod t/upgrading-router-frontends.t t/upgrading-routing-composition.t
```

Expected: PASS. Inspect warnings; a zero exit with malformed POD warnings is
not acceptable evidence.

- [ ] **Step 6: Run the live documentation search.**

Run:

```bash
rg -n -U 'compose\(\s*app\s*=>' lib examples t README.md UPGRADING.md Changes
rg -n 'accepts.*arbitrary.*app|exactly one of.*routes.*app|routes mode.*constructs.*Router' lib examples README.md UPGRADING.md Changes
```

Every remaining match must be an explicit `UPGRADING.md` before example or a
negative test. Record each intentional path and line in the ledger.

- [ ] **Step 7: Commit Task 7 and record evidence.**

```bash
git add Changes README.md UPGRADING.md \
  lib/PAGI/Compose.pm lib/PAGI/Routing.pm lib/PAGI/Routing/Router.pm \
  lib/PAGI/App/Router.pm lib/PAGI/Endpoint/Router.pm lib/PAGI/Tools.pm \
  lib/PAGI/Tools/Tutorial.pod lib/PAGI/Tools/Cookbook.pod \
  t/00-pod t/upgrading-router-frontends.t \
  t/upgrading-routing-composition.t
git diff --cached --name-only
git commit -m "docs: document retained Router composition"
```

Stage only changed files and inspect the list. Record the real SHA, POD and
upgrading totals, intentional search matches, set Task 8 to `in progress`, and
commit the ledger update.

---

### Task 8: Final Audit, Distribution Verification, and Review

**Files:**

- Modify: only files required by a verified failure attributable to this campaign
- Modify: `.superpowers/sdd/2026-08-31-compose-retained-router/progress.md`

**Interfaces:**

- Consumes: complete implementation from Tasks 1-7.
- Produces: one clean candidate branch with auditable evidence and no live old Compose mode.

- [ ] **Step 1: Reconfirm the work map before final mutation or push.**

Run:

```bash
git branch --show-current
git merge-base HEAD origin/main
git status --short
git log --oneline --decorate -12
```

Confirm the branch is `feature/compose-retained-router`, the ledger base and
current merge-base are recorded, and every modified/untracked file belongs to
this campaign. Stop on unrelated work rather than staging around it.

- [ ] **Step 2: Run the final semantic searches.**

Run:

```bash
rg -n -U 'compose\(\s*app\s*=>' lib t examples README.md UPGRADING.md Changes
rg -n 'sub app\b|->app\b' lib/PAGI/Compose.pm lib/PAGI/Compose t/compose
rg -n 'exactly one of routes or app|Compose.*arbitrary.*application|routes mode.*fresh root.*Router' lib examples README.md UPGRADING.md Changes
rg -n 'compose\(\s*router\s*=>\s*\$(builder|endpoint)' lib t examples
```

Expected:

- old Compose app calls occur only in before-migration prose or negative
  tests;
- no Compose `app` accessor remains;
- no live old-constructor claims remain; and
- no frontend object is passed without `to_router`.

Record every intentional match with file and line.

- [ ] **Step 3: Run syntax and diff hygiene checks.**

Run:

```bash
git diff --check origin/main...HEAD
perlbrew exec --with perl-5.42.2@default perl -Ilib -c lib/PAGI/Compose.pm
perlbrew exec --with perl-5.42.2@default perl -Ilib -c lib/PAGI/Compose/Compiler.pm
perlbrew exec --with perl-5.42.2@default prove -lv t/compose/07-response-guard.t t/utils/request-ended-abnormally.t t/middleware/buffered-response.t t/middleware/disconnect-laundering.t t/middleware/head-promises.t
```

Expected: no whitespace errors; both modules report `syntax OK`; the focused
settlement/buffering regression gate passes without changing its event-level
contract.

- [ ] **Step 4: Run the complete distribution test suite once.**

Run:

```bash
perlbrew exec --with perl-5.42.2@default prove -lr -j4 t/
```

Expected: PASS. Record exact files, tests, wall-clock time, and result. Do not
rerun the complete suite automatically. If it fails, diagnose the specific
failure, run only focused tests while fixing it, and rerun the complete suite
once at the new candidate HEAD after recording why the first candidate was
not final.

- [ ] **Step 5: Build the distribution without rerunning its test suite.**

Run:

```bash
perlbrew exec --with perl-5.42.2@default dzil build
```

Expected: build succeeds, public POD and example assets are present, and no
removed module/reference warning appears. Inspect the generated tarball file
list rather than invoking `dzil test`, because the complete suite already ran
in Step 4.

- [ ] **Step 6: Request final code review.**

Use `superpowers:requesting-code-review` against the exact `origin/main...HEAD`
range. Give the reviewer the design spec, this plan, ledger, and explicit
review questions:

1. Does every Compose retain exactly one Router without reconstruction?
2. Can any arbitrary application still enter through a hidden Compose path?
3. Are lifespan ownership and middleware visibility unchanged?
4. Do Router 404/405/Allow, HEAD, and response safety remain intact?
5. Are all live examples and migration docs coherent?
6. Did the campaign add cloning, hidden caches, or a fake root Mount?

Address findings with focused tests and task-local commits. A design deviation
requires user approval and a `DEV-NN` ledger entry.

- [ ] **Step 7: Commit any final review fixes, then complete the ledger.**

If review required code changes, commit them with the affected focused tests.
Then update Task 8 with final HEAD, full-suite totals, distribution-build
evidence, review result, and all intentional search matches. Set every task to
`complete` and commit only the ledger:

```bash
git add -f .superpowers/sdd/2026-08-31-compose-retained-router/progress.md
git commit -m "docs: complete retained Router campaign"
```

- [ ] **Step 8: Present integration choices without pushing automatically.**

Use `superpowers:finishing-a-development-branch`. Report the candidate branch,
commit range, test/build evidence, and review result. Do not push, open a PR,
merge, or modify another worktree until the user chooses the integration path.
