# HTTP Response Family and Streaming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the mutable all-purpose Response and dual-role Pages APIs with concrete reusable response values, explicit buffered/file/stream delivery classes, concise factory exports, and response-valued WebSocket/SSE rejection.

**Architecture:** `PAGI::Response` becomes the byte-oriented base and application boundary; finite subclasses render once, while File and Stream own request-time delivery. Stream relies on PAGI 0.5's deterministic pending-I/O settlement: Writer awaits each send and checks connection state, while the Stream runner alone owns proactive producer cancellation and exactly-once cleanup. Routing adapts Request handlers and instantiated `to_app` components without arity inference, Pages selects a concrete representation, and WebSocket/SSE adapt eligible HTTP response events into their denial event families.

**Tech Stack:** Perl 5.18-compatible distribution code; Perl 5.40 signatures only in modern examples; `Future`, `Future::AsyncAwait`, `JSON::MaybeXS`, `PAGI::Headers`, `PAGI::Request::BodyStream`, `PAGI::Transport`, `Test2::V0`, POD, and Dist::Zilla. Disconnect tests use contract-faithful direct doubles rather than the currently stale `PAGI::Test::Client` HTTP mock. PAGI 0.002006 defines the required core 0.5 / Www 0.4 settlement contract; PAGI::Server 0.002010 is the integration reference. No new runtime CPAN dependency.

**Spec:** `docs/superpowers/specs/2026-08-27-http-response-family-and-streaming-design.md`, originally approved at commit `498d5d0c0ecaffdd4e9a149bbf95d01e10913eea` and amended on 2026-08-28 by approved deviations `DEV-001` and `DEV-002` for PAGI 0.5 settlement.

## Global Constraints

- The approved contract is the specification above as amended by `DEV-001` and `DEV-002`. If implementation evidence conflicts with it, stop, record a deviation, and obtain the user's decision before dependent work continues.
- Work only in `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` or an isolated worktree created for this repository through `superpowers:using-git-worktrees`.
- Execution starts from the reviewed `main` commit containing this plan. Record its exact 40-character SHA; do not assume the specification commit remains HEAD.
- Preserve the unrelated untracked alignment notes and existing `.superpowers/` material. Never stage them with `git add .` or `git add -A`.
- Keep distribution modules and ordinary tests compatible with the declared Perl 5.18 floor unless implementation evidence justifies a separately approved change. Use project Perl 5.42.2 for implementation and functional verification; do not introduce compatibility-only rewrites for Perl 5.16.
- This is an intentional breaking redesign of unreleased PAGI-Tools APIs. Do not add aliases for removed Response finishers, `respond($send)`, Response scope access, Pages arity dispatch, `PAGI::App::File->app_path`, or denial/decline `%opts`.
- Do not recreate `PAGI::Context`. Request handlers receive `PAGI::Request`; WebSocket/SSE handlers receive their direct protocol objects; middleware and raw apps retain `($scope, $receive, $send)`.
- Response objects never store scope, receive, send, connection, Writer, or per-request mutation. Unchanged preconstructed Responses must support concurrent emission.
- Every potentially immediate handler/producer/source result is normalized with `Future->wrap`; never directly `await` a value that may not already be a Future.
- Every `$send` Future is awaited. Do not add an unbounded queue or permit overlapping Writer writes.
- Under PAGI 0.5, a send pending at disconnect resolves successfully after the server finishes with its event. Writer checks `pagi.connection` after awaiting, never manufactures a disconnect failure, and never cancels a send Future. Genuine validation/resource send failures still propagate unchanged.
- File bodies remain server-delivered PAGI `file` events. Do not replace them with blocking application-owned filehandle streaming.
- Stream never starts a competing `$receive` loop. Disconnect observation uses `pagi.connection`; ordinary HTTP Stream has no reconnection behavior.
- Build Stream's private disconnect signal from mandatory `pagi.connection->on_disconnect`; do not require optional `disconnect_future`. Retain proactive cancellation only for Stream-owned producer work and run local cleanup exactly once.
- Until `PAGI::Test::Client` is separately corrected for PAGI 0.5 settlement, do not use its HTTP mock for Writer/Stream disconnect assertions. Use direct doubles that honor await-then-check settlement or a PAGI::Server 0.002010+ integration environment.
- Route remains an exact method-aware leaf; Mount remains prefix/subtree composition. Instantiated `to_app` objects are accepted as Route targets, while coderef apps still require `raw`.
- Pages owns negotiated policy and presentation hooks only. It returns concrete Responses and is neither middleware nor a native arity-overloaded application.
- WebSocket/SSE own protocol state and event-prefix adaptation. A File response is rejected before denial/decline response start.
- Use `apply_patch` for edits and exact deletions. Stage only the current task's named files.
- Use strict TDD per task: write or migrate focused assertions, run and preserve the semantic RED, implement the minimum contract, then run the named GREEN gate.
- Every implementation task ends with one focused commit and independent specification/code-quality review before a dependent task begins.
- Run the repository-wide `prove -lr t` suite only in Task 12. Do not run `dzil test`; run exactly one `dzil build` after the final suite.
- Functional test commands use project Perl:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/response/01-base.t'
  ```

## Work Map

Record and reconfirm this map before implementation, whenever architecture or scope changes, and before any authorized push:

| Repository | Ticket | Execution branch | Base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | HTTP response family and streaming | isolated feature branch/worktree created by the selected execution skill | reviewed `main` containing spec `498d5d0` and this plan; record exact execution SHA | Response family, Request bridge removal, Routing/Pages/File/WS/SSE/Endpoint/middleware consumers, tests, examples, live POD/docs, upgrade/audit evidence named below | Unreleased PAGI-Tools `0.002003`; no deployment, CPAN release, tag, or merge in this plan | None unless the user separately authorizes publication |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI` | Pending-I/O settlement contract | released `main`, PAGI `0.002006` | core spec 0.5 / Www 0.4 | Read-only authority; no changes owned by this campaign | Published on CPAN before Task 4 resumes | None |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server` | Pending-I/O settlement conformance | released `main`, PAGI::Server `0.002010` | conforms to PAGI core 0.5 / Www 0.4 | Read-only integration reference; no changes owned by this campaign | Published on CPAN before Task 4 resumes | None |

## Execution Tracking and Deviation Control

Before Task 1, create the isolated workspace with the selected execution skill. For subagent-driven execution, run:

```bash
/Users/jnapiorkowski/.codex/plugins/cache/openai-curated-remote/superpowers/6.3.0/skills/subagent-driven-development/scripts/sdd-workspace docs/superpowers/plans/2026-08-28-http-response-family-and-streaming.md
```

Create `.superpowers/sdd/2026-08-28-http-response-family-and-streaming/progress.md` with this structure:

```markdown
# SDD ledger — HTTP response family and streaming

Starting HEAD: record the exact 40-character execution SHA

| Task | Status | Implementation SHA | Review/fix SHAs | Focused verification | Full-suite/build evidence | Verdict |
|---|---|---|---|---|---|---|
| 1 | pending | — | — | — | deferred to Task 12 | — |
| 2 | pending | — | — | — | deferred to Task 12 | — |
| 3 | pending | — | — | — | deferred to Task 12 | — |
| 4 | pending | — | — | — | deferred to Task 12 | — |
| 5 | pending | — | — | — | deferred to Task 12 | — |
| 6 | pending | — | — | — | deferred to Task 12 | — |
| 7 | pending | — | — | — | deferred to Task 12 | — |
| 8 | pending | — | — | — | deferred to Task 12 | — |
| 9 | pending | — | — | — | deferred to Task 12 | — |
| 10 | pending | — | — | — | deferred to Task 12 | — |
| 11 | pending | — | — | — | deferred to Task 12 | — |
| 12 | pending | — | — | — | final gate | — |

## Deviations

