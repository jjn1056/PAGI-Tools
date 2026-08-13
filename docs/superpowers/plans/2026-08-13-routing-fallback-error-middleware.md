# Routing Fallback and Error Middleware Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Router-owned HTTP 404/405 responses with trusted request-local
routing evidence, ordinary boundary middleware, and mandatory Compose-level
404/405/500 failsafes while preserving nested Router ownership and producing
safe complete public applications.

**Architecture:** A request-local `PAGI::Routing::Trace` ledger records compact
first-party routing frames and exposes read-only checkpoint snapshots. The
shared compiler records matching facts and completes unanswered on HTTP route
exhaustion; `Routing::NotFound` and `Routing::MethodNotAllowed` middleware turn
trusted declines into responses at any routing boundary. Compose installs the
outer ErrorHandler, completion guard, and routing fallbacks around author
middleware, while opaque applications remain unable to publish into the parent
trace.

**Tech Stack:** Perl 5.18-compatible distribution code, hand-written blessed
references (lexical inside-out state for capability-bearing trace objects),
`Future`, `Future::AsyncAwait`, core `Encode`, `Scalar::Util`,
`Test2::V0`, `PAGI::Test::Client`, POD, Dist::Zilla metadata, and the existing
shared PAGI routing/compiler/middleware infrastructure. No new dependency.

## Global Constraints

- The approved contract is
  `docs/superpowers/specs/2026-08-13-routing-fallback-error-middleware-design.md`.
  If implementation evidence conflicts with it, record a deviation and obtain
  the user's decision before dependent work continues.
- This is an intentional breaking change. Remove Router `not_found` and
  `method_not_allowed` constructor options, accessors, builder storage,
  generated-handler compilation, Response seeding, and generated-`Allow`
  provenance repair. Do not retain aliases, warnings, ignored options, or
  dormant code.
- Work only in
  `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` or an isolated
  worktree created for this repository by the Superpowers worktree workflow.
- Preserve the unrelated untracked files `.cpan-testers-fix-report.md`,
  `.csrf-helper-brief.md`, and `.csrf-helper-report.md`. Never stage them.
- Keep every file under `lib/` and every ordinary test parseable on Perl 5.18:
  use classic `@_` unpacking and avoid signatures, postfix dereferencing,
  `try`/`catch`, and newer syntax. Existing Perl 5.40+ example code may retain
  signatures.
- Keep `PAGI::Routing::{Route,Mount,Router}` immutable. Trace state, frame
  stacks, checkpoints, response lifecycle flags, and diagnostic attempts are
  request-local and must never be retained on routing descriptions or compiled
  applications.
- Preserve declaration-order FULL/PARTIAL selection, first-FULL wins, first-seen
  method union, GET-contributes-HEAD, matched-Mount ownership, path rewriting,
  reverse routing, constraints, and all WebSocket/SSE outcomes.
- Routing evidence is HTTP-only. WebSocket, SSE, lifespan, and extension scopes
  neither install nor mutate `pagi.routing.trace`.
- On HTTP, opaque mounts, raw routes, URLMap mounts, and URLMap's default target
  cannot publish into a parent trace. Shield the publisher channel with a
  shallow child scope; never mutate the incoming scope. On WebSocket, SSE,
  lifespan, and extension scopes, pass any same-named incoming value through
  untouched as ordinary scope data.
- Use `Future->wrap($returned)` wherever a callback, handler, middleware app,
  renderer, reporter, or target may complete immediately or through a Future.
  Do not directly `await` a possibly immediate value.
- Middleware remains pure PAGI app-to-app middleware. Do not add a request-time
  `$next`, response-valued middleware, callback options on Compose, default
  suppression detection, or disable flags.
- Compose's automatic order is exactly: outer HEAD wire boundary; HTTP trace
  preparation; automatic ErrorHandler; private response-completion guard;
  automatic Routing::NotFound; automatic Routing::MethodNotAllowed; author
  Compose middleware in declared order; target. Each `to_app` constructs fresh
  automatic and author wrapper instances; all response/trace state is lexical
  to one request invocation.
- A matched normal Context handler still must return one immediate or
  Future-backed `PAGI::Response`. Manual response emission followed by `undef`,
  a scalar, or another object remains an application error.
- A routing-fallback 405 must contain exactly one authoritative `Allow`
  header. An explicit 405 from a selected handler/native app is untouched.
- Public `ErrorHandler` keeps `development => 0`, `content_type => 'text/html'`,
  `status => 500`, and `on_error => undef` defaults. Compose alone supplies the
  private exception-safe per-request environment resolver.
- Built-in 404/405/ErrorHandler bodies are UTF-8 octets with byte-correct
  `Content-Length` where emitted and `Cache-Control: no-store`. A custom
  ErrorHandler renderer owns its content type and cache policy.
- Use TDD for each behavior: add the smallest focused failing assertion, run it
  and record the expected failure, implement, rerun the focused test, then run
  the named task regression gate.
- Use `PAGI::Test::Client` for end-to-end HTTP application outcomes. Use direct
  scope/receive/send harnesses only where the contract under test is deliberately
  incomplete (naked Router/Cascade), inspects raw events or gated streaming, or
  covers WebSocket/SSE/lifespan scope identity.
- Capture intended failures with `dies` and assert stable semantic fragments,
  not file/line suffixes. Test output must remain warning-free.
- Put public POD beside every new/changed public class, option, lifecycle, and
  boundary rule in the same task as the behavior. Task 9 reconciles the wider
  Tutorial, Cookbook, README, Changes, and upgrade narrative.
- Stage only files named by the current task. Never use `git add .` or
  `git add -A`. `docs/superpowers` is ignored; use `git add -f` only for the
  exact approved spec/plan paths.
- Every implementation task ends with one focused commit and review gate. The
  coordinator independently checks the diff, focused output, commit SHA, and
  ledger row before the next task starts.
- Run the repository-wide `prove -lr t` suite exactly once at the final
  reviewed HEAD. Focused tests may be rerun as TDD requires. Do not run
  `dzil test`, because it repeats the suite. If the final suite exposes a
  defect and HEAD changes, record the failure/fix and run one new final suite
  at the corrected HEAD.
- Run Perl commands through the project Perl. For example:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/13-trace.t'
  ```

## Execution Tracking and Deviation Control

Before Task 1, create the isolated execution workspace using the selected
execution skill. When using subagent-driven development, run:

```bash
/Users/jnapiorkowski/.codex/plugins/cache/openai-curated-remote/superpowers/6.2.0/skills/subagent-driven-development/scripts/sdd-workspace docs/superpowers/plans/2026-08-13-routing-fallback-error-middleware.md
```

The command must print a directory ending in
`.superpowers/sdd/2026-08-13-routing-fallback-error-middleware`. Create its
`progress.md` with this exact first line and tables:

```markdown
# SDD ledger — plan: docs/superpowers/plans/2026-08-13-routing-fallback-error-middleware.md

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

Before Task 1, run `git rev-parse HEAD`. Store the exact 40-character SHA in
`.superpowers/sdd/2026-08-13-routing-fallback-error-middleware/starting-head`
with one trailing newline and add `Starting HEAD: SHA` to `progress.md`. Also
record `git status --short`, including the three preserved untracked reports.

The coordinator owns the ledger. Update each row in the same working step as
its commit/review with exact commands, exit statuses, actual test-file/assertion
counts, elapsed time, commit SHA, and review evidence—never estimates or a
worker's unsupported summary.

A contract conflict gets the next stable ID (`DEV-001`, `DEV-002`, then
sequentially numbered IDs),
status `awaiting decision`, exact conflicting text, concrete evidence, and all
blocked tasks. Record the user's explicit approval, rejection, or replacement
before dependent work continues. An ordinary defect whose fix preserves the
approved contract is not a deviation.

## File and Responsibility Map

