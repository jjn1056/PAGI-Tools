# PAGI Environment Utilities Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a strict, dynamic `PAGI_ENV` contract to `PAGI::Utils` and make `PAGI::App::File` use its typo-proof development predicate.

**Architecture:** `PAGI::Utils` owns the only allowed-value list, strict accessor, four predicates, and export tags. The helpers read `%ENV` on every call and reject invalid nonempty configuration. `PAGI::App::File` calls the fully-qualified development predicate at its existing diagnostic boundary, preserving output and response behavior while making invalid environments fail loudly.

**Tech Stack:** Perl 5.18-compatible library code, core `Carp`, `Exporter`, `Test2::V0`, `PAGI::Test::Client`, POD, Markdown, and `prove` under Perl 5.42.2.

**Design:** `docs/superpowers/specs/2026-08-11-pagi-environment-utils-design.md`

## Global Constraints

- The canonical environment order is exactly `development`, `test`, `staging`, `production`.
- Unset and empty `PAGI_ENV` mean `production`.
- Every nonempty value must exactly equal one canonical lowercase name; do not trim, lowercase, alias, or otherwise normalize it.
- Invalid nonempty values croak with `Invalid PAGI_ENV '<value>'; expected one of: development, test, staging, production`.
- `pagi_env`, `is_development`, `is_test`, `is_staging`, and `is_production` accept zero arguments; any argument croaks with `<function>() does not accept arguments`.
- Read `PAGI_ENV` on every helper call; do not cache it or infer test mode.
- Add all five helpers to optional exports, exactly those five to lowercase `:env`, and all five to existing lowercase `:all`. Add no default exports.
- Preserve the existing custom Utils import and `app_path` caller-origin registration behavior.
- Predicates delegate to `pagi_env`; they do not read `%ENV` independently or duplicate the allowed-value list.
- `PAGI::App::File` uses a fully-qualified Utils call at its existing diagnostic boundary. Do not import the predicate into the File package.
- Preserve App::File diagnostic text, STDOUT destination, placement, escaping, lexical-path behavior, and response/file events.
- Invalid environments are consulted only when the existing App::File diagnostic boundary is reached; earlier request/security rejections retain their behavior.
- Do not convert explicit middleware options named `development`, add another module, change `PAGI_HOME`, add dependencies, or modify unrelated examples.
- Keep library code compatible with Perl 5.18.
- Run focused tests during Tasks 1 and 2. Reserve one repository-wide `prove -lr t` for the final reviewed tree.
- Preserve the three unrelated untracked reports in the main checkout and every unrelated working-tree file.

## File Map

- Modify `lib/PAGI/Utils.pm`: strict accessor, predicates, tags, and POD.
- Create `t/utils-environment.t`: complete canonical environment and export contract.
- Modify `lib/PAGI/App/File.pm`: fully-qualified predicate integration and POD.
- Modify `t/app-file.t`: supported silent modes, invalid failures, and pre-boundary rejection behavior.
- Modify `examples/app-01-file/README.md`: canonical environment behavior.
- Modify `Changes`: public environment utility and App::File adoption note.

## Execution Tracking and Baseline

Before Task 1, initialize the ignored execution ledger
`.superpowers/sdd/2026-08-11-pagi-environment-utils/progress.md` with this exact
first line:

```markdown
# SDD ledger — plan: docs/superpowers/plans/2026-08-11-pagi-environment-utils.md
```

Include starting HEAD, merge base, branch/worktree, one row per task, exact
test totals, commit SHAs, review evidence, and this deviation table:

```markdown
| ID | Status | Conflicting spec/plan text | Evidence and rationale | Affected tasks | User decision |
|---|---|---|---|---|---|
```

No worker may build on a specification deviation before its ID, rationale,
and user decision are recorded.

Run the pre-change baseline in the isolated worktree:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/utils-app-path.t t/utils/is-response.t t/utils-to-app.t t/utils-lifespan.t t/app-file.t t/integration-app-file-demo.t t/00-load.t'
```

Expected: PASS. Record exact Files/Tests totals. Do not run the full suite.

---

### Task 1: Add the Strict Environment Contract to PAGI::Utils

**Files:**
- Modify: `lib/PAGI/Utils.pm`
- Create: `t/utils-environment.t`

**Interfaces:**
- Produces: `pagi_env() -> Str`; `is_development() -> Bool`; `is_test() -> Bool`; `is_staging() -> Bool`; `is_production() -> Bool`; export tags `:env` and updated `:all`.
- Consumes: core `%ENV`, `Carp::croak`, and the existing custom `PAGI::Utils::import` wrapper.

- [ ] **Step 1: Write the failing environment contract test**

Create `t/utils-environment.t`:

```perl
use strict;
use warnings;
use Test2::V0;
use PAGI::Utils qw(:env);

