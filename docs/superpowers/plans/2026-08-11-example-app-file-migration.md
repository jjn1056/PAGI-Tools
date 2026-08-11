# Remaining Example App::File Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate every remaining example `PAGI::App::File` consumer to `app_path`, preserve runtime behavior, and remove redundant `use warnings` pragmas from the Perl 5.40 large application.

**Architecture:** Root-level scripts resolve `public` beside their own `app.pl` and compile the returned component only when their manual dispatchers need a native application. Router examples mount the component directly. Focused integration tests inventory the complete example surface and make real static requests, while the existing large-application and Endpoint Router integration tests own their module-layout assertions.

**Tech Stack:** Perl, `Future::AsyncAwait`, `Test2::V0`, `PAGI::Test::Client`, POD/Markdown documentation, and `prove` under the project Perl 5.42.2 environment.

**Design:** `docs/superpowers/specs/2026-08-11-example-app-file-migration-design.md`

## Global Constraints

- Every example application using `PAGI::App::File` must use `PAGI::App::File->app_path(...)`; no example may retain `PAGI::App::File->new(root => ...)`.
- Root-level manual dispatchers compile the returned component with `->to_app`; routers mount the returned component without `->to_app`.
- Preserve the contact form's explicit writable `uploads` path. `PAGI::App::File->app_path` is not a general path-string helper.
- Remove `File::Basename` and `File::Spec` only where the migration makes them unused.
- Remove redundant `use warnings;` only from the six files already declaring `use v5.40;` in `examples/15-large-application`.
- Do not convert other examples to Perl 5.40, signatures, or a different routing style.
- Do not change routing, endpoint, SSE, upload, lifespan, file-serving, or response behavior.
- Do not modify `lib/PAGI/App/File.pm`, `lib/PAGI/Utils.pm`, dependency metadata, or PAGI-Server.
- Update the four affected example READMEs concisely and update `Changes` only after the complete migration is true.
- Use `PAGI::Test::Client` for real static requests; do not settle for source-string assertions alone.
- Run focused tests during Tasks 1 and 2. Reserve one repository-wide `prove -lr t` for the final reviewed tree.
- Preserve the three unrelated untracked root reports and all unrelated working-tree files.

## File Map

- Create `t/integration-app-file-examples.t`: inventory and runtime checks for the three root-level examples.
- Modify `examples/endpoint-demo/app.pl`: direct component mount using script fallback.
- Modify `examples/endpoint-demo/README.md`: show the mounted component shape.
- Modify `examples/sse-dashboard/app.pl`: compiled `public` application using script fallback.
- Modify `examples/sse-dashboard/README.md`: show the manual-dispatcher shape.
- Modify `examples/13-contact-form/app.pl`: compiled `public` application while retaining the writable upload path.
- Modify `examples/13-contact-form/README.md`: distinguish static component resolution from upload storage.
- Modify `t/integration-endpoint-router-demo.t`: module-layout source shape and real static request.
- Modify `examples/endpoint-router-demo/lib/MyApp/Main.pm`: direct module-relative component mount.
- Modify `examples/endpoint-router-demo/README.md`: document the module-layout constructor form.
- Modify the six Perl files under `examples/15-large-application`: remove redundant `use warnings` only.
- Modify `t/integration-large-application.t`: assert `v5.40` supplies warnings without the extra pragma.
- Modify `Changes`: record that every example File consumer now uses the constructor and the large example has one language declaration.

## Execution Tracking and Baseline

Before Task 1, initialize the ignored execution ledger
`.superpowers/sdd/2026-08-11-example-app-file-migration/progress.md` with its
first line exactly:

```markdown
# SDD ledger — plan: docs/superpowers/plans/2026-08-11-example-app-file-migration.md
```

Include the starting HEAD, branch/worktree path, one row per task, exact test
totals, commit SHAs, review evidence, and this deviation table:

```markdown
| ID | Status | Conflicting spec/plan text | Evidence and rationale | Affected tasks | User decision |
|---|---|---|---|---|---|
```

No worker may build on a specification deviation until it has a recorded ID,
rationale, and user decision.

Run the pre-change baseline in the isolated implementation worktree:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-app-file-demo.t t/integration-endpoint-router-demo.t t/integration-large-application.t t/app-file.t'
```

Expected: PASS. Record exact Files/Tests totals. Do not run the full suite.

---

### Task 1: Migrate the Root-Level Example Applications

**Files:**
- Create: `t/integration-app-file-examples.t`
- Modify: `examples/endpoint-demo/app.pl`
- Modify: `examples/endpoint-demo/README.md`
- Modify: `examples/sse-dashboard/app.pl`
- Modify: `examples/sse-dashboard/README.md`
- Modify: `examples/13-contact-form/app.pl`
- Modify: `examples/13-contact-form/README.md`

**Interfaces:**
- Consumes: `PAGI::App::File->app_path(@components) -> PAGI::App::File` and `PAGI::App::File->to_app -> CodeRef`.
- Produces: three root-level examples whose `public` roots resolve beside their own `app.pl`, plus an integration test that later audits rely on.

- [ ] **Step 1: Write the focused source-shape and runtime test**

Create `t/integration-app-file-examples.t` with this structure:

```perl
use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use PAGI::Test::Client;