| ID | Status | Conflicting plan/spec text | Evidence and rationale | Affected tasks | User decision |
|---|---|---|---|---|---|
```

Write the starting SHA plus one newline to `starting-head`. Create `public-surface-inventory.md` beside the ledger. Inventory every public Response, Pages, File, WebSocket, SSE, Endpoint, Routing, ErrorHandler, and response-building middleware method/export before production edits, with columns `owner`, `current API`, `classification`, `replacement/retention task`, and `final evidence`. The only permitted classifications are `retained`, `replaced by approved design`, and `deferred by approved design`; zero rows may remain unclassified at Task 12.

A scope conflict receives the next stable `DEV-NNN` identifier, an `awaiting decision` status, exact evidence, affected tasks, and the user's explicit ruling before dependent work proceeds. Ordinary corrections that preserve the approved contract are not deviations. Update the ledger row in the same task turn as each commit/review with actual Files/Tests counts, elapsed time, syntax/POD evidence, commit SHA, and reviewer verdict.

## File and Responsibility Map

- `lib/PAGI/Response.pm`: byte-oriented base Response, common metadata, headers/cookies, full-triplet emission, `to_app`, and the nine factory exports.
- `lib/PAGI/Response/{Text,HTML,JSON,Problem,Redirect,Empty}.pm`: finite representation/semantic subclasses and their one optional factory export.
- `lib/PAGI/Response/Stream.pm` and `Writer.pm`: per-invocation producer, sequential body delivery, backpressure, PAGI 0.5 connection-state observation, proactive producer cancellation, and cleanup.
- `lib/PAGI/Response/File.pm` and `File/Plan.pm`: trusted selected-file response, logical windows, conditional/range planning, and PAGI file-event delivery.
- `lib/PAGI/Request.pm`: HTTP input only; remove the temporary `response` bridge.
- `lib/PAGI/Routing.pm`, `Route.pm`, and `Compiler.pm`: `request_app`, instantiated component Route targets, normal method selection, and full-triplet Response emission.
- `lib/PAGI/Pages.pm`: status/negotiation/presentation policy returning concrete Responses and exporting ordinary Request handlers.
- `lib/PAGI/WebSocket.pm` and `lib/PAGI/SSE.pm`: response-valued denial/decline and exact event-prefix adaptation without changing live send behavior.
- `lib/PAGI/App/File.pm`: untrusted URL-path resolution and policy, delegating selected-file response planning/delivery; `from_app_path` replaces the class `app_path` spelling.
- Endpoint, Compose, ErrorHandler, first-party apps/middleware, and test utilities: consume/emit the new Response contract without compatibility shims.
- Examples and live documentation: demonstrate exact Route versus Mount, explicit factories, Request handler ownership, streaming backpressure, and upgrade paths.

## Specification Coverage Map

| Specification area | Owning tasks |
| --- | --- |
| §§1–7 decisions, goals, non-goals, governing designs | Global constraints, Tasks 1 and 12 inventory/audit |
| §8 base hierarchy and subclass responsibilities | Tasks 1, 2, 4, and 5 |
| §9 constructors, options, logical file windows, and exports | Tasks 1, 2, 4, and 5 |
| §10 full-triplet emission, `to_app`, Route/Mount ownership | Tasks 1 and 3 |
| §11 explicit buffering | Tasks 1, 2, 4, and 5 |
| §§12–13 request/response streaming, Writer, disconnects | Task 4 |
| §14 File versus App::File lifecycle | Task 5 |
| §15 Pages policy/functions/subclassing | Task 6 |
| §16 WebSocket denial and SSE decline | Task 7 |
| §§17–19 before/after forms and Apple application | Tasks 10 and 11 |
| §§20–21 validation, failures, middleware, CORS, and HEAD | Tasks 1–9 with final audit in Task 12 |
| §23 consumer/migration inventory | Tasks 1, 8, 9, 10, and 11 |
| §24 required tests | Corresponding Tasks 1–11; exhaustive evidence in Task 12 |
| §25 documentation and upgrade requirements | Task 11 |
| §26 success criteria and distribution readiness | Task 12 |

---

### Task 1: Establish the Base Response Value and Public Inventory

**Files:**

- Modify: `lib/PAGI/Response.pm`
- Modify: `lib/PAGI/Request.pm`
- Create: `t/response/01-base.t`
- Modify: `t/request/14-response.t`
- Modify: `t/response.t`
- Modify: `t/response-value.t`
- Modify: `t/response-subclass.t`
- Modify: `t/utils/is-response.t`

**Interfaces:**

- Produces `PAGI::Response->new($bytes, %options)` for an unflagged byte scalar.
- Produces retained metadata methods exactly as listed in spec §8.1, `respond($scope,$receive,$send) -> Future`, and `to_app() -> CODEREF` snapshot.
- Produces subclass hooks `default_content_type()` and `render($value) -> bytes`.
- Removes `PAGI::Request->response`, Response scope/connection/body-mode access, finishers, CORS, Writer takeover, and `respond($send)`.

- [ ] **Step 1: Create the workspace evidence and complete the pre-edit inventory.** Record branch/base/status in the work map and ledger. Generate the candidate surface with:

  ```bash
  rg -n '^sub |^async sub |^    sub |EXPORT|EXPORT_OK|EXPORT_TAGS' \
    lib/PAGI/Response.pm lib/PAGI/Pages.pm lib/PAGI/App/File.pm \
    lib/PAGI/WebSocket.pm lib/PAGI/SSE.pm lib/PAGI/Endpoint lib/PAGI/Routing.pm \
    lib/PAGI/Routing lib/PAGI/Middleware/ErrorHandler.pm lib/PAGI/Middleware
  ```

  Classify every candidate in `public-surface-inventory.md`. In particular, record all Response methods named in spec §§8.1, 17, 21, and 25; no Response method may disappear merely because it was missed by a new test sketch.

- [ ] **Step 2: Rewrite the base tests before production code.** Pin:

  ```perl
  my $bytes = "abc\x00";
  my $res = PAGI::Response->new(
      $bytes,
      status       => 201,
      content_type => 'application/octet-stream',
      headers      => ['X-One' => 'a', 'X-One' => 'b'],
  );

  is($res->body, $bytes, 'base response retains exact bytes');
  is($res->header_all('x-one'), ['a', 'b'], 'duplicate order retained');
  ok($res->is_buffered, 'base bytes are buffered');
  ok(!$res->can('scope'), 'Response is not a scope source');
  ok(!$res->can('cors'), 'CORS policy is not a Response method');
  like(dies { PAGI::Response->new("wide \x{263a}") }, qr/encoded bytes/i);
  like(dies { PAGI::Response->new('x', status => 204) }, qr/body.*204/i);
  ```

  Add exact tests for status/header/content-type `*_try`, `has_*`, ordered append versus replacement, cookies, forbidden body statuses, malformed/duplicate/unknown options, even-length flat header pairs with nested-pair rejection, UTF-8-flagged ASCII rejection, TE/Content-Length safety, `body`, and subclass render/default-content-type hooks. Pin that implicit status 200 does not count as explicit for `status_try`, and that `header_try` never appends to an existing multi-value field.

- [ ] **Step 3: Pin full-triplet and snapshot behavior.** Use immediate and pending send Futures to prove each send is awaited. Emit the same unchanged Response concurrently to two independent scope/send triplets. Assert `to_app` captures a snapshot that is unaffected by later original header/status mutation. Assert missing/unknown/non-HTTP scope types, blessed scopes, and non-coderef receive/send values fail before events.

- [ ] **Step 4: Run RED.** Run:

  ```bash
  prove -lv t/response/01-base.t t/response.t t/response-value.t \
    t/response-subclass.t t/request/14-response.t t/utils/is-response.t
  ```

  Expected: failures identify the scope constructor, mutable body finishers, one-argument `respond`, missing byte validation/snapshot semantics, and still-present Request response bridge.

- [ ] **Step 5: Implement the minimal base value.** Keep one normalized `PAGI::Headers` instance plus explicit-status metadata and immutable body bytes. `respond` snapshots status/headers/body into invocation locals, sends `http.response.start`, awaits it, then sends/awaits one terminal `http.response.body`. `to_app` clones stable response configuration at compile time and returns an async HTTP-only application. Keep cookie behavior by delegating to the existing Cookie::Baker-safe code, but remove every competing `_file`/`_stream` mode and class/instance finisher.

- [ ] **Step 6: Remove the temporary Request factory and migrate these tests.** Delete `Request->response`; make request tests construct Response explicitly and pass Request to State/Session/Stash/CSRF/URL/Transport helpers. Do not add another outgoing Response shortcut.

- [ ] **Step 7: Run GREEN and compatibility gates.** Run Step 4, then:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -c lib/PAGI/Response.pm'
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -c lib/PAGI/Request.pm'
  podchecker lib/PAGI/Response.pm
  podchecker lib/PAGI/Request.pm
  git diff --check
  ```

  Expected: focused tests pass, syntax/POD pass, and the inventory records each removed base capability with its approved replacement.