- `lib/PAGI/Routing/Trace.pm`: request-local collector installation,
  compatibility marker, checkpoint validation, record storage, and the private
  compiler-recorder seam.
- `lib/PAGI/Routing/Trace/Recorder.pm`: internal frame begin/attempt/selection/
  completion writer that holds the collector-specific capability; it is never
  placed in request scope.
- `lib/PAGI/Routing/Trace/Snapshot.pm`: immutable public summary/attempt view,
  selected-child folding, sibling decline aggregation, and defensive copies.
- `lib/PAGI/Routing/Compiler.pm`: unchanged matching decisions plus trace
  publication, nonterminal HTTP exhaustion, and raw/opaque trace shielding.
- `lib/PAGI/Routing/Router.pm`, `lib/PAGI/App/Router/Builder.pm`, and frontend
  POD/tests: remove Router fallback options and materialization fields.
- `lib/PAGI/Middleware/Routing/NotFound.pm` and
  `lib/PAGI/Middleware/Routing/MethodNotAllowed.pm`: ordinary boundary
  middleware, Context renderer adapters, safe default responses, and local
  send observation.
- `lib/PAGI/Middleware/Routing/_Fallback.pm`: private shared HTTP lifecycle,
  trace-checkpoint, handler adaptation, and response emission mechanics; it
  contains no status-selection policy.
- `lib/PAGI/Middleware/ErrorHandler.pm`: custom renderer, awaited reporting,
  response-start safety, UTF-8 bytes, no-store defaults, and static-vs-private
  dynamic development handling.
- `lib/PAGI/Exception/IncompleteResponse.pm`: typed internal normal-completion
  error shared by Compose and Cascade.
- `lib/PAGI/Compose/ResponseGuard.pm`: private HTTP response lifecycle guard.
- `lib/PAGI/Compose/Compiler.pm`: exact automatic safety graph and private
  exception-safe environment resolver.
- `lib/PAGI/App/Cascade.pm`: caught-status policy plus trusted decline,
  incomplete-child detection, and start-only streaming inspection.
- `lib/PAGI/App/URLMap.pm`: opaque trace shielding for mounts/default targets.
- Focused `t/routing/13-*` through `16-*`, `t/compose/06-*`, and existing
  middleware/App/frontend tests: contract and regression coverage.
- `examples/declarative-routing`, `examples/15-large-application`, and every
  public example that deploys a Router directly: complete application-boundary
  spellings.
- `UPGRADING.md`, `Changes`, `README.md`, `lib/PAGI/Tools.pm`, Tutorial,
  Cookbook, and public module POD: complete migration and author guidance.

---

### Task 1: Request-Local Trace, Recorder, and Snapshot

**Files:**

- Create: `lib/PAGI/Routing/Trace.pm`
- Create: `lib/PAGI/Routing/Trace/Recorder.pm`
- Create: `lib/PAGI/Routing/Trace/Snapshot.pm`
- Modify: `lib/PAGI/Routing/Compiler.pm`
- Modify: `lib/PAGI/App/Cascade.pm`
- Create: `t/routing/13-trace.t`
- Modify: `t/00-load.t`

**Interfaces:**

- `PAGI::Routing::Trace->_ensure_http_scope($scope)` returns
  `($inner_scope, $trace)`. For HTTP it reuses a compatible incoming Trace by
  returning the original scope unchanged, or shallow-clones only when installing
  a fresh Trace/replacing an incompatible value. For non-HTTP it returns
  `($scope, undef)` without mutation. It never returns the write channel.
- `PAGI::Routing::Trace->_fresh_http_scope($scope)` always returns a shallow
  HTTP scope with a newly installed Trace, replacing any incoming value; for a
  non-HTTP scope it returns `($scope, undef)` unchanged. Compose uses this root
  reset while Router/fallback/Cascade use `_ensure_http_scope`.
- `PAGI::Routing::Trace->_claim_compiler_recorder_factory($installer)` is a
  one-time internal bootstrap called from a `BEGIN` block while the real
  `PAGI/Routing/Compiler.pm` file loads. It verifies both caller package and
  source file, invokes `$installer` with a factory closure over Trace's lexical
  writer token, replaces the bootstrap CODE slot with a permanently sealed
  diagnostic, and cannot be claimed again. Compiler retains the factory in a
  lexical. Neither factory, token, nor Recorder enters request scope. This is a
  same-process Perl capability boundary, not a promise against deliberate core
  symbol-table or interpreter introspection.
- `PAGI::Routing::Trace->_claim_cascade_discard_factory($installer)` follows
  the same one-time package/source/install/seal pattern for the real
  `PAGI/App/Cascade.pm` file, but yields only a closure that appends a discarded
  disposition for one exact collector checkpoint window. It cannot begin or
  complete routing frames or append candidate attempts.
- `$trace->checkpoint` returns an opaque collector-owned marker.
- `$trace->snapshot($checkpoint)` returns
  `PAGI::Routing::Trace::Snapshot` and rejects foreign markers.
- Recorder methods are `_begin_frame(\%meta, $parent_link)`,
  `_attempt($frame_id, \%record)`,
  `_select_leaf($frame_id)`, `_select_opaque($frame_id)`,
  `_expect_child($frame_id)`, `_complete_decline($frame_id, \%summary)`,
  `_complete_success($frame_id)`, `_complete_child($frame_id, $child_link)`,
  and `_complete_exception($frame_id)`. `_expect_child` returns a signed,
  one-use parent link; child frame-begin consumes it, and parent child-completion
  follows that exact frame rather than a mutable ambient stack.
- Snapshot public methods are `routing_declined`, `path_matched`,
  `method_matched`, `allowed_methods`, `attempts`, `details_available`, and
  `truncated`. Arrayrefs are fresh defensive copies.

- [ ] **Step 1: Write the failing collector installation tests.** Cover an
  absent trace, a valid reused first-party trace, malformed hash/object values,
  `_fresh_http_scope` replacement of a compatible Trace, and `websocket`, `sse`,
  and `lifespan` scopes. Assert reuse preserves both scope and Trace identity;
  use this installation shape:

  ```perl
  my $scope = { type => 'http', path => '/' };
  my ($inner, $trace)
      = PAGI::Routing::Trace->_ensure_http_scope($scope);

  isnt(refaddr($inner), refaddr($scope), 'installation uses a shallow clone');
  isa_ok($inner->{'pagi.routing.trace'}, 'PAGI::Routing::Trace');
  is($scope->{'pagi.routing.trace'}, undef, 'incoming scope is untouched');
  ok(!$trace->can('record_attempt'), 'public collector has no mutation API');
  ```

- [ ] **Step 2: Run the installation red test.** Run the project-Perl command
  for `prove -lv t/routing/13-trace.t`. Expected: FAIL because the three trace
  classes do not exist.

- [ ] **Step 3: Implement private installation and checkpoint ownership.** Use
  lexical inside-out state keyed by object identity for Trace, checkpoint, and
  Snapshot objects, with cleanup on destruction, so direct hash mutation cannot
  forge compatibility or alter a snapshot. Keep the compatibility marker and
  writer token lexical to `PAGI::Routing::Trace`. Store only the Trace under
  `pagi.routing.trace`.
  Implement separate one-time package-and-source-checked compiler-writer and
  Cascade-discard factory claims. Each requires a CODE installer, passes its
  narrow closure into it rather than returning it, and seals the bootstrap
  immediately after installation. Make Recorder verify token identity on
  construction and every write. A checkpoint contains
  collector identity and current record sequence. `snapshot` croaks with
  `checkpoint belongs to another routing trace` for a marker from another
  collector.

- [ ] **Step 4: Add failing empty-snapshot and capability tests.** Assert an
  empty window reports false summary flags, fresh empty arrays,
  `details_available == false`, and `truncated == false`. Assert Trace and
  Snapshot expose no mutation methods, Recorder cannot be constructed without
  its capability, an ordinary caller cannot claim/reclaim either factory after
  its first-party module loads, the Cascade closure cannot perform compiler
  writes, and no writer/discard object or token appears anywhere in scope.

