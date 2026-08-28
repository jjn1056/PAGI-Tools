# Task 8 audit report

## Current status

**PASS — Task 8 release-evidence audit is complete at reviewed HEAD
`97af8b6`; no release action was performed.**

AUD-001 was corrected by approved and independently reviewed DEV-004 at
`8703e77`. Fresh Phase A then passed. The original repository suite exposed
AUD-002 in `t/upgrading-routing-composition.t` and stopped before the build.
AUD-002 was corrected by DEV-005 at `1693a8c`, independently approved, and its
chronology finalized at `97af8b6`. The controller authorized exactly one
replacement repository suite on that corrected candidate. It passed, after
which exactly one `dzil build` passed and the resulting archive passed the
content, metadata, integrity, and exclusion audit. The build-generated root
README change was restored exactly.

## Audited campaign identity

- Repository: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/.worktrees/remove-pagi-context`
- Ticket: Remove `PAGI::Context`, Task 8 final audit
- Branch: `feat/remove-pagi-context`
- Base: `9ab83b6ee512657086f42669b48e24b04e9e4864`
- Audited HEAD: `97af8b6de19ffb97dee72960835b1525ab5975f1`
- Deployment boundary: local implementation branch only
- Push target: none
- Initial tracked status: clean
- History inspected: all 21 commits in `9ab83b6..97af8b6`; aggregate change is
  93 paths, 2,507 insertions, and 6,687 deletions.

The Task 8 brief, approved design, implementation plan, ledger, complete
Context-test matrix, all seven task reports, commit metadata/path history, and
the complete base-to-HEAD implementation history were read before
classification and rechecked after both approved corrections.

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

No known release blocker remains within this campaign's audited scope. The
usual operational actions remain intentionally outside Task 8: no push, merge,
tag, publication, release, or worktree/artifact deletion was performed. The
ignored build directory and archive remain available for controller inspection.

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
| §18 acceptance | Criteria 1–10 and exact-removal criterion 13 pass Phase A; criterion 11 passes the authorized corrected-candidate suite and criterion 12 passes the single build/archive audit | Focused gate/searches, both preserved suite attempts, and build evidence below | Public migration contract corrected by DEV-004 | `97af8b6`; all acceptance evidence complete |

## Original failed repository-suite invocation

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

## Distribution build at the AUD-002 stop

`dzil build` was **not run at this stop**. The single build budget remained
unused until the approved DEV-005 corrected candidate passed its replacement
suite. `dzil test` was not run.

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

Per the initial DEV-005 boundary, no second repository suite, distribution
build, `dzil test`, host replacement, or push was run during the correction.
Independent review subsequently approved the corrected test semantics. At
reviewed HEAD `97af8b6`, narrow preflight confirmed that only the approved
DEV-005 test/evidence commits followed `8703e77`, the range diff check passed,
and the tracked worktree was clean. The controller then
explicitly authorized the one replacement repository suite recorded below.

## Authorized replacement repository suite

Command under project Perl 5.42.2:

```sh
perlbrew exec --with perl-5.42.2@default prove -lr t
```

Exact result: **PASS**, `Files=208, Tests=2220`, 35 wallclock seconds
(`0.68 usr 0.31 sys + 28.36 cusr 4.07 csys = 33.42 CPU`), process exit 0.

The documented `t/request/multipart-stream-e2e.t` `RELEASE_TESTING` skip was
the only skip. This was the one controller-authorized replacement for the
preserved failed 208/2220 attempt above. It ran in the normal sandbox because
there was no socket-only restriction, so no host-access replacement was used.
No further repository suite was run.

## Single distribution build and archive audit

After the replacement suite passed and a clean-status preflight confirmed
HEAD `97af8b6`, exactly this command ran once under project Perl 5.42.2:

```sh
perlbrew exec --with perl-5.42.2@default dzil build
```

Exact result: **PASS**, process exit 0, 8.008 seconds observed wall time. It
built `PAGI-Tools-0.002002/` and `PAGI-Tools-0.002002.tar.gz`. `dzil test` was
not run.

Archive evidence:

- Size: 884,013 bytes.
- SHA-256:
  `ec5e12d5a3fb6957ee5b55da913af940509e5fdaacc281eb1553ee739cd07866`.
- `gzip -t` passed. The archive has 517 entries: 424 regular files and 93
  directories, totaling 3,714,141 uncompressed file bytes; it has zero
  symlinks, hardlinks, other entry types, or duplicate full paths.
- The archive MANIFEST has 424 file entries and exactly matches the 424
  archived files: zero missing and zero unmanifested files.
- All 69 surviving release paths changed by this campaign are present. The
  four changed `.superpowers` evidence paths are intentionally pruned. All 20
  deleted campaign paths (four Context modules and sixteen Context tests) are
  absent. No `.git`, `.superpowers`, `docs`, `CLAUDE.md`, task/review/ledger
  evidence, `lib/PAGI/Context.pm`, `lib/PAGI/Context/*`, or `t/context/*`
  entry is present.
- `META.json` and `META.yml` agree on name `PAGI-Tools` and version
  `0.002002`; release status is `stable`, and metadata records Perl v5.42.2 as
  the generator runtime. `dist.ini` and `cpanfile` are unchanged from base.
- Generated prerequisites match those unchanged inputs: 1 configure require,
  7 develop requires, 3 runtime recommends, 9 runtime requires, and 5 test
  requires. Runtime requires are `Cookie::Baker` 0.11, `Future` 0.50,
  `Future::AsyncAwait` 0.66, `HTTP::Date` 6.06,
  `HTTP::MultiPartParser` 0.02, `Hash::MultiValue` 0.16,
  `IO::Compress::Gzip` 0, `JSON::MaybeXS` 1.004003, and Perl 5.018.

`ReadmeAnyFromPod` rewrote root `README.md` during the build, as configured.
The audit restored it with `apply_patch`; its post-restore Git blob
`cb5513e6fc8852b783b1f7f287df0d7fee72924c` exactly matches the pre-build and
HEAD blob. The tracked worktree was clean again before this report and ignored
ledger were updated. The build directory and archive remain ignored and were
not deleted.

## Final disposition

Task 8 is **PASS / complete for release evidence** at
`97af8b6de19ffb97dee72960835b1525ab5975f1`. Phase A, the corrected-candidate
repository suite, and the single distribution build/archive audit all pass.
The original failed suite remains separately preserved as AUD-002 chronology.
No push, merge, tag, release, publication, host replacement, deletion, or
additional suite/build invocation occurred.
