# PAGI::Pages Example Adoption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace generic hand-built example responses with `PAGI::Pages` while preserving domain-specific, branded, and protocol-teaching responses.

**Architecture:** Each selected example uses the invocation form appropriate to the layer it demonstrates: Context handlers return a `PAGI::Response`, while raw PAGI applications explicitly call `respond($send)`. Existing integration tests assert public HTTP behavior, including negotiation and mandatory status headers; no test asserts implementation text.

**Tech Stack:** Perl 5.42.2, `Future::AsyncAwait`, `PAGI::Pages`, `PAGI::Test::Client`, Test2::V0.

## Global Constraints

- Do not change `examples/15-large-application`; its nested custom 404 pages are deliberate.
- Do not change the validation payload in `examples/13-contact-form`.
- Do not change `examples/full-demo`, `examples/sse-close`, or WebSocket protocol error events.
- Leave `examples/10-chat-showcase` resource-error JSON unchanged.
- Keep changes limited to the five approved example families, their focused integration tests and READMEs, and this plan.
- Use `PAGI::Pages` directly; do not add wrappers or new production APIs.

## Work Map

| Repository | Ticket | Branch | Base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | PAGI::Pages example adoption | `chore/examples-pages-adoption` | `main@3b1d06eb5e932d5c6df2a1a8b01c890196f40266` | Five approved example families, focused tests/READMEs, this plan | Examples and documentation only | `origin/chore/examples-pages-adoption` (do not push without request) |

---

### Task 1: Use Pages in Context-based routing examples

**Files:**
- Modify: `t/integration-declarative-routing-demo.t`
- Modify: `examples/declarative-routing/lib/MyApp/Routes/Home.pm`
- Modify: `examples/declarative-routing/README.md`
- Modify: `t/integration-endpoint-router-demo.t`
- Modify: `examples/endpoint-router-demo/lib/MyApp/API.pm`
- Modify: `examples/endpoint-router-demo/README.md`

**Interfaces:**
- Consumes: `PAGI::Pages->not_found($context, %options)`, `method_not_allowed($context, allow => \@methods, %options)`, and `unauthorized($context, challenge => $value, %options)`.
- Produces: Context handlers that return unsent `PAGI::Response` values and route middleware that explicitly responds through `$send`.

- [ ] **Step 1: Write failing declarative-routing expectations**

  Change the 404 requests to send `Accept: application/problem+json` and assert literal RFC 9457 members (`status => 404`, `title => 'Not Found'`, `detail => 'No route matched'`). Change the 405 request similarly and assert `status => 405`, `title => 'Method Not Allowed'`, `detail => 'Method not allowed'`, plus `Allow: GET, HEAD`.

- [ ] **Step 2: Verify the declarative test fails for the expected old JSON shape**

  Run: `prove -lv t/integration-declarative-routing-demo.t`

  Expected: FAIL because the current handlers return `{error => ...}` rather than problem documents.

- [ ] **Step 3: Implement the declarative handlers with Pages**

  Import `PAGI::Pages`. Return `PAGI::Pages->not_found($c, detail => 'No route matched')`. Return `PAGI::Pages->method_not_allowed($c, allow => $trace->allowed_methods, detail => 'Method not allowed')` for the 405 handler.

- [ ] **Step 4: Verify declarative routing and update its README**

  Run: `prove -lv t/integration-declarative-routing-demo.t`

  Expected: PASS. Document that boundary-local callbacks use Pages for negotiated bodies and the routing snapshot for `Allow`.

- [ ] **Step 5: Write failing Endpoint Router expectations**

  Request the denied route with `Accept: text/plain`; assert status 401, `WWW-Authenticate: DemoToken realm="endpoint-router-demo"`, and a body containing `demo token required`. Request `/api/show/999` with the demo token and `Accept: application/problem+json`; assert status 404 and problem detail `User not found`.

- [ ] **Step 6: Verify the Endpoint Router test fails for missing Pages behavior**

  Run: `prove -lv t/integration-endpoint-router-demo.t`

  Expected: FAIL because the current 401 has no challenge and the current 404 is plain text.

- [ ] **Step 7: Implement Endpoint Router responses with Pages**

  Import `PAGI::Pages`. In middleware, construct `unauthorized($scope, challenge => 'DemoToken realm="endpoint-router-demo"', detail => 'demo token required')` and explicitly `respond($send)`. In `show`, return `not_found($c, detail => 'User not found')` when the user is absent.

- [ ] **Step 8: Verify and document the Endpoint Router behavior**

  Run: `prove -lv t/integration-endpoint-router-demo.t`

  Expected: PASS. Add a README paragraph showing why middleware explicitly sends while Context handlers return the Response value.

- [ ] **Step 9: Commit Task 1**

  ```bash
  git add -f docs/superpowers/plans/2026-08-16-pages-example-adoption.md
  git add t/integration-declarative-routing-demo.t examples/declarative-routing/lib/MyApp/Routes/Home.pm examples/declarative-routing/README.md t/integration-endpoint-router-demo.t examples/endpoint-router-demo/lib/MyApp/API.pm examples/endpoint-router-demo/README.md
  git commit -m "docs: use Pages in routing examples"
  ```

### Task 2: Use Pages in raw endpoint and lifespan examples

**Files:**
- Modify: `t/integration-app-file-examples.t`
- Modify: `examples/endpoint-demo/app.pl`
- Modify: `examples/endpoint-demo/README.md`
- Create: `t/integration-lifespan-utils-example.t`
- Modify: `examples/14-lifespan-utils/app.pl`
- Modify: `examples/14-lifespan-utils/README.md`