- [ ] **Step 8: Commit, report, review, and update the ledger.** Stage exactly the eight listed files and commit `refactor: make Response a complete byte value`. Obtain independent spec-compliance and code-quality approval before Task 2.

---

### Task 2: Add Buffered and Semantic Response Classes and Factories

**Files:**

- Modify: `lib/PAGI/Response.pm`
- Create: `lib/PAGI/Response/Text.pm`
- Create: `lib/PAGI/Response/HTML.pm`
- Create: `lib/PAGI/Response/JSON.pm`
- Create: `lib/PAGI/Response/Problem.pm`
- Create: `lib/PAGI/Response/Redirect.pm`
- Create: `lib/PAGI/Response/Empty.pm`
- Create: `t/response/02-buffered.t`
- Modify: `t/response-convenience.t`
- Modify: `t/00-load.t`

**Interfaces:**

- Produces the six constructors and exact defaults in spec §§8.2–9.1.
- Produces opt-in factories `response`, `text_response`, `html_response`, `json_response`, `problem_response`, `redirect_response`, `empty_response`; base facade later also exposes File/Stream names.
- Produces `:all` on `PAGI::Response`, no defaults, and one optional factory from each subclass.

- [ ] **Step 1: Write class/factory identity and export tests.** Assert no default exports, unknown imports fail, and:

  ```perl
  isa_ok(text_response('hello'), ['PAGI::Response::Text']);
  isa_ok(PAGI::Response::HTML->new('<b>x</b>'), ['PAGI::Response::HTML']);
  isa_ok(json_response({ ok => \1 }), ['PAGI::Response::JSON']);
  isa_ok(problem_response({ title => 'Nope' }), ['PAGI::Response::Problem']);
  isa_ok(redirect_response('/next'), ['PAGI::Response::Redirect']);
  isa_ok(empty_response(status => 204), ['PAGI::Response::Empty']);
  ```

  Pin strict UTF-8 bytes/byte lengths, Text/HTML rejection of `charset`, JSON round trips and unsorted-key contract, encoding failures, and the explicit non-UTF-8 base Response escape hatch.

- [ ] **Step 2: Add RFC 9457 and semantic validation tests.** Cover every optional standard member, absent-on-wire effective `about:blank`, URI references, extensions, document/HTTP status agreement, invalid status/field types, Redirect statuses and safe Location/body construction, Empty's default 204, and body-forbidden statuses.

- [ ] **Step 3: Run RED.** Run:

  ```bash
  prove -lv t/response/02-buffered.t t/response-convenience.t t/00-load.t
  ```

  Expected: missing modules/factories and old generic finisher behavior fail.

- [ ] **Step 4: Implement finite subclasses through the base hooks.** Text/HTML override only default content type and strict UTF-8 render. JSON uses one non-canonical JSON::MaybeXS encoder. Problem validates before delegating to JSON. Redirect validates URI/status, installs Location, and renders a small escaped finite document. Empty owns zero bytes and no default Content-Type. Imported functions construct fixed first-party classes and never inspect caller package.

- [ ] **Step 5: Complete export tags and load coverage.** Add all nine factory names to `@EXPORT_OK`, with `:all` containing exactly nine; File/Stream factory functions may load their modules lazily until Tasks 4/5 but must preserve fixed mappings. Register the six new modules in `t/00-load.t`.

- [ ] **Step 6: Run GREEN and per-module gates.** Run Step 3, then compile and podcheck all seven changed/created modules under the declared gates and run `git diff --check`.

- [ ] **Step 7: Commit, report, review, and update the ledger.** Stage exactly the ten files and commit `feat: add concrete buffered responses`. Obtain independent review before Task 3.

---

### Task 3: Adapt Routing to Response Components and Export `request_app`

**Files:**

- Modify: `lib/PAGI/Routing.pm`
- Modify: `lib/PAGI/Routing/Route.pm`
- Modify: `lib/PAGI/Routing/Compiler.pm`
- Modify: `lib/PAGI/Routing/Router.pm`
- Modify: `t/routing/01-constructors.t`
- Modify: `t/routing/05-http-dispatch.t`
- Modify: `t/routing/06-head.t`
- Modify: `t/routing/10-head-boundary.t`
- Modify: `t/routing/16-http-outcomes.t`
- Modify: `t/integration-router-application-boundaries.t`

**Interfaces:**

- Produces `request_app($handler_coderef) -> native PAGI CODEREF` as an opt-in `PAGI::Routing` export.
- Route target accepts a Request-handler coderef or instantiated `to_app` object; `raw` remains the only coderef-app marker.
- All Router-selected Responses emit through `respond($scope,$receive,$send)` and `Future->wrap`.

- [ ] **Step 1: Write constructor and dispatch RED tests.** Pin that package strings, classes, unblessed refs, broken `to_app`, and `to_app` returning non-coderef fail at construction/compilation. Pin one Response object Route:

  ```perl
  my $response = PAGI::Response::Text->new('root');
  my $app = router(routes => [route('/' => $response)])->to_app;
  ```

  Assert only `/` matches, omitted methods accepts GET+HEAD, POST is PARTIAL with `Allow: GET, HEAD`, explicit methods/constraints/middleware/name/desc remain identical, and concurrent requests receive independent emissions.

- [ ] **Step 2: Test the named handler adapter.** Cover immediate and Future-backed Response returns, invalid return diagnostics, non-coderef construction rejection, non-HTTP rejection, and successful use at Router `http_default`, Mount `app`, and Compose `app` positions. Assert ordinary coderef Route targets remain Request handlers and native coderef targets remain invalid unless marked `raw`.

- [ ] **Step 3: Run RED.** Run:

  ```bash
  prove -lv t/routing/01-constructors.t t/routing/05-http-dispatch.t \
    t/routing/06-head.t t/routing/10-head-boundary.t \
    t/routing/16-http-outcomes.t t/integration-router-application-boundaries.t
  ```

  Expected: object Route rejection, missing `request_app`, old one-argument response emission, and generic stock-response construction failures.

- [ ] **Step 4: Implement one shared Request-handler adapter.** Put the adapter used by both ordinary handler leaves and exported `request_app` in Routing/Compiler or one private helper. It constructs `PAGI::Request->new($scope,$receive)`, awaits `Future->wrap($handler->($request))`, validates `PAGI::Response`, and awaits full-triplet `respond` exactly once. Do not infer arity.

- [ ] **Step 5: Compile component-valued Route targets.** Route validates instantiated `to_app`, Compiler calls it once per fresh Router compilation, and the selected app remains behind the same route middleware/method/constraint/HEAD boundary as a handler leaf. Stock 404/405 Responses use concrete response classes and full-triplet emission; authoritative `Allow` behavior remains unchanged.

- [ ] **Step 6: Run GREEN plus adjacent Router gates.** Run Step 3 and:

  ```bash
  prove -lv t/routing/07-mounts.t t/routing/12-router-mounts.t \
    t/routing/09-metadata-isolation.t t/app-router-mount-routes.t
  ```

  Compile/podcheck the four modules under project Perl 5.42.2 and run `git diff --check`.

