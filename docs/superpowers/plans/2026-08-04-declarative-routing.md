# Declarative Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the approved `PAGI::Routing` declarative route-tree API, including
immutable route objects, declaration-ordered matching, Context handlers, raw
PAGI escape hatches, mounts, pure middleware, reverse routing, matched-route
metadata, inspection, and complete user documentation.

**Architecture:** `PAGI::Routing` is the public constructor/export layer.
Immutable `Router`, `Route`, `Mount`, and `Middleware` descriptions retain only
configuration. `Pattern` compiles and validates path syntax, `Resolver` builds
the effective named-route index, and `Compiler` turns any executable routing
object into one native PAGI application. Compilation resolves middleware and
components once; request-local matching and metadata remain in lexical state
and shallow scope clones. `PAGI::Context` delegates request-aware reverse
routing to the resolver stored in the last `pagi.routing` frame, and the
resolver delegates authority validation and fallback to `PAGI::Authority`.

**Tech Stack:** Perl 5.18-compatible source, `Future`, `Future::AsyncAwait`,
`Test2::V0`, existing PAGI Authority/Context/Response/WebSocket/SSE components,
and the existing `PAGI::Utils::to_app`/`is_response` contracts. No new required
runtime dependency.

## Global Constraints

- The approved design is the source of truth:
  `docs/superpowers/specs/2026-08-03-declarative-routing-design.md`.
- The approved authority implementation plan
  `docs/superpowers/plans/2026-08-04-authority-validation.md` is a prerequisite.
  Its final verification and ledger must be complete before Routing Task 1;
  routing code must consume the shipped `PAGI::Authority` API rather than
  copying Host scans, authority grammar, or server fallback logic.
- Work only in `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools`.
- Preserve the unrelated untracked files `.cpan-testers-fix-report.md`,
  `.csrf-helper-brief.md`, and `.csrf-helper-report.md`. Never stage them.
- Use classic argument unpacking (`my ($self, $value) = @_`) in shipped code and tests.
  The distribution supports Perl 5.18; do not use signatures, postfix
  dereferencing, `try`/`catch`, or other newer syntax.
- Use hand-written blessed hashes, `strict`, `warnings`, `Carp`, and the
  repository's existing style. Do not introduce Moo, Moose, Role::Tiny, URI,
  or a hard Type::Tiny dependency.
- Public collections are defensive shallow copies. Request-specific state must
  never be stored on source routing descriptions or shared compiled matchers.
- The only middleware contract in this API is app-to-app PAGI middleware.
  Do not add a request-time four-argument `$next` form or copy
  `PAGI::Endpoint::Router`'s value-flow middleware.
- Do not change existing `PAGI::Context`/`PAGI::Response` vocabulary, state, or
  header behavior described in the extracted compatibility design.
- Do not extend `ReverseProxy` or `TrustedHosts` to WebSocket/SSE, fix file
  containment, or change `PAGI::App::Router` HEAD/Allow behavior in this work.
  Those are separately tracked compatibility/security changes.
- Keep `PAGI::App::Router` and `PAGI::Endpoint::Router` supported and
  unchanged. `PAGI::Routing` is additive and uses its own matcher.
- Follow TDD for every behavior task: write the smallest focused failing test,
  run it and observe the expected failure, implement, rerun the focused test,
  then run the relevant neighboring tests.
- Capture intentional errors with `dies`/`warnings`; test output must remain
  clean. Use stable diagnostic fragments rather than line numbers.
- Put POD beside every new public constructor, accessor, option, Context
  method, and middleware helper in the same task that introduces it.
- Use `PAGI::Utils::to_app($target)` fully qualified inside routing modules so a
  method named `to_app` cannot collide with an imported function.
- Each task ends in a focused commit after its tests pass. Stage named files,
  never `git add -A` or `git add .`.
- Before Task 1, both execution modes must run the
  `superpowers:subagent-driven-development` skill's `scripts/sdd-workspace`
  helper for this plan and create the canonical plan-scoped
  `.superpowers/sdd/2026-08-04-declarative-routing/progress.md`. Its first line
  must be:

  ```text
  # SDD ledger — plan: docs/superpowers/plans/2026-08-04-declarative-routing.md
  ```

  Maintain one row per task using this schema:

  ```text
  Task | Status | Commit range | Focused verification | Full-suite verification | Review
  ```

  Status is `pending`, `in_progress`, `complete`, or `blocked`. Verification
  cells contain the exact command, exit status, and actual test count observed
  by the coordinator, not an estimate or an unsupported implementer summary.
  After the implementation commit and required review, the coordinator verifies
  the commit range, independently runs the required verification, updates the
  row, appends the skill-compatible `Task <N>: complete (...)` recovery line,
  and only then advances to the next task.
- The same ledger contains a deviation table with this schema:

  ```text
  ID | Status | Conflicting plan text | Evidence and rationale | Affected tasks | User decision
  ```

  Use stable IDs such as `DEV-001`. A proposed deviation blocks every task that
  would build on it. It becomes `approved` only after the user's explicit
  decision is recorded; rejected or superseded entries remain in the ledger
  rather than being silently removed. The controller, not an implementation
  subagent, owns ledger and deviation updates.
- Run Perl commands through the project Perl:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/01-constructors.t'
  ```

- Run the whole suite after each compiler/dispatch task and before claiming
  completion:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t'
  ```

---

### Task 1: Public constructors and immutable descriptions

**Files:**

- Create: `lib/PAGI/Routing.pm`
- Create: `lib/PAGI/Routing/Router.pm`
- Create: `lib/PAGI/Routing/Route.pm`
- Create: `lib/PAGI/Routing/Mount.pm`
- Create: `lib/PAGI/Routing/Middleware.pm`
- Create: `t/routing/01-constructors.t`
- Modify: `t/00-load.t`

**Interfaces:**

- Consumes: plain constructor argument lists from `PAGI::Routing`.
- Produces: `router(%opts)`, `route($path => $handler, %opts)`,
  `route($path, raw => $app, %opts)`, corresponding `websocket`/`sse` forms,
  `mount($path => $app, %opts)`, `mount($path, routes => \@nodes, %opts)`, and
  `middleware($factory_or_object_or_class, %config)`.
- Produces export tags `:routes`, `:middleware`, and uppercase `:ALL`; nothing
  is exported by default.
- Produces read-only description accessors. `Route` represents all three leaf
  kinds and returns `route`, `websocket`, or `sse` from `kind`. `Mount` returns
  `mount`. An application mount reports `is_raw => 1`; an inline mount reports
  `is_raw => 0`.
- Defers executable compilation to `PAGI::Routing::Compiler->compile($object)`;
  Task 5A supplies its leaf/selection core and Task 5B completes the public
  method.

- [ ] **Step 1: Add failing export tests.** Verify a package using
  `PAGI::Routing ()` receives none of the six functions; `:routes` exports five
  routing constructors, `:middleware` exports only `middleware`, and `:ALL`
  exports all six. Verify lowercase `:all` is rejected.

  ```perl
  {
      package NoImports;
      use PAGI::Routing ();
  }

  ok(!NoImports->can('route'), 'no default route export');

  {
      package RouteImports;
      use PAGI::Routing qw(:routes);
  }

  ok(RouteImports->can('router'), 'routes tag exports router');
  ok(RouteImports->can('mount'), 'routes tag exports mount');
  ok(!RouteImports->can('middleware'), 'routes tag excludes middleware');
  ```

