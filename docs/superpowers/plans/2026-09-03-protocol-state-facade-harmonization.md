# Protocol State Facade Harmonization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `PAGI::Request`, `PAGI::WebSocket`, and `PAGI::SSE` expose the same strict `PAGI::State|undef` application-state contract, while keeping lifespan initialization and the underlying PAGI scope state as ordinary mutable hashrefs.

**Architecture:** `PAGI::State` remains the single read-oriented facade over `$scope->{state}`. The three request/protocol objects delegate their `state` methods to that facade and expose matching `has_state` validation; no facade caching, scope copying, or new state storage is introduced. Lifespan callbacks and `PAGI::Lifespan->state` retain raw hashrefs because lifespan owns state initialization, while request-time consumers receive the typo-catching facade.

**Tech Stack:** Perl 5, `Test2::V0`, existing `PAGI::State`, `PAGI::Request`, `PAGI::WebSocket`, `PAGI::SSE`, Dist::Zilla.

**Spec:** [Request-first handlers and scope helpers design](../specs/2026-08-27-request-first-handlers-and-scope-helpers-design.md), especially §§9.2–9.3. This plan resolves the direct WebSocket/SSE harmonization that §9.3 explicitly deferred.

## Global Constraints

- Work only in `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/.worktrees/compose-retained-router` on `feature/remove-mutable-router-frontends`, based on `main`, for existing PR #28.
- This is one PAGI-Tools/CPAN deployment boundary; no PAGI specification or PAGI::Server repository changes belong here.
- Do not alter `$scope->{state}`: it remains an ordinary hashref owned and populated by lifespan/application code.
- Do not alter `PAGI::Lifespan->state`: lifespan startup/shutdown callbacks retain their mutable raw hashref.
- Do not cache facade objects or promise object identity. Repeated `state` calls may return distinct `PAGI::State` objects over the same backing hashref.
- Missing application state returns `undef`; a present non-hashref state croaks. `has_state` returns false only for absence and also croaks for malformed presence.
- Preserve the existing warned `%{}` compatibility bridge in `PAGI::State`; do not add protocol-specific compatibility machinery.
- Preserve the existing `app_state($source)` export for raw scope and protocol-neutral code. Do not add an exported function named `state`, which conflicts with Perl's `state` declarator.
- Keep connection-local `connection_state` on WebSocket/SSE distinct from lifespan application state.
- Use test-driven development: add failing tests before changing implementation.
- Run the complete suite once after focused tests pass; do not repeat it without a concrete reason.
- Any unexpected need for state copying, facade caching, protocol-specific adapters, or more than the listed live-document migrations is a stop condition for design review.

## Work Map

| Repository | Ticket/PR | Branch | Base | Owned changes | Deployment boundary | Push target |
|---|---|---|---|---|---|---|
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | Existing PR #28; protocol-state follow-up | `feature/remove-mutable-router-frontends` | `main` | WebSocket/SSE state facade parity, tests, examples, POD, Changes, upgrading guidance | PAGI-Tools CPAN distribution | `origin/feature/remove-mutable-router-frontends` after explicit user authorization |

## Contract and rationale

Before this correction, the three direct request/protocol objects disagree:

```perl
$request->state;    # PAGI::State or undef
$websocket->state;  # raw hashref, or a newly allocated empty hashref
$sse->state;        # raw hashref, or a newly allocated empty hashref
```

That makes missing-key typos safe in HTTP handlers but silently autovivifying in WebSocket/SSE handlers, even though all three read the same PAGI scope member. After this correction:

```perl
my $request_state = $request->state;      # PAGI::State or undef
my $socket_state  = $websocket->state;    # PAGI::State or undef
my $stream_state  = $sse->state;          # PAGI::State or undef

my $db = $socket_state->get('db');
```

The lifecycle boundary intentionally remains different:

```perl
startup => sub ($state, $scope) {
    $state->{db} = connect_db();           # mutable raw hashref: initialization owner
},

websocket('/chat' => sub ($websocket) {
    my $db = $websocket->state->get('db'); # read-oriented facade: request-time consumer
    ...
});
```

The old `$websocket->state->{db}` and `$sse->state->{db}` spellings continue through `PAGI::State`'s existing deprecated hash-dereference overload and warning. Exact hashref checks and HashRef consumers must use `->data` during migration. No compatibility promise is added beyond that already documented bridge.

---

### Task 1: Harmonize the WebSocket and SSE state contract