- [ ] **Step 7: Commit, report, review, and update the ledger.** Stage exactly the ten files and commit `feat: route instantiated response components`. Obtain independent review before Tasks 4–6.

---

### Task 4: Implement Stream and Per-Invocation Writer Backpressure

**Files:**

- Create: `lib/PAGI/Response/Stream.pm`
- Create: `lib/PAGI/Response/Writer.pm`
- Modify: `lib/PAGI/Response.pm`
- Modify: `lib/PAGI/Request/BodyStream.pm`
- Create: `t/response/03-stream.t`
- Modify: `t/response-writer.t`
- Modify: `t/request/08-body.t`
- Modify: `t/routing/06-head.t`
- Modify: `t/00-load.t`
- Modify: `cpanfile`

**Interfaces:**

- Produces `PAGI::Response::Stream->new($producer,%common_options)` and `stream_response`.
- Produces the exact Writer API from spec §13.2; Writer is created only by Stream and has no public constructor/application contract.
- `write`/`write_text` permit one outstanding Future, `pipe_from` pulls only after prior settlement, and all cleanup is exactly once.
- Consumes PAGI core 0.5 / Www 0.4 settlement: a pending send resolves at disconnect, the resumed coroutine observes transitioned connection state, and disconnect delivery cannot re-enter `$send`/`$receive`.
- Uses mandatory `on_disconnect` to construct one private signal; optional `disconnect_future` is not a portability requirement.

**Resume note:** Commits `f92e568`, `3aa0bfe`, and `c40e08c` implemented and reviewed the original Task 4 contract. The uncommitted fix-round-3 `_Operation`/failure-observation diff was discarded after PAGI 0.5 defined the race away. The steps below now describe the corrective RED/GREEN cycle from `c40e08c`; do not recreate or preserve disconnect-derived Writer failures.

- [ ] **Step 1: Write lifecycle and backpressure tests first.** Use controlled send Futures to prove headers precede producer invocation, a write remains pending until its send Future settles, and a second overlapping write fails without enqueueing. Assert terminal empty body on normal completion, idempotent local `close`, write-after-close failure, accurate connected `bytes_written`, a fresh Writer/producer per invocation, and no Writer `to_app`/Response inheritance.

- [ ] **Step 2: Pin byte/text and transport behavior.** Test flagged-character rejection in `write`, strict UTF-8 in `write_text`, direct delegation of `buffered_amount`, watermarks, `is_writable`, high-water, and drain callbacks. Without `pagi.transport`, assert `0`, `undef`, `undef`, true, and quiet chainable registrations. Separately retain `transport($request) -> undef` for absent optional capability.

- [ ] **Step 3: Pin source relay ordering.** Create sources whose `next_chunk` returns immediate chunks, Futures, empty chunks, EOF, and failures. Assert `pipe_from` never requests the next chunk before prior send settlement, propagates source/send failure, and preserves BodyStream buffered/streaming mutual exclusion and truncation reporting.

- [ ] **Step 4: Pin PAGI 0.5 disconnect settlement and cleanup.** Use direct connection/send doubles, not `PAGI::Test::Client`'s HTTP mock. Cover disconnect before producer start, during unrelated producer work, while `$send` is pending, immediately after send settlement, and after normal completion. The pending-send double must update `is_connected`/`disconnect_reason`, defer `on_disconnect` delivery outside the `$send` call stack, then resolve the send successfully. Assert the public write resolves normally, observes the reason through Writer state, does not count discarded bytes, and never cancels the send Future. Assert the runner proactively cancels only its own pending producer work, awaits an in-flight send before finishing abort, runs immediate/Future-backed `on_close` callbacks once, emits no terminal success, and does not consume `$receive`. Callback failures are reported, never replace the primary delivery error, and do not prevent later callbacks. A separately controlled validation/resource send failure still fails the write and remains the producer/application failure after cleanup.

- [ ] **Step 5: Run RED.** Run:

  ```bash
  prove -lv t/response/03-stream.t t/response-writer.t \
    t/request/08-body.t t/routing/06-head.t t/00-load.t
  ```

  Expected at corrective HEAD `c40e08c`: PAGI 0.5 assertions fail because Writer still manufactures disconnect failures/cancels active operations and Stream still contains obsolete failure-versus-disconnect arbitration. Existing backpressure, source-ordering, and HEAD assertions remain green.

- [ ] **Step 6: Rebase Writer on PAGI 0.5 settlement.** Store only invocation-local send, connection/transport handles, monotonic local state, counters, one outstanding-operation marker, callbacks, and disconnect reason. Every `write` awaits the exact `$send` Future without exposing cancellation to it, clears the outstanding marker on settlement, then refreshes connection state. If disconnected, return normally and do not increment `bytes_written`; never manufacture a disconnect exception. Propagate genuine failed/cancelled send outcomes according to their own settlement. `pipe_from` is a sequential Future chain that checks `is_disconnected` after each write and before requesting another chunk. `_abort` joins any active send and never cancels it. Delete `_Operation`, deferred-disconnect publication, and failure-observation logic rather than adapting them.

- [ ] **Step 7: Simplify Stream's runner around one disconnect owner.** Snapshot configuration in `to_app`, emit/await start, create one Writer, and build one private Future from mandatory `on_disconnect`. Race that signal against the producer solely to cancel unrelated Stream-owned producer work proactively. The callback records facts and resolves the signal; it performs no asynchronous cleanup. Stream centralizes once-only abort/close cleanup, never cancels a PAGI send Future, emits no terminal event after disconnect, and propagates genuine producer/send failures without any same-turn precedence inspection. Reject non-HTTP scopes through the shared Response contract. Add `PAGI::Server 0.002010` under `develop` prerequisites as the integration reference, not a runtime dependency.

- [ ] **Step 8: Run GREEN and compatibility gates.** Run Step 5, then Router HEAD tests proving Stream HEAD runs/awaits its producer while suppressing body events and an earlier explicit HEAD route avoids producer invocation. Verify the installed integration reference is PAGI::Server 0.002010 or newer when running any server-backed probe. Compile/podcheck all four modules under project Perl 5.42.2, syntax-check `cpanfile`, and run `git diff --check`.

- [ ] **Step 9: Commit, report, review, and update the ledger.** Stage only the Task 4 files changed by the PAGI 0.5 correction and commit `fix: align streaming with PAGI 0.5 settlement`. Record `f92e568`, `3aa0bfe`, and `c40e08c` as the earlier implementation/review chain, the discarded uncommitted fix round as obsolete WIP, and the corrective commit as the new review target. Obtain independent review before protocol integration and final consumers.

---

### Task 5: Implement File Response and Reuse Its Range Planner from App::File

**Files:**

- Create: `lib/PAGI/Response/File.pm`
- Create: `lib/PAGI/Response/File/Plan.pm`
- Modify: `lib/PAGI/Response.pm`
- Modify: `lib/PAGI/App/File.pm`
- Modify: `lib/PAGI/App/Directory.pm`
- Create: `t/response/04-file.t`
- Modify: `t/app-file.t`
- Modify: `t/app-file-resolution.t`
- Modify: `t/34-directory-security.t`
- Modify: `t/00-load.t`

**Interfaces:**

- Produces `PAGI::Response::File->new($trusted_path,%options)` and `file_response`.
- Produces private immutable `PAGI::Response::File::Plan->new(path => $path, scope => $scope, offset => $offset, length => $length, handle_ranges => $bool, etag => $policy)` with read-only `status`, `headers`, and `body_event` accessors for file metadata, logical window, condition/range result, headers, and physical event offset/length.
- Renames `PAGI::App::File->app_path(@parts)` to `from_app_path(@parts)` with no alias; `PAGI::Utils::app_path` remains a path-string function.

