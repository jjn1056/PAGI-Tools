# Task 1 Report: Route method-capability diagnostics

## Files changed

- `lib/PAGI/Routing/Route.pm`
  - Added origin-aware `_normalize_methods($value, $origin)` diagnostics.
  - Explicit `methods` diagnostics remain unchanged.
  - Capability diagnostics identify `route endpoint allowed_methods`, including the distinct empty-result error.
  - Method normalization, deduplication, automatic HEAD insertion, wildcard handling, and construction-time capability snapshot behavior remain unchanged.
- `t/routing/01-constructors.t`
  - Updated the existing real `Route` constructor rejection matrix with six capability-specific diagnostic assertions.
  - Existing explicit `methods` rejection assertions remain separate and unchanged.
- `Changes`
  - Added one `0.002003 - UNRELEASED` bullet documenting the diagnostic correction.

Pre-existing untracked user/session files were preserved and not staged.

## TDD RED

Command:

```text
source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/01-constructors.t
```

Result: exit status `1`. The constructor suite ran 11 top-level tests; only subtest 11 failed, with exactly the six new capability-diagnostic assertions failing. Existing construction-time rejection assertions remained passing. The observed old message was `methods must be a method string, arrayref, or '*'`, confirming the expected missing-origin behavior.

## TDD GREEN

Focused gate command (first run after implementation):

```text
source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/01-constructors.t t/routing/05-http-dispatch.t t/endpoint/03-http-to-app.t t/endpoint/04-http-options.t t/app-router/01-builder-core.t t/endpoint/13-router-frontends.t
```

Result: exit status `0`; `Files=6, Tests=52`; all tests successful.

Post-commit verification repeated the same focused gate under perlbrew Perl 5.42.2:

- exit status `0`
- `Files=6, Tests=52`
- `Result: PASS`

Additional verification: `git diff --check` exited `0` before commit.

## Self-review

- Both `_build` call sites now pass explicit origins: `methods` and `route endpoint allowed_methods`.
- Capability values are still consumed once in list context and normalized from the construction-time snapshot.
- Explicit scalar `methods => '*'` remains the only accepted wildcard form; capability wildcard entries remain rejected.
- Uppercasing, first-seen deduplication, and immediate `HEAD` insertion after `GET` are unchanged.
- Focused tests cover explicit methods, capability methods, GET/HEAD, OPTIONS, scalar wildcard, Router-owned 405, and `Allow` behavior.
- The commit contains only the three requested files.

## Commit

`ac25eb107900cca107b68da3513caf480498b1ff` (`fix: identify invalid route method capabilities`)

## Concerns

None. The broader test suite was not run because the brief specified the focused method gate; the required gate passed before and after commit. Existing untracked files remain in the worktree by design.
