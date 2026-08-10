# Unified Router Frontends Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task. Use
> `superpowers:test-driven-development` for every behavior change and
> `superpowers:verification-before-completion` before claiming completion.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `PAGI::App::Router` and `PAGI::Endpoint::Router` with mutable
and class-oriented frontends over the immutable `PAGI::Routing` model, while
preserving declaration order, sharing one middleware contract and resolver,
and giving existing users a tested migration guide.

**Architecture:** `PAGI::Routing` remains the only immutable route model,
resolver, matcher, Context adapter, and compiler. A private App builder stores
ordered declarations and a private materializer recursively turns mutable App
and Endpoint objects into fresh immutable Router snapshots with identity-based
reuse and cycle detection. Public `PAGI::App::Router` exposes that builder;
`PAGI::Endpoint::Router` adds only explicit local-method binding and helper
adapters before delegating to the same builder and materializer.

**Tech Stack:** Perl 5.18-compatible distribution source, Perl 5.40+ example
source where already required, hand-written blessed hashes, `Future`,
`Future::AsyncAwait`, `Scalar::Util`, `Test2::V0`, `PAGI::Test::Client`, POD,
Dist::Zilla, and the merged inline-constraint-provider implementation. No new
runtime dependency.

## Global Constraints

- The approved contract is
  `docs/superpowers/specs/2026-08-10-unified-router-frontends-design.md`. If
  implementation evidence conflicts with it, record a deviation and obtain
  the user's decision before dependent work continues.
- The inline-constraint-provider branch is a prerequisite. Do not start Task 1
  until current HEAD contains its normalized predicate records,
  `Route->_new_from`, `Mount->_new_from`, declaration-package tests, shared
  protocol constraints, reverse-composition support, Type::Tiny test
  prerequisite, and modernized large example. The current reviewed reference
  is `ca93918`; an equivalent merged/rebased history is acceptable when all
  provider tests pass.
- This is an intentional breaking redesign. Do not preserve the old App
  matcher, `uri_for`, dotted effective names, `as`, mount `namespace`, package
  string loading, native-app-by-default handlers, Endpoint `$self->state`,
  `context_class`, or response-valued `$next` middleware through aliases,
  warnings, dual writes, or deprecation branches.
- Work only in
  `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` or a worktree created
  for this repository by the Superpowers worktree workflow.
- Preserve the unrelated untracked files `.cpan-testers-fix-report.md`,
  `.csrf-helper-brief.md`, and `.csrf-helper-report.md`. Never stage them.
- Keep every file under `lib/` and every ordinary test parseable on Perl 5.18:
  use classic `@_` unpacking and avoid signatures, postfix dereferencing,
  `try`/`catch`, and newer syntax. Existing Perl 5.40+ example code may retain
  signatures.
- Keep `PAGI::Routing::{Route,Mount,Router}` immutable. Mutable frontend
  records, active ancestry, completed-object maps, last-declaration pointers,
  and request-independent build state must never enter an immutable
  description or request scope.
- Preserve one ordered declaration array at every mutable and immutable
  routing level. Do not bucket by protocol, sort paths, prefer static routes,
  or reorder mounts by prefix length.
- Preserve the shared FULL/PARTIAL algorithm: first FULL wins; earlier method
  PARTIALs do not stop a later FULL; first-seen methods form the generated
  `Allow`; a matched mount owns immediately at its declaration position.
- Preserve automatic HEAD through GET method normalization. A cheaper custom
  HEAD handler is an explicit HEAD route declared before GET. Do not add
  `auto_head` or special route pairing.
- Preserve one outermost `PAGI::Routing::HeadBoundary`. Router and route
  middleware must observe the complete GET-equivalent representation before
  ordinary and sendfile body events are suppressed at the wire.
- Use `Future->wrap($returned)` at every existing shared handler/application
  adaptation boundary. Never directly `await` a value that may be an immediate
  `PAGI::Response` or inert scalar.
- Use only pure PAGI app-to-app middleware. A factory synchronously receives
  `($inner_app)` and immediately returns a PAGI app coderef; that app later
  receives `($scope, $receive, $send)`. Do not introduce `$c, $next -> Response`
  under another name.
- A coderef is never inspected, named, rebound, or inferred. Endpoint handler
  strings are the only implicit local-method form. Endpoint middleware methods
  use `middleware_as`; native local applications use `app_as`.
- All middleware positions accept the same four forms: class-name string,
  coderef factory, blessed object with `wrap`, or existing
  `PAGI::Routing::Middleware` description. A middleware-list string always
  denotes a class, including inside Endpoint routes.
- Keep `not_found` and `method_not_allowed` at their existing Router boundary.
  Do not redesign 404/405 bubbling, trailing-slash policy, exceptions, or
  response-status shortcuts.
- Keep the current `PAGI::Context` reverse-routing methods for first-party
  compiled routers. Do not solve the deferred third-party routing contract in
  this plan.
- Put short public POD beside every changed public module in the same task as
  its behavior. The later documentation task reconciles Tutorial, Cookbook,
  examples, README, and Changes; it does not postpone API documentation.
- Use TDD: add the smallest focused failing assertion, run it and record the
  expected failure, implement the behavior, rerun the focused test, then run
  the task's named regression gate.
- Capture intended failures with `dies` and assert stable semantic fragments,
  not file/line suffixes. Test output must remain clean.
- Stage only files named by the current task. Never use `git add .` or
  `git add -A`. `docs/superpowers` is ignored; use `git add -f` only for the
  exact approved plan/spec path.
- Every implementation task ends with one focused commit and review gate. The
  coordinator independently checks the diff, focused output, SHA, and ledger
  row before the next task starts.
- Run the repository-wide `prove -lr t` suite exactly once at the final
  reviewed HEAD. Focused tests may be rerun as TDD requires. Do not run
  `dzil test`, because it would repeat the full suite. If the final suite
  exposes a defect and HEAD changes, record the failure/fix and run one new
  final suite at the corrected HEAD.
- Run Perl commands through the project Perl. For example:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/11-bare-middleware.t'
  ```

## Execution Tracking and Deviation Control

Before Task 1, create the isolated execution workspace using the selected
execution skill. When using subagent-driven development, run:

```bash
/Users/jnapiorkowski/.codex/plugins/cache/openai-curated-remote/superpowers/6.2.0/skills/subagent-driven-development/scripts/sdd-workspace docs/superpowers/plans/2026-08-10-unified-router-frontends.md
```

The command must print a directory ending in
`.superpowers/sdd/2026-08-10-unified-router-frontends`. Create its
`progress.md` with this exact first line and tables:

```markdown
# SDD ledger — plan: docs/superpowers/plans/2026-08-10-unified-router-frontends.md

| Task | Status | Commit range | Focused verification | Full-suite verification | Review |
|---|---|---|---|---|---|
| 1 | pending | — | — | deferred to Task 10 | — |
| 2 | pending | — | — | deferred to Task 10 | — |
| 3 | pending | — | — | deferred to Task 10 | — |
| 4 | pending | — | — | deferred to Task 10 | — |
| 5 | pending | — | — | deferred to Task 10 | — |
| 6 | pending | — | — | deferred to Task 10 | — |
| 7 | pending | — | — | deferred to Task 10 | — |
| 8 | pending | — | — | deferred to Task 10 | — |
| 9 | pending | — | — | deferred to Task 10 | — |
| 10 | pending | — | — | final gate | — |

## Deviations

