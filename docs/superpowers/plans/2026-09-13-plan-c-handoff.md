# Plan C handoff (PAGI-Tools) — for the session that opened the auth work

Written 2026-09-13 by the session that ran Plans A and B and the PAGI-Server
hardening chunks. Everything below is a fact recorded in
`docs/superpowers/plans/2026-09-08-universal-connection-tracking.md` or in
PAGI-Server's SDD ledger; nothing here is a guess.

## Where things stand

- PAGI spec: main at 103ad3c (sub-spec 0.6, core 0.5). The pushed tag
  `v0.002009` (81d4ac3) is behind main; `dzil release` is held by John
  until the server PR is merged. Spec sentences added since the tag that
  Plan C must honour: every pending receive resolves at disconnect
  (plural); a receive after `websocket.disconnect` / `sse.disconnect`
  re-delivers it; a receive after a completed refusal or the application's
  own `sse.close` resolves with the scope's end (`sse.disconnect` with NO
  reason on an sse scope; `http.disconnect` after a WebSocket refusal); a
  server MAY bound such re-deliveries (PAGI::Server: `max_disconnect_receives`,
  default 100, 0 = unbounded); a receive resolved by the application's own
  terminal send may resume inside that send.
- PAGI-Server: PR #19 (https://github.com/jjn1056/PAGI-Server/pull/19),
  branch feature/www-0.6-universal-connection, awaiting John's review;
  0.002014 unreleased; requires Net::HTTP2::nghttp2 0.011 (on CPAN).
  Compliance.pod "PAGI Specification Rulings" is the list of server choices
  where the spec leaves room; read it before assuming behaviour.
- The original Plan C brief:
  `docs/superpowers/plans/2026-09-08-universal-connection-C-pagi-tools.md`
  (handlers send the terminal event for the app; Stream calls abort on
  cancel; state read via the connection object's predicates, not flags).

## Additions to Plan C found this week (measured against PAGI-Tools at HEAD)

1. `lib/PAGI/SSE.pm:683` and `:902` do `$event->{reason} // 'client_closed'`:
   after `$sse->close(reason => 'job_complete')` with `run()` waiting,
   `disconnect_reason` and `on_close` report `client_closed`. An absent
   reason means a clean end the application produced; do not fabricate a
   token.
2. `lib/PAGI/WebSocket.pm:635` matches only `websocket.disconnect`: after a
   refused handshake, `receive` returns the `http.disconnect` hashref as an
   application message and `receive_text` spins to the cap. Treat
   `http.disconnect` on a websocket scope as the end.
3. `lib/PAGI/Test/SSE.pm` parks forever after one synthesized disconnect and
   fabricates `client_closed` after `sse.close`; it cannot reproduce 1 or
   2. Mirror the server: resolve with the reasonless event; model the cap
   if it models re-delivery.
4. Body readers on an sse scope (Request.pm, FormBody, JSONBody,
   MultiPartHandler, Middleware buffer_request_body): verify they stop on a
   reasonless `sse.disconnect` (most guard `last unless $event && $event->{type}`;
   `buffer_request_body` branches on type alone and would spin -- http-only
   today, latent).
5. Any Tools code that calls receive after a disconnect event must stay
   well under `max_disconnect_receives` or document setting it.
6. Cookbook: the app-owned upload limit pattern for streaming endpoints
   that accept unknown-length bodies (enforce a per-route limit while
   reading, report in-band, then `$conn->abort`), since `max_body_size` on
   the server ends the scope with `body_too_large` once the response has
   started (PAGI::Server `max_body_size` POD describes it).

## Rules John set this week that bind Plan C

- Tests pin the spec as written, a Compliance.pod ruling, or a documented
  safety deviation; never incidental behaviour.
- Hardening is best effort (production runs behind Envoy/nginx); no
  mechanism, no special case, no performance cost for a hardening item.
- Found problems go on a ledger for John; no side work, no optional extras
  in fix rounds; a fix round that needs a new mechanism backs up to the
  last reviewed commit instead of stacking.
- Perl only via `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && <cmd>'`;
  the Bash tool's foreground ceiling is 600 s, so long suites run in
  pieces, never in the background.
