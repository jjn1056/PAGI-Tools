# Remove PAGI::Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove `PAGI::Context` completely, make all class-based Endpoint and ErrorHandler callbacks use the direct protocol objects, transfer useful coverage to the owning APIs, and migrate every live example and document.

**Architecture:** `PAGI::Request`, `PAGI::WebSocket`, and `PAGI::SSE` become the only first-party handler objects. Endpoint adapters construct those objects, HTTP dispatch returns a Response while `to_app` emits it, and ErrorHandler applies its resolved status to a returned status-aware Response. Router/middleware capabilities remain explicit scope-bound helpers, while raw applications and middleware retain the native PAGI triplet.

**Tech Stack:** Perl 5.16-compatible library code, `Future`, `Future::AsyncAwait`, Test2::V0, PAGI protocol events, Dist::Zilla

**Spec:** `docs/superpowers/specs/2026-08-27-context-removal-design.md`

## Global Constraints

- Work only in `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools`.
- At execution start, use `superpowers:using-git-worktrees` and record a fresh work map: repository path, ticket `Remove PAGI::Context`, feature branch, exact base commit, owned paths, deployment boundary, and push target.
- The approved design base is `main@7b1b940`; execution must start from the reviewed `main` commit that contains this plan and record that exact SHA rather than assuming the design-base SHA.
- Create `.superpowers/sdd/2026-08-27-remove-pagi-context/progress.md` with one row per task: status, implementation SHA, review/fix SHAs, focused test counts, syntax/POD evidence, deviations, and reviewer verdict. Update the row in the same task turn as its commit.
- Record every scope deviation as `DEV-NNN` with reason and parent approval before depending on it.
- Do not modify, stage, overwrite, or discard the existing uncommitted Response-family design or the unrelated alignment/evidence files in the primary worktree.
- Delete all four Context modules without aliases, stubs, warnings, or a replacement generic factory.
- Do not add `request_class`, `websocket_class`, `sse_class`, or another replacement for `context_class`.
- Keep normal middleware and raw applications on `($scope, $receive, $send)`.
- Keep the current Response implementation and `respond($send)` contract; do not implement the Response-family design in this campaign.
- Keep `PAGI::Request->response` temporarily, but do not add new production dependencies on it.
- Preserve strict explicit protocol types. `PAGI::Request` does not infer a missing type.
- Endpoint callback boundaries that can await must use `Future->wrap`; never directly await a value that may be an immediate Response or `undef`.
- WebSocket/SSE disconnect callbacks remain synchronous because their close notification does not await callback Futures.
- Preserve ErrorHandler exception identity, post-start rethrow, last-resort behavior, and custom-renderer failure propagation.
- Use `apply_patch` for repository edits and exact file deletions. Preserve unrelated work.
- Use focused tests per task. Run the complete `prove -lr t` suite only once in Task 8, with host access if socket tests require it. Run `dzil build` only once after that suite; do not run `dzil test`.
- Every production task gets an independent spec-compliance/code-quality review before the next task begins.

---

### Task 1: Make HTTP Endpoints Request-first

**Files:**
- Modify: `lib/PAGI/Endpoint/HTTP.pm`
- Modify: `t/endpoint/01-http-constructor.t`
- Modify: `t/endpoint/02-http-dispatch.t`
- Modify: `t/endpoint/03-http-to-app.t`
- Modify: `t/endpoint/04-http-options.t`
- Modify: `t/endpoint/10-integration.t`
- Modify: `t/endpoint/11-return-contract.t`

**Interfaces:**
- Consumes: `PAGI::Request->new($scope, $receive)`, `PAGI::Utils::is_response($value)`, current `PAGI::Response->respond($send)`.
- Produces: `dispatch($request) -> Future<PAGI::Response>` with no sends; `to_app` constructs one Request, awaits dispatch, and emits exactly once. Verb methods receive `($self, $request)`. `context_class` no longer exists.

- [ ] **Step 1: Establish the worktree, work map, ledger, and baseline**

Record the exact branch/base/status in the ledger. Confirm the primary worktree's unrelated files are absent from the feature worktree. Run:

```bash
prove -lv \
  t/endpoint/01-http-constructor.t \
  t/endpoint/02-http-dispatch.t \
  t/endpoint/03-http-to-app.t \
  t/endpoint/04-http-options.t \
  t/endpoint/10-integration.t \
  t/endpoint/11-return-contract.t
```

Expected baseline: PASS. Record Files/Tests and the exact starting SHA.

- [ ] **Step 2: Rewrite HTTP Endpoint tests first**

Use `PAGI::Request` and `PAGI::Response` in fixtures. Add assertions equivalent to:

```perl
my $request = PAGI::Request->new($scope, $receive);
my @events;
my $response = TestEndpoint->new->dispatch($request)->get;

isa_ok($request, ['PAGI::Request']);
isa_ok($response, ['PAGI::Response']);
is(\@events, [], 'dispatch returns a Response without sending');
```

Add one synchronous handler and one Future-backed handler:

```perl
sub get {
    my ($self, $request) = @_;
    return PAGI::Response->text('sync');
}

sub post {
    my ($self, $request) = @_;
    return Future->done(PAGI::Response->text('future', status => 201));
}
```

Pin all of these behaviors:

- verb handlers receive exactly `PAGI::Request`;
- `dispatch` returns but does not emit the Response;
- `to_app` emits exactly one start and one terminal body;
- `context_class` is absent on the base and subclass;
- missing and non-HTTP scope types fail before a handler call;
- implicit HEAD calls GET, while explicit HEAD wins;
- automatic OPTIONS and 405 retain complete sorted `Allow`;
- invalid/undef handler returns retain the Endpoint diagnostic; and
- one compiled HTTP Endpoint instance is reused across requests.

- [ ] **Step 3: Run the focused tests and confirm RED**

Run the Step 1 command. Expected: failures identify the Context argument, sending `dispatch`, direct `await` of immediate values, and still-present `context_class`; no unrelated failure.

- [ ] **Step 4: Implement the minimal Request-first HTTP adapter**

In `PAGI::Endpoint::HTTP`:

```perl
use PAGI::Request;
use PAGI::Response;

async sub dispatch {
    my ($self, $request) = @_;
    my $http_method = lc($request->method // 'GET');
    my $response;

    if ($http_method eq 'options' && !$self->can('options')) {
        my $allow = join(', ', $self->allowed_methods);
        $response = PAGI::Response->new($request->scope)
            ->header('Allow', $allow)
            ->empty;
    }
    elsif ($http_method eq 'head'
            && !$self->can('head') && $self->can('get')) {
        $response = await Future->wrap($self->get($request));
    }
    elsif ($self->can($http_method)) {
        $response = await Future->wrap($self->$http_method($request));
    }
    else {
        $response = PAGI::Pages->method_not_allowed(
            $request,
            allow => [$self->allowed_methods],
        );
    }

    croak ref($self) . "->$http_method did not return a response"
        unless is_response($response);
    return $response;
}
```

`to_app` must create its singleton Endpoint once and perform the only send:

```perl
my $endpoint = $class->new;
return async sub {
    my ($scope, $receive, $send) = @_;
    my $request = PAGI::Request->new($scope, $receive);
    my $response = await $endpoint->dispatch($request);
    await Future->wrap($response->respond($send));
};
```

Remove `context_class`, the dynamic `require PAGI::Context`, and every Context POD example.

- [ ] **Step 5: Verify GREEN and compatibility boundaries**

Run the focused command. Expected: PASS. Then run:

```bash
perl -Ilib -c lib/PAGI/Endpoint/HTTP.pm
podchecker lib/PAGI/Endpoint/HTTP.pm
git diff --check
```

Also run `t/endpoint/12-route-middleware.t` and `t/endpoint/13-router-frontends.t` to prove native middleware and Router frontend contracts are unchanged.

- [ ] **Step 6: Commit, review, and update evidence**

Stage exactly the seven listed files and commit:

```bash
git commit -m "refactor: pass Request to HTTP endpoints"
```

Write `task-1-report.md`, update the Task 1 ledger row, and obtain independent spec-compliance and code-quality approval before Task 2.

---

### Task 2: Make WebSocket Endpoints direct and share exact-scope cache validation

**Files:**
- Modify: `lib/PAGI/Utils/Scope.pm`
- Modify: `lib/PAGI/Routing/Compiler.pm`
- Modify: `lib/PAGI/Endpoint/WebSocket.pm`
- Modify: `t/utils-scope-source.t`
- Modify: `t/routing/08-protocols.t`
- Modify: `t/endpoint/05-websocket-constructor.t`
- Modify: `t/endpoint/06-websocket-lifecycle.t`
- Modify: `t/endpoint/07-websocket-to-app.t`
- Modify: `t/endpoint/10-integration.t`

**Interfaces:**
- Consumes: exact selected scope, receive, and send; `PAGI::WebSocket->new`.
- Produces: internal `PAGI::Utils::Scope::_compatible_cached_scope_object($scope, $key, $expected_class) -> object|undef`; WebSocket hooks receive the same direct `PAGI::WebSocket` object for one connection.

- [ ] **Step 1: Add exact-scope cache and direct-callback tests**

