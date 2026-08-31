# Explicit Middleware Descriptors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every core Route, Mount, Router, and Compose middleware list contain only explicit `middleware(...)` descriptions, using Starlette-style deferred construction, Plack-familiar package naming, and the shared PAGI application-value result contract.

**Architecture:** `PAGI::Routing::Middleware` remains the one immutable middleware description. Core constructors validate descriptions without coercion; higher-level App Router, Endpoint Router, and Middleware Builder own any concise syntax and normalize it before materializing immutable nodes. Middleware factories and `wrap` methods still run synchronously once per compiled stack, but may return either native CODE or an instantiated `to_app` object, normalized immediately through `PAGI::Utils::to_app`.

**Tech Stack:** Perl 5.40+, Future::AsyncAwait, Test2::V0, Dist::Zilla, PAGI native application middleware.

**Spec:** `docs/superpowers/specs/2026-08-30-explicit-middleware-descriptors-design.md`

## Global Constraints

- Repository: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools`.
- Ticket: none; this is the middleware-contract follow-up to merged PR #25.
- Execution branch: `feature/explicit-middleware-descriptors`.
- Base: `main@045eae3fc973e0bbca67aa804d834f588ec5087c`.
- Owned changes: PAGI-Tools middleware descriptions, core composition constructors, higher-level router/builder normalization, live tests, examples, POD, README, Changes, and UPGRADING.
- Deployment boundary: one unreleased PAGI-Tools distribution; PAGI and PAGI::Server are read-only references.
- Push target: `origin/feature/explicit-middleware-descriptors`, only after implementation, review, and final verification.
- Breaking changes to unreleased PAGI-Tools APIs are allowed; do not add aliases, warnings, or compatibility parsing for bare core entries or `^` package names.
- Core Route, Mount, Router, and Compose lists accept only `PAGI::Routing::Middleware` descriptions.
- App Router, Endpoint Router, and Middleware Builder remain higher-level sugar and may normalize concise entries internally.
- Short class names resolve under `PAGI::Middleware::`; leading `+` selects an exact package; already `PAGI::Middleware::`-qualified names remain exact; leading `^` is invalid.
- Middleware runtime remains native three-argument app-to-app wrapping. Do not add Request middleware, response-valued `$next`, arity inference, asynchronous stack construction, or request-time factory resolution.
- Factory and `wrap` results may be native CODE or instantiated `to_app` objects and are normalized once during compilation.
- Preserve first-listed-outermost order, Route FULL-only placement, Mount/Router/Compose boundary ownership, metadata timing, HEAD behavior, and HTTP/WebSocket/SSE behavior.
- Do not add defensive copying beyond the existing shallow description/config/list copies.
- Use TDD for each behavior change. Run focused suites per task and the repository-wide suite once at final candidate HEAD.
- Before implementation, create and force-add `.superpowers/sdd/2026-08-30-explicit-middleware-descriptors/progress.md` with one row per task recording status, implementation commit SHA, test counts, and verification evidence. For each task, make the implementation commit first, read its real SHA, then update the ledger in an immediate task-local tracking commit.
- Record any implementation deviation as `DEV-NN` with rationale and user approval before another task depends on it.

---

### Task 1: Make `middleware(...)` the Complete Explicit Description

**Files:**

- Modify: `lib/PAGI/Routing/Middleware.pm`
- Modify: `t/routing/04-middleware-descriptors.t`
- Modify: `t/routing/01-constructors.t`
- Modify: `Changes`
- Create: `.superpowers/sdd/2026-08-30-explicit-middleware-descriptors/progress.md`

**Interfaces:**

- Consumes: `middleware($target, %config)`, `PAGI::Utils::to_app($value)`, and native inner application CODE.
- Produces: immutable descriptions supporting class strings, factory CODE with optional `%config`, and configured `wrap` objects; private `_wrap($inner_code)` always returns compiled native CODE.

- [ ] **Step 1: Create the execution ledger and record the work map.**

Create the progress file with this table:

```markdown
# Explicit Middleware Descriptors Execution

