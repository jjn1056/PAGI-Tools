# Direct Router Frontend Mounting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make direct App Router and Endpoint Router mounting the canonical deployment form while reserving `to_router` for boundaries that genuinely need inspectable routing structure.

**Architecture:** `PAGI::App::Router` and `PAGI::Endpoint::Router` already implement `to_app`, so an ordinary Mount retains either frontend as an opaque PAGI application. An explicit `to_router` remains the opt-in conversion for parent-side descendant-name discovery, immutable inspection, or stable snapshot identity. This campaign is expected to change tests, examples, and documentation rather than runtime code; a failing characterization test triggers a design review instead of frontend-specific Mount or Compose magic.

**Tech Stack:** Perl 5.18-compatible distribution code, Perl 5.40+ syntax in examples that already declare it, Future::AsyncAwait, Test2::V0, PAGI Test Client, Dist::Zilla, `PAGI::Routing`, `PAGI::App::Router`, `PAGI::Endpoint::Router`, and `PAGI::Compose`.

**Spec:** `docs/superpowers/specs/2026-09-01-direct-router-frontend-mounting-design.md`

## Global Constraints

- Repository/worktree: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/.worktrees/compose-retained-router`.
- Ticket: none.
- Branch: `feature/compose-retained-router`.
- Approved-spec commit: `f03b78226f836cb631bb24d9c46b9baa086cf274`; execution starts from the later plan commit and records that exact SHA in the ledger.
- Base relationship at planning time: branch contains the Compose retained-Router campaign over `origin/main` `558b14c282a38051bd8c1bb712290fe1df398330` and is one local commit ahead of `origin/feature/compose-retained-router` `8dea8d0f3b21212d6a58b1b729a962e597eefb89`.
- Owned changes: PAGI-Tools characterization tests, live examples, example READMEs, public POD, Tutorial, Cookbook, README source and generated README, `UPGRADING.md`, `Changes`, and campaign records. Runtime changes are outside the expected path.
- Deployment boundary: unreleased PAGI-Tools distribution. PAGI, PAGI::Server, and other repositories remain out of scope.
- Push target: existing `origin/feature/compose-retained-router` PR branch, only after review and user authorization.
- Reconfirm repository path, branch, HEAD, `main`, `origin/main`, push target, and worktree status before Task 1 and before pushing. Do not silently merge, rebase, or switch worktrees because another session changes `main`.
- If a value already implements the PAGI application contract, mount it directly for ordinary deployment: `mount('/' => app => $frontend)`.
- Use `to_router` only for parent inspection, descendant-name discovery, stable immutable identity, snapshot testing, materialization testing, or cycle testing.
- Do not remove, deprecate, alias, or change `to_router`.
- Do not add `router =>`, `include_router`, `to_routes`, a provider protocol, automatic `to_router` calls, frontend detection, cloning, hidden caches, or special Compose/Mount branches.
- Do not flatten with `$frontend->to_router->routes` or `$router->routes` as a substitute for mounting. Flattening remains explicitly lossy.
- Preserve route order, middleware, `http_default`, description, 404, 405, `Allow`, Resolver metadata inside the child, HEAD, WebSocket, SSE, lifespan, ErrorHandler, and ResponseGuard behavior.
- Keep the nested Endpoint Router snapshots that publish `/api/index`, `/api/events/stream`, and other descendant names to their parents.
- Historical files under `docs/superpowers/specs/` and `docs/superpowers/plans/` are records. Do not mechanically rewrite prior campaigns.
- Run Perl commands through `perlbrew exec --with perl-5.42.2@default`.
- Use focused suites after each task. Run the complete `prove -lr t` suite only once at the final candidate HEAD. Do not apply the campaigns-api twice-run convention here.
- Run `dzil build`, not `dzil test`, after the final suite; the complete suite must not be repeated through Dist::Zilla.
- Maintain `.superpowers/sdd/2026-09-01-direct-router-frontend-mounting/progress.md`. Every task gets status, implementation SHA, real test count, and evidence. Commit each implementation first, then update its ledger row in an immediate tracking commit.
- Record any deviation as `DEV-NN` with the conflicting requirement, evidence, proposed resolution, rationale, and explicit user approval before later tasks depend on it.
- Stop if implementation requires frontend-specific routing hacks, hidden conversions, duplicated resolver state, or changes beyond the files justified by a failing contract test.

---

## File Structure

| File or family | Responsibility after this campaign | Task |
| --- | --- | --- |
| `.superpowers/sdd/2026-09-01-direct-router-frontend-mounting/progress.md` | Work map, task status, commits, test evidence, deviations, retained-usage inventory | 1–5 |
| `t/app-router.t`, `t/upgrading-router-frontends.t`, `t/integration-router-application-boundaries.t` | Direct frontend application behavior versus explicit inspectable snapshot behavior | 1 |
| `examples/background-tasks`, `examples/full-demo`, `examples/endpoint-demo`, `examples/10-chat-showcase` and integration tests | Canonical direct App Router deployment | 2 |
| `examples/endpoint-router-demo` and `t/integration-endpoint-router-demo.t` | Direct Endpoint root deployment with explicit nested discovery boundaries | 3 |
| `lib/PAGI/Compose.pm`, `lib/PAGI/App/Router.pm`, `lib/PAGI/Endpoint/Router.pm` | Public application-versus-structure contract | 4 |
| `lib/PAGI/Tools.pm`, Tutorial, Cookbook, `UPGRADING.md`, `Changes`, generated `README.md`, POD tests | Minimal canonical syntax and explicit snapshot guidance | 4 |
| Repository search, focused suite, full suite, distribution build | Final integrated proof and retained `to_router` classification | 5 |

---

### Task 1: Characterize Direct Frontend Mounting

**Files:**

- Create: `.superpowers/sdd/2026-09-01-direct-router-frontend-mounting/progress.md`
- Modify: `t/app-router.t`
- Modify: `t/upgrading-router-frontends.t`
- Modify: `t/integration-router-application-boundaries.t`

**Interfaces:**

- Consumes: `PAGI::App::Router->to_app`, `PAGI::Endpoint::Router->to_app`, `mount($path => app => $object)`, `PAGI::Routing::URL::path_for`, and Compose's delegated `route_named` inspection.
- Produces: executable proof that a direct frontend mount dispatches and resolves locally while remaining opaque to its parent; an explicit snapshot remains parent-inspectable.

- [ ] **Step 1: Reconfirm the work map and create the campaign ledger.**

Run:

```bash
pwd
git branch --show-current
git rev-parse HEAD
git status --short
git rev-parse main
git rev-parse origin/main
git rev-parse origin/feature/compose-retained-router
```

Expected path and branch are the worktree and branch in Global Constraints.
Record any movement from the planning-time SHAs; do not change branches.

Create and force-add this tracking file:

```markdown
# SDD ledger — direct Router frontend mounting

