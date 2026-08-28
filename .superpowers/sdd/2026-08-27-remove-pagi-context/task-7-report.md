# Task 7 report: publish the breaking migration contract

## Work map

- Repository: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/.worktrees/remove-pagi-context`
- Ticket: Task 7, remove PAGI Context
- Branch: `feat/remove-pagi-context`
- Base: `0cbbf139b3a1126f3d52dba3b8a860662821deed`
- Owned changes: the Task 7 documentation and upgrade-test files listed in `task-7-brief.md`, plus this report
- Deployment boundary: public documentation and executable upgrade coverage; no runtime compatibility layer
- Push target: none

## Initial characterization and documentation RED

The first bare `prove` invocation selected system Perl 5.34 and failed before
test collection because project dependencies such as `Future` were absent. It
was not treated as a behavior characterization. Under the required
`perl-5.42.2@default`, the three upgrade files were initially green: 3 files,
29 tests, zero failures. This is the expected Tasks 1-6 runtime characterization.

The mandated live-surface search was RED before documentation edits. It found
stale compatibility guidance in README, current Changes, UPGRADING, Tutorial,
Cookbook, module POD/comments, Response examples, and the ErrorHandler upgrade
example. The Cookbook's complete apples block also differed from the runnable
`examples/starlette-apples/app.pl`, the approved DEV-003 mismatch.

## Published contract

- Added executable coverage for absent Context files/hooks, one working direct
  Request/WebSocket/SSE callback each, `stash($sse)`, and ErrorHandler's
  Request callback plus explicit-status precedence.
- Added the prominent no-backcompat upgrade section with exact protocol
  signatures, direct Response construction, imported helper ownership,
  status-aware ErrorHandler behavior, removed factory/assertion/type-map/raw/
  dispatcher surfaces, custom-protocol ownership, native triplet retention,
  the blessed-State HashRef warning, and synchronous disconnect hooks.
- Reconciled README, current Changes, and all listed public POD. Generic event
  dispatcher recipes were deleted rather than translated into a replacement
  abstraction. `PAGI::Request->response` is documented only as temporary
  compatibility for this release.
- Resolved DEV-003 by synchronizing the Cookbook apples block with the runnable
  source, including the SPA file route and `/welcome` page.

## Verification

- `perlbrew exec --with perl-5.42.2@default prove -lv t/upgrading-context-removal.t t/upgrading-request-first-handlers.t t/upgrading-router-frontends.t t/endpoint-router.t t/00-pod/cookbook-examples.t` — pass; 5 files, 44 tests.
- `perlbrew exec --with perl-5.42.2@default perl -Ilib -c` for all 18 changed POD-bearing files — pass.
- `perlbrew exec --with perl-5.42.2@default podchecker` for all 18 changed POD-bearing files — pass.
- `t/00-pod/cookbook-examples.t` confirms the apples block is byte-identical to the runnable source after removal of its shebang.
- `git diff --check` — pass.
- No full suite was run, per the Task 7 boundary.

## Retained mandated-search matches at the original Task 7 commit

This was the search classification recorded at commit
`f67b32244b4f71e7ed1170d40e4939c5c4649144`. Fix round 1 below supersedes its
UPGRADING line numbers and corrects the former-surface classifications.

- `UPGRADING.md:82` — removed response-shortcut Before example.
- `UPGRADING.md:83` — removed seeded-status Before example.
- `UPGRADING.md:84` — removed seeded-response Before example.
- `UPGRADING.md:110` — removed URL-helper Before example.
- `UPGRADING.md:111` — removed stash-method Before example.
- `UPGRADING.md:112` — removed session-method Before example.
- `UPGRADING.md:113` — removed state-method Before example.
- `UPGRADING.md:114` — removed response-shortcut Before example.
- `UPGRADING.md:115` — removed CSRF-method Before example.
- `UPGRADING.md:116` — removed transport-flow Before example.
- `UPGRADING.md:169` — removed ErrorHandler renderer Before example.
- `UPGRADING.md:199` — removed Endpoint factory Before example.
- `UPGRADING.md:200` — removed type-map Before example.
- `UPGRADING.md:201` — removed protocol-assertion Before example.
- `UPGRADING.md:202` — removed raw-send Before example.
- `UPGRADING.md:203` — removed raw-receive Before example.
- `UPGRADING.md:204` — removed dispatcher-registration Before example.
- `UPGRADING.md:205` — removed dispatcher-run Before example.
- `UPGRADING.md:1595` — older labeled Before explanation for the removed Endpoint hook.
- `UPGRADING.md:1599` — older labeled Before code for the removed Endpoint hook.
- `t/endpoint-router.t:311` — executable absence assertion over legacy Endpoint methods.
- `t/integration-app-file-examples.t:69` — negative regex asserting generated examples contain no removed syntax.
- `t/integration-app-file-examples.t:129` — negative regex asserting the bidirectional example contains no removed syntax.
- `t/upgrading-router-frontends.t:1018` — executable absence assertion for the Endpoint hook.
- `t/upgrading-router-frontends.t:1019` — diagnostic text for that absence assertion.
- `t/upgrading-context-removal.t:25` — HTTP Endpoint hook absence assertion.
- `t/upgrading-context-removal.t:26` — diagnostic text for the HTTP assertion.
- `t/upgrading-context-removal.t:27` — WebSocket Endpoint hook absence assertion.
- `t/upgrading-context-removal.t:28` — diagnostic text for the WebSocket assertion.
- `t/upgrading-context-removal.t:29` — SSE Endpoint hook absence assertion.
- `t/upgrading-context-removal.t:30` — diagnostic text for the SSE assertion.
- `t/endpoint/01-http-constructor.t:42` — subtest naming the removed hook contract.
- `t/endpoint/01-http-constructor.t:43` — base HTTP Endpoint absence assertion.
- `t/endpoint/01-http-constructor.t:44` — diagnostic text for the base assertion.
- `t/endpoint/01-http-constructor.t:50` — subclass absence assertion.
- `t/endpoint/01-http-constructor.t:51` — diagnostic text for the subclass assertion.

## Scope and handoff

The controller owns the ledger and independent documentation/spec and technical
review coordination. No ledger, runtime implementation, historical design
document, push, merge, tag, or release was performed.

## Fix round 1: exact former HTTP surface

The primary migration was checked against the source immediately before
removal (`git show cfcc50f^:lib/PAGI/Context/HTTP.pm` and
`git show cfcc50f^:lib/PAGI/Context.pm`). `PAGI::Context::HTTP` added the
cached `request`/`req` and `response`/`resp` accessors, guarded `respond`,
`method`, and exactly four response-construction shortcuts: `text`, `html`,
`json`, and `redirect`. `status_try`, `empty`, `send`, `send_raw`, `stream`,
`writer`, and `send_file` belonged to `PAGI::Response`, not Context. The base
Context exposed the raw channel as `receive` and `raw_send`; it had no
`raw_receive` method. Extension types overrode `_type_map`; there was no
`register_type` API.

`UPGRADING.md` now presents only source-backed Before examples and direct
Response/Request migrations for that surface. The three later ErrorHandler
examples now use `($request, $error)` and pass Request to Pages. The stale
statement deferring Context removal was replaced with the shipped no-backcompat
contract. `Changes` now distinguishes the removed cached Response/guarded send
from the retained Response-level `status_try`. The upgrade test executes all
four direct Response factories.

## Fix round 1: broadened live-doc classification

The final public-doc search covered `README.md`, `UPGRADING.md`, `Changes`,
`lib`, and `examples` for `$context`, `PAGI Context`, `Context removal`, the
old `($context, $error)` callback, and broader `Context` references.

- `UPGRADING.md:185-186` is the only retained `$context`/old-callback match;
  it is inside the explicitly labeled **Before (removed)** ErrorHandler block.
- Exact phrases `PAGI Context` and `Context removal` have no live matches.
- `Changes:103` is the current breaking-removal entry. `Changes:510`, `:534`,
  and `:625` are immutable release history describing the former facade.
- `UPGRADING.md:15-247` is the authoritative removal contract; its executable
  legacy spellings occur only in labeled Before blocks. `UPGRADING.md:1099`,
  `:1163`, and `:1289` explain shipped removal in later migration sections.
  `UPGRADING.md:1624-1628` is another explicitly labeled Before block.
- `examples/endpoint-router-demo/README.md:109` and
  `examples/15-large-application/GAPS.md:10` explain why current examples no
  longer hide capabilities on Context; neither teaches a Context API.
- The mandated narrow search's test matches remain executable negative
  assertions listed above. Its UPGRADING line numbers moved in this fix:
  direct-response Before lines 78 and 86-93, helper Before lines 127-133,
  ErrorHandler Before line 186, extension Before lines 216 and 226-232, and
  the older Endpoint-hook Before lines 1624 and 1628.

The broader search found no stale `($context, $error)` callback in an After
block or live module POD/example, and no prose that defers Context removal.

## Fix round 1 verification

- Required Perl 5.42.2 focused gate: `t/upgrading-context-removal.t`,
  `t/upgrading-request-first-handlers.t`, `t/upgrading-router-frontends.t`, and
  `t/00-pod/cookbook-examples.t` pass; 4 files, 34 tests.
- All 18 Task 7 POD-bearing files pass `perl -Ilib -c` under Perl 5.42.2 and
  pass `podchecker`.
- The broadened live-doc searches and the original mandated narrow search were
  rerun after the corrections; retained matches are classified above.
- `git diff --check` passes. No full suite was run.