- [ ] **Step 5: Seal the writer into Compiler and implement the empty public
  snapshot.** Add this initialization shape before Compiler's methods, with the
  factory remaining lexical:

  ```perl
  my $TRACE_RECORDER_FOR;
  BEGIN {
      require PAGI::Routing::Trace;
      PAGI::Routing::Trace->_claim_compiler_recorder_factory(sub {
          ($TRACE_RECORDER_FOR) = @_;
      });
  }
  ```

  Add the equivalent sealed lexical `$DISCARD_TRACE_WINDOW` bootstrap in
  `PAGI::App::Cascade`; Task 7 first calls it. A discarded disposition stores
  collector-validated start/end sequence for one checkpoint window without
  copying application events or scope data. Return immutable scalar
  facts and fresh defensive arrayrefs without exposing internal records. Add
  the internal append-only record store, signed one-use child-link records, and
  folding helpers, but do not invent a test-only writer path; Task 2 exercises
  every write and nonempty fold through the actual compiler.

- [ ] **Step 6: Run the focused green gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/00-load.t t/routing/13-trace.t t/utils-environment.t'
  ```

  Expected: PASS with no warnings.

- [ ] **Step 7: Write Trace and Snapshot POD.** Document the scope key,
  HTTP-only installation, immutable/read-only observer API, foreign-checkpoint
  rejection, defensive copies, development detail gate, bounded attempts, and
  the fact that Recorder/capability methods are internal and unsupported.

- [ ] **Step 8: Commit and review.** Add Trace and Snapshot plus the internal
  Recorder to `t/00-load.t`. Stage only those modules, the Compiler bootstrap,
  `t/routing/13-trace.t`, and `t/00-load.t`; commit
  `feat: add request-local routing trace`.
  Update Task 1's ledger row with the exact SHA, focused command/count, and
  reviewer result.

---

### Task 2: Compiler Trace Publication Without Dispatch Changes

**Files:**

- Modify: `lib/PAGI/Routing/Compiler.pm`
- Modify: `lib/PAGI/Routing.pm`
- Create: `t/routing/14-trace-compiler.t`
- Modify: `t/routing/05-generated-outcomes.t`
- Modify: `t/routing/07-mounts.t`
- Modify: `t/routing/08-protocols.t`
- Modify: `t/routing/09-metadata-isolation.t`

**Interfaces:**

- Direct compiled Routers ensure one HTTP Trace after HEAD preparation and
  reuse any compatible outer collector. Compose instead deliberately forces a
  fresh root Trace on its shallow request scope, replacing even a compatible
  upstream value so one public application boundary cannot inherit stale or
  sibling evidence.
- Every root Router, Router child, and inline subtree begins/completes one
  structural frame. Mount middleware checkpoints can see the selected child
  even when the parent frame began before their window.
- The compiler carries a signed one-use parent link to a selected first-party
  child under the private NUL-prefixed scope key
  `"\0PAGI::Routing::Trace::parent"`. The child dispatcher consumes and removes
  it before matching or constructing a Context. Raw/opaque targets never
  receive it. This is internal transport, not public scope metadata.
- During this transitional task, existing generated 404/405 responses remain;
  fallback behavior changes only in Task 5.

- [ ] **Step 1: Write failing trace-publication tests.** For a Router with
  same-path GET/POST declarations, a later FULL route, an inline mount, a
  Router mount, raw route, and opaque mount, capture the Trace reference in
  outer middleware and assert snapshots after downstream completion. Invoke
  two compiled Routers sequentially under one checkpoint to exercise sibling
  folding through the real compiler. Pin:

  ```perl
  is($snapshot->allowed_methods, [qw(GET HEAD POST)],
      'PARTIAL siblings publish first-seen methods');
  ok(!$later_full_snapshot->routing_declined,
      'a later FULL supersedes discarded partials');
  ```

  Also prove a parent snapshot follows its selected child's summary, a nested
  child is counted once, sequential GET/POST declines union methods in
  first-seen execution order, and a successful sibling is excluded.

- [ ] **Step 2: Run the compiler red gate.** Run `prove -lv` for
  `t/routing/14-trace-compiler.t`. Expected: FAIL because Compiler does not
  install or write the trace.

- [ ] **Step 3: Use the lexical writer factory and wrap every dispatcher in a
  frame.** Use the factory installed in Task 1; do not add a second claim or a
  public accessor. Refactor
  `_compile_router_body` and inline subtree compilation so Router/mount
  middleware remains outside the frame it observes. Begin a frame immediately
  before matching; record success, decline, or exception without changing the
  selected application or existing generated response.

- [ ] **Step 4: Instrument `_select_http` without changing selection.** For
  each candidate append one development attempt containing only declaration
  metadata and Boolean path/method results. On PARTIAL completion record the
  exact first-seen `allowed_methods`; on none record no complete path; on FULL
  leaf call `_select_leaf`; on routing-aware Mount call `_expect_child`, place
  the returned one-use link in a shallow selected-child scope, and complete the
  parent with `_complete_child` after the child returns. Never infer nesting
  from a collector-global current-frame stack. If child Router middleware
  short-circuits without entering its dispatcher, the link remains unconsumed
  and the parent records a selected non-decline completion; it must not invent
  a Router miss. Reusing one link for a second child invocation croaks.

- [ ] **Step 5: Add failing environment/detail tests through real routes.** In
  production, test, and staging, assert summaries remain while attempts are
  empty. In development, compile 257 safe candidate declarations and assert
  only the first 256 attempts are exposed with `truncated == true`. With an
  invalid `PAGI_ENV`, prove construction/checkpointing succeeds and the first
  frame-begin observation—even for an empty Router—throws. Assert attempts contain only `namespace`,
  `pattern`, `name`, `desc`, `candidate_kind`, `path_matched`, and
  `method_matched`, never scope headers, cookies, bodies, or capture values.

- [ ] **Step 6: Add raw/opaque shielding tests.** Pass a compiled Router
  positionally through an opaque Mount and through a raw HTTP route. Assert its
  independent child Trace cannot alter the parent's snapshot and the parent
  records a selected opaque/raw target rather than trusted decline.

- [ ] **Step 7: Implement bounded records and `_shield_trace_scope`.** Let the
  collector resolve `PAGI::Utils::is_development()` lazily on the first
  compiler frame-begin observation. Retain compact frame structure in every environment;
  append at most 256 candidate records only in development and copy only the
  approved safe keys. On HTTP only, create a shallow child scope with
  `pagi.routing.trace` absent before invoking a raw route or opaque Mount.
  Preserve all unrelated scope keys, path parameters, `pagi.routing` reverse
  metadata, and channel identities. A nested first-party Router may install an
  independent trace in that child scope.

- [ ] **Step 8: Pin protocol non-observation.** Add WebSocket/SSE/lifespan tests
  with absent and preexisting `pagi.routing.trace`; assert identity and contents
  are unchanged and protocol denial/close/decline events remain byte-for-byte
  identical. Also prove an explicit handler/native 405 without `Allow` remains
  untouched; adding or changing a Lint warning is outside this feature.

- [ ] **Step 9: Run focused regressions.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/13-trace.t t/routing/14-trace-compiler.t t/routing/05-generated-outcomes.t t/routing/05-http-dispatch.t t/routing/07-mounts.t t/routing/08-protocols.t t/routing/09-metadata-isolation.t t/routing/10-head-boundary.t'
  ```

- [ ] **Step 10: Update Compiler POD and commit.** Document that generated
  outcomes are temporarily still emitted but now accompanied by inert trusted
  evidence; do not present that as final public behavior. Commit
  `feat: publish trusted routing evidence`. Record focused counts/review in the
  ledger.

