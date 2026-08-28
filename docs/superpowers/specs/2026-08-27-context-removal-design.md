# Remove PAGI::Context

**Date:** 2026-08-27

**Status:** Approved design; implementation planning follows

**Scope:** Delete the generic and protocol-specific `PAGI::Context` classes,
migrate class-based Endpoints and ErrorHandler to the direct protocol objects,
transfer useful Context coverage to its owning modules, and leave the repository
ready for the separate HTTP Response-family redesign

## 1. Decision

PAGI-Tools will remove:

```text
PAGI::Context
PAGI::Context::HTTP
PAGI::Context::WebSocket
PAGI::Context::SSE
```

There will be no compatibility aliases, warning shims, generic protocol
factory, or replacement `context_class` hook.

Applications receive the protocol object that owns the active exchange:

```text
HTTP        PAGI::Request
WebSocket   PAGI::WebSocket
SSE         PAGI::SSE
```

Raw PAGI applications and all middleware retain the native contract:

```perl
async sub ($scope, $receive, $send) { ... }
```

Capabilities installed by another component remain explicit scope-bound
helpers:

```perl
use PAGI::Routing::URL qw(url_for);
use PAGI::Session qw(session);
use PAGI::Stash qw(stash);

my $href = url_for($request, 'apple', { apple_id => 2 });
my $user = session($request)->get('user');
my $log  = stash($request)->get('logger');
```

This is an intentional breaking change to an unreleased PAGI-Tools API. Tests,
examples, documentation, and executable upgrade guidance migrate together.

The change is a prerequisite to, not part of, the HTTP Response-family
redesign. The current `PAGI::Response` emission API remains in place during
this campaign. That makes Context removal independently reviewable and leaves
the later Response work with one fewer compatibility layer.

## 2. Work map

| Repository | Work item | Branch | Base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | Remove `PAGI::Context` | `main` | `main@4cd987ab14cbff1617b8d8af9ba85e76e80107c4` | This design specification only | Documentation/design; no runtime change | None requested |

The eventual implementation is confined to PAGI-Tools. It does not alter the
PAGI protocol or PAGI::Server. Before implementation begins, its execution
plan must record a fresh work map with the then-current branch and base,
production/test/document/example ownership, deployment boundary, and push
target.

The modified HTTP Response-family design and the untracked alignment/evidence
files present beside this work are separate user/session work. They must be
preserved. Response implementation planning remains paused until this
prerequisite lands and the Response design is reconciled with the resulting
code.

## 3. Governing and superseded designs

Where they conflict, this design supersedes:

- the Context handler and extensibility portions of the 2026-08-03
  declarative-routing design;
- the Context contract in the 2026-08-04 Context/Response compatibility
  design;
- the Context reverse-routing methods in the 2026-08-08 Router-mount
  reverse-routing design;
- the Context construction and Endpoint conventions in the 2026-08-10
  unified Router-frontends design;
- Context-based examples in the 2026-08-14 Pages response-factory design;
- Context use in the 2026-08-16 Starlette apples example;
- the temporary Context compatibility surface retained by the 2026-08-27
  Request-first handlers and scope-bound helpers design; and
- the Context assumptions still present in the proposed 2026-08-27 HTTP
  Response-family and streaming design.

These decisions remain in force:

- normal declarative and App Router HTTP handlers receive `PAGI::Request`;
- normal WebSocket and SSE handlers receive their direct protocol objects;
- raw Route targets and native applications receive the PAGI triplet;
- middleware is pure app-to-app three-argument middleware;
- explicit scope-bound helpers own router- and middleware-provided
  capabilities;
- Route matches paths and methods, Mount composes applications, Router selects
  children, and Compose owns the deployed root and lifespan; and
- application-control exceptions are not introduced.

## 4. Why remove Context

### 4.1 It duplicates the direct protocol objects

`PAGI::Context::HTTP` wraps `PAGI::Request` and a mutable Response accumulator.
`PAGI::Context::WebSocket` and `PAGI::Context::SSE` mostly forward methods to
`PAGI::WebSocket` and `PAGI::SSE`. The wrapper adds another public vocabulary
without adding a distinct protocol concept.

