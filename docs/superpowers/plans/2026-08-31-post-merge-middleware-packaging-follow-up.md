# Post-Merge Middleware and Packaging Follow-up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct the middleware descriptor rationale without changing its API, and make the PAGI-Tools CPAN build contain its generated Markdown README and a runnable `websocket-chat-v2` example.

**Architecture:** Keep the merged strict-core/concise-frontend middleware split and the `middleware(...)` descriptor name. Correct the design document so it describes deterministic type dispatch, uniform inspectable core values, and the intentional two-layer grammar honestly. Fix distribution packaging with a second build-located README generator and real chat asset files, using the existing built-tree failures as the regression tests.

**Tech Stack:** Perl 5.42.2, Test2::V0, Dist::Zilla, Dist::Zilla::Plugin::ReadmeAnyFromPod, PAGI::Test::Client.

**Spec:** `docs/superpowers/specs/2026-08-30-explicit-middleware-descriptors-design.md` as amended by Task 1; this follow-up also resolves the packaging deviations recorded in `.superpowers/sdd/2026-08-30-explicit-middleware-descriptors/progress.md`.

## Global Constraints

- Repository: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools`.
- Ticket: none at plan time; create one PR for this complete follow-up.
- Execution branch: `fix/post-merge-packaging-and-middleware-rationale`.
- Base: `origin/main@1a5a657c8efa224404034d976b312222bf6e7153`.
- Owned changes: middleware design wording, `dist.ini`, generated root `README.md`, `examples/websocket-chat-v2/public`, its integration test and examples index prose, `Changes`, and the campaign ledger.
- Deployment boundary: the PAGI-Tools source checkout and CPAN distribution artifact only. PAGI and PAGI::Server are out of scope.
- Push target: `origin/fix/post-merge-packaging-and-middleware-rationale`, followed by a PR against `main` only after review and final verification.
- Preserve the merged middleware API: core Route, Mount, Router, and Compose lists still accept only `PAGI::Routing::Middleware` descriptions; higher-level frontends retain deterministic concise-entry normalization.
- Keep the public descriptor constructor named `middleware(...)`. Do not add `mw`, `use_middleware`, `Middleware`, singleton-list coercion, or restored bare core entries.
- State explicitly that string, CODE, configured-object, and descriptor inputs are disjoint shapes; do not claim that the old frontend normalization inferred signatures or resolved ambiguity.
- State explicitly that the distribution intentionally has two user-facing middleware grammars split by layer, and that zero-configuration declarative middleware pays a small ceremony cost for a uniform inspectable core representation.
- Do not add dependencies. Both README plugin instances use the already-installed `Dist::Zilla::Plugin::ReadmeAnyFromPod`.
- The built distribution must contain `README.md`, not only Dist::Zilla's generic `README`.
- Replace only the exact symlink `examples/websocket-chat-v2/public -> ../10-chat-showcase/public`; never recursively delete an unresolved path.
- The replacement chat asset directory contains three ordinary files copied from `examples/10-chat-showcase/public`: `index.html`, `css/style.css`, and `js/app.js`.
- Do not skip the chat integration test in built distributions. The example must remain runnable from the CPAN artifact.
- Do not version-bump or release. Record the fixes beneath `0.002003 - UNRELEASED` in `Changes`.
- Use TDD for packaging behavior. The current built-tree failures are the required RED evidence: missing `README.md` makes `t/upgrading-routing-composition.t` die, and missing chat assets make five assertions in `t/integration-websocket-chat-v2.t` fail.
- Use Perl `5.42.2@default`. Listener-based full-suite verification requires host access.
- Before implementation, create and force-add `.superpowers/sdd/2026-08-31-post-merge-packaging-follow-up/progress.md`. Each task row records status, implementation commit SHA, real test counts, and evidence. Record deviations as `DEV-NN` with rationale and user approval before later tasks depend on them.
- Preserve all unrelated untracked `.pagi-*`, `.superpowers/brainstorm/`, and `.superpowers/plans/` files.

---

### Task 1: Correct the Middleware Design Record

**Files:**

- Create: `.superpowers/sdd/2026-08-31-post-merge-packaging-follow-up/progress.md`
- Modify: `docs/superpowers/specs/2026-08-30-explicit-middleware-descriptors-design.md`

**Interfaces:**

- Consumes: the shipped `_require_descriptors` and `_normalize_frontend_entries` split in `PAGI::Routing::Middleware`.
- Produces: an accurate design record that preserves the API while documenting deterministic normalization, the two-layer grammar, its ergonomic cost, and the retained `middleware(...)` name.

- [ ] **Step 1: Create an isolated execution worktree and ledger.**

Use `superpowers:using-git-worktrees` from current `origin/main`, create branch `fix/post-merge-packaging-and-middleware-rationale`, and record the exact base SHA. Create:

```markdown
# Post-Merge Middleware and Packaging Follow-up

