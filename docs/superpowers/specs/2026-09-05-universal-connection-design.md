# Universal connection state: design

Date: 2026-09-08 (revision 4: adds 4.7, D12 and D13; supersedes revision 3 of 2026-09-07)
Status: for John's review. Nothing implemented.
Repositories: PAGI (spec), PAGI-Server (reference), PAGI-Tools (framework).
Working notes: `.pagi-unstick-ledger.md` (decisions D1-D13, questions Q1-Q6),
`.pagi-server-protocol-disconnect-findings.md` (measured server matrix),
`.pagi-option-a-mockup.md`, `.pagi-sse-shape-debate.md`,
`.pagi-liveness-ideas-survey.md`.

Work map at the time of writing (reconfirm before implementation):

| repo | branch | HEAD | this document changes |
|---|---|---|---|
| PAGI-Tools | `feature/authentication-outcomes-phase1` | `2733ba2` | nothing yet; this file only |
| PAGI | `main` | `d6f7736` (0.002008) | nothing yet |
| PAGI-Server | `main` | `9cc69a7` (0.002013) | nothing yet |

## 1. Goal

Unblock PAGI-Tools Auth Phase 1, which is paused because a framework
streaming response used in a WebSocket denial or SSE decline cannot observe
a client disconnect and therefore cannot terminate its producer or run
cleanup (`.pagi-auth-phase1-protocol-disconnect-gap.md`). "Unblocked" means:

1. `PAGI::WebSocket->deny($stream)` and `PAGI::SSE->decline($stream)` with a
   `PAGI::Response::Stream` whose producer waits on non-send work terminate
   the producer, run Writer and protocol cleanup exactly once, and resolve
   when the client drops mid-body, on HTTP/1.1 and HTTP/2, with scope
   fixtures that are legal under the spec.
2. Tools Task 5 (`t/auth/04-protocol-integration.t`) can be written without
   injecting `pagi.connection` into a scope the spec says cannot carry one.
3. The fix is contract-level: no second receive loop, no send interception,
   no cancellation of server-owned I/O, no fixture that lies about the scope.

## 2. Non-goals

- Removing or reshaping the `sse` scope. That is a separate job with its own
  ecosystem preparation (D8 deferred); the debate record and candidate
  designs are in `.pagi-sse-shape-debate.md`. This document does not depend
  on its outcome.
- Fixing the SSE Accept-detection problem (G4: a request carrying
  `text/event-stream` alongside other media ranges, as htmx 4 sends on every
  request, is classified `sse` and an http-only app returns 500). Ruled a
  known issue until the SSE job (Q5).
- Per-request deadlines, response lifecycle hooks, detached background work
  (`.pagi-liveness-ideas-survey.md` items 3, 6, 7).
- Any change to established-WebSocket message semantics or to
  `websocket.keepalive`.

## 3. The problem

Sends settle successfully whether or not the peer is there, by design, so
they carry no disconnect signal. `pagi.connection` exists so an app can
observe a disconnect without consuming the receive queue, but the spec marks
it NOT APPLICABLE to `websocket` and `sse` scopes. Their disconnect events
live on a queue owned by the protocol handler: a response object or
middleware that reads it steals `websocket.connect`, messages, or the
disconnect itself, and after a normally completed denial or decline no event
is delivered, so a receive-based watcher has no terminal condition and must
abandon live I/O to finish. Measured: on HTTP/1.1 the reference server also
delivers `http.disconnect` on a pre-accept websocket scope (S1). There is no
correct portable program inside the present contract.

## 4. Spec changes (PAGI, `PAGI::Spec::Www` unless noted)

### 4.1 Connection State becomes universal (D1, D2)

**Structure.** The Connection State section moves out of the HTTP chapter to
a top-level chapter after Common Data Types and before HTTP. Its subsections
move intact, with the edits below: The Problem (generalized to name the
`websocket.connect` and `sse.request` events a queue check would consume),
Connection Object Interface, What "connection" means here, Standard
Disconnect Reasons, Server Requirements, State Transition Order, and the
example. The Applicability subsection and the 0.3 rationale that handler
objects manage their own state are deleted. HTTP-chapter cross-references
become links.

