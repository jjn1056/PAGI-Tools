# SDD ledger — plan: docs/superpowers/plans/2026-08-30-route-final-contract-cleanup.md

## Work map

| Repository | Ticket | Branch | Base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | none; PR #25 follow-up | `feature/application-valued-route-endpoints` | `main@8ffe0af3a4f59bc9ae0ef233375a7a0bd966484c` | Route diagnostics, Route/Mount constraints inspection, Route/spec documentation, focused tests, execution evidence | PAGI-Tools only; no deployment or release | `origin/feature/application-valued-route-endpoints`, only after explicit user approval |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI` | reference only | released `main` | PAGI 0.002007 | none | read-only normative reference | none |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server` | reference only | released `main` | PAGI::Server 0.002011 | none | read-only integration reference | none |

Current execution checkout: primary repository checkout at `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools`, explicitly placed on the feature branch by the user. Existing untracked `.pagi-*`, `.superpowers/brainstorm/`, and unrelated `.superpowers/plans/` files are user/session work and are not owned by this plan.

Final work-map reconciliation: local `main` remains at the campaign design base `8ffe0af`, while `origin/main` is the older released/alignment line at `e4b2683`; `origin/feature/application-valued-route-endpoints` is the already-reviewed campaign head `b317342`. This cleanup owns only `b317342..HEAD` and still targets the existing remote feature branch. The repository/architecture/deployment scope is unchanged.

## Preflight conflict scan

| Tasks/interfaces | Producer and consumer | Finding / ruling |
| --- | --- | --- |
| Task 1 ↔ Task 2: `lib/PAGI/Routing/Route.pm`, `t/routing/01-constructors.t`, `Changes` | Task 1 changes only method normalization diagnostics; Task 2 later changes only constraint storage/accessors and their tests/docs. | Clean. Task 2 must begin from Task 1's reviewed commit and preserve the single origin-aware method normalizer unchanged. |
| Task 1 ↔ Task 3: `lib/PAGI/Routing/Route.pm` | Task 1 changes executable method normalization; Task 3 changes `to_app` POD only. | Clean. Task 3 must not alter method behavior while editing the same file. |
| Task 1 ↔ Task 4: method diagnostics and focused tests | Task 1 produces placement-specific diagnostics; Task 4 searches and verifies both diagnostic classes. | Clean. Task 4 consumes the exact messages committed by Task 1. |
| Task 2 ↔ Task 3: `lib/PAGI/Routing/Route.pm` POD | Task 2 documents constraint accessor shape; Task 3 documents standalone compilation and classification. | Clean. The POD subjects are distinct; Task 3 must preserve Task 2's accessor documentation. |
| Task 2 ↔ Task 4: constraint accessor contract | Task 2 removes `_has_constraints` and produces defensive hashrefs; Task 4 searches for the retired flag and verifies focused routing behavior. | Clean. Router's `constraints => undef` remains deliberately unchanged. |
| Task 3 ↔ Task 4: Route/spec docs and synchronization test | Task 3 records the standalone boundary and no-`endpoint_kind` ruling; Task 4 checks both and reviews behavior against `Routing::Compiler`. | Clean. Task 4 must distinguish the intentional ruling occurrence from an implemented accessor. |
| Task 1 internal | RED diagnostics tests precede the origin-aware helper change; focused method tests follow. | Self-consistent and TDD-compliant. Explicit `methods` retains its existing diagnostics. |
| Task 2 internal | RED accessor-shape tests precede removal of `_has_constraints`; focused constraint/routing tests follow. | Self-consistent and TDD-compliant. Inline constraints remain Pattern-owned and are not reconstructed. |
| Task 3 internal | RED documentation synchronization assertions precede POD/spec edits; POD checks follow. | Self-consistent. This is executable documentation synchronization, not runtime behavior. |
| Task 4 internal | Audit and independent reviews precede the single final full suite; evidence is committed afterward; publishing is forbidden. | Self-consistent. The final full suite is run once at the candidate HEAD unless a later code/executable-doc fix invalidates that candidate. |

Preflight result: no contradictions with the specification or Global Constraints. No implementation ruling was required.

## Progress

- Setup complete: work map and preflight scan recorded at `b317342b3fc021261c7123ac7d99af973ad02acd`.
- Baseline environment correction: an accidental system-Perl 5.34 invocation failed before tests because `Future` was absent. Re-running `prove -lv t/routing/01-constructors.t` under `perl-5.42.2@default` passed (1 file, 11 top-level tests, exit 0). The first invocation is not treated as a repository failure.
- Task 1: complete (commits `b317342..ac25eb1`, review clean). TDD RED failed only the six new capability-message assertions; focused GREEN passed 6 files / 52 tests under Perl 5.42.2. Independent review: spec compliant, quality approved, no findings.
- Task 2: complete (commits `ac25eb1..fbcdcfc`, review clean). TDD RED failed only the four new omitted-constraint shape/freshness assertions; focused GREEN passed 6 files / 85 tests under Perl 5.42.2. Independent review: spec compliant, quality approved, no findings.
- Task 3 preflight Ruling: do not add source-text synchronization assertions for human POD/spec prose. The approved plan's Step 1 would test that documents contain phrases rather than exercise behavior, which conflicts with the binding `writing-good-tests` rubric. Existing routing tests remain the behavioral evidence; `podchecker`, existing documentation-example tests, and independent comparison against `Routing::Compiler` validate the documentation update. Cost if wrong: prose drift will be caught by review rather than an automated keyword check, but the suite avoids a brittle change detector that fires on harmless rewording.
- Task 3: complete (commits `fbcdcfc..9a93113`, review clean). Existing docs/POD gate passed 2 files / 14 tests, both POD files reported syntax OK, and focused routing behavior passed 4 files / 36 tests under Perl 5.42.2. Independent review: spec compliant, quality approved, no findings.
- Task 4 review-base Ruling: package `b317342..HEAD` for this cleanup's final reviewers rather than `merge-base(origin/main, HEAD)..HEAD`. The larger application-valued-endpoint campaign through `b317342` already received its own specification and quality reviews; the current plan is a focused follow-up to those findings. `origin/main...HEAD` remains the required diff/scope check, but feeding its roughly 140-commit historical campaign to the cleanup reviewers would hide the three owned fixes. Cost if wrong: final reviewers rely on the recorded earlier campaign reviews for pre-`b317342` code rather than re-reviewing that entire campaign here.
- Task 4 focused audit: PASS at `9a93113`; `git diff --check` clean, forbidden searches matched only the explicit `endpoint_kind` ruling and intended diagnostics, and the focused gate passed 12 files / 123 tests under Perl 5.42.2.
- Task 4 independent specification review: APPROVE, no Critical/Important/Minor findings.
- Task 4 independent quality review: APPROVE, no Critical/Important/Minor findings.
- Task 4 repository-wide suite: PASS at code/documentation candidate `9a93113` under Perl 5.42.2 with host loopback access; 218 files / 2,373 tests / one intentional release-only skip / exit 0.
- Task 4 final checks: `git diff --check` clean; Route and Mount syntax OK under Perl 5.42.2; both POD files syntax OK; `dzil build` exit 0 and produced `PAGI-Tools-0.002002.tar.gz` (935 KiB). Existing PkgVersion notices were non-fatal. The build-generated root README rewrite was removed, leaving no tracked build side effect.
