# Protocol Refusal Ownership Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make deny/decline ordinary awaited application calls, eliminating detached workers and state rollback while preserving public connection and send ownership.

**Architecture:** Each helper awaits the existing application invocation utility directly. PAGI::Common performs only synchronous validation and Request-handler adaptation; it has no helper fields, Future ownership, or settlement hooks. Buffered Response protects server-owned sends at their existing emission boundary.

**Tech Stack:** Perl 5.018-compatible library code, Future >= 0.50, Future::AsyncAwait >= 0.66, Test2::V0, existing PAGI test clients and real-server integration harnesses.

**Spec:** [Ordinary awaited protocol refusals](../specs/2026-09-18-protocol-refusal-ownership-simplification-design.md), which amends the earlier application-refusal design. Read the amendment first; superseded lifetime tests are not implementation requirements.

## Global Constraints

- Backward compatibility is not a requirement for this redesign.
- Original scope identity/type and receive/send callbacks remain unchanged.
- Every refusal target still requires the public connection contract.
- No server/spec repository change, new dependency, Auth redesign, public lifecycle framework, private Response emission call, or receive watcher.
- Perl minimum 5.018, Future minimum 0.50, Future::AsyncAwait minimum 0.66 remain unchanged; library code uses argument unpacking from `@_`.
- The returned refusal Future follows normal application cancellation; no refusal-wide `retain`, `without_cancel`, or settlement callback.
- Do not change unrelated close/cleanup/subscription Future ownership or Stream/Writer internals to make this refactor pass.
- No helper-state reservation, rollback, stored refusal-history flags, send wrapper, or protocol event/scope rewriting.
- Unsupported overlapping/reentrant operations remain unsupported; do not add arbitration or adversarial race machinery.
- Remain on the user's current working branch and preserve unrelated dirty files. Stage exact owned paths only. No push, merge, release, or new worktree.

## Work map and baseline

No external ticket; work item is protocol refusal ownership simplification.

| Repository path | Branch / observed base | Owned changes | Deployment / push target |
| --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | `feature/universal-connection-tools`, `29873dd879ec8a2ca9f8c650fb295e4392642b4e` | This amendment/plan now; Tasks 1–3 at execution | local only / none |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI` | `main`, `9aebdbcd938f4ff520d68ce2ea2e86cd00cf150f` | read-only normative reference | none / none |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server/.worktrees/feature-websocket-close-truthfulness` | `feature/websocket-close-truthfulness`, `c0c08f695a4ecb1cd1d553fdbdfec3dbda86601e` | read-only integration checkout | none / none |

Record actual execution HEAD after these planning documents are committed.
Reconfirm this map if scope changes. Preserve the pre-existing edit to
`docs/superpowers/plans/2026-09-08-universal-connection-tracking.md` and unrelated
`.pagi-*`/`.superpowers` files. Prior final gate: 230 files / 2,640 tests PASS,
one release-only multipart skip. That is baseline history, not proof of this change.

Planning-time probe: cancelling `invoke_app(text_response(...), ...)` while its
start send is pending cancels the supplied server send Future. Normative
`PAGI/lib/PAGI/Spec.pod`, Send Completion Contract, says applications SHOULD NOT
cancel `$send` Futures and the effect is unspecified. Task 1 fixes this at Response.

## File responsibilities

- `lib/PAGI/Response.pm`: cancellation shielding of its two buffered sends only.
- New `lib/PAGI/Common.pm` (user-selected location): synchronous public-capability validation,
  first-response admission, and adaptation; no execution or helper access.
- Delete `lib/PAGI/Utils/_Refusal.pm`: remove the old private utility coordinator.
- `lib/PAGI/WebSocket.pm`, `lib/PAGI/SSE.pm`: visible async delegation and small
  progress-derived guards at existing protocol entry points.
- Existing refusal, response, endpoint, and integration tests: observable behavior,
  cancellation propagation, no duplicate protocol output, and cleanup regression.
- Helper/Response POD, Cookbook, examples README, Changes: explain normal await
  ownership and remove obsolete detached-work and refusal-state descriptions.

## Task 1: Protect buffered Response sends without retaining its operation