**Rule.** Servers MUST provide `pagi.connection` on every `http`,
`websocket`, and `sse` scope: one object per scope instance (per request,
per WebSocket session including its handshake, per SSE stream), never shared
across keep-alive requests or HTTP/2 streams. Servers MUST implement all of
`is_connected`, `disconnect_reason`, `on_disconnect`, `on_complete`,
`disconnect_future` (a fresh, cancellation-isolated observer per call),
`response_started`, `response_complete`, `disconnect_detail` (new, below),
and `abort` (4.2). This promotes
`on_complete`, `response_complete`, and `disconnect_future` from SHOULD to
MUST; frameworks may rely on them unconditionally.

**Meaning per scope.** Abnormal end is one rule for every scope: any
condition in Standard Disconnect Reasons fires `on_disconnect` with that
token and sets `disconnect_reason`. Clean and abnormal end are mutually
exclusive; first wins; terminal state never reopens; `is_connected` is false
after either; `response_complete` is true only after a clean end;
`disconnect_reason` is undef after a clean end.

| scope | `response_started` | clean end: `response_complete`, `on_complete` |
|---|---|---|
| http | server accepts a valid `http.response.start` | server finishes its output of the terminal body, `file`/`fh`, or final trailers without an abnormal end |
| websocket | server accepts a valid `websocket.accept` or an `http.response.start` refusing the handshake | server finishes its output of the refusal, or the accepted socket completes a closing handshake initiated by either side and the transport (the stream on HTTP/2) closes without an abnormal end. The application's terminal act is sending `websocket.close` or receiving `websocket.disconnect`; returning with neither is incomplete (4.7) |
| sse | server accepts a valid `sse.start` or an `http.response.start` refusing the stream | server finishes its output of the refusal, or of a started stream ended by `sse.close`. Returning after `sse.start` without `sse.close` is incomplete (4.7) |

`response_started` reports server acceptance of the start event, not that
headers reached the wire; it is also set for server-generated responses.
Completion means the server finished its output processing, not that the
client received anything; a resolved terminal send is not by itself proof
of completion, since the Send Completion Contract also covers post-close
discard. Receiving a peer Close frame advances the closing handshake; it
does not alone establish a clean end. A completed handshake is clean
regardless of the peer's close code; that code and its reason text remain
protocol data delivered in `websocket.disconnect`. A server-detected
protocol violation, timeout, or transport loss before a clean end is
abnormal with the applicable standard token.

**Ordering.** The 0.4 State Transition Order applies to all three scopes:
the state transition precedes settlement of any pending send or receive, so
await-then-check is race-free everywhere, and `on_disconnect` and
`disconnect_future` delivery is never synchronous inside the app's own
`$send` or `$receive` call. The existing exceptions stand: a callback
registered after the terminal transition is invoked immediately under the
caller's control, and `on_complete` may run inside a terminal send.

**Completion and retention.** Exactly one terminal callback family fires.
`on_complete` registered after a clean end invokes immediately; it never
invokes after an abnormal end, and `on_disconnect` never invokes after a
clean one. The server releases both families' callback references after
terminal delivery and isolates callback exceptions. `disconnect_future`
resolves only on abnormal end; cancelling one returned observer affects
neither another observer nor server I/O. A consumer that must act on either
outcome registers both families. A clean end leaves no watcher or timer
behind.

The callbacks are how the end of a scope is observed by anything that is not
the scope's own receive loop: audit, metrics, subscription cleanup, a
framework's `on_close`. They fire on every terminal outcome including a
completed refusal and an `abort`. An accepted-socket receive loop needs no
extra handling, because `websocket.disconnect` arrives on every ending; an
affirmative `is_connected` check in the loop condition is a readability
preference the spec neither requires nor discourages. The upgrading guide
shows both, and Tools' handler objects register the callbacks on the
application's behalf.

