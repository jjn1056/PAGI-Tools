# C5 resume implementation report — 2026-09-17

Implemented on `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools`, branch `feature/universal-connection-tools`, starting at `99cec8642cd30a4d6be1c323243e0228c57b940b`. Ticket/task C5. Sibling PAGI and Server repositories were read-only. No push, merge, deployment, socket tests, or full-suite run. The previously dirty progress/tracking documents and unrelated untracked notes were not staged.

## Result and ownership

WebSocket and SSE each register one connection `on_end` callback. Synchronous accessors refresh the connection facts, including peer code/text and separate lifecycle reason/detail, without receiving. Local close is `closing`, and committed refusal remains `denying`/`declining` until the connection records its terminal outcome. The helpers never publish modern terminal hooks from receive, successful close/refusal sends, or application failures.

Each helper has one shared cleanup completion and one retained worker. The connection callback retains the helper until terminal delivery; the worker retains it while asynchronous hooks run. Hooks execute sequentially with error isolation. Completion releases callback arrays and retained ownership. Observer cancellation does not cancel cleanup or server sends. No global registry, destructor I/O, protocol watcher on modern scopes, partial-object feature fallback, or additional state machine was introduced. Existing no-connection triplets keep their bounded legacy paths.

WebSocket close issues one send, joins it on repeated/concurrent calls, stops further data/keepalive/accept reopening, and returns at send settlement without awaiting the peer. Private completion Futures hold no helper result; caller-only mapped observers preserve the previous helper return value and are retained only until their settlement (or cancellation), avoiding Future's dropped-sequence warning.

SSE run joins terminal cleanup without receiving. Every uses a fresh isolated connection end observer for each timer race. Closing prevents data sends, restart, and keepalive. Genuine try-send failures still report false/error hooks but cannot establish a terminal connection fact.

Routing protocol coderef handlers and both endpoint `to_app` boundaries issue a missing close only after successful return from an accepted/started active helper. No autoaccept/autostart, additional close after refusal/end, or conversion of a handler exception to clean completion. Endpoint disconnect adapters register before on_connect and return async hook results into cleanup.

Stream publishes its existing owned cancel signal, then calls public connection abort once with `response cancelled by caller`. This order prevents synchronous start settlement from invoking a producer after cancellation. Server-owned sends remain uncancelled; only the owned producer is cancelled. Writer preserves disconnect detail from callbacks and synchronous refresh; clean completion is not an abnormal disconnect.

Owned examples `sse-dashboard/app.pl` and `websocket-chat-v2/lib/ChatApp/WebSocket.pm` register cleanup before awaited I/O, guard resources not yet acquired, and avoid creating later timers/subscribers after terminal observation. Their README excerpts and helper/endpoint/response POD describe the same ordering and lifecycle contracts.

## Explicit API adjustments

- `on_close` registration after cleanup has begun or finished throws a clear diagnostic, including an already-terminal connection observed in the constructor. Register before awaited I/O.
- WebSocket hooks receive `(peer_code, peer_reason, disconnect_detail)`; lifecycle token is exposed through `disconnect_reason`, never substituted for peer text. SSE hooks receive `(sse, disconnect_reason, disconnect_detail)`, with both metadata arguments undefined after clean completion.
- The first SSE close and concurrent calls before cleanup begins await its shared cleanup. Once cleanup has begun, later close calls return close-send settlement (or immediate completion if no send was needed). This applies equally to a hook calling close and an unrelated later caller. It prevents a cleanup→close→cleanup cycle without call-context machinery. The private cleanup join always joins the same completion.
- Refusal start settlement commits the response slot but does not close a live connection. Existing local committed flags preserve accept/start no-ops and the no-retry boundary. Impacted C4 auth/denial/decline fixtures were migrated to terminal authority. Producer/send failures await a server terminal outcome for helper cleanup.
- On connection-backed WebSocket run, receive/message-handler exceptions propagate after existing error notification; they do not manufacture a terminal event. Legacy no-object behavior remains bounded separately.