- [ ] **Step 1: Write constructor and deferred-preflight tests.** Assert construction validates option shapes but performs no existence/readability/stat/content work. A path absent at construction but present before invocation succeeds; a missing/unreadable path at invocation fails before response start. Assert File is unbuffered and `body` croaks.

- [ ] **Step 2: Pin logical-window behavior.** For a known fixture, assert full response and `offset => 1024, length => 65536` both produce 200 without Content-Range, authoritative Content-Length, and correct physical file-event fields. Reject negative/out-of-bounds windows, caller Content-Length/Content-Range/ETag headers, and unplanned 206. Explicit `etag` accepts false/automatic/validated entity tags.

- [ ] **Step 3: Pin conditional and client ranges.** Cover no Range, valid closed/open/suffix single ranges, malformed/multiple ignored-or-rejected behavior matching current strict policy, `handle_ranges => 0`, 304, 206, and 416 against full and configured logical windows. Verify MIME, filename/inline Content-Disposition, logical Content-Range with physical offset addition, and automatic ETags that distinguish two windows of one file while remaining stable across client subranges.

- [ ] **Step 4: Pin File/App::File ownership.** FileResponse must never map URL path to filesystem path. App::File retains rooted traversal, hidden path, index, development diagnostics, 403/404/405/416 Pages policy, and method handling, but delegates selected regular-file metadata/range/event delivery to the shared planner/response path. Directory keeps its listing/containment behavior. Add direct send failure and HEAD boundary cases.

- [ ] **Step 5: Run RED.** Run:

  ```bash
  prove -lv t/response/04-file.t t/app-file.t t/app-file-resolution.t \
    t/34-directory-security.t t/00-load.t
  ```

  Expected: missing File classes/factory, construction-time `-f/-r`, old range duplication, and old class `app_path` behavior fail.

- [ ] **Step 6: Extract and implement the plan.** Move MIME, stat/ETag, logical-window, condition, and single-range arithmetic into `File::Plan` without copying request-path resolution. File request preflight builds one plan before start; delivery sends one `http.response.body` file event and awaits its Future. It opens no application filehandle.

- [ ] **Step 7: Delegate App::File after safe location selection.** Preserve its `locate`/Result policy and pass only the trusted selected path plus applicable request into the shared planner/response delivery. Rename the convenience constructor to `from_app_path` and update its diagnostics/POD. Do not make the path utility return an app.

- [ ] **Step 8: Run GREEN and security gates.** Run Step 5 plus `t/integration-app-file-demo.t` and `t/integration-app-file-examples.t`. Compile/podcheck the five modules, run rooted-path security tests, and run `git diff --check`.

- [ ] **Step 9: Commit, report, review, and update the ledger.** Stage exactly the ten files and commit `feat: add selected file responses`. Obtain independent security/spec review before Tasks 7–10.

---

### Task 6: Reduce Pages to Negotiated Response Policy

**Files:**

- Modify: `lib/PAGI/Pages.pm`
- Modify: `lib/PAGI/Pages/_Catalog.pm`
- Modify: `t/pages/01-catalog.t`
- Modify: `t/pages/02-rendering-negotiation.t`
- Modify: `t/pages/03-invocation-composition.t`
- Modify: `t/pages/04-status-fields-cache.t`
- Modify: `t/pages/05-redirects.t`
- Modify: `t/integration-pages-example.t`

**Interfaces:**

- Pages class methods require an explicit Request/HTTP-capable metadata source and return one concrete Response immediately.
- Produces ordinary opt-in handlers/functions `welcome_page`, `status_page`, `redirect_page`, and every catalog-derived `*_page`; `:common` and `:all` are exact, with no default exports.
- Removes no-source endpoint factories and three-argument native invocation.

- [ ] **Step 1: Rewrite invocation tests to the single-source contract.** Assert `PAGI::Pages->not_found($request)` and `not_found_page($request)` return the same concrete class/bytes/metadata. No-source class/function calls and three-argument invocation croak. A page function works directly as an ordinary Route handler and fails if placed directly at a native app option without `request_app`.

- [ ] **Step 2: Pin representation identity and negotiation.** For HTML, text, JSON, problem JSON, redirect, and empty outcomes, assert exact Response subclass, status, content type, body bytes, Vary/Cache-Control, and repeated Accept combination. Preserve total-failure/default behavior and every catalog status.

- [ ] **Step 3: Preserve Pages policy tests.** Retain mandatory 401/405/407/426 fields, hostile copy encoding, RFC 9457 members, redirect query/fragment safety, favicon hooks, request IDs, dates/retry fields, cache policy, and configured subclass concurrency. Hooks remain synchronous values; Future returns croak.

- [ ] **Step 4: Pin protocol metadata-only sources.** WebSocket/SSE sources may select a representation without changing protocol state. Unknown, lifespan, malformed, or non-HTTP-capable sources fail. Pages does not emit events itself.

- [ ] **Step 5: Run RED.** Run:

  ```bash
  prove -lv t/pages/01-catalog.t t/pages/02-rendering-negotiation.t \
    t/pages/03-invocation-composition.t t/pages/04-status-fields-cache.t \
    t/pages/05-redirects.t t/integration-pages-example.t
  ```

  Expected: generic Response identity, endpoint arity behavior, duplicate rendering, and direct emission assumptions fail.

- [ ] **Step 6: Replace Pages transport work with concrete constructors.** Keep descriptor normalization, negotiation, safe detail, catalog, headers, favicon, and presentation hooks. HTML/text hooks feed Text/HTML; Perl structures feed JSON/Problem; redirects/empty use their semantic classes. Delete `_endpoint`, arity inspection, raw app emission, and duplicate UTF-8/JSON/Content-Length code.

- [ ] **Step 7: Add exports without caller magic.** Each exported function accepts the same explicit source/options as its class method. `:common` and `:all` contain exactly the spec sets. Configured subclass instances remain supported through methods, not first-party factory dynamic dispatch.

- [ ] **Step 8: Run GREEN and gates.** Run Step 5, then ErrorHandler contract tests as characterization only; do not migrate ErrorHandler until Task 8. Compile/podcheck Pages/Catalog and run `git diff --check`.

- [ ] **Step 9: Commit, report, review, and update the ledger.** Stage exactly the eight files and commit `refactor: make Pages return concrete responses`. Obtain independent policy/negotiation review before Task 8.

---

### Task 7: Make WebSocket Denial and SSE Decline Consume Responses

**Files:**

- Modify: `lib/PAGI/WebSocket.pm`
- Modify: `lib/PAGI/SSE.pm`
- Modify: `lib/PAGI/Endpoint/SSE.pm`
- Modify: `t/websocket/denial-response.t`
- Modify: `t/websocket/deny-close-code.t`
- Modify: `t/sse/13-decline.t`
- Modify: `t/endpoint/10-sse-decline.t`
- Modify: `t/integration/sse-decline-end-to-end.t`

**Interfaces:**

- Produces `await $ws->deny($response)` and `await $sse->decline($response)` only.
- Eligible Response events are adapted from HTTP start/body to the protocol prefix; File/fh/trailer/unknown events fail before protocol response start.
- Live WebSocket/SSE send/backpressure/reconnect semantics remain unchanged.

- [ ] **Step 1: Write the response matrix first.** Cover base bytes, Text/HTML/JSON/Problem, Redirect, Empty, and multi-chunk Stream responses. Assert exact start/body mapping, `more` preservation, every send Future awaited, and the original Response remains reusable.

- [ ] **Step 2: Pin emission-scope identity rules.** Capture the scope seen by Response and assert a shallow top-level clone: only `type => http` and `method => GET` are replaced; all other scalar values and nested references, including state/connection/extensions, are preserved; original protocol scope is unchanged.

- [ ] **Step 3: Pin invalid/state paths.** Reject File before any event, reject wrong/undef/non-Response arguments, WebSocket denial after accept, and SSE decline after start. Without WebSocket denial extension, preserve the policy-close fallback and ignore the custom body. SSE clears deferred keepalive, closes once, and sends no live event after decline.

