# Task 6 report: migrate executable examples

Base: `9420f42f14e9eb857c815aaf1acc9fad6373d1a8`

## Delivered

- Migrated `endpoint-demo` from Context callbacks to direct `PAGI::Request`,
  `PAGI::WebSocket`, and `PAGI::SSE` callbacks. HTTP responses now use
  `PAGI::Response`, and SSE subscriber state uses `PAGI::Stash::stash`.
- Migrated `websocket-bidirectional` to one direct `PAGI::WebSocket` created
  from the native scope/receive/send triplet while preserving its serialized
  send queue, `each_text`, `send_text_if_connected`, `is_connected`, and
  `Future->wait_any` behavior.
- Updated the two example READMEs and the examples index to describe the direct
  protocol objects. Added focused executable-example integration coverage.

## Test-first evidence

- RED: `prove -lv t/integration-app-file-examples.t` failed on the expected
  Context reach-through and direct-callback assertions before the migration.
- GREEN: the same gate passes under Perl `5.42.2`: 11 top-level subtests,
  including endpoint static serving, negotiated 415, message list, and JSON
  create/201 behavior.

## Verification

- `perl -Ilib -c examples/endpoint-demo/app.pl` — pass.
- `perl -Ilib -c examples/websocket-bidirectional/app.pl` — pass; retains the
  pre-existing compile warning for its final native-coderef `$app;` return.
- `prove -lv t/integration-starlette-apples.t` — pass; confirms the Starlette
  README Perl copy remains byte-identical to its executable source.
- `git diff --check` — pass.
- No Context token or Context-era reach-through remains in the Task 6 example
  sources or READMEs.

## Existing unrelated source-sync failure

`t/00-pod/cookbook-examples.t` still reports that the Cookbook apples block is
not identical to `examples/starlette-apples/app.pl`. The Cookbook, apples
source, and this test have no diff from the supplied base, so this is outside
Task 6 and was left unchanged.

## Scope and handoff

Only the six Task 6 files plus this required report are changed. The controller
owns the ledger and review coordination; no ledger entry was edited here.