In `t/utils-scope-source.t`, add cases for absent, valid, wrong-class, throwing-scope, and other-scope cached objects. The valid object must be returned without deletion; every invalid object must produce `undef` and remove the key.

In Endpoint tests, assert:

```perl
is(ref($seen_connect), 'PAGI::WebSocket', 'connect receives direct channel');
is(refaddr($seen_connect), refaddr($seen_receive),
    'receive sees the exact connection object');
is(refaddr($seen_connect), refaddr($seen_disconnect),
    'disconnect sees the exact connection object');
is(refaddr($seen_connect->scope), refaddr($selected_scope),
    'channel owns the exact selected scope');
```

Add shallow-clone cases seeded with:

- a real WebSocket bound to the parent scope;
- a blessed wrong-class object;
- an object whose `scope` method dies; and
- a same-scope exact `PAGI::WebSocket` object.

Only the final case may be reused. Add immediate-return `on_connect` and
`on_receive` cases, plus a failed-Future propagation case. Keep
`on_disconnect` synchronous and assert its return is not awaited.

- [ ] **Step 2: Run the exact tests and confirm RED**

```bash
prove -lv \
  t/utils-scope-source.t \
  t/routing/08-protocols.t \
  t/endpoint/05-websocket-constructor.t \
  t/endpoint/06-websocket-lifecycle.t \
  t/endpoint/07-websocket-to-app.t \
  t/endpoint/10-integration.t
```

Expected: failures for missing cache helper, Context callback objects, stale cache reuse under Endpoint, and direct `await` of immediate hooks.

- [ ] **Step 3: Add the shared internal cache predicate**

Implement in `PAGI::Utils::Scope`:

```perl
sub _compatible_cached_scope_object {
    my ($scope, $key, $expected_class) = @_;
    my $cached = $scope->{$key};
    my $reusable = (blessed($cached) // '') eq $expected_class
        && $cached->can('scope');
    if ($reusable) {
        my $cached_scope = eval { $cached->scope };
        $reusable = 0
            if $@
                || ref($cached_scope) ne 'HASH'
                || refaddr($cached_scope) != refaddr($scope);
    }
    delete $scope->{$key} unless $reusable;
    return $reusable ? $cached : undef;
}
```

Import `refaddr` alongside `blessed`. Keep this function internal and unexported. Replace Compiler's local cache-validation block with this exact helper, retaining all existing routing behavior and tests.

- [ ] **Step 4: Implement direct WebSocket lifecycle callbacks**

Remove `context_class` and Context loading. In `to_app`, clear an incompatible cache through the shared helper, construct `PAGI::WebSocket`, and pass it to `handle`.

Within `handle($websocket)`:

```perl
await Future->wrap($self->on_connect($websocket));

$websocket->on_close(sub {
    my ($code, $reason) = @_;
    $self->on_disconnect($websocket, $code, $reason);
});

await Future->wrap($self->on_receive($websocket, $data));
```

Preserve automatic accept, text/bytes/JSON decoding, and `run` when no receive hook exists.

- [ ] **Step 5: Verify, commit, review, and record**

Run the Step 2 gate, then:

```bash
perl -Ilib -c lib/PAGI/Utils/Scope.pm
perl -Ilib -c lib/PAGI/Routing/Compiler.pm
perl -Ilib -c lib/PAGI/Endpoint/WebSocket.pm
podchecker lib/PAGI/Endpoint/WebSocket.pm
git diff --check
```

Commit the exact nine-file scope:

```bash
git commit -m "refactor: pass WebSocket to endpoint hooks"
```

Write `task-2-report.md`, update the ledger, and obtain both reviews before Task 3.

---

### Task 3: Make SSE Endpoints direct

**Files:**
- Modify: `lib/PAGI/Endpoint/SSE.pm`
- Modify: `t/endpoint/08-sse-constructor.t`
- Modify: `t/endpoint/09-sse-lifecycle.t`
- Modify: `t/endpoint/10-integration.t`
- Modify: `t/endpoint/10-sse-decline.t`
- Modify: `t/endpoint/14-sse-keepalive-ordering.t`

**Interfaces:**
- Consumes: Task 2's `_compatible_cached_scope_object`; `PAGI::SSE->new`.
- Produces: `on_connect($self, $sse)` and synchronous `on_disconnect($self, $sse)` with one exact direct object per selected connection.

- [ ] **Step 1: Rewrite SSE tests for the direct object**

Pin exact class/reference/scope identity through connect and disconnect. Add the same stale-cache matrix as WebSocket using `pagi.sse`, including one reusable same-scope exact object. Add immediate and Future-backed `on_connect` cases and failed-Future propagation.

