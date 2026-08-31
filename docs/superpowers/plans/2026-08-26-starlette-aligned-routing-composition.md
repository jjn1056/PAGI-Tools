# Starlette-Aligned Routing and Composition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace PAGI-Tools' three-mode Mount, structural groups, trace-based routing declines, and Compose-owned routing fallbacks with one Starlette-aligned model in which Route matches leaves, Mount composes applications, Router owns routing outcomes, middleware wraps behavior, and Compose owns the application root.

**Architecture:** All native application positions share one coderef-or-instantiated-`to_app` contract. An immutable Mount stores one base application; `routes` eagerly constructs a real child Router, and the compiler always delegates through a compiled child application after a prefix match. The Resolver may inspect mounted first-party Router descriptions for reverse routing, but inspection never changes dispatch ownership. Routers render HTTP NONE through `http_default`, render PARTIAL as a stock negotiated 405, retain protocol-specific misses and the HEAD boundary, while Compose retains only lifespan and root safety layers.

**Tech Stack:** Perl 5.18-compatible distribution code; Perl 5.40 signatures only in already-modern examples; `Future`, `Future::AsyncAwait`, `PAGI::Context`, `PAGI::Pages`, `PAGI::Response`, `PAGI::Routing::HeadBoundary`, `Test2::V0`, `PAGI::Test::Client`, POD, and Dist::Zilla. No new dependency.

**Spec:** `docs/superpowers/specs/2026-08-26-starlette-aligned-routing-composition-design.md`

## Global Constraints

- The approved contract is the specification above at commit `179301629b066da1c3009e82a4e7ea91b05cd9b2`. If implementation evidence conflicts with it, record a deviation and obtain the user's decision before dependent work continues.
- Backward compatibility is not required. Do not retain aliases, ignored options, warnings-only migrations, dual Mount modes, or hidden compatibility branches for `group`, positional Mount targets, `router =>`, `is_raw`, Trace, or routing fallback middleware.
- Work only in `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` or an isolated worktree created for this repository through the Superpowers worktree workflow.
- Preserve the unrelated untracked files `.pagi-0.4-alignment-tools-review.md`, `.pagi-0.4-alignment-tools-rulings.md`, and pre-existing state under `.superpowers/`. Never stage them.
- Keep every file under `lib/` and every ordinary test parseable on Perl 5.18. Use classic `@_` unpacking and avoid signatures, postfix dereferencing, `try`/`catch`, and newer syntax there. Existing Perl 5.40 examples may use signatures.
- Use the installed Perl 5.16.3 for syntax-only compatibility gates. Passing that stricter parser is evidence for the declared Perl 5.18 floor; functional tests still run under the project Perl 5.42.2.
- Every native application position accepts only a coderef or an instantiated object with `to_app`; package strings are rejected without loading them. The object's `to_app` is called once per enclosing compilation and must return a coderef.
- Handler positions remain coderef-only. `PAGI::Pages` works there because its factory returns a dual-invocation coderef; this does not make arbitrary native apps valid Context handlers.
- Mount has exactly one runtime meaning. The compiler may recognize a first-party `PAGI::Routing::Router` to preserve root Resolver metadata, but both recognized and opaque children are compiled once and called as applications; the parent never matches inside the child or resumes after it.
- Functional `mount(routes => ...)` accepts only an arrayref and constructs a real child Router. Builder callbacks exist only in `PAGI::App::Router` and `PAGI::Endpoint::Router`.
- `http_default` receives HTTP NONE only. It never receives WebSocket or SSE scopes, never catches exceptions, and never renders PARTIAL. Omitted `http_default` uses stock negotiated `PAGI::Pages` 404 behavior.
- Router-generated 405 responses use the deterministic first-seen `Allow` union. An outer Router-boundary send wrapper reasserts exactly one authoritative `Allow` header after Router, Mount, and child middleware; arbitrary Compose middleware that deliberately transforms a 405 remains responsible for preserving it.
- Use `Future->wrap($returned)` wherever a handler, native app, middleware-produced app, or response send may complete immediately or through a Future. Never directly `await` a possibly immediate value.
- Mount exact-prefix normalization maps an empty remainder to `/`; it emits no redirect. A root Mount consumes nothing. Preserve `raw_path` under the existing PAGI contract.
- Path-parameter merges are disjoint. Inspectable collisions fail during Router construction; a hidden nested PAGI Router fails before invoking its selected leaf; an arbitrary opaque app owns later interpretation.
- Routing metadata is request-local. No Router, Mount, Resolver, middleware instance, or compiled app may retain mutable request placement, captures, match state, or `Allow` state across requests.
- The first middleware entry remains outermost. Route middleware surrounds only a selected leaf; Router middleware also surrounds its 404, 405, and protocol misses; Mount middleware surrounds all protocols delegated through that occurrence.
- Direct Router compilation retains the HEAD wire boundary, but does not install lifespan, ErrorHandler, or ResponseGuard. Compose remains the root owner of those safety and lifecycle layers.
- Put public POD beside every changed public constructor, accessor, declaration form, outcome, and boundary in the task that changes it. The documentation task reconciles README, Tutorial, Cookbook, examples, `UPGRADING.md`, and Changes.
- Use TDD for each task: add the smallest focused failing assertion, run it and record the expected semantic failure, implement the minimal contract, rerun the focused files, then run the named task gate.
- Use `PAGI::Test::Client` for complete HTTP requests. Use direct scope/receive/send recorders for WebSocket, SSE, exact event ownership, metadata identity, middleware order, malformed invocation, or post-start behavior.
- Stage only files named by the current task. Never use `git add .` or `git add -A`. `docs/superpowers` is ignored; use `git add -f` only for this exact plan path.
- Every implementation task ends with one focused commit and an independent review gate. The coordinator verifies the diff, test output, commit SHA, and ledger row before starting dependent work.
- Run the repository-wide `prove -lr t` suite exactly once at the final reviewed HEAD. Focused tests may run as often as TDD requires. Do not run `dzil test`, because it repeats the suite. If the final suite exposes a defect and HEAD changes, record the failure and fix, then run one new final suite at the corrected HEAD.
- Run Perl commands through the project Perl, for example:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/07-mounts.t'
  ```

## Work Map

Record and reconfirm this map before implementation, whenever scope changes, and before any authorized push:

| Repository | Ticket | Execution branch | Base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | Starlette-aligned routing composition | isolated feature branch/worktree created by the selected execution skill | `design/starlette-aligned-routing-composition@179301629b066da1c3009e82a4e7ea91b05cd9b2` | Exact `lib/`, `t/`, examples, POD, README, Tutorial, Cookbook, `UPGRADING.md`, Changes, and distribution cleanup named below | Unreleased PAGI-Tools `0.002003`; no deployment or CPAN release in this plan | None unless the user separately authorizes publication |

## Execution Tracking and Deviation Control

Before Task 1, create the isolated execution workspace using the selected execution skill. For subagent-driven development, run:

```bash
/Users/jnapiorkowski/.codex/plugins/cache/openai-curated-remote/superpowers/6.3.0/skills/subagent-driven-development/scripts/sdd-workspace docs/superpowers/plans/2026-08-26-starlette-aligned-routing-composition.md
```

The command must print a directory ending in `.superpowers/sdd/2026-08-26-starlette-aligned-routing-composition`. Create `progress.md` there with this exact initial structure:

```markdown
# SDD ledger — plan: docs/superpowers/plans/2026-08-26-starlette-aligned-routing-composition.md

Starting HEAD: 179301629b066da1c3009e82a4e7ea91b05cd9b2

| Task | Status | Commit range | Focused verification | Full-suite verification | Review |
|---|---|---|---|---|---|
| 1 | pending | — | — | deferred to Task 12 | — |
| 2 | pending | — | — | deferred to Task 12 | — |
| 3 | pending | — | — | deferred to Task 12 | — |
| 4 | pending | — | — | deferred to Task 12 | — |
| 5 | pending | — | — | deferred to Task 12 | — |
| 6 | pending | — | — | deferred to Task 12 | — |
| 7 | pending | — | — | deferred to Task 12 | — |
| 8 | pending | — | — | deferred to Task 12 | — |
| 9 | pending | — | — | deferred to Task 12 | — |
| 10 | pending | — | — | deferred to Task 12 | — |
| 11 | pending | — | — | deferred to Task 12 | — |
| 12 | pending | — | — | final gate | — |

## Deviations