**Agreement with disconnect events.** Where a scope delivers a disconnect
receive event for a server-reported abnormal end, its `reason` and the
object's `disconnect_reason` MUST be the same token. This does not apply to
the peer's free-text reason from a Close frame, which is protocol data and
is not overwritten. The events themselves are unchanged, including "no
`websocket.disconnect` after a completed denial" and "no `sse.disconnect`
after a completed decline." What a receive() call returns after a completed
denial or decline stays unspecified (G2, D6); frameworks observe
`on_complete`.

**Detail.** `on_disconnect` callbacks receive `($reason, $detail)` and a
new accessor `disconnect_detail` returns the same string after the fact.
`$detail` is free text of unspecified format, may be undef, and is
diagnostic only: never on the wire, never in a client-visible response,
never a branching key. Servers MUST NOT require applications to parse it;
anything an application needs to branch on is a token. It MUST NOT contain
request bodies, headers, credentials, or the peer's Close-frame text, which
stays in the event. Servers SHOULD supply it when they know more than the
token says: the violated rule for `protocol_error`, the OS or TLS error for
`write_error`/`read_error`/`write_timeout`, the elapsed interval for
`keepalive_timeout`/`idle_timeout`, the limit for `body_too_large`/
`queue_overflow`, the RST_STREAM code for an HTTP/2 `client_closed`, the
exception message for `server_error`, and the application's string for
`app_abort`. Callbacks that ignore the second argument are unaffected.

**No response and incomplete.** Returning from a websocket scope without
accept or denial, or from an sse scope without start or decline, is
"Application Produced No Response" with its existing client-gone carve-out.
Returning after a valid start without the scope's terminal event is an
incomplete response under the existing rules, on every scope, refusals
included; 4.7 names the terminal event per scope. (Revision 3 exempted a
started SSE stream; D12 withdraws that.)

### 4.2 `abort` (D9, Q4)

`$conn->abort($detail)` is a synchronous teardown request with no meaningful
return value. It immediately marks a still-active scope abnormal with the
new standard token `app_abort` and initiates closing the connection on
HTTP/1.1 or resetting only that stream on HTTP/2. It MUST NOT wait for an
in-flight write to drain; that write may be blocked by the peer. The server
then follows 4.1's State Transition Order exactly as for a transport-detected
abnormal end: marks the scope abnormal, resolves `disconnect_future`, invokes
`on_disconnect`, then settles pending receives with the applicable disconnect
event and pending sends successfully; releases or discards pending output and
application-owned resources; does not fire `on_complete`; treats later sends
as post-close no-ops; and does not log an incomplete-response or no-response
error. `$detail` is
an optional string delivered as the `disconnect_detail` (4.1) for this end;
it never reaches the wire and is not an application-selected reason token. `abort` after either terminal
outcome is a no-op that preserves that outcome. It is valid on every scope,
before or after accept or start. `app_abort` is added to Standard Disconnect
Reasons: "the application ended the connection deliberately."

### 4.3 Refusing a handshake or a stream is an ordinary HTTP response (D3, D4, D5, D11)

**One rule, stated once, in the Connection State chapter.** Until the
application accepts a WebSocket (`websocket.accept`) or starts an SSE stream
(`sse.start`), the scope is an HTTP exchange, and the application MAY answer
it with an ordinary HTTP response using the HTTP response events
`http.response.start` and `http.response.body` (and `http.response.trailers`
where the start declared them), with exactly the semantics those events have
on an `http` scope. This is the single exception to the rule that a scope
carries only its own namespace's events; it exists because the wire really
is HTTP until 101 or the first event-stream byte. On the wire a refusal's
status, headers, and body are identical to the same response on an `http`
scope, apart from the connection-lifecycle headers the server owns.

**Consequences.**

- `websocket.http.response.start`/`.body` and `sse.http.response.start`/`.body`
  are removed, along with the `websocket.http.response` extension entry.
  Every server offering `websocket` or `sse` scopes MUST accept the HTTP
  response events before accept or start (D4). No feature detection.
- Body semantics are inherited, not restated (D3): a first body with
  `more => 0` is a complete body the server may frame with Content-Length;
  `more => 1` streams under the transport's ordinary rules; `file`, `fh`,
  and trailers are allowed because they are allowed on HTTP responses.
  Nothing is buffered specially. The reference server's refusal paths become
  the ordinary HTTP response paths.
