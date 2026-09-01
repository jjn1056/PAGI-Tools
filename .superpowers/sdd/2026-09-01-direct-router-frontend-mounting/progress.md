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
| 2. App Router examples | complete | 8ddb014544be465ebbbd3d9245209b30089b18bc | 4 files, 54 tests | Four focused integration commands: PASS |
| 3. Endpoint Router example | complete | c954880272f59e8f583287db56c0e08807e8e4ef | 1 file, 35 tests | `perlbrew exec --with perl-5.42.2@default prove -lv t/integration-endpoint-router-demo.t`: PASS; see `task-3-report.md` |
| 4. Public documentation | complete | e82cf15c5c0c1726db9a37083a2d7bbc684d4274, 777b041 | 3 files, 36 top-level tests; review fix: 2 files, 14 top-level tests | `perlbrew exec --with perl-5.42.2@default prove -lv t/upgrading-routing-composition.t t/upgrading-router-frontends.t t/00-pod/cookbook-examples.t`: PASS; no-archive Dist::Zilla build regenerated and matched README; focused review-fix tests: PASS |
| 5. Final verification | complete | ddd661d6c04e16327e4f8ca36cd34163ccdd4aea, 0ff30ba | focused: 32 files, 232 tests; full: 224 files, 2,464 tests | Both suites PASS at `ddd661d`; one documented release-only skip, zero failures; distribution build and archive inspection PASS; final review found no Critical or Important issues; occurrence-count correction re-review clean |

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
- Ruling: Final whole-campaign review used execution-start commit `f5f7c92` as its base rather than `origin/main`, because this corrective plan began on an already reviewed feature branch and owns only the 17 commits after that point. Cost if wrong: an interaction introduced earlier on the feature branch could fall outside this review; prior campaign reviews plus the integrated focused suite, complete suite, and archive inspection cover that risk.
- Ruling: The complete suite was not rerun after commits that changed only the pruned `.superpowers` audit report and ledger. The tested product, tests, examples, and distribution inputs remain exactly those at `ddd661d`, and archive inspection confirmed `.superpowers` is excluded. Cost if wrong: an unexpected distribution-configuration change could make those records load-bearing, but no such change occurred and the inspected archive excludes them.

## Review log

- Task 1: fix round 1/5 (1 addressed, 0 open — added the exact planning-base work-map field; commit 5de9ffc).
- Task 1: complete (commits f5f7c92..5de9ffc, review clean).
- Task 2: complete (commits 1c46eb0..219a6e8, review clean).
- Task 3: complete (commits 2d3cbea..7de261a, review clean).
- Task 2: complete (implementation commit 8ddb014; four focused integration files pass, review clean).
- Task 3: complete (implementation commit c954880; focused Endpoint integration passes, review clean).
- Task 4: complete (implementation commit e82cf15; focused public-document tests and generated README comparison pass, self-review clean).
- Task 4: fix round 1/5 (2 Important documentation gaps and regression coverage addressed; commit 777b041; 0 open).
- Task 4: scoped re-review complete (commit 777b041; 2 files, 14 top-level tests; clean).
- Task 5: complete (implementation/audit commit ddd661d; focused suite 32 files/232 tests PASS; full suite 224 files/2,464 tests PASS; distribution archive verified).
- Final whole-campaign review: 0 Critical, 0 Important, 1 Minor audit-count wording issue.
- Final review fix round 1/1: corrected 130 matching lines versus 132 literal occurrences in commit 0ff30ba; scoped re-review clean; 0 open.

## Retained user-facing `to_router` inventory

- `examples/endpoint-router-demo/lib/MyApp/Main.pm` converts API because Main's
  `home` handler resolves `/api/index`; the parent must discover API's named
  descendants.
- `examples/endpoint-router-demo/lib/MyApp/API.pm` converts Events so the API
  snapshot publishes `/api/events/stream`; the README and integration test
  exercise that inspectable nested boundary.
