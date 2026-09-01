# SDD ledger — plan: docs/superpowers/plans/2026-09-01-compose-routes-and-explicit-router-mounting.md

Spec: docs/superpowers/specs/2026-09-01-compose-routes-and-explicit-router-mounting-design.md
Repository: /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools
Ticket: none
Branch: feature/compose-retained-router
Execution start: 9d67fb16c55817999894ae3aeb32bdcc10d8a002
Corrective spec base: 037e22f4b2901b730060cec9114d3372efccc0b3
Main at execution start: 558b14c282a38051bd8c1bb712290fe1df398330
Origin/main at execution start: 558b14c282a38051bd8c1bb712290fe1df398330
Deployment boundary: unreleased PAGI-Tools distribution
Push target: origin/feature/compose-retained-router after authorization

Baseline: `perlbrew exec --with perl-5.42.2@default prove -lr t` — Files=224, Tests=2459, Result=PASS.

| Task | Status | Implementation commit | Tests | Evidence |
| --- | --- | --- | --- | --- |
| 1. Compose constructor | complete | e4a0216370de8fd4d056fbb98b0c6fddaf48836f | 1 file, 55 tests PASS; syntax OK | TDD red: 6/56 failed under old constructor; green: 55/55; task review found no Critical or Important issues |
| 2. Root Mount contract | complete | 6809879763b80e5de6f0876585546d569b7a0a44 | 3 files, 32 tests PASS | Characterization passed without production changes; task review approved with no findings |
| 3. Lifecycle and safety | complete | 5a799d0 | 7 files, 118 tests PASS | Compiler and ResponseGuard unchanged; task review approved with no findings |
| 4. Router frontends | complete | e177809, c45c155 | 5 files, 54 tests PASS | Inspectable/opaque frontend boundaries covered; task review approved with no findings |
| 5. Declarative examples | in progress | — | — | — |
| 6. Class-based examples | pending | — | — | — |
| 7. Public documentation | pending | — | — | — |
| 8. Final verification | pending | — | — | — |

## Preflight interface scan

| Task(s) | Producer / consumer or internal check | Finding and ruling |
| --- | --- | --- |
| 1 | Internal: new description tests versus routes-only constructor code | Consistent. Tests fail under the retained-Router mode and pass after minimal constructor removal. |
| 2 | Internal: root-Mount characterization versus existing Router/Mount compiler | Consistent after explicitly adding `use PAGI::Pages ();` to the task requirements; the brief's fixture invokes that class but omitted its import sentence. Ruling: the implementer adds that import — required for the specified fixture, no API cost if wrong. |
| 3 | Internal: fixture migration versus unchanged lifecycle/safety wrappers | Consistent. Compiler and ResponseGuard are verification-only unless evidence contradicts the spec. |
| 4 | Internal: frontend snapshots versus explicit Mount | Consistent. Direct `to_app` tests remain bare, while Compose tests mount immutable snapshots. |
| 5 | Internal: declarative examples versus direct Compose routes | Consistent. Apples remains unchanged structurally; focused example tests are exact. |
| 6 | Internal: class examples versus root Mount | Consistent. The plan forbids flattening and names all current affected example/test files. |
| 7 | Internal: public docs versus implemented contract | Consistent. Generated README is changed only through its documented source/generator. |
| 8 | Internal: final checks versus test-frequency rule | Consistent with one qualification. Ruling: the final source-tree `prove -lr t` and built-distribution `dzil test` are distinct verification boundaries, not accidental repeated fixture-cleanup runs; cost if wrong is runtime only, not semantic change. |
| 1 → 2 | Task 1 produces routes-only Compose; Task 2 consumes it for root Mount | Consistent. |
| 1 → 3 | Constructor removal feeds migration of all Compose test fixtures | Consistent; Task 3 must not reintroduce a local production compatibility path. |
| 1 → 7 | Runtime option names feed Compose POD and diagnostics | Consistent; exact diagnostics originate in Task 1. |
| 2 → 3 | Root-Mount preservation feeds lifecycle/middleware/HEAD fixtures | Consistent; inspectable child Router object is mounted, not its compiled coderef. |
| 2 → 4 | Root Mount and outer Resolver feed frontend snapshot tests | Consistent. |
| 2 → 6 | Root-Mount contract feeds class-based example migration | Consistent. |
| 2 → 7 | Root path/name/outcome rules feed public Mount documentation | Consistent. |
| 3 → 6 | Lifecycle and safety ordering feed modular example verification | Consistent. |
| 3 → 8 | Compose focused suite feeds integrated safety gate | Consistent. |
| 4 → 6 | Frontend snapshot contract feeds Endpoint/App Router examples | Consistent. |
| 4 → 7 | Frontend POD and upgrading tests are revisited by public-doc task | Sequential edits are intentional; Task 7 owns final terminology consistency. |
| 4 → 8 | Frontend tests feed integrated gate | Consistent. |
| 5 → 6 | Both tasks may touch `t/integration-maintained-examples-load.t` | Sequential and consistent: Task 5 commits declarative changes before Task 6 adds class-example changes. |
| 5 → 7 | Example README wording feeds root public narrative | Consistent; Task 7 audits rather than reverses example-specific explanations. |
| 5 → 8 | Declarative canary feeds final integration | Consistent. |
| 6 → 7 | Class-example README wording feeds public migration guide | Consistent. |
| 6 → 8 | Class examples feed final integration | Consistent. |
| 7 → 8 | Public docs and generated README feed stale-surface/package checks | Consistent. |
| 4 → 6 → 7 | `t/00-pod/cookbook-examples.t` is shared | Sequential ownership is explicit; each task commits its own required expectation changes. |

## Process rulings

Ruling: use the execution skill's canonical workspace `.superpowers/sdd/2026-09-01-compose-routes-and-explicit-router-mounting/`, not the plan's shorter shorthand `.superpowers/sdd/2026-09-01-compose-routes-explicit-mount/` — the skill-generated path is how recovery tools locate this plan; cost if wrong is only a different tracking path.

Ruling: the controller initializes and commits the ledger before Task 1 dispatch, instead of asking the Task 1 implementer to create it — the execution skill requires preflight rows before dispatch; cost if wrong is commit sequencing only.

Ruling: retain the force-added progress ledger as the campaign audit at finish and delete only untracked report/review artifacts — the approved spec and plan require committed task rows and evidence; cost if wrong is one tracked audit file remaining in the repository.

Task 4 Ruling: its required `t/upgrading-routing-composition.t` gate and expected PASS depend on two live documents assigned broadly to Task 7. Move the minimal matching `UPGRADING.md` recipes, `$routing->routes` policy-loss warning, and Compose POD retired-constructor text into Task 4, then leave Task 7 responsible for the complete public-doc audit — this preserves a green task boundary; cost if wrong is that Task 7 revisits two files already touched here.

## Deviations

None.

## Task review record

Task 1: minor (deferred): `t/compose/01-description.t` verifies stable root Router identity after routing delegates but does not repeat the identity assertion after `middleware` and `lifespan`; those accessors are independently exercised on another Compose instance. Point the final whole-branch review at this item.

Task 1: complete (commits f57e831..e4a0216, spec compliant; no Critical/Important findings; one deferred minor).

Task 2: complete (commits f713cce..6809879, review clean).

Task 3: complete (commits 7619b0f..5a799d0, review clean).

Task 4: complete (commits 08f198f..c45c155, review clean after controller boundary ruling).