| ID | Status | Conflicting plan text | Evidence and rationale | Affected tasks | User decision |
|---|---|---|---|---|---|
```

Before Task 1, run:

```bash
git rev-parse HEAD
```

Copy its exact 40-character output into both
`.superpowers/sdd/2026-08-10-unified-router-frontends/starting-head` (with one
trailing newline) and `progress.md` as `Starting HEAD: SHA`. Also record
`git status --short` and prerequisite evidence. The coordinator owns the
ledger. Update each task row in the same working step as its commit/review and
record exact commands, exit statuses, real test-file/assertion counts, elapsed
time, commit SHA, and review evidence—never estimates or a worker's unsupported
summary.

A contract conflict gets the next stable ID (`D-001`, `D-002`, and so on),
status `awaiting decision`, exact conflicting text, concrete evidence, and all
blocked tasks. Record the user's explicit approval, rejection, or replacement
before dependent work continues. An ordinary defect whose fix preserves the
approved contract is not a deviation.

## File and Responsibility Map

- `lib/PAGI/Routing/Middleware.pm`: the one four-form middleware normalizer and
  synchronous wrapper compiler.
- `lib/PAGI/Routing/{Route,Mount,Router}.pm`: immutable public descriptions;
  Mount changes from public `namespace` to local `name`.
- `lib/PAGI/Routing/Resolver.pm`: slash-address traversal and match metadata
  using mount `name` while retaining internal `logical_namespace`.
- `lib/PAGI/Routing/Compiler.pm`: unchanged shared matching engine; only mount
  metadata vocabulary may change.
- `lib/PAGI/App/Router/Builder.pm`: private mutable ordered declarations,
  parsing, last-declaration modifiers, and conversion to public immutable
  nodes.
- `lib/PAGI/App/Router/Materializer.pm`: one-root active/completed identity
  context, recursive mutable-frontend conversion, reuse, and cycle diagnostics.
- `lib/PAGI/App/Router.pm`: public mutable frontend, inspection/reverse
  delegation, lifecycle POD, and no matcher.
- `lib/PAGI/Endpoint/Router/Builder.pm`: Endpoint-aware handler-string binding
  and forwarding into the App builder while preserving declaration packages.
- `lib/PAGI/Endpoint/Router.pm`: class/object lifecycle, nested materialization,
  `middleware_as`, `app_as`, `new_context`, and public POD.
- `t/routing/11-bare-middleware.t` and Compose description/middleware tests:
  four-form normalization, construction timing, identity, and ordering.
- `t/routing/{01-constructors,03-reverse-inspection,05-generated-outcomes,08-protocols,09-metadata-isolation,12-router-mounts}.t` and
  `t/context/12-routing-reverse.t`: mount-name vocabulary and unchanged
  resolver/compiler behavior.
- `t/app-router/`: new focused private-builder, public App, order,
  composition, snapshot, reverse-routing, and concurrency tests.
- Existing `t/app-router*.t`, `t/router-*.t`, `t/context/07-router.t`,
  `t/app/03-router.t`, and protocol integration tests: migrated or retired only
  after equivalent focused coverage exists.
- `t/endpoint-router.t`, `t/endpoint/12-route-middleware.t`, and
  `t/integration-endpoint-router-demo.t`: rebuilt class frontend and real
  middleware behavior.
- `examples/endpoint-router-demo`: canonical nested Endpoint application with
  lifespan state and HTTP/WebSocket/SSE.
- `UPGRADING.md` and `t/upgrading-router-frontends.t`: standalone migration
  guide and executable before/after claims.
- `lib/PAGI/Tools.pm`, Tutorial, Cookbook, `README.md`, `Changes`, and affected
  example sources/READMEs: three-frontends/one-engine public narrative and
  migrated runnable code.

---

### Task 1: Normalize All Four Middleware Entry Forms

**Files:**

- Modify: `lib/PAGI/Routing/Middleware.pm`
- Modify: `lib/PAGI/Routing.pm`
- Modify: `lib/PAGI/Compose.pm`
- Modify: `t/routing/11-bare-middleware.t`
- Modify: `t/compose/01-description.t`
- Modify: `t/compose/04-middleware.t`

**Interfaces:**

- `_normalize_descriptors($entries, $error_prefix)` accepts a class-name
  string, CODE factory, blessed object with `wrap`, or existing
  `PAGI::Routing::Middleware` per occurrence.
- It returns a fresh arrayref containing only Middleware descriptions.
- Existing descriptions retain identity; the other three forms each receive a
  fresh description.
- Class/object/factory construction and wrapping remain deferred until
  `to_app`; normalization performs no protocol I/O.
- `middleware($target, %config)` remains required only for configured class
  descriptions and useful for explicit reuse/inspection.

- [ ] **Step 1: Add failing four-form normalization tests.** In
  `t/routing/11-bare-middleware.t`, define a local configured object with a
  counted `wrap`, and use `TestApps::FakeMiddleware` as a loadable class. Build
  a table covering Router, HTTP, WebSocket, SSE, inline mount, Router mount,
  and opaque mount middleware. Each list must contain:

  ```perl
  my $factory = sub { my ($inner) = @_; return $inner };
  my $object  = Local::ConfiguredMiddleware->new;
  my $explicit = middleware('^TestApps::FakeMiddleware');

  middleware => [
      '^TestApps::FakeMiddleware',
      $factory,
      $object,
      $explicit,
  ]
  ```

  Assert four normalized descriptions, target identity for factory/object,
  explicit descriptor identity, fresh top-level list copies, and no class
  construction/`wrap` before `to_app`.

- [ ] **Step 2: Add failing Compose and rejection tests.** Change the current
  Compose cases that reject `'RequestId'` and a wrapping object into accepted
  cases. Assert Compose accessors return descriptions, then add invalid scalar,
  arrayref, hashref, unblessed object, empty string, malformed class, object
  without `wrap`, and class config supplied bare in a list. Keep configured
  class use explicit:

  ```perl
  middleware('RequestId', header => 'X-Request-ID')
  ```

- [ ] **Step 3: Run the red gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/11-bare-middleware.t t/compose/01-description.t t/compose/04-middleware.t'
  ```

  Expected before implementation: direct class strings and wrapping objects
  fail `_normalize_descriptors` with the old “descriptions or coderef
  factories” diagnostic.

- [ ] **Step 4: Expand only the shared normalizer.** Check an existing
  description before the generic blessed-object branch, then normalize:

  ```perl
  if (ref($entry) eq 'CODE') {
      push @normalized, $class->new($entry);
  }
  elsif (blessed($entry) && $entry->isa($class)) {
      push @normalized, $entry;
  }
  elsif (blessed($entry) && $entry->can('wrap')) {
      push @normalized, $class->new($entry);
  }
  elsif (!ref($entry) && defined($entry) && length($entry)) {
      push @normalized, $class->new($entry);
  }
  else {
      croak "$error_prefix entry $index must be a middleware class name, "
          . 'coderef factory, object with wrap, or middleware description';
  }
  ```

  Let `Middleware->new` retain the authoritative class grammar and object
  validation. Include the zero-based or one-based entry index consistently in
  every invalid-list diagnostic and tests.

- [ ] **Step 5: Prove compile/runtime timing and order.** Compile a mixed list
  twice. Assert class construction, object `wrap`, and factories each run once
  per compiled occurrence; requests do not repeat them; and runtime tracing is
  first-listed-outermost. Include a middleware class returning a non-coderef
  and preserve the compile-time `must return PAGI app coderef` failure.

- [ ] **Step 6: Update immediate public POD.** In Middleware, Routing, and
  Compose POD, show the four-form list, state the two phases, and redefine
  `middleware()` as the configuration/reuse/inspection constructor. Remove the
  earlier claim that direct strings and configured objects are invalid.

