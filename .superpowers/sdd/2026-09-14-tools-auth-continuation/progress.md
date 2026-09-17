# SDD ledger — plan: docs/superpowers/plans/2026-09-14-tools-auth-continuation.md

## September 17 resumption

User authorized resuming all pending continuation work after the server/spec fixes. Work map reconfirmed before implementation:

| Repository | Campaign | Branch / observed HEAD / base | Owned changes | Deployment / push |
| --- | --- | --- | --- | --- |
| /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools | Plan C, Auth Phase 1 | feature/universal-connection-tools / 3ecbcdf / 2733ba2 | C3 onward, examples, docs, tests; preserve existing dirty C3 work and unrelated notes | local only; no push; origin https://github.com/jjn1056/PAGI-Tools.git |
| /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI | normative contract | main / 9aebdbc | read-only | none |
| /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server/.worktrees/feature-websocket-close-truthfulness | integration reference | feature/websocket-close-truthfulness / c0c08f6 / daada36 for duplicate-close delta | read-only | unmerged; none |

Server joint gate passed independently at d80bee8: 9 files / 54 tests, including both private probes, single-frame matrix, deadlines, parity and parked-handler terminal notifications. c0c08f6 only corrects Compliance prose; verified that correction. Spec 9aebdbc adds the successful first close-race rule.

| Shared tasks / interface | Current ruling |
| --- | --- |
| C3 / C5 terminal observation | Current spec supersedes old plan callback snippets: on_end/end_future are authoritative, WS close_code/close_reason are peer metadata, disconnect_reason is the lifecycle token. No competing receiver. |
| C3 raw handler completion | Observe app Future settlement at its ownership boundary, including delayed return; HTTP sends consult published connection state during abort callbacks. |
| C3 / C6 close outcomes | Cooperative peer by default; opt-in deterministic abnormal close outcomes. Assert spec tokens and metadata, never server timers or internal fields. |
| C4 / C5 refusal and cleanup | Original scope, ordinary HTTP Response emission. One retained cleanup Future survives handler return; accepted WS close send completion is distinct from terminal on_close. |
| C5 / C7 callback docs | WS callback code/text comes from connection accessors, not disconnect_reason; SSE preserves object-leading signature. Old snippets conflating WS peer text with lifecycle reason are superseded. |
| All task snippets | Preserve current checkout and unrelated dirty files. No historical coauthor trailers. All spec/server dependencies are read-only. Stop and discuss if fixes require stacked workarounds or a new unsettled contract. |

C3 resumed; C4-C7 and Auth6-Auth8 remain pending. Existing C1/C2 commits and middleware rename remain complete; do not repeat them.

Ruling C3 scheduling: retain dependency-free in-process clients. Existing public client operations and app completion drain deferred terminal notifications outside send/receive; expose documented pump() for tests that manually resolve an external Future and park again without a client operation. Synchronous facts remain immediate. This is test scheduling, not a server-specific timeout model; regressions must cover the explicit external-Future case.

C5 preflight completed by c5_preflight (read-only; c5-resume-preflight.md). Rulings for implementation: preserve WS callback first two args as peer code/text and append diagnostic detail, expose lifecycle reason explicitly; reject on_close registrations after cleanup begins instead of silently retaining them or starting another queue; retain existing absent-connection direct-helper compatibility only, never partial-feature fallbacks on a present connection. Costs: late registration becomes a diagnostic instead of silent loss, and legacy no-object helpers cannot offer the new lifetime guarantees. Endpoint hooks register before on_connect to fit this boundary. User's stop-and-discuss rule remains binding if this requires additional architecture.

C4 preflight found Routing::Compiler::_send_protocol_not_found still emits removed names and a preaccept close fallback; include its direct HTTP404 migration in C4. C5 owns its separate handler-return boundary afterward.

C3 implementation checkpoint ff97913 (base3ecbcdf), implementer c3_resume; focused gate 7 files/96 tests PASS, latest log /tmp/C3-resume-focused-final.txt. Parent caught spurious incomplete-response warning after abort; red regression and HTTP finalization correction included before commit. Full top-level gate had sandbox-only app-proxy binding failure and an unclassified captured-stderr chat route-miss failure assigned to C4 for reproduction. No whole-suite pass claimed. Review c3_resume_review running against review-3ecbcdf..ff97913.diff; do not start dependent implementation until accepted.

