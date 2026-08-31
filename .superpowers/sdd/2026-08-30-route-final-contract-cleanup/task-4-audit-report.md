# Route Final Cleanup Audit — Steps 1–3

Audit time: 2026-08-30

## Work map

- Repository: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools`
- Ticket/scope: Route final contract cleanup (PR #25)
- Branch: `feature/application-valued-route-endpoints`
- Push target: `origin/feature/application-valued-route-endpoints` (existing remote branch)
- Controller cleanup base: `b317342b3fc021261c7123ac7d99af973ad02acd`
- Candidate HEAD: `9a93113ef5288e75c54a9b632cf5ee708f9ca758`
- `origin/main`: `e4b2683e1b463e0c8bcff1198cd0c03d50f3caba` (older than the controller base)
- Deployment boundary: PAGI-Tools Perl distribution only; no publish action performed.

## Step 1 — status and diff audit

Commands run:

```text
git status -sb
git branch --show-current
git rev-parse HEAD
git rev-parse b317342b3fc021261c7123ac7d99af973ad02acd
git rev-parse origin/main
git diff --check origin/main...HEAD
git diff --check b317342b3fc021261c7123ac7d99af973ad02acd..HEAD
git log --oneline origin/main..HEAD
git diff --name-status b317342b3fc021261c7123ac7d99af973ad02acd..HEAD
```

Results:

- Branch was `feature/application-valued-route-endpoints`, ahead of its origin branch by 3 commits.
- Both whitespace checks produced no output (clean).
- `origin/main..HEAD` contains 158 commits because `origin/main` predates the controller cleanup base. The required command was run; owned cleanup scope was therefore evaluated against `b317342..HEAD`.
- Cleanup commits: `ac25eb1 fix: identify invalid route method capabilities`; `fbcdcfc refactor: simplify route constraint inspection`; `9a93113 docs: clarify standalone Route behavior`.
- The worktree had pre-existing unrelated untracked files/directories: `.pagi-0.4-alignment-tools-review.md`, `.pagi-0.4-alignment-tools-rulings.md`, `.pagi-0.5-settlement-streaming-correction.md`, `.pagi-0.5-settlement-testclient-audit-probe.pl`, `.pagi-0.5-settlement-testclient-audit.md`, `.superpowers/brainstorm/`, and `.superpowers/plans/`. They were preserved.

Tracked cleanup files (`b317342..HEAD`; 107 insertions, 31 deletions):

```text
Changes
docs/superpowers/specs/2026-08-30-route-endpoints-and-application-valued-responses-design.md
lib/PAGI/Routing/Mount.pm
lib/PAGI/Routing/Route.pm
t/routing/01-constructors.t
```

All five are named by Tasks 1–3 in `docs/superpowers/plans/2026-08-30-route-final-contract-cleanup.md`.

## Step 2 — forbidden and consistency searches

Commands run:

```text
rg -n "_has_constraints|endpoint_kind|normalized kind for introspection" lib t examples README.md UPGRADING.md Changes docs/superpowers/specs/2026-08-30-route-endpoints-and-application-valued-responses-design.md
rg -n "allowed_methods returned no methods|allowed_methods must return valid" lib t
```

Exact results:

```text
docs/superpowers/specs/2026-08-30-route-endpoints-and-application-valued-responses-design.md:1445:`endpoint_kind` value could drift and has no current consumer.
lib/PAGI/Routing/Route.pm:141:        ? 'route endpoint allowed_methods must return valid HTTP method strings'
lib/PAGI/Routing/Route.pm:159:    croak 'route endpoint allowed_methods returned no methods'
t/routing/01-constructors.t:725:        [empty     => [],                 qr/route endpoint allowed_methods returned no methods/],
t/routing/01-constructors.t:726:        [separator => ['GET POST'],       qr/route endpoint allowed_methods must return valid HTTP method strings/],
t/routing/01-constructors.t:727:        [reference => [{}],               qr/route endpoint allowed_methods must return valid HTTP method strings/],
t/routing/01-constructors.t:728:        [future    => [Future->done('GET')], qr/route endpoint allowed_methods must return valid HTTP method strings/],
t/routing/01-constructors.t:729:        [wildcard  => ['*'],              qr/route endpoint allowed_methods must return valid HTTP method strings/],
t/routing/01-constructors.t:730:        [mixed     => ['GET', '*'],        qr/route endpoint allowed_methods must return valid HTTP method strings/],
```

Interpretation:

- `_has_constraints`: no matches.
- `endpoint_kind`: one match, in the explicit rejected-alternative ruling (spec section 21.8); no implementation or test accessor match.
- `normalized kind for introspection`: no matches.
- Both capability-specific diagnostics appear in `Route.pm` and constructor tests.

## Step 3 — complete focused gate

Perl selection: `perlbrew use perl-5.42.2@default`.

Command:

```text
prove -lv t/routing/01-constructors.t t/routing/02-patterns.t t/routing/03-reverse-inspection.t t/routing/05-http-dispatch.t t/routing/07-mounts.t t/routing/13-url-helper.t t/endpoint/03-http-to-app.t t/endpoint/04-http-options.t t/app-router/01-builder-core.t t/endpoint/13-router-frontends.t t/upgrading-routing-composition.t t/00-pod/cookbook-examples.t
```

Result: exit status 0; `All tests successful.` `Files=12, Tests=123`, `3 wallclock secs`, `Result: PASS`.

## Concerns and scope limits

- No tracked cleanup concern found in Steps 1–3.
- This report is intentionally untracked and was created as directed; no tracked file was modified, no commit/push/merge occurred, and no repository-wide suite or reviews were run.
- The origin/main diff is informational only for this cleanup because `origin/main` is older than controller base `b317342`; the owned-change audit uses `b317342..HEAD`.