- [ ] **Step 2: Add failing constructor/accessor tests.** Cover every normal
  and raw leaf form, both mount forms, `desc`, `name`, `namespace`, normalized
  methods, middleware collection copies, constraint hash copies, target
  identity, and router route copies. Cover every common accessor (`kind`,
  `path`, `name`, `desc`, `middleware`, `is_raw`, and `target`), HTTP-only
  `methods`/`constraints`, and mount-only
  `namespace`/`constraints`/`routes`; an inapplicable accessor
  returns `undef`. Assert that modifying a returned arrayref/hashref does not
  alter a later accessor result. Accept empty descriptions as strings, but
  reject reference-valued descriptions and empty/reference names/namespaces.

- [ ] **Step 3: Pin validation failures.** Assert clear croaks for no target,
  positional-plus-raw, mount target-plus-routes, unknown options, invalid
  `methods` shape, an empty method collection, `methods` on WebSocket/SSE,
  non-array `routes`/`middleware`, invalid `desc`/`name`/`namespace`, and a
  non-node in a route list. Normal Context handlers and HTTP fallback handlers
  must be coderefs; only raw/application positions use `PAGI::Utils::to_app`.
  Every entry in a routing object's `middleware` array must be an object
  returned by the `middleware` constructor; reject bare factories/objects
  there so coderef meaning remains position-driven and explicit.
  Use these stable fragments:

  ```text
  route requires exactly one of handler or raw
  mount requires exactly one of target or routes
  unknown route option
  methods must be a method string, arrayref, or '*'
  WebSocket routes do not accept methods
  routes must contain PAGI::Routing nodes
  ```

- [ ] **Step 4: Implement the Exporter front door.** Keep all six constructors
  as thin adapters that load and instantiate the appropriate description.
  Use `@EXPORT_OK` and `%EXPORT_TAGS`, with no `@EXPORT`.

  ```perl
  our @EXPORT_OK = qw(router route websocket sse mount middleware);
  our %EXPORT_TAGS = (
      routes     => [qw(router route websocket sse mount)],
      middleware => [qw(middleware)],
      ALL        => [@EXPORT_OK],
  );
  ```

- [ ] **Step 5: Implement immutable description classes.** Copy collection
  arguments at construction and on access. Keep constructor parsing in the
  relevant class, reject unknown keys through an allowlist, and expose no
  mutators. Normalize methods to uppercase and deduplicate while inserting
  automatic HEAD immediately after a first GET. Accept nonempty HTTP token
  strings, including extension methods such as `RPC`; reject whitespace and
  separators. Preserve `'*'` as the scalar `'*'`; otherwise `methods` returns
  an arrayref copy.

- [ ] **Step 6: Add the explicit compilation boundary.** Give `Router`,
  `Route`, and `Mount` this method, but do not add overloads:

  ```perl
  sub to_app {
      my ($self) = @_;
      require PAGI::Routing::Compiler;
      return PAGI::Routing::Compiler->compile($self);
  }
  ```

  Test `overload::Method($object, '&{}')` is false and a `Middleware`
  descriptor has no `to_app` method.

- [ ] **Step 7: Add `PAGI::Routing` and the four description modules to the
  public load list.** Task 4 adds `PAGI::Middleware::Helpers` after its file
  exists. Run `t/routing/01-constructors.t` and `t/00-load.t`.

- [ ] **Step 8: Commit** the constructor/object slice with message
  `Routing: add declarative constructors and immutable nodes`. After commit and
  task review, complete Task 1's canonical ledger row and recovery line with
  coordinator-verified evidence before Task 2 begins.

---

### Task 2: Path parsing, matching, wildcards, and constraints

**Files:**

- Create: `lib/PAGI/Routing/Pattern.pm`
- Create: `t/routing/02-patterns.t`
- Modify: `lib/PAGI/Routing/Route.pm`
- Modify: `lib/PAGI/Routing/Mount.pm`

**Interfaces:**

- Consumes: decoded route/mount pattern, pattern kind (`route` or `mount`), and
  explicit constraint hash.
- Produces: `PAGI::Routing::Pattern->new(path => $path, mode => $mode,
  constraints => \%constraints)`.
- Produces: `match_route($decoded_path) -> \%captures | undef` and
  `match_mount($decoded_path) -> { captures => \%captures, consumed => $prefix,
  remainder => $path } | undef`.
- Produces: `render(\%params, $route_name) -> $encoded_path`, `parameters ->
  \@names`, `constraints -> \%copy`, and `path -> $normalized_declared_path`.
- A constraint receives exactly the decoded scalar value. Regex and inline
  constraints use `\A(?:$pattern)\z`. Predicate and `check` values are never
  used as coercions.

- [ ] **Step 1: Write failing literal/parameter tests.** Cover exact `/users`
  versus `/users/`, `{id}`, legacy `:id`, percent-decoded values supplied in
  `$scope->{path}`, duplicate parameters within one pattern, leading slash
  enforcement, and literal regex metacharacters.

- [ ] **Step 2: Write failing wildcard tests.** Pin one terminal whole-segment
  wildcard, empty capture for `/files/` and `/`, internal separators, no match
  for `/files`, and croaks for embedded, nonterminal, or repeated wildcards.
  Verify decoded values such as `../private//key` are returned unchanged.

  ```perl
  my $files = PAGI::Routing::Pattern->new(
      path => '/files/*path', mode => 'route', constraints => {},
  );

  is($files->match_route('/files/'), { path => '' }, 'wildcard may be empty');
  is($files->match_route('/files/a/b'), { path => 'a/b' }, 'wildcard keeps slash');
  ok(!defined $files->match_route('/files'), 'separator remains exact');
  ```

- [ ] **Step 3: Write failing mount tests.** Verify segment boundaries,
  `/api` and `/api/` normalization, exact-prefix remainder `/`, parameterized
  prefixes, root mount consuming nothing, and mount wildcard rejection.

- [ ] **Step 4: Write failing constraint tests.** Cover explicit regex,
  `{id:\d+}` through the identical matcher, literal and percent-decoded
  trailing newlines, synchronous false/true predicates, thrown exceptions,
  a Future-returning predicate, and a small blessed Type::Tiny-compatible
  fixture implementing `check` and `get_message`. When inline and explicit
  constraints target the same capture, require both to pass. Verify every
  predicate receives only the captured string, never Context. Also reject
  constraint names not declared in the pattern.

- [ ] **Step 5: Implement tokenization without interpolating a full route into
  source code.** Build quoted literal fragments plus capture fragments, compile
  the final route regex with `\A`/`\z`, and keep a token list for rendering.
  At `Pattern` construction, normalize every explicit constraint into an
  internal checker record. Convert each explicit `Regexp` to one anchored
  `qr/\A(?:$constraint)\z/`; retain predicate coderefs and `check` objects by
  reference; reject invalid constraint types immediately. Compile inline regex
  text to the same anchored-regex representation. When inline and explicit
  constraints target one parameter, retain both checker records in
  declaration-defined order. Keep the declared values separately for the
  defensive public `constraints` accessor.

- [ ] **Step 6: Implement the constraint protocol.** For each captured value:

  ```perl
  my $accepted;
  if ($checker->{kind} eq 'regexp') {
      $accepted = $value =~ $checker->{regexp} ? 1 : 0;
  } elsif ($checker->{kind} eq 'predicate') {
      $accepted = $checker->{value}->($value);
  } elsif ($checker->{kind} eq 'check') {
      $accepted = $checker->{value}->check($value);
  }

  croak 'route constraints must be synchronous; got Future'
      if blessed($accepted) && $accepted->isa('Future');
  ```

  Iterate the construction-time checker list, returning no match on its first
  false result. Let thrown exceptions propagate. Never replace the capture with
  a transformed value. Reuse the same checker records when validating reverse
  rendering; never compile a regex in either request-time path.