| Task | Status | Commit | Tests | Evidence |
|---|---|---|---|---|
| 1. Explicit descriptor | in progress | — | — | — |
| 2. Strict core lists | pending | — | — | — |
| 3. Router frontend sugar | pending | — | — | — |
| 4. Builder naming | pending | — | — | — |
| 5. Examples and docs | pending | — | — | — |
| 6. Upgrade and verification | pending | — | — | — |

Work map: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools`, ticket none,
branch `feature/explicit-middleware-descriptors`, base
`045eae3fc973e0bbca67aa804d834f588ec5087c`, deployment boundary PAGI-Tools
distribution, push target `origin/feature/explicit-middleware-descriptors`.

## Deviations

None.
```

The execution ledger lives under an intentionally ignored working-artifact
directory, so add it explicitly and commit the campaign start before changing
production code:

```bash
git add -f .superpowers/sdd/2026-08-30-explicit-middleware-descriptors/progress.md
git commit -m "docs: start explicit middleware campaign"
```

- [ ] **Step 2: Add failing tests for Plack-familiar class resolution.**

In `t/routing/04-middleware-descriptors.t`, replace `^` cases and pin these exact mappings through description compilation:

```perl
my @cases = (
    ['RequestId', 'PAGI::Middleware::RequestId'],
    ['Auth::Basic', 'PAGI::Middleware::Auth::Basic'],
    ['PAGI::Middleware::RequestId', 'PAGI::Middleware::RequestId'],
    ['+Local::ExactMiddleware', 'Local::ExactMiddleware'],
);
```

Use the existing in-memory module-loader pattern and assert the resolved class is loaded and constructed only when `_wrap` runs. Add:

```perl
like dies { middleware('^Local::OldEscape') },
    qr/invalid middleware class name|leading '\+'|exact package/i,
    'the retired caret exact-package spelling is rejected';
```

- [ ] **Step 3: Add failing tests for factory configuration and application-valued results.**

Add a factory test that records its arguments:

```perl
my @factory_calls;
my $descriptor = middleware(sub {
    my ($inner, %config) = @_;
    push @factory_calls, [$inner, {%config}];
    return Local::WrappedApplication->new(inner => $inner);
}, label => 'items', enabled => 1);
```

Define `Local::WrappedApplication->to_app` to return native CODE delegating to
`inner`. Assert:

- construction performs no factory call;
- `_wrap($inner)` calls the factory exactly once;
- `%config` contains `label => 'items', enabled => 1`;
- `to_app` is called exactly once during `_wrap`;
- the returned value is CODE and delegates correctly; and
- a second `_wrap` creates a distinct compiled wrapper.

Add the same application-valued result assertion for a configured object's
`wrap($inner)`. Retain a test proving a configured object plus descriptor
configuration croaks.

- [ ] **Step 4: Add failing diagnostics tests for invalid synchronous results.**

Require each of these to fail during `_wrap`, before request invocation:

```perl
middleware(sub { return undef })
middleware(sub { return [] })
middleware(sub { return Future->done(sub { }) })
middleware(Local::BadWrapObject->new)
```

Diagnostics must say either `middleware factory` or `middleware wrap` and
`must return a PAGI application value` followed by the underlying shape.

- [ ] **Step 5: Run the descriptor tests and confirm RED.**

Run:

```bash
prove -lv t/routing/04-middleware-descriptors.t t/routing/01-constructors.t
```

Expected: failures are limited to `+` resolution, retired `^` rejection,
coderef configuration, and object-valued wrapper results.

- [ ] **Step 6: Implement the explicit descriptor contract.**

In `PAGI::Routing::Middleware`:

1. Change the class-name validator from optional `^` to optional leading `+`.
2. Permit `%config` for CODE targets.
3. Continue rejecting `%config` for blessed configured objects.
4. Resolve class names as:

```perl
sub _resolve_class {
    my ($name) = @_;
    return substr($name, 1) if substr($name, 0, 1) eq '+';
    return $name if $name =~ /\APAGI::Middleware::/;
    return "PAGI::Middleware::$name";
}
```

5. Call a factory with the inner app and flat configuration:

```perl
my $wrapped = $target->($inner_app, %{$self->{config}});
return _compile_wrapped_app($wrapped, 'middleware factory');
```