## Red/green evidence

All prove commands below used `/bin/bash`, `login=false`, and this exact prefix:

```sh
source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && PERL_FUTURE_NO_XS=1
```

The prefix's final assignment applies to the following `prove` command (one shell command joined with `&&` as in the recorded executions).

| Command following environment setup | Observed red / subsequent green |
| --- | --- |
| `prove -lv t/websocket/15-connection-cleanup.t` | Initial 4/4 top-level subtests failed for premature local cleanup, missing authority/accessors, and resurrection after start. Initial implementation: 4/4 passed, 47 inner assertions. |
| `prove -l t/response/15-cancel-connection.t` | 5/5 failed: no public abort at cancellation stages and missing Writer detail. After cancellation owner/detail change: 5/5 passed (39 inner assertions). |
| `prove -l t/endpoint/12-protocol-terminal.t` | Valid red after correcting test router syntax: 6/26 failed for missing handler-return closes, late WS hook registration, discarded async SSE hook result. After implementation: 26/26 passed. The earlier malformed router test run was harness error, not feature evidence. |
| `prove -l t/websocket/15-connection-cleanup.t` | Expanded 8-subtest run failed 2 for JSON send during closing and swallowed receive error. Expanded 10-subtest run failed 4 including nonterminal refusal wrongly marked closed. Corrections passed all 10. |
| `prove -l t/sse/15-connection-timer.t` | 1/3 failed for SSE restart/data/keepalive after local close; multiple-tick end-observer isolation already passed. Guard correction passed all 3. |
| `prove -l t/sse/15-connection-timer.t t/websocket/15-connection-cleanup.t` | Message callback propagation red: 1/14 failed. Correction: 14/14 passed. |
| `prove -l t/websocket/15-connection-cleanup.t` | Added accept/keepalive-after-close test failed 1/11; guards passed 11/11. Later helper-return regression tests failed 2/12; caller-only result mapping passed 12/12 after correcting the test to compare object identity. A dropped-sequence warning in the first mapping attempt was eliminated by retaining the caller-only sequence until settlement; lifetime release assertions still pass. |
| `prove -l t/auth/04-protocol-integration.t t/websocket/denial-response.t t/sse/13-decline.t t/endpoint/06-websocket-lifecycle.t t/endpoint/09-sse-lifecycle.t t/websocket/15-connection-cleanup.t` | C4 terminal-authority and endpoint async-hook fixture migrations: 6 files, 62 tests passed. |

One intermediate gate used a nonexistent `t/websocket/13-deny.t` path and terminated as a harness error; the correct path is `t/websocket/denial-response.t`. It is not counted as a completed gate.

Broader focused aggregate (not the repository full suite):

```sh
source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && PERL_FUTURE_NO_XS=1 prove -lr t/websocket t/sse t/response t/endpoint t/routing t/auth/04-protocol-integration.t t/integration-app-file-examples.t t/integration-websocket-chat-v2.t
```

**67 files, 532 tests, one failed subtest:** `t/routing/11-explicit-middleware.t` still called WebSocket close before accept, a stale pre-C4 refusal idiom. Its middleware assertions do not depend on refusal; the fixture now accepts/starts before closing. Every other file passed, including the complete endpoint/routing groups, legacy helper suites, response suites, and both existing example integration files. Example integration prints expected request logs to stderr.

Targeted correction and runtime example registration-order proof:

```sh
source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && PERL_FUTURE_NO_XS=1 prove -l t/websocket/16-example-cleanup.t t/websocket/15-connection-cleanup.t t/routing/11-explicit-middleware.t
```

**3 files, 18 tests passed.** The example tests invoke the actual chat/dashboard apps with connection termination during accept/welcome, asserting successful early return and dashboard cleanup rather than checking source text.

Final gate after the last runtime change (helper close return preservation):