- [ ] **Step 7: Implement URI component rendering.** Encode UTF-8 bytes with
  uppercase `%HH`; leave only RFC 3986 unreserved bytes literal. Encode normal
  parameters as one segment. For wildcards, split while retaining empty
  components, encode each component, and rejoin with `/`. Reject missing and
  extra path params and run constraints against the unencoded input before
  rendering.

- [ ] **Step 8: Attach one `Pattern` to each leaf/mount at construction.** Keep
  it private; public `path`, `constraints`, and parameter inspection come from
  defensive description accessors. Run `t/routing/01-constructors.t` and
  `t/routing/02-patterns.t`.

- [ ] **Step 9: Commit** with message
  `Routing: compile exact paths, wildcards, and constraints`. After commit and
  task review, complete Task 2's canonical ledger row and recovery line with
  coordinator-verified evidence before Task 3 begins.

---

### Task 3: Effective names, reverse paths, and tree inspection

**Files:**

- Create: `lib/PAGI/Routing/Resolver.pm`
- Create: `t/routing/03-reverse-inspection.t`
- Modify: `lib/PAGI/Routing/Router.pm`
- Modify: `lib/PAGI/Routing/Mount.pm`

**Interfaces:**

- Consumes: one router's direct node list and inline mount ancestry.
- Produces: `PAGI::Routing::Resolver->new(routes => \@nodes)` with a private
  declaration-ordered record for each named leaf.
- Produces: `path_for($name, \%path_params, \%query_params)`,
  `route_kind($name)`, and internal effective pattern/name metadata.
- Produces: router `routes`, `named_routes`, `route_named`, and `path_for`.
  `named_routes` maps effective names to original immutable leaf objects.
- Application mounts are opaque and do not contribute child names.

- [ ] **Step 1: Write failing direct and inline reverse tests.** Cover direct
  names, unnamed mounts leaving names unprefixed, explicit dot namespaces,
  nested namespaces, path prefixes independent of namespaces, dynamic mount
  parameters, query keys sorted for deterministic output, query value
  escaping, wildcard generation, missing/extra path parameters, and constraint
  failures. Verify a Type::Tiny-compatible reverse failure uses `get_message`
  in a route-name-specific diagnostic.

- [ ] **Step 2: Write failing collision tests.** Cover two direct duplicate
  names, two unnamed mounts exposing the same child name, a collision created
  by equal namespaces, and duplicate parameter names across a known inline
  mount/route ancestry. Diagnostics must name both effective paths and tell the
  caller to add or change a namespace.

- [ ] **Step 3: Write failing inspection tests.** Verify `routes` is only the
  direct child list in declaration order, inline `mount->routes` is recursively
  inspectable, app mounts return `undef` from `routes`, `route_named` returns
  the original leaf, and mutation of returned hashes/arrays does not affect
  later calls.

- [ ] **Step 4: Implement the resolver traversal.** Carry three values through
  inline mounts: effective path prefix, dot-name prefix, and ordered outer
  parameter names/constraints. For a leaf, concatenate patterns without
  normalizing route slashes, join only nonempty namespaces/names with `.`, and
  record the original node plus the complete render token sequence.

- [ ] **Step 5: Implement `path_for`.** Default missing parameter/query hashes
  to empty hashes, require hashrefs, render the named record, then append a
  deterministic query string. Treat query values as scalar strings; reject
  references with `query parameter '$key' must be a scalar` and render an
  undefined scalar as an empty value. Return only the application path, never
  `root_path`, scheme, or authority.

- [ ] **Step 6: Construct and retain the resolver in `Router->new`.** Delegate
  router inspection/reverse methods to it. Preserve source node identity in
  `named_routes`; do not return internal reverse records.

- [ ] **Step 7: Run the three routing test files. Commit** with message
  `Routing: add namespaced reverse paths and tree inspection`. After commit and
  task review, complete Task 3's canonical ledger row and recovery line with
  coordinator-verified evidence before Task 4 begins.

---

### Task 4: Pure middleware descriptors and authoring helpers

**Files:**

- Create: `lib/PAGI/Middleware/Helpers.pm`
- Create: `t/middleware/helpers.t`
- Create: `t/routing/04-middleware-descriptors.t`
- Modify: `lib/PAGI/Routing/Middleware.pm`
- Modify: `t/00-load.t`

**Interfaces:**

- Consumes: `clone_scope($scope, \%changes)`, `wrap_send($send, $interceptor)`,
  and `wrap_receive($receive, $interceptor)`.
- Produces: a new shallow scope or a callback for later request-time I/O.
- Consumes middleware descriptor targets: synchronous factory coderef,
  configured object with `wrap`, or class name plus constructor configuration.
- Produces internally: `$descriptor->_wrap($inner_app) -> $outer_app` and
  `PAGI::Routing::Middleware->_wrap_descriptors(\@descriptors, $inner_app) ->
  $outer_app`. `_wrap_descriptors` performs the reverse fold so the first
  descriptor listed is outermost. Compiler code uses this shared builder for
  router, mount, and route middleware rather than implementing its own loop.

- [ ] **Step 1: Write failing helper validation/lifecycle tests.** Verify no
  default exports, explicit exports, defensive shallow scope clone, shared
  referenced values, argument validation, no send/receive call during wrapper
  construction, event replacement/drop/expansion, repeated receive filtering,
  immediate and Future interceptor results, and propagated exceptions.

  ```perl
  my $wrapped = wrap_send($send, async sub {
      my ($event, $downstream) = @_;
      return if $event->{type} eq 'app.drop';
      await $downstream->({ %$event, inspected => 1 });
  });
  ```

- [ ] **Step 2: Implement `PAGI::Middleware::Helpers`.** Export nothing by
  default. `clone_scope` returns `{ %$scope, %$changes }`. The wrappers are
  async callbacks that call only their interceptors; they do not delegate
  automatically or inspect event types. Invoke each interceptor in scalar
  context, then normalize its immediate-or-Future result before awaiting it:

  ```perl
  my $returned = $interceptor->(@args);
  return await Future->wrap($returned);
  ```

  Load `Future` explicitly. This preserves immediate values, leaves an existing
  Future unchanged, and lets synchronous exceptions propagate normally.

- [ ] **Step 3: Write failing descriptor and chain-builder tests.** Exercise
  first-listed-outermost ordering through the production
  `_wrap_descriptors` method, including an empty list and three observable
  wrappers. Cover factory invocation once per compiled wrapper, configured
  object identity, class auto-load and `new(%config)->wrap($app)`, non-code
  factory results, a Future returned by an accidental async factory, object
  without `wrap`, class/config plus object rejection, and a factory exception.

- [ ] **Step 4: Implement descriptor resolution.** A class string beginning
  with `PAGI::Middleware::` is already fully qualified. For parity with
  Builder, a simple/nested short name gets that prefix and a leading `^`
  selects a caller-owned fully qualified class. Resolve and instantiate during
  `to_app`, never per request. Implement `_wrap_descriptors` as the one shared
  reverse fold and validate every intermediate `wrap` result as `CODE`.

- [ ] **Step 5: Document lifecycle precisely.** In helper POD, state that
  construction is synchronous and does no I/O, wrapped callbacks run only when
  called, downstream completion/backpressure remains attached only when the
  interceptor returns or awaits it, and the wrappers may observe any event
  family the enclosing middleware receives.