6. Normalize `wrap` results through the same helper:

```perl
sub _compile_wrapped_app {
    my ($value, $source) = @_;
    my $app = eval { PAGI::Utils::to_app($value) };
    if (my $error = $@) {
        chomp $error;
        croak "$source must return a PAGI application value: $error";
    }
    return $app;
}
```

Import `PAGI::Utils ()`. Do not catch errors raised by the factory, class
constructor, or `wrap` itself; only contextualize normalization failures.

- [ ] **Step 7: Run focused descriptor tests and confirm GREEN.**

Run:

```bash
prove -lv \
  t/routing/04-middleware-descriptors.t \
  t/routing/01-constructors.t \
  t/router-middleware.t
```

Expected: PASS with factory/object/class construction still occurring once per
compiled wrapper and first-listed-outermost behavior unchanged.

- [ ] **Step 8: Commit Task 1, then record its real evidence.**

Add a Changes bullet describing explicit factory configuration, leading `+`,
and application-valued wrapper results. Commit the implementation without the
ledger:

```bash
git add Changes lib/PAGI/Routing/Middleware.pm \
  t/routing/04-middleware-descriptors.t t/routing/01-constructors.t
git commit -m "refactor: define explicit middleware descriptions"
```

Run `git rev-parse HEAD`, copy that exact SHA and the focused harness totals
into Task 1's ledger row, then make the task-local tracking commit:

```bash
git add -f .superpowers/sdd/2026-08-30-explicit-middleware-descriptors/progress.md
git commit -m "docs: record middleware descriptor evidence"
```

---

### Task 2: Require Descriptions at Every Core Middleware Boundary

**Files:**

- Modify: `lib/PAGI/Routing/Middleware.pm`
- Modify: `lib/PAGI/Routing/Route.pm`
- Modify: `lib/PAGI/Routing/Mount.pm`
- Modify: `lib/PAGI/Routing/Router.pm`
- Modify: `lib/PAGI/Compose.pm`
- Modify: `t/routing/01-constructors.t`
- Rewrite: `t/routing/11-bare-middleware.t`
- Modify: `t/compose/01-description.t`
- Modify: `t/compose/04-middleware.t`
- Modify: `t/compose/05-head-concurrency.t`
- Modify: `.superpowers/sdd/2026-08-30-explicit-middleware-descriptors/progress.md`

**Interfaces:**

- Consumes: arrays of `PAGI::Routing::Middleware` descriptions.
- Produces: `_require_descriptors($entries, $label)` for immutable/core constructors and `_normalize_frontend_entries($entries, $label)` reserved for higher-level frontends.

- [ ] **Step 1: Add a shared core-boundary rejection matrix.**

In `t/routing/01-constructors.t`, exercise Route, WebSocket Route, SSE Route,
Mount `app`, Mount `routes`, and Router constructors. For each constructor,
assert these entries fail at construction:

```perl
'RequestId'
sub { return $_[0] }
Local::ConfiguredMiddleware->new
{}
```

Require diagnostics of the form:

```text
middleware entry 0 must be a PAGI::Routing::Middleware description returned by middleware(...)
```

Add corresponding Compose cases in `t/compose/01-description.t`.

- [ ] **Step 2: Pin valid identity and copy behavior.**

For each core constructor, pass:

```perl
my $first  = middleware('RequestId');
my $second = middleware(sub { return $_[0] });
my $input  = [$first, $second];
```

Assert construction retains each descriptor's identity and order, mutation of
`$input` does not change the description, and mutation of a returned
`middleware` arrayref does not change a later accessor result.

- [ ] **Step 3: Run constructor suites and confirm RED.**

Run:

```bash
prove -lv \
  t/routing/01-constructors.t \
  t/routing/11-bare-middleware.t \
  t/compose/01-description.t \
  t/compose/04-middleware.t
```

Expected: bare entries still pass and therefore fail the new rejection
assertions.

- [ ] **Step 4: Split strict validation from frontend normalization.**

Replace `_normalize_descriptors` with two private methods:

```perl
sub _require_descriptors {
    my ($class, $entries, $error_prefix) = @_;
    $error_prefix //= 'middleware';
    croak "$error_prefix must be an arrayref"
        unless ref($entries) eq 'ARRAY';

    my @descriptions;
    for my $index (0 .. $#$entries) {
        my $entry = $entries->[$index];
        croak "$error_prefix entry $index must be a "
            . 'PAGI::Routing::Middleware description returned by middleware(...)'
            unless blessed($entry) && $entry->isa($class);
        push @descriptions, $entry;
    }
    return \@descriptions;
}
```

Move the old bare-entry conversion behavior into:

```perl
sub _normalize_frontend_entries {
    my ($class, $entries, $error_prefix) = @_;
    # Validate the array and convert class strings, factory CODE, and wrap
    # objects with $class->new; preserve existing descriptions by identity.
}
```

Use explicit code copied from the current `_normalize_descriptors`; do not
make `_require_descriptors` call the sugar method.

- [ ] **Step 5: Switch every core constructor to strict validation.**

Change these four constructors to `_require_descriptors`:

```perl
PAGI::Routing::Route->_build
PAGI::Routing::Mount->_new_from
PAGI::Routing::Router->new
PAGI::Compose->new
```

Do not alter `_wrap_descriptors` or compiler placement.

- [ ] **Step 6: Rewrite the former bare-middleware characterization test.**

Change `t/routing/11-bare-middleware.t` from proving core shorthand to proving:

- all core boundaries reject bare forms;
- equivalent `middleware(...)` descriptions run at Route, Mount, and Router;
- HTTP, WebSocket, and SSE behavior remains protocol-independent;
- first-listed-outermost order remains unchanged; and
- invalid factory/Future/wrap results still fail during `to_app`.

Create `t/routing/11-explicit-middleware.t` with `apply_patch`, update any
references found by `rg`, and remove the old file with `apply_patch` only after
the new focused test passes. Also make the formerly bare author factories in
`t/compose/05-head-concurrency.t` explicit without changing its HEAD-ordering
assertions.

- [ ] **Step 7: Run core middleware suites and confirm GREEN.**

Run:

```bash
prove -lv \
  t/routing/01-constructors.t \
  t/routing/04-middleware-descriptors.t \
  t/routing/11-explicit-middleware.t \
  t/routing/07-mounts.t \
  t/routing/08-protocols.t \
  t/routing/09-metadata-isolation.t \
  t/routing/12-router-mounts.t \
  t/compose/01-description.t \
  t/compose/04-middleware.t \
  t/compose/05-head-concurrency.t
```

Expected: PASS. Core shorthand rejection must not change runtime ordering or
routing outcomes.

- [ ] **Step 8: Commit Task 2, then record its real evidence.**

Commit the implementation and tests first:

```bash
git add lib/PAGI/Routing/Middleware.pm lib/PAGI/Routing/Route.pm \
  lib/PAGI/Routing/Mount.pm lib/PAGI/Routing/Router.pm lib/PAGI/Compose.pm \
  t/routing/01-constructors.t t/routing/11-explicit-middleware.t \
  t/compose/01-description.t t/compose/04-middleware.t \
  t/compose/05-head-concurrency.t
git add -u t/routing/11-bare-middleware.t
git commit -m "refactor: require explicit core middleware descriptions"
```

Run `git rev-parse HEAD`, record that SHA, the focused harness totals, and the
bare-entry scan result in Task 2's row, then commit the ledger separately:

```bash
git add -f .superpowers/sdd/2026-08-30-explicit-middleware-descriptors/progress.md
git commit -m "docs: record strict middleware boundary evidence"
```

---

### Task 3: Preserve Sugar in App Router and Endpoint Router

**Files:**

- Modify: `lib/PAGI/App/Router/Builder.pm`
- Modify: `lib/PAGI/Endpoint/Router.pm`
- Modify: `lib/PAGI/Endpoint/Router/Builder.pm`
- Modify: `t/app-router/01-builder-core.t`
- Modify: `t/app-router/05-middleware-order.t`
- Modify: `t/endpoint-router.t`
- Modify: `t/endpoint/12-route-middleware.t`
- Modify: `t/upgrading-router-frontends.t`
- Modify: `.superpowers/sdd/2026-08-30-explicit-middleware-descriptors/progress.md`