| Task | Status | Commit | Tests | Evidence |
|---|---|---|---|---|
| 1. Correct middleware design record | in progress | — | — | — |
| 2. Ship generated Markdown README | pending | — | — | — |
| 3. Ship real chat example assets | pending | — | — | — |
| 4. Release notes and distribution verification | pending | — | — | — |

## Work map

| Repository | Ticket | Branch | Base | Owned changes | Deployment boundary | Push target |
|---|---|---|---|---|---|---|
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | none | `fix/post-merge-packaging-and-middleware-rationale` | `1a5a657c8efa224404034d976b312222bf6e7153` | Middleware design wording, README packaging, real websocket-chat-v2 assets, tests, Changes | PAGI-Tools source and CPAN artifact | `origin/fix/post-merge-packaging-and-middleware-rationale` |

## Deviations

None.
```

Force-add the ignored ledger and commit the campaign start:

```bash
git add -f .superpowers/sdd/2026-08-31-post-merge-packaging-follow-up/progress.md
git commit -m "docs: start packaging follow-up campaign"
```

- [ ] **Step 2: Replace the overstated safety rationale in §1.**

Replace the paragraph beginning `That convenience weakens` with language carrying these exact facts:

```text
The four accepted inputs are disjoint Perl shapes, so the old normalization
was deterministic type dispatch rather than signature inference. The problem
was representational: immutable composition nodes accepted several input
forms and silently converted them into one stored description. Requiring an
explicit description gives the core one inspectable configuration value and
makes deferred construction visible, while higher-level frontends retain the
same unambiguous convenience dispatch.
```

Do not alter the Route CODE-versus-application discussion elsewhere; that is a genuinely ambiguous callable placement and still requires `as_app`.

- [ ] **Step 3: Document the intentional two-layer grammar and naming decision.**

At the end of §8, add a subsection named `8.1 Deliberate grammar and naming tradeoff` that states:

```text
The distribution intentionally ends with two public grammars. Immutable core
lists accept only descriptions; App Router, Endpoint Router, and Middleware
Builder accept disjoint concise values and materialize descriptions before
entering the core. This is more total surface, not a claim that all middleware
syntax was simplified.

The cost falls most visibly on zero-configuration declarative middleware:
middleware => [middleware('RequestId')]. PAGI keeps that spelling because the
inner function constructs a middleware description and remains searchable and
self-documenting. mw(...) is too cryptic, use_middleware(...) incorrectly
suggests immediate wrapping, and Middleware(...) is class-like rather than
idiomatic Perl. The repeated noun is an accepted cost of the explicit core
boundary.
```

- [ ] **Step 4: Verify the documentation-only task.**

Run:

```bash
git diff --check
prove -l t/routing/04-middleware-descriptors.t t/routing/11-explicit-middleware.t
```

Expected: both test files pass; the diff changes no production module or public API.

- [ ] **Step 5: Commit and update the ledger.**

Commit the design correction:

```bash
git add docs/superpowers/specs/2026-08-30-explicit-middleware-descriptors-design.md
git commit -m "docs: clarify middleware descriptor tradeoffs"
```

Record the real commit SHA and test counts in Task 1's ledger row, change Task 1 to `complete`, Task 2 to `in progress`, and commit the ledger update separately.

---

### Task 2: Ship the Generated Markdown README

**Files:**

- Modify: `dist.ini`
- Modify mechanically: `README.md`
- Test: `t/upgrading-routing-composition.t` from a freshly built distribution tree
- Modify: `.superpowers/sdd/2026-08-31-post-merge-packaging-follow-up/progress.md`

**Interfaces:**

- Consumes: `Dist::Zilla::Plugin::ReadmeAnyFromPod` with `location = root` and `location = build`.
- Produces: identical generated `README.md` files in the source root and every built distribution.

- [ ] **Step 1: Reproduce the missing-built-README failure.**

From the worktree root:

```bash
BUILD_DIR="$(mktemp -d /tmp/pagi-tools-readme-red.XXXXXX)" || exit 1
case "$BUILD_DIR" in
  /tmp/pagi-tools-readme-red.*) ;;
  *) exit 1 ;;