**Files:**
- Modify: `t/websocket-state.t`
- Modify: `t/sse-state.t`
- Modify: `lib/PAGI/WebSocket.pm`
- Modify: `lib/PAGI/SSE.pm`
- Create during execution (ignored tracking artifact): `.superpowers/sdd/2026-09-03-protocol-state-facade-harmonization/progress.md`

**Interfaces:**
- Consumes: `PAGI::State->new($source) -> PAGI::State|undef`; protocol objects already expose `scope()`.
- Produces: `PAGI::WebSocket->state -> PAGI::State|undef`, `PAGI::WebSocket->has_state -> bool`, `PAGI::SSE->state -> PAGI::State|undef`, and `PAGI::SSE->has_state -> bool`.

- [ ] **Step 1: Create the execution tracker and record the work map.** Create `.superpowers/sdd/2026-09-03-protocol-state-facade-harmonization/progress.md` with one row for each of Tasks 1–3 and columns for status, commit SHA, focused tests, full verification, and deviations. Copy the repository/branch/base/push-target facts from this plan. Record deviations as `DEV-NN` with rationale and user sign-off before later work depends on them.

- [ ] **Step 2: Replace the legacy WebSocket state expectations with RED contract tests.** Update `t/websocket-state.t` to assert the facade, absence, malformed-state validation, shared backing data, and stash separation:

```perl
my $state = $ws->state;
ok($ws->has_state, 'has_state recognizes injected application state');
isa_ok($state, ['PAGI::State']);
is($state->get('db'), 'test-connection', 'state reads application data strictly');
is($state->data, exact_ref($scope->{state}), 'facade keeps the exact scope state hash');

ok(!$missing->has_state, 'has_state is false when application state is absent');
is($missing->state, undef, 'state is undef when application state is absent');

like(
    dies { $malformed->has_state },
    qr/PAGI::WebSocket state must be a hashref/,
    'has_state rejects malformed present state',
);
like(
    dies { $malformed->state },
    qr/state.*hashref/i,
    'state rejects malformed present state',
);
```

Use `$state->exists('room')` rather than raw `exists $ws->state->{room}` in the stash-separation assertion. Do not add object-identity assertions.

- [ ] **Step 3: Replace the legacy SSE state expectations with the same RED contract tests.** Update `t/sse-state.t` with the corresponding `PAGI::State`, `has_state`, `undef`, malformed-value, and exact-backing-hash assertions. Keep `connection_state` assertions separate so application state and protocol lifecycle state remain visibly different.

- [ ] **Step 4: Run the focused tests and verify the intended failures.** Run:

```bash
prove -lv t/websocket-state.t t/sse-state.t
```

Expected: FAIL because both methods still return raw/empty hashrefs and neither protocol class implements `has_state`. Confirm the failures are contract failures, not syntax or fixture errors.

- [ ] **Step 5: Implement the WebSocket methods without copying or caching.** Replace `PAGI::WebSocket::state` and add `has_state` alongside it:

```perl
sub has_state {
    my $self = shift;
    return 0 unless exists $self->{scope}{state};
    croak 'PAGI::WebSocket state must be a hashref'
        unless ref($self->{scope}{state}) eq 'HASH';
    return 1;
}

sub state {
    my $self = shift;
    require PAGI::State;
    return PAGI::State->new($self);
}
```

Use the module's existing `Carp` import. Do not memoize the returned object and do not mutate the scope.

- [ ] **Step 6: Implement the matching SSE methods.** Add the equivalent `has_state` and `state` methods to `PAGI::SSE`, with the diagnostic naming `PAGI::SSE`. Reuse `PAGI::State->new($self)`; do not introduce a shared mixin or utility for two small methods.

- [ ] **Step 7: Run focused state tests.** Run:

```bash
prove -lv t/state.t t/request-state.t t/websocket-state.t t/sse-state.t t/websocket/02-state.t t/sse/02-state.t
```

Expected: PASS. This verifies the common facade, Request compatibility, and that protocol `connection_state` behavior is untouched.

- [ ] **Step 8: Update the tracker and commit the behavior.** Record the exact focused test count and result in Task 1's tracking row, then commit only the implementation and tests:

```bash
git add lib/PAGI/WebSocket.pm lib/PAGI/SSE.pm t/websocket-state.t t/sse-state.t
git commit -m "Harmonize protocol application state access"
```

Record the resulting SHA in the same tracking row.

---

### Task 2: Explain and demonstrate the unified state boundary

