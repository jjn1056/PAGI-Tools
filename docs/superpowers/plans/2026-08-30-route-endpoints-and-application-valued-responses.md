# Route Endpoints and Application-Valued Responses Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every Route endpoint either a one-argument protocol handler or an instantiated PAGI application, make HTTP handlers return application values, turn Pages factories into deferred applications, and remove the competing public `Response->respond` and nominal `is_response` contracts without changing PAGI settlement behavior.

**Architecture:** `PAGI::Utils` owns the coderef-or-instantiated-`to_app` application contract and the explicit `as_app`, `request_response`, and `invoke_app` bridges. An immutable Route stores `endpoint`, snapshots HTTP method metadata once, and compiles CODE endpoints through `PAGI::Routing::RequestResponse`; returned application values are invoked against the original triplet. Response subclasses and deferred Pages components are ordinary HTTP applications. App::Router and Endpoint::Router materialize the same declaration model. The public `respond` seam is removed only after all consumers have migrated to `invoke_app`, and its final change is a mechanical private-emission rename guarded by the existing File, Stream, denial, decline, cancellation, and settlement suites.

**Tech Stack:** Perl 5.18-compatible distribution code; Perl 5.40 signatures only in already-modern examples; `Future`, `Future::AsyncAwait`, `PAGI::Request`, `PAGI::Routing`, `PAGI::Response`, `PAGI::Pages`, `PAGI::Endpoint`, `Test2::V0`, `PAGI::Test::Client`, POD, and Dist::Zilla. PAGI 0.002007 and PAGI::Server 0.002011 are read-only protocol and integration authorities. No new runtime dependency.

**Spec:** `docs/superpowers/specs/2026-08-30-route-endpoints-and-application-valued-responses-design.md` at reviewed commit `426c67f72ba30ac5b21fafb2ea31bba9c8590f6b`.

## Global Constraints

- The approved contract is the specification above. If implementation evidence conflicts with it, stop, record a deviation, and obtain the user's decision before dependent work continues.
- Work only in `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` or an isolated worktree created for this repository through `superpowers:using-git-worktrees`.
- Preserve the unrelated untracked `.pagi-*` files and existing `.superpowers/` material. Never stage them with `git add .` or `git add -A`.
- This is an intentional breaking redesign of unreleased PAGI-Tools APIs. Do not retain aliases, warnings-only migrations, dual endpoint grammars, hidden arity inference, or compatibility branches for Route `raw`, `target`, `is_raw`, `request_app`, old Pages `_page` exports, public `respond`, or `is_response`.
- Keep distribution modules and ordinary tests compatible with the declared Perl 5.18 floor. Use project Perl 5.42.2 for functional verification. Do not add workarounds for Perl 5.16.
- A PAGI application value is exactly a native three-argument coderef or an instantiated object with `to_app`. Package names, callable overloads, unblessed references, and Response-like duck types without `to_app` are invalid.
- A Route CODE endpoint is always a one-argument handler. Native CODE applications at Route positions must be wrapped explicitly with `as_app`; Mount, Compose, Router `http_default`, and other native application positions continue accepting a three-argument coderef directly.
- HTTP handlers may return any application value, but ordinary docs and examples use Response or Pages applications. Dynamic return of arbitrary apps is documented as advanced delegation and receives the unchanged scope and remaining body stream.
- Explicit Route `methods` wins. Otherwise, an HTTP object endpoint's `allowed_methods` is called once in list context at Route construction; otherwise the Route defaults to GET plus automatic HEAD. Only scalar `methods => '*'` is unrestricted.
- WebSocket and SSE Route construction never consults `allowed_methods` and never accepts `methods`.
- Every possibly immediate handler, endpoint, application, or middleware result is normalized with `Future->wrap`; never directly await a value that may not be a Future.
- Every `$send` Future is awaited. Do not add buffering, body replay, hidden application caches, overlapping writes, or event interception to make the redesign work.
- Preserve `.pagi-0.5-settlement-streaming-correction.md`: send-Future backpressure, await-then-check disconnect settlement, cancellation-isolated observers, File's denial-body opt-out, and WebSocket/SSE response-start ownership remain unchanged.
- Do not restructure File, Stream, Writer, WebSocket denial, or SSE decline while removing `respond`. The final seam removal is a mechanical rename/delegation change followed immediately by the named lifecycle gate.
- Middleware remains pure app-to-app transformation. This campaign may replace Response emission with `invoke_app`, but it must not redesign middleware resolution or introduce a value-flow `$next` tier.
- Route remains an exact, method-aware leaf. Mount remains prefix/subtree composition and scope rewriting. Endpoint shape never changes path ownership.
- Pages factories return deferred HTTP applications. They negotiate only when invoked, export nothing by default, reject old source-first calls, and throw on lifespan, WebSocket, SSE, or unknown scopes without emitting events.
- A Pages application used as the server root follows PAGI lifespan behavior: automatic mode treats its lifespan exception as a decline and continues; strict mode rejects it. Pages does not implement lifespan itself.
- Use strict TDD per task: add the smallest focused failing assertion, run and record the semantic RED, implement the minimum contract, then run the named GREEN gate.
- A focused task gate may expose failures owned by a later named half-migration. Inspect and record those failures; unrelated or ambiguous failures stop the task.
- File-count growth is not itself a warning. Stop for design review if progress requires repeated special cases, duplicate policy, compensating state, response replay, hidden caches, test bypasses, or compatibility shims merely to make the code fit.
- Every implementation task ends with a focused implementation commit, an immediate ledger evidence update, and independent review before a dependent task begins.
- Run the repository-wide `prove -lr t` suite only at the final integration boundary. Do not run `dzil test`; run one `dzil build` after the final suite. If a fix changes HEAD, record it and run one new final suite at the corrected HEAD.
- Use `PAGI::Test::Client` for complete HTTP behavior. Use direct scope/receive/send recorders for exact application invocation, protocol events, cancellation, settlement, and invalid-boundary tests.
- All maintained examples under `examples/` are in scope. `examples/starlette-apples` is the canary and gets a dedicated migration and integration task before the remaining examples.

