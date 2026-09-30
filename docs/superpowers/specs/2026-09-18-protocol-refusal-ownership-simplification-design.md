# Ordinary awaited protocol refusals

Date: 2026-09-18

Status: approved direction from the follow-up discussion; implementation pending.

## Authority and objective

This is a focused amendment to
[the application-refusal design](2026-09-18-protocol-refusal-applications-design.md).
It supersedes that document's detached operation ownership, cancellation-isolated
refusal observer, and temporary refusal-state bookkeeping in sections 8,
10.1–10.6, 12, and 14.3. Its public target grammar, original scope/channels,
connection requirement, Request/Pages behavior, and six examples remain binding.
The previous implementation/handoff remain historical records of what shipped
on the working branch before this amendment.

The user approved ordinary awaited refusal operations: cancellation may reach
the invoked application; the refusal layer no longer forces abandoned work to
continue. The user also approved shielding buffered Response sends at the send
boundary, where cancelling a server-owned send is currently possible.

## Intended shape

`deny($target)` and `decline($target)` are async methods that validate admission,
adapt a bare Request handler with the existing RequestResponse adapter, await
`invoke_app` on the original triplet, and return the helper on success.
An exception becomes a failed Future through ordinary async behavior.

Neither method creates a detached worker, retains itself, installs an
operation-settlement callback, or returns a refusal-specific cancellation shield.
Neither changes helper state merely because a refusal was invoked. There is
no temporary state to roll back on failure or no-output return.

The former `PAGI::Utils::_Refusal` module is removed. As requested by the user, small shared preparation
lives in `PAGI::Common`: `require_connection($scope, $label)`
checks the existing required public capabilities; `prepare_refusal($scope, $label,
@targets)` validates the single target and live/unclaimed response slot, then
returns the adapted application value. It neither invokes the application nor
accesses helper internals. The actual await is visible in each helper method.
These are shared implementation functions, called by fully qualified name rather
than exported as user utilities. Do not move unrelated utilities in this change.

## State and admission

Public connection facts determine whether a first response is still possible:
`is_connected` must be true and `response_started` false. Validate capability
and target shape before calling a Request factory, handler, or `to_app` method.

Remove stored `denying`/`declining` phases and `_denied`/`_declined` history.
`connection_state` continues to describe helper protocol progress and terminal
state; its initial `connecting`/`pending` value is not a promise that an HTTP
response slot is available. Retire the two refusal phase values from its POD.

For sequential helper operations, an initial-phase helper whose connection
already reports response start cannot start its protocol. A small derived
predicate may read these facts; it must not write a refusal flag or claim to
identify which application emitted the response. Accepted/started streams must
not be mistaken for refused requests merely because `response_started` is true.

Preserve no-wire-output behavior of `accept`/`start` after another response.
Prevent SSE auto-start paths, `run`, and deferred keepalive from starting SSE
after that response. Check each calling path, rather than assuming a no-op
`start` prevents a following `sse.send`. Existing normal accepted-stream behavior
remains intact. At terminal state, normal closed-helper behavior applies;
special post-decline silent-success behavior for SSE data sends is not retained
by adding refusal history. Their existing closed-stream error is sufficient.

Pending keepalive may be discarded when declining to start or at terminal
cleanup; it must never arm after an HTTP response starts. Do not delete it
merely because `response_started` became true during a normal `sse.start`:
normal start must still arm its saved keepalive after its send settles.

No callback is needed to restore admission after a failed or empty application.
Connection progress stays authoritative after partial output or termination.
Overlapping or reentrant operations and competing receive consumers remain
unsupported. Cancellation does not certify that an arbitrary application's
internally protected work has stopped; callers remain responsible for sequencing.

## Ownership and cancellation

The returned Future participates in the enclosing application's ordinary await
tree. The caller owns its wait. The refusal layer does not promise survival
after caller cancellation, loss of references, or connection termination.
Cancellation follows the invoked application's behavior; it cannot necessarily
stop an external service or reverse bytes already sent.

Buffered `PAGI::Response` shields each server-owned send Future with
`without_cancel`. This protects the submitted send, not the whole response.
Cancellation while awaiting response start prevents subsequent body emission;
cancellation while awaiting the body leaves that submitted send under server
control. The response operation itself becomes cancelled. No automatic abort,
replacement response, background drain, or new cleanup worker is added.

File already shields its sends. Stream/Writer already define cancellation,
abort, producer, and cleanup behavior; delegated cancellation must reach that
existing implementation. Do not replace it with refusal-specific handling.
Native/custom apps own their own cancellation compliance. The original send
callback is still passed unchanged, without global interception or shielding.

Connection terminal notification and existing asynchronous `on_close` cleanup
remain independently owned as before. This work does not remove unrelated
`retain`/`without_cancel` uses in close, cleanup, subscriptions, or Writer.

## Boundaries and verification

- Backward compatibility is not a requirement for this redesign.
- Original scope identity/type and receive/send callbacks remain unchanged.
- All supported handler/application forms and fluent success values remain.
- Every refusal target still requires the public connection contract.
- No server/spec repository change, new dependency, Auth redesign, public
  lifecycle framework, private Response emission call, or receive watcher.
- Perl minimum 5.018, Future minimum 0.50, Future::AsyncAwait minimum 0.66
  remain unchanged; library code uses argument unpacking from `@_`.
- Replace tests demanding detached survival with tests of cancellation
  propagation, server-send isolation, and ordinary ownership. Preserve real
  disconnect cleanup, first-response protection, all application forms, and
  normal accepted-stream/keepalive regressions.
- Re-run the actual HTTP/1.1 and HTTP/2 integration cases and the complete Tools
  suite against the recorded server checkout; report skips explicitly.

Implementation details, work map, and exact gates are in
[the focused plan](../plans/2026-09-18-protocol-refusal-ownership-simplification-plan.md).
