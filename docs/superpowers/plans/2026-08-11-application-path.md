# Application Path Helper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a platform-aware `app_path` facility for functional and Endpoint applications, use it to remove static-root path arithmetic from the canonical large application, and finish by documenting immediate versus Future-backed request callables across the routing frontends.

**Architecture:** `PAGI::Utils` owns one origin-aware detector and path builder. The exported `app_path(@components)` supplies its immediate caller as the origin; `PAGI::Endpoint::Router->app_path(@components)` supplies its concrete loaded class and delegates to the same internal engine. Both return ordinary absolute strings, honor `PAGI_HOME`, use core path modules, and perform no filesystem mutation or existence checks. A final documentation-only task gives `PAGI::Routing` the canonical callable-completion contract and aligns the App Router, Endpoint Router, Tutorial, and Cookbook with it.

**Tech Stack:** Perl 5.18-compatible library and test code, Perl 5.40+ large-example code, core `File::Spec` and `File::Basename`, `Exporter`, `Scalar::Util`, Test2::V0, PAGI::Endpoint::Router, PAGI::App::File, and PAGI::Test::Client. No new runtime dependency.

## Global Constraints

- Implement the approved contract in `docs/superpowers/specs/2026-08-11-application-path-design.md`. If implementation evidence conflicts with it, record a deviation and obtain the user's decision before dependent work continues.
- Preserve the unrelated untracked files `.cpan-testers-fix-report.md`, `.csrf-helper-brief.md`, and `.csrf-helper-report.md`. Never stage them.
- Keep `lib/PAGI/Utils.pm`, `lib/PAGI/Endpoint/Router.pm`, fixtures, and ordinary tests parseable on Perl 5.18. Do not add signatures or newer syntax there.
- Keep the existing Perl 5.40 signatures in `examples/15-large-application`; do not modernize or rewrite unrelated example code.
- Add no runtime dependency. Use core `File::Spec` for platform-aware decomposition, absolute-path checks, joining, and canonicalization; core `File::Basename` may remove already-validated directory components.
- `app_path()` returns the absolute detected application home. `app_path(@components)` returns an absolute child path. Both return plain strings.
- Treat `PAGI_HOME` as the first-precedence override when it is defined and nonempty. Make a relative override absolute from the current working directory. Do not require it to exist.
- For a conventional module, verify the complete package/file suffix before removing namespace directories, then remove trailing `lib` followed by trailing `blib`. Never scan ancestors for a conveniently named `lib`.
- For a script-style origin whose package/file suffix does not match, use the origin file's containing directory. Do not search for marker files.
- Join logical path components with `File::Spec`; documentation and examples pass one component per argument and never build paths with literal `/` or `\\` separators.
- Reject every supplied component that is undefined, empty, reference-valued, absolute, or carries a separate platform volume. Permit `.` and `..`; `File::Spec->canonpath` does not collapse `..`.
- Do not call `abs_path`, `realpath`, `stat`, `mkdir`, `open`, or another filesystem-observing/mutating operation from the helper. The returned path may not exist, and the helper is not a sandbox.
- Keep `_app_path_from_origin($package, $source, @components)` internal and non-exported. Do not add a public class argument, caller-depth option, `PAGI::Home` object, `app_dir`, or `app_file`.
- The Endpoint method must resolve from `ref($endpoint)` or its class invocant, not from `PAGI::Endpoint::Router.pm`. Use the concrete class's normal `%INC` entry first and the method caller source only for an inline class without an `%INC` entry.
- Keep Endpoint `app_path` an explicit ordinary helper. Overriding it affects calls to that method only; routing compilation must not invoke it automatically.
- Migrate only `examples/15-large-application`. Do not sweep other examples with existing path arithmetic.
- Document one completion rule across the routing frontends: a request-time callable may complete immediately or return a Future. Use an ordinary `sub` for immediate work and `async sub` plus `await` when the callable must sequence asynchronous work. Never teach `$future->get` inside request handling.
- Keep the three terminal contracts distinct: an HTTP Context handler resolves to a `PAGI::Response`; WebSocket/SSE Context handlers have inert resolved values after owning protocol work through `$c`; native `($scope, $receive, $send)` applications own event emission and have inert resolved values.
- Keep middleware's two phases distinct: its factory or `wrap` method synchronously returns a native app coderef at compilation, while that returned request-time app may complete immediately or through a Future.
- Use TDD for every behavior change: add the focused failing assertion, run it and record the expected failure, implement only that behavior, then rerun the focused gate.
- Stage only the files named by the active task. Never use `git add .` or `git add -A`.
- Run the repository-wide `prove -lr t` suite exactly once at the final reviewed HEAD in Task 5. This repository has no double-run cleanup-fixture rule. If the final run exposes a defect and the code changes, record that evidence and run one replacement final gate at the corrected HEAD.
- Run Perl commands through the project Perl:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/utils-app-path.t'
  ```

## Execution Tracking and Deviation Control

Before Task 1, create the isolated execution workspace through the selected
Superpowers execution skill. For subagent-driven execution, run:

```bash
/Users/jnapiorkowski/.codex/plugins/cache/openai-curated-remote/superpowers/6.2.0/skills/subagent-driven-development/scripts/sdd-workspace docs/superpowers/plans/2026-08-11-application-path.md
```

The workspace command must identify a directory ending in
`.superpowers/sdd/2026-08-11-application-path`. Create `progress.md` there with:

```markdown
# SDD ledger — plan: docs/superpowers/plans/2026-08-11-application-path.md