- [ ] **Step 7: Run focused regressions and commit.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/04-middleware-descriptors.t t/routing/09-metadata-isolation.t t/routing/11-bare-middleware.t t/compose/01-description.t t/compose/04-middleware.t'
  ```

  Then stage only the six task files and commit:

  ```bash
  git add lib/PAGI/Routing/Middleware.pm lib/PAGI/Routing.pm lib/PAGI/Compose.pm t/routing/11-bare-middleware.t t/compose/01-description.t t/compose/04-middleware.t
  git commit -m "Routing: normalize all middleware entry forms"
  ```

  Review that no compiler or runtime request path learned new input shapes.
  Update Task 1's ledger row with the SHA and exact test evidence.

---

### Task 2: Replace Mount `namespace` with Local `name`

**Files:**

- Modify: `lib/PAGI/Routing/Mount.pm`
- Modify: `lib/PAGI/Routing/Route.pm`
- Modify: `lib/PAGI/Routing/Router.pm`
- Modify: `lib/PAGI/Routing/Resolver.pm`
- Modify: `lib/PAGI/Routing/Compiler.pm`
- Modify: `lib/PAGI/Routing.pm`
- Modify: `t/routing/01-constructors.t`
- Modify: `t/routing/03-reverse-inspection.t`
- Modify: `t/routing/05-generated-outcomes.t`
- Modify: `t/routing/08-protocols.t`
- Modify: `t/routing/09-metadata-isolation.t`
- Modify: `t/routing/12-router-mounts.t`
- Modify: `t/context/12-routing-reverse.t`
- Modify: `examples/15-large-application/lib/MyApp/Root.pm`
- Modify: `examples/15-large-application/lib/MyApp/Person.pm`
- Modify: `examples/15-large-application/lib/MyApp/Person/Blogs.pm`
- Modify: `examples/15-large-application/README.md`
- Modify: `examples/15-large-application/GAPS.md`
- Modify: `t/integration-large-application.t`

**Interfaces:**

- `mount(..., name => $segment)` is the only public logical-placement field.
- Inline mounts may omit `name`; Router mounts require it; opaque mounts reject
  it.
- `Mount->name` returns the local segment. Public `namespace` accessors are
  removed from Mount, Route, and Router.
- Resolver internals may retain `logical_namespace`; request match names remain
  absolute slash addresses.
- Mount metadata uses `{ path, name, desc }`, never `{ namespace => ... }`.

- [ ] **Step 1: Convert constructor tests to the new vocabulary and add absence
  assertions.** Replace every valid `namespace =>` fixture with `name =>`.
  Assert:

  ```perl
  is($known->name, 'people', 'Router mount exposes its local name');
  ok(!$known->can('namespace'), 'public namespace accessor is removed');
  like(dies { mount('/x', router => $child) },
      qr/router mount requires a name/);
  like(dies { mount('/x' => $app, name => 'x') },
      qr/opaque application mounts do not accept name/);
  ```

  Include slash, `.`, `..`, empty, and reference-valued invalid names through
  the shared logical-segment validator.

- [ ] **Step 2: Convert resolver/metadata tests before implementation.** Update
  expected addresses unchanged (`/person/show`) but inspect `Mount->name` and
  metadata `mount->{name}`. Add an assertion that declaration `name` is local
  while matched `match->{name}` is absolute. Retain all duplicate-address,
  relative-reference, repeated-parameter, query, fragment, and sibling Router
  reuse cases.

- [ ] **Step 3: Run the red gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/01-constructors.t t/routing/03-reverse-inspection.t t/routing/12-router-mounts.t t/context/12-routing-reverse.t'
  ```

  Expected before implementation: `name` is rejected as an unknown mount option
  and the old `namespace` accessor remains.

- [ ] **Step 4: Change the immutable Mount storage and validation.** Replace
  `namespace` with `name` in allowed options, Router-mount requirements,
  opaque rejection, stored fields, accessors, diagnostics, and POD. Use the
  existing `_validate_logical_segment('name', ...)`. Update structural-Router
  placement guidance to:

  ```perl
  mount('/prefix', router => $router, name => 'prefix')
  ```

  Remove leaf/Router placeholder `namespace` methods rather than returning
  `undef` from a vocabulary the public model no longer has.

- [ ] **Step 5: Thread local mount names through Resolver and metadata.** In
  `_visit_nodes`, append `$node->name` to child address segments. Store:

  ```perl
  mount => {
      path => $node->path,
      name => $node->name,
      desc => $node->desc,
  }
  ```

  Keep `logical_namespace` as the computed canonical ancestry field. Update
  compiler metadata-copy code only where it reads/writes the public mount
  metadata key; do not alter matching, ownership, captures, or frame version.

- [ ] **Step 6: Convert the large application and integration test.** Change
  only `namespace => 'person'/'blog'` to `name => ...`, change introspection
  from `->namespace` to `->name`, and update explanatory text. Preserve its
  functional `routing` methods, Type::Tiny providers, followed links, lifespan,
  custom blog catchall, and Perl >=5.40 guard.

- [ ] **Step 7: Run the mount/resolver regression matrix.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/01-constructors.t t/routing/03-reverse-inspection.t t/routing/05-generated-outcomes.t t/routing/08-protocols.t t/routing/09-metadata-isolation.t t/routing/12-router-mounts.t t/context/12-routing-reverse.t t/integration-large-application.t'
  ```

  Confirm generated paths, Router ownership, HEAD, protocol decline, and
  metadata isolation are unchanged.

- [ ] **Step 8: Search for stale functional vocabulary and commit.** Run:

  ```bash
  rg -n "namespace" lib/PAGI/Routing.pm lib/PAGI/Routing examples/15-large-application t/routing t/context/12-routing-reverse.t t/integration-large-application.t
  ```

  Remaining hits must be the explicitly documented/internal
  `logical_namespace` term or historical prose that is corrected in Task 9;
  no public constructor/accessor fixture may remain. Stage only Task 2 files
  and commit:

  ```bash
  git add lib/PAGI/Routing/Mount.pm lib/PAGI/Routing/Route.pm lib/PAGI/Routing/Router.pm lib/PAGI/Routing/Resolver.pm lib/PAGI/Routing/Compiler.pm lib/PAGI/Routing.pm t/routing/01-constructors.t t/routing/03-reverse-inspection.t t/routing/05-generated-outcomes.t t/routing/08-protocols.t t/routing/09-metadata-isolation.t t/routing/12-router-mounts.t t/context/12-routing-reverse.t examples/15-large-application/lib/MyApp/Root.pm examples/15-large-application/lib/MyApp/Person.pm examples/15-large-application/lib/MyApp/Person/Blogs.pm examples/15-large-application/README.md examples/15-large-application/GAPS.md t/integration-large-application.t
  git commit -m "Routing: use name for logical mount segments"
  ```

  Update Task 2's ledger row.

---

### Task 3: Build the Ordered Mutable Declaration Core

**Files:**

- Create: `lib/PAGI/App/Router/Builder.pm`
- Create: `t/app-router/01-builder-core.t`
- Create: `t/app-router/02-declaration-package.t`

**Interfaces:**

- `PAGI::App::Router::Builder->new(%router_options)` stores one ordered
  declaration array and top-level `desc`, normalized `middleware`,
  `not_found`, and `method_not_allowed`.
- Public-style declaration methods are `get`, `post`, `put`, `patch`,
  `delete`, `head`, `options`, `any`, generic `route`, `websocket`, and `sse`.
- `_add_route_from($package, $kind, $methods, $path, @arguments)` is the private
  forwarding seam later used by Endpoint Builder.
- Ordinary targets are Context handlers; raw targets use the explicit `raw`
  tag. An optional middleware array immediately precedes either target form.
- `name`, `desc`, and `constraints` mutate only the latest compatible record
  and return the builder.
- `_materialize_nodes($materializer)` converts records in stored order with
  `Route->_new_from($declaration_package, ...)`.
- This task supports leaf nodes only. Group/mount recursion and public
  `to_router` arrive in Task 4; the private core is not documented as public.

- [ ] **Step 1: Write failing constructor and route-record tests.** Load the
  private Builder explicitly. Assert top-level option copying, middleware
  normalization, defensive input arrays/hashes, unknown/odd options, and the
  exact declaration sequence returned by a private `_declarations` test seam.
  Add one call for every verb plus generic/custom method, `any`, WebSocket,
  SSE, normal target, raw target, and positional middleware.

  The expected HTTP mapping is:

  ```perl
  [
      ['GET',     '/get'],
      ['POST',    '/post'],
      ['PUT',     '/put'],
      ['PATCH',   '/patch'],
      ['DELETE',  '/delete'],
      ['HEAD',    '/head'],
      ['OPTIONS', '/options'],
      ['*',       '/any'],
      [['RPC'],   '/rpc'],
  ]
  ```

- [ ] **Step 2: Write failing grammar and modifier tests.** Cover these valid
  forms:

  ```perl
  $b->get('/normal' => $handler);
  $b->get('/wrapped' => [$factory] => $handler);
  $b->get('/raw', raw => $app);
  $b->get('/raw-wrapped' => [$factory], raw => $app);
  $b->route('/rpc' => $handler, methods => ['RPC']);
  ```

  Cover missing target, extra positional values, malformed odd tails, methods
  on WebSocket/SSE, generic route without methods, `raw` without a target,
  non-CODE normal handler, invalid middleware array, and stringified-reference
  option diagnostics. Assert `name`, `desc`, and `constraints` update the last
  route and fail without a preceding compatible declaration.

- [ ] **Step 3: Write failing declaration-package tests.** In separate local
  packages, import the same `Int`-style provider name with different predicates
  and declare routes through every public-style Builder method. Assert
  `_materialize_nodes` builds Patterns that resolve `&Int` in the package that
  called `get`/`route`/`websocket`/`sse`, not in Builder. Include a wrapper sub
  and role-package method to preserve the inline-provider contract.

- [ ] **Step 4: Run the red gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/app-router/01-builder-core.t t/app-router/02-declaration-package.t'
  ```

  Expected: Builder cannot be loaded.

