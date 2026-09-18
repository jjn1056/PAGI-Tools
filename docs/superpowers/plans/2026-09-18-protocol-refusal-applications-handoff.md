# Protocol refusal applications handoff

## Delivery

`PAGI::WebSocket->deny($target)` and `PAGI::SSE->decline($target)` now invoke
one public PAGI application on their original scope, receive, and send
channels. A target may be a one-argument Request handler, a `PAGI::Response`,
`PAGI::Pages`, or another object with `to_app`; wrap a native three-argument
coderef with `PAGI::Utils::as_app_object`.

The shared implementation is `PAGI::Utils::_Refusal`. It requires the public
`pagi.connection` capabilities before target construction or execution,
retains its worker when callers cancel their observer, and derives progress
from public connection facts. It does not alter scope type, reconstruct
response progress, or consume the remaining receive stream. Sequential retry
after a live attempt without response start is supported; overlapping or
reentrant protocol operations remain unsupported.

`PAGI::Request` accepts HTTP, WebSocket, and SSE metadata scopes. HTTP and SSE
body readers consume their own native request/disconnect events; WebSocket body
methods reject before reading. Request, WebSocket, and SSE share the exact
`PAGI::Headers` cache in `pagi.request.headers`.

The six executable documented forms are:

1. direct Response: [example](../../../examples/protocol-refusal/README.md)
2. synchronous Request handler: [example](../../../examples/protocol-refusal/README.md)
3. asynchronous Request handler: [example](../../../examples/protocol-refusal/README.md)
4. direct or handler-returned Pages application: [example](../../../examples/protocol-refusal/README.md)
5. custom `to_app` object: [example](../../../examples/protocol-refusal/README.md)
6. native app wrapped with `as_app_object`: [example](../../../examples/protocol-refusal/README.md)

The maintained [Cookbook section](../../../lib/PAGI/Tools/Cookbook.pod),
[WebSocket POD](../../../lib/PAGI/WebSocket.pm), and
[SSE POD](../../../lib/PAGI/SSE.pm) give the public API details. WebSocket refusal
status validation remains the sending environment's responsibility and must
be at least 300; SSE may use ordinary HTTP 200 or 204.

## Work map and commits

| Repository | Branch / commit | Role | Changes |
| --- | --- | --- | --- |
| PAGI-Tools | `feature/universal-connection-tools` / `387388e` | protocol-refusal-applications | implementation, migration-test correction, and this handoff |
| PAGI | `main` / `9aebdbcd938f4ff520d68ce2ea2e86cd00cf150f` | read-only normative reference | none |
| PAGI-Server | `feature/websocket-close-truthfulness` / `c0c08f695a4ecb1cd1d553fdbdfec3dbda86601e` | read-only integration checkout | none |

Execution began from `79580372db37926f1a6c6a31d7b1968df5d8929a`; the
documentation planning base was `e0f14366c1e7afffabfe87a14de2dcba14c89d63`.
The final test correction is `4c6561b` (`test: update refusal migration
contract`), followed by this handoff commit `387388e`. This is a local-only
record. No server/spec runtime code was changed, and no push, merge, or
release occurred.

## Verification

Focused correction gate:

```sh
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 \
  prove -lv t/upgrading-response-family.t
```

Passed: 1 file, 12 tests. The observed RED was the first host full gate:
`t/upgrading-response-family.t` still asserted the retired concrete-Response
diagnostic with fixtures lacking the now-required public connection contract.
The test now supplies `PAGITest::RefusalHarness`, retains direct Response
coverage, and checks the current one-application diagnostic.

Final full gate, with host socket access:

```sh
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 \
  prove -I /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server/.worktrees/feature-websocket-close-truthfulness/lib -lr t
```

Passed: 230 files, 2,640 tests, 48 wallclock seconds. Actual skip:
`t/request/multipart-stream-e2e.t` — `set RELEASE_TESTING=1 to run the
full-stack PAGI::Server e2e`. The new multipart protocol-input coverage ran
normally. The final gate directly executed
`t/integration/protocol-refusal-stream-disconnect.t` and
`t/integration/sse-decline-end-to-end.t` against the mapped server checkout;
their HTTP/1.1 and HTTP/2 refusal cases are verified. The release-only
multipart case is unavailable in this run and is not evidence for either
protocol transport.

The first sandbox full attempt is preserved in
`.superpowers/sdd/2026-09-18-protocol-refusal-applications-plan/task-7-full-gate.log`.
It was blocked where tests bind sockets. The host rerun before the fixture
correction is preserved as `task-7-full-gate-host.log`; it isolated the stale
migration assertion. The final direct host session produced the passing result
above; its tool-session output was not redirected to a scratch file.

`git diff --check` passed after the correction. The production refusal-path
audit found no private `_emit` call, `is_buffered` dispatch, response scope
rewriting, or `PAGI::Server` dependency. The only `PAGI::Server` search hits
are unrelated SSE/WebSocket runner documentation. The added/changed library
paths use `@_` argument unpacking and show no `use feature`, signatures, or
post-5.18 syntax. Perl 5.18 is not installed locally; Perl 5.20 lacks the
required Future dependency, so declared-floor runtime execution was not
claimed.

## Durable execution rulings

- The user directed execution in the current `feature/universal-connection-tools`
  checkout, so no worktree was created. This preserved the existing dirty
  workspace; exact paths only were staged. Cost: unrelated older work remains
  outside this task's review scope.
- The Request header-container helper/POD task preceded the protocol Request
  constructor/access-order task. This avoided broadening Request before its
  body and metadata contract was designed; the cost was deliberate sequential
  execution rather than parallel edits.
- `Endpoint::HTTP` remains HTTP-only with a local scope guard. Broadening it
  would default WebSocket extended CONNECT requests without a method to GET,
  which this redesign did not authorize. Built-in Response, Pages, and
  RequestResponse applications provide the promised refusal support.
- Narrow task gates were used while implementing each task; the one complete
  Tools-suite gate was reserved for Task 7. This kept the tests relevant while
  retaining whole-branch regression evidence before handoff.
- Final broad review is scoped to the approved implementation since
  `7958037`, with the spec and plan as inputs. Older long-lived-branch work is
  not re-reviewed here; the cost is that an independent earlier defect would
  remain outside this focused review.
- Backward compatibility for the superseded Response-only refusal API is not
  required. The migration test now describes the application-valued contract.
- Connection admission is public-capability based for every target, including
  buffered Responses. A version string is diagnostic only.
- No receive watcher, response-event interception, synthetic HTTP scope,
  buffering fallback, server dependency, cancellation policy, or overlap
  arbitration was introduced. These avoid changing the original channel
  contract or inventing terminal truth; the cost is documented unsupported
  overlapping/reentrant use.
- Existing connection-owned cleanup and the distinction between cancelling an
  observer and retained refusal work remain intact.
- Auth remains out of scope. Its documentation passes existing application
  objects directly; no Auth API or server/spec implementation changed.
- This stayed in the user-directed current checkout. The pre-existing modified
  historical plan and unrelated `.pagi-*` / `.superpowers` files remain
  untouched and unstaged.

## Review state

Tasks 1–6 received their recorded scoped reviews. Final broad implementation
review is pending controller dispatch after this handoff. It should assess
scope/channel identity, cleanup retention, all body readers, header-cache
access order, sequential recovery, server independence, and removal of
duplicated refusal code. There are no known runtime blockers.
