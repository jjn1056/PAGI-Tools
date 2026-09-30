# C4 resume report

## Outcome

Ordinary HTTP refusal events now flow directly from concrete `PAGI::Response`
instances on the original WebSocket or SSE scope. The protocol-response bridge,
capability token, WebSocket extension fallback, and pre-accept helper close are
removed. Routing misses on WebSocket and SSE scopes emit an ordinary HTTP 404.

## Files

- Production: `lib/PAGI/Response.pm`, `lib/PAGI/Response/{File,File/Plan,NDJSON}.pm`,
  `lib/PAGI/{WebSocket,SSE}.pm`, and `lib/PAGI/Routing/Compiler.pm`.
- Tests: focused WebSocket, SSE, routing, response, Auth, chat-compose, and real
  SSE integration fixtures listed in the C4 resume brief.
- `File/Plan.pm` is the private preflight component used by `File.pm`; its
  scope guard had to accept the same supported Response scopes for direct File
  refusal to work without cloning the scope.

## Red/green evidence

- Red: `prove -l t/websocket/deny-close-code.t` failed both subtests (2/2) on
  the obsolete policy-close fallback and permitted pre-accept `close()`.
- Migration red: the first 11-file focused run failed 10 WebSocket denial,
  7 SSE decline, 6 routing protocol, 1 router-mount, 1 HTTP-outcome, and 5 Auth
  subtests, plus the removed NDJSON capability call. These failures identified
  the bridge assumptions being replaced.
- Green focused gate: 38 files, 313 tests passed with project Perl 5.42.2 and
  `PERL_FUTURE_NO_XS=1`.
- Green real server smoke: 1 file, 1 top-level test passed against the Server
  feature checkout; the wire response was HTTP 404. The smoke now gates on the
  public terminal connection API and asserts advertised Www 0.6 plus the
  required public terminal methods, so source-checkout version lag cannot
  silently skip it.
- `git diff --check` passed.

## Migration details

- Non-buffered refusals, including File, synchronously require
  `pagi.connection`; WebSocket File refusal uses status 403.
- Test fixtures publish response-start and clean completion only after their
  corresponding sends succeed. Pending and failed sends remain uncommitted.
- SSE clean refusal no longer synthesizes a `declined` disconnect reason.
- Explicit obsolete-event rejection coverage in send validation was retained.
- C5 lifecycle observer and handler-return cleanup changes were not included.

## Concerns

The existing close-callback implementation is intentionally retained for C5.
No full-suite or top-level test run was performed, per the focused-gate brief.

## Review fix round 1

- Repaired `direct_protocol` so its connection object publishes response start
  and clean completion only after the corresponding send Future succeeds.
  Focused assertions cover failed, pending, start-settled, and fully completed
  boundaries.
- Gave every successful WebSocket refusal fixture a legal status of at least
  300, including Empty, scope-identity, inherited Stream, backpressure, and
  cancellation paths. The response matrix also asserts the status boundary.
- Red evidence: the two-file gate failed 2 Auth subtests because successful
  sends left connection state inert, and the WebSocket matrix failed for Text,
  HTML, JSON, Empty, and Stream statuses.
- Green command:
  `bash -c 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && PERL_FUTURE_NO_XS=1 prove -l t/auth/04-protocol-integration.t t/websocket/denial-response.t'`
  passed 2 files and 19 top-level tests.