- [ ] **Step 5: Implement constructor and leaf registration.** Use one
  `declarations => []` field and no HTTP/WS/SSE buckets. Each public method
  captures `caller` before delegating:

  ```perl
  sub get {
      my ($self, @args) = @_;
      my $package = caller;
      return $self->_add_route_from($package, 'route', ['GET'], @args);
  }

  sub websocket {
      my ($self, @args) = @_;
      my $package = caller;
      return $self->_add_route_from($package, 'websocket', undef, @args);
  }
  ```

  `route` extracts one required `methods` option after parsing the target;
  `any` stores `'*'`. Do not inject HEAD here; immutable Route normalization is
  authoritative.

- [ ] **Step 6: Implement one target parser.** Parse an optional leading
  middleware array, then either `raw => $target` or one normal target, and then
  the generic route's named method option. Validate positional shape before
  constructing hashes. Normalize middleware immediately through
  `_normalize_descriptors`, shallow-copy constraints, and store:

  ```perl
  {
      node_kind           => 'route',       # route/websocket/sse
      declaration_package => $package,
      path                => $path,
      target              => $target,
      is_raw              => 0,
      methods             => ['GET'],
      middleware          => $descriptions,
      name                => undef,
      desc                => undef,
      constraints         => undef,
  }
  ```

  The private `_declarations` accessor returns defensive top-level/record/list
  copies for tests; no caller receives the live declaration array.

- [ ] **Step 7: Implement last-record modifiers and direct materialization.**
  Validate `name` with `Route::_validate_logical_segment`, `desc` with
  `_validate_text`, and constraints with `_validate_constraints`. Build each
  immutable leaf using the provider branch's private seam:

  ```perl
  PAGI::Routing::Route->_new_from(
      $record->{declaration_package},
      $record->{node_kind},
      $record->{path},
      ($record->{is_raw} ? ('raw', $record->{target}) : ($record->{target})),
      (defined $record->{name} ? (name => $record->{name}) : ()),
      (defined $record->{desc} ? (desc => $record->{desc}) : ()),
      (defined $record->{methods} ? (methods => $record->{methods}) : ()),
      (defined $record->{constraints}
          ? (constraints => $record->{constraints}) : ()),
      middleware => $record->{middleware},
  )
  ```

  Pass no `methods` for WebSocket/SSE.

- [ ] **Step 8: Add private-module POD and run focused tests.** State that the
  module is internal, records configuration only, preserves declaration order,
  captures the caller package, and emits no events. Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/app-router/01-builder-core.t t/app-router/02-declaration-package.t t/routing/01-constructors.t t/routing/02-patterns.t'
  ```

- [ ] **Step 9: Commit and review.** Stage only the new module/tests:

  ```bash
  git add lib/PAGI/App/Router/Builder.pm t/app-router/01-builder-core.t t/app-router/02-declaration-package.t
  git commit -m "App Router: add ordered declaration builder"
  ```

  Review for a single declaration list, absence of protocol I/O, and correct
  caller capture. Update Task 3's ledger row.

---

### Task 4: Add Groups, Mounts, Snapshots, Reuse, Cycles, and Order Proofs

**Files:**

- Create: `lib/PAGI/App/Router/Materializer.pm`
- Modify: `lib/PAGI/App/Router/Builder.pm`
- Create: `t/app-router/03-composition-order.t`
- Create: `t/app-router/04-snapshots-cycles.t`
- Create: `t/app-router/05-middleware-order.t`

**Interfaces:**

- `PAGI::App::Router::Materializer->new->materialize($object, $placement)`
  returns an immutable `PAGI::Routing::Router`.
- It accepts immutable Router, App Builder/App Router, and—after Task 6—an
  Endpoint Router object implementing the private `_materialize_with` seam.
- Mutable identities have one active-ancestry set and one completed map per
  root operation. Sibling reuse returns the same immutable Router identity;
  an active revisit croaks with the placement chain.
- `group($path [=> \@middleware] => sub { my ($child) = @_; ... })` appends one
  inline structural record and invokes the callback with a fresh child
  Builder.
- `mount` supports opaque targets and `router =>` targets. Mutable known targets
  are recursively materialized; immutable targets retain identity.
- `to_router` always creates a new Materializer and fresh root Router.
- `to_app` is exactly `to_router->to_app`.

- [ ] **Step 1: Add failing group/mount shape tests.** Cover a fresh child
  callback (prove it is not the parent), ignored callback return, nested group,
  optional group middleware, opaque mount, immutable Router mount, mutable
  Builder mount, descriptions, constraints, local names, naming an opaque
  mount, package strings, undefined targets, and unsupported blessed objects.
  Assert groups materialize as inline Mount nodes and known mounts as Router
  Mount nodes.

- [ ] **Step 2: Add the mandatory failing declaration-order matrix.** Through
  the public methods on the private Builder, assert actual handler selection
  with `PAGI::Test::Client` for:

  1. `/{slug}` before and after `/about`;
  2. two FULL routes for the same path/method;
  3. GET PARTIAL before POST FULL;
  4. GET/POST sibling declarations producing first-seen `Allow`;
  5. prefix mount before and after a sibling route;
  6. `/` mount before `/api` and the reverse;
  7. groups before, between, and after parent siblings;
  8. mixed HTTP/WebSocket/SSE node order from `to_router->routes`; and
  9. nested child order at two levels.

  Use distinct response bodies/counters so every test proves which handler
  executed. Do not sort expected nodes.

- [ ] **Step 3: Add failing HEAD and middleware order tests.** Declare explicit
  HEAD before GET and the reverse; prove the first FULL behavior and identical
  body-derived headers with wire suppression. Add Router/group/mount/route
  middleware traces proving first-listed-outermost and inner-to-outer build
  order. Include all four middleware entry forms at a route and one short
  circuit.

- [ ] **Step 4: Add failing snapshot/reuse/cycle tests.** Prove mutation after a
  snapshot is invisible to it, two root snapshots have different identities,
  one child Builder mounted twice has one child Router identity inside one
  snapshot, two placements retain distinct path/name metadata, and:

  ```perl
  $a->mount('/b', router => $b)->name('b');
  $b->mount('/a', router => $a)->name('a');
  ```

  fails with `/b -> /a` placement evidence. Add a concurrency test issuing two
  in-flight requests through one app and asserting no capture/match/metadata
  leakage.

- [ ] **Step 5: Run the red gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/app-router/03-composition-order.t t/app-router/04-snapshots-cycles.t t/app-router/05-middleware-order.t'
  ```

  Expected: group, mount, `to_router`, and materializer are absent.

- [ ] **Step 6: Implement Materializer identity control.** Use `refaddr` and
  keep placement labels separately from object state:

  ```perl
  sub materialize {
      my ($self, $target, $placement) = @_;
      return $target if blessed($target)
          && $target->isa('PAGI::Routing::Router');

      my $is_app = blessed($target)
          && $target->isa('PAGI::App::Router::Builder');
      my $is_endpoint = blessed($target)
          && $target->isa('PAGI::Endpoint::Router');
      croak 'router target must be an immutable Router, App Router, or Endpoint Router'
          unless ($is_app || $is_endpoint)
              && $target->can('_materialize_with');

      my $id = refaddr($target);
      return $self->{completed}{$id} if $self->{completed}{$id};
      croak $self->_cycle_message($placement)
          if $self->{active}{$id};

      $self->{active}{$id} = 1;
      push @{$self->{placements}}, $placement;
      my ($router, $error);
      {
          local $@;
          $router = eval { $target->_materialize_with($self) };
          $error = $@;
      }
      pop @{$self->{placements}};
      delete $self->{active}{$id};
      die $error if length $error;
      croak 'mutable router frontend did not materialize a PAGI::Routing::Router'
          unless blessed($router)
              && $router->isa('PAGI::Routing::Router');
      return $self->{completed}{$id} = $router;
  }
  ```

  Do not bless or mutate input Routers. The explicit cleanup must happen before
  rethrow so a caught error cannot leave an active identity or placement on a
  reused Materializer.

- [ ] **Step 7: Implement group and mount records.** Group creates and appends
  the child before invoking the callback, then leaves the group as the parent's
  last declaration. Opaque mount stores its target untouched. Known mount
  stores the Router/frontend object. Reject package-name strings rather than
  invoking `require` or `to_app`. Apply `name` only to route/group/known mount;
  allow `desc` and constraints on all pattern-bearing records.