| Task | Status | Commit SHA | Focused verification | Full-suite verification | Review |
|---|---|---|---|---|---|
| 1 | pending | — | — | deferred to Task 5 | — |
| 2 | pending | — | — | deferred to Task 5 | — |
| 3 | pending | — | — | deferred to Task 5 | — |
| 4 | pending | — | — | deferred to Task 5 | — |
| 5 | pending | — | — | final gate | — |

## Deviations

| ID | Status | Conflicting spec/plan text | Evidence and rationale | Affected tasks | User decision |
|---|---|---|---|---|---|
```

Run `git rev-parse HEAD` once. Add its exact 40-character output immediately
below the ledger heading as `Starting HEAD: SHA`, and save the same SHA with one
trailing newline in `.superpowers/sdd/2026-08-11-application-path/starting-head`.
Also record the initial `git status --short` and this focused baseline without
running the whole suite:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/utils-to-app.t t/endpoint-router.t t/integration-large-application.t'
```

The coordinator owns the ledger. Update a task row in the same working step as
its commit/review. Record exact commands, exit statuses, real file/assertion
counts, elapsed time, commit SHA, and reviewer evidence—never estimates or a
worker's unsupported summary.

A contract conflict receives the next stable ID (`D-001`, `D-002`, and so on),
status `awaiting decision`, exact conflicting text, concrete evidence, and all
affected tasks. Stop dependent work until the user decides, then record that
decision. An ordinary implementation defect whose fix preserves the contract
is not a deviation.

## File and Responsibility Map

- `lib/PAGI/Utils.pm`: public functional `app_path`, internal origin-aware home detector, shared component validation/path joining, export bundle, and functional POD.
- `t/utils-app-path.t`: functional behavior, environment precedence, portable joining, validation, side-effect boundary, and export coverage.
- `t/lib/TestApps/AppPath/Root.pm`: conventional `t/lib` function-call fixture.
- `t/app-path-fixtures/blib/lib/TestApps/AppPath/BlibRoot.pm`: conventional `blib/lib` function-call fixture.
- `lib/PAGI/Endpoint/Router.pm`: class/object `app_path` frontend, concrete `%INC` source selection, inline-class fallback, and Endpoint POD.
- `t/lib/TestApps/AppPath/Endpoint.pm`: concrete loaded Endpoint subclass fixture.
- `t/endpoint-router.t`: Endpoint public surface and object/class/inline delegation coverage.
- `examples/15-large-application/lib/MyApp/Root.pm`: canonical `app_path('static')` usage.
- `examples/15-large-application/README.md`: convention, override, and bootstrap explanation.
- `t/integration-large-application.t`: source-shape regression plus existing real `/static/app.css` request.
- `lib/PAGI/Routing.pm`: canonical callable-completion rule and distinct Context/raw/middleware contracts.
- `lib/PAGI/App/Router.pm`: mutable-frontend handler and raw-app completion guidance.
- `lib/PAGI/Endpoint/Router.pm`: method-handler, `app_as`, and `middleware_as` completion guidance.
- `lib/PAGI/Tools/Tutorial.pod`: first-principles synchronous versus asynchronous examples for native apps and Context handlers.
- `lib/PAGI/Tools/Cookbook.pod`: side-by-side recipes for immediate handlers, asynchronous database handlers, raw event owners, and middleware.

---

### Task 1: Build the Shared Functional Path Facility

**Files:**

- Create: `t/utils-app-path.t`
- Create: `t/lib/TestApps/AppPath/Root.pm`
- Create: `t/app-path-fixtures/blib/lib/TestApps/AppPath/BlibRoot.pm`
- Modify: `lib/PAGI/Utils.pm:5-12`
- Modify: `lib/PAGI/Utils.pm:14-69`
- Modify: `lib/PAGI/Utils.pm:77-146`

**Interfaces:**

- Consumes: immediate `caller` package/source, optional nonempty `$ENV{PAGI_HOME}`, and zero or more relative scalar path components.
- Produces: exported `app_path(@components) -> Str` and internal `PAGI::Utils::_app_path_from_origin($package, $source, @components) -> Str`.
- Guarantees: absolute platform-canonical string output, no existence requirement or filesystem side effect, exact package-suffix detection, and stable validation croaks.

- [ ] **Step 1: Add conventional source-layout fixtures**

Create `t/lib/TestApps/AppPath/Root.pm`:

```perl
package TestApps::AppPath::Root;

use strict;
use warnings;
use PAGI::Utils qw(app_path);

sub home  { return app_path() }
sub child { shift; return app_path(@_) }

1;
```

Create `t/app-path-fixtures/blib/lib/TestApps/AppPath/BlibRoot.pm`:

```perl
package TestApps::AppPath::BlibRoot;

use strict;
use warnings;
use PAGI::Utils qw(app_path);

sub home { return app_path() }

1;
```

- [ ] **Step 2: Write the failing functional tests**

Create `t/utils-app-path.t` with ordinary Perl 5.18 syntax. Start with these
imports and helpers:

```perl
use strict;
use warnings;
use Test2::V0;
use Cwd qw(getcwd);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

use lib 'lib';
use lib "$Bin/lib";
use lib "$Bin/app-path-fixtures/blib/lib";
use PAGI::Utils qw(app_path);
use TestApps::AppPath::Root ();
use TestApps::AppPath::BlibRoot ();

sub canonical {
    return File::Spec->canonpath(File::Spec->rel2abs($_[0]));
}

{
    package Local::ScriptStylePath;
    sub home  { return PAGI::Utils::app_path() }
    sub child { shift; return PAGI::Utils::app_path(@_) }
}
```

Add subtests that exercise the public function rather than reimplementing its
detection logic:

```perl
subtest 'PAGI_HOME has first precedence and may be relative' => sub {
    my $absolute = tempdir(CLEANUP => 1);
    {
        local $ENV{PAGI_HOME} = $absolute;
        is(app_path(), canonical($absolute), 'absolute override is canonical');
        is(app_path('static', 'app.css'),
            File::Spec->canonpath(File::Spec->catfile(
                canonical($absolute), 'static', 'app.css')),
            'override uses platform-aware component joining');
    }

    {
        local $ENV{PAGI_HOME} = File::Spec->catdir('relative', 'application');
        is(app_path(), canonical(File::Spec->catdir('relative', 'application')),
            'relative override is anchored at the current working directory');
    }
};

subtest 'module and script conventions select the intended home' => sub {
    local $ENV{PAGI_HOME};
    delete $ENV{PAGI_HOME};

    is(TestApps::AppPath::Root->home, canonical($Bin),
        't/lib package strips its complete package suffix and lib');
    is(TestApps::AppPath::BlibRoot->home,
        canonical(File::Spec->catdir($Bin, 'app-path-fixtures')),
        'blib/lib package strips lib and then blib');
    is(Local::ScriptStylePath->home, canonical($Bin),
        'nonmatching script package falls back to the source directory');

    local $ENV{PAGI_HOME} = '';
    is(Local::ScriptStylePath->home, canonical($Bin),
        'empty PAGI_HOME is treated as unset');
};

subtest 'no arguments and child components return plain absolute strings' => sub {
    local $ENV{PAGI_HOME};
    delete $ENV{PAGI_HOME};

    my $home = Local::ScriptStylePath->home;
    ok(!ref($home), 'home is an ordinary string');
    ok(File::Spec->file_name_is_absolute($home), 'home is absolute');
    is(Local::ScriptStylePath->child('static', 'images', 'logo.svg'),
        File::Spec->canonpath(File::Spec->catfile(
            canonical($Bin), 'static', 'images', 'logo.svg')),
        'logical components use the native File::Spec representation');
    is(Local::ScriptStylePath->child('static', '..', 'templates'),
        File::Spec->canonpath(File::Spec->catfile(
            canonical($Bin), 'static', '..', 'templates')),
        '.. is accepted and follows native canonpath behavior');
};

subtest 'invalid child components croak at the public boundary' => sub {
    local $ENV{PAGI_HOME} = tempdir(CLEANUP => 1);
    my $absolute = File::Spec->catfile(File::Spec->rootdir, 'outside');

    for my $case (
        [undef, 'undefined'],
        ['', 'empty'],
        [{}, 'reference-valued'],
        [$absolute, 'absolute'],
    ) {
        my ($value, $label) = @$case;
        like(dies { app_path($value) }, qr/app_path.*component 1.*relative/i,
            "$label component is rejected clearly");
    }

    my $volume_candidate = File::Spec->catpath('X:', '', 'child');
    my ($volume) = File::Spec->splitpath($volume_candidate);
    if (length $volume) {
        like(dies { app_path($volume_candidate) },
            qr/app_path.*component 1.*volume/i,
            'a separately volumed component is rejected');
    } else {
        pass('native path grammar has no separate volume for the test candidate');
    }
};

subtest 'nonexistent paths are returned without side effects' => sub {
    my $home = tempdir(CLEANUP => 1);
    local $ENV{PAGI_HOME} = $home;
    my $missing = app_path('not-created', 'child');
    ok(!-e $missing, 'helper neither requires nor creates the child path');
};

subtest 'an unusable origin requires the explicit override' => sub {
    local $ENV{PAGI_HOME};
    delete $ENV{PAGI_HOME};
    like(dies {
        PAGI::Utils::_app_path_from_origin('Local::NoSource', undef)
    }, qr/app_path.*determine.*set PAGI_HOME/i,
        'missing source information gives explicit override guidance');

    local $ENV{PAGI_HOME} = tempdir(CLEANUP => 1);
    ok(File::Spec->file_name_is_absolute(
        PAGI::Utils::_app_path_from_origin('Local::NoSource', undef)
    ), 'PAGI_HOME takes precedence even when origin information is unusable');
};

subtest 'export surface is explicit and bundled' => sub {
    {
        package Local::DefaultPathImport;
        PAGI::Utils->import();
    }
    {
        package Local::AllPathImport;
        PAGI::Utils->import(':all');
    }
    ok(!Local::DefaultPathImport->can('app_path'), 'app_path is not default-exported');
    ok(Local::AllPathImport->can('app_path'), 'app_path is in the all bundle');
};

done_testing;
```

- [ ] **Step 3: Run the new test and verify RED**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/utils-app-path.t'
```

Expected: compilation fails because `app_path` is not exported by
`PAGI::Utils`. Record the actual diagnostic in the ledger.

- [ ] **Step 4: Add the shared detector and builder**

In `lib/PAGI/Utils.pm`, import the core path modules and add `app_path` to
`@EXPORT_OK`:

```perl
use File::Basename qw(basename dirname);
use File::Spec;

our @EXPORT_OK = qw(handle_lifespan to_app is_response app_path);
```

Add the public wrapper and one internal origin-aware engine. Keep the code in
classic Perl syntax:

```perl
sub app_path {
    my ($package, $source) = caller;
    return _app_path_from_origin($package, $source, @_);
}

sub _same_path_component {
    my ($left, $right) = @_;
    return 0 unless defined $left && defined $right;
    return lc($left) eq lc($right) if File::Spec->case_tolerant;
    return $left eq $right;
}