- The spec note that goes with streaming a refusal: the status and headers
  commit with the first body event; a refusal abandoned after start without
  its terminal body is an incomplete response under the existing rules, with
  the client-gone carve-out; and as with any streamed body, a client that
  disconnects mid-stream may have received part of it. Prefer a complete
  body for a refusal.
- `websocket.close` before accept is an out-of-sequence send and MUST fail
  without mutating state; the bare-403 behaviour is removed (D5). Accept and
  HTTP-refusal start are the only WebSocket handshake choices and are
  mutually exclusive; `sse.start` and HTTP-refusal start likewise for SSE.
  After an HTTP-refusal start, only HTTP response events are valid until the
  terminal one; after accept or `sse.start`, HTTP response events fail.
- A normally completed refusal is a clean end (4.1) with no
  `websocket.disconnect` or `sse.disconnect` event, as today.
- After a completed refusal the server closes the connection on HTTP/1.1
  (the response carries `Connection: close`) and ends the stream on HTTP/2,
  as 0.5 did; keep-alive after a refusal is not offered (ruling D-A-I10).
- `websocket.disconnect` is delivered whenever a websocket scope ends
  abnormally, before or after accept; a completed refusal delivers none. An
  `abort` on an accepted socket sends no Close frame and delivers the event
  with code 1006 and reason `app_abort` (ruling D-A-I6).

### 4.4 `sse.disconnect` wording (G3)

Corrected: sent when the client disconnects at any point after dispatch,
before or after `sse.start`, and when the server shuts down a started
stream; a normally completed refusal delivers none. The `sse` scope itself
is otherwise unchanged by this document (D8 deferred).

### 4.5 Upgrading guide

New document `lib/PAGI/Upgrading.pod` (`PAGI::Upgrading`) in the PAGI dist,
indexed from `PAGI.pm`'s document list beside `PAGI::PSGI` and
`PAGI::Building`. Organized by sub-spec version, newest first, and within a
version by audience. The 0.6 section for this change:

- **Application authors (raw spec).** `pagi.connection` is now on websocket
  and sse scopes: race `disconnect_future`, stop using receive-queue
  watchers, drop `without_cancel` on those races. `abort` exists. Refusing a WebSocket handshake or an SSE request is an ordinary HTTP
  response: send `http.response.start`/`.body` on the scope before accept or
  start; the `websocket.http.response.*` and `sse.http.response.*` events and
  the `extensions` check are gone, and `websocket.close` before accept now
  fails. Refusal bodies stream when `more => 1`; finish them or watch the
  object; a refusal you abandon is an incomplete response. `sse.disconnect` can arrive before `sse.start`.
- **Framework authors.** Handler objects may consult the object instead of
  duplicating state; a streaming response helper races the object, never
  the queue; on caller cancellation call `abort`; log `disconnect_detail` alongside the token; drop denial capability
  detection, bare-403 fallbacks, and any http-to-protocol event renaming
  bridge; middleware that can refuse a request needs exactly one arm.
- **Server implementers.** Attach the object to every scope; all seven
  methods plus `abort`; `app_abort` token; the meaning-per-scope table;
  reason agreement with disconnect events; HTTP response events accepted on
  websocket and sse scopes before accept or start, through the ordinary HTTP
  response paths; the protocol-prefixed response events and the `extensions`
  entry removed; `websocket.close` pre-accept fails; the ported conformance
  matrix.
- **Known issue.** G4, with the spec's own stated correction path (decline)
  and a pointer to the SSE job.

Each bullet becomes a short before/after code pair, reusing the mockup's
verified programs. The guide ships in the same PAGI release as the POD
changes; it is a release blocker, not a follow-up.

### 4.7 Terminal events on every scope (D12, D13)

Every scope has exactly one way to end cleanly from the application's side,
and it is an explicit event: the terminal body or trailers after
`http.response.start` (on any scope, refusals included); `sse.close` after
`sse.start`; `websocket.close` sent, or `websocket.disconnect` received,
after `websocket.accept`. Returning without it is governed by Application
Left a Response Incomplete: the server MUST NOT synthesize the terminal
framing, MUST terminate so the client observes truncation, fires
`on_disconnect` with `server_error`, does not fire `on_complete`, and logs
at error level, with the existing client-gone carve-out.