- [ ] **Step 8: Materialize the ordered graph.** `_materialize_with` walks
  declarations once in array order:

  ```perl
  # group
  PAGI::Routing::Mount->_new_from(
      $record->{declaration_package}, $record->{path},
      routes => $record->{child}->_materialize_nodes($materializer),
      _common_mount_options($record),
  );

  # known mount
  my $child = $materializer->materialize(
      $record->{router}, $record->{path} . ':' . $record->{name},
  );
  PAGI::Routing::Mount->_new_from(
      $record->{declaration_package}, $record->{path},
      router => $child, _common_mount_options($record),
  );
  ```

  Build the root `PAGI::Routing::Router` with stored top-level policy. `to_app`
  must call `to_router` once, then compile that retained snapshot.

- [ ] **Step 9: Run focused order/safety regressions.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/app-router/01-builder-core.t t/app-router/02-declaration-package.t t/app-router/03-composition-order.t t/app-router/04-snapshots-cycles.t t/app-router/05-middleware-order.t t/routing/05-http-dispatch.t t/routing/06-head.t t/routing/09-metadata-isolation.t t/routing/12-router-mounts.t'
  ```

- [ ] **Step 10: Commit and review.** Stage only Task 4 files:

  ```bash
  git add lib/PAGI/App/Router/Materializer.pm lib/PAGI/App/Router/Builder.pm t/app-router/03-composition-order.t t/app-router/04-snapshots-cycles.t t/app-router/05-middleware-order.t
  git commit -m "App Router: materialize ordered routing snapshots"
  ```

  Review every array traversal for order preservation, every recursive edge for
  root-local identity handling, and every request callback for absence of
  builder state. Update Task 4's ledger row.

---

### Task 5: Publish the New `PAGI::App::Router` and Migrate Its Consumers

**Files:**

- Replace: `lib/PAGI/App/Router.pm`
- Create: `t/app-router/06-public-api.t`
- Create: `t/app-router/07-public-reverse-metadata.t`
- Replace or modify: `t/app-router.t`
- Replace or modify: `t/app-router-group.t`
- Modify: `t/app-router-scope-decline.t`
- Replace or modify: `t/router-middleware.t`
- Replace or modify: `t/router-named-routes.t`
- Modify: `t/context/07-router.t`
- Replace or modify: `t/app/03-router.t`
- Modify: `t/sse-router-support.t`
- Modify: `t/integration/sse-decline-end-to-end.t`
- Modify: `t/utils-lifespan.t`
- Modify: `t/lib/TestRoutes/Admin.pm`
- Modify: `t/lib/TestRoutes/Users.pm`
- Modify: `examples/10-chat-showcase/app.pl`
- Modify: `examples/10-chat-showcase/lib/ChatApp/HTTP.pm`
- Modify: `examples/background-tasks/app.pl`
- Modify: `examples/full-demo/app.pl`
- Modify: `examples/endpoint-demo/app.pl`

**Interfaces:**

- Public `PAGI::App::Router` inherits/delegates the complete private Builder
  contract and implements no matching.
- `to_router` returns a fresh immutable Router; `to_app` compiles one snapshot.
- `named_routes`, `route_named`, and `path_for` delegate through a fresh
  snapshot and document the identity cost. `uri_for` is absent.
- Normal HTTP targets receive `$c` and return a Response; normal WebSocket/SSE
  targets receive their Context subclass. Existing native targets use `raw`.
- Public matching, metadata, names, constraints, HEAD, middleware, generated
  outcomes, and order are exactly the shared compiler's behavior.

- [ ] **Step 1: Add failing public facade/surface tests.** Assert App Router is
  a Builder, has `to_router`, `to_app`, `path_for`, `route_named`, and
  `named_routes`, and lacks `uri_for`, `as`, the old public route arrays, and a
  coderef overload. Exercise the same direct/group/mount API through the public
  class and inspect the immutable snapshot.

- [ ] **Step 2: Add failing public dispatch and reverse tests.** Use
  `PAGI::Test::Client` to cover immediate/Future HTTP Responses, raw HTTP,
  WebSocket, raw WebSocket, SSE, raw SSE, named nested routes, relative Context
  links, constraints during dispatch and `path_for`, query/fragment rendering,
  `pagi.routing`, absence of `pagi.router`, custom generated handlers, and
  explicit-HEAD-before-GET.

- [ ] **Step 3: Run the public red gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/app-router/06-public-api.t t/app-router/07-public-reverse-metadata.t'
  ```

  Expected: current public App Router has no `to_router` and invokes ordinary
  handlers with the native three-channel signature.

- [ ] **Step 4: Replace the old matcher with the facade.** Reduce
  `lib/PAGI/App/Router.pm` to the public class over Builder plus complete POD.
  Do not retain old arrays, regex compiler, mount sorter, `_check_constraints`,
  copied name table, `_build_middleware_chain`, or dispatch closure. Public POD
  must show:

  ```perl
  my $r = PAGI::App::Router->new;
  $r->head('/report' => \&head_report);
  $r->get('/report' => [\&audit] => \&get_report)->name('report');
  $r->get('/raw', raw => $native_app);
  $r->mount('/people', router => $people)->name('people');
  my $routing = $r->to_router;
  my $app = $routing->to_app;
  ```

  Document raw route versus mount, snapshot freshness, declaration order,
  FULL/PARTIAL qualification, and all four middleware forms.

- [ ] **Step 5: Migrate existing App tests without preserving obsolete
  behavior.** Replace native helper apps with `$c` Response handlers where the
  test is about routing. Use explicit `raw` where the test is about event
  ownership or protocol decline. Convert `:id` and legacy `*path` spellings to
  the shared Pattern grammar, dotted names to local segments/slash addresses,
  `as`/`namespace` to `name`, `uri_for` to `path_for`, parent-reusing groups to
  fresh child callbacks, and longest-prefix expectations to written order.

  Retire a legacy test file only when its assertions are represented in the
  new focused files; record the old-to-new assertion map in the task ledger
  review note.

- [ ] **Step 6: Migrate non-Endpoint examples that directly use App Router.**
  Keep existing native handlers explicit:

  ```perl
  $router->get('/api/room/{name}/history', raw => $history_app);
  $router->websocket('/ws', raw => $ws_app);
  $router->sse('/events', raw => $sse_app);
  ```

  Convert simple handlers to `$c` only when doing so removes native response
  boilerplate without changing the example's lesson. Put more specific routes
  before broad/root mounts. Do not rewrite prose until Task 9.

