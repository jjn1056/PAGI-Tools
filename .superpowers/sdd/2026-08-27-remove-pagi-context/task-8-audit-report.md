# Task 8 audit report — halted in Phase A

## Status

**BLOCKED: ordinary release-blocking live-documentation defect found.**

Per Task 8 Step 2 and the controller's Phase A gate, the audit stopped before
the changed-test/syntax/POD gate, repository-wide suite, and distribution
build. No production, test, example, or live-documentation fix was applied.
The ledger was not modified.

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

## Gates deliberately not run

- Changed-test focused gate: **not run** (Phase A stopped on AUD-001).
- Changed Perl syntax/POD gate: **not run**.
- Final live-surface/removal gate: **not run**.
- Repository suite `prove -lr t`: **not run; Files/Tests/time/exit unavailable**.
- `dzil build`: **not run; build exit/artifact path/size/SHA-256/entry counts unavailable**.

No suite attempt, host replacement suite, `dzil build`, or `dzil test` was
invoked, preserving the exactly-once Phase B budget for a clean audited HEAD.

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
