# Compose Routes and Explicit Router Mounting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `routes` the sole routing input to `PAGI::Compose`, preserve already-constructed Routers only through explicit Mount, and migrate every live test, example, and document to the corrected composition model.

**Architecture:** Compose constructs and retains one root `PAGI::Routing::Router` from `routes`. An existing immutable Router remains a PAGI application and enters the root routing table through `mount('/' => app => $router)`, preserving its middleware, default, Resolver, and final outcome ownership without a second Compose constructor mode. Small declarative applications continue to place their Route and Mount nodes directly in Compose.

**Tech Stack:** Perl 5.18-compatible distribution code, Perl 5.40+ example syntax where already declared, Future::AsyncAwait, Test2::V0, PAGI Test Client, Dist::Zilla, immutable `PAGI::Routing` descriptions.

**Spec:** `docs/superpowers/specs/2026-09-01-compose-routes-and-explicit-router-mounting-design.md`

## Global Constraints

- Repository: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools`.
- Ticket: none; this is the approved corrective Compose design.
- Execution worktree: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/.worktrees/compose-retained-router`.
- Execution branch: `feature/compose-retained-router`.
- Corrective base: `037e22f4b2901b730060cec9114d3372efccc0b3`; reconfirm branch, base, worktree cleanliness, `main`, and `origin/main` before Task 1 and record movement rather than silently rebasing.
- Owned changes: PAGI-Tools runtime, tests, all live examples, POD, README, Tutorial, Cookbook, `UPGRADING.md`, `Changes`, and campaign records required by the approved spec.
- Deployment boundary: one unreleased PAGI-Tools distribution. `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI` and `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server` remain read-only references.
- Push target: `origin/feature/compose-retained-router`, only after task reviews, final verification, and user authorization.
- Breaking changes to unreleased PAGI-Tools APIs are allowed. Do not preserve `compose(router => ...)` through aliases, warnings, hidden Mount creation, capability guessing, or compatibility parsing.
- Compose requires `routes => \@nodes`. It constructs and retains one root `PAGI::Routing::Router` during Compose construction.
- `Compose->router` remains the accessor for that owned root Router. It is not a constructor mode.
- Existing Routers enter routing tables through explicit `mount($path => app => $router)`. An unnamed `mount('/' => ...)` preserves root route addresses and consumes no path.
- `compose(routes => $router->routes)` is deliberate flattening, not preservation. Do not use it as a mechanical migration for configured Routers.
- Preserve Route, Mount, Router, middleware, `http_default`, 404, 405, authoritative `Allow`, metadata, reverse routing, HTTP, WebSocket, SSE, lifespan, ErrorHandler, ResponseGuard, and HEAD contracts.
- Preserve the settled buffering/disconnect baseline. Do not alter Stream, File, send-Future, denial, decline, abnormal-disconnect, response-completion, GZip, or buffering behavior.
- Preserve existing shallow-copy semantics. Do not add Router, scope, Header, Response, endpoint, or application cloning and do not add mutation snapshots or hidden caches.
- If root Mount behavior is defective, fix the general Mount/Router contract cleanly. Do not add Compose-only matcher, resolver, scope, or metadata exceptions.
- Do not add `include_router`, `to_routes`, routes-provider callbacks, package loading, arity inference, or frontend-specific Compose options.
- All live examples under `examples/` are in scope. The Starlette apples example must remain direct `compose(routes => [...])` and is the readability canary.
- Historical files under `docs/superpowers/specs/` and `docs/superpowers/plans/` remain historical. This plan and its governing spec supersede rather than rewrite them.
- Use TDD for runtime changes. Run focused suites after each task and the complete distribution suite once at final candidate HEAD.
- Run project Perl commands through `perlbrew exec --with perl-5.42.2@default ...` unless execution-time repository instructions identify a newer authoritative environment.
- Before runtime changes, create and force-add `.superpowers/sdd/2026-09-01-compose-routes-explicit-mount/progress.md`. Every task gets status, implementation SHA, real test count, and evidence. Commit the implementation first, then update the task row in an immediate tracking commit.
- Record deviations as `DEV-NN` with the conflicting requirement, evidence, proposed resolution, rationale, and explicit user approval before later tasks depend on them.

---

## File Structure

| File or family | Responsibility after this campaign | Task |
| --- | --- | --- |
| `lib/PAGI/Compose.pm` | Routes-only constructor, retained root Router, accessors and validation | 1 |
| `t/compose/01-description.t` | Public constructor, accessor identity, delegation, shallow-copy and diagnostics contract | 1 |
| `t/compose/02-dispatch.t`, `t/routing/12-router-mounts.t`, `t/routing/03-reverse-inspection.t` | Explicit root-Mount dispatch, ownership and inspection | 2 |
| `t/compose/03-lifespan.t` through `07-response-guard.t`, `lib/PAGI/Compose/Compiler.pm` | Routes-only root lifecycle, middleware, HEAD, safety and compilation | 3 |
| `lib/PAGI/App/Router.pm`, `lib/PAGI/Endpoint/Router.pm`, frontend tests | Explicit frontend snapshot through Mount | 4 |
| `examples/starlette-apples`, `examples/declarative-routing`, `examples/pages` | Direct-routes examples and Starlette comparison | 5 |
| Remaining affected `examples/` and integration tests | Class-based and modular root-Mount examples | 6 |
| Public POD, Tutorial, Cookbook, README, `UPGRADING.md`, `Changes` | Complete public contract and migration guide | 7 |
| Repository search, generated docs, packaging and full suite | Final integrated proof | 8 |

---

### Task 1: Remove the Compose `router` Constructor Mode

**Files:**

- Create: `.superpowers/sdd/2026-09-01-compose-routes-explicit-mount/progress.md`
- Modify: `t/compose/01-description.t`
- Modify: `lib/PAGI/Compose.pm`