- [ ] **Step 7: Run the App consumer regression matrix.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/app-router/01-builder-core.t t/app-router/02-declaration-package.t t/app-router/03-composition-order.t t/app-router/04-snapshots-cycles.t t/app-router/05-middleware-order.t t/app-router/06-public-api.t t/app-router/07-public-reverse-metadata.t t/app-router.t t/app-router-group.t t/app-router-scope-decline.t t/router-middleware.t t/router-named-routes.t t/context/07-router.t t/app/03-router.t t/sse-router-support.t t/integration/sse-decline-end-to-end.t t/utils-lifespan.t t/integration-chat-compose.t t/integration-compose-demo.t'
  ```

  Count actual tests. Confirm no output relies on hash order or sorted mounts.

- [ ] **Step 8: Search for displaced implementation and commit.** Run:

  ```bash
  rg -n "_check_constraints|_build_middleware_chain|longest prefix|pagi\.router|sub uri_for|sub as" lib/PAGI/App/Router.pm t/app-router t/app-router.t t/app-router-group.t t/router-middleware.t t/router-named-routes.t
  ```

  Expected: no displaced code; historical before-text belongs only in the later
  upgrade guide. Stage exactly the Task 5 paths and commit:

  ```bash
  git add lib/PAGI/App/Router.pm t/app-router/06-public-api.t t/app-router/07-public-reverse-metadata.t t/app-router.t t/app-router-group.t t/app-router-scope-decline.t t/router-middleware.t t/router-named-routes.t t/context/07-router.t t/app/03-router.t t/sse-router-support.t t/integration/sse-decline-end-to-end.t t/utils-lifespan.t t/lib/TestRoutes/Admin.pm t/lib/TestRoutes/Users.pm examples/10-chat-showcase/app.pl examples/10-chat-showcase/lib/ChatApp/HTTP.pm examples/background-tasks/app.pl examples/full-demo/app.pl examples/endpoint-demo/app.pl
  git commit -m "App Router: use the shared routing engine"
  ```

  Update Task 5's ledger row after a review comparing the public snapshot to an
  equivalent functional Router.

---

### Task 6: Rebuild `PAGI::Endpoint::Router` as the Method Frontend

**Files:**

- Create: `lib/PAGI/Endpoint/Router/Builder.pm`
- Replace: `lib/PAGI/Endpoint/Router.pm`
- Modify: `cpanfile`
- Replace or modify: `t/endpoint-router.t`
- Delete: `t/endpoint/12-route-middleware-value-flow.t`
- Create: `t/endpoint/12-route-middleware.t`
- Create: `t/endpoint/13-router-frontends.t`

**Interfaces:**

- The base `new` accepts no options and returns an empty instance; configured
  subclasses override `new` with ordinary Perl validation/accessors.
- Endpoint `routes($route_builder)` receives an Endpoint-aware facade over one
  App builder.
- A plain unqualified string in handler position binds an inherited/local
  method on the exact Endpoint instance. A handler coderef is retained
  unmodified and receives only the ordinary Context argument.
- Middleware arrays retain the universal four-form meanings; strings are
  middleware classes.
- `middleware_as($method)` returns a normal factory closure.
- `app_as($method)` returns a normal native app closure.
- `new_context($scope, $receive, $send)` returns `PAGI::Context->new(...)` and
  is not used as the compiler's Context factory.
- Class `to_router`/`to_app` construct one instance; object calls retain that
  object. Nested Endpoint objects materialize in the same root context.
- `state` and `context_class` are absent; no scope state is injected.

- [ ] **Step 1: Replace legacy Endpoint tests with failing surface tests.**
  Assert `new`, `routes`, `to_router`, `to_app`, `middleware_as`, `app_as`, and
  `new_context` exist; `state`, `context_class`, old `_resolve_value_mw`, and
  response-flow `$next` are absent. Test class compilation and configured object
  identity separately.

- [ ] **Step 2: Add failing handler binding tests.** Define Endpoint packages
  with synchronous/Future HTTP methods, WebSocket and SSE methods, inherited
  methods, a role-aliased method, a missing method, a qualified string, and a
  coderef closure. Prove method handlers receive `($self, $c)` while a coderef
  receives only `($c)` and is never rebound. Assert HTTP response validation is
  still the shared compiler's `handler did not return a response` diagnostic.

- [ ] **Step 3: Rewrite the middleware test red-first.** Replace the old
  `$c, $next -> Response` cases with:

  ```perl
  $r->get('/admin' => [
      'RequestId',
      $self->middleware_as('require_auth'),
      $configured_object,
      middleware('Session', cookie_name => 'sid'),
  ] => 'admin');
  ```

  Add compile-time method validation, synchronous app return requirement,
  first-listed-outermost order, downstream call, short circuit, send wrapper,
  cloned scope, immediate/Future downstream completion, and HTTP/WS/SSE parity.

- [ ] **Step 4: Add failing adapter and state tests.** Prove:

  ```perl
  my $factory = $endpoint->middleware_as('auth');
  my $app     = $endpoint->app_as('native');
  my $c       = $endpoint->new_context($scope, $receive, $send);
  ```

  Each method validates unqualified names through `$self->can`, inherited/role
  methods work, helper construction emits no events, `new_context` selects HTTP,
  WebSocket, and SSE subclasses, and overriding it changes only explicit calls.
  Compile a request scope without `state` and assert Endpoint does not seed one;
  compile through Compose lifespan and assert `$c->state` sees the server state.

- [ ] **Step 5: Add failing nested object/reuse/cycle tests.** Root mounts a
  People Endpoint; People mounts Blogs; the three objects provide HTTP,
  WebSocket, and SSE leaves and slash names. Assert absolute/relative
  `path_for`, composed params, handler receiver identity, same-object sibling
  reuse, placement isolation, and a two-Endpoint cycle diagnostic.

- [ ] **Step 6: Run the red gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/endpoint-router.t t/endpoint/12-route-middleware.t t/endpoint/13-router-frontends.t'
  ```

- [ ] **Step 7: Implement the Endpoint route-builder facade.** Capture caller
  at each forwarding method. Parse the handler after an optional middleware
  array. Adapt a string with an exact method CODE:

  ```perl
  my $method = $endpoint->can($name)
      or croak ref($endpoint) . qq{ has no handler method "$name"};
  my $handler = sub {
      my ($context) = @_;
      return $method->($endpoint, $context);
  };
  ```

  Pass coderefs unchanged. Call the App Builder's private
  `_add_route_from($caller, ...)` seam so `&Int` resolves in the Endpoint
  package. Wrap group callbacks with another Endpoint Builder bound to the same
  object. Forward mount and last-declaration modifiers while returning the
  Endpoint Builder for chaining.

- [ ] **Step 8: Implement Endpoint lifecycle and helpers.** On class calls,
  construct `$class->new`; on object calls, preserve the object. Implement
  `_materialize_with($materializer)` by creating one public App Router, invoking
  `routes` synchronously with the Endpoint facade, and asking that App object to
  materialize inside the same context. The base constructor croaks on arguments
  instead of silently discarding configuration; subclasses such as the demo
  define their own constructor. Implement helpers conceptually as:

  ```perl
  sub middleware_as {
      my ($self, $name) = @_;
      my $method = $self->_required_local_method($name, 'middleware');
      return sub { return $method->($self, @_); };
  }

  sub app_as {
      my ($self, $name) = @_;
      my $method = $self->_required_local_method($name, 'application');
      return sub { return $method->($self, @_); };
  }

  sub new_context {
      my ($self, $scope, $receive, $send) = @_;
      require PAGI::Context;
      return PAGI::Context->new($scope, $receive, $send);
  }
  ```

  Delete state injection and custom Context resolution. Remove `Module::Load`
  from `cpanfile` after confirming no remaining source imports it.

- [ ] **Step 9: Write complete Endpoint POD and run regressions.** Document
  class/object lifecycle, nested objects, handler strings versus coderefs,
  four-form middleware, helper phases, ordinary object fields versus lifespan
  state, lack of `context_class`, snapshots, and declaration order. Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/endpoint-router.t t/endpoint/12-route-middleware.t t/endpoint/13-router-frontends.t t/app-router/03-composition-order.t t/app-router/04-snapshots-cycles.t t/routing/08-protocols.t t/context/01-factory.t t/context/03-http.t t/context/04-websocket.t t/context/05-sse.t'
  ```

- [ ] **Step 10: Commit and review.** Stage only Task 6 paths:

  ```bash
  git add lib/PAGI/Endpoint/Router/Builder.pm lib/PAGI/Endpoint/Router.pm cpanfile t/endpoint-router.t t/endpoint/12-route-middleware-value-flow.t t/endpoint/12-route-middleware.t t/endpoint/13-router-frontends.t
  git commit -m "Endpoint Router: bind methods over shared routing"
  ```

  Review that Endpoint contains no matcher, Context sender, response adapter,
  state injection, value-flow chain, or package loader. Update Task 6's ledger
  row.

---

### Task 7: Make the Endpoint Demo the Canonical Nested Example

**Files:**

- Modify: `examples/endpoint-router-demo/lib/MyApp/Main.pm`
- Modify: `examples/endpoint-router-demo/lib/MyApp/API.pm`
- Create: `examples/endpoint-router-demo/lib/MyApp/API/Events.pm`
- Modify: `examples/endpoint-router-demo/app.pl`
- Modify: `examples/endpoint-router-demo/README.md`
- Modify: `t/integration-endpoint-router-demo.t`

**Interfaces:**

- `MyApp::Main`, `MyApp::API`, and `MyApp::API::Events` are explicitly
  constructed nested Endpoint objects.
- Main owns home/static plus root WebSocket; API owns HTTP users and a local
  middleware method; Events owns SSE under the API subtree.
- The app root uses Compose or existing Lifespan with server-owned state; no
  Endpoint object state is mirrored.
- Integration uses `PAGI::Test::Client` to drive startup, HTTP, WebSocket, SSE,
  generated links, custom middleware, and shutdown.

- [ ] **Step 1: Rewrite the integration expectations red-first.** Assert class
  structure lacks `state`, all three classes expose `to_router`, and the root
  immutable Router publishes named leaves such as:

  ```text
  /home
  /api/index
  /api/show
  /api/events/stream
  /status_socket
  ```

  Follow an HTML link from home into API and an API link into an item. Exercise
  API authentication middleware, one WebSocket message, one nested SSE event,
  lifespan state, and an unmatched nested response.

- [ ] **Step 2: Run the red gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-endpoint-router-demo.t'
  ```

  Expected: the current demo mounts `MyApp::API` by package string, has no
  Events object, and advertises the old class surface.