esac
dzil build --no-tgz --in "$BUILD_DIR"
test ! -f "$BUILD_DIR/README.md"
(cd "$BUILD_DIR" && prove -lv t/upgrading-routing-composition.t)
```

Expected RED: the build has no `README.md`, and the test dies with `Cannot read README.md: No such file or directory`.

`dzil build` regenerates root `README.md` under the current configuration. Do not treat that generated diff as the fix until `dist.ini` has the build-located plugin and the built copy is verified.

- [ ] **Step 2: Configure separate root and build README generators.**

Replace the current anonymous section with these two named instances:

```ini
; Render the GitHub README at the repository root.
[ReadmeAnyFromPod / ReadmeMarkdownInRoot]
type = markdown
filename = README.md
location = root

; Ship the same generated README in the CPAN distribution.
[ReadmeAnyFromPod / ReadmeMarkdownInBuild]
type = markdown
filename = README.md
location = build
```

Do not remove Dist::Zilla's generic `README`; the requirement is that the useful generated `README.md` is present as well.

- [ ] **Step 3: Build and verify the generated files.**

Run a new build rather than reusing the RED directory:

```bash
BUILD_DIR="$(mktemp -d /tmp/pagi-tools-readme-green.XXXXXX)" || exit 1
case "$BUILD_DIR" in
  /tmp/pagi-tools-readme-green.*) ;;
  *) exit 1 ;;
esac
dzil build --no-tgz --in "$BUILD_DIR"
test -f "$BUILD_DIR/README.md"
cmp README.md "$BUILD_DIR/README.md"
(cd "$BUILD_DIR" && prove -lv t/upgrading-routing-composition.t)
```

Expected GREEN: `README.md` exists in both locations, the files compare equal, and all ten top-level subtests pass.

- [ ] **Step 4: Verify source documentation gates.**

Run:

```bash
prove -l t/00-pod/cookbook-examples.t t/upgrading-routing-composition.t
git diff --check
```

Expected: both test files pass and the only generated documentation change is `README.md`.

- [ ] **Step 5: Commit and update the ledger.**

```bash
git add dist.ini README.md
git commit -m "dist: ship generated markdown readme"
```

Record the real SHA, built-tree test count, source test count, and `cmp` evidence in Task 2's ledger row; mark Task 3 `in progress` and commit the ledger update.

---

### Task 3: Ship Real WebSocket Chat Assets

**Files:**

- Replace symlink with directory: `examples/websocket-chat-v2/public`
- Create: `examples/websocket-chat-v2/public/index.html`
- Create: `examples/websocket-chat-v2/public/css/style.css`
- Create: `examples/websocket-chat-v2/public/js/app.js`
- Modify: `examples/README.md`
- Modify: `dist.ini`
- Modify: `t/integration-websocket-chat-v2.t`
- Modify: `.superpowers/sdd/2026-08-31-post-merge-packaging-follow-up/progress.md`

**Interfaces:**

- Consumes: the three existing files under `examples/10-chat-showcase/public` and `PAGI::App::File->from_app_path('public')` in the v2 HTTP component.
- Produces: an ordinary 52 KB `public` directory available identically in source and CPAN builds; runtime paths and HTTP behavior remain unchanged.

- [ ] **Step 1: Add a failing source-tree packaging assertion.**

In `t/integration-websocket-chat-v2.t`, define:

```perl
my $public_dir = "$Bin/../examples/websocket-chat-v2/public";
```

Before loading the application, add:

```perl
ok(!-l $public_dir,
    'v2 chat public assets are ordinary files that can ship to CPAN');