- [ ] **Step 6: Add `PAGI::Middleware::Helpers` to `t/00-load.t`.**
  `PAGI::Routing` was added in Task 1. Run the focused middleware tests plus
  `t/middleware/00-base.t` and
  `t/middleware-builder-resolution.t` to prove the existing OO/Builder surfaces
  are unchanged.

- [ ] **Step 7: Commit** with message
  `Middleware: add declarative descriptors and channel helpers`. After commit
  and task review, complete Task 4's canonical ledger row and recovery line
  with coordinator-verified evidence before Task 5A begins.

---

### Task 5A: Compile HTTP leaves and declaration-order selection

**Files:**

- Create: `lib/PAGI/Routing/Compiler.pm`
- Create: `t/routing/05-http-dispatch.t`
- Modify: `lib/PAGI/Routing/Router.pm`
- Modify: `lib/PAGI/Routing/Route.pm`
- Modify: `lib/PAGI/Routing/Mount.pm`

**Interfaces:**

- Consumes: HTTP route descriptions, compiled Patterns, and middleware
  descriptors. Public `Compiler->compile` remains deliberately unwired until
  Task 5B.
- Produces internally:
  `PAGI::Routing::Compiler->_compile_http_leaf($route) -> CODE` and
  `_select_http($compiled_entries, $scope) -> $decision`.
- A decision is one newly allocated request-local hashref of exactly one shape:

  ```perl
  { kind => 'full', app => $compiled_leaf, scope => $matched_scope }
  { kind => 'partial', allowed_methods => \@first_seen }
  { kind => 'none' }
  ```

  The compiled leaf is immutable/shareable; the decision, matched scope,
  path-parameter hash, and ordered method array are request-local.
- Normal HTTP adapter: `handler($c) -> PAGI::Response | Future`; validates with
  `PAGI::Utils::is_response`, then calls `$c->respond($response)` exactly once.
- Raw HTTP adapter: `app($scope, $receive, $send)` after
  `PAGI::Utils::to_app`; the resolved value is ignored.
- Produces HTTP declaration-order FULL/PARTIAL/no-match selection and
  first-seen allowed-method data. It does not synthesize a fallback response or
  an `Allow` header.

- [ ] **Step 1: Write failing handler-contract tests.** Cover synchronous
  Response, Future-resolved Response, `$c` path params, raw application channel
  ownership, exactly one response, `undef`/scalar/wrong object diagnostics,
  manual `$c->respond` followed by `undef`, and manual respond plus returned
  Response producing the existing `response already sent` error. Verify thrown
  handler exceptions and failed Futures propagate instead of becoming 500
  responses.

- [ ] **Step 2: Write failing decision-selection tests.** Exercise the
  production `_select_http` decision builder. Cover default GET,
  automatic HEAD as a normalized match, scalar/array methods, `'*'`, no
  automatic OPTIONS, strict declaration order, a later full match beating an
  earlier partial, constraints converting a candidate to no match, and a true
  catch-all route beating an earlier partial match. Assert exact `full`,
  `partial`, and `none` record shapes without testing response events.

- [ ] **Step 3: Write failing allowed-method decision tests.** Pin GET/POST as
  `GET, HEAD, POST`, POST/GET as `POST, GET, HEAD`, explicit HEAD before GET as
  `HEAD, GET`, deduplication without movement, and distinct method arrayrefs for
  consecutive and concurrent selections. At this boundary the assertion reads
  `allowed_methods`; Task 5B owns its conversion into an `Allow` field. Add a
  comparison assertion showing `PAGI::App::Router` retains its existing
  alphabetical behavior without changing that class.

- [ ] **Step 4: Run the focused test and observe adapter/decision failures.**
  Run `t/routing/05-http-dispatch.t`. Expected: FAIL because Compiler and both
  internal production methods do not exist.

- [ ] **Step 5: Implement compile-time leaf adapters.**
  Compile normal handlers to native apps once, compile raw targets through
  `PAGI::Utils::to_app`, invoke handlers in scalar context, normalize immediate
  values and Futures with `Future->wrap`, and validate the resolved value with
  the shared response predicate:

  ```perl
  my $returned = $handler->($context);
  my $result = await Future->wrap($returned);

  croak 'handler did not return a response'
      unless PAGI::Utils::is_response($result);

  await $context->respond($result);
  ```

  Load `Future` explicitly. Keep this one normal adapter reusable by Task 5B's
  default and custom not-found/method-not-allowed handlers, which may be plain
  subs.

- [ ] **Step 6: Implement HTTP scanning.** For each direct node, return on the
  first FULL route match as a `full` decision containing the compiled leaf and
  a shallow matched scope with request-local `path_params`. For each PARTIAL
  route, add its normalized methods to an ordered set and continue. Ignore a
  constraint-failed candidate entirely. Return `partial` with a copied ordered
  array when nonempty, otherwise `none`. Never call a fallback or format a
  header in this method.

- [ ] **Step 7: Apply route middleware at leaf compilation.** Wrap each compiled
  leaf through `PAGI::Routing::Middleware->_wrap_descriptors`. Prove it runs
  only when the `full` decision's app is invoked and never during selection or
  for `partial`/`none` decisions.

- [ ] **Step 8: Run focused, neighboring, and full suites.** Run
  `t/routing/01-constructors.t` through `t/routing/05-http-dispatch.t`,
  `t/context/03-response-value.t`, and the full suite. Run `git diff --check`.

- [ ] **Step 9: Commit Task 5A.** Stage the five named files and commit with
  message `Routing: compile HTTP leaves and selection decisions`. After commit
  and review, complete ledger row and recovery line `Task 5A`; Task 5B remains
  blocked until that gate passes.

---

### Task 5B: Render generated HTTP outcomes and complete compilation

**Files:**

- Create: `t/routing/05-generated-outcomes.t`
- Modify: `lib/PAGI/Routing/Compiler.pm`
- Modify: `lib/PAGI/Routing/Router.pm`
- Modify: `lib/PAGI/Routing/Route.pm`
- Modify: `lib/PAGI/Routing/Mount.pm`

**Interfaces:**

- Consumes: Task 5A's compiled leaves, normal adapter, and exact `full`,
  `partial`, and `none` decision records.
- Produces: `PAGI::Routing::Compiler->compile($description) -> CODE`. A
  leaf/mount compiles by first placing it in a complete one-node router.
- Converts `partial.allowed_methods` into first-seen `Allow`; `none` selects
  `not_found`; `full` invokes only the selected leaf.
- Completes public `Router`/`Route`/`Mount->to_app` behavior with one fresh
  compiled graph per call.

- [ ] **Step 1: Write failing generated-handler tests.** Cover plain defaults,
  customized ordinary `$c` handlers, seeded 404 status, seeded 405 status and
  Allow, a detached status-405 response receiving a missing Allow, preservation
  of a custom Allow, no Allow added after changing status away from 405, and a
  fully matched application response with custom 404/405 passing untouched.

- [ ] **Step 2: Write failing visible 405 ordering tests.** Drive compiled PAGI
  apps and pin GET/POST as `Allow: GET, HEAD, POST`, POST/GET as
  `POST, GET, HEAD`, explicit HEAD before GET as `HEAD, GET`, deduplication
  without movement, and a fresh Allow accumulator per request. These tests
  consume Task 5A's ordered decision data; they do not rescan routes.