my @canonical = qw(development test staging production);
my @predicates = (
    [development => \&is_development],
    [test        => \&is_test],
    [staging     => \&is_staging],
    [production  => \&is_production],
);

subtest 'unset and empty default to production' => sub {
    local $ENV{PAGI_ENV};
    delete $ENV{PAGI_ENV};
    is(pagi_env(), 'production', 'unset defaults safely');
    ok(is_production(), 'unset satisfies the production predicate');

    $ENV{PAGI_ENV} = '';
    is(pagi_env(), 'production', 'empty defaults safely');
    ok(is_production(), 'empty satisfies the production predicate');
};

subtest 'canonical values and predicates share one contract' => sub {
    for my $environment (@canonical) {
        local $ENV{PAGI_ENV} = $environment;
        is(pagi_env(), $environment, "$environment is returned unchanged");
        for my $predicate (@predicates) {
            my ($name, $code) = @$predicate;
            is($code->() ? 1 : 0, $name eq $environment ? 1 : 0,
                "$name predicate for $environment");
        }
    }
};

subtest 'lookup is dynamic rather than cached' => sub {
    local $ENV{PAGI_ENV} = 'development';
    is(pagi_env(), 'development', 'first call sees development');
    $ENV{PAGI_ENV} = 'staging';
    is(pagi_env(), 'staging', 'next call sees the localized change');
    ok(is_staging(), 'predicate sees the same change');
};

subtest 'invalid nonempty values fail with the canonical list' => sub {
    for my $invalid ('Development', ' development', 'development ',
        'dev', 'prod', 'developement') {
        local $ENV{PAGI_ENV} = $invalid;
        like(
            dies { pagi_env() },
            qr/Invalid PAGI_ENV '\Q$invalid\E'; expected one of: development, test, staging, production/,
            "rejects [$invalid]",
        );
    }
};

subtest 'public helpers reject every argument' => sub {
    my @calls = (
        [pagi_env       => sub { pagi_env(undef) }],
        [is_development => sub { is_development('development') }],
        [is_test        => sub { is_test(undef) }],
        [is_staging     => sub { is_staging('staging') }],
        [is_production  => sub { is_production('production') }],
    );
    for my $call (@calls) {
        my ($name, $code) = @$call;
        like(dies { $code->() }, qr/\Q$name\E\(\) does not accept arguments/,
            "$name rejects arguments");
    }
};

subtest 'exports are optional and bundled' => sub {
    my @helpers = qw(pagi_env is_development is_test is_staging is_production);

    eval q{ package Local::NoEnvironmentExports; PAGI::Utils->import(); 1 }
        or die $@;
    ok(!Local::NoEnvironmentExports->can($_), "$_ is not default-exported")
        for @helpers;

    eval q{ package Local::EnvironmentExports; PAGI::Utils->import(':env'); 1 }
        or die $@;
    ok(Local::EnvironmentExports->can($_), ":env exports $_") for @helpers;
    ok(!Local::EnvironmentExports->can('app_path'),
        ':env contains no unrelated Utils helper');

    eval q{ package Local::AllUtilsExports; PAGI::Utils->import(':all'); 1 }
        or die $@;
    ok(Local::AllUtilsExports->can($_), ":all exports $_") for @helpers;
    ok(Local::AllUtilsExports->can('app_path'),
        ':all retains existing Utils helpers');

    is([sort @{$PAGI::Utils::EXPORT_TAGS{env}}], [sort @helpers],
        ':env contains exactly the five environment helpers');
};

done_testing;
```

- [ ] **Step 2: Run the new test and verify RED**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/utils-environment.t'
```

Expected: FAIL during import because `:env` and the five helpers do not exist.

- [ ] **Step 3: Implement the one canonical accessor and predicates**

Near the export declarations in `lib/PAGI/Utils.pm`, add one private ordered
list, lookup, and tag list:

```perl
my @PAGI_ENVIRONMENTS = qw(development test staging production);
my %VALID_PAGI_ENV = map { $_ => 1 } @PAGI_ENVIRONMENTS;
my @ENV_EXPORTS = qw(
    pagi_env is_development is_test is_staging is_production
);

our @EXPORT_OK = (
    qw(handle_lifespan to_app is_response app_path),
    @ENV_EXPORTS,
);
our %EXPORT_TAGS = (
    all => \@EXPORT_OK,
    env => \@ENV_EXPORTS,
);
```

Add the helpers before `app_path`:

```perl
sub pagi_env {
    croak 'pagi_env() does not accept arguments' if @_;

    my $environment = $ENV{PAGI_ENV};
    return 'production' unless defined $environment && length $environment;
    croak "Invalid PAGI_ENV '$environment'; expected one of: "
        . join(', ', @PAGI_ENVIRONMENTS)
        unless $VALID_PAGI_ENV{$environment};
    return $environment;
}

sub _environment_predicate {
    my ($function, $expected, @arguments) = @_;
    croak "$function() does not accept arguments" if @arguments;
    return pagi_env() eq $expected ? 1 : 0;
}

sub is_development {
    return _environment_predicate('is_development', 'development', @_);
}

sub is_test {
    return _environment_predicate('is_test', 'test', @_);
}

sub is_staging {
    return _environment_predicate('is_staging', 'staging', @_);
}

sub is_production {
    return _environment_predicate('is_production', 'production', @_);
}
```

Do not change `import`, `app_path`, or the caller-origin cache.

- [ ] **Step 4: Document the environment helpers and bundles**

Add a Utils SYNOPSIS example using `qw(:env)`. Add POD sections for
`pagi_env` and the four predicates that state the exact four values, safe
production default, strict nonempty validation, dynamic lookup, zero-argument
contract, and predicate use. Document `:env` as exactly the five functions and
`:all` as every optional helper.

- [ ] **Step 5: Run Task 1 GREEN and regression verification**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/utils-environment.t t/utils-app-path.t t/utils/is-response.t t/utils-to-app.t t/utils-lifespan.t'
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -c lib/PAGI/Utils.pm && podchecker lib/PAGI/Utils.pm'
git diff --check
```

Expected: tests PASS; syntax and POD report OK; diff check is clean. Record the
known standalone Utils/Lifespan circular-load redefinition warnings separately
if they appear.

- [ ] **Step 6: Commit Task 1 and update its ledger row**

```bash
git add lib/PAGI/Utils.pm t/utils-environment.t
git commit -m "feat: add canonical PAGI environment helpers"
```

Record SHA, RED/GREEN commands, exact totals, syntax/POD evidence, and review
status in the ignored Task 1 ledger row in the same step.

---

### Task 2: Make PAGI::App::File Use the Environment Contract

**Files:**
- Modify: `lib/PAGI/App/File.pm`
- Modify: `t/app-file.t`
- Modify: `examples/app-01-file/README.md`
- Modify: `Changes`

**Interfaces:**
- Consumes: `PAGI::Utils::is_development() -> Bool` from Task 1.
- Produces: App::File diagnostics gated through the canonical contract without moving the request-time boundary.

- [ ] **Step 1: Rewrite the App::File environment tests before production code**

In `t/app-file.t`, replace the current nondevelopment loop with supported
silent modes only:

```perl
subtest 'supported nondevelopment modes stay silent at request time' => sub {
    for my $mode (undef, '', 'test', 'staging', 'production') {
        local $ENV{PAGI_ENV};
        defined $mode ? ($ENV{PAGI_ENV} = $mode) : delete $ENV{PAGI_ENV};
        my ($response, $stdout, $stderr) = capture_output(sub {
            return $client->get('/marker.txt');
        });
        my $label = defined $mode && length $mode ? $mode
            : defined $mode ? 'empty' : 'unset';
        is($response->status, 200, "request succeeds for $label");
        is($stdout, '', "STDOUT is silent for $label");
        is($stderr, '', "STDERR is silent for $label");
    }
};
```

Add the strict failure subtest:

```perl
subtest 'invalid environments fail when diagnostics are consulted' => sub {
    for my $mode ('Development', 'none') {
        local $ENV{PAGI_ENV} = $mode;
        like(
            dies { capture_output(sub { $client->get('/marker.txt') }) },
            qr/Invalid PAGI_ENV '\Q$mode\E'; expected one of: development, test, staging, production/,
            "invalid [$mode] fails loudly",
        );
    }
};
```

Extend the rejection test to run its cases once with `development` and once
with invalid `Development`. Both must retain their status and avoid a
file-attempt record because they return before the environment helper boundary.

Add a source-shape assertion that `lib/PAGI/App/File.pm` contains the
fully-qualified `PAGI::Utils::is_development()` call and no direct
`$ENV{PAGI_ENV}` read.

- [ ] **Step 2: Run App::File RED**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/app-file.t'
```

Expected: FAIL because invalid values are still treated as silent
nondevelopment modes and the source still reads `$ENV{PAGI_ENV}` directly.
Existing supported-mode and rejected-request behavior remains green.

- [ ] **Step 3: Replace the direct environment comparison**

Change only the gate in `_development_file_attempt`:

```perl
sub _development_file_attempt {
    my ($file_path) = @_;
    require PAGI::Utils;
    return unless PAGI::Utils::is_development();

    my $display = $file_path;
    $display =~ s/([\x00-\x1f\x7f])/sprintf('\\x%02X', ord($1))/ge;
    print STDOUT "PAGI::App::File: attempting $display\n";
    return;
}
```

Do not import Utils at file scope and do not move the helper call within the
request path.

- [ ] **Step 4: Update App::File and example documentation**

Revise the App::File development-diagnostic POD so it states:

- `development` enables output;
- unset, empty, `test`, `staging`, and `production` are silent;
- invalid nonempty values fail through `PAGI::Utils/pagi_env`;
- rejected requests before the diagnostic boundary still do not inspect the
  environment.

Update `examples/app-01-file/README.md` with the same canonical values and
strict typo behavior. Do not change example code.

- [ ] **Step 5: Update Changes**

Add one `0.002003` bullet stating that `PAGI::Utils` now exports `pagi_env` and
the four predicates through `:env`/`:all`, that unset/empty safely mean
production, and that invalid nonempty values croak. State that App::File uses
`is_development` at its existing request-time diagnostic boundary.

- [ ] **Step 6: Run Task 2 GREEN and focused integration verification**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/app-file.t t/utils-environment.t t/integration-app-file-demo.t t/integration-app-file-examples.t t/00-load.t'
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -c lib/PAGI/App/File.pm && podchecker lib/PAGI/App/File.pm'
git diff --check
```

Expected: tests PASS; syntax/POD report OK; diff check is clean.

- [ ] **Step 7: Commit Task 2 and update its ledger row**

```bash
git add lib/PAGI/App/File.pm t/app-file.t examples/app-01-file/README.md Changes
git commit -m "refactor: centralize App File environment checks"
```

Record exact verification and independent review evidence in the Task 2
ledger row.

---

### Task 3: Complete-Range Audit, Review, and Verification

**Files:**
- Verify: every Task 1 and Task 2 file
- Verify: `docs/superpowers/specs/2026-08-11-pagi-environment-utils-design.md`
- Update: `.superpowers/sdd/2026-08-11-pagi-environment-utils/progress.md` (ignored execution evidence only)

**Interfaces:**
- Consumes: the two reviewed feature commits.
- Produces: evidence that all direct production `PAGI_ENV` interpretation is centralized and the repository passes on the final reviewed tree.

- [ ] **Step 1: Audit the exact range and environment reads**

Run:

```bash
git status --short
git log --oneline main..HEAD
git diff --stat main...HEAD
git diff --check main...HEAD
rg -n "PAGI_ENV|pagi_env|is_development|is_test|is_staging|is_production" lib t examples Changes
git diff --name-only main...HEAD
```

Confirm explicitly:

```text
- PAGI::Utils owns the sole production PAGI_ENV read and canonical list;
- five helpers are optional, in :env, and in :all, with no defaults;
- predicates delegate and all helpers reject arguments;
- lookup is dynamic and strict, with safe production default;
- App::File contains no direct PAGI_ENV read and calls the fully-qualified predicate;
- the App::File diagnostic boundary/output/response behavior is unchanged;
- invalid values fail only when the environment boundary is reached;
- no middleware development options, PAGI_HOME behavior, dependencies, new modules, or unrelated examples changed.
```

- [ ] **Step 2: Run the focused final contract gate**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/utils-environment.t t/utils-app-path.t t/utils/is-response.t t/utils-to-app.t t/utils-lifespan.t t/app-file.t t/integration-app-file-demo.t t/integration-app-file-examples.t t/00-load.t'
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -c lib/PAGI/Utils.pm && perl -Ilib -c lib/PAGI/App/File.pm && podchecker lib/PAGI/Utils.pm && podchecker lib/PAGI/App/File.pm'
git diff --check main...HEAD
```

Expected: PASS. Record exact Files/Tests totals and the known standalone
Utils/Lifespan circular-load warnings separately if they appear.

- [ ] **Step 3: Obtain independent whole-range review**

Package `main...HEAD` with the design and this plan. Require review of exact
environment semantics, error diagnostics, argument rejection, exports/custom
import behavior, dynamic lookup, Perl 5.18 compatibility, App::File lifecycle
placement and security rejections, documentation, test quality, and scope.
Findings must be Critical/Important/Minor with file:line evidence and an
explicit ready/not-ready conclusion. Resolve all findings before the suite;
record and ask about any finding that conflicts with the approved design.

- [ ] **Step 4: Run the one final repository suite**

After review is clean, run once outside the restricted socket sandbox when
required by the SSE end-to-end test:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t'
```

Expected: `Result: PASS`. Record exact Files/Tests and timing. If a real defect
appears, preserve RED, apply one scoped TDD fix, obtain scoped re-review, and
run one replacement suite because the tree changed. Replace an
environment-invalid run once; do not repeat a valid green run for confidence.

- [ ] **Step 5: Close tracking and finish the branch**

Mark Task 3 complete and confirm:

```bash
git status --short
git diff --check main...HEAD
git log --oneline main..HEAD
```

Remove only this plan's validated ignored SDD workspace and temporary script
copies. Then use `superpowers:finishing-a-development-branch` to offer local
merge, PR, or preservation. Do not merge or push without the user's choice.