Retain assertions for:

- deferred keepalive before stream start;
- lazy start from `send_event`;
- default start when `on_connect` is absent;
- decline producing one complete HTTP response and no later `sse.start`;
- a closed stream skipping `run`; and
- synchronous disconnect cleanup.

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
prove -lv \
  t/endpoint/08-sse-constructor.t \
  t/endpoint/09-sse-lifecycle.t \
  t/endpoint/10-integration.t \
  t/endpoint/10-sse-decline.t \
  t/endpoint/14-sse-keepalive-ordering.t
```

Expected: Context-object, stale-cache, and immediate-return failures only.

- [ ] **Step 3: Implement the direct SSE lifecycle**

Remove `context_class` and Context loading. Apply Task 2's cache helper before `PAGI::SSE->new`. Change `handle` to accept the direct stream and use it throughout:

```perl
async sub handle {
    my ($self, $sse) = @_;
    my $keepalive = $self->keepalive_interval;
    await $sse->keepalive($keepalive) if $keepalive > 0;

    $sse->on_close(sub { $self->on_disconnect($sse) })
        if $self->can('on_disconnect');

    if ($self->can('on_connect')) {
        await Future->wrap($self->on_connect($sse));
    }
    else {
        await $sse->start;
    }

    return if $sse->is_closed;
    await $sse->run;
}
```

- [ ] **Step 4: Verify, commit, review, and record**

Run the Step 2 gate, then syntax, POD, and `git diff --check`. Commit the exact six-file scope:

```bash
git commit -m "refactor: pass SSE to endpoint hooks"
```

Write `task-3-report.md`, update the ledger, and obtain both reviews before Task 4.

---

### Task 4: Make ErrorHandler Request-first and status-aware

**Files:**
- Modify: `lib/PAGI/Middleware/ErrorHandler.pm`
- Modify: `t/middleware/error-handler-contract.t`
- Modify: `t/pages/03-invocation-composition.t`
- Modify: `t/compose/04-middleware.t`

**Interfaces:**
- Consumes: strict `PAGI::Request`, current Pages factories, response values implementing both `respond($send)` and `status_try($status)`.
- Produces: custom callback `($request, $original_error)`, explicit status precedence, inferred status fallback, and no Context seed.

- [ ] **Step 1: Rewrite ErrorHandler contract tests**

Replace every Context renderer fixture with `PAGI::Request` and direct `PAGI::Response` construction. Capture the callback inputs:

```perl
handler => sub {
    my ($request, $original) = @_;
    ($seen_request, $seen_error) = ($request, $original);
    return PAGI::Response->json({ error => 'custom' });
}
```

Assert:

- `ref($seen_request) eq 'PAGI::Request'`;
- original blessed-error reference identity is preserved;
- an unset Response receives 418/401/configured status after return;
- an explicit 409 remains 409;
- the callback has no hidden seeded response;
- a respondable object lacking `status_try` fails with
  `handler did not return a status-aware response`;
- a status-aware duck-typed object can receive the seed and respond;
- malformed/throwing/out-of-range exception status claims still become 500;
- immediate and Future-backed handlers work;
- throwing and failed-Future handlers propagate unchanged;
- built-in Pages rendering, last-resort sends, `on_error`, and post-start
  behavior remain unchanged; and
- absent scope type uses a shallow `type => 'http'` view without mutating the
  original hash, while explicit WebSocket/SSE scopes pass through untouched.

Give the status-aware test double both methods:

```perl
sub status_try {
    my ($self, $status) = @_;
    $self->{status} = $status unless exists $self->{status};
    return $self;
}

sub respond {
    my ($self, $send) = @_;
    # emit $self->{status} and one terminal body
}
```

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
prove -lv \
  t/middleware/error-handler-contract.t \
  t/pages/03-invocation-composition.t \
  t/compose/04-middleware.t
```

Expected: Context callback, preseed, and missing `status_try` validation failures.

- [ ] **Step 3: Implement Request-first rendering**

Replace `use PAGI::Context` with `use PAGI::Request`. Preserve the existing HTTP guard. For an absent type only, create the current shallow HTTP view:

```perl
my $request_scope = defined($scope->{type})
    ? $scope
    : { %$scope, type => 'http' };
my $request = PAGI::Request->new($request_scope, $receive);
```

For custom handlers:

```perl
$response = await Future->wrap(
    $self->{handler}->($request, $error),
);
croak 'handler did not return a status-aware response'
    unless PAGI::Utils::is_response($response)
        && $response->can('status_try');
$response->status_try($status);
```