- [ ] **Step 3: Write failing router-middleware and compilation tests.** Prove
  router middleware observes full, generated 404, and generated 405 responses;
  route middleware observes only FULL. Assert `to_app` returns `CODE` for a
  router and standalone HTTP route, the standalone route retains 404/405
  behavior, and two calls produce independent middleware instances.

- [ ] **Step 4: Run `t/routing/05-generated-outcomes.t` and observe failures.**
  Expected: public Compiler wiring and generated response policy do not exist;
  Task 5A's focused file remains green.

- [ ] **Step 5: Compile generated handlers and apply Allow policy.** Compile
  default/custom not-found and method-not-allowed handlers through Task 5A's
  normal adapter. Seed the Context's cached response before calling the
  selected fallback. Turn `allowed_methods` into one first-seen `Allow` value.
  After the method-not-allowed handler resolves, reassert it only when status is
  still 405 and no Allow exists. Send through the same normal adapter path.

- [ ] **Step 6: Wire decisions into public compilation.** For `full`, invoke
  its compiled leaf with its matched scope. For `partial`, invoke the compiled
  405 path. For `none`, invoke the compiled 404 path. Apply router middleware
  through `_wrap_descriptors` around this complete dispatcher but inside the
  HEAD wire boundary added by Task 6. Router middleware receives the complete
  unsuppressed response stream and sees every outcome.

- [ ] **Step 7: Make each `to_app` build a fresh graph.** Do not cache the
  resulting app on descriptions. Resolve middleware factories once per graph,
  retain explicitly configured shared objects/closures by identity, and keep
  every fallback response/Allow accumulator request-local.

- [ ] **Step 8: Run both Task-5 files, neighboring tests, and the full suite.**
  Run `t/routing/01-constructors.t` through
  `t/routing/05-generated-outcomes.t`, `t/context/03-response-value.t`, and the
  full suite. Run `git diff --check`.

- [ ] **Step 9: Commit Task 5B.** Stage the five named files and commit with
  message `Routing: render generated HTTP outcomes and Allow`. After commit and
  review, complete ledger row and recovery line `Task 5B`; Task 6 cannot begin
  until that gate passes.

---

### Task 6: Router-owned HEAD wire suppression

**Files:**

- Create: `t/routing/06-head.t`
- Modify: `lib/PAGI/Routing/Compiler.pm`

**Interfaces:**

- Consumes: the compiled router's outer `$send` on an HTTP HEAD request.
- Produces: unchanged `http.response.start`, no original body/file/trailer
  events, and exactly one empty terminal body when the original response emits
  its first body event with false or absent `more`.
- Leaves `$scope->{method}` as HEAD for matching, middleware, and handlers.

- [ ] **Step 1: Write failing buffered/custom-HEAD tests.** Verify a normal GET
  handler also handles HEAD, sees `HEAD`, preserves GET-equivalent status,
  Content-Type, and Content-Length, and emits an empty wire body. Verify an
  explicit HEAD route before GET wins, the reverse order invokes GET, and a
  rejected explicit-HEAD constraint falls through to GET's automatic HEAD.
  Configure router-level `PAGI::Middleware::ContentLength` around a raw route
  that sends a body without Content-Length; assert GET and HEAD both report the
  full representation length while only GET emits that representation body.
  This test must fail if HEAD suppression is placed inside router middleware.

- [ ] **Step 2: Write failing streaming tests.** Use a raw route that sends two
  body events with `more => 1`, one terminal event with `more => 0`, then a
  trailer. Assert only start plus one replacement terminal body reaches the
  recorder. Repeat with terminal `more` absent.

- [ ] **Step 3: Write failing sendfile tests.** Send a body event containing a
  nonexistent `file`, `offset`, and `length`, with no `body` and no `more`.
  Assert no file open occurs, none of those keys reach downstream, and one
  empty terminal body is emitted.

- [ ] **Step 4: Write failing generated-response tests.** Exercise HEAD 404 and
  HEAD 405 and verify their start status/headers survive while their bodies are
  empty. Verify a normal GET request remains byte-for-byte unchanged.

- [ ] **Step 5: Implement HEAD suppression as the outermost response-event
  boundary of the compiled router.** Build the fully middleware-wrapped router
  first, then invoke it with the HEAD-suppressing send callback:

  ```text
  request metadata/bootstrap
    -> HEAD wire boundary
      -> router middleware
        -> dispatch
  ```

  Router middleware therefore observes the complete representation. HEAD
  suppression sees its final status and headers, forwards each
  `http.response.start` unchanged, drops `http.response.body` events with true
  `more`, and replaces only the first false/absent terminal body. Drop later
  bodies and `http.response.trailers`. Forward unrelated event types unchanged
  so a malformed app remains diagnosable by the server. This boundary covers
  matched routes, generated responses, inline subtrees, and application mounts.

- [ ] **Step 6: Run `t/routing/06-head.t`, `t/middleware/02-head.t`, and the full
  suite.** The existing Head middleware must remain unchanged. Commit with
  message `Routing: enforce HEAD semantics at the dispatch boundary`. After
  commit and task review, complete Task 6's canonical ledger row and recovery
  line with coordinator-verified evidence before Task 7 begins.

---

### Task 7: Inline and opaque application mounts

**Files:**

- Create: `t/routing/07-mounts.t`
- Modify: `lib/PAGI/Routing/Compiler.pm`
- Modify: `lib/PAGI/Routing/Resolver.pm`

**Interfaces:**

- Consumes: a mount match record from `Pattern` plus the parent request scope.
- Produces: a shallow child scope with rewritten `path`, extended `root_path`,
  unchanged original `raw_path`, and merged `path_params`.
- Inline mount: recursively dispatches its known child descriptions with a
  fresh local Allow set and inherited HTTP fallback handlers.
- Application mount: compiles its target once, owns every selected outcome,
  and never lets a child 404/405 resume parent scanning.

- [ ] **Step 1: Write failing scope-rewrite tests.** Cover static, exact,
  trailing-slash declaration, parameterized, nested, and root mounts. Pin exact
  `/api` child path `/`; existing `root_path` extension; actual captured prefix
  in `root_path`; merged outer/inner params; original raw bytes in `raw_path`;
  and root mount leaving empty/nonempty `root_path`, `path`, and `raw_path`
  unchanged. Retain unrelated preexisting `path_params`; current mount/leaf
  captures win only for collisions that could not be known from the declarative
  ancestry at compile time.

- [ ] **Step 2: Write failing ownership/order tests.** Verify an earlier mount
  preempts a later exact route, an earlier broad mount preempts a later narrow
  mount, a failed mount constraint lets scanning continue, a child 404 does not
  resume the parent, and an opaque child 405 is never merged with parent
  partial methods.

- [ ] **Step 3: Write failing inline-boundary tests.** Verify child PARTIAL
  methods use a fresh Allow set, inline child 404/405 use inherited handlers,
  inline mount middleware surrounds those outcomes, and route middleware does
  not run for either generated result. For a separately compiled router used
  as an application mount, pin the complete order as parent router middleware,
  mount middleware, child router middleware, child route middleware, handler.

- [ ] **Step 4: Implement child scope construction.** Special-case root mount
  as zero consumption. For non-root mounts, append the actual decoded consumed
  prefix to `root_path`; do not reconstruct it from the declared template.
  Set an exact-prefix remainder to `/`. Retain `raw_path` exactly as received.

- [ ] **Step 5: Compile inline subtrees structurally.** Pass inherited fallback
  adapters into the child dispatcher and reset its request-local Allow
  accumulator. Apply mount middleware after rewriting scope and outside the
  entire child dispatcher through `_wrap_descriptors`.