**Files:** Modify `lib/PAGI/Response.pm`; create `t/response/16-buffered-cancel-send.t`.

**Interfaces:** `Response->to_app` is unchanged. Cancelling its invocation cancels
the response operation but does not cancel an already-submitted server send.

- [ ] Add this public-boundary regression, with Test2::V0, Future, Response and
  `invoke_app` imports, inside a test file using strict/warnings:

```perl
my $pending = Future->new;
my @events;
my $operation = PAGI::Utils::invoke_app(
    PAGI::Response::text_response('no', status => 403),
    {type => 'http'}, sub { die 'unexpected receive' },
    sub { push @events, $_[0]; return $pending },
);
$operation->cancel;
ok($operation->is_cancelled, 'response invocation is cancelled');
ok(!$pending->is_cancelled, 'server owns its submitted send');
$pending->done;
is([map { $_->{type} } @events], ['http.response.start'],
    'cancelled response never resumes to emit its body');
```

- [ ] Cover both pending-start and pending-body cases on `http`, `websocket`,
  and `sse` scopes. For the body case return `Future->done` for start, then park
  the body send; after cancellation/settlement there are exactly the original
  start/body events. Also check a normal send failure still fails invocation.
  Use public `to_app`/`invoke_app`; never cross-class `_emit` in new tests.
- [ ] Run `perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -lv t/response/16-buffered-cancel-send.t`; record expected RED on send cancellation.
- [ ] In `Response::_emit`, add `->without_cancel` to each of the two existing
  `$send->({...})` awaits. The existing send returns a Future. Do not add a
  retained worker, response-wide shield, abort call, or new cancellation signal.

```perl
await $send->({
    type => 'http.response.start',
    status => $plan->{status}, headers => $plan->{headers},
})->without_cancel;
await $send->({
    type => 'http.response.body', body => $plan->{body}, more => 0,
})->without_cancel;
```

- [ ] Document buffered invocation cancellation in Response POD: stops further
  emission, does not cancel a submitted send, does not promise transport abort.
  Run `perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -lr t/response t/pages`.
- [ ] Self-review and commit exact paths as `fix: isolate buffered Response sends from caller cancellation`.

## Task 2: Replace the coordinator with ordinary awaited methods

**Files:** Create `lib/PAGI/Common.pm`; delete `lib/PAGI/Utils/_Refusal.pm`;
modify WebSocket/SSE modules, `t/protocol-refusal-applications.t`,
`t/websocket/denial-response.t`, `t/sse/13-decline.t`,
`t/sse/14-keepalive-deferred-arm.t`, and affected existing state/POD assertions.
Use `t/lib/PAGITest/RefusalHarness.pm`; change it only for an evidenced fixture gap.

**Interfaces:** Private `require_connection($scope, $label)` retains the current
capability checks/diagnostics. Private `prepare_refusal($scope, $label, @targets)` returns
one application value after synchronous validation/adaptation. It receives no
helper. Public `deny($target)`/`decline($target)` return ordinary async Futures
resolving to the helper; errors are Future failures, observed with await/get.

- [ ] Replace the detached-survival test with a cancellation-propagation test
  for both protocols, using the existing harness and its explicit connection end:

```perl
my $gate = Future->new;
my $h = PAGITest::RefusalHarness->new($kind);
my $operation = $h->{helper}->$method(async sub {
    await $gate;
    return PAGI::Response::text_response('no', status => 403);
});
$operation->cancel;
ok($gate->is_cancelled, 'normal cancellation reaches handler dependency');
is($h->{events}, [], 'cancelled handler emits no response');
$h->{connection}->_mark_disconnected('client_closed');
$h->deliver;
```

  Keep meaningful weak-reference checks: after cancellation, caller references
  are dropped and connection cleanup is delivered, cancelled work must not
  keep its helper alive. Do not test universal cancellation of external services.
- [ ] Update pending buffered start/body cancellation tests to assert operation
  cancellation, uncancelled server sends, and no continuation after cancellation.
  Update Stream cancellation tests to expect its existing `app_abort` behavior,
  producer cancellation and once-only cleanup, not forced producer continuation.
  Compare direct Stream invocation with delegated invocation at start/body gates;
  protect the same server sends and async cleanup. Retain disconnect-driven
  resource-release regressions unchanged unless they assert removed phase names.