C3 review: changes requested (task-C3-resume-review.md). Fix round1 dispatched to c3_resume: failed terminal file capture leaves WS/SSE connection active; manual peer-first app Close overwrites client-visible close metadata; manual peer Close still delivers app data; close_incomplete permits no-peer1006. All are bounded C3 corrections, not a server/spec redesign. Focused probes in /tmp confirmed each. Discarded first Close attempted only after transport loss is explicitly not a finding; preserve existing post-transport no-op boundary. Only t/test gate requested, no host approval or full suite.

Task C3: complete (resumed commits 3ecbcdf..7916c7e, review clean). Fix round1 addressed4/open0, final report and scoped rereview confirm 7 files/101 tests PASS. Final fix delta17 production lines. C4 starts from7916c7e. Source implementation remains on approved Tools branch, sibling repos untouched.

User approved continuation 2026-09-14. Work map reconfirmed: Tools branch feature/universal-connection-tools from 2733ba2; PAGI main 103ad3c and Server main 39d7b26 read-only. No push/release. Current checkout retained per approved plan. Checkpoint cff46ba preserves named source plans, handoffs and spec.

## Preflight and rulings

| Tasks | Shared interface / self consistency | Finding and ruling |
|---|---|---|
| C1 | connection flags / callbacks / abort | Current mock completion flag is separate; make response_complete agree with terminal completion, preserving existing callers of _mark_response_complete until C3 consolidates. Compare current spec, not stale mock POD. |
| C1/C3/C5 | connection state consumed by test server and handlers | Fresh cancellation-isolated disconnect observers, reason/detail, once-only clean vs abnormal callbacks; clear retained hooks. |
| C2/C3/C4/C7 | validation and refusal event namespace | Bare http.response.* everywhere; sequence transitional failures explicitly assigned to C4, not bypassed by aliases. |
| C3/C5/C6 | end events vs connection callbacks | Current merged spec controls re-delivery; no synthesized reason on clean SSE end; callbacks must not erase peer Close protocol metadata. |
| C4 | direct emission and commitment wrapper | Wrapper observes accepted start only; no event mapping or synthetic HTTP scope. File allowed, contrary to original Auth plan. |
| C5 | callback signatures | Preserve SSE object first; append detail to existing WebSocket/SSE signatures. |
| C6 | package version gate vs 0.6 checkout | Source Server.pm 0.002013 differs from dist.ini 0.002014; use measured narrow contract detection or built dist, never a skipped acceptance matrix. |
| C7/Auth8 | shared Cookbook, POD, Changes | C7 documents protocol migration; Auth8 adds user recipes and final distribution evidence without restoring old contracts. |
| Auth6 | cookie example and outcome boundary | Session demo deliberately does not use Auth; no hidden redirect policy in Auth. |
| Auth7 | apples example / source sync | Preserve existing routes and Python checksum; add outcome-only route. |
| All | test commands | Preserve perlbrew PERL5LIB when prepending checkout server. Full suite is recursive. No invented historical coauthor/session attribution. |

Ruling: script task-brief only matches numeric Task headings, while source Plan C uses C1–C7; extract each exact C section into this workspace using the same heading boundaries. This changes artifact generation only.

## Baseline

- Project interpreter perl-5.42.2@default. `prove -l t/auth/ t/pages/ t/response/03-stream.t t/websocket/denial-response.t t/sse/13-decline.t`: PASS, Files=14 Tests=392, 3s; /tmp/tools-continuation-baseline.log.
- First integration invocation overwrote perlbrew's PERL5LIB and could not load IO::Async. Correct command prepends checkout and retains `$PERL5LIB`; sandbox then denied bind. Host integration run requested and running; /tmp/tools-continuation-sse-baseline.log.

## Tasks