**Interfaces:**

- Consumes: `_normalize_frontend_entries`, App Router's existing bare entry forms, and Endpoint `middleware_as($name)`.
- Produces: immutable Route/Mount/Router objects whose middleware accessors contain only explicit descriptions.

- [ ] **Step 1: Add frontend normalization tests before changing production calls.**

For App Router root, Route, and Mount middleware positions, declare this list:

```perl
[
    'RequestId',
    '+Local::ExactMiddleware',
    sub { my ($inner) = @_; return $inner },
    Local::ConfiguredMiddleware->new,
    middleware('ContentLength'),
]
```

Assert each materialized immutable middleware accessor contains five
`PAGI::Routing::Middleware` objects in the same order. Assert the explicit
description retains identity while every bare occurrence receives a distinct
description.

- [ ] **Step 2: Pin Endpoint local-method sugar.**

In `t/endpoint/12-route-middleware.t`, retain:

```perl
$r->get('/private' => [
    $self->middleware_as('authenticate'),
] => 'show');
```

Assert the materialized Route contains an explicit description, the bound
method runs once per request around the native app, and no local method is
invoked during declaration normalization.

- [ ] **Step 3: Run frontend suites and confirm RED after Task 2.**

Run:

```bash
prove -lv \
  t/app-router/01-builder-core.t \
  t/app-router/05-middleware-order.t \
  t/endpoint-router.t \
  t/endpoint/12-route-middleware.t \
  t/upgrading-router-frontends.t
```

Expected: frontend materialization fails because App Router still calls the
retired core normalizer or passes bare entries into strict immutable nodes.

- [ ] **Step 4: Route all App Router sugar through the frontend normalizer.**

Change the App Router root, Mount, and Route declaration paths to call:

```perl
PAGI::Routing::Middleware->_normalize_frontend_entries(
    $entries,
    'middleware',
)
```

Keep the normalized descriptions in mutable records and pass only those
descriptions to the Materializer. Do not re-normalize during each materialized
Route construction.

- [ ] **Step 5: Keep Endpoint adapters explicit at materialization.**

Endpoint Builder continues binding handler strings and leaving
`middleware_as` as an ordinary factory coderef. Confirm it delegates its
middleware list to App Router's frontend normalization exactly once. Do not
teach the immutable Route about Endpoint objects or local method names.

- [ ] **Step 6: Run frontend suites and confirm GREEN.**

Run the command from Step 3. Expected: PASS, including first-listed-outermost
order and class/factory/object/description sugar.

- [ ] **Step 7: Commit Task 3, then record its real evidence.**

Commit the frontend implementation and tests:

```bash
git add lib/PAGI/App/Router/Builder.pm lib/PAGI/Endpoint/Router.pm \
  lib/PAGI/Endpoint/Router/Builder.pm t/app-router/01-builder-core.t \
  t/app-router/05-middleware-order.t t/endpoint-router.t \
  t/endpoint/12-route-middleware.t t/upgrading-router-frontends.t
git commit -m "refactor: keep middleware sugar in router frontends"
```

Run `git rev-parse HEAD`, record the SHA and focused harness totals in Task 3's
row, then make the tracking commit:

```bash
git add -f .superpowers/sdd/2026-08-30-explicit-middleware-descriptors/progress.md
git commit -m "docs: record router frontend middleware evidence"
```

---

### Task 4: Align Middleware Builder with the Leading-Plus Convention

**Files:**

- Modify: `lib/PAGI/Middleware/Builder.pm`
- Modify: `t/middleware-builder-resolution.t`
- Modify: `t/middleware/00-base.t`
- Modify: `lib/PAGI/Tools/Tutorial.pod`
- Modify: `.superpowers/sdd/2026-08-30-explicit-middleware-descriptors/progress.md`

**Interfaces:**

- Consumes: `enable($name, %config)` and `enable_if($condition, $name, %config)`.
- Produces: short names under `PAGI::Middleware::`, leading `+` exact names, and no public `^` escape.