sub source_text {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot open $path: $!";
    local $/;
    my $source = <$fh>;
    close $fh or die "cannot close $path: $!";
    return $source;
}

my @cases = (
    {
        name  => 'endpoint demo',
        file  => "$Bin/../examples/endpoint-demo/app.pl",
        title => qr/PAGI Endpoint Demo/,
        shape => qr{mount\('/'\s*=>\s*PAGI::App::File->app_path\('public'\)\)},
    },
    {
        name  => 'SSE dashboard',
        file  => "$Bin/../examples/sse-dashboard/app.pl",
        title => qr/PAGI Live Dashboard/,
        shape => qr{PAGI::App::File->app_path\('public'\)->to_app},
    },
    {
        name  => 'contact form',
        file  => "$Bin/../examples/13-contact-form/app.pl",
        title => qr/Contact Form/,
        shape => qr{PAGI::App::File->app_path\('public'\)->to_app},
    },
);

for my $case (@cases) {
    subtest $case->{name} => sub {
        my $source = source_text($case->{file});
        like($source, $case->{shape}, 'uses the application-relative constructor');
        unlike($source, qr/PAGI::App::File->new\s*\(/,
            'contains no manual App File constructor');

        local $ENV{PAGI_HOME};
        delete $ENV{PAGI_HOME};
        local $ENV{PAGI_ENV} = 'production';
        my $app = do $case->{file};
        my $load_error = $@ || $!;
        ok(!$load_error, 'loads cleanly') or diag($load_error);
        is(ref($app), 'CODE', 'returns a native PAGI application');

        SKIP: {
            skip 'example did not load', 2 unless ref($app) eq 'CODE';
            my $response = PAGI::Test::Client->new(app => $app)->get('/');
            is($response->status, 200, 'static index responds');
            like($response->text, $case->{title}, 'index comes from the public root');
        }
    };
}

my $endpoint = source_text($cases[0]{file});
unlike($endpoint, qr/File::Basename|File::Spec|dirname\s*\(/,
    'endpoint demo has no obsolete path arithmetic');

my $dashboard = source_text($cases[1]{file});
unlike($dashboard, qr/File::Basename|File::Spec|dirname\s*\(/,
    'SSE dashboard has no obsolete path arithmetic');

my $contact = source_text($cases[2]{file});
like($contact,
    qr/my \$UPLOAD_DIR = File::Spec->catdir\(dirname\(__FILE__\), 'uploads'\)/,
    'contact form retains its explicit writable upload path');
unlike($contact, qr/\$PUBLIC_DIR/,
    'contact form no longer calculates a static public path');

done_testing;
```

- [ ] **Step 2: Run the new test and verify the intended RED state**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-app-file-examples.t'
```

Expected: FAIL on the new constructor/import source-shape assertions. Existing
static runtime requests should remain green, proving the failure is about the
migration rather than broken fixtures.

- [ ] **Step 3: Replace manual roots with the correct constructor forms**

In `examples/endpoint-demo/app.pl`, remove the `File::Basename` and
`File::Spec` imports and replace the final mount with:

```perl
$router->mount('/' => PAGI::App::File->app_path('public'));
```

In `examples/sse-dashboard/app.pl`, remove the two path imports and replace
the two-line root construction with:

```perl
my $static_app = PAGI::App::File->app_path('public')->to_app;
```

In `examples/13-contact-form/app.pl`, delete only `$PUBLIC_DIR` and replace
the static application construction with:

```perl
my $static_app = PAGI::App::File->app_path('public')->to_app;
```

Keep these lines because uploads need a writable path string:

```perl
use File::Basename qw(dirname);
use File::Spec;
my $UPLOAD_DIR = File::Spec->catdir(dirname(__FILE__), 'uploads');
```

- [ ] **Step 4: Update the three README files concisely**

Add the exact canonical form to each README near its static-file feature or
route description:

```perl
# endpoint-demo: Router consumes the component
$router->mount('/' => PAGI::App::File->app_path('public'));

# sse-dashboard and 13-contact-form: manual dispatchers invoke a compiled app
my $static_app = PAGI::App::File->app_path('public')->to_app;
```

In the contact README, add one sentence stating that only `public` uses the
component constructor; writable uploads retain their explicit filesystem
path.

- [ ] **Step 5: Run focused GREEN verification**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-app-file-examples.t t/integration-app-file-demo.t t/app-file.t'
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -c examples/endpoint-demo/app.pl && perl -Ilib -c examples/sse-dashboard/app.pl && perl -Ilib -c examples/13-contact-form/app.pl'
git diff --check
```

Expected: all tests PASS; all three scripts report `syntax OK`; diff check is
clean. Record the harmless existing final-expression warning separately if a
script emits it.

- [ ] **Step 6: Commit Task 1 and update its ledger row**

Stage only the seven Task 1 paths and commit:

```bash
git add t/integration-app-file-examples.t \
  examples/endpoint-demo/app.pl examples/endpoint-demo/README.md \
  examples/sse-dashboard/app.pl examples/sse-dashboard/README.md \
  examples/13-contact-form/app.pl examples/13-contact-form/README.md
git commit -m "examples: migrate root App File consumers"
```

Update the ignored Task 1 row with the SHA, RED/GREEN evidence, exact totals,
and review status in the same step.

---

### Task 2: Migrate the Module Example and Simplify Perl 5.40 Headers

**Files:**
- Modify: `t/integration-endpoint-router-demo.t`
- Modify: `examples/endpoint-router-demo/lib/MyApp/Main.pm`
- Modify: `examples/endpoint-router-demo/README.md`
- Modify: `t/integration-large-application.t`
- Modify: `examples/15-large-application/app.pl`
- Modify: `examples/15-large-application/lib/MyApp/Data.pm`
- Modify: `examples/15-large-application/lib/MyApp/Root.pm`
- Modify: `examples/15-large-application/lib/MyApp/Person.pm`
- Modify: `examples/15-large-application/lib/MyApp/Person/Blogs.pm`
- Modify: `examples/15-large-application/lib/MyApp/View.pm`
- Modify: `Changes`

**Interfaces:**
- Consumes: the same `PAGI::App::File->app_path('public')` component constructor and Perl's documented `use v5.40` strict/warnings bundle.
- Produces: no manual App File constructor anywhere under `examples`, one language declaration per large-app file, and release notes describing the completed migration.

- [ ] **Step 1: Add Endpoint Router source and runtime assertions**

In `t/integration-endpoint-router-demo.t`, add a `source_text` helper and this
subtest before the existing behavior subtest:

```perl
subtest 'Main mounts its application-relative public component' => sub {
    my $path = "$Bin/../examples/endpoint-router-demo/lib/MyApp/Main.pm";
    my $source = source_text($path);
    like($source,
        qr{mount\('/'\s*,\s*PAGI::App::File->app_path\('public'\)\)},
        'module-layout Router mounts the returned component');
    unlike($source, qr/PAGI::App::File->new\s*\(|File::Basename|File::Spec/,
        'module contains no manual static-root arithmetic');
};
```

Inside the existing `PAGI::Test::Client->run` callback, add:

```perl
my $static = $client->get('/index.html');
is($static->status, 200, 'mounted public file responds');
like($static->text, qr/Static file served!/, 'public file comes from the example root');
```

- [ ] **Step 2: Add the Perl 5.40 no-redundant-warning assertion**

In the existing source loop in `t/integration-large-application.t`, add:

```perl
unlike($source, qr/^use warnings;/m,
    "$path relies on the Perl 5.40 warning bundle");
```

- [ ] **Step 3: Run the two tests and verify the intended RED state**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-endpoint-router-demo.t t/integration-large-application.t'
```

Expected: FAIL on the Endpoint source-shape assertions and on six redundant
`use warnings` assertions. Existing runtime behavior, including the static
request added in Step 1, should pass before the migration.

- [ ] **Step 4: Migrate `MyApp::Main`**

Remove these imports from `examples/endpoint-router-demo/lib/MyApp/Main.pm`:

```perl
use File::Basename qw(dirname);
use File::Spec;
```

Replace the manual root and mount with:

```perl
$r->mount('/', PAGI::App::File->app_path('public'));
```

Do not call `to_app`; the Endpoint Router builder accepts the component.

- [ ] **Step 5: Remove only the six redundant warning pragmas**

Delete `use warnings;` immediately following `use v5.40;` from exactly the six
large-application source files listed in this task. Leave every `use v5.40;`
line and all test-file `use warnings;` pragmas intact.

- [ ] **Step 6: Update Endpoint documentation and release notes**

Add this form to `examples/endpoint-router-demo/README.md` where it describes
the static-file mount:

```perl
$r->mount('/', PAGI::App::File->app_path('public'));
```

Explain in one sentence that `MyApp::Main` lives under `lib/MyApp/Main.pm`, so
the constructor resolves `public` from the example root.

In the existing `0.002003` App File bullet in `Changes`, replace the partial
example statement with wording that says all example applications using
`PAGI::App::File` now use the constructor. Add that the Perl 5.40 large
application relies on its version declaration for strictures and warnings.

- [ ] **Step 7: Run Task 2 focused GREEN verification**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-endpoint-router-demo.t t/integration-large-application.t t/integration-app-file-examples.t t/app-file.t'
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -Iexamples/endpoint-router-demo/lib -c examples/endpoint-router-demo/lib/MyApp/Main.pm'
git diff --check
```

Expected: tests PASS, the module reports `syntax OK`, and diff check is clean.

- [ ] **Step 8: Commit Task 2 and update its ledger row**

Stage only the Task 2 files and commit:

```bash
git add Changes t/integration-endpoint-router-demo.t \
  examples/endpoint-router-demo/lib/MyApp/Main.pm \
  examples/endpoint-router-demo/README.md \
  t/integration-large-application.t \
  examples/15-large-application/app.pl \
  examples/15-large-application/lib/MyApp/Data.pm \
  examples/15-large-application/lib/MyApp/Root.pm \
  examples/15-large-application/lib/MyApp/Person.pm \
  examples/15-large-application/lib/MyApp/Person/Blogs.pm \
  examples/15-large-application/lib/MyApp/View.pm
git commit -m "examples: finish App File constructor migration"
```

Update the ignored Task 2 row with exact verification and independent review
evidence.

---

### Task 3: Complete-Range Audit, Review, and Verification

**Files:**
- Verify: all Task 1 and Task 2 files
- Verify: `docs/superpowers/specs/2026-08-11-example-app-file-migration-design.md`
- Update: `.superpowers/sdd/2026-08-11-example-app-file-migration/progress.md` (ignored execution evidence only)

**Interfaces:**
- Consumes: the two reviewed migration commits.
- Produces: evidence that every example uses the constructor correctly and the repository suite passes on the final reviewed tree.

- [ ] **Step 1: Audit every example consumer and the exact scope**

Run:

```bash
git status --short
git log --oneline main..HEAD
git diff --stat main...HEAD
git diff --check main...HEAD
rg -n "PAGI::App::File" examples
rg -n "PAGI::App::File->new\s*\(" examples
rg -n "^use v5[.]40;|^use warnings;" examples/15-large-application
git diff --name-only main...HEAD
```

Confirm explicitly:

```text
- every example App::File consumer uses app_path;
- only manual dispatchers call to_app;
- Router mounts consume components directly;
- contact uploads retain an explicit writable path;
- path imports remain only where still used;
- all six large-app files use v5.40 without use warnings;
- no library, dependency, server, routing, SSE, upload, lifespan, or unrelated example changes entered the range.
```

The second `rg` must return no matches; record that exit status as the expected
clean inventory result rather than a command failure.

- [ ] **Step 2: Run the focused final contract gate**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-app-file-examples.t t/integration-app-file-demo.t t/integration-endpoint-router-demo.t t/integration-large-application.t t/app-file.t t/00-load.t'
git diff --check main...HEAD
```

Expected: PASS. Record exact Files/Tests totals.

- [ ] **Step 3: Obtain independent whole-range review**

Package `main...HEAD` with the design and this plan. Require the reviewer to
check all constructor shapes, caller-origin semantics, contact upload-path
preservation, removed-import correctness, README/Changes accuracy, static
runtime coverage, Perl 5.40 warning semantics, dependency/scope boundaries,
and test quality. Findings must be grouped Critical, Important, and Minor with
file/line evidence and an explicit ready/not-ready conclusion.

Resolve every finding before the final suite. If a finding conflicts with the
approved design, record a deviation and obtain user direction before changing
course.

- [ ] **Step 4: Run the one repository-wide suite on the reviewed tree**

Run once, outside the restricted socket sandbox when needed by the SSE
end-to-end test:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t'
```

Expected: `Result: PASS`. Record exact Files/Tests and timing. If the run finds
a real defect, preserve it as RED, apply one scoped TDD fix, obtain scoped
re-review, and run one replacement suite because the tree changed. Replace an
environment-invalid run once in the correct environment; do not repeat a valid
green run for confidence.

- [ ] **Step 5: Close tracking and finish the branch**

Mark Task 3 complete with focused, review, and full-suite evidence. Confirm:

```bash
git status --short
git diff --check main...HEAD
git log --oneline main..HEAD
```

Remove only this plan's validated ignored SDD workspace and temporary script
copies. Then use `superpowers:finishing-a-development-branch` to offer local
merge, PR, or branch preservation. Do not merge or push without the user's
integration choice.