- [ ] Preserve the eight-form dispatch matrix, exact triplet identity, exactly-once
  handler/to_app calls, invalid target/capability checks, fluent success values,
  live pre-start retry, no-output return, post-start failure and terminal-before-start
  cases. Replace `denying`/`declining` assertions with actual connection progress and
  rejected/no-output subsequent operations. Record RED with:

```sh
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -l t/protocol-refusal-applications.t t/websocket/denial-response.t t/sse/13-decline.t t/sse/14-keepalive-deferred-arm.t
```

- [ ] Move the existing capability validation to `PAGI::Common`, keeping
  only actually consumed public methods and advertised-version diagnostics.
  Implement `prepare_refusal` using that validation, exact-one-target validation,
  `PAGI::Utils::_validate_app_value`, then the following admission/adaptation:

```perl
croak "$label requires a live connection with no response started"
    unless $connection->is_connected && !$connection->response_started;
return ref($target) eq 'CODE'
    ? PAGI::Routing::RequestResponse->new(handler => $target)
    : $target;
```

  `prepare_refusal` calls no `to_app`; `invoke_app` remains responsible for that conversion.
  Change constructor capability-validation call sites to PAGI::Common. Do not
  add exports or move unrelated internal utilities.
- [ ] Implement each helper's method as an async function with this complete
  execution shape (use `decline` and label `SSE decline` in SSE):

```perl
async sub deny {
    my ($self, @targets) = @_;
    my $app = PAGI::Common::prepare_refusal(
        $self->{scope}, 'WebSocket deny', @targets,
    );
    await PAGI::Utils::invoke_app(
        $app, $self->{scope}, $self->{receive}, $self->{send},
    );
    return $self;
}
```

- [ ] Remove refusal-only state mutations/history and pending-operation guards.
  Replace `_refusal_started` with `_response_claimed_before_start`, derived from
  the initial helper phase and public connection progress after terminal refresh:

```perl
sub _response_claimed_before_start {
    my ($self) = @_;
    $self->_refresh_connection;
    my $connection = $self->{scope}{'pagi.connection'} or return 0;
    return $self->{_state} eq 'connecting' && $connection->response_started;
}
```

  Use `pending` in SSE. This indicates an unavailable first-response slot, not
  refusal provenance. No stored flag and no completion callback. Terminal
  helpers use their normal closed paths. Remove private `_denied`/`_declined`
  tests and obsolete pending-refusal phase checks in legacy close paths too.
- [ ] Audit all former `_refusal_started` callers and SSE auto-start paths (`send*`,
  `try_send*`, `each`, `run`, `start`, `keepalive`, `close`). Guard initial claimed
  responses before emitting any protocol event; a no-op `start` alone is not
  enough if its caller then sends data. WS `accept` remains a no-op on a claimed
  initial slot; its sends remain rejected. SSE start/run/send no-op (try variants
  false) while an initial slot is claimed and still live. At terminal state use
  normal closed-stream rules; change old post-decline data-send silent-success
  assertions to closed-stream failures, while start/keepalive/run stay safe.
- [ ] Keep pending SSE keepalive through pre-start failure and normal start.
  Drop it when start/run/keepalive refuses an already-claimed initial slot or at
  terminal refresh. Do not remove it during normal start's in-flight send:
  `response_started` alone does not identify an HTTP refusal. Add assertions for
  normal accepted WS sends and normal SSE start plus keepalive, and sequential
  partial HTTP response followed by every affected auto-start entry point.
- [ ] Update immediate method/state POD and test descriptions alongside behavior.
  Run the focused gate below; replace only superseded requirements. Fix an actual
  missing guard at its existing entry point, not by restoring lifecycle state.

```sh
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -lr t/protocol-refusal-applications.t t/websocket t/sse t/endpoint t/test t/test-client t/response t/auth/04-protocol-integration.t t/upgrading-response-family.t
```