**Interfaces:**

- Consumes: `PAGI::Routing::Router->new(routes => \@nodes, http_default => $app, desc => $text)` and strict middleware descriptions.
- Produces: `compose(routes => \@nodes, ...)`, `PAGI::Compose->router`, `routes`, `http_default`, `desc`, `named_routes`, `route_named`, `path_for`, `middleware`, `lifespan`, and `to_app`; rejects `router` and `app` constructor keys.

- [ ] **Step 1: Verify the work map and create the campaign ledger.**

Run:

```bash
git branch --show-current
git rev-parse HEAD
git status --short
git rev-parse main
git rev-parse origin/main
```

Expected branch: `feature/compose-retained-router`. Expected HEAD before the
plan commit is `037e22f4b2901b730060cec9114d3372efccc0b3`; after the plan commit,
record that newer exact SHA as the execution start. The worktree must contain
no unrelated edits.

Create the tracking file with this content. The corrective base is the exact
approved-spec commit; the tracking-file commit history records the later plan
and execution commits without a self-referential placeholder:

```markdown
# SDD ledger — Compose routes and explicit Router Mount

Spec: docs/superpowers/specs/2026-09-01-compose-routes-and-explicit-router-mounting-design.md
Plan: docs/superpowers/plans/2026-09-01-compose-routes-and-explicit-router-mounting.md
Repository: /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools
Ticket: none
Branch: feature/compose-retained-router
Corrective base: 037e22f4b2901b730060cec9114d3372efccc0b3
Deployment boundary: unreleased PAGI-Tools distribution
Push target: origin/feature/compose-retained-router after authorization

| Task | Status | Implementation commit | Tests | Evidence |
| --- | --- | --- | --- | --- |
| 1. Compose constructor | in progress | — | — | — |
| 2. Root Mount contract | pending | — | — | — |
| 3. Lifecycle and safety | pending | — | — | — |
| 4. Router frontends | pending | — | — | — |
| 5. Declarative examples | pending | — | — | — |
| 6. Class-based examples | pending | — | — | — |
| 7. Public documentation | pending | — | — | — |
| 8. Final verification | pending | — | — | — |

## Deviations

None.
```

Force-add and commit only the ledger:

```bash
git add -f .superpowers/sdd/2026-09-01-compose-routes-explicit-mount/progress.md
git commit -m "docs: start explicit router mount correction"
```

- [ ] **Step 2: Rewrite the positive Compose description fixture around one constructed root Router.**

In `t/compose/01-description.t`, replace the retained-child setup with:

```perl
my $leaf = route('/' => sub {
    return PAGI::Response::Text->new('home');
}, name => 'home');

my $default = PAGI::Pages->not_found(detail => 'No root route');
my $input_routes = [$leaf];
my $composition = compose(
    routes       => $input_routes,
    http_default => $default,
    desc         => 'Constructed root',
    middleware   => [middleware('RequestId')],
    lifespan     => { startup => sub { return } },
);

isa_ok($composition, 'PAGI::Compose');
isa_ok($composition->router, 'PAGI::Routing::Router');
is($composition->routes, [$leaf], 'routes delegates to owned root Router');
is(refaddr($composition->http_default), refaddr($default),
    'http_default delegates by identity');
is($composition->desc, 'Constructed root', 'desc delegates');
is($composition->path_for('/home'), '/', 'path_for delegates');
is(refaddr($composition->route_named('/home')), refaddr($leaf),
    'route_named delegates');
ok(exists $composition->named_routes->{'/home'},
    'named_routes delegates');
ok(!$composition->can('app'), 'retired app accessor is absent');
ok(!overload::Method($composition, '&{}'), 'composition has no coderef overload');
```

Capture `refaddr($composition->router)`, call every accessor, and assert the
identity remains unchanged. Mutate `$input_routes` after construction and
assert `routes` still returns only `$leaf`.

- [ ] **Step 3: Replace the invalid-construction matrix with the routes-only contract.**

Keep existing unknown-option, middleware, and lifespan rows. Replace target
rows with:

```perl
['missing routes', [], qr/compose requires routes/],
['router option', [router => router(routes => [])],
    qr/compose no longer accepts 'router'.*mount\('\/' => app => \$router\)/s],
['router plus routes', [routes => [], router => router(routes => [])],
    qr/compose no longer accepts 'router'/],
['retired app Router', [app => router(routes => [])],
    qr/compose no longer accepts 'app'.*Mount/s],
['retired native app', [app => sub { return }],
    qr/compose no longer accepts 'app'.*deploy.*directly/s],
['routes undef', [routes => undef], qr/compose routes must be an arrayref/],
['routes hash', [routes => {}], qr/compose routes must be an arrayref/],
['invalid route member', [routes => [{}]],
    qr/routes must contain PAGI::Routing nodes/],
```

Remove tests for Router-form `http_default`/`desc` conflicts because Router
form no longer exists.

- [ ] **Step 4: Run the description test and verify the new assertions fail.**

Run:

```bash
perlbrew exec --with perl-5.42.2@default prove -lv t/compose/01-description.t
```

Expected: FAIL because `compose()` still accepts `router`, reports the old XOR
diagnostic when `routes` is absent, and does not emit the new root-Mount hint.

- [ ] **Step 5: Implement the minimal routes-only constructor.**

In `lib/PAGI/Compose.pm`, make the allowed list:

```perl
my %allowed = map { $_ => 1 }
    qw(routes http_default desc middleware lifespan);
```

Check retired keys before the generic unknown-option loop:

```perl
croak q{compose no longer accepts 'router'; put an existing Router in mount('/' => app => $router)}
    if exists $opts{router};

croak q{compose no longer accepts 'app'; deploy the application directly or compose it through Mount}
    if exists $opts{app};
```

Require and validate the route list before constructing the root Router:

```perl
croak 'compose requires routes' unless exists $opts{routes};
croak 'compose routes must be an arrayref'
    unless ref($opts{routes}) eq 'ARRAY';

my $router = PAGI::Routing::Router->new(
    routes => $opts{routes},
    (exists $opts{http_default}
        ? (http_default => $opts{http_default}) : ()),
    (exists $opts{desc} ? (desc => $opts{desc}) : ()),
);
```

Retain the existing middleware and lifespan validation and the internal
`router => $router` storage slot. Delete the constructor's blessed Router
validation and routes/router XOR branches. Do not change public accessors.

- [ ] **Step 6: Run the focused test and syntax checks.**

Run:

```bash
perlbrew exec --with perl-5.42.2@default prove -lv t/compose/01-description.t
perlbrew exec --with perl-5.42.2@default perl -Ilib -c lib/PAGI/Compose.pm
git diff --check
```

Expected: the test passes, `Compose.pm syntax OK`, and `git diff --check`
prints nothing.

- [ ] **Step 7: Commit implementation and tracking evidence.**

```bash
git add lib/PAGI/Compose.pm t/compose/01-description.t
git commit -m "refactor: make Compose routes-only"
```

Record the implementation SHA and exact `prove` test count in Task 1's ledger
row, change Task 1 to `complete` and Task 2 to `in progress`, then:

```bash
git add -f .superpowers/sdd/2026-09-01-compose-routes-explicit-mount/progress.md
git commit -m "docs: record Compose constructor evidence"
```

---

### Task 2: Pin Explicit Root-Mount Preservation

**Files:**

- Modify: `t/compose/02-dispatch.t`
- Verify: `t/routing/12-router-mounts.t` retains general root-Mount ownership coverage
- Verify: `t/routing/03-reverse-inspection.t` retains general root-Mount naming coverage

**Interfaces:**

- Consumes: `compose(routes => \@nodes)`, `mount('/' => app => $router)`, immutable Router `middleware`, `http_default`, `desc`, Resolver and Mount `app` accessor.
- Produces: exercised contract proving that the outer Compose Router and mounted child are distinct retained identities, root Mount consumes no path, the child owns outcomes, and outer reverse routing discovers child names.

- [ ] **Step 1: Add one complete preserved-Router fixture.**

In `t/compose/02-dispatch.t`, import `refaddr`, `router`, and `middleware`, then
add a middleware factory that records order:

```perl
sub recording_middleware {
    my ($label, $seen) = @_;
    return middleware(sub {
        my ($inner) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            push @$seen, "$label:before";
            my $result = await Future->wrap(
                $inner->($scope, $receive, $send),
            );
            push @$seen, "$label:after";
            return $result;
        };
    });
}
```

Also add exact local response helpers:

```perl
sub response_body {
    my ($events) = @_;
    return join '', map { $_->{body} // '' }
        grep { ($_->{type} // '') eq 'http.response.body' } @$events;
}

sub response_header {
    my ($events, $name) = @_;
    my ($start) = grep {
        ($_->{type} // '') eq 'http.response.start'
    } @$events;
    return unless $start;
    for my $pair (@{$start->{headers} // []}) {
        return $pair->[1] if lc($pair->[0]) eq lc($name);
    }
    return;
}
```

Construct:

```perl
my @order;
my @seen_scope;
my $child_default = PAGI::Pages->not_found(
    detail => 'child default',
);
my $child_leaf = route('/item/{id}' => sub {
    my ($request) = @_;
    push @seen_scope, [@{$request->scope}{qw(path raw_path root_path)}];
    push @order, 'handler';
    return PAGI::Response::Text->new('item:' . $request->path_param('id'));
}, methods => ['GET'], name => 'show');
my $child = router(
    routes       => [$child_leaf],
    middleware   => [recording_middleware('child', \@order)],
    http_default => $child_default,
    desc         => 'Preserved child',
);
my $root_mount = mount('/' => app => $child);
my $composition = compose(
    routes     => [$root_mount],
    middleware => [recording_middleware('compose', \@order)],
);
```

- [ ] **Step 2: Assert identity, inspection and reverse-routing semantics.**

Add:

```perl
isnt(refaddr($composition->router), refaddr($child),
    'Compose owns a distinct outer root Router');
is(refaddr($composition->routes->[0]), refaddr($root_mount),
    'Compose routes expose the explicit root Mount');
is(refaddr($composition->routes->[0]->app), refaddr($child),
    'root Mount retains child Router identity');
is($composition->path_for('/show', { id => 7 }), '/item/7',
    'unnamed root Mount adds no namespace or slash');
is(refaddr($composition->route_named('/show')), refaddr($child_leaf),
    'outer Resolver discovers mounted child leaf');
is($child->desc, 'Preserved child', 'child description remains owned by child');
is(refaddr($child->http_default), refaddr($child_default),
    'child default remains owned by child');
```

Construct a second composition with `name => 'legacy'` on the root Mount and
assert `/legacy/show` resolves while `/show` does not.

- [ ] **Step 3: Assert dispatch, final ownership and scope arithmetic.**

Compile the composition and assert:

```perl
my $app = $composition->to_app;
my $full = run_scope($app, scope(
    path => '/item/7', raw_path => '/edge/item/7', root_path => '/edge',
));
is([$full->[0]{status}, $full->[1]{body}], [200, 'item:7'],
    'root-mounted child handles FULL');
is(\@seen_scope, [['/item/7', '/edge/item/7', '/edge']],
    'root Mount preserves path arithmetic');
is(\@order, [qw(compose:before child:before handler child:after compose:after)],
    'Compose middleware remains outside child Router middleware');

my $partial = run_scope($app, scope(method => 'POST', path => '/item/7'));
is($partial->[0]{status}, 405, 'child owns PARTIAL');
is(response_header($partial, 'Allow'), 'GET, HEAD',
    'child publishes authoritative Allow');

my $none = run_scope($app, scope(path => '/missing'));
is($none->[0]{status}, 404, 'child owns NONE');
like(response_body($none), qr/child default/,
    'child custom default remains active');
```

