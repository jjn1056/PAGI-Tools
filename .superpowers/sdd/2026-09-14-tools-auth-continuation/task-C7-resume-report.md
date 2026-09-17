# C7 resume report — 2026-09-17

## Work map and scope

| Repository | Task / branch / base | Changes | Deployment / push |
| --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | C7 / `feature/universal-connection-tools` / `b4883c2` | Lint wiring/diagnostics, focused tests, protocol documentation/audit, one authorized stale test-fixture correction, this report | local commit only; no push |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI` | normative reference / `9aebdbc` | read-only | none |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server/.worktrees/feature-websocket-close-truthfulness` | integration reference / `c0c08f6` | read-only | none |

The pre-existing dirty continuation progress/tracking files and unrelated
untracked notes were preserved and excluded from the commit. No sibling
repository was modified.

## Runtime and test behavior

`PAGI::Middleware::Lint` now constructs the existing shared
`PAGI::Utils::_SendValidation` state machine for HTTP, WebSocket, and SSE.
It accepts ordinary HTTP refusals on protocol scopes, diagnoses removed event
names and close-before-accept, and keeps strict/non-strict forwarding behavior.
Final diagnostics name WebSocket and SSE completion obligations instead of
prescribing HTTP body events. A clean `response_complete` connection fact
satisfies finalization when a peer-initiated close was completed by the server
outside Lint's send-only view; abnormal disconnect reporting remains separate.
No second validator or protocol state machine was added.

The regression tests cover complete refusals, removed names, preaccept close in
both modes, accepted/started terminal sends, incomplete active scopes, and clean
peer-first terminal facts. The realistic mutations caught are removing the
protocol validator wiring, mapping every incomplete state to HTTP diagnostics,
or ignoring the authoritative clean connection fact.

## Documentation and audit

Cookbook, Tutorial, Lint, Routing, Test::Client, Writer, and Changes now record
the completed Www 0.6 contract: universal connection state, ordinary refusal
events on the original scope, File eligibility, streaming connection
requirements, removed bridge/capability/extension names, invalid preaccept
WebSocket close, helper-return terminal ownership versus raw-app obligations,
peer Close metadata versus lifecycle reason/detail, reasonless clean SSE ends,
retained cleanup, and caller-owned abort without cancelling server sends.
Test::Client documents manual peer close outcomes and `pump` notification
delivery without claiming transport timing.

The Cookbook adds an app-owned raw-HTTP recipe for counting an unknown-length
upload. It distinguishes a route policy from a server-wide body limit, emits an
in-band error only when the already-started response format defines one, awaits
that send, and then calls public connection `abort`. It does not claim SSE body
reader support.

Repository audit classification:

- Active `lib`, examples, and tests no longer advertise or send the removed
  namespaced refusal events, denial capability, or extension.
- `_SendValidation` POD and `t/utils-send-validation.t` retain the old names as
  explicit negative coverage.
- Older `Changes` entries retain the names as labeled release history; the
  current unreleased section records their removal.
- The sole `PAGI::Middleware::Helpers` occurrence is the current unreleased
  rename notice to `PAGI::Utils::Middleware`; no active example uses it.

## Verification evidence

All commands used `perlbrew exec --with perl-5.42.2@default env
PERL_FUTURE_NO_XS=1`.

Focused Lint TDD red: `prove -lv t/middleware/lint.t` failed the newly added
protocol rejection and completion cases before Lint was wired. After the
implementation, the final focused command was:

```text
prove -l t/middleware/lint.t t/websocket/denial-response.t t/upgrading-response-family.t t/routing/08-protocols.t t/routing/12-router-mounts.t
```

Result: **5 files, 65 tests passed**.

`podchecker` passed all 12 relevant files: Lint, Routing, Tutorial, Cookbook,
Test::Client, Test::ConnectionState, WebSocket, SSE, Response, Response::File,
Response::Stream, and Response::Writer. `t/00-pod/cookbook-examples.t` also
passed inside the recursive gate. `git diff --check` passed.

The one authorized recursive gate, with host socket access, was:

```text
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -I /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server/.worktrees/feature-websocket-close-truthfulness/lib -lr t
```

Result: **225 files, 2556 tests, one failed subtest**, runtime 48 seconds.
All seven `t/integration/protocol-refusal-stream-disconnect.t` rows executed and
passed; its Server, Tools, and nghttp2 paths were printed. There were no skips
in that acceptance matrix. One unrelated optional test file skipped normally:
`t/request/multipart-stream-e2e.t` requires `RELEASE_TESTING=1`. Expected stderr
was three application access-log lines, the integration path diagnostics, and
the existing SSE smoke-test 404 access log.

The sole failure was `t/response-writer.t` subtest 13: its deliberately small
`T::PAGI05Connection` fake lacked the now-required `disconnect_detail` method.
This was reported before mutation. After authorization, the fixture gained the
detail fact, optional transition detail, and reason/detail callback delivery,
including late registration. An existing disconnect case asserts Writer detail
passthrough. No Writer/runtime compatibility fallback was added. Its TDD red
failed on the absent callback detail and method; the covering rerun was:

```text
prove -l t/response-writer.t
```

Result: **1 file, 24 tests passed**. The recursive suite was not rerun because
the only change was this isolated test fixture and the failure was resolved by
its focused file, as directed.

## Concerns and boundary

The single recursive command is accurately recorded as failed, followed by a
green focused correction; there is no claim that the recursive command itself
passed. Full guarantees require a server implementing the normative Www 0.6
connection API. The referenced server checkout supplied the integration
evidence but is not the only supported implementation. No release version or
PAGI::Server internal dependency is claimed.

## Review fix round 1 — Cookbook terminal outcomes

Addressed both documentation findings from `task-C7-resume-review.md`. The
unknown-length upload recipe now returns immediately on `http.disconnect`, so
a truncated upload cannot fall through to accepted-upload processing or emit a
success response. The SSE decline section now distinguishes unsolicited event
delivery from an explicit post-refusal receive: the completed refusal is a
clean end, and that receive resolves with a reasonless `sse.disconnect` under
Www 0.6. No runtime code, feature, or test behavior changed.

Focused checks after the edits:

```text
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 podchecker lib/PAGI/Tools/Cookbook.pod
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -l t/00-pod/cookbook-examples.t
git diff --check
```

The POD checker passed. The extracted Cookbook example test passed **1 file,
9 tests**. The diff whitespace check passed. No full suite was run in this
bounded documentation fix round.
