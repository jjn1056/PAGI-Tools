# SDD ledger — plan: docs/superpowers/plans/2026-08-31-post-merge-middleware-packaging-follow-up.md

# Post-Merge Middleware and Packaging Follow-up

| Task | Status | Commit | Tests | Evidence |
|---|---|---|---|---|
| 1. Correct middleware design record | complete | f8a6fd9192d1421bfd6628eeb7ec8906030907f5 | `prove -l t/routing/04-middleware-descriptors.t t/routing/11-explicit-middleware.t`: 2 files, 16 tests, PASS; `git diff --check`: PASS | Replaced overstated safety rationale with deterministic type-dispatch wording; documented the two-layer grammar, ergonomic cost, and retained `middleware(...)` name. No production module or public API changed. |
| 2. Ship generated Markdown README | in progress | — | — | — |
| 3. Ship real chat example assets | pending | — | — | — |
| 4. Release notes and distribution verification | pending | — | — | — |

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
