# Task 8 audit report

## Current status

**DEV-005 CORRECTED: independent review of the test semantics and the
authorized replacement repository suite are pending.**

AUD-001 was corrected by approved and independently reviewed DEV-004 at
`8703e77`. Fresh Phase A then passed. The one authorized repository suite
failed in `t/upgrading-routing-composition.t`, so Task 8 stopped before the
distribution build. AUD-002 was corrected by DEV-005 at `1693a8c`; independent
review follows. The controller has authorized a replacement-suite budget, but
it has not been used. No distribution build was attempted.

## Audited campaign identity

- Repository: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/.worktrees/remove-pagi-context`
- Ticket: Remove `PAGI::Context`, Task 8 final audit
- Branch: `feat/remove-pagi-context`
- Base: `9ab83b6ee512657086f42669b48e24b04e9e4864`
- Audited HEAD: `c312941211698419fa4e9e0c80aa129df63de902`
- Deployment boundary: local implementation branch only
- Push target: none
- Initial tracked status: clean
- History inspected: all 18 commits in `9ab83b6..c312941`; aggregate change is
  91 paths, 2,204 insertions, and 6,686 deletions.

The Task 8 brief, approved design, implementation plan, ledger, complete
Context-test matrix, all seven task reports, commit metadata/path history, and
the implementation diffs through the point of the finding were read before
classification.

## AUD-001 — live upgrade guide falsely attributes Context to direct Router callbacks

Classification: **ordinary defect; release blocker; live documentation and
mechanical migration accuracy.**

`UPGRADING.md:25-26` says that both class Endpoint callbacks and direct Router
callbacks received a Context wrapper before this removal. Its Before block at
`UPGRADING.md:40-43` consequently shows HTTP, WebSocket, and SSE direct Router
callbacks taking `$ctx`.

That claim is false for the campaign base:

- The approved design says normal declarative and App Router HTTP handlers
  receive `PAGI::Request`, and normal WebSocket/SSE handlers receive their
  direct protocol objects (`context-removal-design.md:100-101`).
- The same design states that the earlier request-first migration had already
  made direct protocol objects the normal Router contract
  (`context-removal-design.md:119-121`).
- At base `9ab83b6`, `lib/PAGI/Routing/Compiler.pm` constructs
  `PAGI::Request` for HTTP leaves and `PAGI::WebSocket`/`PAGI::SSE` for normal
  protocol leaves.
- Base tests independently pin those contracts, including
  `t/routing/05-http-dispatch.t` and `t/routing/08-protocols.t`.
- The implementation plan's Task 7 migration requirement is specifically for
  the HTTP, WebSocket, and SSE **Endpoint callback signatures**; it does not
  direct this campaign to present Router callbacks as a newly migrated
  Context surface.

The inaccurate block was introduced by commit `f67b322` and remained through
the two Task 7 review-fix commits. The likely root cause is a documentation
scope conflation: the new Context-removal section grouped already-direct Router
callbacks with the class Endpoint callback transition owned by this campaign.

Impact: a reader upgrading from the immediate pre-campaign API is told that a
working direct Router signature was formerly `$ctx` and changed in this
release. This makes the authoritative mechanical upgrade guide historically
and technically inaccurate and violates design §§3, 13.4, 14, and acceptance
criterion 9.

No correction is proposed or applied in this audit turn. Controller approval,
a separately recorded `DEV-NNN` exact-path ruling for `UPGRADING.md`, focused
verification, a separate fix commit, and independent review are required
before Phase A can restart.

## Initial AUD-001 stop at `c312941`: gates deliberately not run

- Changed-test focused gate: **not run** (Phase A stopped on AUD-001).
- Changed Perl syntax/POD gate: **not run**.
- Final live-surface/removal gate: **not run**.
- Repository suite `prove -lr t`: **not run; Files/Tests/time/exit unavailable**.
- `dzil build`: **not run; build exit/artifact path/size/SHA-256/entry counts unavailable**.

At that initial stop, no suite attempt, host replacement suite, `dzil build`,
or `dzil test` was invoked, preserving the Phase B budget for DEV-004's
corrected HEAD.

## Remaining concerns

Phase A is incomplete after the stop point. The remaining requirement mapping,
matrix-row reconciliation, changed-test gate, changed syntax/POD checks, exact
removal/live-surface searches, full suite, and archive inspection must all be
performed fresh after an approved and reviewed correction is present.

## DEV-004 disposition — AUD-001 corrected

The controller approved DEV-004 with exact ownership of `UPGRADING.md`,
`t/upgrading-context-removal.t`, the Task 7 report, and this audit report. The
correction removes Router callbacks from the Context-removal Before block,
limits the mechanical signature migration to class Endpoint frontends, and
records ordinary declarative/App Router Request/WebSocket/SSE signatures as
unchanged at the campaign base.

Source evidence was rechecked at both relevant bases. At Task 7 base
`0cbbf139b3a1126f3d52dba3b8a860662821deed` and Task 8 base
`9ab83b6ee512657086f42669b48e24b04e9e4864`,
`lib/PAGI/Routing/Compiler.pm` passes one `PAGI::Request` to normal HTTP
handlers and one `PAGI::WebSocket`/`PAGI::SSE` to normal protocol handlers.
The audit-base tests `t/routing/05-http-dispatch.t` and
`t/routing/08-protocols.t` separately pin those contracts.

The focused Perl 5.42.2 correction gate passes
`t/upgrading-context-removal.t` (1 file, 5 top-level subtests); all 18 Task 7
POD-bearing files pass `podchecker`. Targeted historical-scope and mandated
legacy-surface searches find no Router `$ctx` Before callback; retained Context
spellings remain labeled Before/removal evidence or negative assertions.
`git diff --check` passes.

This correction does not resume Task 8 Phase A or spend the exactly-once Phase
B suite/build budget. The full audit, suite, and distribution build remain for
the controller's fresh post-correction audit turn.

## Fresh Phase A evidence at `8703e77`

- Corrected HEAD: `8703e77c2c5b339f72777e787103467bcecf28ba`.
- History: 19 commits and 92 changed paths from `9ab83b6`; 2,351 insertions
  and 6,686 deletions.
- Worktree was tracked-clean before Phase A and before the suite.
- All four Context modules and all sixteen `t/context/*.t` files are absent
  from HEAD and the filesystem. The empty untracked `lib/PAGI/Context/`
  directory contains no file and has no Git or distribution entry.
- Matrix audit: all 192 former top-level Context subtests occur in the
  disposition matrix; all 88 `TRANSFER`/`ALREADY` owner-file/name references
  resolve in the final tree.
- Changed-test gate under Perl 5.42.2: `Files=37, Tests=397`, 6 wallclock
  seconds, exit 0.
- Changed syntax gate: 60 `.pm`/`.pl`/`.t` files, zero failures. The
  bidirectional example retains its documented base warning for the final
  native-coderef expression and reports `syntax OK`.
- Changed POD gate: 22 POD-bearing `.pm`/`.pod` files, zero failures.
- `git diff --check` passed.
- No live source loads, requires, inherits from, or constructs Context. No
  replacement `context_class`, `request_class`, `websocket_class`, or
  `sse_class` production hook exists. No new production or example dependency
  on `PAGI::Request->response` was introduced.
- Retained Context-family/path/hook/`$ctx`/`$context` search matches are
  confined to labeled **Before (removed)** migration blocks, current/historical
  removal prose, or executable negative/absence assertions. The only retained
  old ErrorHandler `($context, $error)` spelling is the labeled Before block at
  `UPGRADING.md:224`; no live handler or example uses it.

## Spec §§5–18 implementation map

| Spec | Production / retained owner | Focused evidence | Live documentation | Commit(s) |
|---|---|---|---|---|
| §5 deleted surface | Four Context modules absent; no factory/type-map/assertion/dispatcher stub | `t/00-load.t`, `t/upgrading-context-removal.t`, exact tree search | `UPGRADING.md` removed-surface inventory; current `Changes` | `cfcc50f`, `f67b322`, `763fde5`, `c312941` |
| §6 capability disposition | `PAGI::Request`, `PAGI::WebSocket`, `PAGI::SSE`; `PAGI::Routing::URL`, Stash, Session, State, CSRF, Transport | Matrix plus authority/stash/CSRF/transport/routing/WebSocket/SSE owner tests | `UPGRADING.md` direct-owner/helper tables and examples | `cfcc50f`, `1899d4d`, `9420f42`, `f67b322` |
| §7 HTTP Endpoint | `lib/PAGI/Endpoint/HTTP.pm` constructs strict Request, returns/validates Response, emits only in `to_app` | HTTP Endpoint changed tests, including sync/Future, strict scope, HEAD/OPTIONS/405, singleton and invalid returns | HTTP Endpoint POD and upgrade guide | `b0644ec` |
| §8 WebSocket Endpoint | `Endpoint/WebSocket.pm`, shared exact-scope helper in `Utils/Scope.pm`, Compiler consumer | WebSocket Endpoint lifecycle/cache/immediate/failure/disconnect tests and routing cache tests | WebSocket Endpoint POD and upgrade guide | `ed2412c`, `ecc862e` |
| §9 SSE Endpoint | `Endpoint/SSE.pm` and shared exact-scope helper | SSE lifecycle/cache/keepalive/decline/immediate/failure/disconnect tests | SSE Endpoint POD and upgrade guide | `7fc987a` |
| §10 ErrorHandler | `Middleware/ErrorHandler.pm` constructs Request, validates `respond` + `status_try`, applies fallback after return | `error-handler-contract.t`, Pages composition, Compose middleware | ErrorHandler/Pages/Compose POD and `UPGRADING.md` | `82f5bd6`, `40756f0`, `f67b322`, `763fde5` |
| §11 Pages and scope-source consumers | Pages and helper modules retain structural scope-source ownership; `Request->response` remains temporary | Pages, helper, scope-source, request and transport changed tests | Module POD plus compatibility warning in Request/upgrade guide | `cfcc50f`, `1899d4d`, `f67b322` |
| §12 before/after examples | Direct Request/WebSocket/SSE and Response APIs in executable examples | `t/upgrading-context-removal.t`, `t/integration-app-file-examples.t` | Primary mechanical blocks in `UPGRADING.md` | `1511d4d`, `f67b322`, `763fde5`, `c312941`, `8703e77` |
| §13 test migration | Sixteen Context tests deleted only after owner matrix/coverage transfer | 192/192 former subtests classified; 88/88 retained-owner references resolved | Matrix and Task 5 report | `cfcc50f`, `1899d4d`, `9420f42` |
| §14 docs and examples | Endpoint demo and bidirectional WebSocket use direct objects; public POD reconciled | Example integration, upgrade tests, Cookbook source sync in repository suite before AUD-002 | README, examples READMEs, Tutorial, Cookbook, current Changes, upgrade guide | `1511d4d`, `f67b322`, `763fde5`, `c312941`, `8703e77` |
| §15 non-goals | Current Response `respond($send)` and `Request->response` retained; raw/middleware triplets and topology unchanged; no replacement hooks | Endpoint middleware/frontend tests, response tests, upgrade assertions | Design boundary repeated in Changes/upgrade/POD | Campaign aggregate; no Response-family implementation commit |
| §16 constraints | Direct constructors remain strict; awaitable boundaries use `Future->wrap`; sync disconnect deviations are explicit | Changed gate plus DEV-001/002 regression tests and syntax/POD gates | Ledger and task reports | `b0644ec` through `8703e77` |
| §17 adversarial resolutions | Coverage owners, fixed direct classes, post-return status, exact-scope caches, separate Response campaign | Matrix, ErrorHandler status tests, protocol cache tests, upgrade tests | Approved design and mechanical upgrade guide | Task-specific commits above |
| §18 acceptance | Criteria 1–10 and exact-removal criterion 13 pass Phase A | Focused gate/searches above | Public migration contract corrected by DEV-004 | `8703e77`; criterion 11 failed in Phase B and criterion 12 was not attempted |

## Sole repository-suite invocation

Command under project Perl 5.42.2:

```sh
perlbrew exec --with perl-5.42.2@default prove -lr t
```

Exact result: **FAIL**, `Files=208, Tests=2220`, 38 wallclock seconds
(`0.72 usr 0.36 sys + 29.27 cusr 4.28 csys = 34.63 CPU`), process exit 1.

The documented `t/request/multipart-stream-e2e.t` `RELEASE_TESTING` skip was
the only skip. One ordinary test failed:

```text
t/upgrading-routing-composition.t
Failed test: Router Compose and Context have no retired evidence channel
Cannot read lib/PAGI/Context.pm: No such file or directory
at t/upgrading-routing-composition.t line 578
```

This is not a sandbox/socket failure, so no host-access replacement suite was
authorized or run.

## AUD-002 — unchanged integration test opens the intentionally deleted modules

Classification: **ordinary defect; release blocker; cross-task test
integration.**

`t/upgrading-routing-composition.t:553-587` inventories Router, Compose, and
the four former Context module paths, then unconditionally opens every path to
search it for older retired routing evidence. Context removal at `cfcc50f`
deleted those four files, so the first deleted path dies at line 578 before
the source assertions can run.

The test itself is byte-identical to base `9ab83b6`; its inventory was added by
pre-campaign commit `f585511`. The defect is the unreviewed interaction between
that existing source-inspection test and Task 5's intentional module deletion.
The final live search exposed the path literals, but they were incorrectly
classified as absence evidence; unlike `t/upgrading-context-removal.t`, this
test does not use `-e` and instead requires the files to exist.

At this failed-attempt stop, no fix had been applied. The controller still
needed to approve an exact test path, focused RED/GREEN evidence, independent
review, and a ruling on the consumed suite budget. DEV-005 below records the
subsequent correction; this paragraph remains the chronology of the original
AUD-002 stop.

## Distribution build

`dzil build` was **not run**. Build exit, artifact path, size, SHA-256, entry
counts, metadata comparison, archive integrity, and exclusion checks are
therefore unavailable. `dzil test` was not run.

## DEV-005 disposition — AUD-002 corrected

The controller approved DEV-005 with exact ownership of
`t/upgrading-routing-composition.t` and the Task 7/8 evidence reports. The
focused Perl 5.42.2 RED reproduced the sole-suite failure: 1 file, 10 top-level
subtests, final subtest failed when its unconditional source scan opened the
deleted `lib/PAGI/Context.pm`.

The correction separates the test's two contracts. It continues opening and
checking all seven live Router/Compose sources for the retired routing evidence
channel, while the four former Context paths are now asserted absent with no
compatibility source. No routing-composition assertion was removed. The
focused GREEN passes 1 file and 10 top-level subtests; its final subtest has 60
passing assertions (56 retained source checks plus 4 Context absence checks).

Adjacent verification under Perl 5.42.2 passes
`t/upgrading-routing-composition.t`, `t/upgrading-context-removal.t`, and
`t/upgrading-router-frontends.t`: 3 files, 35 top-level tests. The changed test
passes `perl -Ilib -c`, and `git diff --check` passes.

Per the DEV-005 boundary, no second repository suite, distribution build,
`dzil test`, host replacement, or push was run. Independent review of the
corrected test semantics is pending/following. The controller has authorized
one replacement repository-suite budget, but it remains unused; Task 8 stays
gated before the build until that review and replacement-suite result.