Per scope:

- **SSE (D12).** The "return after the final `sse.send`" idiom is removed;
  `sse.close` keeps its semantics (immediate, idempotent, further sends
  raise, server-side `reason`). A return without it leaves the stream with
  unfinished framing exactly like an HTTP body: no chunk terminator on
  HTTP/1.1, `RST_STREAM INTERNAL_ERROR` on HTTP/2. An `EventSource` client
  reconnects either way, so the rule exists for the server log, the
  connection object, and intermediaries: a helper that returned early (a
  swallowed exception, a `last` that skipped the close) is reported as
  incomplete rather than as a completed stream.
- **WebSocket (D13).** Returning from an accepted socket without a completed
  closing handshake is incomplete. The server sends a Close frame with code
  1011 ("internal error"), waits no longer than its ordinary close timeout
  for the peer's Close, closes the transport (the stream on HTTP/2), reports
  `server_error`, and delivers `websocket.disconnect` with code 1011 and
  reason `server_error`. 1011 rather than 1006: 1006 is a client-synthesized
  code an endpoint MUST NOT send (RFC 6455 section 7.4.1), and the platforms
  that produce it (uvicorn, axum, ASP.NET Core, gorilla) have no policy for
  this case at all; Hypercorn, Daphne, and Starlette use 1011 for the
  application-failure case; 1011 is the WebSocket analog of the
  `RST_STREAM INTERNAL_ERROR` the incomplete-response section already
  prescribes. A peer-initiated handshake is completed by the server, so
  receiving the disconnect event is the application's whole obligation in
  that case. The reference server today closes the transport with no Close
  frame and reports a clean end (`session_complete`) while the client sees
  1006; that inconsistency is what D13 removes.

Rationale (John, 2026-09-08): raw PAGI is an interface language, not an
application language, and should carry no ambiguity; the fix for hand-rolled
applications is one line; frameworks (PAGI::SSE, PAGI::WebSocket) send the
terminal event on the handler's behalf; a uniform rule prepares the later
SSE-as-HTTP migration, where the terminal event becomes the final
`http.response.body`.

Tools consequence: `PAGI::SSE` sends `sse.close` when a handler returns from
a started stream, and `PAGI::WebSocket` sends `websocket.close` 1000 when a
handler returns from an accepted socket without a closing handshake, so
applications built on them keep the shorter form. The Tutorial's SSE
examples also move to the `sse.start`/`sse.send` event names (they carried
the pre-0.2 `sse.response.*` names).

### 4.8 Refusal status boundary and normative close-code pairings (John's PR review, 2026-09-08)

A WebSocket refusal's `http.response.start` status MUST be 300 or above: 101
is the HTTP/1.1 acceptance and any 2xx to the HTTP/2 CONNECT opens the tunnel
(RFC 8441 section 5), so a 1xx/2xx start on a websocket scope fails without
transmitting or mutating state, on both transports. SSE refusals keep every
status, 200 included, because an sse scope is distinguished from a stream by
the answering event, not the status, and a 200 page is the G4 correction
path. The `websocket.disconnect` code/reason pairings are normative where
the server names the ending; a peer's Close-frame code and text are never
replaced by a token. The bundled SSE examples (05 broadcaster, 11 job runner)
end finite streams with `sse.close`; the job runner refuses bad requests
with HTTP responses and observes the end of the stream through
`pagi.connection` rather than a receive loop.

### 4.6 Version bump and history

The HTTP/WebSocket/SSE sub-spec moves from 0.5 to **0.6**. 0.5 has shipped
(PAGI 0.002008, 2026-09-01; PAGI-Server reports `'0.5'`), and these are new
requirements, not clarifications, so `` becomes
`'0.6'` on `http`, `websocket`, and `sse` scopes once a server implements
them. Frameworks gate on it: a scope reporting 0.6 or later carries
`pagi.connection` unconditionally; below that, Tools keeps its existing
HTTP-only polyfill path and refuses Stream through `deny`/`decline` rather
than hanging. `PAGI::Upgrading` keys its section to 0.6 for the same reason.
The core `PAGI::Spec` version is unchanged; the object is defined in Www.