- Task C1: complete. Base cff46ba, implementation 6cefc42. Implementer c1_connection_state; reviewer review_c1. Focused 2 files / 47 tests PASS independently; spec and quality PASS, no findings. Reports task-C1-report.md and task-C1-review.md.
- Task C2: complete. Implementer c2_send_validation, base 6cefc42, implementation 0a9616e, fix 4114eb4. Reviewer review_c2: spec/quality PASS after numeric guard fix; independently 1 file / 50 tests PASS. Reports task-C2-report.md, task-C2-review.md, task-C2-rereview.md.
- C3: in progress, implementer c3_test_clients, base f74e309. Brief augmented for HTTP completion consolidation, faithful end-event delivery, captured response decoder, weak abort wiring.
- User pause: implementation agent interrupted after reporting 5 regression files / 75 tests GREEN. Current C3 changes remain uncommitted; independent review and broader t/test gate pending. User wants discussion if this is becoming layered workarounds; no further implementation until that concern is addressed. C1/C2 remain reviewed and committed. Parent cancellation/metadata notes are design risks for C5, not implemented fixes.
- Bounded pause review complete: design-pause-review.md records two reproduced C3 inconsistencies (HTTP abort callback sends captured; delayed raw WS/SSE app return not finalized) and independent C5 assessment. Cancellation has a small existing ownership boundary; WS automatic cleanup versus peer metadata is a real contract decision, not a wiring fix. No implementation resumed. Do not treat earlier C5 callback guidance as settled until user discusses this finding.
- User then requested cross-language research, explicitly including changes to our spec and server as design options. Research complete in docs/superpowers/plans/2026-09-14-connection-terminal-api-research.md. Context7 plus official docs/source cover Python websockets, Node ws, browser API, Go Gorilla, Java Jetty and .NET. Independent server reviewer lifecycle_design_review identified an h1 peer-Close notification/app-return dependency and initiation/completion conflation by source inspection (not a new executed server probe). Recommendation: server-owned stable terminal result, publication before notifications, independent of app receive/return; agree spec/timing then server proof before resuming Tools. New API names are illustrative, not approved. Research work map reconfirmed all three exact revisions. No runtime edits or implementation resumed.
- C4–C7: pending.
- Auth6–Auth8: pending.

Context7 library lookup returned unrelated packages; no PAGI-Tools docs available there. Local committed source/spec is authoritative for this unreleased API.

Baseline update: host integration run reproduced HTTP 500 in place of expected 404/body; Files=1 Tests=1 FAIL. Server path is checkout, banner 0.002013, actual event rejection is the intended 0.6 incompatibility. Log /tmp/tools-continuation-sse-baseline.log.

Ruling C4: `Response::_validate_http_triplet` currently rejects every non-http scope, including the original websocket/sse scopes that C4 requires direct emission on. Expand that boundary to http/websocket/sse (and update its diagnostic/POD/tests) as part of C4. Do not manufacture a scope clone to get around it. This is required by the merged ordinary-HTTP-refusal contract; cost is the intentional 0.6 widening of valid Response invocation scopes.

Ruling C2: `_check_http` has sequence checks, not the `_check_http_start_fields` helper assumed by the old snippet. Reuse the actual HTTP sequencing rules for refusals without copying the body/trailer logic. Ensure status <300 on WebSocket refusal is rejected per current Www; SSE status 200 remains valid. Keep error categories and state unchanged after rejected events.

Ruling C5: The callback-return boundary is in Routing::Compiler and Endpoint::{WebSocket,SSE}::to_app, not inside a raw handler object constructor. Include those existing dispatch boundaries in C5 so successful handler return can call the protocol helper's terminal close when started/accepted and still active. Do not auto-accept a pending scope or close a refused/disconnected scope; do not hide exceptions as clean completion. No destructor-based I/O. This implements the approved C5 behavior without a new lifecycle abstraction.

Ruling C2 review: The status minimum applies to a valid integer status; general field shape remains the sending environment's job. Numeric comparison must not emit coercion warnings or invoke reference overloads. Use the same scalar-decimal precondition as the server's sequence validator, not a new HTTP shape layer.

C5 named review risk: `on_complete` carries no Close-frame metadata and may run before a pending WebSocket receive resolves. Do not fabricate a close code/text or start a new receiver to obtain it. Check the actual existing receive path and on_close ordering, preserving already-observed protocol metadata and ensuring a once-only cleanup callback does not prevent the real terminal receive from updating the handler's close fields. Document unavailable data honestly; if preserving a promised callback semantic requires a new mechanism, report the conflict before stacking a workaround.

C5 body-reader audit: Request constructor explicitly requires type http; its multipart factory is the only production MultiPartHandler caller. FormBody and JSONBody pass non-http scopes through. Middleware::buffer_request_body has no production callers in this repository and is documented for HTTP. There is no supported SSE request-reader path here to broaden; retain these boundaries unless a focused regression establishes a reachable defect.