For built-in rendering, call `PAGI::Pages->status($request, $status, @detail)`. Emit through `$response->respond($send)`. Do not catch or replace custom handler failures.

- [ ] **Step 4: Verify, commit, review, and record**

Run the Step 2 gate plus:

```bash
perl -Ilib -c lib/PAGI/Middleware/ErrorHandler.pm
podchecker lib/PAGI/Middleware/ErrorHandler.pm
git diff --check
```

Commit:

```bash
git commit -m "refactor: pass Request to error renderers"
```

Write `task-4-report.md`, update the ledger, and obtain both reviews before deleting Context.

---

### Task 5: Transfer Context coverage and delete the modules

**Files:**
- Delete: `lib/PAGI/Context.pm`
- Delete: `lib/PAGI/Context/HTTP.pm`
- Delete: `lib/PAGI/Context/WebSocket.pm`
- Delete: `lib/PAGI/Context/SSE.pm`
- Delete: every `t/context/*.t` file listed in the spec-era tree
- Modify: `t/00-load.t`
- Modify: `t/authority.t`
- Modify: `t/csrf-helper.t`
- Modify: `t/request-stash.t`
- Modify: `t/request-state.t`
- Modify: `t/transport-helpers.t`
- Modify: `t/routing/13-url-helper.t`
- Modify: `t/pages/03-invocation-composition.t`
- Modify: `t/pages/05-redirects.t`
- Modify: `t/middleware/06-security.t`
- Modify: `t/response.t`
- Test: `t/websocket/03-lifecycle.t`
- Test: `t/websocket/04-send.t`
- Test: `t/websocket/05-safe-send.t`
- Test: `t/websocket/06-receive.t`
- Test: `t/websocket/07-iteration.t`
- Test: `t/websocket/08-cleanup.t`
- Test: `t/websocket/denial-response.t`
- Test: `t/websocket-query-params.t`
- Test: `t/websocket-heartbeat.t`
- Test: `t/sse/02-state.t`
- Test: `t/sse/03-start.t`
- Test: `t/sse/04-send.t`
- Test: `t/sse/05-safe-send.t`
- Test: `t/sse/06-lifecycle.t`
- Test: `t/sse/07-last-event-id.t`
- Test: `t/sse/08-keepalive.t`
- Test: `t/sse/09-iteration.t`
- Test: `t/sse/12-close-event.t`
- Test: `t/sse/13-decline.t`
- Test: `t/sse/14-keepalive-deferred-arm.t`

**Interfaces:**
- Consumes: Tasks 1–4 direct callback contracts and existing scope-source helpers.
- Produces: no Context packages; each retained behavior is tested through its owning direct object/helper.

- [ ] **Step 1: Create the Context test disposition matrix**

Write `.superpowers/sdd/2026-08-27-remove-pagi-context/context-test-matrix.md`. Give every subtest in all sixteen `t/context/*.t` files one of these exact dispositions:

```text
TRANSFER -> target file and target subtest name
ALREADY  -> target file and existing subtest name
DELETE   -> rejected Context factory/delegation/dispatcher behavior and spec section
```

The matrix must explicitly classify:

- factory/type-map/assertion tests as `DELETE` under spec §§5 and 6;
- generic dispatcher tests as `DELETE` under spec §6;
- response accumulator/sugar/double-send tests as `DELETE`, with current
  Response/Compose ownership cited;
- shared helper/authority/path-param facts into the direct helper tests;
- reverse routing into `t/routing/13-url-helper.t` using `path_for`, `url_for`,
  and direct Request/WebSocket/SSE sources;
- WebSocket operations into `t/websocket/03-lifecycle.t`, `04-send.t`,
  `05-safe-send.t`, `06-receive.t`, `07-iteration.t`, `08-cleanup.t`,
  `denial-response.t`, `websocket-query-params.t`, and
  `websocket-heartbeat.t`; and
- SSE operations into `t/sse/02-state.t`, `03-start.t`, `04-send.t`,
  `05-safe-send.t`, `06-lifecycle.t`, `07-last-event-id.t`, `08-keepalive.t`,
  `09-iteration.t`, `12-close-event.t`, `13-decline.t`, and
  `14-keepalive-deferred-arm.t`.

- [ ] **Step 2: Add direct-owner tests before deleting wrappers**

Add only the matrix's `TRANSFER` assertions. Required direct assertions are:

- Host validation and duplicate Host rejection for Request, WebSocket, SSE,
  and raw scope sources;
- strict/default path-parameter behavior on Request and protocol objects;
- stash/state/CSRF/Transport behavior from direct objects and raw scopes;
- URL resolver selection, relative capture inheritance, constraint call count,
  root-path encoding, proxy/Host order, and HTTP/WS scheme mapping through the
  exported URL helpers;