sub _home_from_origin {
    my ($package, $source) = @_;

    croak "app_path cannot determine an application home; set PAGI_HOME"
        unless defined $source && !ref($source) && length $source;

    my $absolute = File::Spec->canonpath(File::Spec->rel2abs($source));
    my (undef, $directories, $filename) = File::Spec->splitpath($absolute);
    my @source_dirs = File::Spec->splitdir($directories);
    pop @source_dirs while @source_dirs && $source_dirs[-1] eq '';

    my @package_parts = defined($package) && !ref($package)
        ? split(/::/, $package)
        : ();
    my $module_file = @package_parts ? pop(@package_parts) . '.pm' : '';
    my $matches = length($module_file)
        && _same_path_component($filename, $module_file)
        && @source_dirs >= @package_parts;

    if ($matches) {
        for my $offset (1 .. scalar @package_parts) {
            unless (_same_path_component(
                $source_dirs[-$offset], $package_parts[-$offset]
            )) {
                $matches = 0;
                last;
            }
        }
    }

    my $home = dirname($absolute);
    if ($matches) {
        $home = dirname($home) for @package_parts;
        $home = dirname($home)
            if _same_path_component(basename($home), 'lib');
        $home = dirname($home)
            if _same_path_component(basename($home), 'blib');
    }

    return $home;
}

sub _app_path_from_origin {
    my ($package, $source, @components) = @_;

    for my $index (0 .. $#components) {
        my $component = $components[$index];
        my $position = $index + 1;
        croak "app_path component $position must be a defined, nonempty, "
            . "non-reference relative path component"
            unless defined $component && !ref($component) && length $component;
        croak "app_path component $position must be relative, not absolute"
            if File::Spec->file_name_is_absolute($component);
        my ($volume) = File::Spec->splitpath($component);
        croak "app_path component $position must not specify a volume"
            if defined $volume && length $volume;
    }

    my $home = defined($ENV{PAGI_HOME}) && length($ENV{PAGI_HOME})
        ? $ENV{PAGI_HOME}
        : _home_from_origin($package, $source);
    $home = File::Spec->canonpath(File::Spec->rel2abs($home));

    return $home unless @components;
    return File::Spec->canonpath(File::Spec->catfile($home, @components));
}
```

If the native `File::Spec` behavior uncovered by the focused tests requires a
small correction, preserve the public requirements rather than copying this
illustrative implementation blindly. A contract change is a deviation; a
portable implementation correction is not.

- [ ] **Step 5: Document the functional API beside its implementation**

Extend the `PAGI::Utils` synopsis with:

```perl
use PAGI::Utils qw(app_path);

my $home       = app_path();
my $static     = app_path('static');
my $stylesheet = app_path('static', 'css', 'app.css');
```

Add an `=head2 app_path` section documenting:

- `PAGI_HOME`, conventional `lib/Package.pm`, `blib/lib/Package.pm`, and
  script-fallback precedence;
- one logical component per argument for portable paths;
- absolute string output and empty-override behavior;
- direct-caller sensitivity and wrapper guidance;
- validation of undefined, empty, reference, absolute, and volume-bearing
  components;
- no existence check, creation, symlink resolution, or sandbox guarantee; and
- why root-level `use lib` remains a separate bootstrap concern.

- [ ] **Step 6: Run focused GREEN and utility regressions**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/utils-app-path.t t/utils-to-app.t t/utils-lifespan.t t/utils/is-response.t'
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -c lib/PAGI/Utils.pm && podchecker lib/PAGI/Utils.pm'
git diff --check
```

Expected: all four test files pass; `PAGI::Utils.pm syntax OK`; POD syntax OK;
and no whitespace errors. Record actual test/assertion counts.

- [ ] **Step 7: Review and commit Task 1**

Review that no public class argument or path object was introduced, the helper
performs no filesystem observation, and the two fixtures exercise real caller
filenames. Stage only:

```bash
git add lib/PAGI/Utils.pm t/utils-app-path.t \
  t/lib/TestApps/AppPath/Root.pm \
  t/app-path-fixtures/blib/lib/TestApps/AppPath/BlibRoot.pm
git commit -m "feat: add application path helper"
```

Record the commit SHA, focused evidence, and review result in Task 1's ledger
row before continuing.

---

### Task 2: Add the Endpoint Router Frontend

**Files:**

- Create: `t/lib/TestApps/AppPath/Endpoint.pm`
- Modify: `lib/PAGI/Endpoint/Router.pm:40-74`
- Modify: `lib/PAGI/Endpoint/Router.pm:85-126`
- Modify: `lib/PAGI/Endpoint/Router.pm:259-298`
- Modify: `t/endpoint-router.t:4-11`
- Modify: `t/endpoint-router.t:145-161`
- Modify: `t/endpoint-router.t:224-317`

**Interfaces:**

- Consumes: `PAGI::Utils::_app_path_from_origin($package, $source, @components)` from Task 1, object/class invocants, `%INC`, and the base method's immediate caller source.
- Produces: inherited `$endpoint->app_path(@components) -> Str` and `MyApp::Endpoint->app_path(@components) -> Str` with the same output and validation contract as the function.
- Guarantees: loaded subclasses resolve from their concrete module source; inline subclasses fall back to the method caller source; `PAGI_HOME` remains first precedence.

- [ ] **Step 1: Add a loaded Endpoint fixture**

Create `t/lib/TestApps/AppPath/Endpoint.pm`:

```perl
package TestApps::AppPath::Endpoint;

use strict;
use warnings;
use parent 'PAGI::Endpoint::Router';

1;
```

- [ ] **Step 2: Write failing Endpoint helper tests**