- [ ] **Step 6: Compile application mounts opaquely.** Coerce the target once
  with `PAGI::Utils::to_app`, apply mount middleware once through
  `_wrap_descriptors`, call it after the scope rewrite, and return from the
  parent regardless of the events/status it sends.

- [ ] **Step 7: Extend HEAD tests with application and inline mounts.** Verify
  the router's outer HEAD wrapper suppresses mounted buffered, streamed, and
  sendfile bodies too.

- [ ] **Step 8: Run `t/routing/07-mounts.t`, `t/routing/06-head.t`,
  `t/app-router.t`, `t/app/02-routing.t`, and the full suite. Commit** with
  message `Routing: add declaration-ordered inline and application mounts`.
  After commit and task review, complete Task 7's canonical ledger row and
  recovery line with coordinator-verified evidence before Task 8 begins.

---

### Task 8: WebSocket, SSE, raw protocol routes, and scope fallbacks

**Files:**

- Create: `t/routing/08-protocols.t`
- Modify: `lib/PAGI/Routing/Compiler.pm`

**Interfaces:**

- Normal WebSocket/SSE adapter: constructs the corresponding
  `PAGI::Context` subclass, awaits `handler($c)`, and ignores its resolved
  value.
- Raw WebSocket/SSE adapter: invokes the target native app with all three
  channels and ignores its resolved value.
- Unmatched SSE emits `sse.http.response.start/body` with 404.
- Unmatched WebSocket emits denial response events only when the advertised
  extension exists; otherwise it emits a pre-acceptance `websocket.close`.
- Lifespan returns without receive/send. Unknown scope types croak and include
  the type.

- [ ] **Step 1: Write failing normal protocol tests.** Use Context imperative
  methods to accept/send/close a WebSocket and start/send/close SSE. Assert the
  path params and mounted scope are visible and that scalar/Future return
  values are inert.

- [ ] **Step 2: Write failing raw tests.** Verify raw HTTP, WebSocket, and SSE
  route targets receive the exact child channels, own event emission, and are
  not wrapped in Context response adaptation.

- [ ] **Step 3: Write failing selection tests.** For WebSocket/SSE consider
  only same-protocol leaves and applicable mounts, preserve declaration order,
  treat constraint false as no match, and let an application mount handle all
  three supported scope types without a method filter.

- [ ] **Step 4: Write failing fallback tests.** Pin SSE decline event family,
  WebSocket extension/no-extension behavior, lifespan silence without reading,
  missing type defaulting to HTTP, and an unknown `grpc` type croaking with
  `unsupported PAGI scope type 'grpc'`.

- [ ] **Step 5: Implement protocol adapters and path-only scans.** Apply route
  middleware after the leaf matches through `_wrap_descriptors`. Invoke each
  handler in scalar context, then normalize and await completion without
  interpreting the resolved value:

  ```perl
  my $returned = $handler->($context);
  await Future->wrap($returned);
  return;
  ```

  Load `Future` explicitly. This accepts plain synchronous completion and
  Future-backed completion while preserving synchronous exception propagation.

- [ ] **Step 6: Implement protocol-specific fallbacks directly in Compiler.**
  Do not invoke the HTTP `$c` `not_found` handler on WebSocket/SSE scopes. Match
  the already shipped App::Router event families while leaving that class
  untouched.

- [ ] **Step 7: Verify standalone `websocket`, `sse`, and `mount` objects each
  compile through `to_app` and retain complete fallback behavior.** Run the
  focused test, `t/app-router-scope-decline.t`, `t/sse-router-support.t`, and
  the full suite.

- [ ] **Step 8: Commit** with message
  `Routing: dispatch WebSocket and SSE Context handlers`. After commit and task
  review, complete Task 8's canonical ledger row and recovery line with
  coordinator-verified evidence before Task 9 begins.

---

### Task 9: Versioned matched-route metadata and compilation isolation

**Files:**

- Create: `t/routing/09-metadata-isolation.t`
- Modify: `lib/PAGI/Routing/Compiler.pm`
- Modify: `lib/PAGI/Routing/Resolver.pm`

**Interfaces:**

- Consumes: absent or valid existing `scope->{'pagi.routing'}`.
- Produces a new shallow request scope containing:

  ```perl
  {
      version => 1,
      frames  => [
          {
              resolver => $resolver,
              mounts   => [],
              match    => undef,
          },
      ],
  }
  ```

- Inline mounts append descriptors to the current frame. Leaves set effective
  kind/pattern/name/description. Application mounts set a terminal mount
  record. Generated 404/405 leave `match` undefined.
- A separately compiled child app copies the container/frame list and appends
  its own frame. It never mutates an ancestor frame or `pagi.router`.

- [ ] **Step 1: Write failing metadata lifecycle tests.** Inspect metadata from
  router middleware before and after downstream, mount middleware, route
  middleware, and handlers. Pin effective mounted route and namespaced name,
  mount descriptor order and exact declared `path`/`namespace`/`desc` fields,
  unnamed fields as `undef`, app-mount terminal `kind => 'mount'` plus its
  effective pattern/description, and match remaining undefined for generated
  outcomes. Also prove the leaf match exists before route middleware and remains
  accurate when that middleware short-circuits.

- [ ] **Step 2: Write failing nested-compiled-router tests.** Mount a separately
  compiled router as an app. Assert the child sees two frames, the parent frame
  keeps its terminal mount record, the child frame gets its route record, and
  an existing `pagi.router` hash survives by reference and content.

- [ ] **Step 3: Write failing collision and version tests.** Accept an existing
  version-1 frame container and append one request-local frame. Reject an
  unsupported version before middleware or dispatch with an actionable
  diagnostic that names the encountered and supported versions. Reject a
  scalar, non-array frames, or malformed prior frame with the distinct
  diagnostic `scope key 'pagi.routing' has an incompatible value`. In every
  rejection case, prove the incoming scope and container remain untouched. A
  valid prior frame is a hash with a resolver object capable of reverse
  routing, an arrayref `mounts`, and `match` that is either undefined or a
  hashref.

- [ ] **Step 4: Install newly allocated metadata before router middleware on
  every request invocation.** After validating any incoming `pagi.routing`
  value, allocate a new current frame, frame array, container, and shallow
  scope:

  ```perl
  my $frame = {
      resolver => $compiled_resolver,
      mounts   => [],
      match    => undef,
  };

  my @frames = (
      @{ $incoming_container->{frames} // [] },
      $frame,
  );

  my $container = {
      version => 1,
      frames  => \@frames,
  };

  my $routing_scope = {
      %$scope,
      'pagi.routing' => $container,
  };
  ```

  `$compiled_resolver` is immutable compiled state and may be shared across
  requests. Never allocate or retain `$frame`, `@frames`, `$container`,
  `mounts`, or `match` in the compile-time closure. Pass `$routing_scope` to
  router middleware. This router's internal shallow scope clones deliberately
  retain the same request-local `$frame` reference so downstream changes are
  visible to outer router/mount middleware after await. Do not replace, ignore,
  or partially interpret an incompatible existing container: doing so would
  silently discard routing ancestry. Compatible additions that preserve the
  version-1 contract do not require a version bump; a future implementation may
  explicitly read or migrate version 1.

- [ ] **Step 5: Add effective metadata records at selection time.** Resolver
  records must provide the complete mounted pattern/name without rebuilding
  them from request values. Copy mount descriptors into the request-local
  frame; never expose source object hashes.

