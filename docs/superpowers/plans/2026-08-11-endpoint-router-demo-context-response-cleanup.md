# Endpoint Router Demo Context/Response Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the canonical Endpoint Router demo use the direct Context path-parameter helper and the normal Response emission lifecycle inside native middleware.

**Architecture:** Keep the existing Endpoint object graph, async handler declarations, route declarations, and middleware signature unchanged. Strengthen the existing end-to-end test, then replace only two lower-level API spellings with their public Context/Response equivalents.

**Tech Stack:** Perl 5, PAGI::Endpoint::Router, PAGI::Context, PAGI::Response, Future::AsyncAwait, Test2::V0, PAGI::Test::Client.

## Global Constraints

- Modify only `examples/endpoint-router-demo/lib/MyApp/API.pm`, `t/integration-endpoint-router-demo.t`, and this approved design/plan documentation.
- Keep `async sub` on `home`, `index`, and `show`.
- Preserve the denied response exactly: status 401, body `demo token required`, and a terminal response.
- Use `$c->path_param('user_id')`; do not reach through `$c->request` for the capture.
- Use `$c->text(..., status => 401)->respond($send)` for middleware denial; do not manually emit HTTP events.
- Add no helper, dependency, compatibility path, raw route, or unrelated cleanup.

---

### Task 1: Clean up the Endpoint demo Context and Response usage

**Files:**

- Modify: `t/integration-endpoint-router-demo.t`
- Modify: `examples/endpoint-router-demo/lib/MyApp/API.pm`

**Interfaces:**

- Consumes: `PAGI::Context->path_param($name)`, `PAGI::Context->text($body, status => $status)`, and `PAGI::Response->respond($send)`.
- Produces: the same class-based demo and wire behavior using only the intended public convenience APIs.

- [ ] **Step 1: Strengthen the denied-response integration assertions**

Immediately after the existing denied status assertion, add:

```perl
is($denied->text, 'demo token required',
    'API middleware returns the documented denial body');
is($denied->content_type, 'text/plain; charset=utf-8',
    'API middleware denial uses the Context text response');
```

The body assertion pins existing behavior. The content-type assertion distinguishes the desired Response path from the existing manual `text/plain` event.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-endpoint-router-demo.t'
```

Expected: the new body assertion passes and the new content-type assertion fails because the current middleware emits `text/plain` without `charset=utf-8`.

- [ ] **Step 3: Make the two approved API substitutions**

In `require_demo_token`, replace the two manual send calls with:

```perl
return await $c->text(
    'demo token required',
    status => 401,
)->respond($send);
```

In `show`, replace the request-level capture lookup with:

```perl
my $user_id = $c->path_param('user_id');
```

Do not alter any `async sub` declaration.

- [ ] **Step 4: Run focused verification and verify GREEN**

Run the focused integration command from Step 2.

Expected: `Files=1`, `Tests=2`, all successful, with the denial, generated link, typed capture, WebSocket, SSE, nested 404, and shutdown assertions remaining green.

Then run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -Iexamples/endpoint-router-demo/lib -c examples/endpoint-router-demo/lib/MyApp/API.pm'
git diff --check
```

Expected: syntax OK and no whitespace errors.

- [ ] **Step 5: Review and commit**

Confirm the source diff contains exactly the two API substitutions and the two denial assertions. Commit:

```bash
git add examples/endpoint-router-demo/lib/MyApp/API.pm t/integration-endpoint-router-demo.t
git commit -m "examples: clarify Endpoint Context response usage"
```