- [ ] Commit exact paths as `refactor: await protocol refusal applications directly`.

## Task 3: Update ownership guidance and verify the complete change

**Files:** Helper and Response POD, `lib/PAGI/Tools/Cookbook.pod`,
`lib/PAGI/Tools/Tutorial.pod`, `examples/protocol-refusal/README.md`, `Changes`;
create `docs/superpowers/plans/2026-09-18-protocol-refusal-ownership-simplification-handoff.md`
after results. Adjust maintained example code only if it asserts the removed
contract. Historical implementation plans/handoffs are not rewritten.

**Interfaces:** Existing six examples remain valid and awaited. Documentation
describes ordinary cancellation, server-send shielding in Response, and separate
connection-owned cleanup. The previous orphan-survival contract is explicitly retired.

- [ ] Replace this Cookbook promise and matching refusal-POD prose:

```text
cancelling a refusal observer does not cancel that retained work.
```

  With:

```text
Await the Future returned by deny or decline. Cancellation follows the invoked
application's normal behavior; the helper does not keep abandoned application
work running. Built-in Responses protect server-owned sends, and connection
terminal notification continues to drive helper cleanup.
```

  Explain retired phase values and ordinary closed-helper behavior. Preserve
  accurate Stream/Writer and close-cleanup documentation; do not globally replace
  every use of retain/observer. Audit maintained code/docs/examples with:

```sh
rg -n 'Utils::_Refusal|run_refusal|denying|declining|_denied|_declined|retained work|refusal observer|cancelling.*(deny|decline)|cancellation.isolated' lib t examples
```

- [ ] Run example/docs checks and all changed POD through podchecker:

```sh
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -l t/integration-protocol-refusal-example.t t/00-pod/cookbook-examples.t t/integration-maintained-examples-load.t
perlbrew exec --with perl-5.42.2@default podchecker lib/PAGI/WebSocket.pm lib/PAGI/SSE.pm lib/PAGI/Response.pm lib/PAGI/Tools/Cookbook.pod lib/PAGI/Tools/Tutorial.pod
```

- [ ] Run the existing real gate verbosely. Preserve Pages, SSE POST bodies, four
  parked refusal disconnect cases, and three accepted-WS close cases. No new
  transport harness or server changes are needed for this simplification.

```sh
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -v -I /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server/.worktrees/feature-websocket-close-truthfulness/lib -l t/integration/protocol-refusal-stream-disconnect.t t/integration/sse-decline-end-to-end.t
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -I /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server/.worktrees/feature-websocket-close-truthfulness/lib -lr t
```

  Use host socket access if sandbox binding fails. Prefer direct commands with
  short PTY/session polls; do not hide the run behind a long shell pipeline.
  Record actual totals/skips, not baseline counts. Minimum-Perl compatibility
  remains syntax-reviewed unless that runtime and its dependencies are available.
- [ ] Request final review against the recorded execution base. Specifically ask
  whether the detached coordinator and rollback are gone, send protection is at
  the correct owner, normal start/keepalive still works, and no alternate orphan
  retention mechanism or new lifecycle framework replaced the removed code.
  Assess mergeability without a predetermined conclusion. Run relevant tests for
  fixes; repeat the full suite after runtime changes, not doc-only edits.
- [ ] Write the new handoff with exact commits, tests/skips, API differences and
  review findings. Commit owned docs as `docs: explain ordinary refusal ownership`.
  Keep the branch local and unrelated files untouched.

## Stop conditions and planning self-review

Stop and discuss a concrete failing case before adding helper-held worker
registries, a replacement reference cycle, blanket cancellation suppression,
send interception, receive arbitration, transient refusal phases, server-specific
state, or changing Stream/Writer ownership. Do not trade the removed coordinator
for a differently named framework. A test expecting the retired contract must
change; a supported cleanup or accepted-stream regression must be fixed.

Coverage: Task 1 isolates buffered sends; Task 2 removes coordinator/state and
tests cancellation plus protocol integration; Task 3 updates user guidance and
proves real transports/full-suite behavior. The exact module/method names match
across tasks. No runtime code or tests were changed while writing this plan.