- `lib/PAGI/Compose.pm`, `lib/PAGI/App/Router.pm`, and
  `lib/PAGI/Endpoint/Router.pm` retain parent/child examples in which the parent
  calls `path_for` on a converted child's slash-addressed name. App Router's
  `named_routes`, `route_named`, and `path_for`, and both frontend `to_app`
  implementations also use `to_router` as their documented snapshot or
  compilation primitive.
- `lib/PAGI/Tools/Cookbook.pod` retains an App Router parent-discovery example,
  a deliberately retained snapshot used for `path_for`, and an Endpoint parent
  that resolves child names. `lib/PAGI/Tools/Tutorial.pod` mentions conversion
  only for reverse discovery or coherent retained inspection.
- `UPGRADING.md` retains two explicitly labelled historical `compose(router
  => ...)` examples, their stable-snapshot replacements, one nested
  parent-discovery migration, and one coherent inspection snapshot used for
  `route_named`, `path_for`, and `to_app`.
- The remaining hits under `t/` are subject construction, snapshot identity,
  materialization/cycle/constraint/middleware tests, parent-name discovery, or
  source-regression assertions. They are not public deployment guidance.

Task 5 audit: 130 matching lines across 32 live files, containing 132 literal
`->to_router` occurrences, were classified. Categories 1--5 account for every
occurrence; category 6 (stale deployment ceremony) has zero hits. The three
flattening-search hits are explicitly labelled lossy examples
in `PAGI::Compose`, `PAGI::Routing::Mount`, and `UPGRADING.md`.

## Task 5 work-map reconfirmation

- Repository: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/.worktrees/compose-retained-router`
- Branch: `feature/compose-retained-router`
- Verification-start HEAD: `05b2dd5354080970a41c7689a294a54049f112e7`
- `main`: `558b14c282a38051bd8c1bb712290fe1df398330`
- `origin/main`: `558b14c282a38051bd8c1bb712290fe1df398330`
- Push target before any authorized publish:
  `origin/feature/compose-retained-router` at
  `8dea8d0f3b21212d6a58b1b729a962e597eefb89`
- Worktree was clean at verification start. No sibling repository is in scope.

## Task 5 verification evidence

- Integrated focused suite at `ddd661d6c04e16327e4f8ca36cd34163ccdd4aea`:
  `perlbrew exec --with perl-5.42.2@default prove -lr t/app-router.t
  t/app-router t/endpoint-router.t t/endpoint
  t/integration-router-application-boundaries.t
  t/integration-maintained-examples-load.t
  t/integration-app-file-examples.t t/integration-chat-compose.t
  t/integration-endpoint-router-demo.t t/upgrading-routing-composition.t
  t/upgrading-router-frontends.t t/00-pod` — PASS, 32 files, 232 tests,
  7 wallclock seconds (6.94 CPU seconds).
- Complete suite run exactly once at the same candidate HEAD:
  `perlbrew exec --with perl-5.42.2@default prove -lr t` — PASS, 224
  files, 2,464 tests, 47 wallclock seconds (42.77 CPU seconds), zero
  failures, and one documented skip (`t/request/multipart-stream-e2e.t`
  requires `RELEASE_TESTING=1`). No test warning was reported.
- `perlbrew exec --with perl-5.42.2@default dzil build` — PASS without
  running tests. It produced `PAGI-Tools-0.002002.tar.gz`: 1,013,774 bytes,
  563 entries, SHA-256
  `5e7793d963ce998f813cc57c247d99647b07e7d196dfdd1517b53a5435562234`.
  The archive README matches the tracked README; required POD, upgrade,
  Changes, tests, and affected example READMEs are present; `docs/superpowers`,
  `.superpowers`, VCS metadata, and untracked build debris are absent. The
  only `blib` path is the tracked `t/app-path-fixtures/blib` source fixture.
  Dist::Zilla emitted existing `PkgVersion` layout advisories but completed
  successfully.
- `git diff --check` passed and the build left tracked files unchanged. The
  worktree was clean immediately after archive inspection.

## Deviations

None.
