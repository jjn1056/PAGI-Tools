# C6 resume report — 2026-09-17

## Work map and ownership

| Repository | Task / branch / base | Owned changes | Deployment / push |
| --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | C6 / `feature/universal-connection-tools` / `e42cfa3d424d77a0ac313a7a395d1c370636f499` | Three test files below and this report | local commit only; no push |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI` | normative reference / main / `9aebdbcd938f4ff520d68ce2ea2e86cd00cf150f` | read-only | none |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server/.worktrees/feature-websocket-close-truthfulness` | server reference / feature/websocket-close-truthfulness / `c0c08f695a4ecb1cd1d553fdbdfec3dbda86601e` | read-only | none |

Verified all three HEADs before commit. No helper/runtime/server changes. Preserved unrelated dirty progress/tracking documents and untracked notes.

Owned files:

- `t/integration/protocol-refusal-stream-disconnect.t`: four real refusal rows and three accepted-WebSocket rows, transport bootstrap kept in this test.
- `t/auth/04-protocol-integration.t`: current PAGI 0.5 / Www 0.6 direct scopes, plus both unrelated parked producer regressions using the existing completion-publishing Test::ConnectionState send fixture.
- `t/integration/sse-decline-end-to-end.t`: corrected stale event-mapping comment; exercised its existing portable public-method assertions.

## Executed evidence

All commands used `perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1`. Socket runs had host access. No replacement of perlbrew PERL5LIB, no source-shell wrapper, no full suite.

First real matrix run (four rows before adding accepted cases):

```sh
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -I /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server/.worktrees/feature-websocket-close-truthfulness/lib -lv t/integration/protocol-refusal-stream-disconnect.t
```

**1 file / 4 subtests, 2 failed.** Every lifecycle/resource assertion passed in all four rows. HTTP/1.1 rows failed only their warning assertion: the test's pre-header regex returned an empty list, shifting the response tuple and leaving body undefined. Corrected the harness to return an explicit undefined status until headers arrive. Disabled normal access logs in the new harness. This was a harness failure, not a production regression red.

Same exact command after that correction and adding accepted cases: **1 file / 7 subtests passed**, 144 inner assertions, no skips, no warnings, no server logs. Actual executed rows:

| Transport | Scenario | Assertions | Result |
| --- | --- | ---: | --- |
| HTTP/1.1 TCP | WebSocket denial, write then unrelated Future, socket drop | 21 | PASS |
| HTTP/1.1 TCP | SSE decline, write then unrelated Future, socket drop | 21 | PASS |
| HTTP/2 socketpair + nghttp2 | WebSocket denial, write then unrelated Future, socket drop | 21 | PASS |
| HTTP/2 socketpair + nghttp2 | SSE decline, write then unrelated Future, socket drop | 21 | PASS |
| HTTP/1.1 TCP | application-initiated accepted WS clean close | 20 | PASS |
| HTTP/1.1 TCP | peer-initiated accepted WS clean close, handler parked off receive | 20 | PASS |
| HTTP/2 socketpair + nghttp2 | application Close, peer Close without END_STREAM, natural `close_incomplete` | 20 | PASS |

Loaded paths printed by that test:

- Server: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server/.worktrees/feature-websocket-close-truthfulness/lib/PAGI/Server.pm`
- Tools: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/t/integration/../../lib/PAGI/WebSocket.pm`
- nghttp2: `/Users/jnapiorkowski/.perlbrew/libs/perl-5.42.2@default/lib/perl5/darwin-2level/Net/HTTP2/nghttp2/Session.pm`

Each refusal row asserts actual scope `http_version` and advertised Www `spec_version` 0.6. Availability checks use public capabilities, not the historically lagging distribution version. Optional standalone dependency skips exist, but **none occurred in acceptance**.

Final focused covering gate:

```sh
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -I /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server/.worktrees/feature-websocket-close-truthfulness/lib -l t/auth/04-protocol-integration.t t/integration/sse-decline-end-to-end.t t/websocket/15-connection-cleanup.t t/sse/15-connection-timer.t
```

**4 files / 32 top-level tests passed, no skips.** Auth 6, smoke 1, WebSocket 22, SSE 3. The old smoke emitted its expected access log `GET /events` 404; no unexpected diagnostics. Helper tests had already launched when parent requested narrowing that gate; no additional rerun was done.

Final fixture inspection corrected Auth's PAGI version from 1.0 to the current 0.5, then ran:

```sh
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -l t/auth/04-protocol-integration.t
```

**1 file / 6 top-level tests passed**, no warnings. New parked-producer subtest contains two protocol cases with seven assertions each. `git diff --check` passed.

A proposed negative-control run using a temporary `/tmp/pagi-c6-mutation` Stream copy was aborted at the tool/approval boundary without execution/session output. It is **not counted as executed evidence or a regression red**. No repository source was mutated. Parent directed omitting that experiment; no further mutation or process-inspection attempts followed. C6 is test-only evidence against the already completed C3–C5 fixes; original defect history remains in the continuation brief and earlier reports.

## Lifetime and terminal behavior

Each real refusal producer awaits a successful body write, then parks on a fresh unrelated Future. Before client drop, the wire contains HTTP 403 and `refusal-chunk`, the returned rejection remains pending, and weak producer/writer references are live. After drop, rejection settles successfully, the owned producer's cancellation callback fires once, writer/helper cleanup each run once, and both weak references vanish. All actual send Futures are retained only for inspection and remain uncancelled; only ordinary HTTP start/body events were sent. Public connection state records transport loss and never claims response_complete.

Accepted-WebSocket hooks receive peer 1001 / `peerbye` even though application Close uses 1000 / `applicationbye`. Public server and helper lifecycle reasons agree (undef for clean, `close_incomplete` for unfinished HTTP/2 transport). Cleanup starts without an application receive, parks its first hook, survives handler return, then runs its second hook once and releases the weak helper reference. No monkeypatches, private lifecycle-state assertions, or protocol watchers. The h2 setup accesses server transport construction as allowed by the brief; assertions do not inspect it. A configured close bound keeps the natural incomplete case short; no assertion depends on elapsed time or a private timer constant.

No production gap or unresolved blocker found. C7 still owns the full repository gate. No push, merge, deployment, or sibling edits.