- [ ] **Step 4: Add the root-Mount ordering edge.**

Construct outer routes in this order:

```perl
[
    route('/outer' => sub { return PAGI::Response::Text->new('outer') }),
    mount('/' => app => $child),
    route('/after' => sub { return PAGI::Response::Text->new('unreachable') }),
]
```

Assert `/outer` reaches the earlier outer Route and `/after` is handled as a
child NONE rather than reaching the later sibling. This pins the documented
catch-all ordering rule.

- [ ] **Step 5: Run the focused routing and dispatch tests.**

Run:

```bash
perlbrew exec --with perl-5.42.2@default prove -lv \
  t/compose/02-dispatch.t \
  t/routing/03-reverse-inspection.t \
  t/routing/12-router-mounts.t
```

The general root-Mount behavior may already pass before production changes;
that is expected characterization evidence, not permission to add redundant
runtime code. If an assertion fails, diagnose whether the spec contradicts
the general Mount contract before editing the compiler.

- [ ] **Step 6: Commit tests and ledger evidence.**

Commit the new Compose integration test:

```bash
git add t/compose/02-dispatch.t
git commit -m "test: pin explicit root Router mounting"
```

Record the SHA, exact test count, and that the general routing files required
no change because their existing assertions remained green. Advance the
ledger to Task 3 and commit it separately.

---

### Task 3: Migrate Compose Lifecycle, Middleware, HEAD and Safety Tests

**Files:**

- Modify: `t/compose/03-lifespan.t`
- Modify: `t/compose/04-middleware.t`
- Modify: `t/compose/05-head-concurrency.t`
- Modify: `t/compose/06-failsafes.t`
- Verify: `t/compose/07-response-guard.t` contains no stale Router form and retains settlement coverage
- Verify: `lib/PAGI/Compose/Compiler.pm` already compiles only `Compose->router`

**Interfaces:**

- Consumes: routes-only Compose from Task 1 and explicit root Mount from Task 2.
- Produces: proof that routes-only construction preserves existing application middleware, lifespan, ErrorHandler, ResponseGuard, HEAD, concurrency and settlement behavior.

- [ ] **Step 1: Introduce one local root-Mount helper in tests that truly need a prebuilt Router.**

In each test file that repeatedly preserves a Router, add a file-local helper
rather than a production shortcut:

```perl
sub compose_with_router {
    my ($routing, @options) = @_;
    return compose(
        routes => [mount('/' => app => $routing)],
        @options,
    );
}
```

Use it only where the Router's identity/configuration is part of the test. For
fixtures that merely need a route list, use direct `compose(routes => [...])`
instead. The helper is test vocabulary and must not enter `lib/` or examples.

- [ ] **Step 2: Migrate lifespan fixtures without changing lifecycle assertions.**

In `t/compose/03-lifespan.t`, replace:

```perl
compose(router => $lifespan_router, lifespan => {...})
```

with:

```perl
compose(
    routes   => [mount('/' => app => $lifespan_router)],
    lifespan => {...},
)
```

Retain exact assertions for server state identity, startup/shutdown order,
unknown lifespan events, failed callback Futures, missing state, send/receive
failure, middleware scope visibility, mounted-Compose non-recursion, and
strict/automatic lifespan behavior.

Add one assertion that neither outer root Router nor mounted child endpoint is
invoked for a lifespan scope.

- [ ] **Step 3: Migrate middleware tests according to what each fixture owns.**

In `t/compose/04-middleware.t`:

- convert `router_with_app($target)` cases to direct Route or Mount nodes when
  Router preservation is irrelevant;
- use explicit root Mount when a child Router middleware/default is the
  subject;
- retain strict `middleware(...)` descriptors;
- retain application middleware visibility for lifespan; and
- preserve immediate and Future-backed wrapper completion.

For the ordering case, assert the existing exact order rather than updating
expected output to match an accidental new order.

- [ ] **Step 4: Migrate HEAD and concurrency fixtures without adding nested root adapters.**

In `t/compose/05-head-concurrency.t`, use direct routes for ordinary endpoints
and root Mount for child Router policy. Preserve assertions for:

- one outer HEAD suppression boundary;
- custom HEAD routes winning when declared;
- GET-derived headers matching HEAD;
- sendfile and trailer suppression;
- middleware observing the unsuppressed representation;
- concurrent request-local routing metadata; and
- no cross-request authoritative-`Allow` leakage.

Do not call the child Router's public `to_app` and mount that coderef for an
inspectable case; mount the Router object so the shared compiler retains the
child boundary without adding another public root HEAD adapter.

- [ ] **Step 5: Remove the redundant retained-Router failsafe matrix row.**

In `t/compose/06-failsafes.t`, replace the two-mode matrix:

```perl
['routes', compose(routes => $routes)->to_app],
['retained Router', compose(router => router(routes => $routes))->to_app],
```

with two semantically distinct rows:

```perl
['direct routes', compose(routes => $routes)->to_app],
['root-mounted Router', compose(routes => [
    mount('/' => app => router(routes => $routes)),
])->to_app],
```

Keep ErrorHandler and ResponseGuard assertions identical for both shapes.
Retain all settlement and abnormal-disconnect assertions in
`07-response-guard.t` without broad rewrite.

- [ ] **Step 6: Run the full Compose suite and diagnose failures.**

Run:

```bash
perlbrew exec --with perl-5.42.2@default prove -lv t/compose
```

Expected: all Compose files pass. Failures caused only by remaining
`compose(router => ...)` fixtures are half-migration failures and should be
converted. Any failure in response events, order, settlement, or concurrency
requires systematic debugging before code changes.

