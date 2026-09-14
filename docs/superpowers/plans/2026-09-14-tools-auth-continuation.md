# PAGI-Tools Authentication Continuation Implementation Plan

> **For agentic workers:** Use `superpowers:executing-plans` to execute the existing task plans with the reconciliation and gates below. Use `superpowers:subagent-driven-development` if the user chooses delegation. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete PAGI-Tools' adoption of Www 0.6, prove streaming refusal cleanup on real connections, and finish the already approved authentication outcomes Phase 1.

**Architecture:** Auth produces reusable challenge/forbid Pages applications. Pages materializes concrete Responses. WebSocket denial and SSE decline emit ordinary HTTP response events on their original scopes, using the universal connection object to observe termination without competing for receive events. Identity providers and credential enforcement remain a separate phase.

**Tech Stack:** Existing Perl/Future/Test2/PAGI stack; run verification with perlbrew `perl-5.42.2@default`; preserve the distribution's declared Perl 5.18 compatibility and existing dependency boundary.

**Spec:** `../specs/2026-09-04-authentication-outcomes-design.md` and `../specs/2026-09-05-universal-connection-design.md`, interpreted with the merged PAGI specification at `103ad3c`, current server Compliance.pod, and September 13/14 handoffs. The universal design's historical status and several protocol statements predate the merged contract.

**Status:** Proposed continuation, prepared September 14, 2026. No implementation or verification run has occurred in this planning pass. This document preserves the earlier plans and adds a current execution order, corrections, and acceptance gates; their task-level code remains reference material to check against current source.

## Global constraints

- Preserve the original Auth design and plans; do not rewrite their history. Record later rulings and task evidence in the campaign ledgers.
- Implementation is confined to PAGI-Tools. PAGI and PAGI-Server are read-only contract and integration references. Record sibling defects separately.
- Preserve `.pagi-*`, `.superpowers/`, and the unrelated router worktree. Stage only named task-owned paths.
- No new Auth credential parser, identity facade, JWT implementation, policy engine, auth middleware replacement, or automatic login redirect.
- Keep the SSE scope. SSE-to-HTTP redesign and mixed-Accept classification are outside this continuation.
- Use the existing connection object and lifecycle ownership. Do not add a competing receive watcher, cancel server-owned I/O, buffer streamed refusals, or duplicate the server's terminal state machine.
- A narrow wrapper that observes successful start commitment is permitted by Plan C; it must not map protocol event names or infer connection health from send success.
- Each behavior task follows a focused failing-test, implementation, passing-test cycle, then review and a task commit. Record the commit and evidence in a follow-up ledger commit; do not claim a commit contains its own SHA.
- Full-suite verification means recursive discovery: `prove -lr t`. Run focused gates during development, then a full gate at Plan C completion and a final full gate after the remaining Auth work changes the code.
- Keep documented baseline diagnostics distinct from regressions; never suppress warnings merely to obtain a clean log. Capture actual counts, skips, exit status, and unexpected stderr.
- No push, merge, tag, CPAN upload, or downstream notification is part of this planning request. The implementation outcome is a locally reviewed branch and release evidence.

## Why this work exists

Application authors need a common way to express authentication-required and access-forbidden outcomes, with structured Basic/Bearer/custom challenges and Pages-managed HTML, text, or problem-JSON presentation. The same outcome must work as an HTTP response, a refused WebSocket handshake, or a declined SSE stream.

Auth tasks 1–4 implemented and reviewed that vocabulary and `response_for`. Task 5 exposed a pre-existing streaming refusal problem: when a client dropped while the producer waited on unrelated work, the producer could remain retained and cleanup never run. The tests had incorrectly supplied an HTTP-only connection capability on other scopes.

The approved repair was to make connection state universal in the spec and server, then consume it in Tools. The spec and server work has advanced; Tools is still at the pause. Success requires both the lifecycle repair and the remaining examples, documentation, and integration proof for Auth Phase 1.

## Work map

No external ticket number was found. Use the campaign/task identifiers below; do not invent a ticket.