```sh
source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && PERL_FUTURE_NO_XS=1 prove -lr t/websocket t/sse t/response/03-stream.t t/response/15-cancel-connection.t t/endpoint/06-websocket-lifecycle.t t/endpoint/09-sse-lifecycle.t t/endpoint/12-protocol-terminal.t t/routing/11-explicit-middleware.t t/auth/04-protocol-integration.t
```

**37 files, 266 tests passed**, no warning output. The earlier 67-file gate was not repeated solely for fixture changes; unchanged files retain that gate's individual passing evidence. No claim is made that the 67-file command itself was green.

Additional checks:

```sh
source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && podchecker lib/PAGI/WebSocket.pm lib/PAGI/SSE.pm lib/PAGI/Endpoint/WebSocket.pm lib/PAGI/Endpoint/SSE.pm lib/PAGI/Response/Stream.pm lib/PAGI/Response/Writer.pm
git diff --check
```

All six POD files passed; diff whitespace check passed.

## Lifetime and ordering proof

`t/websocket/15-connection-cleanup.t` drops handler/helper and close-observer references before terminal delivery, keeps only weak inspection references, parks the first hook, and drains the connection notification callbacks. Both helpers survive that handoff, keep the second hook waiting, reject late hook registration, ignore cancellation of a cleanup observer, and disappear after the parked hook completes and the explicit test-held callback arguments are released. WebSocket tests distinguish outgoing 1000/local text from peer 1001/peer text, terminal 1006/undef with no peer Close, and receive-event 1006/lifecycle text from authoritative peer metadata. Both constructor-time terminal observation and start settlement cannot resurrect active helpers.

SSE tests exercise two timer wins followed by clean end, with a receive tripwire throughout, and prove losing timers cancel while future end observation remains usable. They exercise an async on_close calling close, an unrelated later close, and an original caller still awaiting cleanup.

Stream tests park start, body, terminal-send, and cleanup stages. Public cancellation aborts once, does not cancel server send/cleanup Futures, prevents producer startup after synchronous start settlement, cancels an active owned producer, runs cleanup once, and releases weak producer/writer references after cleanup.

## Remaining concerns / boundaries

No unresolved implementation blocker. C6 owns real-socket integration, including natural close timeout/close_incomplete behavior; C7 owns the repository-wide gate. This change intentionally depends on a complete normative connection object on modern scopes. An application hook that never settles retains its cleanup resources by design. The SSE close timing rule and pre-I/O registration requirement are explicit API costs, not hidden fallback behavior.

## Review fix round 1 — committed-refusal data guards

Addressed the single P2 in `task-C5-resume-review.md` on top of parent ledger commit `b3fd210`. The nonterminal `denying`/`declining` progress states exposed a missed former implicit guard: WebSocket text/bytes/JSON sends and their boolean variants, plus all four SSE boolean sends, could issue protocol data while a committed HTTP refusal body was pending.

Added the existing `_denied`/`_declined` commitment flag to those ten public send guards. Throwing WebSocket methods now reject locally before invoking send; boolean methods return false without send/error hooks. Connection liveness and terminal cleanup ownership remain unchanged. Keepalive, ordinary SSE sends, and all other behavior are unchanged.

Parameterized regressions cover each affected method with a pending refusal-body Future, assert that only `http.response.start` and `http.response.body` reached send, preserve nonterminal connection facts, and prove terminal cleanup starts exactly once only after the connection ends.

Exact red command:

```sh
source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && PERL_FUTURE_NO_XS=1 prove -l t/websocket/15-connection-cleanup.t
```

**1 file, 22 tests: 10 failed (subtests 13–22).** Every new case failed its local-rejection/no-protocol-send assertions; existing 12 subtests passed.

Exact green covering command:

```sh
source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && PERL_FUTURE_NO_XS=1 prove -l t/websocket/15-connection-cleanup.t t/websocket/denial-response.t t/sse/13-decline.t
```

**3 files, 51 tests passed**, with no warnings. `git diff --check` passed. No aggregate/full-suite run, sibling repository mutation, push, or additional scope in this fix round.