- [ ] **Step 6: Write failing compilation-state tests.** Use a stateful
  middleware factory to prove two requests through one compiled app share its
  ordinary compiled instance, while two `to_app` calls get independent
  instances. Prove an explicitly reused middleware object and an explicitly
  shared closure retain caller-owned shared state.

- [ ] **Step 7: Write failing subtree/concurrency tests.** Mount one inline
  subtree twice and verify separate wrapper instances. Start two handler
  Futures before resolving either and assert their `path_params`, frames,
  matches, and fallback Allow accumulators remain independent. Use reference
  identity assertions to prove concurrent requests have distinct containers,
  frame arrays, current frames, and `mounts` arrays while sharing only the
  immutable compiled resolver. Within one request, prove router middleware
  before/after downstream and the selected route observe the same frame
  identity. A match or mount update in either request must be absent from the
  other.

- [ ] **Step 8: Implement fresh compilation and request-local storage until
  every isolation test passes.** No request writes may target a node, Pattern,
  Resolver, compiled route entry, or middleware descriptor.

- [ ] **Step 9: Run `t/routing/09-metadata-isolation.t` and the full suite.
  Commit** with message
  `Routing: publish request-local match frames without state leakage`. After
  commit and task review, complete Task 9's canonical ledger row and recovery
  line with coordinator-verified evidence before Task 10 begins.

---

### Task 10: Context `path_for` and absolute `url_for`

**Files:**

- Create: `t/context/12-routing-reverse.t`
- Modify: `lib/PAGI/Context.pm`
- Modify: `lib/PAGI/Routing/Resolver.pm`

**Interfaces:**

- Produces: `$c->path_for($name, \%path_params, \%query_params)` using the last
  valid routing frame and prefixing the request's `root_path`.
- Produces: `$c->url_for($name, \%path_params, \%query_params)` as an absolute
  URL using normalized scope data and `PAGI::Authority->from_scope($scope)`.
- Resolver adds internal `url_for_scope($scope, $name, \%path, \%query)` and
  route-kind lookup. Router `path_for` remains request-independent.
- No new `uri_for` method is introduced.

- [ ] **Step 1: Write failing Context frame-selection tests.** Cover one frame,
  nested frames selecting the last resolver, no routing frame, malformed frame,
  and HTTP/WebSocket/SSE Context subclasses inheriting both methods from the
  base class.

- [ ] **Step 2: Write failing path tests.** Pin empty and nonempty `root_path`,
  avoid duplicate slashes at the root boundary, retain generated query strings,
  and show router `path_for` never includes request `root_path`.

- [ ] **Step 3: Write failing Authority-integration tests.** Use one valid Host
  with an explicit port and one absent-Host server fallback. Prove a malformed
  Host and duplicate Host propagate `PAGI::Authority` failures without falling
  back, and no usable source croaks. Do not repeat Authority's complete grammar,
  IPv4/IPv6, delimiter, port, or header-cardinality matrix here; that belongs to
  `t/authority.t` in the completed prerequisite.

- [ ] **Step 4: Write failing scheme tests.** HTTP and SSE targets map `ws` to
  `http` and `wss` to `https`; WebSocket targets map `http` to `ws` and `https`
  to `wss`; already normalized `ws`/`wss` remain so for WebSocket targets.
  A missing scheme follows the existing Context default of `http`. Croak on an
  unsupported scheme rather than inventing a mapping.

- [ ] **Step 5: Implement the base Context delegation.** Validate the public
  frame schema, select the last resolver, and croak with
  `path_for requires a PAGI::Routing resolver in scope` when absent. Join
  `root_path` and generated application path without normalizing internal path
  content.

- [ ] **Step 6: Implement authority delegation and scheme formatting in
  Resolver.** Call `PAGI::Authority->from_scope($scope)` exactly once; do not
  inspect Host pairs or format `scope->{server}` locally. Never parse
  `Forwarded` or `X-Forwarded-*`. Select the route scheme using the named leaf's
  kind and concatenate only the validated authority returned by the prerequisite.

- [ ] **Step 7: Add POD security/order guidance.** Document
  `ReverseProxy -> TrustedHosts -> PAGI::Routing` for HTTP; explicitly state
  the shipped middleware still passes WebSocket/SSE through and those scopes
  must already be normalized/validated. Link `PAGI::Authority`, explain that
  invalid or duplicate Host never falls back to server, and direct users who
  need raw last-value behavior to `header('host')` rather than recreating it in
  the resolver.

- [ ] **Step 8: Run `t/context/12-routing-reverse.t`, `t/authority.t`, all
  existing Context tests, URL middleware tests, and the full suite. Commit** with message
  `Context: add routing-aware path_for and url_for`. After commit and task
  review, complete Task 10's canonical ledger row and recovery line with
  coordinator-verified evidence before Task 11 begins.

---

### Task 11: Complete reference docs, comparison, and executable example

**Files:**

- Modify: `lib/PAGI/Routing.pm`
- Modify: `lib/PAGI/Routing/Router.pm`
- Modify: `lib/PAGI/Routing/Route.pm`
- Modify: `lib/PAGI/Routing/Mount.pm`
- Modify: `lib/PAGI/Routing/Middleware.pm`
- Modify: `lib/PAGI/Routing/Pattern.pm`
- Modify: `lib/PAGI/Routing/Resolver.pm`
- Modify: `lib/PAGI/Routing/Compiler.pm`
- Modify: `lib/PAGI/Middleware/Helpers.pm`
- Modify: `lib/PAGI/Tools.pm`
- Modify: `lib/PAGI/Tools/Tutorial.pod`
- Modify: `lib/PAGI/Tools/Cookbook.pod`
- Create: `examples/declarative-routing/app.pl`
- Create: `examples/declarative-routing/lib/MyApp/Routes/Home.pm`
- Create: `examples/declarative-routing/README.md`
- Modify: `examples/README.md`
- Create: `t/integration-declarative-routing-demo.t`
- Modify: `Changes`
- Regenerate: `README.md` from `PAGI::Tools` POD through the configured
  `ReadmeAnyFromPod` workflow

**Interfaces:**

- Produces: one primary `PAGI::Routing` tutorial/reference POD and focused class
  POD for object-specific accessors and lifecycle.
- Produces: a runnable app file whose final expression is a PAGI app coderef,
  plus a separately loaded fully qualified handler package.
- Produces: an explicit three-router comparison that identifies both matching
  engines and both middleware contracts.

- [ ] **Step 1: Write the integration test first.** Load the example's package,
  `do` the app file, assert the result is `CODE`, and use `PAGI::Test::Client`
  to exercise home, a constrained mounted route, custom 404, 405 Allow, HEAD,
  and a generated URL. Capture app-file load errors cleanly.

- [ ] **Step 2: Build the small example.** Use named async subs in
  `MyApp::Routes::Home`, load them normally with
  `use MyApp::Routes::Home ()`, pass fully
  qualified coderefs, include one inline `/api` namespace, one route-level
  pure middleware descriptor, and finish `app.pl` with `$routing->to_app`.
  Keep raw, WebSocket, and SSE examples in docs so the executable demo stays
  small.