| Repository path | Ticket/campaign | Current branch and observed HEAD | Proposed implementation branch and base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | Universal connection Plan C; Auth Phase 1 tasks 5–8 | `feature/authentication-outcomes-phase1` @ `2733ba2500c1d4117a163b8a07083080a77ce415` | `feature/universal-connection-tools`, based on that exact Auth HEAD; retain the current checkout as requested in the original campaign | Test server, refusal validation/emission, handler/Stream cleanup, legal fixtures, examples, POD and ledgers | Local unreleased Tools changes | None now; configured origin is `https://github.com/jjn1056/PAGI-Tools.git`; publication branch mapping must be decided before a later push |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI` | Plan A, completed; normative reference | `main` @ `103ad3cc96bea77f0f5728ff4c30bbcdb79bf4a0` | No implementation branch | Read-only Www/core contract | No change | None |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server` | Plan B, completed; integration reference | `main` @ `39d7b26f4b1c3c1bebca4fb685d8d026f6252ada` | No implementation branch | Read-only server behavior and Compliance.pod | No change | None |

Reconfirm paths, branches, base commits, and owned changes before implementation, whenever scope changes, and before any future push. Finish Auth tasks 6–8 on the continuation branch after C6 repairs Task 5; do not switch back to an Auth branch lacking Plan C's commits. Integration of those branches is a later explicit boundary.

## Source documents and precedence

1. Merged local PAGI specification and server Compliance.pod establish protocol semantics.
2. `2026-09-13-plan-c-handoff.md` and `2026-09-14-pagi-tools-sse-decline-and-ci-handoff.md` add measured Tools gaps.
3. `2026-09-08-universal-connection-C-pagi-tools.md` provides C1–C7 task details.
4. `2026-09-04-authentication-outcomes-phase1.md` provides remaining Auth tasks 6–8.
5. The two tracking ledgers hold task status and evidence. Old overview paragraphs do not override later corrections.

These newer documents are ignored by `.gitignore`'s `docs/superpowers/` rule. At the first implementation checkpoint, preserve the named continuation plan, source plans/specs needed for execution, handoffs, and campaign ledgers with explicit path staging (force-add only those ignored files). Do not change the global ignore rule or stage the entire notes tree.

## Reconciliation required before copying old task code

| Old instruction or ambiguity | Current continuation requirement |
| --- | --- |
| Auth plan rejects File responses in protocol refusal and requires `body-events-v1` | Plan C supersedes this: ordinary HTTP refusal permits File/fh/trailers with the same relevant HTTP extension requirements; remove the bridge and capability gate. |
| `sse.http.response.*` and `websocket.http.response.*` | Migrate both to bare `http.response.*` across emitters, validators, test clients, tests, and public examples. Old names remain only in explicitly historical migration notes or rejection tests. |
| New handoff describes the SSE rename as separate | Plan C C2–C4 already requires this rename. Incorporate the expanded file list and integration guard correction there; do not build a second patch using the old bridge. |
| Historical clean-return SSE and unspecified post-refusal receive behavior | Use the merged terminal-event and receive-redelivery contract. Handler helpers finish on the application's behalf; raw apps send their required terminal events. |
| Plan C summary omits the SSE object from callback arguments | Preserve the existing leading object: SSE `($sse, $reason, $detail)`; WebSocket `($code, $reason, $detail)`. C5's detailed interface and current source agree. |
| Blindly raise the server version guard to `0.002014` | Current source Server.pm declares `0.002013`, while dist.ini declares `0.002014` and scopes advertise Www `0.6`. Verify the loaded module and behavior. Use a narrow tested contract check or a correctly built distribution for the integration run; never count a skipped checkout test as passing. |
| `prove -l t/` described as the full suite | Use `prove -lr t`; subdirectory tests are part of the acceptance gate. |
| Body-reader handoff suggests broad SSE changes | FormBody/JSONBody currently pass non-HTTP scopes through. Test that boundary; only fix a reader whose supported path can actually encounter the ending. An HTTP-only helper does not acquire SSE support merely because a probe can call it. |
| Server Future::XS lockout mentioned as a possible Tools change | Exercise the affected lifecycle paths and inspect diagnostics. Record an independently reproduced Tools defect; do not automatically duplicate the server lockout. |

## Continuation sequence

### 1. Re-establish the baseline and preserve the work record

- [ ] Reconfirm the work map, create the planned Tools branch from `2733ba2`, and preserve the named planning records in its first checkpoint.
- [ ] Read current Www connection state/refusal/end-of-scope clauses and Compliance.pod; resolve conflicts with old snippets before implementation.
- [ ] Run existing Auth/Pages/Stream/refusal focused tests and the SSE end-to-end test against the checkout server. Capture baseline failures separately; the legacy SSE event rejection is expected from source inspection, but has not been re-run in this session.
- [ ] Record the actual interpreter, loaded server path/version, source commit, optional HTTP/2 dependencies, and test skips. Establish how the integration harness proves the 0.6 contract despite the source version lag.