In `t/endpoint-router.t`, import `File::Spec` and `FindBin`, add the fixture
library, and load the concrete fixture:

```perl
use File::Spec;
use FindBin qw($Bin);
use lib "$Bin/lib";
use TestApps::AppPath::Endpoint ();
```

Add `app_path` to the existing positive public-surface method list:

```perl
for my $method (qw(
    new routes to_router to_app middleware_as app_as new_context app_path
)) {
    ok(PAGI::Endpoint::Router->can($method), "has $method");
}
```

Define an inline subclass that calls the inherited helper from its own source:

```perl
{
    package Local::InlinePathEndpoint;
    use parent 'PAGI::Endpoint::Router';

    sub resource_path {
        my ($self, @components) = @_;
        return $self->app_path(@components);
    }
}
```

Add a focused subtest:

```perl
subtest 'app_path delegates with the concrete Endpoint origin' => sub {
    local $ENV{PAGI_HOME};
    delete $ENV{PAGI_HOME};

    my $expected_home = File::Spec->canonpath(File::Spec->rel2abs($Bin));
    my $expected_static = File::Spec->canonpath(
        File::Spec->catfile($expected_home, 'static')
    );

    is(TestApps::AppPath::Endpoint->app_path(), $expected_home,
        'class helper resolves from the concrete t/lib module');
    is(TestApps::AppPath::Endpoint->new->app_path('static'), $expected_static,
        'object helper returns a platform-aware child path');
    unlike(TestApps::AppPath::Endpoint->app_path(),
        qr{PAGI.Tools\z},
        'inherited implementation does not resolve from the base distribution');

    my $inline = Local::InlinePathEndpoint->new;
    is($inline->resource_path('static'), $expected_static,
        'inline subclass falls back to the source of its method call');

    my $override = File::Spec->catdir($Bin, 'configured-home');
    local $ENV{PAGI_HOME} = $override;
    is($inline->resource_path('static'),
        File::Spec->canonpath(File::Spec->catfile(
            File::Spec->rel2abs($override), 'static')),
        'Endpoint helper honors the shared PAGI_HOME precedence');
    like(dies { $inline->resource_path(undef) },
        qr/app_path.*component 1.*relative/i,
        'Endpoint helper uses shared component validation');
};
```

- [ ] **Step 3: Run the Endpoint test and verify RED**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/endpoint-router.t'
```

Expected: the public-surface and focused tests fail because
`PAGI::Endpoint::Router` has no `app_path` method. Record the actual diagnostic.

- [ ] **Step 4: Implement concrete-class source selection and delegation**

Add this ordinary helper near `middleware_as`, `app_as`, and `new_context` in
`lib/PAGI/Endpoint/Router.pm`:

```perl
sub app_path {
    my ($invocant, @components) = @_;
    my $class = blessed($invocant) || $invocant;

    (my $module_file = $class) =~ s{::}{/}g;
    $module_file .= '.pm';

    my (undef, $caller_source) = caller;
    my $source = $INC{$module_file};
    $source = $caller_source unless defined $source && length $source;

    require PAGI::Utils;
    return PAGI::Utils::_app_path_from_origin(
        $class, $source, @components,
    );
}
```

The `/` in `$module_file` is Perl's notional module key used by `%INC`; it is
not filesystem path concatenation. Do not route the Endpoint method through
the exported caller-sensitive wrapper.

- [ ] **Step 5: Document the Endpoint helper**

Add `$self->app_path('static')` to the Endpoint synopsis. Add an
`=head2 app_path` section beside the other explicit helpers covering:

```perl
my $home   = $endpoint->app_path();
my $static = $endpoint->app_path('static');
```

Document concrete object/class origin selection, `%INC`, inline-class fallback,
`PAGI_HOME`, shared function validation/output, and the fact that an override
affects only explicit helper calls—not route compilation or dispatch.

- [ ] **Step 6: Run focused GREEN and helper regressions**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/utils-app-path.t t/endpoint-router.t'
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -c lib/PAGI/Endpoint/Router.pm && podchecker lib/PAGI/Endpoint/Router.pm'
git diff --check
```

Expected: both test files pass; Endpoint syntax and POD are valid; no whitespace
errors. Record actual counts.

- [ ] **Step 7: Review and commit Task 2**

Verify class and object calls share the internal Task 1 implementation, the
base module path cannot leak into results, and no routing lifecycle calls the
helper. Stage only:

```bash
git add lib/PAGI/Endpoint/Router.pm t/endpoint-router.t \
  t/lib/TestApps/AppPath/Endpoint.pm
git commit -m "feat: add Endpoint application path helper"
```

Record Task 2's SHA, evidence, and review result in the ledger.

---

### Task 3: Migrate the Canonical Large Application

**Files:**

- Modify: `t/integration-large-application.t:55-94`
- Verify existing behavior: `t/integration-large-application.t:458-469`
- Modify: `examples/15-large-application/lib/MyApp/Root.pm:5-16`
- Modify: `examples/15-large-application/lib/MyApp/Root.pm:51-60`
- Modify: `examples/15-large-application/README.md:41-54`

**Interfaces:**

- Consumes: exported `PAGI::Utils::app_path(@components)` from Task 1.
- Produces: `MyApp::Root` static mount rooted by `app_path('static')`, with the same `/static/app.css` response and opaque-mount behavior as before.
- Guarantees: the example retains its minimal `app.pl` bootstrap because `app_path` cannot load `lib` before the application modules are available.

- [ ] **Step 1: Pin the intended source shape before changing the example**

In the existing source-style subtest in `t/integration-large-application.t`,
after reading `$root_app`, add:

```perl
like($root_app, qr/use PAGI::Utils qw\(app_path\)/,
    'Root imports the application path helper');
like($root_app, qr/root\s*=>\s*app_path\('static'\)/,
    'static mount uses one platform-aware application-relative expression');
unlike($root_app, qr/File::Basename|File::Spec|__FILE__|\$STATIC_ROOT/,
    'Root contains no manual source-file path arithmetic');
```

Do not duplicate the runtime CSS assertions already at lines 458-469.
At file scope, localize and delete `$ENV{PAGI_HOME}` so a developer's shell
override cannot redirect this convention-layout integration test:

```perl
local $ENV{PAGI_HOME};
delete $ENV{PAGI_HOME};
```

- [ ] **Step 2: Run the integration test and verify RED**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-large-application.t'
```

Expected: the three new source-shape assertions fail while the existing static
request still passes through the old `$STATIC_ROOT`. Record the failure.

- [ ] **Step 3: Replace Root's manual path arithmetic**

In `examples/15-large-application/lib/MyApp/Root.pm`, remove:

```perl
use File::Basename qw(dirname);
use File::Spec;

my $STATIC_ROOT = File::Spec->catdir(
    dirname(__FILE__), '..', '..', 'static',
);
```

Import the helper:

```perl
use PAGI::Utils qw(app_path);
```

Change the static mount to:

```perl
mount('/static' => PAGI::App::File->new(
    root => app_path('static'),
)),
```

Do not alter the route order, opaque mount form, lifespan callbacks, named
Router mounts, handlers, constraints, or signatures.

- [ ] **Step 4: Explain convention detection in the example README**

Extend the Root/static bullets with this concrete explanation:

```markdown
- Root passes `app_path('static')` to `PAGI::App::File`. Because
  `MyApp::Root` is loaded from `lib/MyApp/Root.pm`, the helper removes the
  package suffix and trailing `lib`, then appends `static` with `File::Spec`.
  A nonstandard deployment can set `PAGI_HOME` explicitly.
```

Also state near the run instructions that `app.pl` still locates `lib` because
bootstrap happens before `PAGI::Utils` or `MyApp::Root` can be loaded. Do not
edit the preserved Python/Starlette comparison.

- [ ] **Step 5: Run focused GREEN and example syntax checks**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/utils-app-path.t t/integration-large-application.t'
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -Iexamples/15-large-application/lib -c examples/15-large-application/lib/MyApp/Root.pm'
git diff --check
```

Expected: both tests pass; `MyApp/Root.pm syntax OK`; `/static/app.css` retains
status 200, `text/css`, and the recognizable `.page` rule; missing static files
remain owned by the opaque file app. Record actual counts.

- [ ] **Step 6: Review and commit Task 3**

Confirm only the approved example was migrated and `app.pl` still performs its
bootstrap. Stage only:

```bash
git add examples/15-large-application/lib/MyApp/Root.pm \
  examples/15-large-application/README.md \
  t/integration-large-application.t
git commit -m "examples: use application path helper"
```

Record Task 3's SHA, evidence, and review result in the ledger.

---

### Task 4: Document Immediate and Future-Backed Callables

**Files:**

- Create: `t/documentation-callable-completion.t`
- Modify: `lib/PAGI/Routing.pm:136-181`
- Modify: `lib/PAGI/Routing.pm:301-308`
- Modify: `lib/PAGI/Routing.pm:543-567`
- Modify: `lib/PAGI/App/Router.pm:69-121`
- Modify: `lib/PAGI/App/Router.pm:160-189`
- Modify: `lib/PAGI/Endpoint/Router.pm:193-279`
- Modify: `lib/PAGI/Tools/Tutorial.pod:18-104`
- Modify: `lib/PAGI/Tools/Tutorial.pod:628-675`
- Modify: `lib/PAGI/Tools/Cookbook.pod:32-63`
- Modify: `lib/PAGI/Tools/Cookbook.pod:353-397`
- Modify: `lib/PAGI/Tools/Cookbook.pod:731-797`
- Modify: `lib/PAGI/Tools/Cookbook.pod:939-988`

**Interfaces:**

- Consumes: the shipped `Future->wrap` adaptation behavior in `PAGI::Routing::Compiler`, the three routing frontends, native PAGI `($scope, $receive, $send)` applications, and synchronous middleware factories.
- Produces: one consistent public explanation of when ordinary `sub`, direct Future return, and `async sub`/`await` are appropriate.
- Guarantees: examples distinguish completion shape from ownership—Context HTTP handlers return Responses, WebSocket/SSE Context handlers own protocol operations through `$c`, native apps own wire events, and middleware factories synchronously return request-time apps.

- [ ] **Step 1: Add a failing documentation-contract test**

Create `t/documentation-callable-completion.t` using only Perl 5.18-compatible
syntax and core file I/O:

```perl
use strict;
use warnings;
use Test2::V0;

sub source_text {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot open $path: $!\n";
    local $/;
    my $source = <$fh>;
    close $fh or die "cannot close $path: $!\n";
    return $source;
}

my $routing  = source_text('lib/PAGI/Routing.pm');
my $app      = source_text('lib/PAGI/App/Router.pm');
my $endpoint = source_text('lib/PAGI/Endpoint/Router.pm');
my $tutorial = source_text('lib/PAGI/Tools/Tutorial.pod');
my $cookbook = source_text('lib/PAGI/Tools/Cookbook.pod');

like($routing, qr/=head1 CALLABLE COMPLETION/,
    'Routing owns the canonical completion contract');
like($routing, qr/ordinary C<sub>.*C<async sub>.*C<await>/s,
    'Routing explains when ordinary and async subs are appropriate');
like($routing, qr/HTTP Context handler.*L<PAGI::Response>/s,
    'Routing names the HTTP Context terminal value');
like($routing, qr/native.*C<\(\$scope, \$receive, \$send\)>.*inert/s,
    'Routing separates native event ownership from resolved values');
like($routing, qr/factor(?:y|ies).*synchronously.*request-time.*Future/s,
    'Routing separates middleware compilation and request completion');
like($routing, qr/Never call.*C<<\s*->get\s*>>.*blocks the event loop/s,
    'Routing explicitly rejects blocking Future waits');

like($app, qr/=head2 Synchronous and asynchronous completion/,
    'App Router documents both handler shapes');
like($endpoint, qr/=head2 Synchronous and asynchronous completion/,
    'Endpoint Router documents both method-handler shapes');
like($endpoint, qr/C<middleware_as>.*synchronously.*request-time.*Future/s,
    'Endpoint middleware helper keeps its two phases distinct');

unlike($tutorial, qr/A PAGI application is an C<async> sub/,
    'Tutorial no longer claims every native app must use async sub');
like($tutorial, qr/sub home.*return \$c->html/s,
    'Tutorial uses an ordinary sub for immediate handler work');
like($tutorial, qr/async sub show_person.*await.*find_person/s,
    'Tutorial uses async sub for asynchronous database work');

like($cookbook, qr/=head3 Choosing ordinary sub or async sub/,
    'Cookbook has an explicit callable-shape recipe');
like($cookbook, qr/sub home.*async sub show/s,
    'Endpoint recipe contrasts immediate and asynchronous methods');
unlike($cookbook, qr/\$future->get\b/,
    'Cookbook does not recommend blocking the request loop');

done_testing;
```

The test intentionally checks public documentation contracts, not compiler
implementation details or line numbers.

- [ ] **Step 2: Run the documentation test and verify RED**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/documentation-callable-completion.t'
```

Expected: assertions for the new canonical heading, frontend subsections,
tutorial examples, and cookbook recipe fail; the test also exposes the
tutorial's current overstatement that every PAGI app is an `async sub`.

- [ ] **Step 3: Add the canonical completion contract to PAGI::Routing**

Add `=head1 CALLABLE COMPLETION` after the constructor/code-position material
and before the constructor reference. State all of the following explicitly:

```text
Request-time PAGI callables may complete immediately or return a Future.
Use an ordinary sub when all work and the terminal value are immediately
available. Use async sub and await when asynchronous database, network,
receive, send, or cleanup operations must be sequenced. Returning an existing
Future directly is valid when no additional sequencing is needed. Never call
->get inside request handling; it blocks the event loop.
```

Include these contrasting HTTP Context handlers:

```perl
sub home {
    my ($c) = @_;
    return $c->html('<h1>Home</h1>');
}

async sub show_person {
    my ($c) = @_;
    my $person = await $database->find_person(
        $c->path_param('person_id'),
    );
    return $c->json($person) if $person;
    return $c->text('Person not found', status => 404);
}
```

Then distinguish the terminal contracts:

- an HTTP Context handler resolves to an `L<PAGI::Response>`, which Routing
  validates and emits once;
- WebSocket and SSE Context handlers perform protocol operations through `$c`,
  and their resolved values are inert;
- a native `($scope, $receive, $send)` app owns protocol events, may return a
  single operation's Future directly, or may use `async sub`/`await` to
  sequence several operations; its resolved value is inert; and
- a middleware factory or `wrap` method runs synchronously at compilation and
  must immediately return a native app coderef, while that request-time app may
  complete immediately or through a Future.

Cross-link the existing HTTP lifecycle and middleware sections to this new
section. Preserve the existing rule that synchronous handlers run in the
server's current execution context rather than a worker pool.

- [ ] **Step 4: Align App Router and Endpoint Router POD**

In `PAGI::App::Router`'s HTTP-routes section, add
`=head2 Synchronous and asynchronous completion` with one ordinary handler and
one asynchronous database handler. Explain that both are adapted by the shared
compiler and must ultimately resolve to a Response. In its raw section, show
that a native app may return one send/respond Future directly but needs
`async sub`/`await` for ordered multiple events.

In `PAGI::Endpoint::Router`'s handler section, add the same subsection using
method signatures:

```perl
sub home {
    my ($self, $c) = @_;
    return $c->html('<h1>Home</h1>');
}

