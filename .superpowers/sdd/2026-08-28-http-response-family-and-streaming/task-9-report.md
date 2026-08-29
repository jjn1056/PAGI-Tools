# Task 9 report — Concrete failsafe responses

Date: 2026-08-29
Status: implementation complete; parent review pending

## Work map

| Repository | Ticket | Branch | Base | Owned changes | Deployment boundary | Push target |
|---|---|---|---|---|---|---|
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/.worktrees/http-response-family-and-streaming` | HTTP response family and streaming, Task 9 | `feat/http-response-family-and-streaming` | `main` at `d7827d2617ae3307301b07f75c260239f3b7239d`; task starts at `794777e447fcd3bb9abcbbb95ea0d55b63cdc23d` | `PAGI::Middleware::ErrorHandler`, Compose HTTP response completion/guard behavior, Router stock HTTP outcomes, the ten named test files, direct stock-outcome caller `t/endpoint-router.t`, and this report | unreleased PAGI::Tools library/tests only; no release or deployment | none; parent task owns integration/push |

The repository is a linked worktree on the requested branch, with no upstream configured and no pre-existing changes. No second repository is in scope. The map was reconfirmed when the Router migration exposed one clean direct caller: `t/endpoint-router.t` now requests its asserted problem representation explicitly instead of assuming stock NONE is unconditionally JSON. The architecture, ticket, deployment boundary, and push target did not change.

## TDD evidence

### Untouched baseline

Before any test or production edit, the required command was run under Perl 5.42.2:

```text
prove -lv t/compose/01-description.t t/compose/02-dispatch.t t/compose/03-lifespan.t t/compose/04-middleware.t t/compose/05-head-concurrency.t t/compose/06-failsafes.t t/compose/07-response-guard.t t/middleware/03-error-handler.t t/middleware/error-handler-contract.t t/routing/16-http-outcomes.t
```

Exact summary:

```text
Files=10, Tests=146, Result: FAIL
```

The dominant failure was the verified Task 9 blocker at Compose/ErrorHandler construction:

```text
ErrorHandler configured status cannot be rendered completely; a handler is required
```

Tracing confirmed `_pages_accepts_status` called finalized `PAGI::Pages->status($status)` without the required request metadata source. The untouched ErrorHandler contract also still used removed Response factories, the Request response bridge, response-like duck typing, and one-argument emission.

### Semantic RED after the full named test migration

Before production edits, route fixtures were migrated to `PAGI::Response::Text`/`::Empty`; the configured Pages Router default was adapted explicitly with `request_app`; custom ErrorHandler tests required immediate/Future concrete Response values and no Request response bridge; Router stock outcomes were required to negotiate Pages text; and focused NONE/PARTIAL start/body send-failure probes were added.

The exact required command then reported:

```text
Files=10, Tests=147, Result: FAIL
```

Representative semantic failures were:

```text
ErrorHandler configured status cannot be rendered completely; a handler is required
handler did not return a status-aware response
Response requires an unblessed HTTP scope hashref
stock NONE/PARTIAL returned application/problem+json when text/plain was requested
```

The last two exposed the obsolete one-argument response emission and the direct Problem stock outcomes. The new Router start/body send-failure probes were already green, proving that send settlement and no-retry behavior needed no new disconnect or cancellation policy.

### Minimal implementation

- `ErrorHandler::_pages_accepts_status` now exercises Pages with a complete inert HTTP metadata source instead of relying on removed no-source arity.
- Custom handlers still receive exactly `(PAGI::Request, $original_error)`, but their immediate/Future result must now be a nominal concrete `PAGI::Response`.
- Returned custom or Pages responses are status-seeded with `status_try` and emitted exactly once with `respond($request_scope, $receive, $wrapped_send)`.
- Reporting order, exact original exception identity, pre-start last-resort behavior, and post-start report/rethrow remain unchanged.
- Router stock NONE constructs `Pages->not_found($request)` through the existing HTTP handler adapter; PARTIAL constructs `Pages->method_not_allowed($scope, allow => $first_seen_union)` and emits it with one full triplet.
- The outer request-local Allow adapter still repairs only Router-generated 405 responses after all Router/Mount middleware. No send cancellation, disconnect inference, response buffering, compatibility adapter, or Response-object inspection was introduced.
- ResponseGuard code remained event-only; its POD now states that boundary explicitly.

### GREEN and focused failure probes

Focused ErrorHandler/Router command:

```text
prove -lv t/middleware/03-error-handler.t t/middleware/error-handler-contract.t t/routing/16-http-outcomes.t
All tests successful.
Files=3, Tests=45, Result: PASS
```

The required complete cone was then rerun:

```text
All tests successful.
Files=10, Tests=156, Result: PASS
```

This includes built-in/custom handler rendering, immediate/Future returns, status seeding, reporter settlement and failure containment, exact original object/string rethrow after start, synchronous/failed-Future outer send errors, hardcoded last-resort start/body failures, Router NONE/PARTIAL start/body failures, before-start replacement, after-start incomplete response, response completion, HEAD, concurrency, lifespan, and silent-app failure.

### Clean direct-caller expansion

After Router stock responses became negotiated Pages values, the previously blocked Pages integration passed, while `t/endpoint-router.t` exposed one Task 8-era assumption that NONE was unconditionally JSON. That direct caller was migrated to request `application/problem+json` explicitly and assert the complete RFC 9457 stock document.

Caller RED:

```text
Files=2, Tests=15, Result: FAIL
got text/html; charset=utf-8, expected application/problem+json
```

After adding the explicit Accept request, one further test-only RED identified the final Pages document's required `type` and `detail` fields. The literal expectation was completed, then the adjacent command passed:

```text
prove -lv t/endpoint-router.t t/integration-pages-example.t
All tests successful.
Files=2, Tests=15, Result: PASS
```

### Syntax, POD, and diff gates

The three required modules compiled and passed POD validation under Perl 5.42.2:

```text
lib/PAGI/Compose/ResponseGuard.pm syntax OK
lib/PAGI/Middleware/ErrorHandler.pm syntax OK
lib/PAGI/Routing/Compiler.pm syntax OK
lib/PAGI/Compose/ResponseGuard.pm pod syntax OK.
lib/PAGI/Middleware/ErrorHandler.pm pod syntax OK.
lib/PAGI/Routing/Compiler.pm pod syntax OK.
```

`git diff --check` exited 0.

After the final review pass, the exact ten-file command was rerun from the
tree to be committed:

```text
All tests successful.
Files=10, Tests=156, Result: PASS
```

The adjacent direct-caller command was also rerun from that same tree:

```text
All tests successful.
Files=2, Tests=15, Result: PASS
```

All three modules again reported `syntax OK` and `pod syntax OK`; the final
`git diff --check` exited 0.

## Changed files

- `lib/PAGI/Compose/ResponseGuard.pm`: documents its existing event-only, non-buffering completion boundary.
- `lib/PAGI/Middleware/ErrorHandler.pm`: explicit Pages validation source, nominal concrete Response contract, full-triplet emission, and matching POD.
- `lib/PAGI/Routing/Compiler.pm`: negotiated Pages-backed stock 404/405 Responses with authoritative first-seen Allow and matching POD.
- `t/compose/01-description.t`
- `t/compose/02-dispatch.t`
- `t/compose/04-middleware.t`
- `t/compose/05-head-concurrency.t`
- `t/compose/06-failsafes.t`
- `t/middleware/error-handler-contract.t`
- `t/routing/16-http-outcomes.t`
- `t/endpoint-router.t`: clean direct stock-outcome caller migration.
- `.superpowers/sdd/2026-08-28-http-response-family-and-streaming/task-9-report.md`

The other named files (`t/compose/03-lifespan.t`, `t/compose/07-response-guard.t`, and `t/middleware/03-error-handler.t`) already expressed final event/failure behavior and required no textual change; all are included in the GREEN gate.

## Self-review and concerns

- Mutation check: restoring the no-source Pages call breaks ErrorHandler/Compose construction; restoring one-argument `respond` breaks built-in and custom concrete responses; accepting `can('respond')` makes the two response-like rejection cases fail; restoring direct Problem stock outcomes breaks text negotiation; changing or dropping first-seen Allow breaks nested-authority tests; retrying either send breaks exact attempted-event probes.
- ErrorHandler reports the original application failure before resolving status or rendering. Renderer and response-send failures propagate outward without replacing that original reporting record. After-start failures still skip rendering and rethrow the exact original exception.
- Ordinary downstream responses are not buffered. ResponseGuard observes only actual events and has no dependency on Response classes or object mutation state.
- PAGI send Futures remain server-owned and authoritative. The implementation awaits them, adds no disconnect inference, and never cancels them.
- No old Pages arity, Response finisher, one-argument Response emission, handler arity inference, compatibility alias, duplicate status policy, or compensating state was introduced.
- A broader characterization (`prove -lr t/routing t/app-router t/compose ...`) reported `Files=33, Tests=386, Result: FAIL` only in already-scheduled later caller migrations: multiple non-named Routing/App Router tests still invoke removed `PAGI::Response->text`, and `examples/declarative-routing/app.pl` still calls Pages without a source. The complete Task 9 cone and the one newly exposed direct caller are green. Expanding into those later test/example ownership groups would duplicate subsequent migration tasks, so no compatibility bypass was added.
- The supplied instruction forbids subagents. Independent error/failure-path review is therefore deferred to the parent/controller; this report contains the local self-review and exact evidence for that review.