- [ ] **Step 3: Convert Main and API.** Construct child objects explicitly:

  ```perl
  my $events = MyApp::API::Events->new;
  my $api    = MyApp::API->new(events => $events);
  $r->mount('/api', router => $api)->name('api');
  ```

  Use `{user_id}` or `{user_id:&Int}` path grammar, local route names, `$c`
  Response handlers, and `$c->path_for` links. Add one
  `$self->middleware_as('require_demo_token')` route. Keep raw code only where
  the example genuinely demonstrates the native app escape hatch.

- [ ] **Step 4: Add nested HTTP/WS/SSE behavior and lifespan state.** Put
  configuration/metrics in startup state and read them through `$c->state`.
  Ensure shutdown marks/closes the mock resource. Endpoint object fields may
  retain immutable configuration but never receive the scope state hash.

- [ ] **Step 5: Update the README as an exact package walkthrough.** Show the
  file tree, explicit constructors, `routes` hooks, the logical address map,
  `middleware_as`, `new_context` only in native middleware, and the difference
  between ordinary fields and lifespan state. Remove value-flow, package-string,
  `$self->state`, and `context_class` descriptions.

- [ ] **Step 6: Run focused demo and frontend tests.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-endpoint-router-demo.t t/endpoint-router.t t/endpoint/12-route-middleware.t t/endpoint/13-router-frontends.t'
  ```

- [ ] **Step 7: Commit and review.** Stage only demo paths and commit:

  ```bash
  git add examples/endpoint-router-demo/lib/MyApp/Main.pm examples/endpoint-router-demo/lib/MyApp/API.pm examples/endpoint-router-demo/lib/MyApp/API/Events.pm examples/endpoint-router-demo/app.pl examples/endpoint-router-demo/README.md t/integration-endpoint-router-demo.t
  git commit -m "examples: demonstrate nested Endpoint routers"
  ```

  Review the demo against the complete design example rather than merely
  checking responses. Update Task 7's ledger row.

---

### Task 8: Write and Test the Standalone Upgrade Guide

**Files:**

- Create: `UPGRADING.md`
- Create: `t/upgrading-router-frontends.t`
- Modify: `lib/PAGI/App/Router.pm`
- Modify: `lib/PAGI/Endpoint/Router.pm`

**Interfaces:**

- `UPGRADING.md` is user-facing and understandable without internal specs.
- Every changed contract has a concrete before/after example and a one-sentence
  reason.
- Runnable claims are syntax-checked or exercised in
  `t/upgrading-router-frontends.t`.
- App and Endpoint POD link directly to the root guide.

- [ ] **Step 1: Create the migration test red-first.** Add table-driven tests
  for the new side of each guide section: Context HTTP handler, explicit raw,
  path-first generic route, slash names, `name` on known mounts, fresh-child
  group, explicit object mount, declaration-order mounts, four middleware
  forms, Endpoint real middleware/`middleware_as`, lifespan state, nested
  Endpoint, protocol middleware, `pagi.routing`, constraint-aware `path_for`,
  snapshots, and raw route versus mount.

  Add absence assertions for `uri_for`, `as`, public `namespace`, Endpoint
  `state`, and `context_class`. At the end, open `UPGRADING.md` and assert all
  twenty exact section headings from Step 3 are present in order. The test's
  initial red result must therefore be the missing guide file, not missing
  routing behavior already implemented by Tasks 1–7.

- [ ] **Step 2: Run the test before writing prose.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/upgrading-router-frontends.t'
  ```

  Expected: FAIL opening missing `UPGRADING.md`. The executable fixtures should
  already pass; do not weaken them to manufacture a behavior failure and do not
  treat prose grep as the behavioral test.

- [ ] **Step 3: Write the guide with exact before/after pairs.** Use these
  section headings in order:

  1. Choose a frontend: three descriptions, one engine
  2. App handlers now receive `$c`
  3. Ask for native channels with `raw`
  4. Generic `route` is path-first
  5. Names are slash-addressed
  6. `name` replaces `as` and mount `namespace`
  7. Groups receive a fresh child builder
  8. Load and construct packages explicitly
  9. Declaration order now governs routes and mounts
  10. Middleware has four universal forms
  11. Endpoint middleware is native PAGI middleware
  12. Use `middleware_as` for a local middleware method
  13. Use lifespan state through `$c->state`
  14. `context_class` is gone; `new_context` is local only
  15. Mount nested Endpoint objects with `router =>`
  16. Route middleware works for HTTP, WebSocket, and SSE
  17. Read `pagi.routing`, not `pagi.router`
  18. Retain a `to_router` snapshot for stable inspection
  19. Generated paths validate and encode parameters
  20. Raw routes and opaque mounts are different

  The ordering section must accurately say the old router stored separate
  protocol collections, checked routes before mounts, and sorted mounts
  longest-prefix-first; it must not claim ordinary route paths were sorted
  alphabetically.

- [ ] **Step 4: Add migration links to public POD.** Put a short `MIGRATING`
  section in App and Endpoint POD pointing to `UPGRADING.md` in the source
  distribution and summarizing the intentional break. Do not duplicate the
  entire guide into both modules.

- [ ] **Step 5: Verify guide terminology and examples.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/upgrading-router-frontends.t'
  rg -n "uri_for|pagi\.router|context_class|\$self->state|namespace|->as\(" UPGRADING.md
  ```

  Each grep hit must occur in clearly labeled “Before” or “Removed” text, not
  in new instructions.

- [ ] **Step 6: Commit and review.** Stage only guide/test/POD files:

  ```bash
  git add UPGRADING.md t/upgrading-router-frontends.t lib/PAGI/App/Router.pm lib/PAGI/Endpoint/Router.pm
  git commit -m "docs: add router frontend upgrade guide"
  ```

  Review every before claim against the pre-feature code and every after claim
  against a test. Update Task 8's ledger row.

---

### Task 9: Reconcile Public Documentation, Examples, and Release Surface

**Files:**

- Modify: `lib/PAGI/Tools.pm`
- Modify: `lib/PAGI/Tools/Tutorial.pod`
- Modify: `lib/PAGI/Tools/Cookbook.pod`
- Modify: `lib/PAGI/Routing.pm`
- Modify: `lib/PAGI/Compose.pm`
- Modify: `README.md` through the configured `ReadmeAnyFromPod` workflow
- Modify: `Changes`
- Modify: `examples/README.md`
- Modify: `examples/10-chat-showcase/README.md`
- Modify: `examples/full-demo/README.md`
- Modify: `examples/endpoint-demo/README.md`
- Modify: `examples/background-tasks/README.md`
- Modify: `t/00-load.t`

**Interfaces:**

- Public docs consistently present three frontends and one routing engine.
- Middleware docs state compile-time factory/`wrap` and request-time app phases.
- App/Endpoint docs use `$c`, explicit `raw`, local `name`, slash addresses,
  written order, snapshots, and explicit child objects.
- README is regenerated from `lib/PAGI/Tools.pm`; it is not hand-edited as an
  independent source.
- `Changes` records the breaking redesign and links users to `UPGRADING.md`.

- [ ] **Step 1: Inventory stale public claims before editing.** Run:

  ```bash
  rg -n "separate matcher|route-first|mount-last|longest.prefix|native PAGI application|value-flow|\$next|uri_for|pagi\.router|context_class|\$self->state|namespace|->as\(|package name" lib/PAGI/Tools.pm lib/PAGI/Tools/Tutorial.pod lib/PAGI/Tools/Cookbook.pod lib/PAGI/Routing.pm lib/PAGI/Compose.pm README.md Changes examples
  ```

  Save the hit list in Task 9's ledger evidence. Classify each as current API,
  historical release note, unrelated use, or stale claim. Do not mechanically
  replace historical Changes entries.

- [ ] **Step 2: Rewrite the frontend comparison and App recipes.** Tutorial and
  Cookbook must include this conceptual table:

  ```text
  PAGI::Routing          immutable functional declarations   $c handlers
  PAGI::App::Router      mutable imperative builder          verb methods + $c
  PAGI::Endpoint::Router class/role-oriented frontend        local method names
  ```

  State that all three share Pattern, Resolver, Compiler, metadata, constraints,
  HEAD, generated outcomes, and reverse routing. Convert App recipes to shared
  path syntax, Context handlers, explicit raw, written order, and four-form
  middleware.

- [ ] **Step 3: Rewrite the Endpoint Cookbook section.** Keep the class-based
  cookbook substantial: HTTP, WebSocket, SSE, ordinary fields, lifespan state,
  nested Endpoint objects, local handler strings, coderef closures,
  `middleware_as`, `app_as`, `new_context`, route middleware, relative links,
  and complete Compose root. Remove every response-valued `$next`, package
  string, `$self->state`, and `context_class` example.

- [ ] **Step 4: Reconcile Routing/Compose and example READMEs.** Remove claims
  that declarative routing is a separate matcher rather than another frontend.
  Explain that Compose remains the optional lifespan/application root. Update
  example endpoint lists from `:name` to `{name}`, mark native handlers `raw`,
  and explain declaration order where a root/static mount is last.

- [ ] **Step 5: Update front-page POD, load coverage, and Changes.** Link
  `UPGRADING.md`; present the three frontends; add new internal modules to
  `t/00-load.t`; remove `Module::Load` narrative; and add an unreleased Changes
  entry that explicitly calls the redesign breaking and points to the guide.
  Preserve earlier historical entries as historical facts unless they assert
  the current API outside their release section.

- [ ] **Step 6: Regenerate README and validate POD.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && dzil build'
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && podchecker lib/PAGI/App/Router.pm lib/PAGI/Endpoint/Router.pm lib/PAGI/Routing.pm lib/PAGI/Compose.pm lib/PAGI/Tools.pm lib/PAGI/Tools/Tutorial.pod lib/PAGI/Tools/Cookbook.pod'
  ```

  `dzil build` must regenerate `README.md` from Tools POD and complete without
  running the full test suite. Do not stage a generated distribution directory
  or tarball.