**Interfaces:**
- Consumes: `PAGI::Pages->unsupported_media_type($scope, as => 'json', detail => $text)` and `PAGI::Pages->welcome($scope, as => 'text')`.
- Produces: raw PAGI branches that explicitly await `$response->respond($send)`.

- [ ] **Step 1: Write a failing endpoint-demo 415 expectation**

  Extend the endpoint-demo subtest to POST `/api/messages` without JSON content type. Assert status 415, `application/problem+json`, title `Unsupported Media Type`, and detail `Content-Type must be application/json`.

- [ ] **Step 2: Verify the endpoint-demo test fails for the old payload**

  Run: `prove -lv t/integration-app-file-examples.t`

  Expected: FAIL because the old response lacks the RFC 9457 title/status members.

- [ ] **Step 3: Implement and document the endpoint-demo response**

  Replace the hand-built `PAGI::Response` 415 with `PAGI::Pages->unsupported_media_type(...)`, explicitly responding through `$send`. Update the middleware section of the README with that raw-application form.

- [ ] **Step 4: Verify endpoint-demo**

  Run: `prove -lv t/integration-app-file-examples.t`

  Expected: PASS.

- [ ] **Step 5: Create a failing lifespan-utils integration test**

  Load `examples/14-lifespan-utils/app.pl` with `do`, run it through `PAGI::Test::Client`, GET `/` with `Accept: text/plain`, and assert status 200 plus text beginning `200 Welcome to PAGI` and containing the PAGI documentation URL.

- [ ] **Step 6: Verify the lifespan-utils test fails for the placeholder response**

  Run: `prove -lv t/integration-lifespan-utils-example.t`

  Expected: FAIL because the current body is only `Hello from PAGI!`.

- [ ] **Step 7: Implement and document the lifespan welcome response**

  Import `PAGI::Pages`; after the lifespan/type branches, return `await PAGI::Pages->welcome($scope, as => 'text')->respond($send)`. Update the README output and explain that `handle_lifespan` owns lifecycle scopes while Pages owns the HTTP response.

- [ ] **Step 8: Verify the lifespan-utils example**

  Run: `prove -lv t/integration-lifespan-utils-example.t`

  Expected: PASS without warnings.

- [ ] **Step 9: Commit Task 2**

  ```bash
  git add t/integration-app-file-examples.t examples/endpoint-demo/app.pl examples/endpoint-demo/README.md t/integration-lifespan-utils-example.t examples/14-lifespan-utils/app.pl examples/14-lifespan-utils/README.md
  git commit -m "docs: use Pages in raw application examples"
  ```

### Task 3: Use Pages for the v2 chat API fallback

**Files:**
- Modify: `t/integration-websocket-chat-v2.t`
- Modify: `examples/websocket-chat-v2/lib/ChatApp/HTTP.pm`
- Modify: `examples/websocket-chat-v2/README.md`

**Interfaces:**
- Consumes: `PAGI::Pages->not_found($scope, as => 'json', detail => $text)`.
- Produces: problem JSON for absent rooms and unmatched direct API paths while leaving successful API payloads unchanged.

- [ ] **Step 1: Write failing API-not-found expectations**

  Add requests for `/api/not-a-route` and `/api/room/missing/history` with `Accept: application/problem+json`. Assert status 404, content type `application/problem+json`, title `Not Found`, and details `No API route matched` and `Room not found`, respectively. Retain the existing successful `/api/stats` assertion.

- [ ] **Step 2: Verify the v2 chat test fails for the old JSON schema**

  Run: `prove -lv t/integration-websocket-chat-v2.t`

  Expected: FAIL because the current responses contain only an `error` member and use `application/json`.

- [ ] **Step 3: Implement Pages-backed API misses**

  Import `PAGI::Pages`. In each absent-room branch, immediately respond with a JSON Pages 404 whose detail is `Room not found`. In the final unmatched route branch, respond with detail `No API route matched`. Keep `_send_json` for successful domain payloads.

- [ ] **Step 4: Verify and document the v2 chat behavior**

  Run: `prove -lv t/integration-websocket-chat-v2.t`

  Expected: PASS. Update the README to explain that the direct dispatcher retains domain success JSON while delegating generic HTTP failures to Pages.

- [ ] **Step 5: Commit Task 3**

  ```bash
  git add t/integration-websocket-chat-v2.t examples/websocket-chat-v2/lib/ChatApp/HTTP.pm examples/websocket-chat-v2/README.md
  git commit -m "docs: use Pages for chat API misses"
  ```

### Task 4: Final verification

**Files:**
- Verify all files changed by Tasks 1-3.

**Interfaces:**
- Consumes: all example behavior above.
- Produces: a clean, tested example-only branch ready for integration.

- [ ] **Step 1: Run the focused integration set**

  ```bash
  prove -lv \
    t/integration-declarative-routing-demo.t \
    t/integration-endpoint-router-demo.t \
    t/integration-app-file-examples.t \
    t/integration-lifespan-utils-example.t \
    t/integration-websocket-chat-v2.t
  ```

  Expected: PASS.

- [ ] **Step 2: Check syntax and POD**

  Run `perl -Ilib -c` for every changed `.pl` and `.pm` file, and `podchecker` for changed READMEs only where applicable (Markdown files require no POD check).

- [ ] **Step 3: Run the complete suite once**

  Run: `prove -lr t/`

  Expected: all tests pass. This repository is not campaigns-api, so do not repeat the suite.

- [ ] **Step 4: Inspect scope and whitespace**

  Run: `git diff --check`, `git status --short`, and `git diff main...HEAD --stat`.

- [ ] **Step 5: Commit any final test/documentation corrections**

  Stage only files in this plan and use `git commit -m "test: verify Pages example adoption"` when a final correction exists. Do not create an empty commit.