- [ ] **Step 3: Complete `PAGI::Routing` POD.** Include imports, constructor
  grammar, coderef-position table, no callable overload, compile-once guidance,
  methods/automatic HEAD/custom HEAD order, exact slash semantics, constraints,
  raw lifecycle, fallbacks, catch-alls, mount ownership/scope rewriting,
  middleware placement, reverse routing, metadata, and inspection. Include the
  no-verb-constructor rationale and the `mount` import collision with
  `PAGI::Middleware::Builder` plus selective-import solutions. State that
  dispatch, constraint, raw-app, and middleware exceptions propagate to
  `PAGI::Middleware::ErrorHandler`; the router does not synthesize 500s and
  never moves synchronous handlers into a worker pool. Explain that the HEAD
  ordering guarantee covers middleware configured on the router. A caller that
  wraps the compiled app with body-derived middleware outside this boundary can
  invalidate GET-equivalent HEAD headers; GZip, ContentLength, ETag, and similar
  response-transforming middleware belong in the router's `middleware` list
  when using router-owned HEAD handling. Document the metadata compatibility
  rule: independently composed routers must use compatible `pagi.routing`
  container versions; an unknown incompatible version fails before middleware
  or dispatch rather than silently losing ancestor frames. Compatible schema
  additions retain version 1, and a future implementation may explicitly read
  or migrate the version-1 contract.

- [ ] **Step 4: Add weight-bearing cookbook recipes.** Include:

  - handlers loaded from other packages;
  - inline versus application mounts and raw route versus mount;
  - dynamic mount captures visible to child handler/middleware/reverse routing;
  - router/mount/child-router/route middleware order;
  - `clone_scope`, `wrap_send`, and `wrap_receive` with lifecycle notes;
  - negotiated `not_found`/`method_not_allowed` handlers;
  - root and subtree catch-alls with 405 consequences;
  - explicit HEAD before GET, reversed-order behavior, and constraint fallback;
  - normal HTTP response return versus raw event ownership;
  - imperative WebSocket/SSE handlers and raw forms;
  - regex, predicate, and Type::Tiny-compatible constraints;
  - wildcard traversal/symlink/containment warning;
  - names, optional namespaces, duplicate-name errors, `path_for`, and
    proxy-safe `url_for`;
  - `pagi.routing` schema, nested frames, and middleware visibility;
  - `PAGI::Lifespan->wrap($routing, startup => $hook)` composition.

- [ ] **Step 5: Add the API comparison table.** State:

  | API | Matcher | Handler | Route middleware |
  |---|---|---|---|
  | `PAGI::Routing` | new immutable declaration-ordered matcher | `$c`; HTTP returns Response | pure app-to-app event middleware |
  | `PAGI::App::Router` | existing mutable route-first/mount-fallback matcher | native PAGI app | pure app-to-app event middleware |
  | `PAGI::Endpoint::Router` | delegates matching to `PAGI::App::Router` | class method with `$c`; HTTP returns Response | shipped value-flow `($c, $next)` middleware |

  Also document first-seen versus alphabetical Allow ordering, without calling
  either order method priority.

- [ ] **Step 6: Document public scope and helper lifecycle.** Every helper must
  state whether it validates/builds at compile time, changes request-local
  state, constructs a callback for later, or actually emits/awaits events.
  Document `pagi.routing` as a read-only versioned convention and explain that
  outer middleware does not see downstream top-level scope additions.

- [ ] **Step 7: Update front-page/module/example indexes and release notes.**
  Present declarative routing as an alternative, not a replacement. Mention
  the deliberate Starlette mount-slash difference and the current HTTP-only
  proxy/Host middleware limitation. Do not claim the extracted Context/Response
  or cross-protocol compatibility designs are shipped.

- [ ] **Step 8: Check docs and example.** Run the integration test,
  `podchecker` over every changed POD-bearing module, `perl -Ilib -c` on the app
  and package file, and regenerate/check `README.md` from `lib/PAGI/Tools.pm`.

- [ ] **Step 9: Commit** with message
  `docs: teach declarative routing and its protocol boundaries`. After commit
  and task review, complete Task 11's canonical ledger row and recovery line
  with coordinator-verified evidence before Task 12 begins.

---

### Task 12: Release-quality verification and scope audit

**Files:**

- Modify only if a verification failure exposes an in-scope defect.

**Interfaces:**

- Produces evidence that the implementation and documentation satisfy every
  approved design section while leaving extracted work unchanged.

- [ ] **Step 1: Run every focused routing test together.**

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t/routing t/context/12-routing-reverse.t t/middleware/helpers.t t/integration-declarative-routing-demo.t'
  ```

  Expected: `Result: PASS` with no warnings outside captured diagnostics.

- [ ] **Step 2: Run the full distribution suite twice.**

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t'
  ```

  Both runs must pass. The second run catches hidden shared-state/order leaks.

- [ ] **Step 3: Run POD and packaging checks.** Use `podchecker` on every new
  and changed POD-bearing file, then `dzil test`. Confirm the generated MANIFEST
  contains every new `lib/`, `t/`, and example file while `docs/` remains
  pruned as configured.

- [ ] **Step 4: Audit public behavior against design sections 1-22.** Make a
  temporary checklist from every bullet in sections 20 and 21 and point each
  item to a test and POD/example location. Add only missing tests/docs; do not
  widen the feature.

- [ ] **Step 5: Audit explicit exclusions.** Confirm diffs contain no semantic
  edits to `PAGI::App::Router`, `PAGI::Response`, `ReverseProxy`,
  `TrustedHosts`, `PAGI::App::File`, or `PAGI::Middleware::Static`. Confirm no
  `uri_for`, verb constructor, OPTIONS generator, slash redirect, callable
  overload, worker pool, OpenAPI layer, or `walk_routes` was added.

- [ ] **Step 6: Run repository hygiene checks.** `git diff --check`, inspect
  `git status --short`, confirm the three unrelated untracked report files are
  untouched, and inspect the final diff for generated or accidental files.

- [ ] **Step 7: Commit any verification-only in-scope corrections** with
  message `Routing: finish release verification` after rerunning the focused
  and full suites. If no correction was needed, do not create an empty commit.
  Regardless, after the final review complete Task 12's canonical ledger row
  and recovery line with coordinator-verified evidence before branch handoff.

## Plan Self-Review

- Design §§1-6 map to Tasks 1, 5A, 5B, and 9: additive API, export bundles,
  immutable objects, explicit `to_app`, fresh compilation, and concurrency.
- Design §§7-14 map to Tasks 2, 5A, 5B, 6, 7, and 8: grammar, HEAD, mounts,
  FULL/PARTIAL matching, constraints, handler adaptation, generated outcomes,
  catch-alls, and all scope families.
- Design §§15-16 map to Task 4 and placement assertions in Tasks 5A, 5B, 7,
  and 9.
- Design §§17-18 map to Tasks 3, 9, and 10: names, namespaces, reverse routing,
  versioned scope frames, descriptions, and recursive inspection.
- Design §§19-22 map to validation in Tasks 1-10, the complete test matrix, Task
  11 documentation, and Task 12 release audit.
- The plan consumes the separately completed `PAGI::Authority` prerequisite
  but intentionally does not implement the Context/Response compatibility
  design, proxy/Host cross-protocol design, file containment audit, or
  `PAGI::App::Router` implied-HEAD Allow correction.
- Public and internal types are consistent: descriptions are immutable objects,
  Patterns return request-local match hashes, Resolver owns effective immutable
  name records, Compiler returns only native PAGI coderefs, normal HTTP handlers
  return Response values, and protocol/raw apps return inert completion values.
- No implementation step relies on signature introspection, string evaluation,
  response-status interception for mount ownership, or hidden route sorting.
- The final placeholder scan contains no implementation placeholders. Uses of
  `deferred` identify approved non-goals with separate designs, not unfinished
  requirements inside this plan.

  Expected: only this self-review command contains placeholder-search terms.