The request-first migration has already made direct protocol objects the
normal Router contract. Leaving Context for Endpoint classes and middleware
creates two handler worlds that differ only by which adapter was used.

### 4.2 It combines capabilities with different owners

The base Context currently combines:

1. scope and incoming request facts;
2. HTTP response construction and emission;
3. Router-specific URL generation;
4. middleware-owned stash, session, state, and CSRF access;
5. optional server transport and connection facts; and
6. a generic event dispatcher.

Those features do not have one common owner. Keeping them on one object makes
middleware and Router facilities appear intrinsic and makes a third-party
Router or higher-level framework conform to PAGI-Tools internals.

### 4.3 The simpler layering is reversible

A higher-level framework can wrap or subclass a direct protocol object and add
its own conveniences. PAGI-Tools cannot make a router-coupled Context neutral
after applications depend on it. Removing Context from the toolkit preserves
that downstream choice.

### 4.4 Future protocols deserve their own objects

The Context type map is not the extension seam. If PAGI later gains an MCP or
another custom event type, its toolkit representation should be a direct
protocol object such as `PAGI::MCP`. It should not inherit a base class whose
surface was assembled around HTTP, WebSocket, and SSE conveniences.

## 5. Deleted public surface

Delete the four modules and all of their public methods, including:

- the polymorphic `PAGI::Context->new` factory;
- `_type_map`, `_resolve_class`, and unmapped-type warnings;
- `assert_http`, `assert_websocket`, and `assert_sse`;
- `request`, `response`, `respond`, `req`, and `resp`;
- Context response shortcuts such as `text`, `html`, `json`, and `redirect`;
- Context delegations for WebSocket and SSE operations;
- Context-owned `path_for` and `url_for` compatibility methods;
- Context-owned stash, session, state, and CSRF delegations;
- Context-owned transport and connection delegations;
- raw `send`/`receive` accessors; and
- the generic `on`, `on_default`, `on_error`, `stop`, and `run` dispatcher.

Do not leave a stub package that croaks or warns. A stale `use PAGI::Context`
must fail as an ordinary missing-module error, making migration mistakes loud.

## 6. Capability disposition

| Context capability | Owning API after removal |
| --- | --- |
| HTTP request metadata and body | `PAGI::Request` |
| WebSocket operations and receive loops | `PAGI::WebSocket` |
| SSE operations and stream lifecycle | `PAGI::SSE` |
| path parameters | direct protocol object |
| path and URL generation | `PAGI::Routing::URL` |
| stash | `PAGI::Stash` |
| session | `PAGI::Session` |
| application state | `PAGI::State` |
| CSRF | `PAGI::CSRF` |
| authority/Host validation | `PAGI::Authority` and direct accessors |
| connection, backpressure, and watermarks | `PAGI::Transport` |
| HTTP response construction | current `PAGI::Response`, pending its separate redesign |
| protocol assertion | strict direct-object constructor |
| custom event-type selection | a future protocol-specific object |
| generic event dispatcher | removed |

All scope-bound helpers continue accepting either an unblessed scope hashref
or a blessed object whose `scope` method returns that hashref. Direct
`PAGI::Request`, `PAGI::WebSocket`, and `PAGI::SSE` objects already satisfy
that contract. Raw applications therefore retain equivalent access without a
Context wrapper.

The generic dispatcher is deliberately not relocated. WebSocket and SSE have
protocol-native loops and callbacks. Unusual event streams can use the raw
PAGI receive loop until a concrete reusable abstraction is justified.

## 7. Endpoint::HTTP

### 7.1 Construction and ownership

`PAGI::Endpoint::HTTP->to_app` continues constructing one Endpoint instance
for the lifetime of the compiled application. It constructs one strict
`PAGI::Request` for each request:

```perl
my $request = PAGI::Request->new($scope, $receive);
```

The Request constructor remains authoritative for validating an explicit
`http` scope and the receive callback. Endpoint does not infer a missing scope
type.

Delete `context_class`. Do not replace it with `request_class`. A framework
that needs a different handler object can supply its own Endpoint base class or
native adapter instead of changing the object contract invisibly.

