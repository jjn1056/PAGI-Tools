# PAGI Environment Utilities Design

**Date:** 2026-08-11

## Goal

Replace direct string comparisons against `PAGI_ENV` with one strict,
request-time environment contract in `PAGI::Utils`. The contract should make
ordinary environment gates typo-proof while still exposing the canonical
environment name when code needs to select among all supported modes.

`PAGI::App::File` becomes the first production consumer in this change.

## Canonical Environments

The complete supported set, in diagnostic and documentation order, is:

```text
development
test
staging
production
```

`PAGI_ENV` is strict configuration, not permissive user input:

- an unset variable means `production`;
- an empty string means `production`;
- each nonempty value must exactly equal one of the four lowercase names;
- case variants, surrounding whitespace, abbreviations, and misspellings
  croak;
- values are read on every helper call and are never cached.

For example, `Development`, ` development`, `prod`, and `developement` are
invalid. This strictness is the feature: a configuration typo must fail loudly
rather than silently select production-like behavior.

The invalid-value diagnostic is:

```text
Invalid PAGI_ENV 'developement'; expected one of: development, test, staging, production
```

## Public API

Add five optional exports to `PAGI::Utils`:

```perl
use PAGI::Utils qw(
    pagi_env
    is_development
    is_test
    is_staging
    is_production
);

my $environment = pagi_env();
return if is_test();
```

`pagi_env()` returns exactly one canonical string. Each predicate returns
ordinary Perl true or false after consulting `pagi_env()`:

```text
is_development()  <=> pagi_env() eq 'development'
is_test()         <=> pagi_env() eq 'test'
is_staging()      <=> pagi_env() eq 'staging'
is_production()   <=> pagi_env() eq 'production'
```

Every public helper is a zero-argument function. Passing any argument,
including `undef`, croaks with the function name:

```text
pagi_env() does not accept arguments
is_development() does not accept arguments
```

This rejects accidental attempts to use the accessor as a value-normalization
function. There is no public `pagi_env($value)` form and no setter.

## Export Bundles

Add a lowercase `:env` tag containing exactly the five new helpers:

```perl
use PAGI::Utils qw(:env);
```

The existing `:all` tag continues to contain every optional Utils export,
including these five. Default exports remain empty. Existing Utils imports and
the caller-origin registration used by `app_path` remain unchanged.

## Implementation Shape

`PAGI::Utils` owns one private ordered list or lookup table for validation.
`pagi_env()` performs the unset/empty default and strict membership check.
The four predicates delegate to that accessor; they do not read `%ENV`
independently or duplicate the allowed-value list.

Library code remains compatible with the distribution's Perl 5.18 floor.
No enum dependency, value object, global cache, or mutable configuration
singleton is added.

## PAGI::App::File Integration

Replace the direct comparison in `_development_file_attempt`:

```perl
($ENV{PAGI_ENV} // '') eq 'development'
```

with a fully-qualified call to `PAGI::Utils::is_development()`. Load Utils at
the point needed rather than importing the predicate into
`PAGI::App::File`; this avoids changing the File package's no-export import
hook or adding irrelevant caller-origin registration.

The diagnostic stays at its existing request-time boundary: after request
path validation and index selection, before the file readability check. The
change does not move output, change its stream, alter its contents, or mutate
responses/file events.

Consequences:

- `development` continues to print the file-attempt record;
- `test`, `staging`, `production`, unset, and empty remain silent;
- an invalid nonempty environment croaks when this environment-dependent
  boundary is reached;
- requests rejected before this boundary retain their existing behavior and
  do not consult `PAGI_ENV`.

## Documentation

Extend `PAGI::Utils` POD with the canonical values, default, strict failure
policy, dynamic lookup, predicate examples, and `:env` bundle.

Update `PAGI::App::File` POD to refer to the canonical environment contract
and state that invalid nonempty values fail rather than acting as a silent
nondevelopment mode. Update the root static-file example README and `Changes`
to use the same terminology.

## Verification

Create `t/utils-environment.t` covering:

- unset and empty default to `production`;
- each of the four exact values is returned unchanged;
- exactly one predicate is true for each environment;
- repeated calls observe a newly localized environment rather than a cache;
- case variants, whitespace, abbreviations, and misspellings croak with the
  canonical allowed list;
- every helper rejects arguments;
- no default exports are introduced;
- `:env` exports exactly the five helpers;
- `:all` includes the five helpers alongside existing Utils exports.

Update `t/app-file.t` to prove:

- development output is unchanged;
- unset, empty, `test`, `staging`, and `production` are silent;
- invalid nonempty values such as `Development` and `none` fail loudly at the
  diagnostic boundary;
- rejected paths still do not consult the environment helper.

Run the focused Utils, App::File, load, and example integration tests, then the
repository suite once on the final reviewed tree.

## Scope Boundaries

- Do not add `PAGI::Environment` or another module.
- Do not add aliases such as `dev`, `stage`, or `prod`.
- Do not lowercase, trim, or otherwise normalize nonempty values.
- Do not cache the environment.
- Do not add setters or argument-taking validation forms.
- Do not infer `test` mode from the test harness.
- Do not convert middleware options named `development`; they are explicit
  component configuration, not direct `PAGI_ENV` reads.
- Do not change other environment variables such as `PAGI_HOME`.
- Add no dependency.

## Rejected Alternatives

A separate `PAGI::Environment` module would isolate the concern but adds
module and import ceremony without enough behavior to justify it.

Constants alone would reduce misspellings in comparisons but would not reject
a mistyped external `PAGI_ENV`, leaving the more dangerous half of the problem
unsolved.

Permissive case/whitespace normalization would make deployment mistakes harder
to notice and contradict the typo-prevention goal.
