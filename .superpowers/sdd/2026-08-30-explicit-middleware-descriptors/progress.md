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
| 3. Router frontend sugar | complete | `108bf48c53745d1dfdb4335266f482b2f5345725` | 5 files / 52 tests | Characterization and stale-expectation migration GREEN; task review clean |
| 4. Builder naming | complete | `020336f8c64a3e7a427a9f59f7ee35ab413c20a7` | 3-file combined gate / 17 tests PASS after Task 5 | Code review approved; sequencing dependency resolved |
| 5. Examples and docs | complete | `f1566eefd9e6152bee3873693d7103b3dc78c81b`, fix `374b9769d1df1824b27b536d8b3bd2c6a339f473` | Integration/POD: 3 files / 52 tests; compiles and POD syntax clean | Fix round 1 resolved both important findings |
| 6. Upgrade and verification | complete | `56a4b396f56f1258f6ab818cdf60eda1c23a8418`, fix `7ca500abb6acbad3c3901b4e81993d165adc5707` | Focused: 48 files / 440 tests; source suite: 218 files / 2372 tests; fix gate: 3 files / 35 tests | Task review approved after one focused wording fix; built-distribution failures reproduced on clean baseline |

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

Task 3: complete (commits b1b8d95..108bf48, review clean). The reviewer noted
that the implementer did not edit the ledger; the controller's standing
ledger-ownership ruling resolves that operational item in this tracking
commit.

Ruling: Task 4's Builder implementation is approved, but its required combined
POD command cannot pass until Task 5 migrates the Cookbook's bare core Route
factory. Task 5 explicitly owns that file and migration, so expanding Task 4
would duplicate scope. Keep Task 4 open, execute Task 5, rerun Task 4's exact
combined command, then close both gates. Cost if wrong: task completion order
temporarily differs from the plan, but no downstream production behavior is
built on an unreviewed Builder change.

Task 4: important (sequencing): `t/00-pod/cookbook-examples.t` fails at its
representative bare Route factory until Task 5 migrates the Cookbook.

Task 4: minor (deferred to Task 5): `PAGI::Routing` still advertises retired
`^` and bare core entries.

Task 5: fix round 1/5 (2 addressed, 0 open — callable-shape table and Builder
frontend distinction; commits f1566ee..374b976).

Task 5: minor (deferred to final whole-branch review): Compose's short summary
says the target of `middleware(...)` receives the inner app, while the detailed
text correctly distinguishes class construction, factory invocation, and
object `wrap`.

Task 4: complete (implementation commit 020336f; code review approved; the
Task 5 migration made its exact combined gate pass 3 files / 17 tests).

Task 5: complete (commits fe8bad8..374b976, review clean after fix round 1).

Task 6: fix round 1/5 (1 addressed, 0 open — UPGRADING now distinguishes
App/Endpoint Router core-description materialization from Middleware Builder's
separate records and `to_app` construction/wrapping; commits 56a4b39..7ca500a).

Ruling: Task 6's source and focused gates are green, but `dzil test` remains
red because the built distribution omits shared chat assets and `README.md`.
Both failures reproduce on clean `main@045eae3`, and this campaign changes
neither the packaging configuration nor those inputs, so they are recorded as
pre-existing release concerns rather than campaign regressions. Cost if wrong:
the feature branch could still inherit unrelated release blockers and must not
be described as distribution-clean until those packaging issues are resolved
or explicitly accepted.

Task 6: complete (commits 56a4b39..7ca500a, review approved after fix round 1).

Final review: fix wave 1/1 addressed all five findings: stale core examples and
claims in `UPGRADING.md`, the declarative-routing README wording, the missing
Middleware Builder `^` to `+` migration example, the overgeneralized Compose
summary, and blessed-coderef factory classification. The production fix was
developed RED then GREEN and the combined gate passed 13 files / 243 tests.
Scoped re-review passed 2 files / 39 tests and approved commits
`8ff156f828af87d51981f5d82ad0014ec690d9e7` and
`eb696cccc0946cc9dd43540e9964f5525fd90c76` with no new breakage.