- [ ] **Step 4: Run RED.** Run:

  ```bash
  prove -lv t/websocket/denial-response.t t/websocket/deny-close-code.t \
    t/sse/13-decline.t t/endpoint/10-sse-decline.t \
    t/integration/sse-decline-end-to-end.t
  ```

  Expected: old `%opts` APIs, missing Response adapters, and File/Stream behavior fail.

- [ ] **Step 5: Implement one private event adapter per protocol or one narrow internal helper.** Build the exact shallow HTTP scope, invoke the Response through full-triplet emission with a validating send wrapper, map only start/body events, and preserve failures. Preflight `is_buffered`/class capability so File cannot emit start before rejection; Stream remains allowed.

- [ ] **Step 6: Remove duplicate mini-response construction.** Delete status/header/body option parsing from `deny`/`decline`; retain state machines, extension/fallback, keepalive cleanup, close transitions, and existing live send methods unchanged.

- [ ] **Step 7: Run GREEN plus live protocol gates.** Run Step 4 and focused send/lifecycle/backpressure suites:

  ```bash
  prove -lv t/websocket/03-lifecycle.t t/websocket/04-send.t \
    t/sse/03-start.t t/sse/04-send.t t/sse/06-lifecycle.t \
    t/sse/14-keepalive-deferred-arm.t
  ```

  Compile/podcheck both modules and run `git diff --check`.

- [ ] **Step 8: Commit, report, review, and update the ledger.** Stage exactly the eight files and commit `refactor: share Responses with protocol denials`. Obtain independent protocol-state review before Tasks 9–12.

---

### Task 8: Migrate Endpoint, ErrorHandler, Compose, and Router Emission Boundaries

**Files:**

- Modify: `lib/PAGI/Endpoint/HTTP.pm`
- Modify: `lib/PAGI/Endpoint/Router.pm`
- Modify: `lib/PAGI/Compose/ResponseGuard.pm`
- Modify: `lib/PAGI/Middleware/ErrorHandler.pm`
- Modify: `lib/PAGI/Routing/Compiler.pm`
- Modify: `t/endpoint/02-http-dispatch.t`
- Modify: `t/endpoint/03-http-to-app.t`
- Modify: `t/endpoint/11-return-contract.t`
- Modify: `t/endpoint/13-router-frontends.t`
- Modify: `t/compose/07-response-guard.t`
- Modify: `t/middleware/03-error-handler.t`
- Modify: `t/middleware/error-handler-contract.t`

**Interfaces:**

- Endpoint/Router handlers continue returning immediate/Future Responses; only native app boundaries emit using the full triplet.
- ErrorHandler passes a direct Request plus error to custom handlers, accepts immediate/Future concrete Responses, applies safe status seeding, and emits full-triplet without replacing the original error on renderer failure.
- Compose ResponseGuard continues detecting actual event completion; it does not inspect mutable Response state.

- [ ] **Step 1: Rewrite boundary tests before code.** Assert Endpoint `dispatch` returns but does not emit a concrete Response; `to_app` emits once with `respond($scope,$receive,$send)`. Assert immediate/Future returns, invalid return diagnostics, automatic HEAD/OPTIONS/405, route middleware, and frontend identity remain unchanged.

- [ ] **Step 2: Pin ErrorHandler ordering/failure behavior.** Cover safe 500 and claimed status, custom `(Request,error) -> Response`, Pages adapter use, invalid/out-of-range/throwing status claims, async reporting, handler failure, send failure, before-start replacement, after-start report-and-rethrow, last-resort bytes, and exception identity. Ensure a custom handler receives two arguments and a one-source Pages factory is wrapped explicitly rather than passed directly.

- [ ] **Step 3: Pin guard and Router stock responses.** A normal completed Response is accepted, silent completion remains an incomplete-response failure, HEAD completion remains valid, and one Router stock 404/405 uses Pages/concrete Responses with authoritative `Allow` and no second send.

- [ ] **Step 4: Run RED.** Run:

  ```bash
  prove -lv t/endpoint/02-http-dispatch.t t/endpoint/03-http-to-app.t \
    t/endpoint/11-return-contract.t t/endpoint/13-router-frontends.t \
    t/compose/07-response-guard.t t/middleware/03-error-handler.t \
    t/middleware/error-handler-contract.t t/routing/16-http-outcomes.t
  ```

  Expected: one-argument `respond`, removed generic finishers, and old Pages callback adaptation fail.

- [ ] **Step 5: Migrate each native boundary.** Normalize immediate values with `Future->wrap`, validate `PAGI::Response`, and await `$response->respond($scope,$receive,$send)`. Do not let dispatch methods emit. Preserve ResponseGuard's event observer and ErrorHandler's outermost production-safe environment handling.

- [ ] **Step 6: Run GREEN and adjacent gates.** Run Step 4 plus `t/compose/05-head-concurrency.t`, `t/compose/06-failsafes.t`, and `t/endpoint/10-integration.t`. Compile/podcheck all five modules and run `git diff --check`.

- [ ] **Step 7: Commit, report, review, and update the ledger.** Stage exactly the twelve files and commit `refactor: emit response values at native boundaries`. Obtain independent error/failure-path review before Task 9.

---

### Task 9: Migrate Remaining First-Party Apps, Middleware, and Test Utilities

**Files:**

- Modify: `lib/PAGI/App/Cascade.pm`
- Modify: `lib/PAGI/App/Directory.pm`
- Modify: `lib/PAGI/App/Healthcheck.pm`
- Modify: `lib/PAGI/App/Loader.pm`
- Modify: `lib/PAGI/App/Proxy.pm`
- Modify: `lib/PAGI/App/Router.pm`
- Modify: `lib/PAGI/App/Throttle.pm`
- Modify: `lib/PAGI/App/URLMap.pm`
- Modify: `lib/PAGI/App/WrapCGI.pm`
- Modify: `lib/PAGI/App/WrapPSGI.pm`
- Modify: `lib/PAGI/Middleware/Auth/Basic.pm`
- Modify: `lib/PAGI/Middleware/Auth/Bearer.pm`
- Modify: `lib/PAGI/Middleware/CORS.pm`
- Modify: `lib/PAGI/Middleware/CSRF.pm`
- Modify: `lib/PAGI/Middleware/ContentNegotiation.pm`
- Modify: `lib/PAGI/Middleware/FormBody.pm`
- Modify: `lib/PAGI/Middleware/Healthcheck.pm`
- Modify: `lib/PAGI/Middleware/HTTPSRedirect.pm`
- Modify: `lib/PAGI/Middleware/JSONBody.pm`
- Modify: `lib/PAGI/Middleware/Maintenance.pm`
- Modify: `lib/PAGI/Middleware/RateLimit.pm`
- Modify: `lib/PAGI/Middleware/ReverseProxy.pm`
- Modify: `lib/PAGI/Middleware/Rewrite.pm`
- Modify: `lib/PAGI/Middleware/Static.pm`
- Modify: `lib/PAGI/Middleware/TrustedHosts.pm`
- Modify: `lib/PAGI/Test/Client.pm`
- Modify: `lib/PAGI/Test/Response.pm`
- Modify: `t/app/02-routing.t`
- Modify: `t/app/03-router.t`
- Modify: `t/app/04-utilities.t`
- Modify: `t/app/07-routing-composition.t`
- Modify: `t/app-proxy.t`
- Modify: `t/app-router.t`
- Modify: `t/app-wrapcgi-env.t`
- Modify: `t/middleware/04-static.t`
- Modify: `t/middleware/06-security.t`
- Modify: `t/middleware/09-body-parsing.t`
- Modify: `t/middleware/10-session-auth.t`
- Modify: `t/middleware/11-url-handling.t`
- Modify: `t/middleware/12-protocol-specific.t`
- Modify: `t/middleware/13-development.t`
- Modify: `t/middleware/cors-warning.t`
- Modify: `t/middleware/rate-limit.t`
- Modify: `t/test-client/01-response.t`
- Modify: `t/test-client/02-client-http.t`
- Modify: `t/test-client/06-integration.t`
- Modify: `t/test-client/07-multi-value.t`
- Modify: `t/test-client/08-exception-handling.t`