- SSE `is_connected == is_started && !is_closed`; and
- direct close callbacks synchronize WebSocket/SSE state without a Context
  terminal-event hook.

Run the exact direct-owner files named by the matrix and record their top-level and leaf assertion counts before module deletion.

- [ ] **Step 3: Migrate remaining non-Endpoint test fixtures**

Use a strict `PAGI::Request` or raw scope for Pages tests. In security tests, replace Context response emission with an ordinary Response:

```perl
my $response = PAGI::Response->text(
    'application-owned CSRF rejection',
    status => 403,
);
await $response->respond($downstream_send);
```

Remove Context double-send tests from `t/response.t`; retain and clarify that Response itself is a value and server/Compose owns cross-emission enforcement. Replace the Context transport-source row with Request, WebSocket, SSE, and raw-scope rows.

- [ ] **Step 4: Delete the exact Context files and load entry**

Delete with `apply_patch`:

```text
lib/PAGI/Context.pm
lib/PAGI/Context/HTTP.pm
lib/PAGI/Context/WebSocket.pm
lib/PAGI/Context/SSE.pm
t/context/01-factory.t
t/context/02-shared.t
t/context/03-http.t
t/context/03-response-value.t
t/context/04-websocket.t
t/context/05-sse.t
t/context/06-extension.t
t/context/07-router.t
t/context/08-dispatcher.t
t/context/09-websocket-delegation.t
t/context/10-sse-delegation.t
t/context/11-sse-connection-state.t
t/context/12-routing-reverse.t
t/context/assert-type.t
t/context/http-sugar.t
t/context/raw-send.t
```

Remove `PAGI::Context` from `t/00-load.t`.

- [ ] **Step 5: Run the transfer/removal gate**

Run `t/00-load.t`, every changed direct-owner test, all Endpoint tests, the ErrorHandler contract, Pages invocation/redirects, security, Response, and Transport tests. Expected: PASS with no skip introduced to hide a missing module.

Then run:

```bash
rg -n 'use PAGI::Context|require PAGI::Context|PAGI::Context->new|context_class' lib t examples
git diff --check
```

At this task boundary, matches may remain only in Task 6 examples and Task 7 prose/executable upgrade fixtures; classify each exact path in the report.

- [ ] **Step 6: Commit, review, and record**

Stage the exact deletion/transfer paths and commit:

```bash
git commit -m "refactor: remove PAGI Context"
```

Write `task-5-report.md` with the completed matrix and before/after assertion counts, update the ledger, and obtain both reviews before Task 6.

---

### Task 6: Migrate executable examples

**Files:**
- Modify: `examples/endpoint-demo/app.pl`
- Modify: `examples/endpoint-demo/README.md`
- Modify: `examples/websocket-bidirectional/app.pl`
- Modify: `examples/websocket-bidirectional/README.md`
- Modify: `examples/README.md`
- Modify: `t/integration-app-file-examples.t`

**Interfaces:**
- Consumes: direct Endpoint callback objects and explicit `PAGI::Stash::stash`.
- Produces: loadable examples with no Context dependency and preserved HTTP behavior/full-duplex send serialization.

- [ ] **Step 1: Tighten example integration tests first**

Extend `t/integration-app-file-examples.t` to require:

- the Endpoint demo source contains no `$ctx`, `PAGI::Context`,
  `->request`, `->websocket`, or `->sse` reach-through;
- HTTP methods name and use `$request`;
- WebSocket hooks name and use `$websocket`;
- SSE hooks name and use `$sse` plus `stash($sse)`;
- the loaded app still serves `/`, rejects non-JSON POST with negotiated 415,
  lists messages, and creates a JSON message with 201; and
- the bidirectional example loads to a native coderef and names/uses one
  direct `$websocket` in its receive and send loops.

- [ ] **Step 2: Run the integration test and confirm RED**

```bash
prove -lv t/integration-app-file-examples.t
```

Expected: source/behavior failures caused by Context-era callbacks; existing static-file assertions remain green.

- [ ] **Step 3: Migrate the Endpoint demo**

Use direct handlers:

```perl
async sub post {
    my ($self, $request) = @_;
    my $data = await $request->json;
    ...
    return PAGI::Response->json($message, status => 201);
}

async sub on_connect {
    my ($self, $websocket) = @_;
    await $websocket->accept;
}

async sub on_connect {
    my ($self, $sse) = @_;
    my $id = ++$sub_id;
    stash($sse)->set(sub_id => $id);
    await $sse->send_event(...);
}
```