Functional test commands use project Perl:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/utils/application-values.t'
```

## Work Map

Record and reconfirm this map before implementation, whenever scope or architecture changes, and before any authorized push:

| Repository | Ticket | Execution branch | Base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | None; approved WIP design campaign | isolated feature branch/worktree created by the selected execution skill | `main@426c67f72ba30ac5b21fafb2ea31bba9c8590f6b`; execution records the actual starting SHA | Application utilities, Routing/Route/Compiler, App and Endpoint Router frontends, Endpoint::HTTP, Pages, Response emission seam, first-party callers, all maintained examples, tests, live POD, `UPGRADING.md`, and Changes | Unreleased PAGI-Tools; no CPAN release, tag, merge, or deployment in this plan | `origin/main` only after explicit user authorization |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI` | PAGI application and settlement contracts | released `main`; read-only | PAGI `0.002007`, core 0.5 / Www 0.4 | Normative reference only | Published on CPAN | None |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server` | PAGI loading and settlement conformance | released `main`; read-only | PAGI::Server `0.002011` | Integration reference only | Published on CPAN | None |

If a PAGI or PAGI::Server defect is discovered, stop and open a separate work item. Do not edit either sibling repository from this campaign.

## Execution Tracking and Deviation Control

Before Task 1, create the isolated workspace with the selected execution skill. For subagent-driven execution, run:

```bash
/Users/jnapiorkowski/.codex/plugins/cache/openai-curated-remote/superpowers/6.3.0/skills/subagent-driven-development/scripts/sdd-workspace docs/superpowers/plans/2026-08-30-route-endpoints-and-application-valued-responses.md
```

Create `.superpowers/sdd/2026-08-30-route-endpoints-and-application-valued-responses/progress.md` with this structure:

```markdown
# SDD ledger — Route endpoints and application-valued responses

Starting HEAD: record the exact 40-character execution SHA

| Task | Status | Implementation SHA | Review/fix SHAs | Focused verification and actual counts | Full-suite/build evidence | Verdict |
|---|---|---|---|---|---|---|
| 1 | pending | — | — | — | deferred to Task 13 | — |
| 2 | pending | — | — | — | deferred to Task 13 | — |
| 3 | pending | — | — | — | deferred to Task 13 | — |
| 4 | pending | — | — | — | deferred to Task 13 | — |
| 5 | pending | — | — | — | deferred to Task 13 | — |
| 6 | pending | — | — | — | deferred to Task 13 | — |
| 7 | pending | — | — | — | deferred to Task 13 | — |
| 8 | pending | — | — | — | deferred to Task 13 | — |
| 9 | pending | — | — | — | deferred to Task 13 | — |
| 10 | pending | — | — | — | deferred to Task 13 | — |
| 11 | pending | — | — | — | deferred to Task 13 | — |
| 12 | pending | — | — | — | deferred to Task 13 | — |
| 13 | pending | — | — | — | final gate | — |

## Deviations

