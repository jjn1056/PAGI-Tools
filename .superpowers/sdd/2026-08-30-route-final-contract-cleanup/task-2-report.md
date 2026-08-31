# Task 2 Report: Route and Mount constraint accessor shape

## Files changed

- `lib/PAGI/Routing/Route.pm`
  - Normalizes the optional explicit constraints value once, always passing a
    hashref to `PAGI::Routing::Pattern`.
  - Removes `_has_constraints` from the object and delegates `constraints`
    directly to the Pattern defensive copy.
  - Documents the stable fresh-hashref accessor shape and the fact that inline
    path constraints remain Pattern-owned.
- `lib/PAGI/Routing/Mount.pm`
  - Applies the same normalized-hashref storage and direct accessor delegation.
  - Documents the stable fresh-hashref accessor shape and inline constraint
    ownership.
- `t/routing/01-constructors.t`
  - Adds omitted and explicitly empty Route assertions, omitted Mount
    assertions, and mutation checks proving every empty result is fresh.
- `Changes`
  - Adds a concise `0.002003 - UNRELEASED` entry for the stable accessor shape.

`t/routing/02-patterns.t` was included in the required focused run but needed
no source edit: its existing Pattern matching, inline/provider, checker-order,
identity, and defensive-copy coverage remained valid.

Pre-existing untracked user/session files were preserved and not staged.

## TDD RED

Command:

```text
source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/01-constructors.t t/routing/02-patterns.t
```

Result: exit status `2`. The two files ran 22 top-level tests; only two
constructor subtests failed, with exactly four new omitted-constraint
assertions failing (Route omitted shape/freshness and Mount omitted
shape/freshness). The explicit-empty Route assertions, existing explicit
constraint identity/copy checks, Router `constraints` `undef` assertion, and
all Pattern tests passed. The observed old accessor result was `<UNDEF>`,
confirming the expected missing stable hashref behavior.

## TDD GREEN

Focused gate command after implementation:

```text
source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/01-constructors.t t/routing/02-patterns.t t/routing/03-reverse-inspection.t t/routing/05-http-dispatch.t t/routing/07-mounts.t t/routing/13-url-helper.t
```

Result: exit status `0`; `Files=6, Tests=85`; all tests successful.

Post-commit verification repeated the same focused gate under perlbrew Perl
5.42.2 with the same result: exit status `0`, `Files=6, Tests=85`, and
`Result: PASS`.

Additional verification: `git diff --check` and the committed diff check both
exited `0`. The worktree retains only the pre-existing untracked user/session
files.

## Self-review

- Route and Mount each use the exact requested `exists` normalization shape.
- `_has_constraints` is absent from both blessed objects and both accessors
  delegate directly to Pattern.
- Pattern continues to own inline/provider predicate records; public explicit
  constraint maps remain separate and defensive.
- Explicit checker identity, matching, reverse validation, predicate order,
  and provider behavior remain covered and unchanged.
- Router's intentionally inapplicable `constraints` accessor remains `undef`.
- The Task 1 origin-aware method normalizer is unchanged.
- Only the requested tracked implementation, test, and documentation files
  were staged; unrelated untracked files remain untouched.

## Commit

`fbcdcfcf96a3fe8779ce00a8a10e73366350d58d` (`refactor: simplify route constraint inspection`)

## Concerns

None. The broader test suite was not run because the brief specified the
focused routing gate; that gate passed before and after commit.