### 7.2 Verb dispatch

Every verb method receives `($self, $request)`:

```perl
package MyApp::Apples;
use parent 'PAGI::Endpoint::HTTP';
use Future::AsyncAwait;
use PAGI::Response ();

async sub get {
    my ($self, $request) = @_;
    return PAGI::Response->json([ values %{ apples($request) } ]);
}
```

Immediate and Future-backed returns are accepted uniformly:

```perl
my $response = await Future->wrap($self->$method($request));
```

The returned value must satisfy `PAGI::Utils::is_response`; otherwise dispatch
croaks with the existing Endpoint-style diagnostic. Dispatch emits it exactly
once through the current API:

```perl
await Future->wrap($response->respond($send));
```

The later Response-family campaign will change that emission call to the full
triplet. Context removal must not pre-implement that redesign.

### 7.3 OPTIONS, HEAD, and 405

Preserve:

- explicit verb methods;
- implicit HEAD dispatch to GET when no explicit HEAD method exists;
- explicit HEAD overriding GET;
- automatic OPTIONS with the complete `Allow` field;
- automatic negotiated 405 through `PAGI::Pages`; and
- the complete, sorted `allowed_methods` result.

Automatic responses use a direct Request as the Pages source and an ordinary
Response value. They do not reconstruct Context.

The existing deployment boundary remains responsible for final HEAD body
suppression when the Endpoint is selected through Routing/Compose. A bare
standalone Endpoint currently has no equivalent final boundary; that existing
deployment-compliance question is recorded but not silently changed by this
campaign. Context removal does not move or duplicate `HeadBoundary`.

## 8. Endpoint::WebSocket

`PAGI::Endpoint::WebSocket->to_app` validates a WebSocket scope, creates one
Endpoint instance for that connection, and obtains the direct channel:

```perl
my $websocket = PAGI::WebSocket->new($scope, $receive, $send);
```

The exact same `$websocket` object is passed to:

```text
on_connect($self, $websocket)
on_receive($self, $websocket, $decoded_message)
on_disconnect($self, $websocket, $code, $reason)
```

The encoding modes `text`, `bytes`, and `json`, automatic accept when
`on_connect` is absent, disconnect registration, and receive-loop behavior
remain unchanged.

Use the same exact-scope cache rule already enforced by declarative routing: a
cached `pagi.websocket` value is reusable only when it is the expected direct
protocol class and its `scope` is the exact selected scope reference. Discard
an inherited, wrong-class, or other-scope cache entry before construction. A
shallow-cloning middleware must not make one connection reuse another
connection's channel state.

Immediate and Future-backed `on_connect` and `on_receive` completion are both
accepted with `Future->wrap`. `on_disconnect` remains a synchronous close
callback because the underlying close notification does not await callback
Futures. Its documentation must say so plainly.

Delete `context_class`; do not add `websocket_class`.

## 9. Endpoint::SSE

`PAGI::Endpoint::SSE->to_app` validates an SSE scope, creates one Endpoint
instance for that connection, and obtains the direct stream:

```perl
my $sse = PAGI::SSE->new($scope, $receive, $send);
```

The same `$sse` object is passed to:

```text
on_connect($self, $sse)
on_disconnect($self, $sse)
```

Preserve deferred keepalive setup, lazy stream start, clean HTTP decline,
closed-after-connect detection, and waiting for disconnect. `on_connect`
accepts immediate or Future completion through `Future->wrap`.
`on_disconnect` remains synchronous for the same callback-ownership reason as
WebSocket.

Apply the equivalent exact-class and exact-scope rule to a cached `pagi.sse`
value before reuse.

Delete `context_class`; do not add `sse_class`.

## 10. ErrorHandler

### 10.1 Callback contract

Change a custom ErrorHandler callback from:

```perl
sub ($context, $original_error) { ... }
```

to:

```perl
sub ($request, $original_error) { ... }
```

The middleware constructs a strict `PAGI::Request` from the HTTP scope and
receive callback. It does not expose `$send` through Request. Preserve the
current ErrorHandler guard convention for a missing type: when the outer guard
has treated an absent type as HTTP, construct a shallow request-local scope
view with `type => 'http'` before calling the strict Request constructor. Do
not mutate the application's original scope. An explicit non-HTTP type still
passes through without HTTP rendering.

