# Tools universal connection and Auth Phase 1 completion handoff

Status: complete and reviewed, ready to merge. Final code commit: `7b90716`. The whole-branch review's three findings are resolved; the scoped rereview found no new issues. Keep this branch local until John chooses integration.

## Goals and result

Application authors can construct a reusable authentication-required or forbidden outcome, let Pages select HTML, text, or problem JSON, and use it for HTTP, a refused WebSocket, or a declined SSE stream. Auth constructs validated challenge metadata and outcomes; it does not acquire credentials, establish identity, or replace existing authentication middleware.

The original blocker was a streaming refusal producer retained forever after the client disconnected while the producer awaited unrelated work. The spec-defined universal connection now owns the terminal facts. Tools observes those facts and retains one asynchronous cleanup operation until it finishes. Real HTTP/1.1 and HTTP/2 tests prove producer cancellation, resource release, and once-only cleanup.

## Repository boundary

| Repository | Branch / reference | Work in this continuation |
| --- | --- | --- |
| PAGI-Tools | `feature/universal-connection-tools`; whole-branch base `c4c007f`; continuation began at Auth checkpoint `2733ba2` | Local implementation, tests, examples, documentation, build |
| PAGI | `main` at `9aebdbc` | Read-only normative `lib/PAGI/Spec/Www.pod` |
| PAGI-Server | `.worktrees/feature-websocket-close-truthfulness`, branch `feature/websocket-close-truthfulness` at `c0c08f6` | Read-only integration reference; server merge remains John's decision |

No push, merge, tag, upload, or release occurred. Tools runtime depends on the public connection contract, not this server's internal fields or timeout values. Server-specific transport construction exists only in integration tests.

## Completed work

- Plan C C1–C7: terminal-aware test clients, ordinary HTTP refusal validation/emission on original scopes, File support, connection-owned terminal observation, retained helper cleanup, cancellation ownership, endpoint/handler-return boundaries, real integration proof, Lint and public protocol documentation.
- Auth Phase 1: structured Basic/Bearer/custom challenges; `challenge`/`forbid` Pages applications; synchronous, no-send `response_for`; distinct repeated `WWW-Authenticate` fields; examples, discovery and recipes.
- Middleware namespace drive-by: `PAGI::Utils::Middleware`, including examples and docs.
- Cookie login example: explicit application session/redirect policy, regeneration on login and destruction on logout, with its demo limitations stated.
- Apples canary: `/apples/auth-required` always returns a negotiated Bearer challenge. Existing behavior and the original Python comparison block are preserved.

## Contract details and compatibility choices

- Accepted WebSocket `close()` finishes when its send settles. The connection later determines clean or abnormal termination and supplies the peer's code/text. Outgoing application intent is not substituted for peer metadata.
- WebSocket `on_close` receives `(peer_code, peer_reason, disconnect_detail)`; lifecycle reason is available separately. SSE receives `(sse, disconnect_reason, disconnect_detail)`, with undefined reason/detail on clean completion.
- Register `on_close` before awaited I/O. Registration after cleanup starts now fails clearly instead of silently retaining an unreachable callback. Endpoint adapters and maintained examples follow that ordering.
- The first SSE close joins cleanup. Calls after cleanup starts return send settlement or immediate completion, including unrelated later callers; this prevents a cleanup callback from awaiting itself. The owned cleanup continues until all hooks settle.
- Refusal header commitment reserves the response slot but does not mean the connection has ended. Helpers remain `denying`/`declining` until terminal facts arrive, and reject protocol data after refusal commitment.
- Stream observer cancellation signals its owned cancellation before requesting public connection abort. It never cancels a server-owned send Future.
- Test clients use a cooperative peer by default and explicit manual outcome controls for abnormal cases. `pump()` delivers deferred notifications after externally resumed test work; no server timer simulation is introduced.
- Existing manually constructed helpers with no connection object retain bounded legacy behavior. A present connection object must provide the current spec interface.
- Library code keeps the declared Perl 5.18 boundary. The cookie and apples examples declare Perl 5.40 and their tests skip before loading them on older interpreters.

These are deliberate observable choices, not hidden compatibility fallbacks. Their cost is primarily the callback-registration and close-timing migration described above. Credential/identity middleware and a complete multi-protocol authentication application remain Phase 2.

## Verification

Project interpreter: `perl-5.42.2@default`, with `PERL_FUTURE_NO_XS=1`.

The fresh recursive gate passed **226 files / 2,583 tests** after the final runtime correction:

```sh
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove \
  -I /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server/.worktrees/feature-websocket-close-truthfulness/lib \
  -lr t
```

All seven real-server cases executed: WebSocket denial and SSE decline over both transports; both accepted WebSocket close initiators; natural HTTP/2 `close_incomplete`. Those cases contain 144 assertions and no skips. The only full-suite skip was the unrelated optional multipart test requiring `RELEASE_TESTING=1`.

The focused Auth documentation gate passed 19 files / 286 tests. The final Pages/Auth correction gate passed 13 files / 429 tests plus both affected POD checks. Its regression proves repeated materialization leaves raw HTTP and Request source hashes and header-cache identities unchanged, while policy hooks still receive the original scope. The correction is a shallow copy only at the metadata-only Request boundary.

`dzil build` produced `PAGI-Tools-0.002002.tar.gz`, rebuilt after the last documentation correction. Archive inspection confirmed Auth modules, README, Changes and intended examples; historical `docs/` and `.superpowers/` content is excluded. Nonfatal PkgVersion layout warnings were reported for existing package formatting. This is a local build at the existing distribution version, not a release.

Detailed commands, reviews and decisions are retained in `.superpowers/sdd/2026-09-14-tools-auth-continuation/`, especially `progress.md`, task resume reports, and the final branch review.

## Try the outcome API

Run the apples example using its README, then request `/apples/auth-required` with `Accept: application/problem+json`. It returns HTTP 401, `WWW-Authenticate: Bearer realm="apples"`, and a problem document whose detail is `A valid access token is required.` Choosing HTML or text negotiates that representation instead. This route demonstrates outcomes and deliberately does not validate a token.

For interactive login policy, see `examples/auth-cookie-login/README.md` and its tested `demo` / `secret` journey.

## Workspace preservation

The pre-existing edits in `docs/superpowers/plans/2026-09-08-universal-connection-tracking.md` and unrelated `.pagi-*`/`.superpowers` notes remain untouched. Do not blanket-stage or delete them. The current branch and workspace are retained for John's integration decision.