`PAGI::Spec::Www` 0.6 history entry: `pagi.connection` universal, all
methods required; `abort` and `app_abort`; refusals before accept or start use the HTTP
response events, the `websocket.http.response.*` and `sse.http.response.*`
events and the extension entry removed, `websocket.close` before accept
fails;
Applicability removed; `sse.disconnect` wording; `sse.close` and the WebSocket
closing handshake required as terminal events, WebSocket closed with 1011
(4.7). Both the Spec Versions list
at the top of Www.pod and the Version History at the bottom get the entry.
The dist `Changes` entry mirrors the 0.002008 pattern: "sub-spec 0.5 -> 0.6,
new requirements, `spec_version` moves." G4 is recorded as a known issue.

## 5. Reference server (PAGI-Server)

Implement: attach per-scope connection state to websocket and sse scopes on
both transports (the code skips them today with a "per spec" comment, so
the plumbing exists) and drive its transitions from the sites that queue
disconnect events and finish clean responses; all methods with 4.1's
per-scope meaning; `disconnect_detail` populated per the SHOULD list in 4.1 at
each detection site; `abort` on both transports via teardown that releases
pending I/O without draining; accept `http.response.*` on websocket
scopes before accept and on sse scopes before `sse.start`, routed through the
ordinary HTTP response paths (the two tests asserting buffered denial/decline
are reversed; the protocol-prefixed event validators and the extension
advertisement are removed); fail `websocket.close` before accept. Per 4.7:
an application return after `sse.start` without `sse.close` is an incomplete
response (no end-of-stream marker, `stream_complete` no longer applies); an
application return from an accepted WebSocket without a closing handshake
sends Close 1011, reports `server_error`, logs, and delivers
`websocket.disconnect` 1011/`server_error` instead of `session_complete`.

Fix as conformance bugs: S1 (h1 pre-accept disconnect delivers
`http.disconnect`), S2 (h1 receive after completed denial gets a
disconnect), S3 (h2 completed decline delivers `sse.disconnect`), S4 (h2
socket close reports empty reason), S5 (h2 spurious no-response log after
client gone), S7 (h1 http receive after complete parks). Keep the S6
retention regression even though frameworks no longer need a watcher.

Lifecycle state (added 2026-09-09, John: "we need to clean up"): the server
keeps one lifecycle state per scope, the `EventValidator` state machine
mirrored into `h1_seq` / `seq_state` for websocket and sse as it already is
for http, read through `scope_started` / `scope_send_clean`; the
hand-maintained flags (`websocket_accepted`, `ws_accepted`, `ws_close_clean`,
`ws_refusal_completed`, `sse_started`, `sse_close_sent`, `sse_clean_end`,
`sse_decline_completed`, `websocket_mode`, `sse_mode`) are removed. Only
receive-side close, transport liveness, the termination reason, and the
terminator latch remain separate fields. Rationale: B2's three bugs were all
a boolean one site set and another read at the wrong moment; the reviewer's
audit (task-B2-rereview.md Part 4) found eight of twenty flags duplicated
validator states.

Conformance tests: port the 19-cell matrix probe
(`.pagi-server-protocol-disconnect-matrix-probe.pl`) and the retention probe
(`.pagi-server-denial-retention-probe.pl`) into `t/`; add `abort` on both
transports before and after accept, including a blocked send released
without cancelling its Future; assert object/event reason agreement for
server-reported abnormal ends and that peer Close reason text stays peer
data; cover start pending, body pending, producer waiting on non-send work,
normal completion, late callback registration, cancellation of one observer,
HTTP/2 sibling-stream isolation, and release of callbacks and timers on both
terminal outcomes; cover a streamed refusal with a mid-body drop on both
transports, a `file` refusal, and the four invalid orderings (HTTP events
after accept or `sse.start`; protocol events after an HTTP-refusal start).

## 6. PAGI-Tools