Spec: docs/superpowers/specs/2026-09-01-direct-router-frontend-mounting-design.md
Plan: docs/superpowers/plans/2026-09-01-direct-router-frontend-mounting.md
Repository: /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/.worktrees/compose-retained-router
Ticket: none
Branch: feature/compose-retained-router
Approved-spec commit: f03b78226f836cb631bb24d9c46b9baa086cf274
Planning base: f03b78226f836cb631bb24d9c46b9baa086cf274
Deployment boundary: unreleased PAGI-Tools distribution
Push target: origin/feature/compose-retained-router after authorization

| Task | Status | Implementation commit | Tests | Evidence |
| --- | --- | --- | --- | --- |
| 1. Characterize contract | in progress | — | — | — |
| 2. App Router examples | pending | — | — | — |
| 3. Endpoint Router example | pending | — | — | — |
| 4. Public documentation | pending | — | — | — |
| 5. Final verification | pending | — | — | — |

## Retained user-facing `to_router` inventory

Pending final classification in Task 5.

## Deviations

None.
```

Add the exact execution-start HEAD from the work-map command to the first
Task 1 evidence entry before committing the ledger. Commit the ledger alone:

```bash
git add -f .superpowers/sdd/2026-09-01-direct-router-frontend-mounting/progress.md
git commit -m "docs: start direct frontend mounting campaign"
```

- [ ] **Step 2: Add an App Router root-mount characterization.**

In `t/app-router.t`, import local reverse routing:

```perl
use PAGI::Routing::URL qw(path_for);
```

After the existing explicit-snapshot subtest, add:

```perl
subtest 'Compose mounts an App Router frontend directly for ordinary deployment' => sub {
    my $default = PAGI::Response::Text->new(
        'frontend missing', status => 404,
    );
    my $builder = PAGI::App::Router->new(http_default => $default);
    $builder->get('/target' => sub {
        my ($request) = @_;
        return PAGI::Response::Text->new(path_for($request, 'target'));
    })->name('target');

    my $composition = compose(routes => [
        mount('/' => app => $builder),
    ]);

    is($composition->route_named('/target'), undef,
        'the outer Resolver does not inspect a frontend application');
    my $app = $composition->to_app;
    is(response_body(run_scope($app, path => '/target')), '/target',
        'the selected frontend installs its own resolver for local links');
    is(response_body(run_scope($app, path => '/missing')), 'frontend missing',
        'the selected frontend retains its own HTTP default');
    my $wrong = run_scope($app, method => 'POST', path => '/target');
    is([$wrong->[0]{status}, response_header($wrong, 'Allow')],
        [405, 'GET, HEAD'],
        'the selected frontend retains Router-owned 405 and Allow');
};
```

This test should pass against the existing runtime. If it fails, stop and
report the exact general contract failure before changing `lib/`.

- [ ] **Step 3: Strengthen the Endpoint direct-mount characterization.**

In the existing `Compose distinguishes inspectable Endpoint snapshots from
opaque frontends` subtest in `t/upgrading-router-frontends.t`, add this
identity assertion immediately after constructing `$opaque`:

```perl
is(refaddr($opaque->routes->[0]->app), refaddr($endpoint),
    'ordinary deployment retains the exact Endpoint application object');