for my $asset ('index.html', 'css/style.css', 'js/app.js') {
    ok(-f "$public_dir/$asset", "v2 chat ships $asset");
}
```

Run:

```bash
prove -lv t/integration-websocket-chat-v2.t
```

Expected RED: only the new non-symlink assertion fails; the three asset checks and existing HTTP behavior still pass through the checkout symlink.

- [ ] **Step 2: Validate and remove only the known symlink.**

Before modifying it, run these exact checks in one foreground shell:

```bash
test -L examples/websocket-chat-v2/public
test "$(readlink examples/websocket-chat-v2/public)" = "../10-chat-showcase/public"
```

If either check fails, stop and record a deviation; do not broaden the target or use recursive deletion. Once both checks pass, remove only the symlink:

```bash
unlink examples/websocket-chat-v2/public
```

- [ ] **Step 3: Materialize the three ordinary asset files.**

```bash
mkdir -p examples/websocket-chat-v2/public/css
mkdir -p examples/websocket-chat-v2/public/js
cp examples/10-chat-showcase/public/index.html examples/websocket-chat-v2/public/index.html
cp examples/10-chat-showcase/public/css/style.css examples/websocket-chat-v2/public/css/style.css
cp examples/10-chat-showcase/public/js/app.js examples/websocket-chat-v2/public/js/app.js
```

The v2 example intentionally starts with the same frontend. Do not add a byte-for-byte equality test between the two examples; future intentional divergence is allowed, while the integration test protects the actual served behavior.

- [ ] **Step 4: Remove obsolete pruning and source-only documentation.**

Delete this exact `dist.ini` block:

```ini
; symlink into a sibling example; resolves in git checkouts but CPAN
; tarballs must not contain symlinks
match = ^examples/websocket-chat-v2/public$
```

Replace the note in `examples/README.md` with:

```markdown
**Note on `websocket-chat-v2/public`:** the v2 example carries ordinary copies
of the shared chat frontend assets so it remains runnable from CPAN tarballs,
which cannot preserve the source checkout's former directory symlink.
```

- [ ] **Step 5: Verify source behavior is GREEN.**

Run:

```bash
prove -lv t/integration-websocket-chat-v2.t
test ! -L examples/websocket-chat-v2/public
test -f examples/websocket-chat-v2/public/index.html
test -f examples/websocket-chat-v2/public/css/style.css
test -f examples/websocket-chat-v2/public/js/app.js
git diff --check
```

Expected: the integration test passes all existing behavior plus the four packaging assertions.

- [ ] **Step 6: Verify the built distribution behavior is GREEN.**

```bash
BUILD_DIR="$(mktemp -d /tmp/pagi-tools-chat-green.XXXXXX)" || exit 1
case "$BUILD_DIR" in
  /tmp/pagi-tools-chat-green.*) ;;
  *) exit 1 ;;
esac
dzil build --no-tgz --in "$BUILD_DIR"
test ! -L "$BUILD_DIR/examples/websocket-chat-v2/public"
test -f "$BUILD_DIR/examples/websocket-chat-v2/public/index.html"
test -f "$BUILD_DIR/examples/websocket-chat-v2/public/css/style.css"
test -f "$BUILD_DIR/examples/websocket-chat-v2/public/js/app.js"
(cd "$BUILD_DIR" && prove -lv t/integration-websocket-chat-v2.t)
```

Expected: all assertions pass from ordinary files inside the distribution tree.

- [ ] **Step 7: Commit and update the ledger.**

Stage the deleted symlink, new ordinary files, test, configuration, and prose explicitly:

```bash
git add dist.ini examples/README.md examples/websocket-chat-v2/public t/integration-websocket-chat-v2.t
git commit -m "dist: ship websocket chat assets"
```

Record the real SHA and source/built test evidence in Task 3's ledger row; mark Task 4 `in progress` and commit the ledger update.

---

### Task 4: Record and Verify the Release Candidate

**Files:**

- Modify: `Changes`
- Modify: `.superpowers/sdd/2026-08-31-post-merge-packaging-follow-up/progress.md`

**Interfaces:**

- Consumes: the corrected design record, dual README generation, and ordinary chat asset directory.
- Produces: one source-clean and distribution-clean candidate with auditable verification evidence.

- [ ] **Step 1: Add the unreleased Changes entry.**

Under `0.002003 - UNRELEASED`, after the middleware descriptor breaking-change paragraph, add:

```text
  - Clarified that concise middleware normalization is deterministic dispatch
    across disjoint Perl value shapes; the strict core descriptor requirement
    provides one inspectable representation rather than resolving callable
    ambiguity. The public API and middleware(...) spelling are unchanged.
  - Distribution builds now include the generated Markdown README and real
    websocket-chat-v2 frontend assets, so built-tree documentation and chat
    integration tests exercise the same files as source checkouts.