async sub show {
    my ($self, $c) = @_;
    my $person = await $self->{repository}->find(
        $c->path_param('id'),
    );
    return $c->json($person);
}
```

Clarify under `app_as` that its three-channel method follows the native
request-time completion rule. Clarify under `middleware_as` that the adapted
method is the synchronous factory; the native app it returns may itself be an
ordinary or async coderef. Do not imply that `middleware_as` accepts an async
factory returning a Future of an app.

- [ ] **Step 5: Teach the rule from first principles in Tutorial and Cookbook**

In Tutorial Part 1, replace “A PAGI application is an `async sub`” with “A
PAGI application is a callable receiving `($scope, $receive, $send)`.” Explain
that the two-event hello-world example is async because it sequences two sends,
not because native apps are required to use `async sub`. Add a one-operation
example that returns the Future directly:

```perl
sub text_app {
    my ($scope, $receive, $send) = @_;
    return PAGI::Response->text('Hello, world!')->respond($send);
}
```

In Tutorial Part 2, make `home` an ordinary sub and add `async sub show_person`
with an awaited asynchronous repository/database call. Explain that the router
uses the same declarations for both and that each must resolve to a Response.
In Tutorial Part 6, state that the middleware factory is synchronous while the
returned wrapper app follows the immediate-or-Future request-time rule.

In the Cookbook:

- change the package-handler recipe's immediate `home` to an ordinary sub;
- add `=head3 Choosing ordinary sub or async sub` beneath “Normal, Raw,
  WebSocket, and SSE Handler Lifecycles,” with the same immediate-versus-async
  decision and direct-Future-return option;
- keep the raw two-send example async and explain why;
- change the Endpoint `home` method to an ordinary sub while keeping the
  repository-backed `show` method async; and
- clarify the synchronous `middleware_as` factory versus its request-time
  wrapper.

Do not rewrite unrelated asynchronous examples that genuinely await protocol,
lifespan, database, streaming, or middleware operations.

- [ ] **Step 6: Run documentation GREEN and focused regression gates**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/documentation-callable-completion.t t/endpoint-router.t t/integration-large-application.t'
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && podchecker lib/PAGI/Routing.pm && podchecker lib/PAGI/App/Router.pm && podchecker lib/PAGI/Endpoint/Router.pm && podchecker lib/PAGI/Tools/Tutorial.pod && podchecker lib/PAGI/Tools/Cookbook.pod'
git diff --check
```

Expected: the documentation contract and both routing/example regressions pass;
all five POD files report syntax OK; no whitespace errors. Record exact counts.

- [ ] **Step 7: Review and commit Task 4**

Review every use of `async sub` changed by this task: it may become an ordinary
sub only when the body performs no `await` and returns its terminal value or
Future directly. Confirm the docs never conflate a middleware factory with the
request-time app it returns. Stage only:

```bash
git add lib/PAGI/Routing.pm lib/PAGI/App/Router.pm \
  lib/PAGI/Endpoint/Router.pm lib/PAGI/Tools/Tutorial.pod \
  lib/PAGI/Tools/Cookbook.pod t/documentation-callable-completion.t
git commit -m "docs: explain callable completion styles"
```

Record Task 4's SHA, test/POD evidence, and review result in the ledger.

---

### Task 5: Final Contract and Repository Verification

**Files:**

- Inspect: `docs/superpowers/specs/2026-08-11-application-path-design.md`
- Inspect: `.superpowers/sdd/2026-08-11-application-path/progress.md`
- Inspect: all files changed by Tasks 1-4
- Modify only if verification finds a contract-preserving defect: the owning Task 1-4 files

**Interfaces:**

- Consumes: the four reviewed implementation/documentation commits and their ledger evidence.
- Produces: one verified feature range with complete spec coverage, one repository-wide suite result, clean POD/syntax/diff checks, and no unresolved deviation.

- [ ] **Step 1: Audit the diff and spec coverage before the expensive gate**

Run:

```bash
git status --short
git diff --stat main...HEAD
git diff --check main...HEAD
rg -n "app_path|PAGI_HOME|File::Basename|File::Spec|STATIC_ROOT" \
  lib/PAGI/Utils.pm lib/PAGI/Endpoint/Router.pm \
  examples/15-large-application/lib/MyApp/Root.pm \
  examples/15-large-application/README.md \
  t/utils-app-path.t t/endpoint-router.t t/integration-large-application.t
```

Compare every design-spec requirement with a named test or POD paragraph.
Verify only the three known untracked report files remain outside the feature.
Do not run the full suite until this audit is clean.

- [ ] **Step 2: Run syntax, POD, and focused integration gates**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -c lib/PAGI/Utils.pm && perl -Ilib -c lib/PAGI/Endpoint/Router.pm && podchecker lib/PAGI/Utils.pm && podchecker lib/PAGI/Endpoint/Router.pm'
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/utils-app-path.t t/endpoint-router.t t/integration-large-application.t t/documentation-callable-completion.t'
```

Expected: syntax and POD checks succeed and all four focused tests pass.
Record exact counts and elapsed time.

- [ ] **Step 3: Request a whole-feature review**

Use `superpowers:requesting-code-review` against the recorded starting HEAD
through current HEAD. Require the reviewer to check:

- exact package-suffix removal and `lib`/`blib` order;
- platform-aware joining and component validation;
- absence of filesystem observation and security overclaims;
- Endpoint concrete-class versus base-class origin;
- function/Endpoint documentation agreement;
- large-example bootstrap and static runtime behavior;
- immediate/Future completion guidance across Context handlers, native apps,
  and middleware without recommending blocking waits; and
- scope containment against the approved design.

Fix ordinary in-scope defects in the owning task's files, rerun the affected
focused gate, commit the correction, and record it. Stop for the user if review
finds a contract conflict.

- [ ] **Step 4: Run the repository-wide suite exactly once at final HEAD**

Only after the diff audit, focused gates, and review are clean, run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t'
```

Expected: all repository test files pass. Record exact file/assertion counts,
exit status, elapsed time, and final HEAD. Do not repeat the suite merely to
obtain a second identical result. If it finds a real defect, fix and commit the
defect, then run one replacement final suite at the corrected HEAD and record
why the earlier gate was superseded.

- [ ] **Step 5: Close the ledger and report completion**

Set all five task rows to `complete`; fill every SHA, focused evidence,
full-suite evidence, and review cell; and ensure every deviation is either
absent or has the user's recorded decision. Report:

- the starting and final commit SHAs;
- the four feature/documentation commits plus any correction commit;
- focused and full-suite results with actual counts;
- the review result;
- approved deviations, or `none`;
- confirmation that the unrelated untracked reports were untouched; and
- the exact example expression now used: `root => app_path('static')`.