- [ ] **Step 7: Verify the compiler contains no target-mode branching.**

Inspect `lib/PAGI/Compose/Compiler.pm`. Its compile entry should obtain the
owned root Router and compile it once:

```perl
my $routing_app = $composition->router->to_app;
```

Confirm there is no code switching among `app`, `routes`, or injected
`router` targets. The current branch should already satisfy this requirement;
leave the file untouched and record the inspected compile entry in the
ledger. Do not restructure lifespan, middleware, ErrorHandler, ResponseGuard,
or HEAD wrappers.

- [ ] **Step 8: Commit the migration and ledger evidence.**

Run `git diff --check` and commit the changed Compose tests:

```bash
git add \
  t/compose/03-lifespan.t \
  t/compose/04-middleware.t \
  t/compose/05-head-concurrency.t \
  t/compose/06-failsafes.t
git commit -m "test: migrate Compose boundaries to explicit routes"
```

Record exact Compose test counts, the unchanged compiler inspection, and the
unchanged ResponseGuard coverage, then advance the ledger.

---

### Task 4: Migrate App Router and Endpoint Router Frontends

**Files:**

- Modify: `t/app-router.t`
- Modify: `t/upgrading-router-frontends.t`
- Modify: `t/upgrading-routing-composition.t`
- Modify: `t/app-router/03-composition-order.t`
- Modify: `t/00-pod/cookbook-examples.t` where executable snippets change
- Modify: `lib/PAGI/App/Router.pm`
- Modify: `lib/PAGI/Endpoint/Router.pm`

**Interfaces:**

- Consumes: `PAGI::App::Router->to_router`, `PAGI::Endpoint::Router->to_router`, `mount('/' => app => $snapshot)`, direct frontend `to_app`.
- Produces: explicit inspectable snapshot mounting, documented opaque direct mounting, and unchanged bare frontend compilation.

- [ ] **Step 1: Replace the App Router Compose identity test.**

In `t/app-router.t`, replace the retained-identity subtest with:

```perl
subtest 'Compose preserves an explicit App Router snapshot through Mount' => sub {
    my $builder = PAGI::App::Router->new;
    $builder->get('/' => handler('home'))->name('home');

    like(dies { compose(router => $builder) },
        qr/no longer accepts 'router'.*mount/s,
        'Compose rejects the retired Router constructor mode');

    my $routing = $builder->to_router;
    my $root_mount = PAGI::Routing::mount('/' => app => $routing);
    my $root = compose(routes => [$root_mount]);

    isnt(refaddr($root->router), refaddr($routing),
        'Compose owns a distinct root Router');
    is(refaddr($root->routes->[0]->app), refaddr($routing),
        'root Mount retains the immutable snapshot');
    is($root->path_for('/home'), '/',
        'outer Resolver discovers snapshot names');
};
```

Import `mount` through the existing routing import style rather than calling a
nonexistent package function if the file currently imports only classes.

- [ ] **Step 2: Migrate all App Router dispatch fixtures.**

Replace:

```perl
compose(router => $router->to_router)->to_app
```

with:

```perl
compose(routes => [
    mount('/' => app => $router->to_router),
])->to_app
```

Retain direct `$router->to_app` tests for bare Router 404/405 and absence of
Compose ResponseGuard. Those direct tests distinguish deployment from root
composition and must not be rewritten through Compose.

- [ ] **Step 3: Migrate Endpoint Router tests and pin inspectable versus opaque behavior.**

For an Endpoint instance `$endpoint`, test both:

```perl
my $inspectable = compose(routes => [
    mount('/' => app => $endpoint->to_router),
]);
ok($inspectable->route_named('/show'),
    'immutable snapshot is inspectable');

my $opaque = compose(routes => [
    mount('/' => app => $endpoint),
]);
ok(!$opaque->route_named('/show'),
    'frontend application remains opaque to parent inspection');
```

Dispatch both and assert they reach the same endpoint behavior. Do not make
Compose call `to_router` automatically.

- [ ] **Step 4: Rewrite upgrade assertions around Mount, not flattening.**

In `t/upgrading-routing-composition.t` and
`t/upgrading-router-frontends.t`, require `UPGRADING.md` to contain these
before/after relationships:

```text
compose(router => $routing)
compose(routes => [mount('/' => app => $routing)])

compose(router => $builder->to_router)
compose(routes => [mount('/' => app => $builder->to_router)])
```

Also require prose identifying `$routing->routes` as flattening that discards
Router-level policy. Negative tests for Mount's retired `router =>` option
remain valid and are not this Compose change.

- [ ] **Step 5: Update frontend POD examples and explanations.**

In both frontend modules:

- replace positive `compose(router => ...)` examples with explicit root Mount;
- explain that `to_router` exposes names through an inspectable Mount;
- explain that mounting the frontend object directly is valid but opaque;
- keep direct `to_app` documented as bare Router compilation; and
- do not add a frontend `compose`, `to_routes`, or lifecycle helper.

Use this canonical snippet:

```perl
my $snapshot = $router->to_router;
my $app = compose(
    routes => [mount('/' => app => $snapshot)],
)->to_app;
```

- [ ] **Step 6: Run focused frontend and executable-doc tests.**

Run:

```bash
perlbrew exec --with perl-5.42.2@default prove -lv \
  t/app-router.t \
  t/app-router/03-composition-order.t \
  t/upgrading-router-frontends.t \
  t/upgrading-routing-composition.t \
  t/00-pod/cookbook-examples.t
```

Expected: all pass with the same routing results and changed composition
topology.

- [ ] **Step 7: Commit implementation and ledger evidence.**

```bash
git add \
  lib/PAGI/App/Router.pm \
  lib/PAGI/Endpoint/Router.pm \
  t/app-router.t \
  t/app-router/03-composition-order.t \
  t/upgrading-router-frontends.t \
  t/upgrading-routing-composition.t \
  t/00-pod/cookbook-examples.t
git commit -m "docs: route frontend roots through explicit Mount"
```

