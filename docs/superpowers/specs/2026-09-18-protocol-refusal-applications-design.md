# WebSocket and SSE refusal through ordinary PAGI applications

Date: 2026-09-18

Status: **draft design for user review; not an implementation plan**.

## 1. Objective and authority

Change `PAGI::WebSocket->deny` and `PAGI::SSE->decline` to accept the same
two public forms used by HTTP route endpoints:

- a one-Request handler coderef returning a PAGI application value; or
- an instantiated PAGI application object implementing `to_app`.

A native three-argument coderef is supplied explicitly through the existing
`PAGI::Utils::as_app_object` adapter. The conversation sometimes called this
`as_app`; this proposal uses the existing name and does not add an alias.

The user explicitly prefers consistency and application control over attempts
to prove that an arbitrary application will emit a sensible refusal. A valid
application shape is sufficient for dispatch. Protocol correctness remains the
application's responsibility and is subject to ordinary PAGI server validation.

`_emit` is private. WebSocket, SSE, Routing, and application code must not use
it as an interface to Response implementations. The public execution boundary
is `to_app`, invoked through ordinary PAGI application machinery.

Auth is out of scope. The proposed `PAGI::Response::Auth`, authentication
backends, identity helpers, and the Auth design snapshot are neither dependencies
nor deliverables of this change. Examples use manually constructed handlers,
Responses, Pages applications, and native apps.

The requested input forms and public invocation boundary are settled direction.
On 2026-09-18 the user explicitly confirmed that backward compatibility is not
a requirement for this redesign. Existing APIs, behavior, tests, and examples
may change to establish a coherent contract; do not add compatibility branches,
shims, or deprecation stages merely to preserve the previous implementation.
This ruling does not expand the task into unrelated API changes or Auth work.
The detailed lifecycle design remains for review. Approval to write this spec
is not approval to implement it.

## 2. Work map

No external ticket was supplied. Campaign: protocol refusal application contract.

| Repository path | Branch and base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | `feature/universal-connection-tools`, `b4aae631df4602bcb2fca33427b2081cc1cd6b49` | This design document now; proposed Tools implementation described below | Local unreleased Tools work; no runtime changes in the specification task | None |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI` | Read-only normative reference, observed HEAD `9aebdbc` | No edits | No deployment | None |

No PAGI-Server changes are proposed. Its public connection implementation can
be used for later integration verification, but implementation must not depend
on its internal fields, timer values, or transport classes.

Reconfirm the map before implementation and any later publishing operation.
Preserve unrelated worktree edits and notes.

## 3. Problem in the current implementation

Today both refusal methods require a concrete `PAGI::Response`, inspect
`is_buffered`, and invoke its private `_emit` method. Their nearly identical
bodies also reserve local protocol state, observe response-start sends, manage
pre-start failure recovery, retain asynchronous execution, and accommodate
legacy scopes without a connection object.

This followed the old Plan C explicitly; it was not an accidental implementation
of the new application-oriented contract. The interface is now being revised.

Three public components currently disagree about scope support:

| Component | Current execution contract |
| --- | --- |
| Response `to_app` | Can emit ordinary HTTP response events on HTTP, WebSocket, or SSE scopes |
| Pages application `to_app` | Rejects non-HTTP scopes even though `response_for` can materialize for them |
| Request / RequestResponse adapter | Requires an HTTP scope |

Replacing `_emit` with `invoke_app` alone would not fix handler construction or
Pages application execution. This change aligns those public interfaces and
then simplifies the refusal coordinators around them.

## 4. Public API

### 4.1 Accepted arguments

Both methods accept exactly one target:

```perl
await $ws->deny($target);
await $sse->decline($target);
```

| Target | Interpretation |
| --- | --- |
| Unblessed coderef | One-Request handler |
| Instantiated object with `to_app` | Native PAGI application object |
| `as_app_object($native_coderef)` | Explicit native application object |

Class-name strings, raw hashes, overloaded callable objects without `to_app`,
and undefined values are not targets. Do not infer calling convention from
arity, package name, inheritance, or method names such as `response_for`.

Response and Pages objects satisfy the same application-object contract. No
`isa('PAGI::Response')`, response capability, or `is_buffered` check is part of
target acceptance.

### 4.2 Request-handler example

```perl
use PAGI::Response qw(json_response);

