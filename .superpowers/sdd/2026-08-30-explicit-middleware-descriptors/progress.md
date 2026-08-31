# SDD ledger — plan: docs/superpowers/plans/2026-08-30-explicit-middleware-descriptors.md

## Work map

| Repository | Ticket | Branch | Base | Owned changes | Deployment boundary | Push target |
|---|---|---|---|---|---|---|
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/.worktrees/explicit-middleware-descriptors` | none | `feature/explicit-middleware-descriptors` | `main@045eae3fc973e0bbca67aa804d834f588ec5087c` | Middleware descriptions; core constructors; router/builder frontend normalization; live tests, examples, POD, README, Changes, and UPGRADING | PAGI-Tools distribution only; PAGI and PAGI::Server are read-only | `origin/feature/explicit-middleware-descriptors` after review and verification |

Baseline: Perl 5.42.2; `prove -lr t` passed 218 files / 2373 tests at `b2bfb00`.

## Task status

| Task | Status | Implementation commit | Tests | Evidence |
|---|---|---|---|---|
| 1. Explicit descriptor | complete | `24098f5757a06bf37c3b54bb0f1bb695a2ad9e09` | 3 files / 29 tests | RED captured; focused GREEN; task review approved with one deferred POD minor |
| 2. Strict core lists | complete | `982dfd41e7fbe46fa9cf65e6db7d120b968816cf` | 10 files / 148 tests | RED captured; focused GREEN; task review clean |
| 3. Router frontend sugar | in progress | — | — | — |
| 4. Builder naming | pending | — | — | — |
| 5. Examples and docs | pending | — | — | — |
| 6. Upgrade and verification | pending | — | — | — |

## Preflight consistency scan

| Tasks/interface | Producer and consumer relationship | Finding |
|---|---|---|
| Task 1 | Tests describe class, factory, object, and invalid-result behavior before the implementation described in the same task. | Consistent. |
| Task 2 | Rejection/copy tests precede strict constructor validation; the renamed test and Compose HEAD migration are both named in files and commands. | Consistent. |
| Task 3 | Frontend tests precede replacing calls to the retired core normalizer. | Consistent. |
| Task 4 | Naming tests precede the resolver and POD change. | Consistent. |
| Task 5 | The known live example list matches the pre-plan inventory; integration and compile commands cover those examples without broad staging. | Consistent. |
| Task 6 | Focused, full, distribution, hygiene, and scope gates precede the final evidence record. | Consistent. |
| Tasks 1 → 2: `PAGI::Routing::Middleware` | Task 1 expands descriptor targets/results; Task 2 splits strict validation from frontend coercion without changing `_wrap`. | Consistent; Task 2 consumes Task 1's contract. |
| Tasks 1 → 5: descriptor POD | Task 1 changes behavior; Task 5 publishes the complete user explanation. | Consistent. |
| Tasks 1 → 6: `Changes` | Task 1 records the implementation; Task 6 consolidates it into one BREAKING release bullet. | Consistent; Task 6 edits rather than duplicates the Task 1 entry. |
| Tasks 2 → 3: normalization interface | Task 2 creates `_normalize_frontend_entries`; Task 3 makes App/Endpoint frontends its only concise-list consumers. | Consistent and load-bearing. |
| Tasks 2 → 5: strict core declarations | Task 2 changes constructor acceptance; Task 5 updates live declarative examples and prose. | Consistent. |
| Tasks 2 → 6: upgrade path | Task 2 removes core coercion; Task 6 documents the before/after contract. | Consistent. |
| Tasks 3 → 5: frontend POD | Task 3 preserves sugar; Task 5 explains that it is frontend-only and materializes descriptions. | Consistent. |
| Tasks 3 → 6: frontend migration | Task 3 preserves concise forms; Task 6 explicitly exempts those frontends from the core breaking change. | Consistent. |
| Tasks 4 → 5: `Tutorial.pod` | Task 4 replaces `^` with `+`; Task 5 incorporates that naming into the broader middleware explanation. | Consistent. |
| Tasks 4 → 6: package-name migration | Task 4 changes live behavior; Task 6 records exact before/after syntax. | Consistent. |
| Tasks 5 → 6: public documentation | Task 5 updates current usage; Task 6 adds migration/release framing and validates the complete surface. | Consistent. |

## Deviations and rulings

Ruling: Under the approved subagent-driven workflow, the controller owns and
commits the execution ledger; task implementers skip the plan's ledger-editing
and ledger-commit substeps. This preserves one authoritative recovery record
and keeps implementer diffs task-scoped. Cost if wrong: git history uses one
controller tracking commit per review gate rather than the plan's suggested
implementer-local evidence commit, while retaining the same SHAs and evidence.

Task 1: minor (deferred to Task 5 documentation pass):
`PAGI::Routing::Middleware` POD says an explicit descriptor is required only
for class configuration, but configured factories now require it too.

Task 1: complete (commits df22b8f..24098f5, spec compliant and quality
approved; one documentation minor deferred).

Task 2: complete (commits 72b3f06..982dfd4, review clean). The reviewer
confirmed the App Router Builder call-site rename was the minimal dependency
adjustment required by the private helper split, not premature Task 3 work.

Ruling: Task 3's predicted RED is stale because Task 2 necessarily switched
the three App Router Builder call sites to `_normalize_frontend_entries` when
the old private helper was removed. Task 3 will add focused regression and
materialization evidence; it must not manufacture a failure or make unrelated
production edits if the approved behavior already passes. Cost if wrong: Task
3 may be a tests-only commit, but the behavior remains guarded and the Task 2
review already verified the production seam.