| ID | Status | Conflicting plan/spec text | Evidence and rationale | Affected tasks | User decision |
|---|---|---|---|---|---|
```

Write the starting SHA plus one newline to `starting-head`. Create `public-surface-inventory.md` beside the ledger. Inventory the current and final forms of:

- `PAGI::Utils` app helpers;
- Routing exports, Route accessors, constructor grammars, and Router defaults;
- App::Router and Endpoint::Router declarations;
- Endpoint::HTTP return and lifetime contracts;
- Pages methods and export bundles;
- Response, File, Stream, Writer, denial, and decline emission seams; and
- every current occurrence of `raw`, `request_app`, `_page`, `is_response`, and public `respond` under `lib/`, `t/`, and `examples/`.

Use classifications `retained`, `replaced by approved design`, or `deferred by approved design`; Task 13 permits no unclassified row. After each implementation commit, record its SHA, exact focused command, actual test/assertion counts, elapsed time, and reviewer verdict in the same working step before beginning the next task. A scope conflict receives the next stable `DEV-NNN` identifier, status `awaiting decision`, exact evidence, affected tasks, and the user's explicit ruling before dependent work resumes.

## Specification Coverage Map

| Design area | Owning tasks |
| --- | --- |
| Application values and utilities (§7) | Tasks 1–2 |
| Route declaration and method capability (§8) | Task 3 |
| RequestResponse and HTTP dispatch (§9) | Task 4 |
| Response application and protocol settlement (§10) | Tasks 8 and 11 |
| Deferred Pages factories (§11) | Task 6 |
| Other application positions (§12) | Tasks 1, 6, and 8 |
| Endpoint classes and Router frontends (§13) | Tasks 5 and 7 |
| Synchronous execution and middleware scope (§§14–15) | Tasks 2, 4, 7, and 8 |
| Apple comparison (§16) | Task 9 |
| Diagnostics, migration, and maintained examples (§§17–19) | Tasks 3–10 and 12 |
| Required behavior (§20) | Tasks 1–11; final evidence in Task 13 |
| Acceptance criteria (§23) | Task 13 |

---

### Task 1: Add the Shared Application Adapters

**Files:**

- Modify: `lib/PAGI/Utils.pm`
- Create: `lib/PAGI/Utils/_App.pm`
- Create: `t/utils/application-values.t`
- Modify: `t/utils-to-app.t`

**Interfaces:**

- `as_app($code) -> instantiated object with to_app`
- `invoke_app($value, $scope, $receive, $send) -> Future`
- existing `to_app($value) -> CODE` remains the one normalization primitive
- `as_app`, `invoke_app`, and later `request_response` are opt-in and included in `:all`; nothing is exported by default

- [ ] **Step 1: Initialize campaign evidence.** Create the worktree, ledger, starting-head file, and public-surface inventory. Record the preserved untracked files and the complete baseline searches:

  ```bash
  rg -n "request_app|raw =>|is_response|_page\\b|->respond\\(" lib t examples
  rg -n "^sub |^async sub |EXPORT|EXPORT_OK|EXPORT_TAGS" lib/PAGI/Utils.pm lib/PAGI/Routing.pm lib/PAGI/Pages.pm lib/PAGI/Response.pm lib/PAGI/Response
  ```

- [ ] **Step 2: Write failing utility tests.** Pin exact CODE identity, distinct `as_app` wrapper identity, object `to_app` call counts, invalid package/hash/middleware/broken-object diagnostics, exact triplet identity, immediate completion, Future completion, and failure propagation:

  ```perl
  my $component = as_app($native);
  is(to_app($component), $native, 'as_app exposes the exact native app');

  await invoke_app($component, $scope, $receive, $send);
  is($seen, [$scope, $receive, $send], 'invoke_app preserves the triplet');
  ```

- [ ] **Step 3: Run the RED gate.**

  ```bash
  prove -lv t/utils/application-values.t t/utils-to-app.t
  ```

  Record missing exports/modules as the expected failure.

- [ ] **Step 4: Implement the minimum adapters.** `PAGI::Utils::_App` stores exactly one coderef and returns it unchanged from `to_app`. `invoke_app` must be an `async sub`, call `to_app($value)` once, invoke the result once, and await `Future->wrap($returned)`. It must not catch, translate, or validate PAGI events.

- [ ] **Step 5: Run the GREEN gate and syntax check.**

  ```bash
  prove -lv t/utils/application-values.t t/utils-to-app.t
  perl -Ilib -c lib/PAGI/Utils.pm
  perl -Ilib -c lib/PAGI/Utils/_App.pm
  ```

- [ ] **Step 6: Commit and record evidence.** Stage only the four task files, commit `feat: add explicit PAGI application adapters`, update the Task 1 ledger row with the implementation SHA and actual counts, then review for arity inspection, extra state, exception translation, or protocol policy.

---

### Task 2: Introduce the RequestResponse Component

**Files:**

- Create: `lib/PAGI/Routing/RequestResponse.pm`
- Modify: `lib/PAGI/Utils.pm`
- Create: `t/routing/17-request-response.t`
- Modify: `t/utils/application-values.t`

**Interfaces:**

- `request_response($handler) -> PAGI::Routing::RequestResponse`
- `PAGI::Routing::RequestResponse->new(handler => $code)`
- `to_app() -> CODE`, constructing one `PAGI::Request` per invocation and invoking the returned application value against the original triplet

- [ ] **Step 1: Write failing constructor and invocation tests.** Cover exact class identity, handler validation, non-HTTP rejection before handler invocation, one Request argument, immediate and Future-backed handler results, returned native CODE and returned `to_app` object, one object compilation per request, no cross-request returned-app cache, unchanged scope, remaining receive channel identity, and invalid/undef result diagnostics.

- [ ] **Step 2: Pin concurrency and body ownership.** Start two handler invocations with distinct scopes and pending returned applications; prove each invocation retains its own Request/triplet. In a body-stream case, consume one request event in the handler and prove the returned advanced app sees only the remaining receive events.

- [ ] **Step 3: Run the RED gate.**

  ```bash
  prove -lv t/routing/17-request-response.t t/utils/application-values.t
  ```

- [ ] **Step 4: Implement RequestResponse.** Validate the handler at construction. In `to_app`, validate `scope->{type} eq 'http'`, create `PAGI::Request->new($scope, $receive)`, await `Future->wrap($handler->($request))`, validate with the shared application-value contract, and `await invoke_app(...)`. Do not inspect signatures, replay the body, install HEAD/lifespan/error boundaries, or cache dynamic results.

- [ ] **Step 5: Export `request_response` only from Utils.** Include it in `@EXPORT_OK` and `:all`; do not add a duplicate Routing export.

- [ ] **Step 6: Run the GREEN gate.**

  ```bash
  prove -lv t/routing/17-request-response.t t/utils/application-values.t t/utils-to-app.t
  perl -Ilib -c lib/PAGI/Routing/RequestResponse.pm
  ```

- [ ] **Step 7: Commit and record evidence.** Commit `feat: add Request handler application adapter`. Review that every possibly immediate result uses `Future->wrap`, `to_app` is called once per handler invocation, and the original triplet is unchanged.

---

### Task 3: Replace Route Target Modes with One Endpoint Model

**Files:**

- Modify: `lib/PAGI/Routing/Route.pm`
- Modify: `lib/PAGI/Routing.pm`
- Modify: `t/routing/01-constructors.t`
- Modify: `t/routing/03-reverse-inspection.t`
- Modify: `t/routing/05-http-dispatch.t`
- Modify: `t/routing/08-protocols.t`
- Modify: `t/routing/09-metadata-isolation.t`

**Interfaces:**

- canonical `PAGI::Routing::Route->new(path => $path, endpoint => $value, %opts)` constructs HTTP Routes
- concise `route($path => $endpoint, %opts)`, `websocket(...)`, and `sse(...)`
- accessors include `endpoint`; `target` and `is_raw` are removed
- method precedence is explicit `methods`, object `allowed_methods`, then GET+HEAD; only scalar `'*'` is unrestricted

- [ ] **Step 1: Rewrite constructor tests to the final grammar.** Assert functional/object equivalence, endpoint identity, declaration package/provider behavior, option duplication/odd-list/unknown-option errors, CODE/object acceptance, package/unblessed rejection, and absence of `target`/`is_raw`.

- [ ] **Step 2: Add the complete method matrix.** Use objects with counting `allowed_methods` methods to prove:

  ```perl
  is(route('/a' => $endpoint)->methods,
      [qw(GET HEAD POST OPTIONS)], 'capability is normalized once');
  is(route('/a' => $endpoint, methods => ['PATCH'])->methods,
      ['PATCH'], 'explicit methods win without consulting the capability');
  is(route('/file' => $response)->methods,
      [qw(GET HEAD)], 'ordinary application objects use the safe default');
  is(route('/relay' => as_app($native), methods => '*')->methods,
      '*', 'unrestricted dispatch is explicit');
  ```

  Reject empty lists, Future/reference results, malformed tokens, `'*'` from the capability, `['*']`, and mixed wildcard lists. Prove case normalization, duplicate removal, and GET-to-HEAD ordering. Prove the capability is a construction-time snapshot and is never consulted for WebSocket/SSE.

- [ ] **Step 3: Run the RED gate.**

  ```bash
  prove -lv t/routing/01-constructors.t t/routing/03-reverse-inspection.t t/routing/08-protocols.t t/routing/09-metadata-isolation.t
  ```

- [ ] **Step 4: Implement a duplicate-aware canonical option parser.** Do not construct `%opts` until duplicate keys have been rejected. Keep `_new_from($declaration_package, $kind, ...)` as the internal functional-constructor seam, but store `endpoint` only.

- [ ] **Step 5: Implement method resolution at immutable construction.** Call `allowed_methods` once in list context only for HTTP object endpoints without explicit `methods`. Normalize through the same token path as explicit methods. Reject zero methods loudly rather than creating a route that can never match.

- [ ] **Step 6: Remove Routing's `request_app` export and implementation.** `request_response` belongs to `PAGI::Utils`; update import tests accordingly. Do not yet remove stale examples or POD—Tasks 9, 10, and 12 own those migrations.

- [ ] **Step 7: Run the GREEN gate.**

  ```bash
  prove -lv t/routing/01-constructors.t t/routing/03-reverse-inspection.t t/routing/05-http-dispatch.t t/routing/08-protocols.t t/routing/09-metadata-isolation.t
  perl -Ilib -c lib/PAGI/Routing/Route.pm
  perl -Ilib -c lib/PAGI/Routing.pm
  ```

- [ ] **Step 8: Commit and record evidence.** Commit `refactor: make Route endpoints explicit application values`. Review for accidental unrestricted object routes, multiple capability calls, mutable method arrays, or protocol capability leakage.

---

### Task 4: Compile HTTP Endpoints and Returned Applications

**Files:**

- Modify: `lib/PAGI/Routing/Compiler.pm`
- Modify: `t/routing/05-http-dispatch.t`
- Modify: `t/routing/06-head.t`
- Modify: `t/routing/10-head-boundary.t`
- Modify: `t/routing/16-http-outcomes.t`
- Modify: `t/integration-router-application-boundaries.t`
- Modify: `t/routing/17-request-response.t`

**Interfaces:**

- a static CODE endpoint is compiled once through one RequestResponse component per Router compilation
- a static object endpoint's `to_app` is called once per Router compilation
- returned applications are normalized and invoked once per request
- Router owns FULL/PARTIAL/NONE and the deterministic first-seen Allow union

- [ ] **Step 1: Add failing compilation-lifetime tests.** Compile one Router twice and prove two independent static endpoint compilations. Run multiple concurrent requests through one compiled app and prove no returned app, Request, capture, or Allow state crosses requests.

- [ ] **Step 2: Pin HTTP selection with capability-derived methods.** Route a `PAGI::Endpoint::HTTP`-style object and prove GET, HEAD, and OPTIONS select it; an unsupported method becomes Router PARTIAL; sibling routes at the same path contribute a first-seen union without sorted reordering; Router reasserts one authoritative Allow header only for its generated 405.

- [ ] **Step 3: Pin HEAD behavior.** A Response object endpoint defaults to GET+HEAD, its GET body-derived headers are identical on HEAD, the final boundary suppresses body and file events, and an earlier explicit HEAD Route prevents an expensive GET/Stream handler from running.

- [ ] **Step 4: Run the RED gate.**

  ```bash
  prove -lv t/routing/05-http-dispatch.t t/routing/06-head.t t/routing/10-head-boundary.t t/routing/16-http-outcomes.t t/routing/17-request-response.t t/integration-router-application-boundaries.t
  ```

- [ ] **Step 5: Replace `_compile_http_handler` with RequestResponse compilation.** CODE endpoints compile through `request_response($handler)->to_app`; object endpoints compile with `PAGI::Utils::to_app`. Keep route middleware outside the compiled leaf app and inside the Router's final HEAD boundary.

- [ ] **Step 6: Emit generated responses as applications.** For the transitional old Pages API, let RequestResponse invoke the returned Response application. Do not call `respond` in new Compiler code. Task 6 replaces the old Pages call shape.

- [ ] **Step 7: Run the GREEN gate.** Use the command from Step 4, then:

  ```bash
  perl -Ilib -c lib/PAGI/Routing/Compiler.pm
  ```

- [ ] **Step 8: Commit and record evidence.** Commit `refactor: invoke application-valued HTTP endpoints`. Review exact middleware/HEAD ordering, one-time static compilation, per-invocation dynamic compilation, and first-seen Allow behavior.

---

### Task 5: Align WebSocket and SSE Endpoint Classification

**Files:**

- Modify: `lib/PAGI/Routing/Compiler.pm`
- Modify: `t/routing/08-protocols.t`
- Modify: `t/websocket/denial-response.t`
- Modify: `t/sse/13-decline.t`
- Modify: `t/integration/sse-decline-end-to-end.t`

**Interfaces:**

- WebSocket/SSE CODE endpoints remain one-argument direct protocol handlers whose completion is awaited
- WebSocket/SSE object endpoints are native applications compiled through `to_app`
- native protocol CODE apps use `as_app`; no `raw` branch remains

- [ ] **Step 1: Add failing protocol classification tests.** Cover named and anonymous CODE handlers, `as_app($native)`, instantiated object apps, immediate/Future completion, exact protocol-object argument, exact native triplet, one static compilation per Router compilation, no method-capability call, and package/unblessed rejection.

- [ ] **Step 2: Prove protocol misses and response-valued denial/decline remain unchanged.** Keep clean WebSocket close/denial and SSE decline event prefixes, start ownership, no duplicate start, and File capability rejection.

- [ ] **Step 3: Run the RED gate.**

  ```bash
  prove -lv t/routing/08-protocols.t t/websocket/denial-response.t t/sse/13-decline.t t/integration/sse-decline-end-to-end.t
  ```

- [ ] **Step 4: Simplify `_compile_protocol_leaf`.** CODE means one-argument protocol handler; object means native application. Remove every `is_raw`/`target` branch. Await every handler/app result through `Future->wrap`.

- [ ] **Step 5: Run the GREEN gate.** Repeat Step 3 and record skips separately from passing assertions.

- [ ] **Step 6: Commit and record evidence.** Commit `refactor: align protocol Route endpoint classification`. Review that HTTP method capabilities cannot affect protocol leaves and no settlement logic changed.

---

### Task 6: Make Pages Factories Return Deferred Applications

**Files:**

- Modify: `lib/PAGI/Pages.pm`
- Create: `lib/PAGI/Pages/Application.pm`
- Modify: `lib/PAGI/Routing/Compiler.pm`
- Modify: `t/pages/01-catalog.t`
- Modify: `t/pages/02-rendering-negotiation.t`
- Modify: `t/pages/03-invocation-composition.t`
- Modify: `t/pages/04-status-fields-cache.t`
- Modify: `t/pages/05-redirects.t`
- Create: `t/pages/06-lifespan-decline.t`
- Modify: `t/integration-pages-example.t`

**Interfaces:**

- `PAGI::Pages->welcome(%opts)`, configured instance methods, subclass methods, and opt-in exports return immutable deferred HTTP applications
- exports are `welcome`, `not_found`, named catalog functions, `status`, and `redirect`; no default exports
- `:common` excludes `status` and `redirect`; `:all` includes them
- source-first forms such as `welcome($request)` and all `_page` exports are errors/removed

- [ ] **Step 1: Rewrite export and construction tests.** Assert equivalent class, configured-instance, subclass, and imported factory behavior; distinct factory calls; immutable captured options; no default imports; exact `:common`/`:all` membership; and collision-prone `status`/`redirect` explicit-only behavior.

- [ ] **Step 2: Move negotiation assertions to invocation time.** Construct one Page app before a request exists, invoke it against HTML, problem JSON, and text Accept scopes, and prove each invocation creates its own Response representation without cross-request state.

- [ ] **Step 3: Pin rejection and root behavior.** Assert old source-first forms and `_page` imports fail, while lifespan/WebSocket/SSE/unknown scopes throw before emitting. Add a documented integration probe showing a bare Pages app declines automatic lifespan and explaining that strict lifespan mode rejects it; do not teach Pages to handle lifespan.

- [ ] **Step 4: Run the RED gate.**

  ```bash
  prove -lv t/pages/01-catalog.t t/pages/02-rendering-negotiation.t t/pages/03-invocation-composition.t t/pages/04-status-fields-cache.t t/pages/05-redirects.t t/pages/06-lifespan-decline.t t/integration-pages-example.t
  ```

- [ ] **Step 5: Implement the deferred component.** `PAGI::Pages::Application` captures one Pages policy object plus a descriptor factory. Its `to_app` validates HTTP scope, creates the request-time descriptor, calls the existing rendering/negotiation policy, and delegates the produced Response with `invoke_app`. It stores no request, scope, response, receive, or send.

- [ ] **Step 6: Change Pages factories and generated methods.** Remove `_take_request_source`, `_scope_from_source`, `_page` exports, and source-first dispatch. Preserve every existing status/header/representation validation and subclass rendering hook.

- [ ] **Step 7: Update Router defaults and generated 405s.** Compile `PAGI::Pages->not_found` directly as the HTTP default and invoke `PAGI::Pages->method_not_allowed(allow => ...)` as an application. Keep Router's authoritative Allow wrapper.

- [ ] **Step 8: Run the GREEN gate.** Repeat Step 4 plus:

  ```bash
  prove -lv t/routing/05-http-dispatch.t t/routing/16-http-outcomes.t
  perl -Ilib -c lib/PAGI/Pages.pm
  perl -Ilib -c lib/PAGI/Pages/Application.pm
  ```

- [ ] **Step 9: Commit and record evidence.** Commit `refactor: make Pages factories deferred applications`. Review that negotiation is request-time, lifespan remains a decline, no arity sniffing exists, and existing page validation did not weaken.

---

### Task 7: Align Mutable Router Frontends and Endpoint::HTTP

**Files:**

- Modify: `lib/PAGI/App/Router/Builder.pm`
- Modify: `lib/PAGI/App/Router.pm`
- Modify: `lib/PAGI/Endpoint/Router/Builder.pm`
- Modify: `lib/PAGI/Endpoint/Router.pm`
- Modify: `lib/PAGI/Endpoint/HTTP.pm`
- Modify: `t/app-router/01-builder-core.t`
- Modify: `t/app-router/04-snapshots-cycles.t`
- Modify: `t/app-router/06-public-api.t`
- Modify: `t/app/02-routing.t`
- Modify: `t/app/03-router.t`
- Modify: `t/app/07-routing-composition.t`
- Modify: `t/endpoint/01-http-constructor.t`
- Modify: `t/endpoint/02-http-dispatch.t`
- Modify: `t/endpoint/03-http-to-app.t`
- Modify: `t/endpoint/04-http-options.t`
- Modify: `t/endpoint/11-return-contract.t`
- Modify: `t/endpoint/13-router-frontends.t`
- Modify: `t/endpoint-router.t`

**Interfaces:**

- App::Router stores `endpoint` and materializes the immutable Route contract; its verb helpers preserve declaration order and method meaning
- Endpoint::Router method names bind to one-argument handlers; CODE handlers pass through; `app_as` returns a native coderef and therefore must be wrapped with `as_app` at Route positions
- Endpoint::HTTP verb methods return application values; `dispatch` does not perform nominal Response checks
- instance `to_app` dispatches on that exact instance; class `to_app` may construct one instance for standalone compatibility

- [ ] **Step 1: Rewrite App::Router tests to remove raw mode.** Test CODE handlers, object endpoints, `as_app($native)`, explicit `methods => '*'`, endpoint identity through snapshots, declaration order, independent materialization, and unchanged cycle diagnostics.

- [ ] **Step 2: Rewrite Endpoint::Router binding tests.** A local method name becomes a one-argument handler; an ordinary CODE is the same; a native method app is declared as `as_app($self->app_as('native'))`. Preserve `middleware_as`, `new_request`, `app_path`, mounts, naming, constraints, and router defaults.

- [ ] **Step 3: Rewrite Endpoint::HTTP return tests.** Accept immediate/Future Response, Pages, native CODE, and arbitrary `to_app` object results; reject undef/string/hash before invocation with application-value diagnostics. Prove a configured instance retains its own fields and request-to-request state, rather than `to_app` allocating a different object.

- [ ] **Step 4: Pin routed method ownership.** With an Endpoint object used directly in Route, prove the snapshotted `allowed_methods` includes implemented verbs, HEAD, and OPTIONS; unsupported methods become Router-owned 405/Allow. Prove Endpoint's own 405 remains when standalone/mounted or when Route explicitly declares broader methods.

- [ ] **Step 5: Run the RED gate.**

  ```bash
  prove -lv t/app-router/01-builder-core.t t/app-router/04-snapshots-cycles.t t/app-router/06-public-api.t t/app/02-routing.t t/app/03-router.t t/app/07-routing-composition.t t/endpoint/01-http-constructor.t t/endpoint/02-http-dispatch.t t/endpoint/03-http-to-app.t t/endpoint/04-http-options.t t/endpoint/11-return-contract.t t/endpoint/13-router-frontends.t t/endpoint-router.t
  ```

- [ ] **Step 6: Normalize Builder records.** Replace `target`/`is_raw` with `endpoint`; accept CODE or instantiated app objects; carry explicit or inferred methods through immutable Route construction without a second capability call. Preserve declaration-package and middleware ordering.

- [ ] **Step 7: Update Endpoint::HTTP.** `dispatch` returns the handler's application value after validation through the shared app contract. `to_app` captures the supplied instance when invoked on an object, constructs once when invoked on a class, creates Request, awaits dispatch, and delegates through `invoke_app`.

- [ ] **Step 8: Run the GREEN gate.** Repeat Step 5 plus syntax checks for all five modified modules.

- [ ] **Step 9: Commit and record evidence.** Commit `refactor: align Router frontends with application endpoints`. Review declaration order, endpoint instance identity, no duplicate allowed-method snapshot, and no raw-mode remnants in runtime modules.

---

### Task 8: Migrate First-Party Application and Middleware Callers

**Files:**

- Modify: every current runtime caller returned by `rg -l -- '->respond\(' lib --glob '*.pm'`, excluding Response internals reserved for Task 11
- Modify: every current runtime source-first Pages caller returned by `rg -l 'PAGI::Pages->|_page\(' lib --glob '*.pm'`
- Modify: focused tests corresponding to each touched app/middleware

**Interfaces:**

- raw/native code delegates application values only through `invoke_app`
- first-party apps and middleware use new Pages factories without request/source arguments
- middleware semantics, event interception, and status/header policy remain unchanged

- [ ] **Step 1: Freeze the exact ownership list.** Run:

  ```bash
  rg -n -- '->respond\(' lib --glob '*.pm'
  rg -n 'PAGI::Pages->|_page\(' lib --glob '*.pm'
  ```

  Put every result into the ledger inventory with an owning focused test. Do not edit Response, File, Stream, WebSocket denial, or SSE decline emission internals in this task.

- [ ] **Step 2: Migrate Pages call sites by meaning.** Examples: `PAGI::Pages->not_found(detail => ...)`, `PAGI::Pages->method_not_allowed(allow => ...)`, and `PAGI::Pages->redirect($target, ...)`. Never pass `$request` or `$scope` to a factory.

- [ ] **Step 3: Migrate application emission.** Replace calls such as:

  ```perl
  await $response->respond($scope, $receive, $send);
  ```

  with:

  ```perl
  await PAGI::Utils::invoke_app($response, $scope, $receive, $send);
  ```

  Preserve any existing send wrapper by passing it as the exact `$send` argument. Do not buffer bodies or special-case Response subclasses.

- [ ] **Step 4: Run ownership-cone tests in groups.** At minimum:

  ```bash
  prove -lv t/app t/compose t/middleware t/request/14-response.t
  rg --files t | rg '(app-file|app-directory|app-static|file|directory|static)'
  ```

  The second command discovers the exact existing ownership tests. Record and
  run every applicable file it returns, without suppressed errors, as part of
  the actual GREEN gate.

- [ ] **Step 5: Re-run runtime searches.** Only Task 11's Response/File/Stream and protocol-settlement internals may still contain `->respond`. No first-party runtime caller may use an old Pages source form.

- [ ] **Step 6: Commit and record evidence.** Commit `refactor: delegate first-party responses as applications`. Review every change as a semantic one-for-one delegation; stop if any caller seems to need replay, buffering, or Response-type branching.

---

### Task 9: Migrate the Starlette Apples Canary

**Files:**

- Modify: `examples/starlette-apples/app.pl`
- Modify: `examples/starlette-apples/README.md`
- Modify: `t/integration-starlette-apples.t`

**Canary shape:**

```perl
use PAGI::Pages qw(welcome not_found);
use PAGI::Response qw(file_response json_response);
use PAGI::Routing qw(route mount router);