---

### Task 3: Harden and Extend ErrorHandler

**Files:**

- Modify: `lib/PAGI/Middleware/ErrorHandler.pm`
- Create: `t/middleware/error-handler-contract.t`
- Modify: `t/middleware/03-error-handler.t`

**Interfaces:**

- Public options/defaults stay: `development => 0`, `on_error => undef`,
  `content_type => 'text/html'`, `status => 500`.
- New public `handler => $coderef` receives `($context, $original_error)` and
  returns an immediate/Future-backed response value accepted by the existing
  `PAGI::Utils::is_response` contract.
- `PAGI::Middleware::ErrorHandler->_new_compose_failsafe(%config)` is an
  internal constructor used only by Compose. It accepts the private dynamic
  development resolver without adding `_development_resolver` to the public
  `new` option surface.
- `on_error($error)` may return immediately or via Future; reporting failure
  never replaces the original error.

- [ ] **Step 1: Add failing renderer/default tests.** Assert ordinary
  `ErrorHandler->new` does not consult localized invalid `PAGI_ENV`, still
  defaults to HTML/production, and its built-in HTML/plain/JSON responses each
  contain `Cache-Control: no-store`.

- [ ] **Step 2: Add failing custom-handler tests.** Use both:

  ```perl
  handler => sub {
      my ($c, $error) = @_;
      return $c->json({ error => 'custom' });
  }
  ```

  and `Future->done($c->text(...))`. Assert seeded blessed-exception/default
  status, explicit status override, custom content type/cache headers untouched,
  invalid return diagnostic, and renderer exceptions propagate outward. Include
  a handler that returns a detached response-like object with `respond` but no
  mutable status/header API; its emitted explicit status still passes through,
  proving validation follows `PAGI::Utils::is_response` rather than class name.

- [ ] **Step 3: Run the ErrorHandler red gate.** Run the two ErrorHandler test
  files. Expected: failures for unknown behavior, missing no-store, and custom
  renderer support.

- [ ] **Step 4: Refactor error capture and custom rendering.** Preserve the
  original exception object. Build `PAGI::Context` only when a renderer is
  needed, seed its cached response with the selected status, normalize with
  `Future->wrap`, validate with `PAGI::Utils::is_response`, and emit via
  Context. Do not invoke a renderer after response start.

- [ ] **Step 5: Add failing async-reporting and post-start tests.** Cover
  immediate/Future success, synchronous throw, failed Future, and a gated
  Future proving rendering/rethrow waits. After start, assert no second start
  and identity/string of the original exception rethrown after reporting.

- [ ] **Step 6: Implement awaited reporting.** Use an internal async helper:

  ```perl
  async sub _report_error {
      my ($self, $error) = @_;
      return unless $self->{on_error};
      eval { await Future->wrap($self->{on_error}->($error)); 1 };
      return;
  }
  ```

  Keep reporting failures contained. Reverse the shipped post-start behavior
  explicitly: report, then `die $original_error`.

- [ ] **Step 7: Add failing UTF-8 tests.** Render an error containing
  `"snowman \x{2603}"` as plain text, HTML, and JSON. Assert body has no UTF-8
  flag, decodes exactly once, and header length equals byte length. Add missing
  `scope->{type}` coverage under captured warnings.

- [ ] **Step 8: Implement byte-safe built-ins.** Use `Encode::encode('UTF-8',
  $character_body)` exactly once for text/HTML; preserve JSON encoder octets.
  Calculate `Content-Length` only after encoding. Treat
  `($scope->{type} // 'http')` as the protocol discriminator.

- [ ] **Step 9: Implement exception-safe private development resolution.** For
  ordinary `new` instances use the stored Boolean and reject the private
  resolver key as unknown. Add `_new_compose_failsafe` as the one internal
  construction path that stores a resolver. Evaluate it per handled request
  inside `eval`; on failure report the resolver/configuration error, select
  production rendering, and never let the resolver failure escape the
  last-resort renderer.

- [ ] **Step 10: Run the focused green gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/middleware/03-error-handler.t t/middleware/error-handler-contract.t t/utils-environment.t'
  ```

- [ ] **Step 11: Update POD and commit.** Document handler/on_error lifecycle,
  static public defaults, post-start rethrow, no-store, UTF-8, and non-HTTP
  pass-through. Keep ErrorHandler's existing load entry green. Commit
  `feat: harden application error handling`; record the review gate.

---

### Task 4: Routing Fallback Middleware

**Files:**

- Create: `lib/PAGI/Middleware/Routing/_Fallback.pm`
- Create: `lib/PAGI/Middleware/Routing/NotFound.pm`
- Create: `lib/PAGI/Middleware/Routing/MethodNotAllowed.pm`
- Create: `t/routing/15-fallback-middleware.t`
- Modify: `t/00-load.t`

**Interfaces:**

- Both classes are ordinary `PAGI::Middleware` subclasses usable by short
  names `Routing::NotFound` and `Routing::MethodNotAllowed` in every existing
  middleware position.
- Each accepts only optional `handler => CODE`; odd option lists, unknown keys,
  or non-CODE values croak during construction.
- Handler signatures are `($context, $snapshot)` and return immediate/Future
  response values accepted by `PAGI::Utils::is_response`.

- [ ] **Step 1: Write trace-backed fixtures only through public components.**
  Use real compiled Routers for no-match and method-partial declines, a
  selected normal route for success, a throwing native app for exception, and
  a silent native app for no evidence. Because Task 2 deliberately still emits
  the old generated response, wrap only the decline fixtures in a transitional
  test adapter that invokes the Router with a private sink `$send`, discards
  those generated events, and leaves the real send untouched; the compiler's
  trusted trace remains the input under test. Do not call Recorder or expose
  any test-only writer seam. Task 5 removes this adapter when Router exhaustion
  becomes truly silent.

- [ ] **Step 2: Add failing NotFound lifecycle tests.** Cover immediate/Future
  renderers, status seed 404, explicit renderer status winning, response-start
  inertness, exception rethrow, no-evidence inertness, WebSocket/SSE/lifespan
  identity pass-through, production body `Not Found`, development diagnostics,
  safe encoding, and no-store. Pin odd-list, unknown-key, and non-CODE-handler
  construction failures.

- [ ] **Step 3: Add failing MethodNotAllowed lifecycle tests.** Cover the same
  cases plus cached status 405 and authoritative `Allow`. Use custom responses
  containing missing, duplicate, lowercase, and conflicting Allow fields and
  assert exactly one `Allow: GET, HEAD, POST`. If handler changes status to
  404, assert no computed Allow is added and unrelated headers remain. Repeat
  the 405 case with a response-like object that only implements `respond` to
  prove event-boundary normalization does not depend on Response internals.

- [ ] **Step 4: Run the fallback red gate.** Run
  `t/routing/15-fallback-middleware.t`. Expected: module-load failure.

- [ ] **Step 5: Implement the private common lifecycle.** `_Fallback` must:
  ensure/reuse an HTTP Trace; checkpoint immediately before inner invocation;
  observe start locally; `Future->wrap` inner completion; rethrow unchanged;
  return when start occurred; snapshot normal unanswered completion; and invoke
  the subclass renderer only when its predicate matches. Construct Context from
  the boundary scope plus the original `$receive` and outer `$send` (never the
  observer wrapper), validate the return through `PAGI::Utils::is_response`,
  and emit once with `$context->respond($response)`. It must never clear or
  consume records.

- [ ] **Step 6: Implement NotFound policy.** Act only when
  `routing_declined && !path_matched`. Seed the Context response to 404. Built-in
  production output is UTF-8 `Not Found`; development identifies the automatic
  failsafe and includes safe method/path/attempt information without captures,
  headers, cookies, bodies, or arbitrary scope extensions.

- [ ] **Step 7: Implement MethodNotAllowed policy.** Act only when
  `routing_declined && path_matched && !method_matched` with a nonempty method
  union. Seed status 405 but not Allow. After renderer completion, if final
  status is 405, normalize its outgoing `http.response.start` at this
  middleware's local send boundary: remove every case-insensitive `Allow` pair
  and append exactly one `['Allow' => join(', ', @$allowed_methods)]`. This
  supports every object accepted by `PAGI::Utils::is_response`, not only
  `PAGI::Response`. Do nothing to Allow for another status, and do not mutate
  the returned object.

- [ ] **Step 8: Add duplication/boundary tests.** Nest two instances of each
  fallback and assert one response start. Put a custom fallback inside an outer
  default and assert the inner response makes the outer inert. Check that a
  Route-level fallback is syntactically valid but cannot observe exhaustion.

- [ ] **Step 9: Run the focused green gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/13-trace.t t/routing/15-fallback-middleware.t t/routing/04-middleware-descriptors.t t/routing/11-bare-middleware.t'
  ```