**Interfaces:**

- First-party HTTP outcomes are concrete Responses emitted with the full native triplet or returned from Request handlers.
- CORS policy remains `PAGI::Middleware::CORS`; literal headers remain Response metadata.
- Test Client/Test Response continue exposing recorded wire results rather than depending on Response builder internals.

- [ ] **Step 1: Reconcile the exact listed files with the inventory before edits.** In the ledger/report, classify every production file above as `runtime change`, `POD-only migration`, or `inspected/no change`, and record the listed focused tests. Files classified `inspected/no change` are not staged. Any newly discovered live consumer is a deviation requiring controller approval before editing.

- [ ] **Step 2: Add or migrate focused tests for every runtime consumer.** Exercise at least one success and each module-owned error outcome. Assert exact status/content type/body/required headers, immediate/Future send handling, non-HTTP behavior, and no use of removed finishers. For CORS, preserve simple, credentialed, rejected-origin, and preflight behavior after `Response->cors` removal.

- [ ] **Step 3: Run the exact focused RED gate.** Run every test listed in this task in one `prove -lv` invocation and save the command verbatim in `task-9-report.md`. Expected failures must be only removed Response/Pages/deny/decline spellings or full-triplet emission; investigate any unrelated failure before production edits.

- [ ] **Step 4: Migrate apps and middleware with the narrowest owner.** Request handlers return a factory/class Response. Native apps/middleware call `respond($scope,$receive,$send)` only where they themselves own emission. Apps that already forward downstream events remain event middleware and must not grow Response buffering. Preserve method `Allow`, authentication challenges, proxy/rewrite redirects, Retry-After/rate-limit fields, JSON/body parse diagnostics, and protocol pass-through.

- [ ] **Step 5: Migrate test utilities without weakening wire assertions.** Test Client accepts coderef or instantiated `to_app` root as already specified. Test Response continues decoding captured event streams, including repeated headers and file/body events; it does not become a constructor for production Responses.

- [ ] **Step 6: Run GREEN, syntax, POD, and live-source search.** Rerun the exact Step 3 command. Compile every changed module with project Perl 5.42.2, podcheck modules with POD, and run:

  ```bash
  rg -n --glob 'lib/**' --glob 't/**' \
    'PAGI::Response->(text|html|json|send|send_raw|send_file|stream|empty|redirect)|->respond\(\$send\)|->cors\(|->deny\([^\)]*(status|body)|->decline\([^\)]*(status|body)'
  git diff --check
  ```

  Remaining matches must be explicit removal/upgrade assertions or receive a ledger classification.

- [ ] **Step 7: Commit, report, review, and update the ledger.** Stage only listed files classified as changed and commit `refactor: migrate first-party response consumers`. Obtain independent review of every changed runtime category before examples/docs depend on it.

---

### Task 10: Migrate Every Live Example, Led by the Starlette Apples Comparison

**Files:**

- Modify: `examples/starlette-apples/app.pl`
- Modify: `examples/starlette-apples/README.md`
- Modify: `examples/15-large-application/lib/MyApp/Root.pm`
- Modify: `examples/15-large-application/lib/MyApp/Person.pm`
- Modify: `examples/15-large-application/lib/MyApp/Person/Blogs.pm`
- Modify: `examples/15-large-application/README.md`
- Modify: `examples/pages/app.pl`
- Modify: `examples/pages/README.md`
- Modify: `examples/endpoint-router-demo/lib/MyApp/API.pm`
- Modify: `examples/endpoint-router-demo/lib/MyApp/Main.pm`
- Modify: `examples/endpoint-router-demo/README.md`
- Modify: `examples/13-contact-form/app.pl`
- Modify: `examples/14-lifespan-utils/app.pl`
- Modify: `examples/background-tasks/app.pl`
- Modify: `examples/compose/app.pl`
- Modify: `examples/declarative-routing/app.pl`
- Modify: `examples/declarative-routing/lib/MyApp/Routes/Home.pm`
- Modify: `examples/endpoint-demo/app.pl`
- Modify: `examples/test-lifespan-shutdown/app.pl`
- Modify: `examples/websocket-chat-v2/lib/ChatApp/HTTP.pm`
- Modify: `t/integration-starlette-apples.t`
- Modify: `t/integration-large-application.t`
- Modify: `t/integration-pages-example.t`
- Modify: `t/integration-endpoint-router-demo.t`
- Modify: `t/integration-compose-demo.t`
- Modify: `t/integration-declarative-routing-demo.t`
- Modify: `t/integration-lifespan-utils-example.t`
- Modify: `t/integration-websocket-chat-v2.t`

**Interfaces:**

- Apple `/` is exact `route('/' => file_response(...))`, `/welcome` is `\&welcome_page`, `/apples` remains a child Router, and root custom 404 uses `http_default => request_app(\&root_not_found)`.
- CRUD handlers use `json_response`; no handler manually emits.
- READMEs preserve synchronized complete source blocks and the untouched Python comparison.

- [ ] **Step 1: Reconcile the named example set.** Search `examples/` for removed Response finishers, Pages no-source endpoint calls, `respond($send)`, denial/decline `%opts`, and `PAGI::App::File->app_path`. Every match must already be in the named file list; a new match is a scope deviation requiring approval before editing. Classify named files with no live migration as inspected/no-change and do not stage them.

- [ ] **Step 2: Rewrite integration assertions first.** For Apples, pin `/` file SPA, `/welcome`, list/create/read/update/delete, URL generation, invalid typed ID, child 404/405, root custom 404 for every method, exact 405 `Allow`, and no catchall route. Assert source-copy synchronization and unchanged Python block hash.

- [ ] **Step 3: Run RED.** Run the four named integration tests plus every frozen additional example integration. Expected: old constructors/factories or direct Page app shape fail; no unrelated behavior regression.

- [ ] **Step 4: Migrate Apples exactly to spec §19.** Use `PAGI::Response qw(file_response json_response)`, Pages function exports, and `PAGI::Routing qw(route mount router request_app)`. Keep the lifespan-backed database helper unchanged. Preserve Perl 5.40 signatures and the current SPA asset.

- [ ] **Step 5: Migrate remaining examples by ownership.** Handlers return concrete Responses; raw apps emit full-triplet; native defaults use `request_app`; file subtrees use App::File `from_app_path`; selected files use File Response; protocol denial/decline receives a Response. Do not introduce compact routing syntax or simplify example data architecture.

- [ ] **Step 6: Synchronize README source and run GREEN.** Rerun Step 3. Compare the Apple README Perl block byte-for-byte with `app.pl`, verify the Python block SHA recorded before edits is unchanged, compile every changed example with its declared Perl version, and run `git diff --check`.

- [ ] **Step 7: Commit, report, review, and update the ledger.** Stage only the frozen example/test set and commit `examples: adopt concrete response values`. Obtain independent example clarity and behavior review before public docs.

---

### Task 11: Publish the Class Model and Complete Upgrade Guide

**Files:**