Import `PAGI::Response` and `PAGI::Stash qw(stash)` in the packages that use them. Keep middleware as native triplets.

- [ ] **Step 4: Migrate the bidirectional WebSocket example**

Replace Context construction with:

```perl
use PAGI::WebSocket;

my $websocket = PAGI::WebSocket->new($scope, $receive, $send);
await $websocket->accept;
```

Keep the single serialized send queue, `each_text`, `send_text_if_connected`, `is_connected`, and `Future->wait_any` behavior exactly. Rewrite the README around the direct WebSocket object rather than claiming Context supplies the pattern.

- [ ] **Step 5: Verify, commit, review, and record**

Run the integration test, compile both app files with project Perl, run POD/Markdown copy checks used by the repository, and run `git diff --check`. Commit:

```bash
git commit -m "examples: use direct protocol objects"
```

Write `task-6-report.md`, update the ledger, and obtain both reviews.

---

### Task 7: Publish the breaking migration contract

**Files:**
- Create: `t/upgrading-context-removal.t`
- Modify: `README.md`
- Modify: `UPGRADING.md`
- Modify: `Changes`
- Modify: `lib/PAGI/Tools.pm`
- Modify: `lib/PAGI/Tools/Tutorial.pod`
- Modify: `lib/PAGI/Tools/Cookbook.pod`
- Modify: `lib/PAGI/Endpoint/Router.pm`
- Modify: `lib/PAGI/Compose.pm`
- Modify: `lib/PAGI/Pages.pm`
- Modify: `lib/PAGI/Request.pm`
- Modify: `lib/PAGI/Response.pm`
- Modify: `lib/PAGI/Routing/URL.pm`
- Modify: `lib/PAGI/CSRF.pm`
- Modify: `lib/PAGI/Middleware/CSRF.pm`
- Modify: `lib/PAGI/Middleware/Session.pm`
- Modify: `lib/PAGI/Middleware/ErrorHandler.pm`
- Modify: `lib/PAGI/Transport.pm`
- Modify: `lib/PAGI/Test/ConnectionState.pm`
- Modify: `lib/PAGI/Utils/SecureCompare.pm`
- Modify: `lib/PAGI/WebSocket.pm`
- Modify: `lib/PAGI/SSE.pm`
- Modify: `t/upgrading-request-first-handlers.t`
- Test: `t/endpoint-router.t`
- Test: `t/upgrading-router-frontends.t`

**Interfaces:**
- Consumes: final runtime contracts from Tasks 1–6.
- Produces: one authoritative mechanical upgrade guide and no live Context guidance.

- [ ] **Step 1: Write executable upgrade assertions**

In `t/upgrading-context-removal.t`, exercise actual APIs rather than grepping prose:

```perl
ok(!PAGI::Endpoint::HTTP->can('context_class'),
    'HTTP Endpoint has no context_class hook');
ok(!PAGI::Endpoint::WebSocket->can('context_class'),
    'WebSocket Endpoint has no context_class hook');
ok(!PAGI::Endpoint::SSE->can('context_class'),
    'SSE Endpoint has no context_class hook');
```

Add one working direct callback for each protocol, one `stash($sse)` helper example, and one ErrorHandler callback proving Request + explicit-status precedence. Assert the four Context module files do not exist in the source tree so an accidental reintroduction fails loudly.

- [ ] **Step 2: Run the executable characterization gate and capture the documentation RED**

Run:

```bash
prove -lv \
  t/upgrading-context-removal.t \
  t/upgrading-request-first-handlers.t \
  t/upgrading-router-frontends.t
```

The executable behavior may already be GREEN because Tasks 1–6 implement the runtime before this documentation task. Do not fabricate a runtime failure. Record its initial characterization result, then capture RED with the live-surface search from Step 5: current POD, README, Cookbook, Tutorial, Changes, and upgrading prose still contain the removed Context contract.

- [ ] **Step 3: Write the upgrading section and current Changes entry**

Add a prominent `UPGRADING.md` section with exact before/after blocks for:

- HTTP, WebSocket, and SSE Endpoint callback signatures;
- Context response shortcuts to direct Response construction;
- Context URL/stash/session/state/CSRF/Transport methods to imported helpers;
- ErrorHandler `($context, $error)` to `($request, $error)`;
- removal of the hidden seeded response and `status_try` behavior;
- `context_class`, assertions, type map, raw send/receive, and dispatcher removal;
- custom protocols using their own object; and
- the note that a blessed `PAGI::State` is not `ref(...) eq 'HASH'` even when its compatibility hash dereference works, retained from the prior Request migration.

Rewrite all Context entries in the current `0.002003 - UNRELEASED` Changes section into one coherent breaking-removal entry plus retained direct-object fixes. Do not edit historical design documents.