- `PAGI::Test::Client`, `PAGI::Test::ConnectionState`: every scope fixture
  carries a connection object modelling deferred notification, immutable
  terminal state, per-call cancellation isolation, and `abort`; the
  WebSocket helper drops the extension advertisement and the bare-403 path;
  completion methods are mandatory.
- `PAGI::WebSocket`: `deny($response)` emits the Response directly on the
  scope; drop `supports_denial_response` and the `websocket.close` fallback;
  the `denying` state machine is unchanged; document the helper's removal.
- `PAGI::SSE`: `decline($response)` likewise; public shape unchanged. Per 4.7,
  when a handler returns from a started stream without `sse.close`, the
  helper sends `sse.close`; `PAGI::WebSocket` sends `websocket.close` 1000
  when a handler returns from an accepted socket with no closing handshake.
- Design rule for `deny` and `decline`: the safe thing is easy, the risky
  thing is guarded. Buffered Responses (Problem, HTML, Text, JSON, the Auth
  and Pages values) are the default and cannot be abandoned mid-body.
  `PAGI::Response::Stream` remains accepted and is the only streaming path
  through these methods. Stream owns
  the discipline the spec note in 4.3 warns about: it observes the
  disconnect through the connection object, stops the producer, and on
  producer failure or caller cancel calls `abort` so the wire never shows a
  silently abandoned denial. The `deny`/`decline` POD says to prefer a
  finite Response for a rejection and explains what streaming one commits
  you to.
- `PAGI::Response::_respond_for_protocol` and the `body-events-v1` protocol
  capability: deleted. There is nothing to rename. `deny` and `decline` call
  `$response->_emit($scope, $receive, $send)`; with `pagi.connection` present,
  Stream's Writer builds its disconnect signal from it. `PAGI::Response::File`
  becomes a valid refusal.
- `PAGI::Response::Stream` and `PAGI::Response::Writer`: on a `websocket` or
  `sse` scope whose `spec_version` is below 0.6, or that carries no
  `pagi.connection`, `deny`/`decline` refuse Stream synchronously with a
  message naming the server version, rather than proceeding into the hang.
  On `http` scopes behaviour is unchanged. This is the only place Tools
  reads `spec_version`.
- `PAGI::Response::Stream`: on `caller_cancelled`, call `$conn->abort`.
  Cancellation must be observable while start or body send is pending, not
  only once the producer race is reached; retain and await the server send
  until teardown settles it; never cancel that Future; producer cancellation
  and cleanup exactly once.
- Replace the illegal fixtures (`t/websocket/denial-response.t:417`,
  `t/sse/13-decline.t:415`) and rewrite Task 5's disconnect subtest with
  legal scopes. Task 5 is accepted when it passes against the Test Client and
  against PAGI-Server with section 5 applied.
- Acceptance, carried from the handoff: legal scopes; abnormal disconnect
  while start or body is pending; sends never cancelled or rewritten;
  disconnect observed without consuming a queue event; a producer on
  non-send work stopped per Stream policy; Writer and protocol cleanup
  exactly once; failed start retryable; settled start owns the slot; normal
  completion retains no watcher; buffered Pages/Auth responses unchanged;
  File accepted as a refusal; docs separate server settlement, local slot
  commitment, wire progress, and clean completion.

## 7. Sequence

1. John reviews this document.
2. PAGI: POD diffs for section 4 including `PAGI::Upgrading`, reviewed before
   merge, on a branch.
3. PAGI-Server: section 5 with the ported conformance tests, on a branch.
4. PAGI-Tools: section 6; resume Auth Phase 1 at Task 5.
5. A tracking file with one row per task, commit SHAs, and real test counts
   from step 2 onward; deviations get an ID and sign-off before anything is
   built on them.

## 8. Deferred

- D8 / Q1: SSE over HTTP (Option A) or a typed payload (Shape 2), the
  heartbeat contract's record-boundary and encoding rules, and the migration
  and compatibility-shim work. Separate job after ecosystem preparation.
- G4: SSE Accept-detection misclassification. Known issue until then.
- Document location: stays in PAGI-Tools with the ledger; moving it to PAGI
  is a later step.