### 10.2 Status ownership

Today ErrorHandler seeds the cached Context response before invoking the
custom callback. Remove that action-at-a-distance. Resolve and validate the
exception status as today, invoke the callback, validate its returned Response,
then apply the inferred status only when the Response has no explicit status:

```perl
my $response = await Future->wrap(
    $handler->($request, $original_error),
);

croak 'handler did not return a response'
    unless PAGI::Utils::is_response($response);

$response->status_try($inferred_status);
await Future->wrap($response->respond($send));
```

Consequences:

- a custom callback's explicit status wins;
- an unset status receives the configured or validated exception status;
- the callback no longer reads a hidden preseed from
  `$context->response->status`; and
- a callback that needs to branch on the exception can inspect its explicit
  `$original_error` argument or close over its configuration.

Do not add a third status argument. The returned Response is the status
ownership seam.

### 10.3 Built-in renderer and failure behavior

The built-in Pages renderer receives the Request directly:

```perl
PAGI::Pages->status($request, $status, @detail)
```

Preserve all current ErrorHandler boundaries:

- `on_error` receives the original application error, accepts an immediate or
  Future return, and its own failure is contained;
- a failure after `http.response.start` is reported and rethrown unchanged;
- validated exception `status_code` claims retain their current rules;
- built-in Pages rendering failure emits the fixed safe 500;
- failures while sending that last-resort response propagate without retry;
- an invalid custom-handler return uses the standard diagnostic; and
- a custom handler exception or failed Future propagates unchanged rather than
  being hidden by the built-in fallback.

This campaign changes the custom callback's first argument and status-seeding
mechanism only. It does not introduce exception-based HTTP control flow or
broaden ErrorHandler to non-HTTP scopes.

## 11. Pages and scope-source consumers

`PAGI::Pages`, `PAGI::Routing::URL`, `PAGI::Stash`, `PAGI::Session`,
`PAGI::State`, `PAGI::CSRF`, and `PAGI::Transport` must not depend on a
Context package. Their shared source contract remains structural:

```text
one unblessed scope hashref
or
one blessed object whose scope() returns an unblessed scope hashref
```

Remove Context-specific examples and prose from those modules. Do not narrow
the generic structural contract to a hardcoded list of first-party classes.
That is what keeps the helpers usable by raw PAGI applications and downstream
framework objects.

`PAGI::Request->response` remains temporarily for user-code compatibility
during this prerequisite. Its removal belongs to the Response-family campaign.
No new code in this campaign should rely on it when direct Response
construction is equally clear.

## 12. Before and after examples

### 12.1 HTTP Endpoint

Before:

```perl
async sub post {
    my ($self, $ctx) = @_;
    my $input = await $ctx->request->json;
    return $ctx->json(create_apple($input), status => 201);
}
```

After:

```perl
async sub post {
    my ($self, $request) = @_;
    my $input = await $request->json;
    return PAGI::Response->json(
        create_apple($input),
        status => 201,
    );
}
```

### 12.2 WebSocket Endpoint

Before:

```perl
async sub on_receive {
    my ($self, $ctx, $message) = @_;
    await $ctx->websocket->send_json({ echo => $message });
}
```

After:

```perl
async sub on_receive {
    my ($self, $websocket, $message) = @_;
    await $websocket->send_json({ echo => $message });
}
```

### 12.3 SSE Endpoint with middleware state

Before:

```perl
async sub on_connect {
    my ($self, $ctx) = @_;
    my $user_id = $ctx->stash->get('user_id');
    await $ctx->sse->send_event(data => { user_id => $user_id });
}
```

After:

```perl
use PAGI::Stash qw(stash);

async sub on_connect {
    my ($self, $sse) = @_;
    my $user_id = stash($sse)->get('user_id');
    await $sse->send_event(data => { user_id => $user_id });
}
```

### 12.4 ErrorHandler

Before:

```perl
handler => sub {
    my ($context, $error) = @_;
    return PAGI::Pages->internal_server_error(
        $context,
        as => 'json',
    );
}
```