- [ ] **Step 4: Reconcile all public POD and examples**

Replace Context links/examples with their actual owner. Delete the generic dispatcher recipes rather than translating them into a new abstraction. Ensure ErrorHandler documentation says custom returns require `respond` and `status_try`. Ensure Endpoint disconnect hooks are explicitly synchronous.

Keep `PAGI::Request->response` documented as temporary compatibility for this release, without recommending it in new examples. Do not edit the separate proposed Response-family spec in this task.

- [ ] **Step 5: Run documentation and live-surface gates**

Run the three upgrade tests, all changed-module `perl -Ilib -c` checks, and `podchecker` on every changed POD-bearing module. Then run:

```bash
rg -n \
  'PAGI::Context|Context::HTTP|Context::WebSocket|Context::SSE|context_class|\$ctx->|\$context->' \
  lib t examples README.md UPGRADING.md Changes
```

Expected matches are limited to explicit removal assertions and Before blocks in `UPGRADING.md`/the executable upgrade test. Every retained match must be listed with path, line, and rationale in `task-7-report.md`. `git diff --check` must pass.

- [ ] **Step 6: Commit, review, and record**

Commit the exact approved documentation/test scope:

```bash
git commit -m "docs: explain removal of PAGI Context"
```

Write `task-7-report.md`, update the ledger, and obtain independent documentation/spec and technical review.

---

### Task 8: Final audit, full suite, and distribution build

**Files:**
- Modify only if a verified audit defect requires a separately approved `DEV-NNN`: exact affected production/test/document path
- Evidence only: `.superpowers/sdd/2026-08-27-remove-pagi-context/task-8-audit-report.md`
- Evidence only: `.superpowers/sdd/2026-08-27-remove-pagi-context/progress.md`

**Interfaces:**
- Consumes: the complete seven-task implementation.
- Produces: release evidence that no Context surface remains and the distribution is complete.

- [ ] **Step 1: Perform a requirement-by-requirement audit before the full suite**

Map every spec §5–§18 requirement to a production path, focused test, documentation location, and commit. Confirm every Task 5 matrix row is resolved. Run all changed tests as an explicit focused gate and all changed Perl syntax/POD checks.

Run broad searches for:

```text
PAGI::Context
PAGI/Context.pm
PAGI/Context/
context_class
normal handlers named $ctx or $context
ErrorHandler examples taking ($context, $error)
```

Classify only explicit removal/Before-history references. Do not rewrite `docs/superpowers/specs` or `docs/superpowers/plans` historical records.

- [ ] **Step 2: Resolve only verified release blockers**

If the audit finds a runtime, test, example, or live-doc defect, stop before the full suite. Record `DEV-NNN`, obtain parent approval for exact paths, implement with a focused RED/GREEN cycle, commit separately, and obtain independent review. Do not use Task 8 as general cleanup.

- [ ] **Step 3: Run the repository suite exactly once**

Use the project Perl environment:

```bash
prove -lr t
```

Expected: all tests pass, with only the repository's documented `RELEASE_TESTING` skip. If socket tests fail solely because of sandbox host restrictions, preserve that output and run one authorized host-access replacement suite; do not run a third suite. If any ordinary test fails, stop, record it, and do not build until an approved focused correction is reviewed.

- [ ] **Step 4: Build and inspect the distribution exactly once**

After the suite passes:

```bash
dzil build
```

Do not run `dzil test`. Inspect the generated archive and assert:

- no `lib/PAGI/Context.pm` or `lib/PAGI/Context/*` entries;
- Endpoint, Request, WebSocket, SSE, ErrorHandler, Pages, helpers, upgrading guide, examples, and their tests are present;
- META version/prerequisites are unchanged unless another approved release task changed them;
- no `.git`, `.superpowers`, unrelated alignment notes, symlinks, or duplicate entries; and
- archive integrity passes.

Restore any tracked README side effect from the exact pre-build blob without touching unrelated changes.

- [ ] **Step 5: Close the audit evidence**

Record exact suite Files/Tests/time/exit, build exit, archive path/size/SHA-256/entry counts, search results, final HEAD, and clean tracked status in `task-8-audit-report.md` and the ledger. Do not commit, push, merge, tag, release, or delete the worktree in this task.

---

## Execution completion

After Task 8 is green, use `superpowers:finishing-a-development-branch` to present integration choices. The user must explicitly choose merge/PR/keep/discard. After integration, reconcile `docs/superpowers/specs/2026-08-27-http-response-family-and-streaming-design.md` against the post-Context tree and write its plan as a separate campaign.
