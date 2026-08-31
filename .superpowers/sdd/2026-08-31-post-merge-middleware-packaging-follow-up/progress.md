# SDD ledger — plan: docs/superpowers/plans/2026-08-31-post-merge-middleware-packaging-follow-up.md

# Post-Merge Middleware and Packaging Follow-up

| Task | Status | Commit | Tests | Evidence |
|---|---|---|---|---|
| 1. Correct middleware design record | complete | f8a6fd9192d1421bfd6628eeb7ec8906030907f5 | `prove -l t/routing/04-middleware-descriptors.t t/routing/11-explicit-middleware.t`: 2 files, 16 tests, PASS; `git diff --check`: PASS | Replaced overstated safety rationale with deterministic type-dispatch wording; documented the two-layer grammar, ergonomic cost, and retained `middleware(...)` name. No production module or public API changed. |
| 2. Ship generated Markdown README | complete | 38bd88aa4753de36a8ae1d0c52e904f6614b7abe | built: `prove -lv t/upgrading-routing-composition.t`: 1 file, 10 top-level subtests, PASS; source: `prove -l t/00-pod/cookbook-examples.t t/upgrading-routing-composition.t`: 2 files, 14 tests, PASS; `git diff --check`: PASS | Fresh `/tmp/pagi-tools-readme-green.QY6pUp` build contains `README.md`; `cmp README.md /tmp/pagi-tools-readme-green.QY6pUp/README.md` exited 0. |
| 3. Ship real chat example assets | complete | ee58ea12e34c3657ac91bd8b8cfb113d3dc65b0e | source: `prove -lv t/integration-websocket-chat-v2.t`: 1 file, 9 top-level tests, PASS; built: same test from fresh `/tmp/pagi-tools-chat-green.J6mZCn` distribution tree: 1 file, 9 top-level tests, PASS; source/built ordinary-file checks and `git diff --check`: PASS | Replaced only the guarded `public` symlink with independent ordinary frontend files, removed the obsolete dist prune rule, and documented CPAN-tarball availability. No equality coupling to the source example was added. |
| 4. Release notes and distribution verification | in progress | — | — | — |

## Work map

| Repository | Ticket | Branch | Base | Owned changes | Deployment boundary | Push target |
|---|---|---|---|---|---|---|
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | none | `fix/post-merge-packaging-and-middleware-rationale` | `1a5a657c8efa224404034d976b312222bf6e7153` | Middleware design wording, README packaging, real websocket-chat-v2 assets, tests, Changes | PAGI-Tools source and CPAN artifact | `origin/fix/post-merge-packaging-and-middleware-rationale` |

## Preflight consistency scan

### Cross-task interfaces and shared files

| Tasks | Producer / consumer relationship | Finding |
|---|---|---|
| 1 → 4 | Task 1 corrects the design record; Task 4 describes the same rationale in `Changes` and verifies no runtime change. | Consistent: both require deterministic type-dispatch wording and preserve `middleware(...)`. |
| 2 → 4 | Task 2 configures and verifies built `README.md`; Task 4 repeats the fresh-build and equality gates. | Consistent: Task 4 consumes the exact artifact contract established by Task 2. |
| 3 → 4 | Task 3 replaces the symlink, updates `dist.ini`, and proves source/built behavior; Task 4 repeats final artifact and suite gates. | Consistent: Task 4 validates the ordinary-file result rather than reimplementing it. |
| 2 ↔ 3 | Both modify `dist.ini` and create fresh distribution builds. | Consistent and intentionally sequential: Task 2 adds named README plugins; Task 3 removes only the obsolete chat prune rule while retaining those plugins. |
| 1 ↔ 2 ↔ 3 ↔ 4 | Every task updates this ledger in separate bookkeeping commits. | Consistent: the ledger records the preceding implementation commit and moves the next task to in progress. |

### Per-task internal consistency

| Task | Code/files versus tests/evidence | Finding |
|---|---|---|
| 1 | Documentation-only design correction; focused middleware tests ensure no runtime regression. | Consistent. The controller creates the ledger and preflight table before dispatch; the implementer owns the design edit and task commits. |
| 2 | Two named `ReadmeAnyFromPod` instances produce root/build `README.md`; `cmp` and built/source tests verify the promised identity and availability. | Consistent. Root `README.md` regeneration is a mechanical plugin output, not hand-authored prose. |
| 3 | Exact symlink validation precedes `unlink`; three copied files replace it; source and built integration tests verify packaging and runtime behavior. | Consistent. The plan forbids recursive deletion and byte-equality coupling after the initial copy. |
| 4 | `Changes` records only completed behavior; focused, complete source, artifact, and complete built-tree gates verify the release candidate. | Consistent. No version bump, release, push, or merge is included. |

## Deviations

None.

## Baseline

- Base `1a5a657c8efa224404034d976b312222bf6e7153` verified under Perl 5.42.2: `prove -lr t` passed 218 files / 2,374 tests; the documented `RELEASE_TESTING=1` multipart end-to-end test remained skipped.

## Review record

- Task 1: complete (commits `fad7d06..28d1566`, review clean).
- Task 2: complete (commits `b81539f..b2fde61`, review clean).
- Task 3: fix round 1/5 (1 addressed, 0 open — corrected non-resolving implementation SHA; commit `7ff1911`).
- Task 3: complete (commits `e095bad..7ff1911`, review clean).