Stage only files changed. Record exact tests and advance the ledger.

---

### Task 5: Keep Declarative Examples Direct and Starlette-Like

**Files:**

- Verify: `examples/starlette-apples/app.pl` remains direct-routes and behaviorally unchanged
- Modify: `examples/starlette-apples/README.md`
- Modify: `examples/declarative-routing/app.pl`
- Modify: `examples/declarative-routing/README.md`
- Modify: `examples/pages/app.pl`
- Modify: `examples/pages/README.md`
- Modify: `t/integration-starlette-apples.t`
- Modify: `t/integration-declarative-routing-demo.t`
- Modify: `t/integration-pages-example.t`
- Modify: `t/integration-maintained-examples-load.t`

**Interfaces:**

- Consumes: direct `compose(routes => [...])`, Compose `http_default`, `desc`, `middleware`, and `lifespan`.
- Produces: primary examples that never construct a temporary Router merely to feed Compose.

- [ ] **Step 1: Audit each declarative example before editing.**

For each example, record in the ledger evidence whether it currently owns a
separately reusable/configured Router. Apply this rule:

- if the Router exists only to become the Compose root, move its direct route
  nodes and root options into Compose;
- if it is reused or intentionally demonstrates Router preservation, defer it
  to Task 6 and use root Mount;
- never call `$router->routes` as a shortcut.

- [ ] **Step 2: Preserve the Starlette apples canary exactly in direct-routes form.**

Its root must remain structurally:

```perl
compose(
    routes => [
        route('/' => file_response($manager_file, inline => 1), ...),
        route('/welcome' => welcome(), ...),
        mount('/apples', routes => [...], ...),
    ],
    http_default => not_found(...),
    middleware   => [middleware('RequestId')],
    lifespan     => { startup => \&startup },
    desc         => 'Starlette apples comparison application',
);
```

Do not wrap those routes in `router(...)` or `mount('/')`. Update README
comparison prose to state that both `Starlette(routes=[...])` and
`compose(routes => [...])` construct and own their root Router.

- [ ] **Step 3: Simplify declarative-routing and Pages roots.**

Where either currently does:

```perl
my $routing = router(routes => [...]);
compose(router => $routing);
```

change it to:

```perl
compose(routes => [...]);
```

Move `http_default` and `desc` into Compose when they belonged to that root
Router. Preserve all route names, middleware placement, response bodies, and
lifespan callbacks.

- [ ] **Step 4: Add or update Test Client link-following checks.**

Use `PAGI::Test::Client` through the examples' existing integration harness.
At minimum assert:

```perl
my $home = await $client->get('/');
is($home->status, 200, 'root page works');

my $missing = await $client->get('/definitely-missing');
is($missing->status, 404, 'custom root default works');
```

For apples, retain list/create/read/update/delete, generated links, API
middleware header, welcome page, SPA, 404, and 405+Allow coverage.

- [ ] **Step 5: Run only the focused example tests.**

Discover exact integration files with:

```bash
rg -l 'starlette-apples|declarative-routing|examples/pages' t
```

Run the returned files plus syntax checks for each `app.pl`:

```bash
perlbrew exec --with perl-5.42.2@default perl -Ilib -c examples/starlette-apples/app.pl
perlbrew exec --with perl-5.42.2@default perl -Ilib -c examples/declarative-routing/app.pl
perlbrew exec --with perl-5.42.2@default perl -Ilib -c examples/pages/app.pl
```

Supply each example's own `lib` through its documented loader/test harness if
direct syntax checking requires it; do not restore app-local `use lib` lines.

- [ ] **Step 6: Commit examples and ledger evidence.**

```bash
git add examples/starlette-apples examples/declarative-routing examples/pages t
git commit -m "examples: keep declarative Compose roots direct"
```

Before committing, inspect `git diff --cached --name-only` and unstage any
unrelated test. Record exact focused counts and advance the ledger.

---

### Task 6: Migrate Class-Based and Modular Examples Through Root Mount

**Files:**

- Modify: `examples/background-tasks/app.pl`
- Modify: `examples/background-tasks/README.md`
- Modify: `examples/endpoint-demo/app.pl`
- Modify: `examples/endpoint-demo/README.md`
- Modify: `examples/endpoint-router-demo/app.pl`
- Modify: `examples/endpoint-router-demo/README.md`
- Modify: `examples/full-demo/app.pl`
- Modify: `examples/full-demo/README.md`
- Modify: `examples/10-chat-showcase/app.pl`
- Modify: `examples/10-chat-showcase/lib/ChatApp/HTTP.pm`
- Modify: `examples/10-chat-showcase/README.md`
- Modify: `examples/15-large-application/lib/MyApp/Root.pm`
- Modify: `examples/15-large-application/README.md`
- Modify: `t/integration-app-file-examples.t`
- Modify: `t/integration-chat-compose.t`
- Modify: `t/integration-endpoint-router-demo.t`
- Modify: `t/integration-large-application.t`
- Modify: `t/integration-maintained-examples-load.t`
- Modify: `t/integration-router-application-boundaries.t`
- Modify: `t/00-pod/cookbook-examples.t`

**Interfaces:**

- Consumes: frontend `to_router`, explicit unnamed root Mount, Compose lifespan/root middleware, outer Resolver.
- Produces: class-oriented examples that preserve Router configuration and explain the boundary rather than flatten it.

- [ ] **Step 1: Inventory every live positive Router-form occurrence.**

Run:

```bash
rg -n -U 'compose\(\s*router\s*=>' examples
```

Classify every result as direct-routes simplification or prebuilt-Router
preservation. Record the file list in Task 6's ledger evidence. No result may
be skipped because it appears only in README prose.