- [ ] **Step 1: Rewrite naming tests to the Plack convention.**

Require:

```perl
$builder->_resolve_middleware('RequestId')
    eq 'PAGI::Middleware::RequestId';
$builder->_resolve_middleware('Auth::Basic')
    eq 'PAGI::Middleware::Auth::Basic';
$builder->_resolve_middleware('+My::Custom::Middleware')
    eq 'My::Custom::Middleware';
```

Add a rejection assertion for `^My::Custom::Middleware` before any module load
or warning.

- [ ] **Step 2: Run builder tests and confirm RED.**

Run:

```bash
prove -lv t/middleware-builder-resolution.t t/middleware/00-base.t
```

Expected: leading `+` cases fail and current `^` cases still pass.

- [ ] **Step 3: Replace the resolver implementation.**

Validate `$name` as a nonempty scalar class token. Strip one leading `+` for
an exact name; otherwise preserve an already `PAGI::Middleware::`-qualified
name or add the prefix. Remove the current regex that prepends a prefix and
then strips through `^`.

Continue resolving/loading at the same Builder phase. Do not change Builder's
mounting, condition, object-instance, or ordering behavior.

- [ ] **Step 4: Update Builder and Tutorial examples.**

Replace every live:

```perl
enable '^MyApp::Middleware::PoweredBy';
```

with:

```perl
enable '+MyApp::Middleware::PoweredBy';
```

Explain that this is the Plack-familiar exact-package escape used by both
Builder sugar and explicit routing descriptions.

- [ ] **Step 5: Run focused Builder and POD tests.**

Run:

```bash
prove -lv \
  t/middleware-builder-resolution.t \
  t/middleware/00-base.t \
  t/00-pod/cookbook-examples.t
```

Expected: PASS.

- [ ] **Step 6: Commit Task 4, then record its real evidence.**

Commit the Builder naming change and its focused documentation/tests:

```bash
git add lib/PAGI/Middleware/Builder.pm lib/PAGI/Tools/Tutorial.pod \
  t/middleware-builder-resolution.t t/middleware/00-base.t
git commit -m "refactor: use Plack middleware package naming"
```

Run `git rev-parse HEAD`, record the SHA and focused harness totals in Task 4's
row, then make the tracking commit:

```bash
git add -f .superpowers/sdd/2026-08-30-explicit-middleware-descriptors/progress.md
git commit -m "docs: record middleware package naming evidence"
```

---

### Task 5: Migrate Core Examples and Primary Documentation

**Files:**

- Modify: `README.md`
- Modify: `lib/PAGI/Routing.pm`
- Modify: `lib/PAGI/Routing/Middleware.pm` POD
- Modify: `lib/PAGI/Routing/Route.pm` POD
- Modify: `lib/PAGI/Routing/Mount.pm` POD
- Modify: `lib/PAGI/Routing/Router.pm` POD
- Modify: `lib/PAGI/Compose.pm` POD
- Modify: `lib/PAGI/Tools.pm`
- Modify: `lib/PAGI/Tools/Cookbook.pod`
- Modify: `lib/PAGI/Tools/Tutorial.pod`
- Modify: `lib/PAGI/App/Router.pm` POD
- Modify: `lib/PAGI/Endpoint/Router.pm` POD
- Modify: `examples/declarative-routing/app.pl`
- Modify: `examples/10-chat-showcase/app.pl`
- Modify: `examples/10-chat-showcase/README.md`
- Modify: `.superpowers/sdd/2026-08-30-explicit-middleware-descriptors/progress.md`

**Interfaces:**

- Consumes: the strict core list contract and retained higher-level frontend sugar.
- Produces: executable documentation and examples that clearly distinguish explicit core descriptions from frontend convenience.

- [ ] **Step 1: Generate and save the live migration inventory.**

Run:

```bash
rg -n "middleware\s*=>\s*\[|\^.*Middleware|middleware\(" \
  lib t examples README.md UPGRADING.md Changes
```

Classify every match as:

- strict core Route/Mount/Router/Compose list;
- App Router/Endpoint Router intentional sugar;
- Middleware Builder intentional sugar;
- already explicit description; or
- historical test/upgrade text.