- [ ] **Step 10: Write complete POD and commit.** Each public POD shows Compose,
  Router, and routing-aware Mount placement, mount ownership, handler contract,
  default-vs-official policy, and why Route placement is inert. NotFound
  cross-links `PAGI::App::NotFound` with the conditional-vs-unconditional
  distinction. Add both public middleware classes to `t/00-load.t`; leave the
  private `_Fallback` out of the public load list. Commit
  `feat: add routing fallback middleware`; update ledger.

---

### Task 5: Nonterminal HTTP Router Exhaustion

**Files:**

- Modify: `lib/PAGI/Routing/Compiler.pm`
- Modify: `lib/PAGI/Routing.pm`
- Replace: `t/routing/05-generated-outcomes.t` with
  `t/routing/16-http-declines.t`
- Modify: `t/routing/15-fallback-middleware.t`
- Modify: `t/routing/05-http-dispatch.t`
- Modify: `t/routing/06-head.t`
- Modify: `t/routing/07-mounts.t`
- Modify: `t/routing/09-metadata-isolation.t`
- Modify: `t/routing/12-router-mounts.t`
- Modify: `t/routing/11-bare-middleware.t`
- Modify: `t/router-middleware.t`

**Interfaces:**

- A direct compiled Router sends nothing for HTTP `none` or `partial` and
  returns normal completion after recording a trusted decline.
- A selected normal handler/route that fails its return contract still throws;
  a selected raw/opaque target that sends nothing remains silent and is marked
  selected, not declined.
- Router, inline-Mount, and Router-Mount middleware can render local declines by
  including the Task 4 fallback middleware in their existing lists.

- [ ] **Step 1: Write failing direct-decline tests.** Replace generated-response
  expectations with event-free completion and snapshots:

  ```perl
  my ($events, $snapshot) = run_with_trace(
      router(routes => [route('/items' => \&show, methods => 'GET')])->to_app,
      method => 'POST', path => '/items',
  );
  is($events, [], 'PARTIAL emits no response');
  ok($snapshot->routing_declined, 'PARTIAL is trusted decline');
  is($snapshot->allowed_methods, [qw(GET HEAD)], 'method union survives');
  ```

  Add none, later FULL, explicit handler 404/405, raw silence, opaque silence,
  and invalid normal-handler return cases.

- [ ] **Step 2: Run the decline red gate.** Run
  `t/routing/16-http-declines.t`. Expected: existing generated 404/405 events
  make the event-free assertions fail.

- [ ] **Step 3: Remove generated handler compilation.** Delete
  `_compile_generated_handler`, `_generated_allow_send`, their `refaddr` use,
  policy arguments in `_compile_http_handler`, and the fallback parameters
  threaded through `_compile_router_body`/`_compile_dispatcher`. On none or
  partial, complete the active frame and return without calling `$send`.
  Remove Task 4's private-sink test adapter so the same fallback lifecycle
  assertions now run against a direct Router decline.

- [ ] **Step 4: Add failing nested-boundary tests.** Build a child Router
  mounted after a parent method partial. Assert:

  ```text
  child none     => parent does not resume; outer NotFound handles child
  child partial  => child Allow only; parent partial excluded
  child fallback => Mount and parent defaults remain inert
  ```

  Repeat for inline subtree and a reused child mounted twice with occurrence-
  specific fallback middleware.

- [ ] **Step 5: Implement terminal Mount ownership with unanswered bubbling.**
  Keep the matched Mount's immediate FULL selection. Link the parent frame to
  the selected routing-aware child before invocation, allow the child's normal
  unanswered completion to unwind through child/occurrence/parent middleware,
  and never continue the parent's declaration scan.

- [ ] **Step 6: Add middleware-order and HEAD tests.** Pin outer Router,
  Router-Mount, child Router, inline Mount, and route middleware order for FULL,
  none, and partial. For fallback-rendered HEAD, assert ContentLength inside the
  router sees the full fallback body while the one outer HeadBoundary emits one
  empty terminal body and suppresses sendfile/file bodies.

- [ ] **Step 7: Rework metadata/concurrency tests.** Replace generated-handler
  Context assertions with concurrent Trace/Snapshot isolation. Start two
  PARTIAL requests against one compiled app, mutate a returned method array,
  and prove the other request and later requests remain unchanged.