```

- [ ] **Step 2: Run the focused source gate.**

```bash
prove -l \
  t/routing/04-middleware-descriptors.t \
  t/routing/11-explicit-middleware.t \
  t/00-pod/cookbook-examples.t \
  t/upgrading-routing-composition.t \
  t/integration-websocket-chat-v2.t
```

Expected: all five files pass.

- [ ] **Step 3: Run the complete source suite with host socket access.**

```bash
prove -lr t
```

Expected baseline: at least 218 files and 2,374 tests pass; the full-stack PAGI::Server multipart test may retain its documented `RELEASE_TESTING=1` skip. Record the actual counts rather than copying the baseline.

- [ ] **Step 4: Build a fresh distribution and verify its contents.**

```bash
BUILD_DIR="$(mktemp -d /tmp/pagi-tools-final-dist.XXXXXX)" || exit 1
case "$BUILD_DIR" in
  /tmp/pagi-tools-final-dist.*) ;;
  *) exit 1 ;;
esac
dzil build --no-tgz --in "$BUILD_DIR"
test -f "$BUILD_DIR/README.md"
cmp README.md "$BUILD_DIR/README.md"
test ! -L "$BUILD_DIR/examples/websocket-chat-v2/public"
test -f "$BUILD_DIR/examples/websocket-chat-v2/public/index.html"
test -f "$BUILD_DIR/examples/websocket-chat-v2/public/css/style.css"
test -f "$BUILD_DIR/examples/websocket-chat-v2/public/js/app.js"
```

Expected: every check exits zero.

- [ ] **Step 5: Run the complete built-distribution suite with host socket access.**

```bash
(cd "$BUILD_DIR" && prove -lr t)
```

Expected: the same maintained test inventory passes from the built tree. In particular, `t/upgrading-routing-composition.t` finds `README.md`, and `t/integration-websocket-chat-v2.t` serves the chat HTML and CSS instead of returning 404.

- [ ] **Step 6: Run final hygiene and scope checks.**

```bash
git diff --check
git status --short
git diff --stat origin/main...HEAD
git diff --name-only origin/main...HEAD
```

Confirm the diff contains only the files named by this plan plus the generated ledger. Confirm all unrelated untracked `.pagi-*`, `.superpowers/brainstorm/`, and `.superpowers/plans/` files remain untouched.

- [ ] **Step 7: Commit Changes and final evidence.**

```bash
git add Changes
git commit -m "docs: record distribution packaging fixes"
```

Update Task 4 to `complete` with the Changes commit SHA, exact source and built test counts, README comparison, asset checks, and final diff evidence. Commit the ledger:

```bash
git add -f .superpowers/sdd/2026-08-31-post-merge-packaging-follow-up/progress.md
git commit -m "docs: record packaging follow-up verification"
```

- [ ] **Step 8: Request final review before publishing.**

Use `superpowers:requesting-code-review` over `origin/main...HEAD`. Require the reviewer to confirm:

- no middleware runtime or accepted-input behavior changed;
- the revised rationale distinguishes deterministic type dispatch from callable ambiguity;
- the two-layer grammar and retained function name are recorded honestly;
- both source and build receive generated `README.md`;
- the CPAN tree contains ordinary chat asset files and no directory symlink;
- source and built-distribution suites pass; and
- no unrelated worktree or untracked file was modified.

Address review findings one at a time using `superpowers:receiving-code-review`, rerun the affected focused gate after each fix, and rerun Steps 3–6 after the final fix before pushing or opening the PR.

---

## Self-Review Results

- **Spec coverage:** Task 1 corrects the overreaching rationale, records the intentional dual grammar, and keeps the approved name. Task 2 fixes and tests README packaging. Task 3 fixes and tests the chat assets without a built-dist skip. Task 4 records the release impact and proves both source and CPAN-tree behavior.
- **Placeholder scan:** No `TBD`, `TODO`, generic test instruction, undefined implementation seam, or execution-time placeholder remains.
- **Interface consistency:** Both README plugin instances use `filename = README.md`; the source and built copies are compared directly. The chat application continues resolving `from_app_path('public')`; replacing the symlink with an ordinary directory requires no runtime code change.
- **Scope control:** The plan does not reopen middleware behavior, add aliases, skip failing distribution tests, change versions, or touch PAGI/PAGI::Server.
