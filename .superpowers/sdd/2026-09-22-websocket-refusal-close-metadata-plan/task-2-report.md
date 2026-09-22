# Task 2 report: WebSocket refusal close metadata

## Result

`PAGI::Test::ConnectionState` now records `close_code = 1006` and an
undefined `close_reason` when a WebSocket scope completes without a supplied
peer Close. The existing connected guard, deferred notification behavior, and
terminal publication order remain unchanged.

The public-path regression uses `PAGI::Test::Client` and `PAGI::WebSocket` to
verify that a successfully delivered HTTP refusal is a clean completion:
`on_complete` and `on_end` see `1006`, `on_close` receives
`(1006, undef, undef)`, `on_disconnect` does not run, and the HTTP response
remains intact. `PAGI::Test::WebSocket->close_code` remains its separate
wire-Close record and is still undefined for an HTTP refusal.

The POD beside `deny` now explains the local metadata and includes the
connection-observer example. The close-accessor section links back to `deny`.

## TDD evidence

### Red

Ran before changing `lib/PAGI/Test/ConnectionState.pm`:

```sh
perlbrew exec --with perl-5.40.0@default prove -lv t/test/client-ws-lifecycle.t t/websocket/deny-close-code.t t/websocket/15-connection-cleanup.t t/test/connection-state.t
```

Result: failed as expected. The refusal regressions and the clean WebSocket
completion control observed `undef` where `1006` is required. Existing peer
Close and abnormal-end assertions passed.

### Green

Ran after the state-settlement change:

```sh
perlbrew exec --with perl-5.40.0@default prove -lv t/test/connection-state.t t/test/client-ws-lifecycle.t t/test/client-terminal-outcomes.t t/test/client-sse-decline.t t/websocket/deny-close-code.t t/websocket/15-connection-cleanup.t t/protocol-refusal-applications.t
perlbrew exec --with perl-5.40.0@default podchecker lib/PAGI/WebSocket.pm
```

Result: the focused suite passed: 7 files, 108 tests, result `PASS`.
`podchecker` reported `lib/PAGI/WebSocket.pm pod syntax OK`.

## Review

- `git diff --check` passed.
- The only production behavior change is the clean WebSocket completion
  normalization in `PAGI::Test::ConnectionState::_mark_complete`.
- Existing supplied peer metadata remains authoritative; non-WebSocket clean
  completion remains undefined; late completion after an abnormal end remains
  abnormal and does not re-notify observers.
- No production helper fallback, API, flag, timer, or Server dependency was
  added.

## Concern

`t/websocket/15-connection-cleanup.t` emits pre-existing “lost a sequence
Future” diagnostics during its passing run. The focused suite still exits
successfully; this task does not change that cleanup machinery.
