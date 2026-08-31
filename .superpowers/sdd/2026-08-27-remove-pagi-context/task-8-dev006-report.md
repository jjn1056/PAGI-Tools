# DEV-006 — Endpoint protocol adapter coverage

Base/head before this correction: `74b5ef6`.

## Scope

- `t/endpoint/06-websocket-lifecycle.t` now drives real compiled WebSocket
  apps through text, bytes, and JSON frames, verifies decoded `on_receive`
  values, and verifies the no-`on_connect` automatic accept path.
- `t/endpoint/07-websocket-to-app.t` and `t/endpoint/09-sse-lifecycle.t` each
  invoke one compiled app twice and retain both observed Endpoint objects to
  prove per-connection Endpoint construction.
- No production source or Context compatibility surface changed.

## Verification

Under Perl `5.42.2@default`:

```sh
perlbrew exec --with perl-5.42.2@default prove -lv \
  t/endpoint/06-websocket-lifecycle.t \
  t/endpoint/07-websocket-to-app.t \
  t/endpoint/09-sse-lifecycle.t
```

Final result: `PASS`, `Files=3`, `Tests=18`, exit `0`.

Mutation evidence: temporarily changed the expected text, bytes, and JSON
payloads, expected default event from `websocket.accept` to
`websocket.close`, and each fresh-instance `isnt` assertion to `is`. The same
focused command failed all six added behavior checks (three adapter payloads,
automatic accept, WebSocket fresh instance, SSE fresh instance); expectations
were restored before the final green run.