| ID | Status | Conflicting plan text | Evidence and rationale | Affected tasks | User decision |
|---|---|---|---|---|---|
```

Also write the exact 40-character starting SHA plus one newline to `.superpowers/sdd/2026-08-26-starlette-aligned-routing-composition/starting-head`. Record `git status --short`, including every preserved untracked artifact. The coordinator owns the ledger and updates a row in the same working step as its commit/review with exact commands, exit status, actual file/assertion counts, elapsed time, commit SHA, and review evidence.

A contract conflict gets the next stable ID (`DEV-001`, `DEV-002`, then sequentially), status `awaiting decision`, the exact conflicting text, concrete evidence, and every blocked task. Record the user's explicit decision before dependent work continues. An ordinary defect whose fix preserves the approved contract is not a deviation.

## File and Responsibility Map

- `lib/PAGI/Utils.pm`: one private application-shape validator and the public application coercer; no package-name loading in app positions.
- `lib/PAGI/Routing/Route.pm`: immutable exact-leaf description and raw-app shape validation.
- `lib/PAGI/Routing/Mount.pm`: immutable prefix plus one original base app; `routes` constructs a child Router and is not a runtime mode.
- `lib/PAGI/Routing/Router.pm`: ordered child collection, optional declared `http_default`, Resolver, inspection, and fresh compilation boundary.
- `lib/PAGI/Routing/Resolver.pm`: construction-time first-party Router walk, canonical names, cycle/collision validation, and placement metadata.
- `lib/PAGI/Routing/Compiler.pm`: leaf adaptation, Mount delegation, scope rewrite, Router-owned outcomes, metadata, middleware order, protocol misses, and direct HEAD boundary.
- `lib/PAGI/Compose.pm` and `lib/PAGI/Compose/Compiler.pm`: root description, lifespan, author middleware, ErrorHandler, ResponseGuard, and final HEAD boundary only.
- `lib/PAGI/App/Router/Builder.pm` and `Materializer.pm`: mutable declarations that snapshot to the immutable model; no independent matcher.
- `lib/PAGI/Endpoint/Router.pm` and `Builder.pm`: method-binding facade over the same App Router declarations.
- `lib/PAGI/Routing/Trace*.pm` and `lib/PAGI/Middleware/Routing/*.pm`: removed after their consumers and replacement tests are gone.
- Routing, Compose, frontend, Context, integration, and upgrade tests: behavior-first coverage of each boundary without retaining obsolete trace assertions.
- `examples/starlette-apples`, `examples/15-large-application`, `examples/declarative-routing`, `examples/endpoint-router-demo`, static-file examples, and Pages examples: canonical public shapes exercised by integration tests.
- Public POD, `README.md`, `lib/PAGI/Tools/Tutorial.pod`, `lib/PAGI/Tools/Cookbook.pod`, `UPGRADING.md`, and Changes: one coherent model, deliberate Starlette differences, and complete breaking migration.

---

### Task 1: Enforce One Native Application Contract

**Files:**

- Modify: `lib/PAGI/Utils.pm`
- Modify: `lib/PAGI/Routing/Route.pm`
- Modify: `lib/PAGI/Compose.pm`
- Modify: `t/utils-to-app.t`
- Modify: `t/routing/01-constructors.t`
- Modify: `t/compose/01-description.t`

**Interfaces:**

- Produces private `PAGI::Utils::_validate_app_value($value, $label) -> $value`, accepting only a coderef or blessed object with `to_app` and issuing label-specific construction errors.
- Changes public `PAGI::Utils::to_app($value) -> CODE` to reject all package strings without loading them, call an object's `to_app` once, and reject a non-coderef result.
- `route(..., raw => $value)` validates the same shape at description construction and retains the original value until compilation.
- `compose(app => $value)` delegates shape validation to the shared utility; middleware class strings remain unchanged.

- [ ] **Step 1: Replace class-loading tests with the exact accepted/rejected matrix.** In `t/utils-to-app.t`, use local classes with `to_app`, `wrap`, and a broken `to_app`, then assert:

  ```perl
  is(to_app($native), $native, 'a native coderef is already an app');
  is(to_app(Local::App->new), $compiled, 'an instantiated component compiles');
  like(dies { to_app('Local::App') }, qr/instantiated object.*to_app/i,
      'a package name is never loaded as an app');
  like(dies { to_app(Local::BrokenApp->new) }, qr/to_app.*coderef/i,
      'an object must compile to a native coderef');
  like(dies { to_app(Local::Middleware->new) }, qr/middleware.*not an app/i,
      'middleware-object guidance remains specific');
  ```

- [ ] **Step 2: Add constructor-level failures.** In the Routing and Compose constructor tests, assert that raw/app package strings, unblessed references, objects without `to_app`, and undefined values fail synchronously, while instantiated app objects are stored by identity and not compiled at construction. Also assert that `'RequestId'` remains accepted in middleware arrays.

- [ ] **Step 3: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/utils-to-app.t t/routing/01-constructors.t t/compose/01-description.t'
  ```

  Expected: failures show package strings still being loaded/accepted, Compose's local validator accepting class strings, and Route raw targets lacking shared shape validation.

- [ ] **Step 4: Implement the shared validator and strict coercer.** Use this contract in `PAGI::Utils`:

  ```perl
  sub _validate_app_value {
      my ($value, $label) = @_;
      $label = 'application' unless defined $label && length $label;
      croak "$label must be a coderef or instantiated object with to_app"
          unless defined $value
              && (ref($value) eq 'CODE'
                  || (blessed($value) && $value->can('to_app')));
      return $value;
  }

  sub to_app {
      my ($value) = @_;
      _validate_app_value($value, 'to_app() application');
      return $value if ref($value) eq 'CODE';
      my $app = $value->to_app;
      croak ref($value) . '->to_app must return a coderef'
          unless ref($app) eq 'CODE';
      return $app;
  }
  ```

  Preserve the middleware-specific diagnostic before the generic object failure by checking a blessed `wrap`-only object in `_validate_app_value`. Call this validator from Route raw construction and Compose construction; do not call `to_app` until compilation.

- [ ] **Step 5: Update focused POD.** In `PAGI::Utils`, Route, and Compose POD, replace class-name app examples with instantiated objects, state that app positions never load packages, and contrast this with middleware's explicit class-loading contract.

- [ ] **Step 6: Run the GREEN gate and compatibility syntax checks.** Run the Step 3 command, then:

  ```bash
  perlbrew exec --with perl-5.16.3 perl -Ilib -c lib/PAGI/Utils.pm
  perlbrew exec --with perl-5.16.3 perl -Ilib -c lib/PAGI/Routing/Route.pm
  perlbrew exec --with perl-5.16.3 perl -Ilib -c lib/PAGI/Compose.pm
  git diff --check
  ```

  Expected: focused tests pass; all three modules report `syntax OK`; diff check is silent.

- [ ] **Step 7: Commit and update the ledger.** Stage exactly the six task files and commit:

  ```bash
  git add lib/PAGI/Utils.pm lib/PAGI/Routing/Route.pm lib/PAGI/Compose.pm t/utils-to-app.t t/routing/01-constructors.t t/compose/01-description.t
  git commit -m "refactor: unify native application values"
  ```

### Task 2: Reduce Mount and Router to the Immutable Core Model

**Files:**

- Modify: `lib/PAGI/Routing/Mount.pm`
- Modify: `lib/PAGI/Routing/Router.pm`
- Modify: `lib/PAGI/Routing.pm`
- Modify: `t/routing/01-constructors.t`
- Modify: `t/routing/03-reverse-inspection.t`
- Modify: `t/routing/11-bare-middleware.t`
- Modify: `t/pages/03-invocation-composition.t`

**Interfaces:**

- `PAGI::Routing::Mount->_new_from($package, $path, app => $value, %opts)` or `routes => \@nodes` accepts exactly one target form.
- `routes` constructs `PAGI::Routing::Router->new(routes => $nodes)` during Mount construction and stores that Router in `app`; the public `app` accessor always returns the original base application.
- Removes public Mount `target`, `router`, `is_raw`, and `routes` accessors and all positional parsing.
- `PAGI::Routing::Router->new(..., http_default => $app)` validates but does not compile the optional declared HTTP app; `http_default` returns that declaration or `undef` when omitted.

- [ ] **Step 1: Rewrite constructor tests around the exact option sets.** Add table-driven failures for positional Mount targets, `router =>`, both/neither `app` and `routes`, non-array functional `routes`, Router objects inside structural routes, Mount methods/schema/lifespan/fallback keys, and Router `default`, `not_found`, and `method_not_allowed`. Assert this accepted shape:

  ```perl
  my $child = router(routes => [route('/' => sub { $_[0]->text('ok') })]);
  my $mounted = mount('/api', app => $child, name => 'api');
  is($mounted->app, $child, 'Mount retains its exact base app');

  my $short = mount('/api', routes => [
      route('/' => sub { $_[0]->text('ok') }, name => 'index'),
  ]);
  isa_ok($short->app, ['PAGI::Routing::Router']);
  ok(!$short->can('target') && !$short->can('router')
      && !$short->can('is_raw') && !$short->can('routes'),
      'removed Mount modes have no compatibility accessors');
  ```

- [ ] **Step 2: Add Router HTTP-default construction assertions.** Prove omitted `http_default` returns `undef`, a coderef and instantiated object retain identity without compilation, invalid shapes use the Task 1 validator, and route order/defensive accessor copies remain unchanged.

- [ ] **Step 3: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/01-constructors.t t/routing/03-reverse-inspection.t'
  ```

  Expected: old positional/router forms still work, new `app` and `http_default` are unknown, and shorthand Mount does not expose one base app.

- [ ] **Step 4: Implement one Mount representation.** Remove parity parsing and mode flags. Validate options with:

  ```perl
  my %allowed = map { $_ => 1 }
      qw(app routes name desc constraints middleware);
  my $has_app = exists $opts{app};
  my $has_routes = exists $opts{routes};
  croak 'mount requires exactly one of app or routes'
      unless $has_app != $has_routes;
  my $app = $has_app
      ? PAGI::Utils::_validate_app_value($opts{app}, 'mount app')
      : PAGI::Routing::Router->new(routes => $opts{routes});
  ```

  Store `app => $app`; retain Pattern, name, desc, constraints, and normalized middleware. Keep `_validate_routes` as the shared structural-node validator and change its Router diagnostic to recommend `app => $router`.
  Load `PAGI::Routing::Router` with a branch-local `require` only when
  constructing the `routes` shorthand; do not add a compile-time
  Mount↔Router dependency cycle.

- [ ] **Step 5: Add Router `http_default`.** Extend the allowed keys, validate a supplied value through `PAGI::Utils::_validate_app_value`, store it without compiling, and add the accessor. Do not instantiate the stock Pages default in the description; Task 5 supplies it at compilation when the accessor is `undef`.

- [ ] **Step 6: Rewrite Routing/Mount/Router POD.** Lead with the exact Route/Mount/Router responsibility rule, document only `app` XOR `routes`, show named and unnamed Mounts, and explain that `routes` is shorthand for a real child Router application.

- [ ] **Step 7: Run the GREEN gate, POD, and compatibility checks.** Run the Step 3 command plus `t/routing/11-bare-middleware.t` and `t/pages/03-invocation-composition.t`, run `podchecker` for the three modules, compile the three modules under Perl 5.16.3, and run `git diff --check`.

- [ ] **Step 8: Commit and update the ledger.** Stage exactly the seven task files and commit:

  ```bash
  git add lib/PAGI/Routing/Mount.pm lib/PAGI/Routing/Router.pm lib/PAGI/Routing.pm t/routing/01-constructors.t t/routing/03-reverse-inspection.t t/routing/11-bare-middleware.t t/pages/03-invocation-composition.t
  git commit -m "refactor: give Mount one composition model"
  ```

### Task 3: Rebuild Reverse Inspection Around Mounted Base Routers

**Files:**

- Modify: `lib/PAGI/Routing/Resolver.pm`
- Modify: `t/routing/03-reverse-inspection.t`
- Modify: `t/context/12-routing-reverse.t`

**Interfaces:**

- Resolver recursively inspects `$mount->app` only when it is blessed and `isa('PAGI::Routing::Router')`; it never calls an arbitrary app's `routes`, `path_for`, or `to_app`.
- Named Mounts prepend one logical segment; unnamed Mounts retain the current namespace. An opaque named Mount declares no reverse target by itself.
- Active-ancestry Router identity detects cycles; the same Router object remains legal in completed sibling branches.
- Resolver metadata locations cover the root Router and each inspectable child Router without flattening runtime dispatch.

- [ ] **Step 1: Add mounted-base-app discovery tests.** Replace `router =>` fixtures with `app =>` and assert named and unnamed paths, exact original leaf identities, query/fragment rendering, and one child at two placements:

  ```perl
  is($root->path_for('/left/show', { id => 7 }), '/left/7');
  is($root->path_for('/right/show', { id => 8 }), '/right/8');
  is($unnamed->path_for('/show', { id => 9 }), '/people/9');
  like(dies { $opaque_named->path_for('/legacy') },
      qr/logical namespace|unknown route/, 'a Mount name is not an opaque target');
  ```

- [ ] **Step 2: Add adversarial inspection tests.** Create an object whose `routes` method dies and verify Router construction never calls it. Add duplicate canonical names, duplicate effective params across Mount/leaf, legal sibling reuse, and a test-only Router subclass whose `routes` returns `[mount('/loop', app => $self)]`; assert a cycle diagnostic names the effective path and namespace.

- [ ] **Step 3: Add Context reverse expectations for child boundaries.** Convert old inline/router fixtures to mounted Router apps and retain absolute/relative lookup, capture inheritance, query, fragment, reused-placement, opaque-boundary, and unknown-name assertions.

- [ ] **Step 4: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/03-reverse-inspection.t t/context/12-routing-reverse.t'
  ```

  Expected: Resolver still calls removed Mount accessors and cannot discover `app => $router` children.

- [ ] **Step 5: Rewrite the traversal branch.** At each Mount, extend prefix captures and placement metadata first, then use this exact inspection gate:

  ```perl
  my $child = $node->app;
  my $inspectable = blessed($child)
      && $child->isa('PAGI::Routing::Router');
  next unless $inspectable;
  $self->_walk_router($child, $effective_path, $address_segments,
      $effective_parameters, \@location, $active_ancestry);
  ```

  Use `refaddr` only in an active-recursion hash. Delete it on unwind so sibling reuse succeeds. Preserve normalized predicate records rather than reparsing constraints.

- [ ] **Step 6: Align metadata records.** Remove `is_raw` from records. Keep placement `mount => { path, name, desc }`, effective match `{ kind, route, name, logical_namespace, desc }`, source node, predicates, and location. An opaque Mount gets placement metadata but no descendant location records.

- [ ] **Step 7: Run the GREEN gate and static checks.** Run the Step 4 command, compile Resolver under Perl 5.16.3, run `podchecker lib/PAGI/Routing/Resolver.pm`, and `git diff --check`.

- [ ] **Step 8: Commit and update the ledger.** Stage exactly the three task files and commit:

  ```bash
  git add lib/PAGI/Routing/Resolver.pm t/routing/03-reverse-inspection.t t/context/12-routing-reverse.t
  git commit -m "refactor: inspect mounted Router applications"
  ```

### Task 4: Compile Mounts as Real Child Applications

**Files:**

- Modify: `lib/PAGI/Routing/Compiler.pm`
- Modify: `t/routing/07-mounts.t`
- Modify: `t/routing/08-protocols.t`
- Modify: `t/routing/12-router-mounts.t`
- Modify: `t/integration-router-application-boundaries.t`

**Interfaces:**

- Compiler creates one mounted app per Mount occurrence during `to_app`, then wraps that app once in Mount middleware.
- A first-party Router base app compiles as a child Router application with root Resolver/location context; an opaque coderef/object uses `PAGI::Utils::to_app`. Both are called once after prefix selection and own completion.
- `_merge_path_params($incoming, $captures, $effective_path)` returns a fresh disjoint hash or croaks before the selected leaf/app runs.
- `_mount_scope` rewrites exact consumed remainder `''` to `/`, preserves `raw_path`, and leaves root Mount path/root_path unchanged.

- [ ] **Step 1: Rewrite Mount dispatch tests for one mode.** Cover coderef, instantiated object, explicit Router app, and `routes` shorthand. Assert each object `to_app` and each middleware factory runs once per compilation, never per request; two placements get independent middleware instances; and child silence never resumes a later parent sibling.

- [ ] **Step 2: Pin exact-prefix and root behavior.** Use a child `route('/')` and assert both `/apples` and `/apples/` reach it with child `path => '/'`; no redirect event occurs. Assert a root Mount receives unchanged `path`, `root_path`, and `raw_path`.

- [ ] **Step 3: Pin scope merge behavior.** Assert parent captures reach opaque apps, fresh hashes prevent parent mutation, distinct parent/child captures combine, and duplicate `path_params` fail before a hidden nested Router's handler increments its call count.

- [ ] **Step 4: Pin protocol ownership and middleware order.** For HTTP, WebSocket, and SSE, prove the first prefix Mount wins in declaration order, Mount middleware sees all three scopes, and child protocol misses return the existing WebSocket close/denial and SSE 404 behavior without parent resumption.

- [ ] **Step 5: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/07-mounts.t t/routing/08-protocols.t t/routing/12-router-mounts.t t/integration-router-application-boundaries.t'
  ```

  Expected: Compiler calls removed mode accessors, exact-prefix children see an empty path, and hidden duplicate params overwrite silently.

- [ ] **Step 6: Replace the three Mount compile branches with one child-app builder.** Use one helper whose only type-specific work is first-party Resolver placement:

  ```perl
  sub _compile_mounted_app {
      my ($class, $mount, $root_resolver, $location) = @_;
      my $base = $mount->app;
      my $app = blessed($base) && $base->isa('PAGI::Routing::Router')
          ? $class->_compile_router_body($base, $root_resolver, $location, 1)
          : PAGI::Utils::to_app($base);
      my $awaiting = async sub {
          my ($scope, $receive, $send) = @_;
          await Future->wrap($app->($scope, $receive, $send));
          return;
      };
      return PAGI::Routing::Middleware->_wrap_descriptors(
          $mount->middleware, $awaiting,
      );
  }
  ```

  The fourth flag means “enter a child Router metadata boundary,” not “inline matching.” Parent selection still invokes the returned app exactly like an opaque app and never sees the child's decision.

- [ ] **Step 7: Add disjoint scope helpers.** Before merging, reject every key present in both incoming `path_params` and captures with `duplicate path parameter '$name' while entering '$path'`. Normalize `remainder eq '' ? '/' : $remainder`; only append a nonempty consumed prefix; preserve `raw_path` exactly.

- [ ] **Step 8: Run the GREEN gate and static checks.** Run the Step 5 command, compile Compiler under Perl 5.16.3, run its POD checker, and `git diff --check`.

- [ ] **Step 9: Commit and update the ledger.** Stage exactly the five task files and commit:

  ```bash
  git add lib/PAGI/Routing/Compiler.pm t/routing/07-mounts.t t/routing/08-protocols.t t/routing/12-router-mounts.t t/integration-router-application-boundaries.t
  git commit -m "refactor: compile Mounts as child applications"
  ```

### Task 5: Make Router Own HTTP Outcomes and Selected Metadata

**Files:**

- Modify: `lib/PAGI/Routing/Compiler.pm`
- Modify: `t/routing/05-http-dispatch.t`
- Modify: `t/routing/06-head.t`
- Modify: `t/routing/09-metadata-isolation.t`
- Modify: `t/routing/10-head-boundary.t`
- Modify: `t/routing/12-router-mounts.t`
- Delete: `t/routing/16-http-declines.t`
- Create: `t/routing/16-http-outcomes.t`

**Interfaces:**

- HTTP `_select_http` remains declaration-ordered and returns `full`, `partial` with first-seen `allowed_methods`, or `none` without Trace arguments.
- A Router body invokes its compiled declared/default HTTP app on NONE and emits `PAGI::Pages->method_not_allowed(... allow => \@methods)` on PARTIAL.
- The root Router compilation installs one request-local authoritative-Allow state outside all Router/Mount/child middleware and one final HEAD boundary.
- First-party child Router entry appends a request-local `pagi.routing` frame using the root Resolver and inherited placement snapshot; no app object is mutated.

- [ ] **Step 1: Replace decline assertions with response assertions.** Create `16-http-outcomes.t` and remove `16-http-declines.t`. Test that NONE is negotiated 404, PARTIAL is negotiated 405, allowed methods are unioned in first-seen order, a later FULL route wins, a Mount FULL transfers ownership, and endpoint-produced 404/405 passes unchanged.

- [ ] **Step 2: Add custom HTTP-default tests.** Use a recording native app and prove it sees HTTP NONE only, receives the original request channels and current Router scope, runs inside Router and Mount middleware, does not run for PARTIAL, selected exceptions, handler-returned 404, WebSocket NONE, or SSE NONE, and is compiled once per Router occurrence.

- [ ] **Step 3: Add authoritative-Allow middleware tests.** Install child, Mount, and Router middleware that delete/duplicate/change `Allow` on a Router-generated 405. Assert the final event has one exact `Allow: GET, HEAD, POST` in first-seen order. Also assert an endpoint-generated 405 is not rewritten by the Router authority.

- [ ] **Step 4: Add nested ownership tests.** For the specification's child GET and later parent PUT example, assert `PUT /api/item` is the child's 405 with only `GET, HEAD`, `/api/missing` is the child's HTTP default, and no later parent handler runs.

- [ ] **Step 5: Rewrite selected metadata assertions.** Require root Resolver identity, cumulative Mount chain, effective pattern/name/description, child Router boundary frames, capture snapshots, and outer middleware visibility after downstream. Run two in-flight requests paused on separate Futures and assert distinct container/frame/capture/mount/Allow-state identities and correct final metadata after opposite-order completion.

- [ ] **Step 6: Pin HEAD ownership.** Assert direct Router GET and generated 404/405 HEAD responses preserve GET-equivalent headers while suppressing body, sendfile, and trailer events; explicit HEAD before GET wins; an expensive GET handler is not called for that explicit HEAD route; and Router middleware computes body-derived headers before suppression.

- [ ] **Step 7: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/05-http-dispatch.t t/routing/06-head.t t/routing/09-metadata-isolation.t t/routing/10-head-boundary.t t/routing/12-router-mounts.t t/routing/16-http-outcomes.t'
  ```

  Expected: NONE/PARTIAL still complete silently through Trace; child metadata has old inline semantics; no Router-owned authoritative Allow exists.

- [ ] **Step 8: Remove Trace from selection and compile Router outcomes.** Delete recorder/frame/attempt/parent-link arguments and helpers. Compile each Router's default once:

  ```perl
  my $http_default = defined $router->http_default
      ? PAGI::Utils::to_app($router->http_default)
      : PAGI::Utils::to_app(PAGI::Pages->not_found);
  ```

  On PARTIAL, create/send `PAGI::Pages->method_not_allowed($scope, allow => $methods)` through the Context/Response path; on NONE, await the native default app. Keep WebSocket/SSE stock misses independent.

  The PARTIAL send path is exactly:

  ```perl
  my $response = PAGI::Pages->method_not_allowed(
      $scope, allow => $decision->{allowed_methods},
  );
  await Future->wrap($response->respond($send));
  ```

- [ ] **Step 9: Implement request-local Allow authority.** At public Router entry, shallow-clone the scope with a private token/state pair. The dispatcher sets the expected union before it emits its own 405. A send wrapper outside Router middleware removes every case-insensitive `Allow` pair and appends one normalized authoritative pair only when that private state marks a Router-generated outgoing 405. Child Router bodies reuse the same state so the outer Router boundary repairs changes made by child and Mount middleware. Never store this state in the compiled object.

- [ ] **Step 10: Narrow `pagi.routing` metadata.** Root entry creates one compatible v1 container/frame. Entering an inspectable child Router app appends a new frame that copies the root Resolver, root entry `root_path`, logical namespace, captures, and Mount chain from the selected parent frame, then receives the child leaf/default/405 updates. Opaque apps keep their own metadata behavior. Remove every trace field and candidate attempt.

- [ ] **Step 11: Run the GREEN gate and static checks.** Run the Step 7 command; compile Compiler under Perl 5.16.3; run `podchecker`; run `git diff --check`.

- [ ] **Step 12: Commit and update the ledger.** Stage exactly the eight task paths and commit:

  ```bash
  git add lib/PAGI/Routing/Compiler.pm t/routing/05-http-dispatch.t t/routing/06-head.t t/routing/09-metadata-isolation.t t/routing/10-head-boundary.t t/routing/12-router-mounts.t t/routing/16-http-declines.t t/routing/16-http-outcomes.t
  git commit -m "feat: make Router own HTTP outcomes"
  ```

### Task 6: Return Compose to Root Lifecycle and Safety

**Files:**

- Modify: `lib/PAGI/Compose/Compiler.pm`
- Modify: `lib/PAGI/Compose.pm`
- Modify: `t/compose/02-dispatch.t`
- Modify: `t/compose/03-lifespan.t`
- Modify: `t/compose/04-middleware.t`
- Modify: `t/compose/05-head-concurrency.t`
- Modify: `t/compose/06-failsafes.t`
- Modify: `t/compose/07-response-guard.t`

**Interfaces:**

- For HTTP, Compose compilation order is final HeadBoundary → ErrorHandler → ResponseGuard → author middleware → target dispatcher; lifespan and non-HTTP handling retain their existing protocol-specific safety boundaries.
- Compose installs no Trace and no automatic routing NotFound/MethodNotAllowed middleware.
- `compose(routes => \@nodes)` constructs an ordinary Router whose own defaults produce 404/405.
- Selected app silence, exception behavior, post-start behavior, and lifespan remain Compose responsibilities.

- [ ] **Step 1: Replace fallback-layer construction tests.** Remove monkey-patches for Trace and routing fallback wrappers. Instrument HeadBoundary, ErrorHandler, ResponseGuard, author middleware, target, and lifespan callbacks; assert compile-once and first-listed-outermost ordering without any routing layer.

- [ ] **Step 2: Pin root outcomes.** Through `PAGI::Test::Client`, assert `compose(routes => [])` receives Router's negotiated 404, method mismatches receive Router 405/Allow, `compose(app => $silent)` becomes safe 500, thrown/failed-Future targets become safe 500, and a response-started exception is reported/rethrown according to the shipped ErrorHandler contract.

- [ ] **Step 3: Pin lifespan isolation.** Assert root startup/shutdown still run once against server state, target and Router never receive lifespan, and mounting a Compose object does not run its nested lifespan callbacks.

- [ ] **Step 4: Pin final HEAD and concurrency.** Assert Compose's outer HeadBoundary is idempotent with a Router's direct boundary, author middleware sees unsuppressed representation bytes, final wire suppresses body/file/trailer events, and two concurrent requests do not share response-guard or HEAD state.

- [ ] **Step 5: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/compose/01-description.t t/compose/02-dispatch.t t/compose/03-lifespan.t t/compose/04-middleware.t t/compose/05-head-concurrency.t t/compose/06-failsafes.t t/compose/07-response-guard.t'
  ```

  Expected: tests observe automatic Trace/NotFound/MethodNotAllowed layers and obsolete Compose-owned routing prose.

- [ ] **Step 6: Simplify the compiler.** Remove imports and wrappers for `PAGI::Routing::Trace`, `PAGI::Middleware::Routing::NotFound`, and `MethodNotAllowed`. Preserve one author app, one guarded HTTP/supported-scope app, lifespan handling, and the final HeadBoundary. Continue to normalize every immediate/Future completion through `Future->wrap`.

- [ ] **Step 7: Rewrite Compose POD.** State that `routes` constructs a normal root Router, Router owns 404/405, Compose never interprets routing metadata, and direct `app` silence is an application error guarded as 500.

- [ ] **Step 8: Run the GREEN gate and static checks.** Run the Step 5 command, compile both Compose modules under Perl 5.16.3, check both PODs, and run `git diff --check`.

- [ ] **Step 9: Commit and update the ledger.** Stage exactly the eight task files and commit:

  ```bash
  git add lib/PAGI/Compose/Compiler.pm lib/PAGI/Compose.pm t/compose/02-dispatch.t t/compose/03-lifespan.t t/compose/04-middleware.t t/compose/05-head-concurrency.t t/compose/06-failsafes.t t/compose/07-response-guard.t
  git commit -m "refactor: narrow Compose to root safety"
  ```

### Task 7: Align the Mutable App Router Frontend

**Files:**

- Modify: `lib/PAGI/App/Router.pm`
- Modify: `lib/PAGI/App/Router/Builder.pm`
- Modify: `lib/PAGI/App/Router/Materializer.pm`
- Modify: `t/app/02-routing.t`
- Modify: `t/app/03-router.t`
- Modify: `t/app/07-routing-composition.t`
- Delete: `t/app-router-group.t`
- Create: `t/app-router-mount-routes.t`
- Modify: `t/app-router.t`
- Modify: `t/app-router/01-builder-core.t`
- Modify: `t/app-router/02-declaration-package.t`
- Modify: `t/app-router/03-composition-order.t`
- Modify: `t/app-router/04-snapshots-cycles.t`
- Modify: `t/app-router/05-middleware-order.t`
- Modify: `t/app-router/06-public-api.t`
- Modify: `t/app-router/07-public-reverse-metadata.t`
- Modify: `t/router-middleware.t`
- Modify: `t/router-named-routes.t`

**Interfaces:**

- Constructor accepts `desc`, `middleware`, and optional `http_default`.
- `http_default($app)` configures exactly once, whether constructor or method supplied it; a second configuration croaks.
- `mount($path, app => $app, middleware => \@entries)` or `mount($path, routes => $array_or_sync_callback, middleware => \@entries)` is the only mutable Mount grammar; name/desc/constraints remain chained modifiers.
- A `routes` callback receives a fresh App Router builder synchronously; its return value is ignored. `group` does not exist.
- Raw Route targets accept the Task 1 application contract; normal handlers remain coderef-only.

- [ ] **Step 1: Rewrite builder grammar tests.** Remove `t/app-router-group.t` and create `t/app-router-mount-routes.t`. Assert `group`, positional targets, `router =>`, both/neither app/routes, and positional Mount middleware fail. Assert `routes => sub { ... }`, `routes => [route(...)]`, opaque app, named/unnamed immutable Router app, Mount middleware, and declaration order work.

- [ ] **Step 2: Add `http_default` tests.** Cover constructor and method forms, identity retention, exactly-once configuration, no protocol invocation, snapshot isolation, and propagation into `to_router->http_default`.

- [ ] **Step 3: Add raw object tests.** Use an instantiated `to_app` object as an HTTP/WebSocket/SSE raw leaf, assert compilation once and invocation with three channels, reject package strings and broken objects, and leave ordinary handler coderefs one-argument.

- [ ] **Step 4: Pin snapshot and order behavior.** Verify a callback child is built once per `to_router`, later parent/child mutation cannot change an old snapshot, first FULL declaration wins, Mount remains at its written position, one child Router can be reused at named sibling placements, and middleware builds fresh per compilation.

- [ ] **Step 5: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/app/02-routing.t t/app/03-router.t t/app/07-routing-composition.t t/app-router-mount-routes.t t/app-router.t t/app-router/01-builder-core.t t/app-router/02-declaration-package.t t/app-router/03-composition-order.t t/app-router/04-snapshots-cycles.t t/app-router/05-middleware-order.t t/app-router/06-public-api.t t/app-router/07-public-reverse-metadata.t t/router-middleware.t t/router-named-routes.t'
  ```

  Expected: current builder exposes group/positional/router modes, lacks `http_default`, and rejects raw app objects.

- [ ] **Step 6: Implement the new declaration records.** Store Mount records as `{ node_kind => 'mount', app => ... }` or `{ ..., child => $builder/\@nodes }`; never store `is_raw` or `router`. For a callback, construct `ref($self)->new`, call synchronously, and retain the child builder. At materialization, snapshot child builders through the same Materializer and pass the resulting immutable Router as `app`; let declarative Mount construct a Router from arrayref nodes.

- [ ] **Step 7: Implement one-shot HTTP default and raw shape validation.** Track an explicit boolean so omitted and configured are distinct. `_router_options` carries the original app; `_materialize_with` passes it to Router. Use `PAGI::Utils::_validate_app_value` for raw and Mount app targets; allow mutable frontend objects as opaque app values, while documentation instructs callers to use `to_router` when child names must be discoverable.

- [ ] **Step 8: Remove group and stale Materializer branches.** Delete group methods/records and router-target recursion that is no longer reachable. Retain Materializer identity caching for explicit frontend snapshot operations and callback child snapshots; retain defensive cycle diagnostics for malformed frontend graphs.

- [ ] **Step 9: Rewrite App Router POD.** Document `mount(app => ...)`, `mount(routes => sub { ... })`, `http_default`, explicit `to_router` for discoverable nested mutable frontends, raw Route versus Mount, and direct Router versus Compose safety.

- [ ] **Step 10: Run the GREEN gate and static checks.** Run the Step 5 command, compile all three App Router modules under Perl 5.16.3, check public POD, and `git diff --check`.

- [ ] **Step 11: Commit and update the ledger.** Stage exactly the eighteen task paths and commit:

  ```bash
  git add lib/PAGI/App/Router.pm lib/PAGI/App/Router/Builder.pm lib/PAGI/App/Router/Materializer.pm t/app/02-routing.t t/app/03-router.t t/app/07-routing-composition.t t/app-router-group.t t/app-router-mount-routes.t t/app-router.t t/app-router/01-builder-core.t t/app-router/02-declaration-package.t t/app-router/03-composition-order.t t/app-router/04-snapshots-cycles.t t/app-router/05-middleware-order.t t/app-router/06-public-api.t t/app-router/07-public-reverse-metadata.t t/router-middleware.t t/router-named-routes.t
  git commit -m "refactor: align mutable Router composition"
  ```

### Task 8: Align the Method-Oriented Endpoint Router Frontend

**Files:**

- Modify: `lib/PAGI/Endpoint/Router.pm`
- Modify: `lib/PAGI/Endpoint/Router/Builder.pm`
- Modify: `t/endpoint/12-route-middleware.t`
- Modify: `t/endpoint/13-router-frontends.t`
- Modify: `t/endpoint-router.t`

**Interfaces:**

- Endpoint facade exposes the App Router's route verbs, `route`, `websocket`, `sse`, `mount`, `http_default`, `name`, `desc`, and `constraints`; it exposes no `group`.
- A Mount `routes` callback receives a fresh Endpoint facade bound to the same Endpoint instance and a fresh child App Router.
- Handler strings bind only in normal handler positions. Native app positions use coderefs/objects, commonly `$self->app_as('method')`; middleware methods use `$self->middleware_as('method')`.
- Nested Endpoint instances with cross-boundary reverse names are explicitly converted through `to_router` before `app =>` placement.

- [ ] **Step 1: Rewrite Endpoint declaration tests.** Use this canonical shape and assert method identity/binding:

  ```perl
  sub routes {
      my ($self, $r) = @_;
      $r->http_default($self->app_as('not_found_app'));
      $r->get('/' => 'index')->name('index');
      $r->mount('/admin', routes => sub {
          my ($admin) = @_;
          $admin->get('/users' => 'users')->name('users');
      })->name('admin');
      $r->mount('/legacy', app => $self->app_as('legacy_app'));
  }
  ```

  Assert callback children bind to the same `$self`, normal coderef handlers are not rebound, `app_as` gets three channels, and `group`/positional/`router =>` forms fail.

- [ ] **Step 2: Add nested Endpoint/reverse tests.** Mount `$child_endpoint->to_router` under two names and prove absolute/relative Context lookup selects each placement. Mount the Endpoint object directly as opaque and prove dispatch works but outer reverse discovery does not guess its names.

- [ ] **Step 3: Add HTTP-default/protocol tests.** Prove `app_as` custom default receives HTTP NONE and responds, does not see PARTIAL/WS/SSE/exception, and duplicate configuration croaks through the App builder.

- [ ] **Step 4: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/endpoint/12-route-middleware.t t/endpoint/13-router-frontends.t t/endpoint-router.t'
  ```

  Expected: facade still exposes group and forwards only the old Mount grammar; it has no `http_default` or callback wrapping.

- [ ] **Step 5: Implement callback wrapping and forwarding.** In Endpoint Builder, parse Mount options enough to replace a `routes => $callback` value with a closure that constructs `PAGI::Endpoint::Router::Builder->new($endpoint, $child_app_builder)` and calls the user's callback. Forward arrayref routes and app values unchanged. Add a plain `http_default` forwarding method; do not bind strings implicitly.

- [ ] **Step 6: Delete Endpoint group and obsolete recursive materialization prose.** Keep `_instance_for`, `to_router`, `to_app`, `middleware_as`, `app_as`, `new_context`, and `app_path` unchanged except where POD examples use the new surface.

- [ ] **Step 7: Run the GREEN gate and static checks.** Run the Step 4 command, compile both Endpoint modules under Perl 5.16.3, check POD, and `git diff --check`.

- [ ] **Step 8: Commit and update the ledger.** Stage exactly the five task files and commit:

  ```bash
  git add lib/PAGI/Endpoint/Router.pm lib/PAGI/Endpoint/Router/Builder.pm t/endpoint/12-route-middleware.t t/endpoint/13-router-frontends.t t/endpoint-router.t
  git commit -m "refactor: align Endpoint Router composition"
  ```

### Task 9: Retire Trace and Routing Fallback Middleware

**Files:**

- Delete: `lib/PAGI/Routing/Trace.pm`
- Delete: `lib/PAGI/Routing/Trace/Recorder.pm`
- Delete: `lib/PAGI/Routing/Trace/Snapshot.pm`
- Delete: `lib/PAGI/Middleware/Routing/_Fallback.pm`
- Delete: `lib/PAGI/Middleware/Routing/NotFound.pm`
- Delete: `lib/PAGI/Middleware/Routing/MethodNotAllowed.pm`
- Delete: `t/routing/13-trace.t`
- Delete: `t/routing/14-trace-compiler.t`
- Delete: `t/routing/15-fallback-middleware.t`
- Delete: `t/app-router-scope-decline.t`
- Modify: `lib/PAGI/App/Cascade.pm`
- Modify: `lib/PAGI/App/URLMap.pm`
- Modify: `t/00-load.t`
- Modify: `t/app/02-routing.t`
- Modify: `t/app/07-routing-composition.t`
- Modify: `t/upgrading-router-frontends.t`
- Delete: `t/upgrading-routing-fallbacks.t`
- Create: `t/upgrading-routing-composition.t`
- Modify: `t/context/07-router.t`

**Interfaces:**

- No loadable/public Trace or routing fallback middleware remains.
- `pagi.routing` contains selected reverse-routing/metadata frames only and is never interpreted as a decline/status request.
- Cascade catches ordinary child 404/405 responses according to its existing
  `catch` contract and needs no trace discard channel. URLMap delegates with
  ordinary rewritten scopes and performs no trace shielding.
- The executable upgrade test rejects every removed spelling and exercises the new replacements.

- [ ] **Step 1: Add negative load and API tests before deleting files.** Assert Router/Compose/Context code no longer references `pagi.routing.trace`, Trace classes, fallback middleware, checkpoints, attempts, `routing_declined`, or `allowed_methods` evidence. Assert the new Router outcome tests already cover their former behavioral purpose. In App routing tests, prove Cascade advances on a Router's emitted 404/405 and replays the first non-caught response, while URLMap delegates without deleting unrelated `pagi.routing` selected metadata.

- [ ] **Step 2: Rewrite the upgrade executable.** Remove `t/upgrading-routing-fallbacks.t` and create `t/upgrading-routing-composition.t`. Replace fallback-middleware recipes with exact before/after cases for Router `http_default`, built-in 405, nested ownership, Mount `app/routes`, no group, no package app strings, and direct Router versus Compose safety. Include assertions that removed options fail as unknown and removed methods are absent.

- [ ] **Step 3: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/00-load.t t/app/02-routing.t t/app/07-routing-composition.t t/upgrading-router-frontends.t t/upgrading-routing-composition.t t/context/07-router.t'
  ```

  Expected: load tests and upgrade fixtures still import removed modules/surface.

- [ ] **Step 4: Delete the six modules and four obsolete tests with `apply_patch`.** Do not use recursive filesystem deletion. Remove their `t/00-load.t` entries and every live reference from the surviving task tests. Remove Cascade's Trace discard factory and URLMap's Trace-key shielding; do not change their public mount/catch contracts.

- [ ] **Step 5: Search the live tree.** Run:

  ```bash
  rg -n "PAGI::Routing::Trace|pagi\.routing\.trace|Middleware::Routing::(?:NotFound|MethodNotAllowed)|routing_declined|_Fallback" lib t examples README.md UPGRADING.md Changes
  ```

  Expected: no live matches. Historical `docs/superpowers/specs` and plans are explicitly outside this search and remain unchanged.

- [ ] **Step 6: Run the GREEN gate and load/static checks.** Run the Step 3 command, `perlbrew exec --with perl-5.16.3 perl -Ilib -c` for every changed surviving `.pm`, and `git diff --check`.

- [ ] **Step 7: Commit and update the ledger.** Stage exactly the nineteen paths and commit:

  ```bash
  git add lib/PAGI/Routing/Trace.pm lib/PAGI/Routing/Trace/Recorder.pm lib/PAGI/Routing/Trace/Snapshot.pm lib/PAGI/Middleware/Routing/_Fallback.pm lib/PAGI/Middleware/Routing/NotFound.pm lib/PAGI/Middleware/Routing/MethodNotAllowed.pm t/routing/13-trace.t t/routing/14-trace-compiler.t t/routing/15-fallback-middleware.t t/app-router-scope-decline.t lib/PAGI/App/Cascade.pm lib/PAGI/App/URLMap.pm t/00-load.t t/app/02-routing.t t/app/07-routing-composition.t t/upgrading-router-frontends.t t/upgrading-routing-fallbacks.t t/upgrading-routing-composition.t t/context/07-router.t
  git commit -m "refactor: remove routing decline machinery"
  ```

### Task 10: Migrate and Strengthen the Public Examples

**Files:**

- Modify: `examples/starlette-apples/app.pl`
- Modify: `examples/starlette-apples/README.md`
- Modify: `examples/15-large-application/lib/MyApp/Root.pm`
- Modify: `examples/15-large-application/lib/MyApp/Person.pm`
- Modify: `examples/15-large-application/lib/MyApp/Person/Blogs.pm`
- Modify: `examples/15-large-application/README.md`
- Modify: `examples/15-large-application/GAPS.md`
- Modify: `examples/declarative-routing/app.pl`
- Modify: `examples/declarative-routing/README.md`
- Modify: `examples/endpoint-router-demo/lib/MyApp/Main.pm`
- Modify: `examples/endpoint-router-demo/lib/MyApp/API.pm`
- Modify: `examples/endpoint-router-demo/README.md`
- Modify: `examples/10-chat-showcase/app.pl`
- Modify: `examples/10-chat-showcase/README.md`
- Modify: `examples/background-tasks/app.pl`
- Modify: `examples/endpoint-demo/app.pl`
- Modify: `examples/endpoint-demo/README.md`
- Modify: `examples/pages/app.pl`
- Modify: `examples/pages/README.md`
- Modify: `examples/README.md`
- Modify: `t/integration-starlette-apples.t`
- Modify: `t/integration-large-application.t`
- Modify: `t/integration-declarative-routing-demo.t`
- Modify: `t/integration-endpoint-router-demo.t`
- Modify: `t/integration-chat-compose.t`
- Modify: `t/integration-router-application-boundaries.t`
- Modify: `t/integration-app-file-examples.t`
- Modify: `t/integration-pages-example.t`

**Interfaces:**

- Examples return Compose/Router objects where a conforming server accepts `to_app` objects; they do not append `->to_app` merely for loading.
- Starlette apples uses one `mount('/apples', routes => [...])`; no temporary child variable exists solely for `router =>`.
- Large application demonstrates root and nested Router HTTP defaults, `app => $child_router`, cross-mount reverse links, lifespan, and Pages without wildcard fallbacks masquerading as normal 404 policy.
- Endpoint demo demonstrates `mount(routes => sub { ... })`, explicit `to_router` for discoverable child Endpoint objects, `app_as`, and `http_default`.

- [ ] **Step 1: Change integration expectations first.** Require `/apples` and `/apples/` to reach the same child index, child 405 to own its Allow, child invalid-ID miss to use the child default, root miss to use the root default, links to resolve across mounts, and all examples to load as objects with `to_app`.

- [ ] **Step 2: Modernize the apples app to the specification's exact shape.** Keep Perl 5.40 signatures and `Types::Standard qw(Int)`, inline the child routes under `mount('/apples', routes => [...], name => 'apples')`, keep the Welcome route, and return `compose(...)` without `->to_app`.

- [ ] **Step 3: Modernize the large application.** Replace `router =>` with `app =>`; replace root and Blogs wildcard catchalls with explicit Router `http_default` Pages endpoints carrying boundary-specific detail; retain handler-produced resource 404s, named links, relative `..`, query, fragment, state, static Mount, and lifespan. Remove resolved GAPS entries and accurately retain deferred gaps only.

- [ ] **Step 4: Modernize declarative and Endpoint demos.** Make declarative nested routes use Mount `routes` or `app` according to whether a separate Router configuration is needed. Make Endpoint callback nesting and custom defaults use the Task 8 facade; retain HTTP/WebSocket/SSE demonstrations and route-level middleware.

- [ ] **Step 5: Migrate remaining live Mount spellings.** Run:

  ```bash
  rg -n "mount\([^\n]*=>|router\s*=>|\bgroup\s*\(" examples
  ```

  Inspect every match rather than applying a blind rewrite. CSS classes, prose about external frameworks, and the Python source are not Perl declarations; leave them intact.
  The step is incomplete until every Perl declaration beneath `examples/`
  uses `mount(app => ...)` or `mount(routes => ...)`, no example calls
  `group`, and every changed example has a focused integration or load test.

- [ ] **Step 6: Run focused integration tests.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-starlette-apples.t t/integration-large-application.t t/integration-declarative-routing-demo.t t/integration-endpoint-router-demo.t t/integration-chat-compose.t t/integration-router-application-boundaries.t t/integration-app-file-demo.t t/integration-app-file-examples.t t/integration-pages-example.t'
  ```

  Expected: all migrated apps load and behavior assertions pass.

- [ ] **Step 7: Verify example syntax and copy.** Compile every changed Perl 5.40 example with project Perl, run `git diff --check`, and compare the complete apples Perl block against the Python block in its README so the comparison table names current syntax/outcome ownership.

- [ ] **Step 8: Commit and update the ledger.** Stage only the exact example and integration files actually changed, list them explicitly in the ledger, and commit:

  ```bash
  git add examples/starlette-apples/app.pl examples/starlette-apples/README.md examples/15-large-application/lib/MyApp/Root.pm examples/15-large-application/lib/MyApp/Person.pm examples/15-large-application/lib/MyApp/Person/Blogs.pm examples/15-large-application/README.md examples/15-large-application/GAPS.md examples/declarative-routing/app.pl examples/declarative-routing/README.md examples/endpoint-router-demo/lib/MyApp/Main.pm examples/endpoint-router-demo/lib/MyApp/API.pm examples/endpoint-router-demo/README.md examples/10-chat-showcase/app.pl examples/10-chat-showcase/README.md examples/background-tasks/app.pl examples/endpoint-demo/app.pl examples/endpoint-demo/README.md examples/pages/app.pl examples/pages/README.md examples/README.md t/integration-starlette-apples.t t/integration-large-application.t t/integration-declarative-routing-demo.t t/integration-endpoint-router-demo.t t/integration-chat-compose.t t/integration-router-application-boundaries.t t/integration-app-file-examples.t t/integration-pages-example.t
  git commit -m "docs: migrate examples to composed Mounts"
  ```

### Task 11: Publish the New Model and Complete Upgrade Guide

**Files:**

- Modify: `README.md`
- Modify: `lib/PAGI/Tools.pm`
- Modify: `lib/PAGI/Tools/Tutorial.pod`
- Modify: `lib/PAGI/Tools/Cookbook.pod`
- Modify: `lib/PAGI/Routing.pm`
- Modify: `lib/PAGI/Routing/Mount.pm`
- Modify: `lib/PAGI/Routing/Router.pm`
- Modify: `lib/PAGI/Routing/Compiler.pm`
- Modify: `lib/PAGI/Compose.pm`
- Modify: `lib/PAGI/App/Router.pm`
- Modify: `lib/PAGI/Endpoint/Router.pm`
- Modify: `lib/PAGI/App/Cascade.pm`
- Modify: `lib/PAGI/App/File.pm`
- Modify: `lib/PAGI/App/URLMap.pm`
- Modify: `lib/PAGI/Middleware/ErrorHandler.pm`
- Modify: `lib/PAGI/Pages.pm`
- Modify: `lib/PAGI/Response.pm`
- Modify: `UPGRADING.md`
- Modify: `Changes`
- Modify: `t/upgrading-routing-composition.t`

**Interfaces:**

- Public docs lead with: “Route matches a complete URL leaf. Mount composes an application under a prefix. Router selects and owns routing outcomes. Middleware wraps behavior. Compose owns the application root and lifespan.”
- Upgrade tests make all live Perl snippets executable under the intended frontend.
- Changes records the redesign inside unreleased `0.002003`; this task does not release, tag, push, or increment the distribution version.

- [ ] **Step 1: Write the executable migration matrix first.** Cover every section-17 row plus application strings versus middleware strings, Router direct safety, exact Mount normalization, nested ownership, child custom HTTP default, mutable callback syntax, Endpoint `app_as`, and `raw` versus Mount. Use accepted snippets that construct and rejected snippets wrapped in `dies`.

- [ ] **Step 2: Run the RED migration test.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/upgrading-routing-composition.t'
  ```

  Expected: stale public docs/snippets or any remaining old spelling fail their asserted construction/search contract.

- [ ] **Step 3: Rewrite public conceptual documentation.** Include complete declarative apples, mutable App Router, Endpoint Router, separate child Router with local HTTP default, static app Mount, raw exact Route, middleware at all four levels, named/unnamed reverse lookup, reused child placements, and nested 404/405 ownership.

- [ ] **Step 4: Document deliberate Starlette differences.** State explicit Context versus native app positions, validation without coercion, slash logical names and relative lookup, first-class SSE, HTTP-only `http_default`, pure PAGI middleware, Compose-owned root lifespan, and deferred OpenAPI/schema support. Record that Starlette's multiprotocol `default` was considered and deliberately not copied.

- [ ] **Step 5: Write the complete breaking upgrade section.** Show exact before/after code for positional Mount, `router =>`, group, inline transparent routes, old Mount accessors, silent Router decline, fallback middleware, Compose automatic fallbacks, and package-name apps. Explain that a bare Router now sends its own 404/405 but still lacks root ErrorHandler/ResponseGuard/lifespan.

- [ ] **Step 6: Update release notes and cross-links.** Put the redesign under unreleased `0.002003`, cross-link Router/Mount/Compose/Endpoint POD, remove live Trace/fallback links, and state that the redesign lands before the next CPAN release with no compatibility layer.

- [ ] **Step 7: Run documentation gates.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/upgrading-routing-composition.t t/00-pod/cookbook-examples.t'
  ```

  Then run `podchecker` on every changed `.pm`/`.pod`, compile changed `.pm` files under Perl 5.16.3, and run the live-tree searches:

  ```bash
  rg -n "PAGI::Routing::Trace|pagi\.routing\.trace|Middleware::Routing::(?:NotFound|MethodNotAllowed)|mount\('/[^']*'\s*=>|router\s*=>|\bgroup\s*\(" lib t examples README.md UPGRADING.md Changes
  rg -n "app\s*=>\s*'[A-Za-z_][A-Za-z0-9_:]*'" lib t examples README.md UPGRADING.md Changes
  ```

  Expected: first search has only deliberately quoted rejected-before examples in the upgrade test/docs and non-API prose/CSS, each manually classified in the ledger; second has only the documented rejected-before example.

- [ ] **Step 8: Commit and update the ledger.** Run `git diff --check`, stage exactly the changed documentation/test files, and commit:

  ```bash
  git add README.md lib/PAGI/Tools.pm lib/PAGI/Tools/Tutorial.pod lib/PAGI/Tools/Cookbook.pod lib/PAGI/Routing.pm lib/PAGI/Routing/Mount.pm lib/PAGI/Routing/Router.pm lib/PAGI/Routing/Compiler.pm lib/PAGI/Compose.pm lib/PAGI/App/Router.pm lib/PAGI/Endpoint/Router.pm lib/PAGI/App/Cascade.pm lib/PAGI/App/File.pm lib/PAGI/App/URLMap.pm lib/PAGI/Middleware/ErrorHandler.pm lib/PAGI/Pages.pm lib/PAGI/Response.pm UPGRADING.md Changes t/upgrading-routing-composition.t
  git commit -m "docs: explain routing composition redesign"
  ```

### Task 12: Final Contract Audit, Review, Suite, and Distribution Build

**Files:**

- Modify only if a verified defect is found: files already owned by Tasks 1–11
- Create/update ignored execution evidence: `.superpowers/sdd/2026-08-26-starlette-aligned-routing-composition/progress.md`
- Create ignored audit report: `.superpowers/sdd/2026-08-26-starlette-aligned-routing-composition/task-12-audit-report.md`

**Interfaces:**

- Produces one auditable spec-to-code/test/doc matrix, one independently reviewed final HEAD, one final full-suite result, and one inspected distribution archive.
- Does not push, merge, tag, publish, or modify another repository.

- [ ] **Step 1: Audit every specification section.** In the report, map sections 6–17, all twenty testing requirements, removed-surface rows, adversarial findings, non-goals, documentation outcomes, and acceptance criteria to exact code, tests, docs, and commit SHAs. Mark each `covered`; a genuine mismatch becomes a DEV record before code changes.

- [ ] **Step 2: Run the mandatory self-review scans.** Search the plan and implementation for stale names and placeholders; verify type/signature consistency for `_validate_app_value`, `Mount->app`, `Router->http_default`, metadata frames, App/Endpoint callback forms, and every example. Confirm no request-local data lives in compiled objects and no app is compiled per request.

- [ ] **Step 3: Request independent code review.** Use `superpowers:requesting-code-review`. Give the reviewer the approved spec, this plan, starting HEAD, final candidate HEAD, task ledger, and explicit questions about nested ownership, Allow authority, metadata concurrency, exact-prefix normalization, resolver cycles/collisions, protocol misses, and Compose safety. Resolve all Critical/Important findings through focused TDD and record review rounds.

- [ ] **Step 4: Run one pre-suite focused campaign gate.** Run all routing/Compose/frontend/Context/upgrading/example integration files changed by Tasks 1–11 in one `prove -l` invocation. Record actual file/test counts and elapsed time. This is not the full suite.

- [ ] **Step 5: Verify Perl floor and POD.** Compile every changed `lib/*.pm` under Perl 5.16.3; compile modern examples under project Perl; run `podchecker` for every changed POD-bearing file; run both live-tree stale searches from Task 11; run `git diff --check` and verify `git status --short` contains only known ignored/untracked evidence.

- [ ] **Step 6: Run the repository-wide suite exactly once at the reviewed candidate HEAD.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t'
  ```

  Record exact HEAD, exit status, file count, assertion count, wall/CPU time, skips, warnings, and failures. Do not run `dzil test`.

- [ ] **Step 7: If the full suite exposes a defect, fix it with focused TDD and repeat the final-suite gate once at the corrected HEAD.** Append the original evidence and correction to the audit report and ledger. Obtain review of the fix before the replacement final suite. Do not erase the failed run.

- [ ] **Step 8: Build and inspect the distribution without rerunning tests.** Run `dzil build`, inspect the generated archive with `tar -tf`, and assert deleted Trace/fallback modules are absent; current modules, upgrade docs, README, Changes, and tests expected in the distribution are present; `docs/superpowers` and unrelated artifacts are absent. Inspect generated META prerequisites and version `0.002002`/unreleased Changes placement without publishing.

- [ ] **Step 9: Reconfirm the work map and final diff.** Record branch, base, commit range, exact owned paths, no deployment, and no push target. Verify no unrelated user artifacts were staged or committed and all task rows contain real evidence.

- [ ] **Step 10: Commit only verified audit fixes, if any.** If Steps 1–8 required production/test/doc corrections, stage only those exact owned files and use a specific commit subject such as `fix: complete routing composition contract`; otherwise make no empty commit. Update Task 12's row with the final reviewed SHA and archive evidence.

## Plan Self-Review Record

- **Spec coverage:** Tasks 1–11 cover shared app values, exact constructors, reverse inspection, Mount delegation, Router outcomes, middleware/HEAD/protocol ownership, Compose safety, both class frontends, trace removal, examples, migrations, docs, and release sequencing. Task 12 maps all twenty testing requirements and every acceptance criterion before the only full suite.
- **Placeholder scan:** The plan contains no `TBD`, `TODO`, “similar to,” unspecified error-handling step, conditional file ownership, or unnamed test command.
- **Type consistency:** `_validate_app_value($value,$label)` returns the original value; `to_app($value)` returns CODE; `Mount->app` returns the base coderef/object/constructed Router; `Router->http_default` returns the declared app or `undef`; normal handlers remain CODE; mutable `routes` accepts arrayref/callback only; functional `routes` accepts arrayref only.
- **Boundary consistency:** First-party Router recognition affects Resolver metadata and collision validation only. Runtime always calls a compiled child app, matched Mount ownership is final, and no Trace/exception/`$next` fallback path remains.