- [ ] **Step 2: Migrate each class-based root with an unnamed explicit Mount.**

Use:

```perl
use PAGI::Routing qw(mount);

compose(
    routes => [
        mount('/' => app => $router->to_router),
    ],
    lifespan => {...},
);
```

If a module already returns an immutable Router, omit the extra `to_router`:

```perl
compose(
    routes => [mount('/' => app => $routing)],
    lifespan => {...},
);
```

Do not name the root Mount unless the example intentionally changes every
route address. Do not pass the child Router's `http_default`, middleware, or
desc again to Compose.

- [ ] **Step 3: Update example commentary at the exact boundary.**

Each affected README gets one compact explanation:

```text
The class frontend materializes an immutable Router. Compose constructs its
own application-root Router from routes, so the existing Router enters through
an unnamed Mount at `/`. A root Mount consumes no path and adds no route-name
namespace; it preserves the child Router's middleware, default, and reverse
resolver. Passing `$routing->routes` would flatten that boundary and discard
those Router-level policies.
```

Do not copy a long generic explanation into every README. Tailor the paragraph
to the example and cross-link the Compose/Mount POD for full details.

- [ ] **Step 4: Verify behavior with the PAGI Test Client.**

For each example's existing integration test, retain or add assertions for the
features it demonstrates. The complete set across the task must exercise:

- root and nested HTTP dispatch;
- reverse-generated links through the unnamed root Mount;
- custom child 404 and child 405+Allow;
- Compose startup state and shutdown;
- global Compose middleware outside child Router middleware;
- static/file responses;
- WebSocket chat success and miss behavior; and
- SSE success and decline/miss behavior.

Do not replace behavior assertions with source regexes.

- [ ] **Step 5: Run focused example suites and syntax checks.**

Find exact tests:

```bash
rg -l 'background-tasks|endpoint-demo|endpoint-router-demo|full-demo|10-chat-showcase|15-large-application' t
```

Run those files with `prove -lv`. Run each changed `app.pl` through the
example's documented loader or existing compile test. Expected: all pass with
unchanged application behavior.

- [ ] **Step 6: Confirm no live example teaches Router form.**

Run:

```bash
rg -n -U 'compose\(\s*router\s*=>' examples
rg -n 'compose\s*\([^)]*router\s*=>' examples
```

Expected: no output. Also search for `$router->routes` near Compose and inspect
every result to ensure no accidental flattening migration was introduced.

- [ ] **Step 7: Commit examples and ledger evidence.**

```bash
git add examples t
git commit -m "examples: mount class Router roots explicitly"
```

Inspect the staged file list and exclude unrelated tests. Record exact test
counts and the complete migrated example list, then advance the ledger.

---

### Task 7: Rewrite the Public Contract and Upgrade Guide

**Files:**

- Modify: `lib/PAGI/Compose.pm`
- Modify: `lib/PAGI/Routing.pm`
- Modify: `lib/PAGI/Routing/Router.pm`
- Modify: `lib/PAGI/Routing/Mount.pm`
- Modify: `lib/PAGI/Tools.pm`
- Modify: `lib/PAGI/Tools/Tutorial.pod`
- Modify: `lib/PAGI/Tools/Cookbook.pod`
- Modify: `lib/PAGI/Middleware/ErrorHandler.pm` and any other live POD returned by search
- Modify: `README.md` through its generator
- Modify: `UPGRADING.md`
- Modify: `Changes`
- Modify: `t/00-pod/cookbook-examples.t`
- Modify: `t/upgrading-routing-composition.t`
- Modify: `t/upgrading-router-frontends.t`

**Interfaces:**

- Consumes: completed routes-only runtime and explicit Mount behavior.
- Produces: one coherent public explanation of construction, preservation, flattening, inspection, lifecycle and migration.

- [ ] **Step 1: Rewrite Compose POD around one constructor grammar.**

Document this canonical synopsis:

```perl
my $app = compose(
    routes => [
        route('/' => \&home),
        mount('/api', routes => \@api_routes),
    ],
    http_default => not_found(...),
    middleware   => [middleware('RequestId')],
    lifespan     => { startup => \&startup, shutdown => \&shutdown },
    desc         => 'Application root',
);
```

Document `router` only as an accessor returning the root Router constructed by
Compose. State that `routes` accessor returns direct root children, so a
preserved child appears as the root Mount rather than flattened leaves.

- [ ] **Step 2: Add the four-way composition comparison to Compose and Mount POD.**

Include and explain:

```perl
# New root Router from declarations
compose(routes => \@nodes);

# Preserve an existing Router application
compose(routes => [mount('/' => app => $router)]);

# Deliberately flatten direct child nodes
compose(routes => $router->routes);

# Deploy without Compose root services
$router->to_app;
```

State that root Mount consumes no path, unnamed Mount adds no namespace, the
child owns 404/405/protocol misses, and later siblings after root Mount cannot
win.

- [ ] **Step 3: Correct Router and Routing POD.**

Replace claims that Compose retains the exact Router through `router =>` with:

```perl
compose(routes => [mount('/' => app => $router)]);
```

Explain that the Router identity is retained by Mount while Compose owns a
distinct outer root Router. Keep direct Router `to_app`, middleware,
`http_default`, Resolver, and lifespan caveats accurate.

- [ ] **Step 4: Write a complete upgrade section.**

In `UPGRADING.md`, include before/after examples for:

1. small declarative Router folded into direct Compose routes;
2. reusable immutable Router preserved through root Mount;
3. `PAGI::App::Router->to_router` preserved through root Mount;
4. `PAGI::Endpoint::Router->to_router` preserved through root Mount;
5. direct bare Router deployment; and
6. intentional `$router->routes` flattening with an explicit warning listing
   discarded middleware, default, desc, identity and Resolver.

State that there is no compatibility layer because the API is unreleased.

- [ ] **Step 5: Update Tutorial and Cookbook examples contextually.**