compose(
    app => router(
        routes => [
            route('/' => file_response($manager_file, inline => 1),
                name => 'home', desc => 'Apple manager SPA'),
            route('/welcome' => welcome(),
                name => 'welcome', desc => 'PAGI welcome page'),
            mount('/apples', routes => [
                route('/' => \&list_apples, methods => ['GET'], name => 'list'),
                route('/' => \&create_apple, methods => ['POST'], name => 'create'),
                route('/{apple_id:&Int}' => \&read_apple,
                    methods => ['GET'], name => 'read'),
                route('/{apple_id:&Int}' => \&update_apple,
                    methods => ['PUT'], name => 'update'),
                route('/{apple_id:&Int}' => \&delete_apple,
                    methods => ['DELETE'], name => 'delete'),
            ], name => 'apples'),
        ],
        http_default => not_found(
            detail => 'That page does not exist in the Apple demo.'),
    ),
    lifespan => { startup => \&startup },
);
```

- [ ] **Step 1: Rewrite the executable and copied README source together.** Preserve Perl 5.40 signatures, Type::Tiny `&Int`, state fixture, reverse links, SPA, CRUD behavior, `/welcome`, nested `/apples` Router ownership, and the original Python source byte-for-byte.

- [ ] **Step 2: Strengthen the canary test.** Retain all current assertions and explicitly verify:

  - static Response object endpoint defaults to GET+HEAD;
  - `/welcome` is a direct Pages application endpoint;
  - CRUD handlers return JSON applications;
  - `/apples` and `/apples/` reach the child index;
  - failed `Int` is a routing 404 while negative Int reaches the handler;
  - child collection wrong method is 405 with `GET, HEAD, POST`;
  - unknown GET and DELETE use the root `http_default` 404;
  - PUT `/welcome` is 405 with `GET, HEAD`; and
  - README Perl source equals `app.pl` and Python digest is unchanged.

- [ ] **Step 3: Run the canary GREEN gate.**

  ```bash
  prove -lv t/integration-starlette-apples.t
  ```

- [ ] **Step 4: Run stale-form searches only in the canary.**

  ```bash
  rg -n "request_app|raw =>|_page\\b|->respond\\(|is_response" examples/starlette-apples t/integration-starlette-apples.t
  ```

  Expect no matches.

- [ ] **Step 5: Commit and record evidence.** Commit `docs: migrate the Starlette apples canary`. Review the result side-by-side with the README's Python app and record whether any remaining Perl ceremony is essential rather than legacy API residue.

---

### Task 10: Migrate and Verify Every Maintained Example

**Files:**

- Modify as required: every file under `examples/` returned by the baseline searches
- Modify: `examples/README.md`
- Modify: corresponding `t/integration-*.t`, `t/00-pod/cookbook-examples.t`, and example-specific tests

**Required example inventory:**

- `examples/10-chat-showcase`
- `examples/13-contact-form`
- `examples/14-lifespan-utils`
- `examples/15-large-application`
- `examples/background-tasks`
- `examples/compose`
- `examples/declarative-routing`
- `examples/endpoint-demo`
- `examples/endpoint-router-demo`
- `examples/full-demo`
- `examples/pages`
- `examples/test-lifespan-shutdown`
- `examples/websocket-chat-v2`
- every additional directory discovered by the fresh searches

- [ ] **Step 1: Generate an example migration matrix.** For every directory under `examples/`, record `affected/not affected`, current old forms, final form, and its load/integration test. Do not limit the matrix to the known list.

- [ ] **Step 2: Migrate by placement semantics.** Use these rules:

  - static Response/Pages application: place the object directly in Route;
  - request-derived response: return the application from the one-argument handler;
  - native CODE at Route: wrap with `as_app`;
  - native CODE at Mount/Compose/default: pass directly;
  - custom Request-based default: use `request_response`;
  - raw three-argument delegation: use `invoke_app`;
  - Endpoint::Router native local method: `as_app($self->app_as(...))`.

- [ ] **Step 3: Give high-value examples deliberate review.** In `15-large-application`, preserve nested reverse links, custom routing boundaries, lifespan fixtures, static mounting, and GAPS status. In Endpoint demos, preserve class-based cleanliness and local middleware helpers. In Pages, show class/configured/export factories, direct Route, Mount/root app, raw three-argument `invoke_app`, negotiation, and automatic-versus-strict lifespan caveat.

- [ ] **Step 4: Run every example integration test.** At minimum:

  ```bash
  prove -lv t/integration-chat-compose.t t/integration-compose-demo.t t/integration-declarative-routing-demo.t t/integration-endpoint-router-demo.t t/integration-large-application.t t/integration-lifespan-utils-example.t t/integration-pages-example.t t/integration-websocket-chat-v2.t
  prove -lv t/00-pod/cookbook-examples.t
  ```

  Add every discovered example-specific test to the recorded command. A maintained example without an executable test gets a load/compile assertion in this task.

- [ ] **Step 5: Enforce the all-examples stale-form gate.**

  ```bash
  rg -n "request_app|raw =>|_page\\b|->respond\\(|is_response" examples
  ```

  Expect no matches, excluding prose that is explicitly labelled as a before/after migration example in `UPGRADING.md`—which is outside `examples/`.

- [ ] **Step 6: Commit and record evidence.** Commit `docs: migrate all examples to application-valued endpoints`. Record the full example matrix and exact integration counts in the ledger. Review that no example uses `invoke_app` where a direct Route or returned Response is clearer.

---

### Task 11: Remove Public Response Emission Mechanically

**Files:**

- Modify: `lib/PAGI/Response.pm`
- Modify: `lib/PAGI/Response/File.pm`
- Modify: `lib/PAGI/Response/Stream.pm`
- Modify: `lib/PAGI/WebSocket.pm`
- Modify: `lib/PAGI/SSE.pm`
- Modify: `lib/PAGI/Utils.pm`
- Modify: response/protocol tests that call or override public `respond`
- Remove or replace: `t/utils/is-response.t`

**Interfaces:**

- public Response contract uses `to_app` only for native invocation
- a protected/private emission seam may exist solely for subclass implementation; it is not documented as public
- `PAGI::Utils::is_response` is removed
- denial and decline continue accepting only compatible Response applications through `protocol_response_capability`

- [ ] **Step 1: Freeze the final direct-call list.** Run `rg -n -- '->respond\(' lib t` and classify every remaining occurrence as base/File/Stream implementation, denial/decline adapter, subclass fixture, or stale caller. Any stale caller returns to Task 8 ownership before proceeding.

- [ ] **Step 2: Add failing public-surface tests.** Assert Response, File, Stream, and subclasses do not expose public `respond`; Utils cannot export `is_response`; every subclass still works through `to_app` and `invoke_app`.

- [ ] **Step 3: Perform only the mechanical seam change.** Rename the internal implementation seam consistently (for example `_emit`) and make each `to_app` snapshot call it. Update denial/decline mapping to invoke the exact mapped Response app while preserving the settlement wrapper and start-commit callback. Do not change lifecycle branches, writer state, range planning, capability values, error text unrelated to the method name, or event shapes.

- [ ] **Step 4: Run the immediate critical settlement gate.**

  ```bash
  prove -lv t/response/01-base.t t/response/02-buffered.t t/response/03-stream.t t/response/04-file.t t/response-writer.t t/websocket/denial-response.t t/sse/13-decline.t t/endpoint/14-sse-keepalive-ordering.t t/integration/sse-decline-end-to-end.t
  ```

  This gate must prove File's `protocol_response_capability` remains `undef`; send-Future resolution remains accepted/committed rather than client-delivered; mapped backpressure disconnect cleanup keys off connection/disconnect state rather than send failure; Stream cancellation and cleanup remain exactly once; and denial/decline emit at most one start.

- [ ] **Step 5: Run broader Response gates.**

  ```bash
  prove -lv t/response.t t/response-value.t t/response-subclass.t t/response-convenience.t t/upgrading-response-family.t t/websocket t/sse
  ```

- [ ] **Step 6: Enforce runtime removal searches.**

  ```bash
  rg -n -- '->respond\(' lib
  rg -n "is_response" lib
  ```

  Only an explicitly private internal method definition/call may remain under its new name; the commands above must produce no matches.

- [ ] **Step 7: Commit and record evidence.** Commit `refactor: remove public Response emission seam`. Record critical and broad suite counts separately. Independent review must compare the before/after File, Stream, WebSocket, and SSE diffs and reject any non-mechanical settlement change.

---

### Task 12: Reconcile Live Documentation and Upgrade Guidance

**Files:**

- Modify: `README.md`
- Modify: `UPGRADING.md`
- Modify: `Changes`
- Modify: `lib/PAGI/Utils.pm`
- Modify: `lib/PAGI/Routing.pm`
- Modify: `lib/PAGI/Routing/Route.pm`
- Modify: `lib/PAGI/Routing/Mount.pm`
- Modify: `lib/PAGI/Routing/Router.pm`
- Modify: `lib/PAGI/Routing/RequestResponse.pm`
- Modify: `lib/PAGI/App/Router.pm`
- Modify: `lib/PAGI/Endpoint/Router.pm`
- Modify: `lib/PAGI/Endpoint/HTTP.pm`
- Modify: `lib/PAGI/Pages.pm`
- Modify: `lib/PAGI/Pages/Application.pm`
- Modify: `lib/PAGI/Response.pm` and every Response subclass with affected invocation POD
- Modify: `lib/PAGI/WebSocket.pm`
- Modify: `lib/PAGI/SSE.pm`
- Modify: `lib/PAGI/Compose.pm`
- Modify: `lib/PAGI/Middleware/Builder.pm`
- Modify: `lib/PAGI/Tools/Tutorial.pod`
- Modify: `lib/PAGI/Tools/Cookbook.pod`
- Modify: documentation tests

- [ ] **Step 1: Write the upgrade guide first.** Include executable before/after sections for Route raw apps, object endpoints, method defaults/capabilities, request handler returns, raw application emission, Pages factories/exports, Router defaults, Endpoint::HTTP objects, and `respond`/`is_response` removal. State that `as_app($native)` without explicit methods defaults to GET+HEAD and needs scalar `methods => '*'` for unrestricted delegation.

- [ ] **Step 2: Document the callable mapping consistently.** Every current doc must say:

  ```text
  Route CODE endpoint       -> one Request/WebSocket/SSE argument
  Route to_app object       -> native PAGI application
  Mount/Compose/default CODE -> native PAGI application
  handler result            -> native CODE or instantiated to_app object
  ```

  Explain why Route and Mount are not interchangeable: Route matches one complete path and participates in methods/Allow; Mount consumes a prefix, rewrites child scope, and owns the subtree.

- [ ] **Step 3: Document sharp edges and lifecycle.** Cover dynamic arbitrary app returns, unchanged scope, consumed body, no lifespan replay, opaque reverse/schema metadata, per-invocation `to_app`, synchronous inline handlers, expensive Stream HEAD, Pages automatic/strict lifespan behavior, and File's protocol denial opt-out.

- [ ] **Step 4: Reconcile Pages and Response docs.** Remove all claims that Pages receives Request/source or that Response exposes `respond`. Show direct Route, `http_default`, raw `invoke_app`, and root CLI:

  ```bash
  pagi-server -MPAGI::Pages -e 'PAGI::Pages->welcome'
  ```

- [ ] **Step 5: Run documentation gates.**

  ```bash
  prove -lv t/00-pod/cookbook-examples.t t/upgrading-response-family.t t/upgrading-router-frontends.t t/upgrading-routing-composition.t
  podchecker lib/PAGI/Routing.pm lib/PAGI/Pages.pm lib/PAGI/Response.pm
  ```

- [ ] **Step 6: Run live-document stale searches.** Search `README.md`, `UPGRADING.md`, `Changes`, `lib/`, `t/`, and `examples/`. Historical `docs/superpowers/specs` and plans are exempt. Every old spelling in `UPGRADING.md` must be inside an explicitly labelled Before block; no live normative prose may endorse it.

- [ ] **Step 7: Commit and record evidence.** Commit `docs: explain application-valued Route endpoints`. Review terminology consistency for endpoint, handler, application, Response, Route, Mount, automatic HEAD, and method capability.

---

### Task 13: Final Audit, Full Verification, and Build

**Files:**

- Modify only if evidence requires: files already owned by Tasks 1–12
- Update: `.superpowers/sdd/2026-08-30-route-endpoints-and-application-valued-responses/progress.md`
- Update: `public-surface-inventory.md`

- [ ] **Step 1: Reconfirm the work map and repository status.** Verify current branch, starting base, task commits, preserved untracked files, and no changes in PAGI/PAGI-Server. Before any later push, reconfirm the declared ticket/branch/base/push mapping.

- [ ] **Step 2: Complete the public-surface inventory.** Every row must have a final classification and evidence. Check all exports and tags, Route accessors, Router frontends, Endpoint::HTTP, Pages, Response subclasses, and denial/decline capabilities.

- [ ] **Step 3: Run final forbidden-form searches.** Excluding historical superpowers records:

  ```bash
  rg -n "request_app|raw =>|is_raw|->target\b|_page\\b|->respond\\(|is_response" README.md UPGRADING.md Changes lib t examples
  ```

  Review allowed Before blocks manually; all other matches must be removed or justified in the ledger.

- [ ] **Step 4: Run focused canary and settlement gates once more at final HEAD.**

  ```bash
  prove -lv t/integration-starlette-apples.t t/integration-large-application.t t/integration-endpoint-router-demo.t t/pages/03-invocation-composition.t t/routing/05-http-dispatch.t t/endpoint/11-return-contract.t
  prove -lv t/response/03-stream.t t/response/04-file.t t/response-writer.t t/websocket/denial-response.t t/sse/13-decline.t t/integration/sse-decline-end-to-end.t
  ```

- [ ] **Step 5: Run the repository-wide suite exactly once at the candidate HEAD.**

  ```bash
  prove -lr t
  ```

  Record total files, tests/assertions, wall time, skips, and exit status. If a fix changes HEAD, record the failed candidate and run one new final suite on the corrected candidate.

- [ ] **Step 6: Run syntax, diff, and distribution checks.**

  ```bash
  git diff --check
  perl -Ilib -c lib/PAGI/Utils.pm
  perl -Ilib -c lib/PAGI/Routing/Compiler.pm
  perl -Ilib -c lib/PAGI/Pages.pm
  perl -Ilib -c lib/PAGI/Response/Stream.pm
  dzil build
  ```

  Do not run `dzil test`.

- [ ] **Step 7: Perform final independent reviews.** Require one specification-compliance review and one code-quality review. The reviews must specifically inspect method capability ownership, dynamic application compilation, Route/Mount boundaries, every example directory, and the mechanical settlement diff.

- [ ] **Step 8: Commit final evidence.** Commit any final owned corrections separately, update the ledger with the final candidate SHA and verification evidence, and commit `docs: record Route endpoint campaign verification` if tracked evidence changed. Do not merge, push, tag, or release without the user's next instruction.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-08-30-route-endpoints-and-application-valued-responses.md`.

Recommended execution mode:

1. **Subagent-driven development** — execute one task at a time with fresh implementer and reviewer context, using the ledger and stop conditions above.
2. **Inline execution** — use `superpowers:executing-plans` in this session, honoring the same task boundaries and review gates.
