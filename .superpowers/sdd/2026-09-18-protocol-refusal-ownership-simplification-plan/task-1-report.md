# Task 1 report

## Result

Buffered `PAGI::Response` send Futures are isolated from caller cancellation
with `without_cancel` at both response-start and response-body awaits. A
cancelled invocation stops subsequent emission while the already-submitted
server send remains owned by the server. Normal send failures still propagate.

## TDD evidence

RED command:

```text
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -lv t/response/16-buffered-cancel-send.t
```

RED output: the test ran 7 subtests and failed 6 cancellation subtests. All
six failures were the expected `server owns its submitted send` assertion;
the pending send Future was cancelled. The send-failure subtest passed.

GREEN command:

```text
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -lv t/response/16-buffered-cancel-send.t
```

GREEN output:

```text
All tests successful.
Files=1, Tests=7, 0 wallclock secs
Result: PASS
```

Focused gate:

```text
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -lr t/response t/pages
```

Focused gate output: all 14 files and 364 tests passed.

## Files

- `lib/PAGI/Response.pm`: add `without_cancel` to the two existing buffered
  send awaits and document cancellation ownership in `to_app` POD.
- `t/response/16-buffered-cancel-send.t`: public `invoke_app` regression for
  pending start/body sends on HTTP, WebSocket, and SSE scopes, plus send
  failure propagation.
- `.superpowers/sdd/2026-09-18-protocol-refusal-ownership-simplification-plan/task-1-report.md`:
  this report.

## Self-review

The implementation changes only the two existing buffered send awaits. It
adds no retained worker, response-wide shield, abort call, cancellation
signal, receive watcher, or lifecycle framework. The regression uses public
`Response`/`to_app` normalization through `invoke_app` and preserves the
original scope and callbacks. `git diff --check` passes. Unrelated dirty and
untracked files remain untouched.

Commit: `fix: isolate buffered Response sends from caller cancellation`.
