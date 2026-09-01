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
| 5. Declarative examples | complete | 1e6ff71 | 4 files, 43 tests PASS; 3 syntax checks PASS | Apples stayed direct; declarative-routing retained only its configured `/api` Router boundary; Pages folded its disposable root into Compose; task review approved with one ledger-only follow-up completed here |
| 6. Class-based examples | complete | 9c876e0, 4148ab0 | 7 files, 64 tests PASS; 6 syntax checks PASS; fix gate 1 file, 30 tests PASS | Migrated background-tasks, endpoint-demo, endpoint-router-demo, full-demo, 10-chat-showcase, and 15-large-application through unnamed root Mounts; task review approved after one fix round |
| 7. Public documentation | complete | 829fdc0, 4107830 | 3 files, 36 tests PASS; 11 POD syntax checks PASS; fix gate 1 file, 10 tests PASS | Routes-only contract, four-way composition comparison, six upgrade recipes, generated README idempotence, and example ownership wording reviewed clean after one fix round |
| 8. Final verification | complete | 9e73882, c51dba1 | focused 33 files/380 tests PASS; full 224 files/2455 tests PASS; `dzil test` 224/2455 PASS; final fix 2 files/69 tests PASS | README idempotent, stale positive constructor count zero, task review and whole-branch review approved after one evidence round and one final fix wave |

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

Task 5 Ruling: `t/integration-maintained-examples-load.t` is a shared discovery test whose only current failure is the still-unmigrated `examples/full-demo/app.pl`, explicitly owned by Task 6. Accept Task 5's three owned integration files plus all discovered cookbook coverage as its green gate, carry the shared discovery test into Task 6, and do not partially migrate a class-based example in the declarative-example task — this keeps architectural ownership coherent; cost if wrong is a temporary red shared integration file between two consecutive campaign commits.

## Deviations

None.

## Task review record

Task 1: minor (resolved in final fix wave): `t/compose/01-description.t` now verifies stable root Router identity after the `middleware` and `lifespan` accessors on the same Compose instance.

Task 1: complete (commits f57e831..e4a0216, spec compliant; no Critical/Important findings; one deferred minor later resolved in the final fix wave).

Task 2: complete (commits f713cce..6809879, review clean).

Task 3: complete (commits 7619b0f..5a799d0, review clean).

Task 4: complete (commits 08f198f..c45c155, review clean after controller boundary ruling).

Task 5 audit: `starlette-apples` is the direct Compose-routes canary and remained structurally direct; `declarative-routing` had a disposable outer root but retained its intentionally configured `/api` child Router through Mount; `pages` had a disposable outer root and moved its direct nodes and lifespan into Compose. No migration flattened a Router through `$router->routes`.

Task 5: complete (commits f1b3b7f..1e6ff71, spec compliant; no Critical/Important findings; reviewer ledger-only follow-up completed in tracking commit).

Task 6 inventory: all 14 positive `compose(router => ...)` occurrences under `examples/` were prebuilt-Router preservation cases spanning background-tasks, endpoint-demo, endpoint-router-demo, full-demo, 10-chat-showcase, and 15-large-application code/README material. Each now uses an unnamed `mount('/' => app => ...)`; no example flattens through `$router->routes`.

Task 6: fix round 1/5 (2 addressed, 0 open — canonical Test Client now proves terminal WebSocket miss denial; chat fallback comment names the HTTP catchall Route; commits 9c876e0..4148ab0).

Task 6: complete (commits 69b0e43..4148ab0, review clean after fix round 1).

Task 7: README generator evidence — `perlbrew exec --with perl-5.42.2@default dzil build --no-tgz --in /private/tmp/pagi-tools-readme-task7-pass1`, followed by the same command targeting `pass2`; both exited 0 and the second pass preserved README SHA-256 `6a580036526b308df7ed87c9b11d8b2f8c01a6d344a7235d15e296810a3be89b`.

Task 7: stale-surface evidence — no live `compose(router => ...)` usage remains in `lib`, generated `README.md`, `Changes`, or `examples`; six `UPGRADING.md` hits are deliberately labeled removed Before forms. The upgrade guide covers direct declarations, immutable Router preservation, App Router snapshot, Endpoint Router snapshot, bare Router deployment, and intentional lossy flattening.

Task 7: fix round 1/5 (1 addressed, 0 open — example READMEs now assign child Router retention to the unnamed root Mount, and the public-doc guard covers both; commits 829fdc0..4107830).

Task 7: complete (commits bf73d42..4107830, review clean after fix round 1).

Task 8 Ruling: the verification worker owns Steps 1–5 and reports any attributable failure without spawning a reviewer or closing the ledger. The controller then performs the required task review and the execution skill's single broad whole-branch review, dispatches at most one final fix wave if needed, and closes the ledger only after that review evidence exists — this reconciles the plan's review requirement with the no-subagents worker contract and prevents duplicate final reviews; cost if wrong is process sequencing only, not product behavior.

Task 8: final mapping — branch `feature/compose-retained-router`; product/documentation candidate `c51dba14feb935d5c203dfaf9f49b3face1a8a44`; `main` and `origin/main` both `558b14c282a38051bd8c1bb712290fe1df398330`; no push, merge, rebase, or sibling-repository mutation.

Task 8: integrated evidence — exact focused aggregate PASS (`Files=33, Tests=380`); one complete source-tree run PASS (`Files=224, Tests=2455`); `perlbrew exec --with perl-5.42.2@default dzil test` PASS (`Files=224, Tests=2455`); generated README produced no diff; `git diff --check` clean; positive live `compose(router => ...)` count zero. The remaining search hits are six labeled Before examples in `UPGRADING.md` and two negative rejection tests.

Task 8: attributable verification fix — `9e73882` aligned the rejected `router` diagnostic with the canonical `mount('/' => app => $router)` spelling; targeted `t/compose/01-description.t` PASS (55 tests before final assertions).

Task 8: evidence fix round 1/5 (1 addressed, 0 open — exact final focused aggregate rerun at `9e73882`, 33 files/380 tests PASS; no product commit).

Final whole-branch review: one Important documentation finding and the deferred Task 1 Minor were fixed together in `c51dba1`; the four mutable App Router READMEs now snapshot through `to_router`, reserve `$snapshot->routes` for deliberate lossy flattening, and explain direct frontend mounting as valid but opaque. Scoped final re-review approved with no new breakage; fresh final fix gate PASS (`Files=2, Tests=69`) under Perl 5.42.2.

Task 8: complete (commits 7fa091b..c51dba1, task review clean after evidence round 1; whole-branch review approved after one final fix wave).

## Campaign closure

- Final product/documentation candidate: `c51dba14feb935d5c203dfaf9f49b3face1a8a44`.
- Unapproved deviations: 0.
- Live positive `compose(router => ...)` uses: 0.
- Branch has not been pushed or merged.
