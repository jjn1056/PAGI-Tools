# SDD ledger — plan: docs/superpowers/plans/2026-09-01-direct-router-frontend-mounting.md

Spec: docs/superpowers/specs/2026-09-01-direct-router-frontend-mounting-design.md
Repository: /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/.worktrees/compose-retained-router
Ticket: none
Branch: feature/compose-retained-router
Approved-spec commit: f03b78226f836cb631bb24d9c46b9baa086cf274
Planning base: f03b78226f836cb631bb24d9c46b9baa086cf274
Execution-start HEAD: f5f7c92efbb50e05d507e256d686b6ef3ad9f3e8
Planning-time main/origin-main: 558b14c282a38051bd8c1bb712290fe1df398330
Deployment boundary: unreleased PAGI-Tools distribution
Push target: origin/feature/compose-retained-router after authorization

| Task | Status | Implementation commit | Tests | Evidence |
| --- | --- | --- | --- | --- |
| 1. Characterize contract | complete | 5fb3bbac3ec0f9473fdf1aeb34318559ebd2cee7 | 3 files, 35 tests | `perlbrew exec --with perl-5.42.2@default prove -lv t/app-router.t t/upgrading-router-frontends.t t/integration-router-application-boundaries.t`: PASS |
| 2. App Router examples | in progress | — | — | — |
| 3. Endpoint Router example | pending | — | — | — |
| 4. Public documentation | pending | — | — | — |
| 5. Final verification | pending | — | — | — |

## Preflight dependency scan

| Tasks/interface | Producer and consumer | Finding |
| --- | --- | --- |
| Task 1 internal | Characterization tests describe existing direct-mount runtime; no runtime implementation step follows | Consistent. Tests are characterization and are expected to pass immediately. |
| Task 2 internal | Source-shape assertions fail before five direct-mount substitutions and pass after them | Consistent. Live behavior tests remain unchanged. |
| Task 3 internal | Root `$main` assertion fails before migration; nested API/Events snapshot assertions already pass | Consistent. The task changes only the root boundary. |
| Task 4 internal | Public-doc tests fail against snapshot-first prose, then the authoritative POD and generated README change together | Consistent. README generation is explicit. |
| Task 5 internal | Audit consumes all prior commits and runs the only complete suite | Consistent. No second full-suite or `dzil test` instruction exists. |
| Tasks 1 → 2: `t/integration-router-application-boundaries.t` | Task 1 renames the generic object-boundary subtest; Task 2 adds reusable source reading and example assertions | Compatible; Task 2 consumes the renamed test without changing its application contract. |
| Tasks 1 → 4: `t/upgrading-router-frontends.t` | Task 1 pins direct Endpoint identity; Task 4 retains it while changing public-doc expectations | Compatible; behavioral proof remains stable while prose assertions evolve. |
| Tasks 1 → 3: direct Endpoint application contract | Task 1 proves direct Endpoint dispatch; Task 3 applies it to the demo root | Compatible and load-bearing. |
| Tasks 2 → 4: App Router example READMEs | Task 2 rewrites example-local explanations; Task 4's public-doc test requires that final form | Compatible; Task 4 validates rather than rewrites those READMEs. |
| Tasks 2 → 5: App Router live examples | Task 2 produces direct roots; Task 5 inventories remaining `to_router` uses and reruns integrations | Compatible. |
| Tasks 3 → 4: Endpoint Router README and source | Task 3 produces the mixed direct-root/inspectable-child model; Task 4 documents it in public POD | Compatible. |
| Tasks 3 → 5: nested discovery | Task 3 preserves nested conversions; Task 5 must classify them as retained user-facing uses | Compatible. |
| Tasks 4 → 5: public docs and generated README | Task 4 synchronizes live guidance; Task 5 searches, tests, and packages it | Compatible. |

## Rulings

- Ruling: The controller created the plan-specific ledger before Task 1 because the SDD skill requires recovery metadata before dispatch. Task 1 will verify and commit it rather than create it from scratch. Cost if wrong: Task 1's first procedural step differs from the plan wording, but the committed file content and audit guarantees are stronger and no product behavior changes.

## Retained user-facing `to_router` inventory

Pending final classification in Task 5.

## Deviations

None.