Append the classification counts and exact file list to the execution ledger
before editing. The known live example migrations are
`examples/declarative-routing/app.pl`, `examples/10-chat-showcase/app.pl`, and
`examples/10-chat-showcase/README.md`; if the inventory finds another live
core declaration, stop and record it as a scope-map correction before editing.
Do not mechanically wrap higher-level sugar examples that intentionally teach
App Router, Endpoint Router, or Middleware Builder.

- [ ] **Step 2: Migrate every live core declaration.**

For each core bare factory:

```perl
middleware => [\&with_logging]
```

write:

```perl
middleware => [middleware(\&with_logging)]
```

For each core bare object or class string, wrap it with `middleware(...)`.
Add `middleware` to the existing `PAGI::Routing` import list in that package;
do not use fully qualified calls merely to avoid updating imports.

- [ ] **Step 3: Rewrite the primary middleware explanation.**

In `PAGI::Routing` and `PAGI::Routing::Middleware` POD, replace the four-shape
core table with:

```text
middleware($class, %config)   deferred class construction
middleware($factory, %config) synchronous app-to-app factory
middleware($object)           configured object with wrap
```

State that core lists contain descriptions only. Show short, nested,
already-PAGI-qualified, and leading-`+` class names. Explain that factories
and `wrap` may return CODE or a `to_app` object, while their request-time app
returns completion.

- [ ] **Step 4: Document frontend sugar without making it canonical.**

App Router and Endpoint Router POD may show concise arrays, but must say that
the frontend immediately materializes explicit descriptions. Endpoint's
`middleware_as` example remains:

```perl
$r->get('/private' => [
    $self->middleware_as('authenticate'),
] => 'show');
```

Compose, declarative Route, Mount, and Router examples must show only
`middleware(...)` entries.

- [ ] **Step 5: Run example and documentation verification.**

Run the exact integration tests for every changed example, plus:

```bash
prove -lv \
  t/integration-declarative-routing-demo.t \
  t/integration-chat-compose.t \
  t/00-pod/cookbook-examples.t
```

Compile each changed example entrypoint with the repository's Perl:

```bash
perl -Ilib -c examples/declarative-routing/app.pl
perl -Ilib -c examples/10-chat-showcase/app.pl
```

Expected: PASS and `syntax OK`.

- [ ] **Step 6: Perform the live bare-core scan.**

Run the inventory command again. For every remaining bare entry, record why it
belongs to App Router, Endpoint Router, Middleware Builder, a negative test, or
historical upgrade documentation. There must be no unexplained live bare core
entry and no live `^...Middleware` spelling.

- [ ] **Step 7: Commit Task 5, then record its real evidence.**

Commit the exact documentation and example files owned by this task:

```bash
git add README.md \
  lib/PAGI/Routing.pm lib/PAGI/Routing/Middleware.pm \
  lib/PAGI/Routing/Route.pm lib/PAGI/Routing/Mount.pm \
  lib/PAGI/Routing/Router.pm lib/PAGI/Compose.pm lib/PAGI/Tools.pm \
  lib/PAGI/Tools/Cookbook.pod lib/PAGI/Tools/Tutorial.pod \
  lib/PAGI/App/Router.pm lib/PAGI/Endpoint/Router.pm \
  examples/declarative-routing/app.pl \
  examples/10-chat-showcase/app.pl examples/10-chat-showcase/README.md
git commit -m "docs: teach explicit middleware descriptions"
```

Before committing, inspect `git diff --cached --name-only`; it must equal the
owned list above, minus files whose existing text already required no edit.
Run `git rev-parse HEAD`, record the SHA, changed-example list, harness totals,
compile results, and final scan evidence in Task 5's row, then commit the
ledger:

```bash
git add -f .superpowers/sdd/2026-08-30-explicit-middleware-descriptors/progress.md
git commit -m "docs: record middleware documentation evidence"
```

---

### Task 6: Publish the Upgrade Contract and Verify the Candidate

**Files:**