Do not perform blind search-and-replace. For each occurrence:

- use direct Compose routes for small declarative applications;
- use root Mount only for a prebuilt/configured Router;
- retain nested prefix Mounts as they are;
- preserve middleware placement and lifespan ownership; and
- explain inspectable immutable Router versus opaque frontend object where the
  distinction matters.

- [ ] **Step 6: Update Changes and the generated README source.**

Add a release-note bullet saying Compose now accepts only `routes`; existing
Routers are composed through Mount, and `$router->routes` is flattening.
Update the POD source from which README is generated, run the repository's
documented README generation command, and verify a second generation produces
no diff.

- [ ] **Step 7: Run documentation and upgrade tests.**

Run:

```bash
perlbrew exec --with perl-5.42.2@default prove -lv t/00-pod
perlbrew exec --with perl-5.42.2@default prove -lv \
  t/upgrading-routing-composition.t \
  t/upgrading-router-frontends.t
```

Then run:

```bash
rg -n -U 'compose\(\s*router\s*=>' \
  lib README.md UPGRADING.md Changes examples
```

Expected: no live positive usage. Negative diagnostics in upgrading prose may
match and must be inspected rather than deleted.

- [ ] **Step 8: Commit docs and ledger evidence.**

```bash
git add lib README.md UPGRADING.md Changes t/00-pod \
  t/upgrading-routing-composition.t t/upgrading-router-frontends.t
git commit -m "docs: teach routes and explicit Router mounting"
```

Stage only changed files. Record generator command, test counts, and stale
search evidence in the ledger, then advance to final verification.

---

### Task 8: Integrated Verification and Campaign Closure

**Files:**

- Modify: `.superpowers/sdd/2026-09-01-compose-routes-explicit-mount/progress.md`
- Modify: only files required to fix failures attributable to this campaign

**Interfaces:**

- Consumes: all prior tasks at one integrated HEAD.
- Produces: verified release candidate with no live Router constructor mode, synchronized generated docs, complete examples and auditable evidence.

- [ ] **Step 1: Reconfirm repository and branch mapping before verification.**

Run:

```bash
git branch --show-current
git status --short
git rev-parse HEAD
git rev-parse main
git rev-parse origin/main
```

Record exact output in the ledger. Do not merge, rebase, push, or modify sibling
repositories during this task.

- [ ] **Step 2: Run focused composition, routing, frontend, upgrade and POD suites together.**

Run:

```bash
perlbrew exec --with perl-5.42.2@default prove -lr \
  t/compose \
  t/routing \
  t/app-router.t \
  t/app-router \
  t/upgrading-routing-composition.t \
  t/upgrading-router-frontends.t \
  t/00-pod
```

Expected: PASS. Record file and test counts from the prove summary.

- [ ] **Step 3: Run final stale-surface and accidental-flattening searches.**

Run:

```bash
rg -n -U 'compose\(\s*router\s*=>' \
  lib t examples README.md UPGRADING.md Changes
rg -n 'compose.*->routes|routes\s*=>\s*\$[A-Za-z_][A-Za-z0-9_]*->routes' \
  lib t examples README.md UPGRADING.md Changes
rg -n "no longer accepts 'router'" lib t UPGRADING.md
```

Classify every hit:

- positive live `compose(router => ...)`: failure;
- negative diagnostic test or before-upgrade example: allowed;
- historical superpowers record: outside this search scope;
- `$router->routes` flattening: allowed only where prose/test explicitly says
  flattening and lists discarded policy.

- [ ] **Step 4: Run the complete distribution suite once.**

Run:

```bash
perlbrew exec --with perl-5.42.2@default prove -lr t
```

Expected: PASS. Do not repeat the full suite merely for fixture cleanup; that
twice-run convention applies only to the separate campaigns-api repository.
Record the exact files/tests/result.

- [ ] **Step 5: Run packaging and generated-file checks.**

Use the repository's existing Dist::Zilla build/test command. At minimum run:

```bash
perlbrew exec --with perl-5.42.2@default dzil test
git diff --check
git status --short
```

Regenerate README once more and assert no diff. If packaging fails, establish
whether the failure is introduced by this branch. Fix attributable failures;
record a pre-existing unrelated gate with command output rather than claiming
packaging success.

- [ ] **Step 6: Request final code review before closure.**

Use `superpowers:requesting-code-review` against the approved spec and this
plan. The reviewer must check:

- no hidden Mount or flattening;
- no lost Router policy;
- no stale positive Router constructor mode;
- correct root-Mount path/name/outcome ownership;
- unchanged lifespan and safety contracts;
- apples remains direct and readable; and
- every class-based example explains its explicit Mount.

Resolve findings with `superpowers:receiving-code-review`. Any design deviation
requires user approval and a ledger `DEV-NN` before correction.

- [ ] **Step 7: Commit any attributable final fixes, then close the ledger.**

If review or final verification required changes, run their focused tests and
commit those files with a descriptive message before closing the ledger.

Update Task 8 to `complete`, fill every row with implementation SHA, real test
count, and evidence, and add a final summary. It must name branch
`feature/compose-retained-router`, copy the exact final candidate SHA from
`git rev-parse HEAD`, copy the focused and full file/test counts from their
`prove` summaries, copy the packaging command and result, state that the stale
positive `compose(router => ...)` count is zero, and state that the unapproved
deviation count is zero.

Then:

```bash
git add -f .superpowers/sdd/2026-09-01-compose-routes-explicit-mount/progress.md
git commit -m "docs: close explicit Router mount campaign"
```

- [ ] **Step 8: Stop for integration direction.**

Report the final SHA, verification evidence, packaging evidence, review
result, branch status, and that the branch has not been pushed or merged unless
the user separately authorized those actions. Use
`superpowers:finishing-a-development-branch` only after the user selects the
integration path.