```

Retain the existing equal-dispatch assertion and inspectable-snapshot
assertions. Rename `$opaque` to `$direct` only if every assertion in that
subtest is updated together; either variable name is acceptable, but the test
description must call direct mounting the canonical deployment form rather
than a fallback.

- [ ] **Step 4: Pin compilation frequency at the generic Mount boundary.**

In `t/integration-router-application-boundaries.t`, preserve the existing
`Local::MountedIntegrationApp` test and change its subtest description to:

```perl
subtest 'a directly mounted application object compiles once per parent graph' => sub {
```

Do not add a Router-specific counter or subclass. The generic application
contract plus the App/Endpoint dispatch tests is the intended proof; a special
frontend counter would test an implementation detail.

- [ ] **Step 5: Run focused characterization tests.**

Run:

```bash
perlbrew exec --with perl-5.42.2@default prove -lv \
  t/app-router.t \
  t/upgrading-router-frontends.t \
  t/integration-router-application-boundaries.t
```

Expected: PASS. Record the exact file and test counts.

- [ ] **Step 6: Commit Task 1 and update its ledger row.**

```bash
git add t/app-router.t t/upgrading-router-frontends.t \
  t/integration-router-application-boundaries.t
git commit -m "test: characterize direct router frontend mounting"
```

Then update Task 1 to `complete`, Task 2 to `in progress`, add the exact
implementation SHA and prove evidence, and commit the ledger update:

```bash
git add -f .superpowers/sdd/2026-09-01-direct-router-frontend-mounting/progress.md
git commit -m "docs: record frontend mount characterization"
```

---

### Task 2: Migrate App Router Examples to Direct Mounting

**Files:**

- Modify: `examples/background-tasks/app.pl`
- Modify: `examples/background-tasks/README.md`
- Modify: `examples/full-demo/app.pl`
- Modify: `examples/full-demo/README.md`
- Modify: `examples/endpoint-demo/app.pl`
- Modify: `examples/endpoint-demo/README.md`
- Modify: `examples/10-chat-showcase/app.pl`
- Modify: `examples/10-chat-showcase/lib/ChatApp/HTTP.pm`
- Modify: `examples/10-chat-showcase/README.md`
- Modify: `t/integration-router-application-boundaries.t`
- Modify: `t/integration-maintained-examples-load.t`
- Modify: `t/integration-app-file-examples.t`
- Modify: `t/integration-chat-compose.t`

**Interfaces:**

- Consumes: each example's existing `PAGI::App::Router` object and unnamed root Mount.
- Produces: executable examples that say exactly `app => $router`, retain all current behavior, and no longer teach snapshot conversion without a structural consumer.

- [ ] **Step 1: Add source-shape assertions before changing examples.**

Add this helper to both `t/integration-router-application-boundaries.t` and
`t/integration-maintained-examples-load.t`:

```perl
sub source_text {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot open $path: $!\n";
    local $/;
    my $source = <$fh>;
    close $fh or die "cannot close $path: $!\n";
    return $source;
}
```

In the background-task subtest, replace its inline file read with
`my $source = source_text($file);` and assert:

```perl
like($source,
    qr{mount\('/'\s*=>\s*app\s*=>\s*\$router\)},
    'background-task root mounts the App Router application directly');
unlike($source, qr/\$router->to_router/,
    'background-task root does not materialize an unused snapshot');
```

In `t/integration-maintained-examples-load.t`, place this block after `$file`
is assigned inside each example subtest:

```perl
if ($directory eq 'full-demo') {
    my $source = source_text($file);
    like($source,
        qr{mount\('/'\s*=>\s*app\s*=>\s*\$router\)},
        'full demo mounts the App Router application directly');
    unlike($source, qr/\$router->to_router/,
        'full demo does not materialize an unused snapshot');
}
```

In the endpoint-demo case in `t/integration-app-file-examples.t`, add the same
two assertions to `$source`.

In `t/integration-chat-compose.t`, add direct-root assertions for both
`$app_source` and `$http_source`:

```perl
for my $case (
    ['chat root', $app_source],
    ['chat HTTP child', $http_source],
) {
    my ($label, $source) = @$case;
    like($source,
        qr{mount\('/'\s*=>\s*app\s*=>\s*\$router\)},
        "$label mounts its App Router directly");
    unlike($source, qr/\$router->to_router/,
        "$label does not materialize an unused snapshot");
}
```

- [ ] **Step 2: Run the source-shape tests and confirm the expected failures.**

```bash
perlbrew exec --with perl-5.42.2@default prove -lv \
  t/integration-router-application-boundaries.t \
  t/integration-maintained-examples-load.t \
  t/integration-app-file-examples.t \
  t/integration-chat-compose.t
```

Expected: FAIL only on the new direct-mount source assertions.

- [ ] **Step 3: Replace unnecessary App Router snapshots.**

Make these exact semantic replacements:

```perl
# Before
mount('/' => app => $router->to_router)

# After
mount('/' => app => $router)
```

Apply them to the five application boundaries listed in Files: background
tasks, full demo, endpoint demo, chat root, and `ChatApp::HTTP`'s internal API
Router. Do not alter route declarations, middleware, lifespan callbacks,
static file applications, protocol handlers, or return types.

- [ ] **Step 4: Rewrite the example explanations around application mounting.**

For each affected README, replace snapshot-first prose with this model. Use
the concrete example name in place of "this application" when it improves the
surrounding paragraph:

````markdown
`PAGI::App::Router` already implements `to_app`, so Compose mounts the
frontend directly:

```perl
compose(routes => [mount('/' => app => $router)]);
```

The unnamed root Mount consumes no path and keeps the Router's middleware,
default, and routing outcomes. The outer Compose Router treats the frontend
as an application boundary and does not inspect its descendant names. Call
`$router->to_router` only when a parent must discover those names or retain an
immutable snapshot; this application has no such parent-side consumer.
````

Preserve each README's domain-specific explanations. Delete claims that the
frontend "must cross the immutable boundary" before deployment and delete
unused `$snapshot->routes` discussions from these root examples. Keep the
general warning that `$router->routes` is lossy only where the surrounding
section is explicitly comparing composition choices.

- [ ] **Step 5: Run the affected live example tests.**

```bash
perlbrew exec --with perl-5.42.2@default prove -lv \
  t/integration-router-application-boundaries.t \
  t/integration-maintained-examples-load.t \
  t/integration-app-file-examples.t \
  t/integration-chat-compose.t
```

Expected: PASS with unchanged HTTP, WebSocket, SSE, static-file, middleware,
and lifespan behavior.

- [ ] **Step 6: Commit Task 2 and update its ledger row.**

```bash
git add examples/background-tasks examples/full-demo examples/endpoint-demo \
  examples/10-chat-showcase \
  t/integration-router-application-boundaries.t \
  t/integration-maintained-examples-load.t \
  t/integration-app-file-examples.t t/integration-chat-compose.t
git commit -m "docs: mount app router examples directly"
```

Record the exact implementation SHA and test counts, mark Task 2 complete and
Task 3 in progress, then commit the ledger update.

---

### Task 3: Mount the Endpoint Root Directly and Preserve Nested Discovery

**Files:**

- Modify: `examples/endpoint-router-demo/app.pl`
- Modify: `examples/endpoint-router-demo/README.md`
- Modify: `t/integration-endpoint-router-demo.t`

**Interfaces:**

- Consumes: direct root Endpoint application `$main`, explicit nested snapshots `$self->{api}->to_router` and `$self->{events}->to_router`, and request-local `path_for`.
- Produces: a minimal root deployment that still publishes nested names within Main and API.

- [ ] **Step 1: Add source assertions for the intended mixed composition.**

In `t/integration-endpoint-router-demo.t`, extend the complete-demo subtest
after loading `app.pl` source:

```perl
like($app_source,
    qr{mount\('/'\s*=>\s*app\s*=>\s*\$main\)},
    'Compose mounts the configured Main Endpoint directly');
unlike($app_source, qr/\$main->to_router/,
    'the root does not materialize an unused Main snapshot');
```

Extend the source-level Endpoint-method subtest with:

```perl
like($main,
    qr{mount\('/api'\s*,\s*app\s*=>\s*\$self->\{api\}->to_router\)},
    'Main keeps the API snapshot because it resolves API descendant names');
like($api,
    qr{mount\('/events'\s*,\s*app\s*=>\s*\$self->\{events\}->to_router\)},
    'API keeps the Events snapshot in its inspectable namespace');
```

Keep the existing live assertions for `/api/index`, `/api/show/1`,
`/api/tools/status`, `/api/events/stream`, API default, 405 `Allow`, WebSocket,
SSE, and lifespan state.

- [ ] **Step 2: Run the Endpoint integration test and confirm only the root-shape assertion fails.**

```bash
perlbrew exec --with perl-5.42.2@default prove -lv t/integration-endpoint-router-demo.t
```

Expected: the new `$main` root assertion fails; nested snapshot assertions and
live behavior pass.

- [ ] **Step 3: Mount Main directly.**

In `examples/endpoint-router-demo/app.pl`, replace only:

```perl
mount('/' => app => $main->to_router)
```

with:

```perl
mount('/' => app => $main)
```

Do not change `MyApp::Main` or `MyApp::API` nested Mount declarations.

- [ ] **Step 4: Rewrite the README's root-versus-nested explanation.**

Use this root example:

```perl
my $events = MyApp::API::Events->new;
my $api    = MyApp::API->new(events => $events);
my $main   = MyApp::Main->new(api => $api);

my $app = compose(
    routes => [mount('/' => app => $main)],
    lifespan => { startup => \&startup, shutdown => \&shutdown },
);
```

State explicitly:

- Main is already a PAGI application and needs no root conversion;
- Main's own compilation installs the resolver used by `home`;
- Main converts API because `home` resolves `/api/index`;
- API converts Events so `/api/events/stream` remains part of the inspectable
  tree;
- the outer Compose Router does not need Main's descendant names merely to
  deploy it; and
- `$main->to_router` remains useful to tests and tools that inspect the whole
  tree.

- [ ] **Step 5: Run the Endpoint integration test.**

```bash
perlbrew exec --with perl-5.42.2@default prove -lv t/integration-endpoint-router-demo.t
```

Expected: PASS. The generated home-to-API and API-to-item links must still be
followed by the Test Client rather than compared only as strings.

- [ ] **Step 6: Commit Task 3 and update its ledger row.**

```bash
git add examples/endpoint-router-demo/app.pl \
  examples/endpoint-router-demo/README.md \
  t/integration-endpoint-router-demo.t
git commit -m "docs: mount endpoint root directly"
```

Record the exact implementation SHA and test count, mark Task 3 complete and
Task 4 in progress, then commit the ledger update.

---

### Task 4: Correct the Public Documentation Model

**Files:**

- Modify: `lib/PAGI/Compose.pm`
- Modify: `lib/PAGI/App/Router.pm`
- Modify: `lib/PAGI/Endpoint/Router.pm`
- Modify: `lib/PAGI/Tools.pm`
- Modify: `lib/PAGI/Tools/Tutorial.pod`
- Modify: `lib/PAGI/Tools/Cookbook.pod`
- Modify: `UPGRADING.md`
- Modify: `Changes`
- Modify through its generator: `README.md`
- Modify: `t/upgrading-routing-composition.t`

**Interfaces:**

- Consumes: the characterized application/inspection distinction and migrated examples.
- Produces: one public rule across constructor POD, tutorials, cookbook, README, Changes, and upgrade guide.

- [ ] **Step 1: Change documentation tests to require the canonical form.**

In `t/upgrading-routing-composition.t`, replace the class-example loop that
requires `$router->to_router` snapshots in every README. Require instead:

```perl
like($source,
    qr{mount\('/'\s*=>\s*app\s*=>\s*\$router\)},
    "$file mounts its frontend application directly");
unlike($source, qr/\$router->to_router/,
    "$file has no unconsumed root snapshot conversion");
like($source,
    qr/already implements.*?to_app.*?directly.*?to_router.*?(?:inspect|discover|snapshot)/is,
    "$file explains direct application mounting and explicit inspection");
```

Use a separate Endpoint Router README assertion requiring `app => $main` at
the root and the two justified nested `to_router` calls.

For `lib/PAGI/App/Router.pm`, require:

```perl
like($source,
    qr/mount\('\/' => app => \$r\).*?ordinary.*?application/is,
    'App Router leads with direct frontend mounting');
like($source,
    qr/to_router.*?parent.*?(?:inspect|discover).*?descendant/is,
    'App Router reserves to_router for structural discovery');
```

For `lib/PAGI/Endpoint/Router.pm`, require:

```perl
like($source,
    qr/mount\('\/' => app => \$endpoint\).*?ordinary.*?application/is,
    'Endpoint Router leads with direct frontend mounting');
like($source,
    qr/to_router.*?parent.*?(?:inspect|discover).*?descendant/is,
    'Endpoint Router reserves to_router for structural discovery');
```

- [ ] **Step 2: Run the documentation tests and confirm stale guidance fails.**

```bash
perlbrew exec --with perl-5.42.2@default prove -lv \
  t/upgrading-routing-composition.t \
  t/upgrading-router-frontends.t \
  t/00-pod/cookbook-examples.t
```

Expected: failures identify snapshot-first public examples and prose.

- [ ] **Step 3: Correct Compose POD.**

In `lib/PAGI/Compose.pm`:

- keep `compose(routes => [mount('/' => app => $router)])` for an existing
  immutable Router;
- replace the claim that mutable frontends must cross the immutable boundary;
- show `mount('/' => app => $builder)` and `mount('/' => app => $endpoint)` as
  ordinary deployment;
- state that direct frontend applications are opaque only to the outer
  Resolver, not to their own handlers;
- show `$child->to_router` only in a named parent Mount whose parent generates
  or inspects a child route; and
- retain the warning that `compose(routes => $router->routes)` is lossy.

The key normative paragraph must say:

```text
App Router and Endpoint Router frontends already implement to_app and may be
mounted directly for ordinary application composition. Convert a frontend
with to_router only when the receiving Router must discover its descendant
names or when the immutable snapshot itself must be retained or inspected.
Compose and Mount never call to_router automatically.
```

- [ ] **Step 4: Correct App Router and Endpoint Router POD.**

In both modules, make the first Compose deployment example direct:

```perl
my $app = compose(
    routes => [mount('/' => app => $r)],
)->to_app;
```

and:

```perl
my $app = compose(
    routes => [mount('/' => app => $endpoint)],
)->to_app;
```

Keep `to_router` documentation, but lead its composition example with a real
parent consumer:

```perl
$parent->mount(
    '/people',
    app => $people->to_router,
)->name('people');

$parent->path_for('/people/show', { id => 42 });
```

State that `to_app` itself already materializes and compiles one fresh Router
snapshot, so calling `to_router` immediately before an opaque root Mount only
adds syntax unless the outer root inspects that snapshot.

- [ ] **Step 5: Correct Tutorial, Cookbook, front-page POD, upgrade guide, and Changes.**

Apply these rules consistently:

- front-page App Router examples end with `mount('/' => app => $router)`;
- tutorial root examples use direct frontends;
- cookbook nested examples keep `$child->to_router` when followed by parent
  `path_for` or inspection;
- cookbook deployment examples with no parent consumer use the frontend
  directly;
- `UPGRADING.md` separates "ordinary deployment" from "retain an inspectable
  snapshot" and does not say every mutable frontend must cross an immutable
  boundary; and
- the `0.002003 - UNRELEASED` Compose section in `Changes` adds:

```text
  - App Router and Endpoint Router objects already implement `to_app`, so
    ordinary root Mounts now pass those frontend objects directly. `to_router`
    remains the explicit conversion when a parent must discover descendant
    names or retain an immutable snapshot; Compose and Mount perform no hidden
    conversion.
```

Do not rewrite historical Before blocks whose purpose is to show a removed
API. Label them clearly enough that repository searches can distinguish them
from current guidance.

- [ ] **Step 6: Regenerate README from `lib/PAGI/Tools.pm`.**

Run one no-archive Dist::Zilla build in a fresh temporary directory:

```bash
build_dir=$(mktemp -d /tmp/pagi-tools-direct-mount-readme.XXXXXX)
perlbrew exec --with perl-5.42.2@default dzil build --no-tgz --in "$build_dir"
test -f README.md
test -f "$build_dir/README.md"
cmp README.md "$build_dir/README.md"
```

The `build_dir` assignment and all three checks must run in the same shell
invocation so the validated path is not lost. Do not delete or reuse an
unvalidated directory. Inspect `git diff -- README.md lib/PAGI/Tools.pm` and
confirm the generated README carries the direct form.

- [ ] **Step 7: Run focused public-document tests.**

```bash
perlbrew exec --with perl-5.42.2@default prove -lv \
  t/upgrading-routing-composition.t \
  t/upgrading-router-frontends.t \
  t/00-pod/cookbook-examples.t
```

Expected: PASS.

- [ ] **Step 8: Commit Task 4 and update its ledger row.**

```bash
git add lib/PAGI/Compose.pm lib/PAGI/App/Router.pm \
  lib/PAGI/Endpoint/Router.pm lib/PAGI/Tools.pm \
  lib/PAGI/Tools/Tutorial.pod lib/PAGI/Tools/Cookbook.pod \
  README.md UPGRADING.md Changes \
  t/upgrading-routing-composition.t t/upgrading-router-frontends.t
git commit -m "docs: teach direct router frontend mounting"
```

Record the exact implementation SHA and test counts, mark Task 4 complete and
Task 5 in progress, then commit the ledger update.

---

### Task 5: Audit Retained Conversions and Verify the Distribution

**Files:**

- Modify only if the audit finds an attributable stale live usage: files under `lib/`, `t/`, `examples/`, `README.md`, `UPGRADING.md`, or `Changes`
- Modify: `.superpowers/sdd/2026-09-01-direct-router-frontend-mounting/progress.md`

**Interfaces:**

- Consumes: all prior task commits at one integrated HEAD.
- Produces: classified retained `to_router` inventory, passing focused/full suites, clean generated documentation, and one inspected distribution build.

- [ ] **Step 1: Reconfirm the multi-repository work map before final verification.**

```bash
pwd
git branch --show-current
git rev-parse HEAD
git status --short
git rev-parse main
git rev-parse origin/main
git rev-parse origin/feature/compose-retained-router
```

Record the exact output in the ledger. Do not merge, rebase, push, or modify a
sibling repository.

- [ ] **Step 2: Inventory every live `to_router` use.**

Run:

```bash
rg -n --glob '!docs/superpowers/**' --glob '!blib/**' --glob '!local/**' \
  '->to_router' lib t examples README.md UPGRADING.md Changes
```

Classify every hit into one of these allowed categories:

1. implementation of `to_app` or inspection convenience inside the frontend;
2. parent descendant-name discovery;
3. retained immutable snapshot inspection or identity;
4. materialization, cycle, or snapshot tests;
5. explicitly labelled Before/upgrade history; or
6. stale deployment ceremony to remove.

No category-6 hit may remain. Add a concise retained user-facing inventory to
the ledger naming each live example/POD conversion and its consumer. At
minimum it must explain the Endpoint demo's Main-to-API and API-to-Events
boundaries and the Cookbook's parent reverse-routing example.

- [ ] **Step 3: Search for accidental flattening and stale canonical prose.**

```bash
rg -n 'mounting.*frontend.*opaque|cross.*immutable boundary|snapshot.*before.*Compose' \
  lib examples README.md UPGRADING.md Changes
rg -n 'routes\s*=>\s*\$[A-Za-z_][A-Za-z0-9_]*(?:->to_router)?->routes' \
  lib t examples README.md UPGRADING.md Changes
```

Every surviving opacity statement must call direct mounting ordinary
application composition and explain the parent-inspection limitation. Every
flattening hit must be an explicit lossy example or test. Fix attributable
stale guidance and rerun the owning focused test before continuing.

- [ ] **Step 4: Run the integrated focused suite.**

```bash
perlbrew exec --with perl-5.42.2@default prove -lr \
  t/app-router.t \
  t/app-router \
  t/endpoint-router.t \
  t/endpoint \
  t/integration-router-application-boundaries.t \
  t/integration-maintained-examples-load.t \
  t/integration-app-file-examples.t \
  t/integration-chat-compose.t \
  t/integration-endpoint-router-demo.t \
  t/upgrading-routing-composition.t \
  t/upgrading-router-frontends.t \
  t/00-pod
```

Expected: PASS. Record exact files/tests/result.

- [ ] **Step 5: Run the complete suite once at final candidate HEAD.**

```bash
perlbrew exec --with perl-5.42.2@default prove -lr t
```

Expected: PASS. Record exact HEAD, exit status, file count, assertion count,
wall/CPU time, skips, warnings, and failures. If a defect requires a code
change, record it, run only its focused test while fixing, and then run one new
full suite at the corrected final HEAD; do not rerun for reassurance.

- [ ] **Step 6: Build and inspect one distribution archive without rerunning tests.**

```bash
perlbrew exec --with perl-5.42.2@default dzil build
git diff --check
git status --short
```

Do not run `dzil test`. Record the archive path, size, SHA-256, and entry count.
Verify the archive contains the current README, POD, upgrade guide, Changes,
tests, and example documentation required by the distribution configuration;
verify `docs/superpowers`, `.superpowers`, VCS data, and unrelated build
artifacts are absent. Confirm the build does not change tracked README content.

- [ ] **Step 7: Request final code review.**

Use `superpowers:requesting-code-review` against the approved spec and this
plan. The reviewer must check:

- direct frontend Mount is the canonical root form;
- no runtime conversion magic was added;
- nested snapshot conversions have concrete name/inspection consumers;
- examples and docs agree;
- no routing, middleware, lifespan, HTTP, WebSocket, or SSE behavior regressed;
- retained `to_router` inventory is complete; and
- verification evidence belongs to the exact reviewed HEAD.

Apply accepted review fixes with focused tests. If HEAD changes after the full
suite, follow Step 5's corrected-final-HEAD rule.

- [ ] **Step 8: Commit any final attributable correction, then close the ledger.**

If Task 5 changed live files, commit them with their focused test evidence:

```bash
git add lib t examples README.md UPGRADING.md Changes
git commit -m "docs: complete direct frontend mount audit"
```

Update Task 5 to `complete`; record final implementation/review commits, exact
focused and full-suite counts, distribution evidence, work-map verification,
and the retained user-facing inventory. Commit the ledger update:

```bash
git add -f .superpowers/sdd/2026-09-01-direct-router-frontend-mounting/progress.md
git commit -m "docs: close direct frontend mounting campaign"
```

Do not push, merge, close the PR, switch the main checkout, or remove this
worktree without explicit user authorization.