await $ws->deny(sub ($request) {
    return json_response(
        { error => 'Endpoint unavailable', path => $request->path },
        status => 403,
    );
});
```

An async handler has the same input and returns a Future-backed application
value. A synchronous handler executes inline; normalization does not move
blocking work to a thread pool.

### 4.3 Application-object examples

```perl
await $sse->decline(
    text_response('Service unavailable', status => 503),
);

await $ws->deny(
    PAGI::Pages->forbidden(detail => 'Endpoint unavailable'),
);

await $sse->decline(MyApp::UnavailablePage->new);
```

The last object needs only `to_app`; it need not inherit from a toolkit class.
The adapter invokes its application without inspecting its rendering strategy.

### 4.4 Native application example

```perl
use Future::AsyncAwait;
use PAGI::Utils qw(as_app_object);

await $ws->deny(as_app_object(async sub {
    my ($scope, $receive, $send) = @_;

    await $send->({
        type    => 'http.response.start',
        status  => 403,
        headers => [['content-type', 'text/plain']],
    });

    await $send->({
        type => 'http.response.body',
        body => 'Unavailable',
        more => 0,
    });
}));
```

All these forms apply equally to `deny` and `decline`, subject to their protocol
state and status rules. No extra native-coderef dispatch mode is added.

### 4.5 Handler results

A handler receives exactly one `PAGI::Request`. Its immediate or Future-backed
result follows the existing route-handler result grammar: a native application
coderef or an instantiated `to_app` object. A coderef returned by the handler is
a native application, not another Request handler. There is no recursive
handler adaptation or automatic conversion of scalar bodies and hashes.

The handler executes once. A configured object's `to_app` is normalized once for
that refusal invocation; a dynamically returned object's `to_app` is likewise
normalized once when its result is invoked. Do not cache per-request returned
apps on a reusable protocol adapter.

Success resolves to the protocol helper (`$ws` or `$sse`) for fluent use.
It means the invoked application finished, not independent proof
that the peer received the response or that the connection completed cleanly.

## 5. Scope and event ownership

The callback's Request exposes the actual protocol scope. The native app gets
that same scope and the remaining original receive stream. The send path uses
ordinary PAGI events with no protocol-response event mapping.

Do not rewrite the scope's `type` to `http`, manufacture HTTP request-body
events for a native app, consume an initial connect event to hide the protocol,
or replay already-consumed input. No lifespan startup/shutdown is replayed.

The specification already permits ordinary `http.response.*` refusal events on
WebSocket and SSE scopes. This capability is not a claim that an arbitrary app
written only for `type => 'http'` will accept a different scope. Such an app may
reject the scope, just as any delegated app can reject unsupported input.

Built-in Response and Pages applications and the Request-handler adapter will
support the documented refusal scopes. Other apps own their compatibility.

## 6. Request support

### 6.1 Supported sources and metadata

Broaden `PAGI::Request->new($scope, $receive)` to accept `http`, `websocket`, and
`sse`. Keep its existing raw-scope and receive-coderef requirements. Lifespan and
arbitrary custom scope types remain unsupported by Request construction.

Request is a view of incoming request metadata; constructing it performs no
receive, accept/start, send, or connection transition. `scope()` and `raw()`
retain the original hash identity and type.

Headers, query parameters, routing parameters, application state, and the
standalone helpers remain available according to data actually in the scope.
The design does not add auth-specific properties.

Request, WebSocket, and SSE use `PAGI::Headers` for their shared
`pagi.request.headers` cache. Their `headers` methods expose that container;
`header` and `header_all` use its case-insensitive lookup behavior and preserve
repeated values regardless of which helper accesses the headers first. Replace
the protocol helpers' `Hash::MultiValue` header containers; do not add a legacy
container adapter or separate header caches. This does not change query/form
parameter containers. This choice was approved during the 2026-09-18 review.

Do not fabricate a WebSocket method: preserve `method` if supplied and otherwise
return `undef`. In particular, do not guess GET for HTTP/2 extended CONNECT.
Method predicates must remain safe when method is absent. Preserve `ws`/`wss`
as the WebSocket scheme and `http`/`https` as supplied for HTTP/SSE; update POD
that currently promises only HTTP scheme values.

### 6.2 Request bodies

The previous discussion assumed non-HTTP scopes might have no usable request
body. The current PAGI spec makes an important distinction:

| Scope | Request-body source |
| --- | --- |
| HTTP | `http.request` chunks and the HTTP disconnect semantics |
| SSE | `sse.request` chunks and SSE disconnect semantics |
| WebSocket | No HTTP request-body stream; receives handshake and WebSocket events |

Request's buffered and streaming body APIs must support SSE's real request
body. This includes `body`, derived text/JSON/form/upload methods, `body_stream`,
and `multipart_stream`. Preserve existing size limits, caching, partial-body
disconnect handling, and buffered-versus-streaming exclusivity.

Body readers may select the proper native event family internally. This must
not replace the receive channel supplied to a delegated native application.
Maintain the distinction between an empty body and a disconnected partial body.
SSE body readers recognize `sse.disconnect`, including the reasonless event
returned after a completed SSE refusal. After a completed WebSocket refusal,
receive returns `http.disconnect`; WebSocket Request body APIs nevertheless
reject access without consuming events. Do not silently interpret an unrelated
event as an empty body chunk.

On a WebSocket Request, every body-consuming API must fail clearly before
consuming receive events or setting body-consumption/cache flags. A missing
Content-Type or a cached-body fast path must not bypass this rule. In particular,
`websocket.connect` must not be consumed as a successful empty HTTP body.

This is a coherent Request contract, not additional policing of arbitrary apps:
a native app still receives the real protocol events and owns its use of them.

### 6.3 Adapter reuse

Broaden the existing RequestResponse application adapter to those same supported
scope types. Use that public adapter, or a shared implementation behind it, for
both routes and refusal callbacks. Do not write a second independent
Request-handler invocation loop in WebSocket or SSE.

The existing `request_response(..., request_factory => ...)` object can supply a
custom Request subclass and be passed as an ordinary app object. This design
does not add separate factory options to `deny` or `decline`.

## 7. Pages application support

Permit `PAGI::Pages::Application->to_app` on HTTP, WebSocket, and SSE scopes.
Each invocation still creates a fresh response using request metadata and the
configured Pages policy, then invokes it through public application machinery
against the original triplet.

Content negotiation, explicit representation choices, custom Pages rendering,
and request-local materialization remain intact. A refusal method does not
special-case Pages or call `response_for` on behalf of an arbitrary target.

`response_for` remains useful as an explicit, synchronous, no-send materializer.
It is not required merely to pass a Pages application to `deny` or `decline`.

For HTTP/WebSocket/SSE materialization, use the expanded Request support rather
than synthesizing an HTTP-typed metadata scope just to satisfy Request's old
constructor. Preserve the no-source-mutation guarantee: isolated metadata
copies for header-cache writes remain legitimate, but retain the real type and
values. Descriptor factories still observe the documented original source.

Both execution and explicit materialization support HTTP, WebSocket, and SSE
scopes. Reject unsupported scope types clearly. Existing metadata-only support
for custom request-like scopes is not a compatibility requirement and must not
retain HTTP-type coercion or introduce another adapter path. Custom-protocol
support would require a separate design.

## 8. Responsibility split and shared coordinator

### 8.1 Public invocation

Refusal execution uses Request-handler adaptation plus `to_app` / `invoke_app`.
WebSocket/SSE do not call Response private methods, inspect buffering, or infer
body capabilities from class identity. Response implementations may continue to
use their own private implementation methods inside their public `to_app` path.

### 8.2 Helper responsibilities

The protocol helper owns:

- checking that a refusal can still begin;
- owning the invoked asynchronous work until it settles;
- protocol-specific bookkeeping such as deferred SSE keepalive removal;
- delegating execution to shared machinery;
- existing connection-driven close callbacks and cleanup ownership.

### 8.3 Connection responsibilities

The public connection object owns response-start facts and clean/abnormal
terminal state. Application completion, a resolved send, or observer
cancellation must not manufacture a clean connection outcome.

Use its synchronous `response_started`, `is_connected`, and, where relevant,
`response_complete` facts. Existing `on_end` observation continues to trigger
helper close cleanup, including after the handler returns.

`response_started` can also mean WebSocket acceptance, SSE start, or a
server-generated response. It is sufficient to establish that the first-response
slot is no longer available; it must not be relabeled as proof that this app
sent a successful refusal.

### 8.4 Shared implementation

Centralize application adaptation, asynchronous ownership, and operation
settlement instead of duplicating the current lifecycle body in both helpers.
A small internal coordinator is acceptable; no new public lifecycle framework
or Response-specific interface is needed.

The implementation plan should identify each piece of state and its owner.
Avoid separate copies of connection facts. Retain the running operation for
its lifetime; this does not require arbitration of conflicting helper calls.

Do not introduce a configurable callback framework with many hooks just to
factor two functions. Protocol-specific admission and keepalive decisions can
remain in the helpers; common operation execution belongs in one place.

## 9. Required connection baseline

Refusal through `deny` or `decline` requires the current public
`pagi.connection` contract for every target,
including buffered Responses. Fail before calling user code if that capability
is missing or invalid. State the required capability and the advertised spec
version in the diagnostic where available; do not rely solely on a version
string as proof of capability.

The spec already requires the connection object on supported WebSocket/SSE
scopes. This choice removes refusal-only legacy branches and the need to inspect
Response buffering to decide whether a legacy path is safe.

Remove legacy branches affected by this redesign rather than carrying them into
the new coordinator. Constructor or accepted-connection paths may also change
where necessary for a coherent implementation; unrelated cleanup is not a
deliverable. Update manually constructed refusal fixtures to provide the
spec-defined connection object. Test-client doubles must update its facts at
send processing boundaries like a conforming server.

Old-server refusal support is not required. Do not hide a fallback emitter
inside the shared coordinator or retain a buffered-Response exception.

## 10. Lifecycle contract

### 10.1 Admission and caller sequencing

A refusal begins only before WebSocket acceptance or SSE start, with the
connection still active and its response slot unclaimed. Validate the target's
basic public shape and required connection capability before user execution.

Applications must sequence operations that answer the request and await the
chosen operation. Overlapping acceptance/start and refusal, repeated concurrent
refusals, and reentrant conflicting helper calls are unsupported; helpers need
not detect or arbitrate them. There is no promised winner, early helper error,
or recovery behavior. Existing inexpensive guards may reject misuse, but this
work must not add pending-accept/start flags or a concurrency state machine to
guarantee rejection in every ordering. This boundary was approved during the
2026-09-18 review.

Likewise, applications must not run competing receive consumers while delegating
the original receive channel. Already-running readers are caller responsibility;
do not add receive arbitration, cancellation, or event replay to manage them.

Normal admission checks and ownership of the invoked work remain required.
Operation retention supports asynchronous lifetime, not concurrent-call safety.

Native application code is not placed behind a new event whitelist. It can
misuse the protocol; the adapter neither certifies nor repairs it.

### 10.2 Progress without send interception

The target architecture uses public connection progress instead of wrapping send
to maintain a separate `$committed` flag. The delegated app receives the original
send channel. Server processing sets response progress before a successful
start-send continuation resumes.

Retain the operation while the app runs. If it finishes after a response has
started but before terminal observation, later sequential helper calls still
observe the claimed response slot through the connection facts. App return
does not reopen acceptance/start or refusal. Close callbacks use the connection,
not the app's return value.

If public connection semantics prove insufficient to implement this behavior,
produce a focused failing case and stop for design review. Do not silently
reintroduce send interception or a second terminal state machine.

### 10.3 Application failure

| Facts when the application fails | Required behavior |
| --- | --- |
| Connection active; no response started | Propagate the original error; settle operation bookkeeping so the caller can deliberately recover |
| Response started; connection still active | Propagate the error; never reopen acceptance/start or a second response |
| Connection terminal | Propagate genuine application errors; never restore an initial helper state |

Failure during object normalization, Request construction, handler execution,
or returned-app invocation follows the same rule. Do not catch errors merely
to produce a replacement page after a response has started.

SSE deferred keepalive survives a pre-start failure. Once a response starts,
it must not later arm a live SSE stream. Sequential helper entry points must
respect the connection's progress; concurrent misuse has the boundary in 10.1.

### 10.4 Application returns without a response

A structurally valid native app may return without sending anything. That is
application responsibility. If the connection is still active and no response
started, settle operation bookkeeping and return the helper without inventing
a refusal, clean completion, or replacement body. Normal outer server/app
completion policy still applies if the whole request returns without a response.

By contrast, a Request handler returning `undef` violates its documented return
contract and fails validation. These cases must not be conflated.

An app that sends a partial response and returns remains subject to the usual
PAGI incomplete-response rules. The refusal coordinator does not append a final
body event, drain a custom producer, or mark it complete.

### 10.5 Cancellation and retention

Return a cancellation-isolated observer for the refusal operation. Cancelling
that observer does not cancel the handler, native app, producer, or server-owned
send Future and does not release ownership of the work. This preserves the existing
refusal cancellation ownership rule.

Retain the operation independently until the invoked work settles, then release
its references. Retention must survive both caller-reference loss and an earlier
terminal connection notification.

Connection terminal notification still runs helper cleanup once. Streaming
Response cancellation/cleanup remains owned by Stream/Writer and their public
connection observation. An arbitrary application parked on unrelated work is
not automatically made cancellation-aware by this adapter. It owns that work
and can observe the connection itself. Do not add a competing receive watcher.

### 10.6 Repeated calls

Both methods use the same sequential-call admission rule: reject another
refusal after a response has started or after the connection ends. Rejection
does not invoke the target, emit events, or repeat cleanup.
There is no SSE-only idempotent success path after a completed refusal.

A later attempt is allowed only when the previous operation has settled, the
connection remains active, and no response has started, as described for
pre-start failures and no-output returns above. Cancellation of an observer
does not settle the owned operation or make a retry admissible.
Calling again while work is pending is unsupported concurrency under 10.1,
not a guaranteed helper rejection.

Validate argument shape consistently in both methods. Replace tests of the old
settled-call distinction with tests of this shared contract.

## 11. Normal protocol constraints

The server/spec continue to govern event validity. In particular:

- A WebSocket refusal uses ordinary HTTP response events before acceptance and
  requires a status of 300 or above.
- An SSE refusal uses ordinary HTTP response events before `sse.start`; its
  status may include 200 or 204.
- File/fh bodies, streaming bodies, and trailers follow ordinary HTTP response
  semantics and applicable extension requirements.
- Once a refusal starts, it cannot become a WebSocket or live SSE stream.

Do not add another response schema, capability marker, eager buffering pass, or
automatic status correction in `deny`/`decline`. The configured app controls
headers, content negotiation, body generation, and errors.

## 12. Expected simplification

The redesign removes:

- nominal Response checks;
- direct `_emit` calls from protocol helpers;
- refusal-side `is_buffered` and response capability checks;
- the need for callers to materialize Pages applications before delegation;
- duplicated Request-handler invocation code;
- refusal-specific legacy fallback emission and terminal inference;
- send interception solely to copy response-start state into local flags.

It retains the complexity that has a separate purpose:

- ownership of pending application work, including before response start;
- asynchronous operation ownership;
- recovery only before the response slot has been claimed;
- connection-authoritative terminal state and once-only cleanup;
- a small amount of protocol-specific state integration.

Success is not a line-count target. The review must be able to identify why each
remaining branch exists and verify that both helpers use the same public
application execution path. Moving the old emitter into a utility unchanged is
not sufficient.

## 13. Files and integration boundaries

Expected implementation areas, subject to the later plan:

- `lib/PAGI/WebSocket.pm`, `lib/PAGI/SSE.pm`: new target contract and thin refusal
  coordination using public connection facts.
- `lib/PAGI/Routing/RequestResponse.pm`: shared supported-scope handler adapter.
- `lib/PAGI/Request.pm`: supported scope metadata and protocol-aware body entry
  points.
- `lib/PAGI/Request/BodyStream.pm`, `lib/PAGI/Request/MultipartStream.pm`, or their
  shared input path: SSE request-body/disconnect semantics without duplication.
- `lib/PAGI/Pages/Application.pm`, `lib/PAGI/Pages.pm`: execute on supported
  refusal scopes and remove unnecessary HTTP-typed metadata coercion there.
- A narrowly scoped internal shared refusal coordinator if needed.
- Relevant protocol, Request, Pages, Routing, test-client, and integration tests.
- Public POD, Cookbook, `examples/`, and upgrading/release notes affected by the
  changed input and connection requirements.

Auth modules are not renamed, redesigned, or used to shape these interfaces.
Existing Auth outcome tests may run as regression coverage because those values
are Pages apps, but no auth-specific branch may enter the new implementation.

Keep library syntax compatible with the declared minimum Perl version. The
signature-based sketches in this document illustrate usage, not permission to
raise the library's minimum version.

## 14. Acceptance matrix

### 14.1 Application dispatch

Test both helpers with:

1. A synchronous Request handler returning a concrete Response.
2. An async Request handler returning a Pages application.
3. A Request handler returning a native three-argument app.
4. A direct concrete Response, including buffered, File, and Stream variants.
5. A direct Pages application with representation negotiation.
6. A custom object implementing only `to_app`, with no Response inheritance or
   `response_for`, `_emit`, or `is_buffered` methods.
7. A native app wrapped with `as_app_object`.
8. A custom Request factory through the public `request_response` app object.

Assert handler argument count/type, original scope identity/type, single
invocation/normalization, headers/body on the wire, and propagated errors. Reject
invalid input and result shapes before unintended event emission.

An object whose public app works but whose `_emit` would fail is a useful
regression proving the private interface is not invoked by refusal helpers.

### 14.2 Request and Pages

- Ordinary HTTP Request metadata and body semantics remain correct.
- Request and each protocol helper share a `PAGI::Headers` header cache in both
  access orders. Test mixed-case names, repeated values, and consistent public
  container type; update affected header documentation and examples.
- WebSocket metadata works with absent method and with ws/wss schemes; body APIs
  fail before receive, including streaming constructors and cached fast paths.
- SSE buffered, chunked, JSON, form, and streaming/multipart input use actual
  `sse.request` events; disconnect and partial-body behavior remain correct.
- No connect/body events are consumed merely to construct a Request or render
  Pages metadata.
- A returned native app receives the remaining original input, with no replay or
  protocol rewriting.
- Pages negotiation produces independent response values across repeated and
  concurrent requests without replacing the source scope type or corrupting its
  header cache.
- Unsupported execution and materialization scopes fail clearly without
  coercing their type to HTTP.

### 14.3 Operation lifetime and sequential recovery

- Async handler work remains owned while pending before its first send.
- Before-start failure on a live connection permits sequential recovery and
  preserves pending SSE keepalive.
- Failure after response start or connection end never restores the initial
  protocol state.
- Observer cancellation during handler work, start send, and body send does not
  cancel owned work or server sends; references are released after settlement.
- Connection completion and drop run close callbacks once, including asynchronous
  callbacks after handler return.
- App return without output and partial-output return have the documented
  delegation behavior; no fabricated terminal response is added.
- Missing/invalid connection capability fails for every target form, before
  handler or app execution.
- Both helpers reject sequential repeated refusal after response start and
  after termination; only settled, live, pre-start attempts permit retry.
- Tests do not require detection or arbitration of unsupported overlapping
  helper operations or competing receive consumers.

### 14.4 Public protocol and integration proof

Use spec-faithful doubles whose connection facts change during send processing.
Do not preserve invalid fixtures by reintroducing a send observer as a substitute
for correct connection behavior.

Run real HTTP/1.1 and HTTP/2 refusal cases where dependencies are available:

- a Pages application refused through each helper;
- a streamed refusal whose producer parks and whose client disconnects;
- original scope identity preserved through handler/app execution;
- no WebSocket acceptance or SSE start for ordinary refusal examples;
- once-only producer/Writer/helper cleanup and uncancelled server sends;
- at least one SSE request-body refusal through a Request handler.

Preserve the existing close-truthfulness integration coverage. These changes
must not weaken the accepted WebSocket closing-handshake behavior or duplicate
terminal cleanup.

The later implementation plan must name exact commands and record executed
versus skipped transport tests. A full green Tools suite is required before
claiming implementation completion; tests of this draft have not been run.

## 15. Migration and documentation

Existing concrete Response arguments remain valid because they already provide
`to_app`. Explicit `$page->response_for($source)` remains legal but is no longer
required for these supported protocol boundaries.

Document the CODE-position distinction with examples: a direct coderef is a
Request handler; `as_app_object` explicitly selects the native triplet form;
a coderef returned by a Request handler is already a native application value.

Document the deliberate requirement for the universal connection capability,
including its impact on old servers and manually constructed test helpers.
Document the shared repeated-call rule and supported materialization scopes.
Replace superseded tests and examples with the new contract; no compatibility
mode, deprecated alias, or staged migration is required.

Update both methods' POD to describe application delegation, not concrete
response emission. State that arbitrary application compatibility and behavior
belong to the application. Explain Request's SSE body support and WebSocket body
restriction without suggesting that its scope has become HTTP.

### 15.1 Required usage examples

The six usage mockups reviewed with the user are documentation requirements,
not merely design illustrations. The documentation for both `deny` and
`decline` must teach all of these forms:

1. A direct concrete Response, showing text and JSON responses.
2. A synchronous one-Request handler building a response from request metadata,
   including reuse of the same handler in either protocol endpoint.
3. An async one-Request handler awaiting an application-owned service before
   returning its response; explain awaiting the operation and its work ownership.
4. A Pages application passed directly and returned by a handler, explaining
   content negotiation without requiring `response_for`.
5. A custom application object implementing `to_app` without toolkit inheritance,
   with a complete minimal class definition and a call-site example.
6. A native three-argument async application wrapped with `as_app_object`,
   showing ordinary `http.response.start` and `http.response.body` events.

Each method's POD must show its basic response and Request-handler usage and
directly link to the remaining examples in a maintained shared guide or
Cookbook section. All six forms must be discoverable from either method's
documentation; a link to this design document is not sufficient. The shared
examples must show both `deny` and `decline` call sites and make clear that they
are alternatives on separate requests, not sequential refusals on one request.

Include imports and async/signature prerequisites, mark application-owned
services as illustrative, and show endpoint control flow ending after refusal.
Explain the direct-coderef versus returned-native-coderef distinction, original
scope preservation, the connection requirement, repeated-call behavior, and
the WebSocket/SSE status distinction alongside the examples. No example may
use `_emit` or depend on the proposed Auth redesign.

The implementation's documentation review must account for all six examples
and verify their syntax and API usage against the implemented public contract.

Audit `examples/` and maintained docs for refusal snippets, old `_emit` guidance,
Response-only restrictions, and unnecessary mandatory materialization. Keep
historical plans as historical records; do not rewrite them to imply they
specified the new contract.

## 16. Stop conditions and review questions

Stop and discuss before implementation adds any of the following:

- scope-type spoofing to run a handler or an application;
- a private emission interface between protocol helpers and response objects;
- a new protocol event bridge or competing receive watcher;
- a second source of clean/abnormal terminal facts;
- application-content inspection, capability certification, or a Response-class
  whitelist for native delegation;
- a hidden old-server fallback with different refusal semantics;
- server/spec changes merely to accommodate a Tools implementation shortcut;
- new Auth APIs or a rename of current Auth modules.

Backward compatibility has been explicitly waived. The current connection
baseline and removal of legacy refusal paths do not need another compatibility
decision before planning.

Review the supporting Request contract carefully: handlers on SSE support its
actual request body; WebSocket Request body APIs fail before consuming protocol
events. This is broader than merely removing the constructor's type check.

The public handler/application shape is not blocked on choosing an internal
coordinator class name. That choice belongs in the implementation plan once the
contract is approved.

## 17. References and verification status

- Local normative reference: `../PAGI/lib/PAGI/Spec/Www.pod`, sections Connection
  State, Meaning per scope, Refusing the handshake, SSE Request Body, and
  Refusing the stream, observed at `9aebdbc`.
- [Previous Plan C](../plans/2026-09-08-universal-connection-C-pagi-tools.md),
  especially task C4, records the Response-only/private-emitter design being
  replaced.
- [Completed continuation handoff](../plans/2026-09-17-tools-auth-continuation-complete-handoff.md)
  records the lifecycle behavior and integration proof to preserve.
- [Auth design snapshot](2026-09-17-authentication-backends-and-context-design.md)
  remains separate and is not an implementation prerequisite.
- Current source: `PAGI::Routing::RequestResponse`, `PAGI::Utils`,
  `PAGI::Pages::Application`, `PAGI::Request`, `PAGI::WebSocket`, and `PAGI::SSE`.

This document captures the requested redesign and proposed supporting contract.
Its source assumptions and internal consistency were checked while drafting.
No implementation, server change, runtime test claim, push, or release follows
from writing it. User review is required before producing the execution plan.