- [ ] **Step 8: Run focused routing regressions.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/14-trace-compiler.t t/routing/15-fallback-middleware.t t/routing/16-http-declines.t t/routing/05-http-dispatch.t t/routing/06-head.t t/routing/07-mounts.t t/routing/08-protocols.t t/routing/09-metadata-isolation.t t/routing/10-head-boundary.t t/routing/12-router-mounts.t t/router-middleware.t'
  ```

- [ ] **Step 9: Finalize Compiler and Routing POD.** State direct Router
  compilation is a routing component, HTTP misses emit nothing, protocol misses
  retain existing outcomes, and fallback middleware is the only policy seam.
  Remove all generated-handler/seeded-response/Allow-repair prose.

- [ ] **Step 10: Commit and review.** Commit
  `refactor: make HTTP route exhaustion nonterminal`. Record the removed test,
  replacement coverage, focused count, SHA, and review result in Task 5's row.

---

### Task 6: Compose Automatic Safety Boundary

**Files:**

- Create: `lib/PAGI/Exception/IncompleteResponse.pm`
- Create: `lib/PAGI/Compose/ResponseGuard.pm`
- Modify: `lib/PAGI/Compose/Compiler.pm`
- Modify: `lib/PAGI/Compose.pm`
- Create: `t/compose/06-failsafes.t`
- Create: `t/compose/07-response-guard.t`
- Modify: `t/compose/02-dispatch.t`
- Modify: `t/compose/04-middleware.t`
- Modify: `t/compose/05-head-concurrency.t`
- Modify: `t/00-load.t`

**Interfaces:**

- `PAGI::Exception::IncompleteResponse->new(stage => $stage, message => $text)`
  is a blessed throwable with string overload; stages used here are
  `before_start`, `after_start`, and `body_before_start`. Construction requires
  a known stage and a defined scalar
  message; accessors return both fields and stringification returns the message.
- `PAGI::Compose::ResponseGuard->wrap($app)` returns an HTTP-only native app
  that tracks start and terminal body events and throws the typed exception only
  after normal incomplete completion.
- Compose accepts no new public option.

- [ ] **Step 1: Write failing ResponseGuard unit tests.** Cover complete body,
  absent/false `more`, sendfile terminal body with `file/offset/length`, no
  start, start without terminal body, inner exception before start, inner
  exception after start, and non-HTTP identity pass-through. Pin that an inner
  exception is never replaced by the guard. Pin typed
  exception accessors/stringification and rejection of unknown stages,
  reference messages, and missing constructor input.

- [ ] **Step 2: Run the guard red gate.** Run
  `t/compose/07-response-guard.t`. Expected: missing modules.

- [ ] **Step 3: Implement the typed exception and guard.** The guard's wrapped
  send observes but does not copy or rewrite events. It sets terminal when an
  `http.response.body` has absent/false `more`, regardless of whether payload is
  in `body` or `file`. Await the app with `Future->wrap`; only after successful
  normal completion validate the lifecycle.

- [ ] **Step 4: Add failing exact-order tests.** Use tracing author middleware,
  custom fallback renderers, ErrorHandler reporting, and target events to pin:

  ```text
  HEAD -> trace prep -> ErrorHandler -> guard -> NotFound ->
  MethodNotAllowed -> author outer -> author inner -> target
  ```

  Assert author-rendered 404/405/500 travels through earlier author middleware,
  while an automatic default response does not travel inward through author
  middleware.

- [ ] **Step 5: Compile the exact automatic graph.** In
  `PAGI::Compose::Compiler`, first compile/wrap author middleware around the
  target. Then wrap MethodNotAllowed, NotFound, ResponseGuard, and an automatic
  ErrorHandler in that order, constructing fresh automatic objects during each
  `to_app` call. At request time, keep HeadBoundary outermost and
  call `PAGI::Routing::Trace->_fresh_http_scope` before entering ErrorHandler;
  unlike fallback/Router `_ensure_http_scope`, this always installs a fresh
  collector on a shallow request scope, even when upstream supplied a valid
  first-party Trace.
  Lifespan and extension scopes retain their existing dispatcher path.

- [ ] **Step 6: Configure the private last-resort ErrorHandler.** Construct it
  through `_new_compose_failsafe` with `content_type => 'text/plain'`, private dynamic resolver
  `sub { PAGI::Utils::is_development() }`, and an internal reporter that warns
  `PAGI application error: $error` without exposing that callback as a Compose
  option. Its resolver failure is reported and rendered in production mode.

- [ ] **Step 7: Add complete outcome tests.** Cover `compose(routes => ...)` and
  `compose(app => ...)` for FULL, none, partial union Allow, explicit matched
  404/405/500, silent native app, silent raw target, silent opaque Mount,
  thrown/failed-Future database-like error, and a renderer that itself throws.
  Assert one response start in every rendered case.

- [ ] **Step 8: Add invalid-environment tests.** With invalid `PAGI_ENV`, prove:
  a first-party Router observation becomes a safe production 500; a throwing
  native app also becomes safe production 500; and a normally complete native
  app returns its response without consulting the environment or warning.

- [ ] **Step 9: Add post-start and HEAD tests.** Assert guard missing-terminal
  after start is reported/rethrown with no second start. Add a Router-level
  middleware that derives `X-Body-Length`; GET and HEAD must agree while HEAD
  carries only the empty terminal wire body. Repeat for fallback and ErrorHandler
  built-ins and a sendfile body.

- [ ] **Step 10: Run focused Compose regressions.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/compose/01-description.t t/compose/02-dispatch.t t/compose/03-lifespan.t t/compose/04-middleware.t t/compose/05-head-concurrency.t t/compose/06-failsafes.t t/compose/07-response-guard.t t/middleware/03-error-handler.t t/middleware/error-handler-contract.t'
  ```

- [ ] **Step 11: Rewrite Compose POD and commit.** Replace “errors propagate/no
  synthesized 500” with exact automatic guarantees, ordering, application-vs-
  routing-component distinction, customization-through-middleware examples,
  no options/detection/disabling, and HEAD placement. Add the typed exception
  to `t/00-load.t`; keep private ResponseGuard out of the public load list. Commit
  `feat: add Compose routing and error failsafes`; update ledger/review.

---

### Task 7: Cascade and URLMap Composition

**Files:**

- Modify: `lib/PAGI/App/Cascade.pm`
- Modify: `lib/PAGI/App/URLMap.pm`
- Modify: `lib/PAGI/App/NotFound.pm`
- Create: `t/app/07-routing-composition.t`
- Modify: `t/app/02-routing.t`

**Interfaces:**

- Cascade retains `apps` and `catch` public options/defaults. It adds no
  callback or routing-specific option.
- For HTTP, Cascade ensures/reuses Trace and checkpoints each child. Trusted
  decline and caught explicit status are distinct advance conditions.
- URLMap mounts/default are always opaque and shield parent trace publication.
- Cascade and URLMap keep their existing constructor/add/mount/map coercion and
  option surfaces; this task adds no target-shape magic or new callbacks.

- [ ] **Step 1: Add failing Cascade decline tests.** Cover a non-final naked
  Router decline advancing, a final Router decline remaining unanswered with
  evidence visible to outer NotFound/Compose, arbitrary silent non-final/final
  children throwing `IncompleteResponse`, explicit final caught 404/405 passing
  unchanged, an empty HTTP app list throwing `IncompleteResponse`, and
  exceptions never becoming declines.

  Preserve constructor/add coercion tests for coderef, object, and class-name
  apps plus custom/default `catch`; invalid app shapes still fail through
  `PAGI::Utils::to_app` with its existing diagnostic.

- [ ] **Step 2: Add failing sibling-union tests through real Cascade.** Invoke
  GET-only and POST-only Routers for a PUT request, then let the final Router
  decline. Assert an enclosing MethodNotAllowed sees first-execution union
  `[GET, HEAD, POST]`. Insert an explicit caught 404-producing Router/app between
  them and prove it contributes no routing summary. Add a child Router wrapped
  in child `Routing::NotFound` whose rendered 404 is caught; assert its prior
  decline is excluded from the outer snapshot while a snapshot the child took
  before Cascade's disposition still reports its local decline.

- [ ] **Step 3: Add failing streaming tests.** Use gated Futures to prove a
  non-caught start and first chunk reach the outer send before child completion;
  caught start/body events never reach it; a caught child completes before the
  next begins; body-before-start throws; caught incomplete response throws; and
  exception after forwarded start propagates as post-start failure.

- [ ] **Step 4: Run the Cascade red gate.** Run the App routing tests. Expected:
  current whole-response buffering and silent-child behavior fail.

- [ ] **Step 5: Implement HTTP Cascade state.** Around each child, take a
  checkpoint and track `start_seen`, `terminal_seen`, `caught`, and
  `forwarded_start`. For a non-final child, suppress all events after a caught
  start; otherwise forward start immediately and every later event directly.
  Await child completion before advancing. After a caught child completes
  successfully, call the sealed `$DISCARD_TRACE_WINDOW` closure with that
  child's collector/checkpoint so later enclosing snapshots ignore only that
  discarded window. Validate lifecycle with the shared typed exception and
  consult the snapshot only when no start occurred; never append a discard
  disposition for an exception or incomplete caught response.

- [ ] **Step 6: Preserve non-HTTP behavior without redesign.** Snapshot the
  current implementation before editing and pin it exactly: with two non-last
  children, the first child's emitted events are buffered until it completes,
  then replayed and Cascade returns without invoking the second; an empty app
  list completes normally with no events. Exercise this with WebSocket, SSE,
  lifespan, and one extension scope. Do not install/mutate a trace or apply
  HTTP `catch`, start/body validation, or discard dispositions to those scopes.
  If that observed behavior cannot be preserved while sharing code, record a
  deviation rather than inventing a new protocol policy.

- [ ] **Step 7: Add failing URLMap opacity tests.** Put a naked Router in a
  selected mount and in `default`. Under outer Compose both must become an
  opaque incomplete-app 500, not 404. Wrap the child with Compose and assert its
  own 404. Assert incoming parent trace object/records are unchanged by the
  naked child.

- [ ] **Step 8: Shield URLMap targets.** For an HTTP selected mount or default,
  shallow clone the delegated scope and remove `pagi.routing.trace` before
  invocation. Keep mount path/root_path rewriting and every unrelated key
  unchanged. For every non-HTTP scope, preserve an incoming same-named value by
  identity. Do not recognize Router classes or merge an independently installed
  child trace.

