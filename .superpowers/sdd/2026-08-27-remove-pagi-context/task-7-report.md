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

## Retained mandated-search matches

Every final match is removal evidence, not live guidance:

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