- Modify: `UPGRADING.md`
- Modify: `Changes`
- Modify: `.superpowers/sdd/2026-08-30-explicit-middleware-descriptors/progress.md`

**Interfaces:**

- Consumes: the completed middleware contract from Tasks 1–5.
- Produces: one user-facing migration section and a verified release candidate.

- [ ] **Step 1: Add concrete before/after migration examples.**

Add one `UPGRADING.md` section containing all of these transformations:

```perl
# Before: declarative core shorthand
middleware => ['RequestId', \&audit, $object]

# After: explicit core descriptions
middleware => [
    middleware('RequestId'),
    middleware(\&audit),
    middleware($object),
]
```

```perl
# Before: exact package
middleware('^MyApp::Middleware::Auth')

# After: Plack-familiar exact package
middleware('+MyApp::Middleware::Auth')
```

```perl
# Configured factory
middleware(\&audit_factory, label => 'items')

sub audit_factory {
    my ($inner, %config) = @_;
    return MyApp::AuditBoundary->new(
        inner => $inner,
        label => $config{label},
    );
}
```

State explicitly that App Router, Endpoint Router, and Middleware Builder may
retain concise forms because they are higher-level frontends.

- [ ] **Step 2: Consolidate the Changes entry.**

Under `0.002003 - UNRELEASED`, add one BREAKING bullet covering:

- explicit-only core middleware lists;
- `middleware(...)` as the construction description;
- short and leading-`+` package resolution;
- configured coderef factories;
- application-valued wrapper results; and
- preserved higher-level sugar and runtime behavior.

Do not split this one contract into several repetitive bullets.

- [ ] **Step 3: Run focused regression groups.**

Run:

```bash
prove -lr \
  t/routing \
  t/compose \
  t/app-router \
  t/endpoint \
  t/router-middleware.t \
  t/endpoint-router.t \
  t/middleware-builder-resolution.t \
  t/upgrading-router-frontends.t
```

Expected: PASS. Record the real file/test totals from the harness.

- [ ] **Step 4: Run the repository-wide suite once.**

Run:

```bash
prove -lr t
```

Expected: PASS. If a failure is caused by an unexplained bare core middleware
entry, fix the declaration and its owning documentation/test rather than
adding compatibility coercion. If a failure is unrelated, document the exact
pre-existing reason before deciding whether it blocks this candidate.

- [ ] **Step 5: Run distribution and hygiene checks.**

Run:

```bash
dzil test
git diff --check
git status --short
rg -n "\^.*Middleware" lib t examples README.md UPGRADING.md Changes
```

Expected: `dzil test` passes, diff check is empty, status contains only owned
changes plus the user's pre-existing untracked `.pagi-*` and `.superpowers/`
artifacts, and every remaining caret match is an intentional negative or
historical migration example.

- [ ] **Step 6: Review scope against the work map.**

Inspect:

```bash
git diff --stat 045eae3fc973e0bbca67aa804d834f588ec5087c
git diff --name-only 045eae3fc973e0bbca67aa804d834f588ec5087c
```

Confirm every file belongs to middleware contract code, tests, examples,
documentation, or the execution ledger. Record any approved `DEV-NN` entries
and confirm none remain unresolved.

- [ ] **Step 7: Commit the upgrade contract, then record final evidence.**

Commit the user-facing release documentation first:

```bash
git add UPGRADING.md Changes
git commit -m "docs: publish explicit middleware upgrade path"
```

Run `git rev-parse HEAD`. Mark all ledger rows complete with the real
implementation SHAs, focused and full-suite totals, distribution verification,
scope review, and any approved deviations. Then make the final tracking commit:

```bash
git add -f .superpowers/sdd/2026-08-30-explicit-middleware-descriptors/progress.md
git commit -m "docs: record explicit middleware verification"
```

- [ ] **Step 8: Request final code review before publishing.**

Use `superpowers:requesting-code-review` against the complete branch diff.
Require the reviewer to check the spec, core-vs-frontend boundary, package
resolution, app-valued wrapper normalization, all four core placements,
examples, upgrade guide, and test evidence. Address findings through the
receiving-code-review workflow and rerun only the affected focused suites plus
the final full suite if production code changes.