- [ ] **Step 9: Run focused App/Compose regressions.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/app/02-routing.t t/app/07-routing-composition.t t/compose/06-failsafes.t t/routing/13-trace.t t/routing/16-http-declines.t'
  ```

- [ ] **Step 10: Update reciprocal POD and commit.** Document Cascade as a
  routing component, trusted decline vs `catch`, streaming start inspection,
  incomplete arbitrary apps, and required enclosing fallback. Document URLMap
  opacity and child Compose. Cross-link App::NotFound to conditional
  Routing::NotFound without equating them. Commit
  `feat: compose routing declines across apps`; update ledger/review.

---

### Task 8: Remove Frontend Fallback Options and Migrate Examples

**Files:**

- Modify: `lib/PAGI/Routing/Router.pm`
- Modify: `lib/PAGI/App/Router/Builder.pm`
- Modify: `lib/PAGI/App/Router.pm`
- Modify: `lib/PAGI/Endpoint/Router.pm`
- Modify: `t/routing/01-constructors.t`
- Modify: `t/app-router/01-builder-core.t`
- Modify: `t/app-router/07-public-reverse-metadata.t`
- Modify: `t/app-router-group.t`
- Modify: `t/app-router-scope-decline.t`
- Modify: `t/app-router.t`
- Modify: `t/app/03-router.t`
- Modify: `t/endpoint/13-router-frontends.t`
- Modify: `t/upgrading-router-frontends.t`
- Modify: `examples/declarative-routing/app.pl`
- Modify: `examples/declarative-routing/lib/MyApp/Routes/Home.pm`
- Modify: `examples/10-chat-showcase/app.pl`
- Modify: `examples/10-chat-showcase/lib/ChatApp/HTTP.pm`
- Modify: `examples/10-chat-showcase/README.md`
- Modify: `examples/background-tasks/app.pl`
- Modify: `examples/background-tasks/README.md`
- Modify: `examples/endpoint-demo/app.pl`
- Modify: `examples/endpoint-demo/README.md`
- Modify: `examples/full-demo/app.pl`
- Modify: `examples/full-demo/README.md`
- Modify: `examples/declarative-routing/README.md`
- Create: `t/integration-router-application-boundaries.t`
- Modify: `t/integration-app-file-examples.t`
- Modify: `t/integration-declarative-routing-demo.t`
- Modify: `t/integration-chat-compose.t`
- Modify: `t/integration-compose-demo.t`
- Modify: `t/integration-endpoint-router-demo.t`
- Modify: `t/integration-large-application.t`

**Interfaces:**

- `PAGI::Routing::Router->new` accepts only `routes`, `middleware`, and `desc`.
- `PAGI::App::Router->new`/Builder accept only `middleware` and `desc` at the
  Router level; Endpoint materialization inherits that exact surface.
- Direct `to_app` remains legal low-level compilation; deployed examples use
  Compose unless they deliberately install every boundary middleware.

- [ ] **Step 1: Add failing constructor rejection tests.** For immutable and
  mutable frontends assert both removed names fail as unknown options. Assert
  no `not_found`/`method_not_allowed` accessors and no keys in `_router_options`.

- [ ] **Step 2: Run the frontend red gate.** Run the constructor/builder tests.
  Expected: old options are still accepted and accessors exist.

- [ ] **Step 3: Remove all frontend storage/materialization.** Delete Router
  validation/accessors/hash fields, App Builder allowed keys/validation/storage,
  `_router_options` fields, and conditional arguments in `_materialize_with`.
  Update the inline-mount compiler signature so child dispatchers no longer
  inherit generated handlers, and rewrite constructor/mount diagnostics that
  still name those options. Do not change names, route order, resolver, reverse
  routing, protocol routes, middleware normalization, or Endpoint method
  binding.

- [ ] **Step 4: Convert declarative-routing custom policy.** Change the example
  root to:

  ```perl
  compose(
      app => $routing,
      middleware => [
          middleware('Routing::NotFound',
              handler => \&MyApp::Routes::Home::not_found),
          middleware('Routing::MethodNotAllowed',
              handler => \&MyApp::Routes::Home::method_not_allowed),
      ],
  )->to_app;
  ```

  Change `method_not_allowed` to accept `($c, $trace)` and render
  `join(', ', @{$trace->allowed_methods})`; do not read a seeded Allow header.

- [ ] **Step 5: Migrate deployed Router examples to complete boundaries.** The
  chat showcase root already uses Compose; retain it, but change
  `ChatApp::HTTP` so its internally compiled HTTP Router is itself returned as
  `compose(app => $router)->to_app` before the outer opaque root mount. This
  preserves the current ownership rule: every `/api/...` request belongs to
  that child, and an unknown API path receives the child's complete 404 rather
  than falling through to static serving. Wrap the
  final Router in background tasks with `compose(app => $router)`. In endpoint
  demo, retain `PAGI::Endpoint::{HTTP,WebSocket,SSE}->to_app` as deliberately
  opaque mounted endpoint applications—the classes do not implement
  `to_router`—and wrap only the root Router with Compose. In full-demo, replace
  the hand-written `handle_lifespan` wrapper with
  `compose(app => $router, lifespan => { startup => ..., shutdown => ...
  })->to_app`, moving the existing callback bodies without semantic change.
  Preserve route declarations, middleware, protocol endpoints, state identity,
  and static-file behavior. Do not add branded fallback handlers where the
  example did not already have one.

- [ ] **Step 6: Preserve intentional catchall examples.** Keep the large
  application's root and Blogs `/*path` routes unchanged. Add integration
  assertions proving Blogs catchall handles its owned subtree, root catchall
  handles other missing paths, and child method exhaustion reaches the Compose
  automatic 405 with child-only Allow.

- [ ] **Step 7: Migrate frontend tests by intent.** Tests of low-level Router
  selection assert no events plus trace. Tests of complete HTTP application
  behavior wrap the Router/Endpoint in Compose. Tests of explicit application
  404/405 continue to assert those responses are untouched.

- [ ] **Step 8: Add an executable example-boundary regression.** In
  `t/integration-router-application-boundaries.t`, load the background-tasks
  application and assert it returns a coderef, a known route still succeeds,
  and an unknown HTTP path receives Compose's complete 404 rather than an empty
  event stream. Load full-demo with a direct raw-event harness so its optional
  sleep/backend paths do not make the integration test depend on an event-loop
  installation; assert its known `/` route and unknown-path 404. Extend
  `t/integration-app-file-examples.t` so endpoint-demo still serves its static
  root and an unresolved root request is a complete response. Extend
  `t/integration-chat-compose.t` so an unknown
  `/api/...` path is the inner HTTP child's 404 and the outer root Compose does
  not emit a second response. Keep the existing declarative, endpoint-router,
  and large-application integration coverage.

- [ ] **Step 9: Run focused frontend/example regressions.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/01-constructors.t t/app-router/01-builder-core.t t/app-router/07-public-reverse-metadata.t t/app-router-group.t t/app-router-scope-decline.t t/app-router.t t/app/03-router.t t/endpoint/13-router-frontends.t t/upgrading-router-frontends.t t/integration-app-file-examples.t t/integration-router-application-boundaries.t t/integration-declarative-routing-demo.t t/integration-chat-compose.t t/integration-compose-demo.t t/integration-endpoint-router-demo.t t/integration-large-application.t'
  ```

- [ ] **Step 10: Update frontend/example POD and commit.** Remove generated
  outcome handler prose, state all frontends share nonterminal exhaustion, and
  link Compose/fallback middleware. Commit
  `refactor: remove Router fallback callbacks`; record ledger/review.

---

### Task 9: Upgrade Guide and Public Documentation

**Files:**

- Modify: `UPGRADING.md`
- Create: `t/upgrading-routing-fallbacks.t`
- Modify: `Changes`
- Modify: `lib/PAGI/Tools.pm`
- Modify: `lib/PAGI/Tools/Tutorial.pod`
- Modify: `lib/PAGI/Tools/Cookbook.pod`
- Modify: `README.md`
- Modify: `lib/PAGI/Routing.pm`
- Modify: `lib/PAGI/Compose.pm`
- Modify: `lib/PAGI/Middleware/ErrorHandler.pm`
- Modify: `lib/PAGI/Middleware/Routing/NotFound.pm`
- Modify: `lib/PAGI/Middleware/Routing/MethodNotAllowed.pm`
- Modify: `lib/PAGI/App/Cascade.pm`
- Modify: `lib/PAGI/App/URLMap.pm`
- Modify: `lib/PAGI/App/NotFound.pm`
- Modify: `examples/README.md`
- Modify: `examples/declarative-routing/README.md`
- Modify: `examples/10-chat-showcase/README.md`
- Modify: `examples/background-tasks/README.md`
- Modify: `examples/endpoint-demo/README.md`
- Modify: `examples/endpoint-router-demo/README.md`
- Modify: `examples/full-demo/README.md`
- Modify: `examples/15-large-application/README.md`

**Interfaces:**

- `UPGRADING.md` is the standalone document for the existing user base.
- `t/upgrading-routing-fallbacks.t` executes the new spellings and asserts the
  migration claims; it must not merely regex-match prose.

- [ ] **Step 1: Write the executable upgrade cases first.** Cover:

  ```text
  old Router callback option          => rejected
  application fallback middleware     => custom 404/405
  Router/Mount boundary fallback       => local policy
  naked router->to_app                 => unanswered component
  compose(app => $router)              => complete defaults
  opaque compiled Router               => guard 500
  router => Router Mount               => trusted outer fallback
  opaque child compose                 => child fallback
  URLMap naked/wrapped Router          => 500/child fallback
  Cascade Router entries               => trusted advance
  post-start ErrorHandler exception    => original rethrown
  ```

- [ ] **Step 2: Run the upgrade red/green gate.** The test may initially fail
  only for missing documentation fixture text; implementation behavior from
  Tasks 1–8 must already pass. Keep runtime assertions independent from prose
  matching.

- [ ] **Step 3: Write the upgrade guide.** Include exact before/after examples
  for constructor callbacks, direct server deployment, opaque vs router-aware
  Mount, URLMap, Cascade, ErrorHandler post-start behavior, awaited `on_error`,
  no-store/UTF-8 change, and catchall route vs NotFound middleware. State that
  no compatibility aliases exist.

- [ ] **Step 4: Rewrite the public routing narrative.** Explain Router as a
  nonterminal routing component, Trace as facts not status, fallback placement
  at Compose/Router/Mount, method union/Allow enforcement, mount ownership,
  raw/opaque jailbreak differences, and why Context gains no routing-fallback
  methods.

- [ ] **Step 5: Rewrite Compose/ErrorHandler guidance.** Show the exact safety
  graph; mandatory inert defaults; application policy inside access logging,
  request ID, and security middleware; safe production bodies; dynamic Compose
  development mode; static ordinary ErrorHandler; async reporting; and
  before/after-start error behavior with a database failure example. Replace
  the Cookbook's shared Router `http_error` callback with two ordinary routing
  middleware handlers (or one shared renderer explicitly passed to both) that
  read the seeded status and the MethodNotAllowed snapshot rather than a seeded
  Router `Allow` header.

- [ ] **Step 6: Reconcile App utility documentation.** Explain Cascade's
  status catch vs trusted decline and streaming behavior, URLMap opacity,
  App::NotFound's unconditional role, and reciprocal links to conditional
  Routing::NotFound.

- [ ] **Step 7: Update front page, Tutorial, Cookbook, Changes, and example
  READMEs.** Preserve existing voice and edit incrementally. Ensure README and
  `PAGI::Tools` front-page POD make the same shipped claims. Mark every feature
  as shipped by this change, not planned or merely possible.

- [ ] **Step 8: Run documentation-focused verification.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/upgrading-routing-fallbacks.t t/upgrading-router-frontends.t t/integration-declarative-routing-demo.t t/integration-large-application.t'
  ```

  Then run `git diff --check` and search for stale public phrases:

  ```bash
  rg -n 'generated 404|generated 405|not_found\s*=>|method_not_allowed\s*=>|Compose does not synthesize HTTP 500|errors propagate normally' lib README.md UPGRADING.md Changes examples
  ```

  Every hit must be either an explicitly labeled “before” migration example or
  intentional application handler/catchall name; remove all stale API claims.

- [ ] **Step 9: Commit and review.** Commit
  `docs: document routing fallback migration`. Record exact documentation test
  results, stale-search disposition, SHA, and review in Task 9's row.

---

### Task 10: Final Verification and Whole-Feature Review

**Files:**

- Modify only if verification finds a contract-preserving defect in files
  already named by Tasks 1–9.
- Update execution ledger:
  `.superpowers/sdd/2026-08-13-routing-fallback-error-middleware/progress.md`

**Interfaces:**

- No new API. This task proves the approved spec, implementation, migration
  guide, and examples agree at one reviewed HEAD.

- [ ] **Step 1: Audit plan/spec coverage.** Read every requirement in sections
  4–17 of the approved spec and map it to an implementation file plus focused
  test. Record the mapping in Task 10's ledger notes. Any uncovered requirement
  is a defect; any genuine contract conflict is a `DEV-*` deviation and blocks
  completion.

- [ ] **Step 2: Run static integrity checks.** Run:

  ```bash
  git diff --check
  perl -Ilib -MPAGI::Routing::Trace -MPAGI::Routing::Trace::Snapshot -MPAGI::Middleware::Routing::NotFound -MPAGI::Middleware::Routing::MethodNotAllowed -MPAGI::Middleware::ErrorHandler -MPAGI::Compose -MPAGI::App::Cascade -MPAGI::App::URLMap -e 'print qq{modules load\n}'
  ```

  Expected: clean diff check and `modules load`.

- [ ] **Step 3: Run the consolidated focused gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/13-trace.t t/routing/14-trace-compiler.t t/routing/15-fallback-middleware.t t/routing/16-http-declines.t t/middleware/03-error-handler.t t/middleware/error-handler-contract.t t/compose/06-failsafes.t t/compose/07-response-guard.t t/app/07-routing-composition.t t/upgrading-routing-fallbacks.t t/integration-declarative-routing-demo.t t/integration-large-application.t'
  ```

  Record exact files/tests/assertions and exit status.

- [ ] **Step 4: Run the repository suite once.** At the final reviewed HEAD run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t'
  ```

  Record exact output, elapsed time, file count, assertion count, and exit
  status. Do not rerun it merely for confidence.

- [ ] **Step 5: Correct only evidenced defects.** If either gate fails, use
  `superpowers:systematic-debugging`, add or strengthen the smallest focused
  regression, make one named-file correction commit, rerun the failed focused
  gate, and—because HEAD changed—run one new final repository suite. Record both
  the failed and corrected evidence in the ledger.

- [ ] **Step 6: Perform the whole-feature review.** Use
  `superpowers:requesting-code-review` against the recorded Starting HEAD
  through final HEAD. Review for spec compliance, trace trust/opacity,
  concurrency, response lifecycle, UTF-8/headers, middleware order, migration
  completeness, and unrelated changes. Apply contract-preserving findings with
  focused tests; route contract changes through the deviation table.

- [ ] **Step 7: Close the ledger and hand off.** Every task row must contain a
  real commit range, focused evidence, review result, and final-suite reference.
  The deviation table must be empty or contain only user-decided entries.
  Report final commit range, exact verification evidence, documented breaking
  changes, and preserved unrelated files. Then use
  `superpowers:finishing-a-development-branch` to offer integration choices.
