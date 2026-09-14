# PAGI-Tools handoff: the 0.6 SSE-decline rename, and the new ecosystem CI

Written 2026-09-14 by the session that ran the PAGI-Server 0.6 work (PR #19,
now merged to `main`). For the session working the PAGI-Tools fix on
`feature/authentication-outcomes-phase1`. Everything below is verified against
PAGI-Server `main` at `39d7b26` (PR #19 merged as `18fbf9b`) and the PAGI-Tools
working tree as it stands today.

## The urgent finding: SSE decline is broken against a 0.6 server

PAGI 0.6 **removed** the `sse.http.response.*` SSE-decline protocol and
replaced it with the bare `http.response.*` events on the sse scope, unifying
stream refusal across http, websocket, and sse. PAGI-Tools — the WIP branch
included, not just the stale CPAN 0.002002 — still declines with
`sse.http.response.*`. Against a 0.6 server those events are rejected, and an
SSE decline becomes a 500 instead of the intended real HTTP response.

This is not addressed in the working tree. The cross-repo test
`t/integration/sse-decline-end-to-end.t` guards only on
`PAGI::Server->VERSION >= 0.002005` (`MIN_SSE_DECLINE_SERVER_VERSION`), and the
0.6 server reports a higher version while having removed the feature, so the
test runs and fails rather than skipping.

### Proof

- Server side, current `main`: `sse.http.response` appears **nowhere** in
  `lib/`. `lib/PAGI/Server/EventValidator.pm` (`validate_sse_send`, lines
  ~256-285) accepts on an sse scope: `sse.start`, `sse.send`, `sse.comment`,
  `sse.keepalive`, `sse.close`, the refusal trio `http.response.start` /
  `http.response.body` / `http.response.trailers`, and `http.fullflush`.
  Anything else croaks `Unrecognized event type '<type>' for sse protocol`.
- Spec: `lib/PAGI/Server/Compliance.pod` (~line 1053) states a refusal uses
  `http.response.start`, "which is also how a websocket or sse scope is
  refused." The bare `http.response.*` events are the 0.6 refusal contract on
  every scope.
- The ecosystem CI canary (see below) reproduced it: PAGI::Tools 0.002002
  installed against the checkout server fails exactly one test,
  `t/integration/sse-decline-end-to-end.t`, with
  `PAGI application error (SSE): Unrecognized event type
  'sse.http.response.start' for sse protocol at .../Connection.pm line 7094`.
- Why it looked fine before: a pre-0.6 server (for example the
  perlbrew-installed `PAGI::Server 0.002013` on the dev box) still has the
  `sse.http.response.*` protocol, so PAGI-Tools' suite passes there. Only a
  0.6 server exposes the break.

## Where PAGI-Tools uses the old name

`grep -rn 'sse\.http\.response' lib/ t/` — 5 lib files, 10 test files:

- `lib/PAGI/SSE.pm:347` — the decline path passes the event-name prefix
  `'sse.http.response'` to `PAGI::Response::_respond_for_protocol`, which
  appends `.start` / `.body`. This is the emit site.
- `lib/PAGI/Utils/_SendValidation.pm` — the toolkit's own send validation,
  which recognises `sse.http.response.*`. Must match whatever the server
  accepts.
- `lib/PAGI/Test/Client.pm` (~489, ~1305) and `lib/PAGI/Test/SSE.pm` — the
  test client detects a decline by these event names.
- `lib/PAGI/Tools/Cookbook.pod` (~1730-1751) — documents
  `sse.http.response.start` / `.body` as the public decline API on the raw
  `$send`.
- Tests: `t/integration/sse-decline-end-to-end.t` (and its
  `MIN_SSE_DECLINE_SERVER_VERSION` guard), `t/sse/13-decline.t`,
  `t/sse/14-keepalive-deferred-arm.t`, `t/test/client-sse-decline.t`,
  `t/auth/04-protocol-integration.t`, `t/routing/08-protocols.t`,
  `t/routing/12-router-mounts.t`, `t/routing/16-http-outcomes.t`,
  `t/utils-send-validation.t`, `t/upgrading-response-family.t`.

## The decision, and the likely shape of the fix

Two ways to resolve, and it is your call (or a joint call with the server,
though the server side deliberately unified refusal in 0.6 and is unlikely to
re-add the old events):

1. **Migrate PAGI-Tools to the 0.6 contract** (expected): decline an sse
   scope by emitting bare `http.response.*` on the raw `$send`. The core code
   change may be as small as the prefix string at `SSE.pm:347`
   (`'sse.http.response'` -> `'http.response'`) plus `_SendValidation.pm`, but
   the real surface is public: the Cookbook documents the old events as API,
   `Test::Client`/`Test::SSE` detect them, and roughly ten tests assert them.
   The `MIN_SSE_DECLINE_SERVER_VERSION` guard should also be re-pointed at the
   first 0.6 server version rather than 0.002005, so the test skips cleanly on
   servers that lack the new contract instead of failing.
2. Server re-adds `sse.http.response.*` as accepted aliases. Contradicts the
   0.6 unification; not recommended.

This ships as part of the "one CPAN break" the redesign already planned, so a
public rename here is in scope rather than a compatibility burden.

## How to reproduce locally

From the PAGI-Tools working tree, load the 0.6 checkout server ahead of any
installed copy:

```
PERL5LIB=/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server/lib \
  prove -lr t/integration/sse-decline-end-to-end.t t/sse/13-decline.t
```

Gotcha: the perlbrew-installed `PAGI::Server` is pre-0.6 and still has the old
protocol, so without the `PERL5LIB` override the break is masked. Confirm you
are on the 0.6 server with
`PERL5LIB=.../PAGI-Server/lib perl -MPAGI::Server -e 'print $INC{"PAGI/Server.pm"}'`.

## The new ecosystem CI (PAGI-Server side, already live)

PAGI-Server `main` now has a GitHub Actions workflow (`.github/workflows/ci.yml`):

- A core matrix runs the server suite on Perl 5.36-5.42 on Linux, green.
- A second, **non-blocking** `ecosystem` job installs `PAGI::Tools`, then
  `Task::WebDyne::PAGI`, `Thunderhorse`, and `PAGI::FastAPI` from CPAN with the
  checkout's `PAGI::Server` ahead on `PERL5LIB`, and runs their suites. It is
  the cross-repo canary. It is currently **red** on the SSE-decline break above
  (PAGI::Tools fails, and the three frameworks that depend on it cascade;
  WebDyne itself installs fine). Non-blocking means it never reddens the
  server's own CI.

The canary clears once (a) PAGI-Tools' SSE decline is migrated to the 0.6
contract, and (b) the fixed PAGI-Tools is released to CPAN — the job installs
from CPAN, not from a checkout of Tools.

## What is blocking the release chain

CPAN's `02packages` index has been frozen globally since 2026-09-11 15:54 GMT
(not a PAGI upload problem — PLICEASE's Alien-Build 2.87 is missing too). This
blocks:
- releasing the fixed PAGI-Tools (so the canary stays red until then),
- `Net::HTTP2::nghttp2` 0.010/0.011 reaching CPAN (server CI builds it from a
  pinned commit meanwhile),
- the PAGI-Server 0.002014 release.

Nothing to do but wait for the index to resync, or ping the PAUSE admins if it
drags on. A three-day freeze is abnormal.

## Other current-state facts you may need

- PAGI-Server `main` includes, beyond the 0.6 protocol work: a Future::XS
  lockout (the server now sets `PERL_FUTURE_NO_XS=1` at compile time because
  Future::XS 0.15 warns "lost a sequence Future" when a `without_cancel`
  observer is dropped, the shape of racing `disconnect_future` with
  `wait_any`; reported upstream, RT queue for Future-XS). **PAGI-Tools has no
  such guard.** Its suite passed with Future::XS installed on the dev box, but
  any PAGI app that races `disconnect_future` will see the warning under
  Future::XS; worth a deliberate decision if the toolkit or its examples do
  that.
- Two server h2 tests were made tolerant of the libnghttp2 version (1.59 vs
  1.68 differ on malformed-header policy); not relevant to Tools, but explains
  recent server test churn if you read the log.
- The prior Plan C handoff still stands for the other PAGI-Tools items
  (SSE reason fabrication, WebSocket `http.disconnect`, `Test::SSE`, body
  readers, `max_disconnect_receives`, the upload cookbook pattern):
  `docs/superpowers/plans/2026-09-13-plan-c-handoff.md`. The SSE-decline rename
  here is a separate, newly surfaced item not in that doc.

## References

- PAGI-Server `main`: `39d7b26`; PR #19 merge: `18fbf9b`.
- Server accepted sse send events: `lib/PAGI/Server/EventValidator.pm`
  ~256-285; refusal on sse scope: `lib/PAGI/Server/Connection.pm` ~7099
  (`$type =~ /^http\.response\./`); the reject site the canary hit: ~7094.
- Tracking ledger (this campaign):
  `docs/superpowers/plans/2026-09-08-universal-connection-tracking.md` — see the
  "Ecosystem canary" and SSE-decline entries under "Ledger: found, not started."