After:

```perl
handler => sub {
    my ($request, $error) = @_;
    return PAGI::Pages->internal_server_error(
        $request,
        as => 'json',
    );
}
```

## 13. Test migration

The implementation must classify every test under `t/context/` before
deleting it. Unique behavior moves to the module that owns it; forwarding-only
tests disappear with the forwarding layer.

### 13.1 Direct object and helper coverage

Transfer or confirm tests for:

- Request scope validation, metadata, path parameters, body consumption,
  disconnect state, and authority;
- WebSocket connection state, receive/send helpers, close callbacks, denial,
  and decoding modes;
- SSE start/close state, event sending, decline, keepalive, disconnect, and
  query/header access;
- URL lookup from Request, WebSocket, SSE, and raw scope sources;
- stash, session, state, CSRF, and Transport from direct object and raw scope
  sources; and
- exact-scope cache behavior already owned by the direct objects.

Do not recreate Context tests under new filenames merely to preserve test
counts.

### 13.2 Endpoint coverage

Tests must pin:

- exact direct-object classes passed to every callback;
- same-object identity through one WebSocket/SSE connection lifecycle;
- no cross-request or cross-connection object reuse, including inherited,
  wrong-class, and other-scope cache entries;
- HTTP Endpoint singleton and WebSocket/SSE per-connection Endpoint lifetime;
- immediate and Future-backed callback completion;
- invalid response returns and callback failures;
- HTTP verb dispatch, implicit and explicit HEAD, OPTIONS, 405, and `Allow`;
- WebSocket text/bytes/JSON receive modes and automatic accept;
- SSE keepalive, lazy start, decline, and post-decline completion; and
- strict rejection of the wrong or missing scope type.

### 13.3 ErrorHandler coverage

Tests must pin:

- the exact `($request, $original_error)` callback arguments;
- original blessed-error identity;
- immediate and Future-backed custom responses;
- inferred status applied to a response with no explicit status;
- explicit response status winning over the inferred status;
- invalid and throwing `status_code` accessors retaining safe behavior;
- invalid custom return diagnostics;
- custom handler exception and failed-Future identity propagation;
- built-in renderer failure using the fixed last-resort 500;
- send failures propagating without retry; and
- post-start exceptions being reported and rethrown without a second response.

### 13.4 Removal and integration coverage

Add executable upgrade coverage for the before/after handler signatures.
Update existing example integration tests rather than replacing them with
source-string assertions.

A scoped live-tree search across `lib/`, `t/`, examples, current README/POD,
`UPGRADING.md`, and the current unreleased `Changes` section must find no:

- `use`, `require`, inheritance, or construction of `PAGI::Context`;
- `PAGI::Context::*` package reference;
- normal handler documented as receiving `$ctx` or `$context`; or
- `context_class` hook.

Historical specifications and released historical records are not rewritten.

## 14. Documentation and examples

Update at least:

- Endpoint HTTP, WebSocket, and SSE POD;
- ErrorHandler and Pages POD;
- `PAGI::Tools`, Tutorial, and Cookbook;
- repository and examples READMEs;
- the WebSocket bidirectional example;
- load tests and module inventories;
- `UPGRADING.md`; and
- the current unreleased `Changes` entry.

Examples must show direct objects and explicit helper ownership. Use names such
as `$request`, `$websocket`, and `$sse`, not a generic `$ctx` variable. The
upgrade guide must include:

- Context class deletion;
- handler signature changes for each protocol;
- `context_class` removal;
- response-shortcut replacements;
- URL/stash/session/state/CSRF/Transport helper replacements;
- ErrorHandler callback and status-seeding changes;
- generic dispatcher removal; and
- guidance that a future/custom protocol should define its own direct object.

The Thunderhorse handoff is a live migration consumer. Documentation must be
clear enough to give that project as a mechanical upgrade guide; it does not
require changing Thunderhorse in this repository campaign.

## 15. Non-goals

This campaign does not:

- implement the proposed Response subclass family;
- remove `PAGI::Request->response`;
- change `PAGI::Response->respond($send)` to the full triplet;
- redesign `PAGI::Pages` beyond removing Context wording and callers;
- add MCP or another protocol type;
- add a replacement generic event dispatcher;
- create protocol-object subclass hooks on Endpoint;
- change the PAGI protocol or PAGI::Server;
- change Route, Mount, Router, or Compose topology;
- resolve standalone `PAGI::Endpoint::HTTP` HEAD-body suppression outside a
  Routing/Compose boundary;
- add exception-based HTTP outcomes; or
- preserve backward compatibility for Context.

## 16. Implementation constraints

1. Use strict test-first changes for each production seam.
2. Remove Context only after its useful coverage has an identified owner.
3. Use `Future->wrap` at Endpoint callback boundaries; never directly `await`
   an immediate Response.
4. Keep raw PAGI and middleware arity unchanged.
5. Do not weaken strict direct-object constructor validation.
6. Do not introduce hidden response or helper caches as a replacement Context.
7. Preserve ErrorHandler exception identity and response-start boundaries.
8. Preserve user-owned unrelated work and historical design records.
9. Keep the implementation campaign separate from Response-family work.
10. End with one repository-wide suite run and one distribution build; do not
    repeatedly run the full suite when focused tests provide the needed proof.

## 17. Adversarial findings and resolutions

### 17.1 Removing Context can accidentally remove behavior, not just syntax

Resolution: classify every Context test and method. Move behavior to its owner;
delete only forwarding, factory, assertion, and generic-dispatch behavior that
this design explicitly rejects.

### 17.2 Endpoint hooks could recreate the same abstraction indirectly

Replacing `context_class` with `request_class`, `websocket_class`, and
`sse_class` looks extensible but gives equivalent frontends different handler
contracts. Resolution: direct first-party classes are fixed. A framework owns
its distinct Endpoint adapter.

### 17.3 Error status can become invisible to custom renderers

The old cached Context response exposed a preseeded status. That convenience
also coupled the renderer to shared mutable state. Resolution: an unset
returned Response receives the inferred status through `status_try`; an
explicit status wins. The error remains an explicit callback argument. No
third callback argument is introduced.

### 17.4 Direct protocol objects might be reconstructed inconsistently

WebSocket and SSE state depends on one object per selected scope. Resolution:
Endpoint obtains the canonical scope-cached direct object and passes the exact
same reference throughout one lifecycle. Tests pin identity and reject stale
objects from another scope.

### 17.5 Context removal and Response redesign can become one unreviewable diff

Resolution: this campaign retains the current Response value and emission
contract. The Response design is reconciled and planned only after Context is
gone.

### 17.6 Generic event types lose the Context factory extension seam

Resolution: this is intentional. A future protocol receives a purpose-built
object and compiler/Router integration. A warning-returned generic Context
does not provide a meaningful typed API for that protocol.

## 18. Acceptance criteria

The campaign is complete only when:

1. all four Context module files are absent;
2. no current module, test, example, or live documentation loads or recommends
   Context;
3. `context_class` is absent;
4. Endpoint HTTP, WebSocket, and SSE callbacks receive their exact direct
   protocol objects;
5. Endpoint callbacks accept immediate and Future-backed completion where the
   lifecycle can await it;
6. ErrorHandler custom callbacks receive `($request, $original_error)`;
7. ErrorHandler applies inferred status with `status_try` after a valid custom
   response is returned, preserving explicit status;
8. current HTTP, WebSocket, SSE, Pages, helper, Endpoint, and ErrorHandler
   behavior has focused ownership tests;
9. executable examples and upgrade guidance use the new signatures;
10. raw PAGI and middleware triplets are unchanged;
11. the full repository suite passes once in the appropriate host environment;
12. one distribution build passes and contains no Context modules; and
13. the worktree contains no accidental build or unrelated-file changes.

## 19. Sequencing after acceptance

After this campaign lands:

1. update the HTTP Response-family design so it no longer describes Context
   compatibility or Context-owned response state;
2. resolve the remaining Response helper ownership questions, including CORS;
3. write a fresh Response implementation plan against the post-Context tree;
   and
4. execute that plan as its own reviewed campaign.

No Response implementation task should be built on the pre-removal Context
architecture.