Baseline focused command, in the project Perl environment:

```bash
prove -lv t/auth/ t/pages/ t/response/03-stream.t t/websocket/denial-response.t t/sse/13-decline.t
```

Checkout integration command:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && PERL5LIB=/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server/lib prove -lv t/integration/sse-decline-end-to-end.t'
```

### 2. Make validation and the test server model the real contract — C1, C2, C3

**Files:** `lib/PAGI/Test/ConnectionState.pm`, `lib/PAGI/Utils/_SendValidation.pm`, `lib/PAGI/Test/Client.pm`, `lib/PAGI/Test/WebSocket.pm`, `lib/PAGI/Test/SSE.pm`; their existing tests under `t/test/` and `t/utils-send-validation.t`.

- [ ] Execute C1: detail, abort, first-terminal-state-wins behavior, late callback delivery, observer isolation, and reference release. Compare the current server contract, not just the old proposed implementation.
- [ ] Execute C2: ordinary HTTP refusal validation on WebSocket/SSE scopes, including streaming/trailers and existing extension constraints; reject removed event names and close-before-accept.
- [ ] Execute C3: attach the connection object to every HTTP/WebSocket/SSE fixture, report core `0.5` / Www `0.6`, and expose refusal responses correctly.
- [ ] Fold in the Test::SSE handoff: clean endings have no fabricated reason; subsequent receive calls reproduce the applicable terminal event rather than parking forever. Test pending and subsequent receives. Keep receive counts bounded; if a server-style cap is modeled, use its documented default 100 and 0-as-unbounded semantics.
- [ ] Run `prove -lv t/test/ t/utils-send-validation.t`, record migration failures awaiting C4 separately, and review each task before dependent work.

**Acceptance:** Raw 0.6 apps can be tested faithfully; completion, disconnect, and refusal are distinguishable; the harness cannot hide a retained producer by parking indefinitely after an end.

### 3. Make refusals ordinary HTTP responses end to end — C4

**Files:** `lib/PAGI/Response.pm`, `lib/PAGI/Response/File.pm`, `lib/PAGI/Response/NDJSON.pm`, `lib/PAGI/WebSocket.pm`, `lib/PAGI/SSE.pm`; protocol, routing, upgrading, and integration tests enumerated in C4 and the September 14 handoff.

- [ ] Rewrite the existing refusal expectations with the current contract; retain assertions for backpressure, start commitment, multi-chunk bodies, File/fh/trailers, cancellation ownership, and refusal before accept/start.
- [ ] Emit the concrete Response on the original scope; remove `_respond_for_protocol`, obsolete capability checks, the WebSocket denial extension, and close-before-accept fallback.
- [ ] Require the needed connection capability for non-buffered refusal and provide a useful synchronous error when absent. Do not infer capability solely from package version text.
- [ ] Migrate all affected test-client and public event names. Add coverage for the corrected integration gate on old servers and the current checkout.
- [ ] Run protocol/routing/response focused tests and the real-server SSE decline test. Verify the intended status/body reaches the client and no stream starts.

**Acceptance:** SSE decline no longer produces the server's unrecognized-event error; WebSocket and SSE refusals use the same response family without event translation or body buffering.

### 4. Repair termination and cleanup — C5 plus September 13 additions

**Files:** `lib/PAGI/WebSocket.pm`, `lib/PAGI/SSE.pm`, `lib/PAGI/Response/Stream.pm`, `lib/PAGI/Response/Writer.pm`; new `t/websocket/connection-object.t`, `t/sse/connection-object.t`; existing `t/response/03-stream.t` and request-body tests.

- [ ] Execute C5's connection-based terminal observation and detail propagation. Preserve callback arguments, exception handling, and exactly-once cleanup when callbacks and receive events both report the ending.
- [ ] On caller cancellation, abort the connection through its public method while preserving server-owned pending-send/receive settlement.
- [ ] Make handler return emit the necessary terminal event exactly once. Cover explicit close, prior disconnect, refusal, and return from a started/accepted scope.
- [ ] Remove synthesized `client_closed` for reasonless SSE clean ends; treat `http.disconnect` after WebSocket refusal as termination, including through `receive_text`.
- [ ] Use a receive-count tripwire in regression tests to detect loops before the server's default cap. Audit Request, MultiPartHandler, FormBody, JSONBody, and `Middleware::buffer_request_body` for supported scope paths and preserve HTTP-only pass-through boundaries.
- [ ] Run `prove -lr t/websocket t/sse t/response t/request t/middleware`; record any actual body-reader changes with their reproductions.

**Acceptance:** A clean app-produced ending stays clean; a real drop carries the server reason/detail; a parked producer terminates; cleanup runs once; no competing reader or repeated-disconnect spin exists.

### 5. Prove the original failure is fixed — C6

**Files:** `t/auth/04-protocol-integration.t`, new `t/integration/protocol-refusal-stream-disconnect.t`; both campaign ledgers.

- [ ] Rebuild the Auth fixtures as legal 0.6 scopes and replace obsolete File/capability assertions.
- [ ] Test WebSocket denial and SSE decline on HTTP/1.1 and HTTP/2. In each row, let the producer write, park on unrelated work, then drop the client mid-body.
- [ ] Assert settlement of the refusal Future, producer cancellation/release, Writer cleanup once, handler cleanup once, and no cancellation of server-owned I/O or unexpected server error log.
- [ ] Prove the four transport/protocol rows actually executed with the checkout or built 0.6 server. A missing optional HTTP/2 dependency is an unmet integration gate, not a passing matrix.
- [ ] Review the regression's ability to catch the original leak, then mark Auth Task 5 complete with the C6 evidence.

### 6. Finish the protocol migration documentation and Plan C gate — C7

**Files:** `lib/PAGI/Middleware/Lint.pm`, `t/middleware/lint.t`, module POD, Cookbook, `Changes`, and the universal connection ledger.

- [ ] Wire refusal validation through Lint for all relevant scopes and run its focused tests.
- [ ] Document the refusal event migration, connection requirement, File support, callback signatures, reasonless clean ends, terminal-event ownership, and abort behavior.
- [ ] Add the handoff's streaming upload-limit recipe: app-owned per-route counting for unknown-length bodies, in-band error when already started, then connection abort. Keep server body limits and app policy distinct.
- [ ] Audit remaining legacy event/capability references and classify historical examples explicitly.
- [ ] Run the recursive Tools suite against the verified 0.6 server. Record optional skips and all diagnostic differences from baseline; review the entire Plan C change.

### 7. Finish the user-facing authentication work — original Auth tasks 6, 7, 8

- [ ] Task 6: create `examples/auth-cookie-login/app.pl`, its README, and `t/integration-auth-cookie-login.t`. Demonstrate explicit session/redirect policy, failed login, session regeneration, protected home, and logout. This demo intentionally does not use the Auth outcome API; preserve that approved distinction.
- [ ] Task 7: add the outcome-only `/apples/auth-required` canary to `examples/starlette-apples/app.pl`; update its README and `t/integration-starlette-apples.t`, preserving existing behavior, synchronized source, and the Python comparison.
- [ ] Task 8: finish Auth/Pages POD, Cookbook/Tutorial, package discovery, load tests, and Changes. Apply the current refusal contract wherever the old task says File is excluded.
- [ ] Run focused example/auth/documentation checks, then `prove -lr t` with the verified server and `dzil build` in the project Perl environment. Inspect the actual generated archive for the three Auth modules and intended public documentation; do not assume a historical archive filename/version.
- [ ] Record final review evidence and remaining issues. Present the local branch as ready for the user's integration/release decision.

## Definition of done and release boundary

- Auth tasks 1–8 have current passing evidence; Task 5's historical invalid fixture no longer serves as proof.
- Plan C C1–C7 are complete with reviewed commits and ledger entries.
- The four real-server refusal/disconnect cases pass and demonstrate cleanup of a producer blocked outside a send.
- Public examples and test clients teach and exercise Www 0.6 consistently; full suite and distribution build pass at the final HEAD.
- No new Phase 2 auth machinery, SSE scope redesign, or sibling-server refactor has entered the patch.

The handoff reports that server ecosystem CI installs released Tools from CPAN. A local fix alone therefore does not clear that downstream canary. Once this branch is reviewed and publication is requested, separately verify current CI and CPAN status, choose the release version, publish the fixed distribution, and observe a fresh canary run. The September 14 CPAN-index-freeze note is historical evidence, not a current release blocker verified by this plan.
