### Task 4: Final Audit, Review, and PR Verification

**Files:**

- Modify only if evidence requires: files already owned by Tasks 1–3
- Create: `.superpowers/sdd/2026-08-30-route-final-contract-cleanup/progress.md`
- Create: `.superpowers/sdd/2026-08-30-route-final-contract-cleanup/task-4-report.md`

**Interfaces:**

- Consumes: Tasks 1–3 at one candidate HEAD.
- Produces: independently reviewed, fully verified commits ready to push to PR #25.

- [ ] **Step 1: Reconfirm the work map and audit the final diff.**

Verify:

```bash
git status -sb
git branch --show-current
git diff --check origin/main...HEAD
git log --oneline origin/main..HEAD
```

Confirm the branch remains `feature/application-valued-route-endpoints`, the push target remains its existing origin branch, and only PAGI-Tools files named by this plan changed.

- [ ] **Step 2: Run final forbidden and consistency searches.**

Run:

```bash
rg -n "_has_constraints|endpoint_kind|normalized kind for introspection" \
  lib t examples README.md UPGRADING.md Changes \
  docs/superpowers/specs/2026-08-30-route-endpoints-and-application-valued-responses-design.md

rg -n "allowed_methods returned no methods|allowed_methods must return valid" \
  lib t
```

Expected:

- no `_has_constraints` implementation or test remains;
- `endpoint_kind` appears only in the explicit rejected-alternative ruling and any test asserting that ruling;
- the old “normalized kind for introspection” promise is absent;
- both capability-specific diagnostic classes appear in implementation and tests.

- [ ] **Step 3: Run the complete focused gate.**

Run:

```bash
prove -lv \
  t/routing/01-constructors.t \
  t/routing/02-patterns.t \
  t/routing/03-reverse-inspection.t \
  t/routing/05-http-dispatch.t \
  t/routing/07-mounts.t \
  t/routing/13-url-helper.t \
  t/endpoint/03-http-to-app.t \
  t/endpoint/04-http-options.t \
  t/app-router/01-builder-core.t \
  t/endpoint/13-router-frontends.t \
  t/upgrading-routing-composition.t \
  t/00-pod/cookbook-examples.t
```

Expected: PASS.

- [ ] **Step 4: Obtain independent specification and quality reviews.**

The specification reviewer must verify:

- diagnostics identify explicit `methods` versus endpoint `allowed_methods` placement;
- Route/Mount constraints always return defensive hashrefs while Router remains `undef`;
- standalone Route 404, 405/Allow, HEAD, and lifespan documentation matches `Routing::Compiler`;
- no new endpoint-classification accessor or dispatch mode was introduced.

The quality reviewer must verify:

- normalization still has one implementation path;
- no cloning, caching, arity inference, or special-case dispatch chain appeared;
- `_has_constraints` is fully removed;
- documentation tests check outcomes rather than brittle paragraph formatting.

Resolve Important findings before the repository-wide suite.

- [ ] **Step 5: Run the repository-wide suite exactly once at the final candidate HEAD.**

Use Perl 5.42.2 with host loopback access:

```bash
prove -lr t
```

Record candidate SHA, files, tests, skips, wall time, and exit status. If a subsequent fix changes code or executable documentation, record the failed candidate and run one new final suite at the corrected HEAD.

- [ ] **Step 6: Run syntax, diff, and distribution checks.**

```bash
git diff --check origin/main...HEAD
perl -Ilib -c lib/PAGI/Routing/Route.pm
perl -Ilib -c lib/PAGI/Routing/Mount.pm
podchecker lib/PAGI/Routing/Route.pm lib/PAGI/Routing/Mount.pm
dzil build
```

Do not run `dzil test` after the repository-wide suite.

- [ ] **Step 7: Record final evidence and commit it.**

Update the focused progress record and report with exact commands, actual counts, reviewer verdicts, build artifact, deviations, and final candidate SHA.

```bash
git add -f .superpowers/sdd/2026-08-30-route-final-contract-cleanup/
git commit -m "docs: record final Route contract verification"
```

- [ ] **Step 8: Stop before publishing.**

Do not push, merge, tag, release, or update PR #25 until the user reviews the completed implementation and explicitly chooses the publishing action.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-08-30-route-final-contract-cleanup.md`.

Recommended execution mode:

1. **Subagent-Driven** — execute Tasks 1–4 with fresh implementation and review context, using the focused ledger and stop conditions above.
2. **Inline Execution** — execute the same tasks in this session with explicit review checkpoints.