- [ ] **Step 7: Run documentation-owned focused tests.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/00-load.t t/upgrading-router-frontends.t t/integration-endpoint-router-demo.t t/integration-large-application.t t/integration-chat-compose.t t/integration-compose-demo.t'
  ```

- [ ] **Step 8: Repeat the stale-claim audit.** Run the Step 1 `rg` command
  again. Remaining hits must be historical before/upgrade text, internal
  `logical_namespace`, or unrelated concepts. Record the explanation for each
  remaining current-file hit in the ledger review.

- [ ] **Step 9: Commit and review.** Stage only paths actually changed from the
  Task 9 inventory, naming them explicitly; never stage a build directory. The
  minimum command is:

  ```bash
  git add lib/PAGI/Tools.pm lib/PAGI/Tools/Tutorial.pod lib/PAGI/Tools/Cookbook.pod lib/PAGI/Routing.pm lib/PAGI/Compose.pm README.md Changes examples/README.md examples/10-chat-showcase/README.md examples/full-demo/README.md examples/endpoint-demo/README.md examples/background-tasks/README.md t/00-load.t
  git commit -m "docs: unify router frontend guidance"
  ```

  Review generated README against Tools POD, not as an independent rewrite.
  Update Task 9's ledger row.

---

### Task 10: Final Scope, Distribution, and Repository Verification

**Files:**

- Modify only if a failing verification exposes an in-scope defect: the file
  that owns that defect and its closest focused test
- Update outside Git: the Task 10 row in
  `.superpowers/sdd/2026-08-10-unified-router-frontends/progress.md`

**Interfaces:**

- Final reviewed HEAD satisfies every acceptance criterion in the design.
- Exactly one successful repository-wide suite is recorded for that HEAD.
- Distribution build/POD/load checks pass without `dzil test`.
- No unrelated or generated artifacts are staged.

- [ ] **Step 1: Audit commits and file scope.** Record:

  ```bash
  /bin/bash -lc 'pagi_router_start=$(cat .superpowers/sdd/2026-08-10-unified-router-frontends/starting-head); test -n "${pagi_router_start:?missing starting HEAD}"; git cat-file -e "${pagi_router_start}^{commit}"; git log --oneline --decorate "${pagi_router_start}..HEAD"; git diff --stat "${pagi_router_start}..HEAD"; git diff --name-status "${pagi_router_start}..HEAD"; git status --short'
  ```

  Confirm every path belongs to middleware normalization, immutable naming, mutable App
  materialization, Endpoint binding, tests, examples, migration docs, public
  docs, dependency cleanup, or generated README. Confirm the three unrelated
  report files are untracked and absent from every commit.

- [ ] **Step 2: Audit the one-engine invariant.** Run:

  ```bash
  rg -n "_compile_path|_check_constraints|_build_middleware_chain|longest.prefix|pagi\.router|_resolve_value_mw|context_class|sub state" lib/PAGI/App/Router.pm lib/PAGI/App/Router lib/PAGI/Endpoint/Router.pm lib/PAGI/Endpoint/Router
  ```

  Expected: no independent matcher, value-flow middleware, Endpoint state, or
  custom dispatch Context. Hits in explanatory removed-API POD must be clearly
  labeled migration text.

- [ ] **Step 3: Audit exact creation order and universal middleware coverage.**
  Run the focused public behavior matrix one last time before the full suite:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/11-bare-middleware.t t/app-router/03-composition-order.t t/app-router/04-snapshots-cycles.t t/app-router/05-middleware-order.t t/app-router/06-public-api.t t/app-router/07-public-reverse-metadata.t t/endpoint-router.t t/endpoint/12-route-middleware.t t/endpoint/13-router-frontends.t t/upgrading-router-frontends.t'
  ```

  Verify the output includes every section 9.4 order case: static/dynamic both
  orders, same FULL, PARTIAL then FULL, first-seen Allow, route/mount both
  orders, broad/specific mounts both orders, parent/group positions, mixed
  protocol inspection, and nested order.

- [ ] **Step 4: Verify load, POD, packaging, and diff hygiene.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/00-load.t'
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && podchecker lib/PAGI/App/Router.pm lib/PAGI/Endpoint/Router.pm lib/PAGI/Routing.pm lib/PAGI/Compose.pm lib/PAGI/Tools.pm lib/PAGI/Tools/Tutorial.pod lib/PAGI/Tools/Cookbook.pod'
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && dzil build'
  /bin/bash -lc 'pagi_router_start=$(cat .superpowers/sdd/2026-08-10-unified-router-frontends/starting-head); test -n "${pagi_router_start:?missing starting HEAD}"; git diff --check "${pagi_router_start}..HEAD"'
  ```

  Inspect the build output/MANIFEST for the two new private modules and
  `UPGRADING.md`. Do not run `dzil test`.

- [ ] **Step 5: Run the repository-wide suite once at final reviewed HEAD.**
  Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t'
  ```

  Record the exact HEAD, exit status, elapsed time, Files count, Tests count,
  and final result. Do not repeat it unchanged. If it fails, record the failure,
  use `superpowers:systematic-debugging`, add a failing focused regression,
  make the smallest in-scope correction, commit it, review it, and then run one
  new final suite at the changed HEAD.

- [ ] **Step 6: Perform the spec/non-goal audit.** Walk sections 1–21 of the
  design and cite the owning task/test for each requirement in Task 10's ledger
  review. Explicitly confirm no 404/405 redesign, third-party Context routing
  contract, `PAGI::App` base, package discovery, `auto_head`, value-flow tier,
  snapshot cache, or coderef overload entered the diff.

- [ ] **Step 7: Close the ledger and report.** Mark every row complete only
  after its SHA, exact verification, and review are present. Resolve every
  deviation with the user's recorded decision. Report final commit range,
  successful full-suite counts, packaging/POD evidence, upgrade-guide path,
  and preserved unrelated files. Do not create an empty verification commit.

## Completion Criteria

The plan is complete only when all ten ledger rows say `complete`, every
implementation commit passed its review gate, all three frontends compile
through one immutable model/compiler, the exact written order is proven
behaviorally, all middleware positions share four forms, Endpoint has no
value-flow/state/context-class layer, `UPGRADING.md` covers every break, public
docs/examples agree, one final repository-wide suite passes at reviewed HEAD,
packaging/POD pass without a second suite, and the unrelated user files remain
untouched.