- Modify: `lib/PAGI/Response.pm`
- Modify: `lib/PAGI/Response/Text.pm`
- Modify: `lib/PAGI/Response/HTML.pm`
- Modify: `lib/PAGI/Response/JSON.pm`
- Modify: `lib/PAGI/Response/Problem.pm`
- Modify: `lib/PAGI/Response/Redirect.pm`
- Modify: `lib/PAGI/Response/Empty.pm`
- Modify: `lib/PAGI/Response/Stream.pm`
- Modify: `lib/PAGI/Response/Writer.pm`
- Modify: `lib/PAGI/Response/File.pm`
- Modify: `lib/PAGI/Response/File/Plan.pm`
- Modify: `lib/PAGI/Pages.pm`
- Modify: `lib/PAGI/Routing.pm`
- Modify: `lib/PAGI/Routing/Route.pm`
- Modify: `lib/PAGI/Routing/Mount.pm`
- Modify: `lib/PAGI/WebSocket.pm`
- Modify: `lib/PAGI/SSE.pm`
- Modify: `lib/PAGI/App/File.pm`
- Modify: `lib/PAGI/Middleware/CORS.pm`
- Modify: `lib/PAGI/Tools.pm`
- Modify: `lib/PAGI/Tools/Tutorial.pod`
- Modify: `lib/PAGI/Tools/Cookbook.pod`
- Modify: `README.md`
- Modify: `UPGRADING.md`
- Modify: `Changes`
- Create: `t/upgrading-response-family.t`
- Modify: `t/00-pod/cookbook-examples.t`
- Modify: `t/00-load.t`

**Interfaces:**

- POD documents the exact constructors/exports/classes, buffered versus streaming costs, full-triplet raw emission, Route versus Mount, Stream backpressure/disconnect/HEAD behavior, File selected-path lifecycle, Pages policy, and response-valued protocol denial.
- UPGRADING contains every before/after row and downstream Thunderhorse handoff required by spec §25.

- [ ] **Step 1: Write executable upgrade assertions first.** Cover every removed spelling from spec §25: Request response bridge, generic finishers, custom charset escape hatch, scope/is_sent/has_body_source/CORS, Writer takeover, one-argument respond, class App::File `app_path`, direct Pages native app, denial/decline `%opts`, and JSON key-order non-contract. Execute valid after forms and assert removed methods are absent or fail with the documented diagnostic.

- [ ] **Step 2: Run documentation RED.** Run:

  ```bash
  prove -lv t/upgrading-response-family.t t/00-pod/cookbook-examples.t t/00-load.t
  ```

  Also run scoped live prose searches for every obsolete spelling. Expected: stale public examples/POD and missing upgrade coverage fail.

- [ ] **Step 3: Rewrite primary Response and subclass POD.** Lead with class identity and class/factory forms, then memory behavior. Document exact options, validation, metadata methods, snapshot/concurrency rules, `respond`, `to_app`, non-HTTP failure, and subclass hooks. Stream prominently requires awaiting each write, forbids overlap, explains transport fallback versus optional `transport`, and documents PAGI 0.5's successful pending-send settlement plus race-free await-then-check. State explicitly that disconnect never manufactures a write failure, genuine validation/resource failures still propagate, Stream may cancel its own producer but never a send Future, no competing receive loop/reconnect exists, HEAD may run an expensive producer, and an explicit HEAD route is the escape hatch.

- [ ] **Step 4: Rewrite File/Route/Mount/Pages/protocol POD.** Place exact Route, wildcard Route, and subtree Mount side-by-side. Explain selected trusted File versus App::File untrusted path resolution, deferred request-time file validation, logical windows rather than automatic 206, and `from_app_path` versus utility `app_path`. Pages shows ordinary function handlers and explicit raw emission; WebSocket/SSE show eligible Responses, File rejection, and state/fallback behavior.

- [ ] **Step 5: Update Tutorial, Cookbook, front page, README, Changes, and UPGRADING.** Preserve developed prose while replacing obsolete examples. Include the complete Apple before/after reasoning, raw PAGI example, CORS middleware migration, startup file-validation tradeoff, Thunderhorse-facing handler changes, and all spec §25 table rows. Mark features as shipped only once their tasks are committed; Changes remains `0.002003 UNRELEASED`.

- [ ] **Step 6: Run GREEN and doc gates.** Rerun Step 2. Podcheck every changed POD/module, compile executable snippets through cookbook/upgrading tests, ensure all new modules load, run the obsolete live-source search across `lib/`, `t/`, `examples/`, README, UPGRADING, and Changes while exempting historical `docs/superpowers`, then run `git diff --check`.

- [ ] **Step 7: Commit, report, review, and update the ledger.** Stage exactly the documented files and commit `docs: explain the response family migration`. Obtain independent technical-copy and API-completeness review before final audit.

---

### Task 12: Exhaustive Contract Audit, Full Suite, and Distribution Build

**Files:**

- Create ignored evidence: `.superpowers/sdd/2026-08-28-http-response-family-and-streaming/task-12-audit-report.md`
- Modify production/tests/docs only for independently reviewed corrections authorized through the deviation ledger

**Interfaces:**

- Produces no new API. It proves every approved spec requirement, inventory row, consumer, example, and distribution artifact is complete at one reviewed HEAD.

- [ ] **Step 1: Audit the spec and public inventory before running the suite.** Map every requirement in spec §§6, 8–16, 20–21, 23–26 to a committed implementation/test/doc location. Confirm all inventory rows have a final classification/evidence and no unapproved API disappeared. Confirm historical docs were not rewritten.

- [ ] **Step 2: Run a changed-test focused gate.** Construct the exact union of test files changed by Tasks 1–11, deduplicate it, and run once under project Perl. Record Files/Tests, elapsed time, exit status, and warnings. Any defect gets a narrow TDD correction plus independent review before continuing.

- [ ] **Step 3: Perform adversarial probes.** At minimum probe: unchanged Response concurrent emission; mutation after `to_app`; component Route method union; Stream overlapping writes, a send pending at disconnect resolving normally, resumed connection-state visibility, no send cancellation, proactive producer cancellation, and exactly-once cleanup; file logical-window physical offsets and deferred existence; Pages repeated Accept; ErrorHandler after-start failure; protocol shallow scope clone/File rejection; and Apple DELETE of an unknown root path returning custom 404 rather than wildcard 405.

- [ ] **Step 4: Run compatibility, POD, and live-surface gates.** Compile every changed distribution module with project Perl 5.42.2, podcheck every changed POD, run `t/00-load.t`, run the full obsolete-spelling search, verify no unexpected runtime dependency, confirm any server-backed settlement probe uses PAGI::Server 0.002010 or newer, and run `git diff --check`.

- [ ] **Step 5: Pause for Phase A review.** Obtain independent exhaustive review of the audit map, adversarial evidence, all corrections, exact HEAD, and the reserved suite/build commands. Do not run the full suite until the reviewer approves Phase B.

- [ ] **Step 6: Run the repository suite exactly once at reviewed HEAD.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t'
  ```

  Preserve the complete summary. If and only if socket tests fail solely because the sandbox forbids binding, run the repository's established host-access replacement once and record both attempts. An ordinary failure stops the build; correct/review it and obtain explicit approval before a replacement final suite.

- [ ] **Step 7: Build and inspect one distribution archive.** After a passing suite, run project-Perl `dzil build` exactly once. Do not run `dzil test`. Verify archive integrity, version `0.002002` with `Changes` carrying `0.002003 UNRELEASED`, prerequisites, all new Response modules, live docs/tests/examples required for shipping, absence of historical docs/VCS/evidence/symlinks, no duplicate entries, and expected `MetaNoIndex`/PruneFiles behavior. Restore any generated tracked README side effect exactly to reviewed HEAD.

- [ ] **Step 8: Close evidence without committing audit-only files.** Record final HEAD, suite/build commands and counts, archive path/size/SHA-256/entry counts, exclusions, final `git status --short`, and `git diff --check`. Update every ledger row and mark Task 12 complete only if tracked status is clean and no release blocker remains. Do not push, merge, tag, release, delete worktrees, or remove build artifacts without separate user authorization.

---

## Execution Handoff

After this plan is committed, execute it only from an isolated worktree using one of these workflows:

1. **Subagent-Driven Development (recommended):** one fresh implementer per task, independent spec and code-quality reviews, then controller verification and ledger update.
2. **Inline Execution:** use `superpowers:executing-plans` in the isolated worktree with explicit checkpoints after each task.

No implementation begins on the primary `main` checkout, and no task may rely on an unreviewed predecessor.