**Files:**
- Modify: `lib/PAGI/WebSocket.pm`
- Modify: `lib/PAGI/SSE.pm`
- Modify: `lib/PAGI/Lifespan.pm`
- Modify: `lib/PAGI/State.pm`
- Modify: `lib/PAGI/Tools/Tutorial.pod`
- Modify: `examples/endpoint-class-demo/lib/MyApp/StatusSocket.pm`
- Modify: `examples/endpoint-class-demo/lib/MyApp/API/Events.pm`
- Modify: `examples/endpoint-class-demo/README.md`
- Modify: `UPGRADING.md`
- Modify: `t/upgrading-request-first-handlers.t`
- Modify: `Changes`
- Modify: `docs/superpowers/specs/2026-08-27-request-first-handlers-and-scope-helpers-design.md`

**Interfaces:**
- Consumes: the four direct methods from Task 1 and the unchanged `app_state($source)` factory.
- Produces: one documented state-access rule across HTTP, WebSocket, and SSE; a clear mutable-lifespan versus read-oriented-consumer boundary; executable upgrading examples.

- [ ] **Step 1: Rewrite WebSocket and SSE POD around the facade contract.** For each class, show:

```perl
my $state = $websocket->state
    or die 'application requires lifespan state';
my $db = $state->get('db');

if ($websocket->has_state) {
    ...
}
```

Document `PAGI::State|undef`, malformed-state croaks, no repeated-call identity guarantee, `->data` as the explicit raw-hash escape hatch, and the distinction from `connection_state` and `PAGI::Stash`. Give `has_state` its own POD entry in both classes.

- [ ] **Step 2: Clarify lifecycle ownership in Lifespan and State POD.** Update `PAGI::Lifespan` examples so startup/shutdown continue using `$state->{db}`, while request-time examples use `$req->state->get('db')`, `$ws->state->get('db')`, and `$sse->state->get('db')`. State explicitly that lifespan receives the mutable hash because it initializes application state; the three direct protocol/request objects expose read-oriented `PAGI::State`. Extend `PAGI::State`'s accepted-source examples/SEE ALSO list to include WebSocket and SSE without changing its implementation.

- [ ] **Step 3: Update the tutorial's unified helper explanation.** Change the sentence that currently singles out `$request->state` so it explains that `$request->state`, `$websocket->state`, and `$sse->state` share the same facade/absence contract. Retain the reason the functional export is named `app_state`, and retain `app_state($scope)` as the raw-PAGI/protocol-neutral spelling.

- [ ] **Step 4: Migrate the endpoint-class demonstration to direct protocol methods.** In `MyApp::StatusSocket`, remove `use PAGI::State qw(app_state)` and replace both `app_state($websocket)` calls with `$websocket->state`. In `MyApp::API::Events`, remove the import and replace `app_state($sse)` with `$sse->state`. Keep request-handler uses of `app_state($request)` unchanged where those files deliberately demonstrate the functional helper. Update the README to explain both equivalent request-time spellings, emphasizing that direct protocol methods now match Request.

- [ ] **Step 5: Add executable upgrading assertions.** Extend `t/upgrading-request-first-handlers.t` with before/after examples:

```perl
# Before: raw hashref or fabricated empty hashref
my $db = $websocket->state->{db};

# After: the same strict optional contract as Request
my $state = $websocket->state
    or die 'lifespan state required';
my $db = $state->get('db');
```

Assert both protocol types return `PAGI::State`, missing state returns `undef`, and `->data` is the exact backing hashref for callers that genuinely require one. The prose in `UPGRADING.md` must call out that `ref($protocol->state) eq 'HASH'` becomes false and that the existing `%{}` overload is temporary compatibility, not transparent hashref identity.

- [ ] **Step 6: Record the change in Changes and resolve the old design deferral.** Add a BREAKING/consistency bullet under the current unreleased release explaining the unified contract and lifecycle exception. In the 2026-08-27 design, preserve the historical fact that the original phase deferred WebSocket/SSE, then add a dated follow-up resolution pointing to this plan; do not silently rewrite the earlier sequencing decision as though it never existed.

- [ ] **Step 7: Run documentation and example-focused tests.** Run:

```bash
prove -lv t/00-pod/cookbook-examples.t t/integration-endpoint-class-demo.t t/upgrading-request-first-handlers.t
```

Expected: PASS. The existing integration test already asserts that the migrated WebSocket endpoint emits `resource => 'demo-resource'`, that the SSE endpoint emits the same lifespan resource, and that shutdown closes the resource; those assertions are the end-to-end acceptance gate and require no test-only implementation coupling.

- [ ] **Step 8: Search live surfaces for contradictory raw protocol-state guidance.** Run:

```bash
rg -n --glob '!docs/superpowers/plans/**' --glob '!docs/superpowers/specs/**' \
  'state returns hashref|Returns empty hashref if no state|\$ws->state->\{|\$sse->state->\{|app_state\(\$websocket\)|app_state\(\$sse\)' \
  lib examples README.md UPGRADING.md Changes
```

Expected: no contradictory current documentation or example code. Historical before snippets in `UPGRADING.md` are allowed only when labeled as previous behavior. Do not mechanically rewrite unrelated `PAGI::Test::Client->state` or `PAGI::Lifespan->state`; both intentionally return raw shared state.

- [ ] **Step 9: Update the tracker and commit documentation/examples.** Record focused evidence and any approved deviations, then commit:

```bash
git add lib/PAGI/WebSocket.pm lib/PAGI/SSE.pm lib/PAGI/Lifespan.pm lib/PAGI/State.pm \
  lib/PAGI/Tools/Tutorial.pod examples/endpoint-class-demo \
  t/upgrading-request-first-handlers.t \
  UPGRADING.md Changes \
  docs/superpowers/specs/2026-08-27-request-first-handlers-and-scope-helpers-design.md
git commit -m "Document unified protocol state access"
```

Record the resulting SHA in Task 2's tracking row.

---

### Task 3: Verify the complete branch and prepare the existing PR

**Files:**
- Modify only if verification exposes a requirement-owned defect: files already listed in Tasks 1–2
- Update ignored execution tracker: `.superpowers/sdd/2026-09-03-protocol-state-facade-harmonization/progress.md`

**Interfaces:**
- Consumes: completed implementation and documentation from Tasks 1–2.
- Produces: evidence that the state change and the complete PAGI-Tools branch are review-ready; no push without explicit user authorization.

- [ ] **Step 1: Verify repository and PR mapping before publication work.** Run:

```bash
git status -sb
git branch --show-current
git log -3 --oneline
```

Expected: `feature/remove-mutable-router-frontends`, tracking `origin/feature/remove-mutable-router-frontends`, with only intended state-harmonization commits beyond the already-reviewed local branch state. Reconcile any mismatch before continuing.

- [ ] **Step 2: Run all state and affected integration tests together.** Run:

```bash
prove -lv \
  t/state.t t/request-state.t t/websocket-state.t t/sse-state.t \
  t/websocket/02-state.t t/sse/02-state.t \
  t/integration-endpoint-class-demo.t t/upgrading-request-first-handlers.t
```

Expected: PASS. Record the exact files/tests/result.

- [ ] **Step 3: Run the complete test suite once.** In the project's configured Perl environment, run:

```bash
prove -lr t
```

Expected: PASS. If unrelated tests fail because the larger branch is in a known half-migrated state, inspect and record concrete evidence before deciding; do not paper over failures or rerun blindly.

- [ ] **Step 4: Run distribution and diff hygiene checks.** Run:

```bash
git diff --check main...HEAD
dzil build
git status --short
```

Expected: clean diff check, successful distribution build, and no untracked/generated build artifacts requiring inclusion. Do not commit generated README churn unless the source POD intentionally changed it and repository policy requires regeneration.

- [ ] **Step 5: Review the incremental change against the approved boundary.** Confirm:
  - Request/WebSocket/SSE expose one state contract;
  - Lifespan and Test::Client retain raw state intentionally;
  - no scope copying, facade caching, or protocol-specific compatibility was added;
  - examples use direct protocol state cleanly;
  - upgrading material explains absence and hashref-identity breakage;
  - connection lifecycle state, Stash, backpressure, and disconnect behavior are untouched.

- [ ] **Step 6: Complete the tracker and report PR readiness.** Mark all rows complete with SHAs and evidence. Report the exact verification results and that the local branch is ready. Do not push or update PR #28 until the user explicitly authorizes that external action.

## Completion criteria

The work is complete when all of the following are true:

- `PAGI::Request`, `PAGI::WebSocket`, and `PAGI::SSE` return `PAGI::State|undef` from `state` and validate presence through `has_state`.
- All three facades wrap the exact `$scope->{state}` hashref without copying or identity guarantees.
- Lifespan startup/shutdown and `PAGI::Test::Client->state` retain their mutable/raw state contracts.
- WebSocket/SSE POD, tutorial, lifespan docs, example code, Changes, and UPGRADING agree on the boundary and migration.
- Focused tests, the complete suite, `git diff --check`, and `dzil build` pass with recorded evidence.
- No unrelated refactor or compatibility mechanism entered the change.
