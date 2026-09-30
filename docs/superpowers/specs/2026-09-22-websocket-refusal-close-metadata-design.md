# WebSocket refusal close metadata

Date: 2026-09-22

Status: implemented and reviewed. See the [implementation plan](../plans/2026-09-22-websocket-refusal-close-metadata-plan.md#execution-result--2026-09-22) for checkout identities and verification results.

## Goal

Make the server and Tools test double report the existing PAGI contract consistently when a WebSocket handshake is refused with an HTTP response. After the refusal completes, the connection reports `close_code = 1006` and `close_reason = undef`, with those values available to terminal observers.

The refusal itself remains a successful PAGI scope completion. Delivering an HTTP refusal successfully and establishing a WebSocket successfully are different outcomes.

**No PAGI specification change is required.** This is an implementation correction and a small Tools documentation clarification, not another closing-handshake redesign.

## Repository work map

All repository paths below are under `/Users/jnapiorkowski/Desktop/PAGI-Project/`. No ticket was supplied. No push, merge, release, or deployment is authorized by this document.

| Repository | Observed branch and baseline | Owned changes | Deployment boundary / push target |
| --- | --- | --- | --- |
| `PAGI-Tools` | `feature/universal-connection-tools` at `a068bffb815ebbcaff8cca8b2a892507c92397f5`; branch base `main`, merge-base `c4c007f7a0603c2e36cd88266f2289db4f3baa12` | Test-double normalization, regression tests, Tools documentation | Tools distribution; no push target selected |
| `PAGI-Server` | `main` at `59c40cf78906b48f1a9a0482fd1d810053e302cd` | HTTP/1.1 and HTTP/2 refusal terminal metadata and server regressions | Server distribution; implementation branch and push target must be recorded before implementation |
| `PAGI` | `main` at `9aebdbcd938f4ff520d68ce2ea2e86cd00cf150f` | Read-only contract reference | No changes or publication |

Reconfirm this map before implementation, particularly the server branch. Preserve unrelated work already present in Tools. The Tools production helper must remain portable to other conforming PAGI servers.

## Existing contract and evidence

`PAGI/lib/PAGI/Spec/Www.pod`, under the connection close accessors, already defines `1006` when a WebSocket scope ends without a received peer Close, and requires metadata to be populated before terminal callbacks. Its refusal section separately treats a normally completed HTTP refusal as clean scope completion.

This agrees with RFC 6455: failed establishment leaves the WebSocket closed (§7.1.4); a closed connection without a received Close has close code `1006` (§7.1.5). `1006` is a locally reported value and must never be sent in a Close frame (§7.4.1). We do not need to restate these rules normatively in PAGI.

Research reproduced the discrepancy through both the Tools public TestClient and a real HTTP/1.1 server refusal: the refusal completed successfully, but the accessor and completion observer saw `undef`. HTTP/2 code inspection found the same ordering concern; a runtime probe was skipped because the available environment lacked the required `Net::HTTP2::nghttp2` version. HTTP/2 remains a verification requirement.

Relevant implementation locations:

- Server: `lib/PAGI/Server/Connection.pm`, especially `_h1_end_scope_output`, `_h2_end_scope_output`, and WebSocket close metadata settlement; `lib/PAGI/Server/ConnectionState.pm` terminal publication.
- Tools: `lib/PAGI/Test/WebSocket.pm` refusal completion and `lib/PAGI/Test/ConnectionState.pm` terminal state.
- Tools production projection: `lib/PAGI/WebSocket.pm`, `_refresh_connection` and its terminal observer.
- Conflicting Tools coverage: `t/websocket/deny-close-code.t` expects `undef`, while `t/websocket/15-connection-cleanup.t` manually supplies `1006` before completion. The latter verifies projection, not correct refusal settlement.

## Observable behavior

For a normally completed WebSocket HTTP refusal:

| Observation | Required result |
| --- | --- |
| HTTP status, headers, and body | The application's chosen refusal response |
| `response_started` / `response_complete` | True / true |
| `is_connected` | False: the PAGI scope has ended |
| `close_code` / `close_reason` | `1006` / `undef` |
| `disconnect_reason` / `disconnect_detail` | `undef` / `undef` |
| `on_complete` / `on_end` | Each registered observer is called once |
| `on_disconnect` | Not called |
| `end_future` | Resolves with `undef`, as for successful scope completion |

These values must agree inside terminal callbacks and after completion. The Tools WebSocket helper's `on_close` observes the server-supplied `1006` and undefined reason; this does not convert the refusal into a PAGI disconnect failure.

While refusal output is still pending and no peer Close has been received, `close_code` remains `undef`. Starting a refusal or returning from the handler is not sufficient to publish the terminal value.

An interruption before refusal completion keeps its existing abnormal outcome and disconnect token. A later completion attempt must not replace that terminal record. Accepted WebSockets retain their existing peer-code behavior, including `1005` for a Close without a code and preservation of a received peer code on an abnormal finish. HTTP and SSE close accessors remain `undef`.

## Implementation responsibilities

### Server

Populate WebSocket refusal close metadata at the existing successful output-completion boundary, before publishing terminal state or notifying observers. Cover both HTTP/1.1 and HTTP/2.

The completion paths also serve HTTP and SSE. Apply the WebSocket-specific rule using the existing scope information; do not give every generic connection state a `1006` fallback. A setter invoked after `_mark_complete` cannot repair the result because terminal state is immutable.

Keep the existing refusal completion boundary. Do not introduce another wait for a peer Close, a new timer, or a different transport shutdown policy to produce the accessor value. This correction does not change HTTP/2 END_STREAM handling or accepted-WebSocket handshake settlement.

### Tools

Make the WebSocket test double produce the same terminal metadata through normal refusal execution. Use the existing WebSocket scope distinction and terminal machinery; avoid a new public option or independent state machine.

Keep `PAGI::WebSocket` authoritative from `pagi.connection`. Do not synthesize a code in `deny`, `_refresh_connection`, or the helper's callbacks to hide a nonconforming server.

Replace the contradictory refusal expectation. Add coverage through the public TestClient and `deny` path so the test does not manufacture the desired code by calling a private metadata setter. Retain useful direct projection tests as separate coverage.

### Documentation

Clarify the existing Tools WebSocket refusal documentation with a short example: a delivered HTTP 403 can produce `on_complete` and an `on_close` code of `1006`, because no WebSocket handshake was established and no peer Close was received. A caller checking delivery success should use scope completion rather than interpret `1006` alone as an HTTP response failure.

Keep this explanation beside `deny` or the close-accessor lifecycle documentation. Do not expand the normative PAGI prose or describe server internals as an application contract.

## Acceptance criteria

1. A real HTTP/1.1 refusal and a real HTTP/2 refusal produce the table above. Terminal callbacks read the correct metadata immediately; an application awaiting `end_future` also sees it.
2. Buffered and incrementally produced refusal output show the boundary correctly: no terminal code before output completion, then `1006` before terminal observation. Exercise trailers where they defer the existing completion boundary. File and filehandle output must follow the same terminal path; add focused coverage if they bypass the corrected path, rather than duplicating an exhaustive response-format matrix.
3. The public Tools TestClient refusal path agrees with the server on status/body, close accessors, completion versus disconnect callbacks, and the helper's `on_close` arguments.
4. Aborting an unfinished refusal preserves the existing abnormal outcome and first-terminal-state rule. A repeated completion notification neither overwrites metadata nor invokes observers twice.
5. Accepted-WebSocket peer code/reason behavior and HTTP/SSE undefined close accessors remain unchanged. Existing suitable regressions may establish this without new duplicate tests.
6. Normal refusal emits HTTP response traffic, not a WebSocket Close frame or a new `websocket.disconnect` event. Existing post-refusal receive behavior remains unchanged.
7. Run the affected regressions and each changed repository's suite. An HTTP/2 dependency skip does not establish HTTP/2 correctness: run its regression in a suitably provisioned environment before declaring the joint gate complete. Report any remaining verification limitation explicitly.

Assertions target PAGI outcomes and wire behavior, not server-private fields, callback scheduling tricks, or particular timeout values. No browser automation is needed.

## Out of scope

- New PAGI requirements, capabilities, events, or public APIs.
- Changes to `deny`/`decline` argument shapes, authentication, or refusal response generation.
- Accepted-WebSocket timeout and closing-handshake redesign.
- Helper-side compatibility fallbacks, new retention machinery, or background cleanup workers.
- Committing or publishing the existing unrelated branch changes.

## References

- Local contract: `PAGI/lib/PAGI/Spec/Www.pod`, connection close accessors and “Refusing the handshake”.
- [RFC 6455 §7.1.4: The WebSocket Connection is Closed](https://www.rfc-editor.org/rfc/rfc6455.html#section-7.1.4).
- [RFC 6455 §7.1.5: The WebSocket Connection Close Code](https://www.rfc-editor.org/rfc/rfc6455.html#section-7.1.5).
- [RFC 6455 §7.4.1: Defined Status Codes](https://www.rfc-editor.org/rfc/rfc6455.html#section-7.4.1).
