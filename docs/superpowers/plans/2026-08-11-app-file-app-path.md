# App::File Application-Path Constructor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the narrow `PAGI::App::File->app_path(@path_parts)` component constructor, safe development-mode file-attempt output, and concise static-file setup in the two canonical examples.

**Architecture:** `PAGI::Utils` factors its existing load-time source capture into one private registrar. Both `PAGI::Utils::import` and a new no-export `PAGI::App::File::import` register each use site's package/source pair, while the File constructor delegates path resolution to the existing private origin-aware engine and then calls `$class->new(root => $path)`. Request-time diagnostics are a separate App::File concern: after request validation and index selection, exact `PAGI_ENV=development` prints one control-safe lexical candidate to `STDOUT` without changing response behavior.

**Tech Stack:** Perl 5.18-compatible library code, `Future::AsyncAwait`, core `Carp`, `Cwd`, and `File::Spec`, `Test2::V0`, `PAGI::Test::Client`, POD, and `prove`.

**Design:** `docs/superpowers/specs/2026-08-11-app-file-app-path-design.md`

## Global Constraints

- `PAGI::App::File->app_path(@path_parts)` is a class-only alternate constructor returning an object of the invoked class; it never returns a path string or compiled app.
- Every argument after the class is a path component. Do not add options, a trailing hash grammar, coercions, or setters.
- Calling the constructor with no path parts is valid and selects application home.
- Reuse `PAGI::Utils::_app_path_from_origin`; do not create another home detector, validator, or path joiner.
- Origin registration remains private, keyed by both caller package and reported caller source. It is not an export or supported application API.
- Every ordinary `use PAGI::App::File` registers its own caller origin and exports nothing. Preserve the current behavior of ignoring import arguments.
- `PAGI_HOME`, exact package-suffix matching, `lib` then `blib` removal, script fallback, component validation, relative-source stability, and no-filesystem-side-effect semantics remain those of `PAGI::Utils`.
- Object and unblessed-reference invocants croak clearly as invalid class-constructor calls. Subclass class names construct the subclass.
- Development output is enabled only when `($ENV{PAGI_ENV} // '') eq 'development'` at request time.
- Emit exactly one `STDOUT` line after request validation and index selection but before the existing `-f`/`-r` check. Unsupported methods and rejected paths stay silent.
- Log the lexical candidate, never the later resolved symlink target. Escape ASCII controls as visible `\xNN` text so one request cannot inject another physical line.
- Development output must not change status, headers, body, or the file path sent to the server. It is not access logging.
- Update both agreed example applications: `examples/15-large-application` and `examples/app-01-file`. Do not sweep other examples.
- Do not change PAGI-Server, `PAGI::Endpoint::Router->app_path`, App::File range/MIME/security algorithms, or dependency metadata.
- Library and focused test code must use Perl 5.18-compatible syntax. The existing large example remains Perl 5.40+.
- Add no dependency.
- Run focused tests during tasks. Reserve one repository-wide `prove -lr t` for the final gate; repeat it only if an invalid environment prevented a real run or a subsequent fix changed the tree.
- Preserve unrelated working-tree files. Stage only the paths listed by the current task.

## File Map

- Modify `lib/PAGI/Utils.pm`: private origin registrar and unchanged public import behavior.
- Modify `lib/PAGI/App/File.pm`: no-export import hook, alternate constructor, development diagnostic, and POD.
- Create `t/app-file.t`: local constructor, caller-origin, serving, and diagnostic contract tests.
- Create `t/app-file-fixtures/one/lib/TestApps/AppFile/One.pm`: first conventional caller fixture.
- Create `t/app-file-fixtures/one/static/index.html`: first fixture index.
- Create `t/app-file-fixtures/one/static/marker.txt`: first fixture marker.
- Create `t/app-file-fixtures/one/static/nested/marker.txt`: multiple-component marker.
- Create `t/app-file-fixtures/one/static/empty-dir/.keep`: index-free directory fixture.
- Create `t/app-file-fixtures/two/lib/TestApps/AppFile/Two.pm`: second conventional caller fixture.
- Create `t/app-file-fixtures/two/static/marker.txt`: second fixture marker.
- Create `t/app-file-script-static/marker.txt`: root-level test-script fallback marker.
- Modify `examples/15-large-application/lib/MyApp/Root.pm`: concise module-layout static component.
- Modify `examples/15-large-application/README.md`: explain the alternate constructor.
- Modify `t/integration-large-application.t`: source-shape and existing runtime static assertions.
- Modify `examples/app-01-file/app.pl`: concise root-level script fallback.
- Modify `examples/app-01-file/README.md`: constructor and development-output usage.
- Create `t/integration-app-file-demo.t`: load and exercise the root-level example.
- Modify `Changes`: record the constructor, diagnostics, and example migrations.

## Execution Tracking and Baseline

Before Task 1, create the ignored execution ledger
`.superpowers/sdd/2026-08-11-app-file-app-path/progress.md` with the starting
HEAD, branch/worktree path, and one row per task:

```markdown
| Task | Status | Commit SHA | Focused verification | Full-suite verification | Review |
|---|---|---|---|---|---|
| 1 | pending | — | — | deferred to Task 4 | — |
| 2 | pending | — | — | deferred to Task 4 | — |
| 3 | pending | — | — | deferred to Task 4 | — |
| 4 | pending | — | — | — | — |

## Deviations

| ID | Status | Conflicting spec/plan text | Evidence and rationale | Affected tasks | User decision |
|---|---|---|---|---|---|
```

Update the current row in the same step as each task commit. Record exact test
counts and review evidence, not only `PASS`. A worker must not build on a
specification deviation until it has an ID, rationale, and user decision.

Execute the implementation on a named feature branch in an isolated worktree
created through `superpowers:using-git-worktrees`. The `main...HEAD` audit range
in Task 4 assumes that branch boundary; do not implement these tasks directly
on `main`.

Run the pre-change baseline in the implementation worktree:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/utils-app-path.t t/endpoint-router.t t/integration-large-application.t t/00-load.t'
```

Expected: PASS. Record the exact Files/Tests totals in the ledger. Do not run
the full repository suite here.

---

### Task 1: Shared Caller Origins and the Alternate File Constructor

**Files:**
- Modify: `lib/PAGI/Utils.pm:15-34`
- Modify: `lib/PAGI/App/File.pm:3-8,89-105`
- Modify: `lib/PAGI/App/File.pm:14-24,280-330` (constructor POD)
- Create: `t/app-file.t`
- Create: `t/app-file-fixtures/one/lib/TestApps/AppFile/One.pm`
- Create: `t/app-file-fixtures/one/static/index.html`
- Create: `t/app-file-fixtures/one/static/marker.txt`
- Create: `t/app-file-fixtures/one/static/nested/marker.txt`
- Create: `t/app-file-fixtures/one/static/empty-dir/.keep`
- Create: `t/app-file-fixtures/two/lib/TestApps/AppFile/Two.pm`
- Create: `t/app-file-fixtures/two/static/marker.txt`
- Create: `t/app-file-script-static/marker.txt`
- Test: `t/app-file.t`
- Test: `t/utils-app-path.t`
- Test: `t/endpoint-router.t`

**Interfaces:**
- Consumes: existing `PAGI::Utils::_app_path_from_origin($package, $source, @components) -> Str` and `PAGI::App::File->new(root => $path) -> PAGI::App::File`.
- Produces: private `PAGI::Utils::_remember_app_path_origin($package, $source) -> undef`; no-export `PAGI::App::File->import(@ignored)`; public class constructor `PAGI::App::File->app_path(@components) -> object of invoked class`.

- [ ] **Step 1: Create two independent conventional caller fixtures**

Create `t/app-file-fixtures/one/lib/TestApps/AppFile/One.pm`:

```perl
package TestApps::AppFile::One;

use strict;
use warnings;
use PAGI::App::File;

sub files {
    return PAGI::App::File->app_path('static');
}

1;
```

Create `t/app-file-fixtures/two/lib/TestApps/AppFile/Two.pm` with the same
shape but package `TestApps::AppFile::Two`.

Create `t/app-file-fixtures/one/static/marker.txt` containing:

```text
caller one
```

Create `t/app-file-fixtures/one/static/index.html` containing:

```text
one index
```

Create `t/app-file-fixtures/one/static/nested/marker.txt` containing:

```text
caller one nested
```

Create `t/app-file-fixtures/one/static/empty-dir/.keep` as a zero-byte fixture
so the directory exists but contains no configured index file.

Create `t/app-file-fixtures/two/static/marker.txt` containing:

```text
caller two
```

Create `t/app-file-script-static/marker.txt` containing:

```text
script caller
```

The distinct text is required: a collision must not let both callers confirm
the same root.

- [ ] **Step 2: Write the failing constructor and origin tests**

Create `t/app-file.t` with this foundation and constructor subtests:

```perl
use strict;
use warnings;
use Test2::V0;
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

use lib 'lib';
use lib "$Bin/app-file-fixtures/one/lib";
use lib "$Bin/app-file-fixtures/two/lib";
use PAGI::App::File;
use PAGI::Test::Client;
use TestApps::AppFile::One ();
use TestApps::AppFile::Two ();

{
    package Local::AppFileSubclass;
    use parent 'PAGI::App::File';
}

sub fetched_text {
    my ($component, $path) = @_;
    local $ENV{PAGI_ENV} = 'production';
    return PAGI::Test::Client->new(app => $component)->get($path)->text;
}

subtest 'class constructor returns a serving component and preserves subclasses' => sub {
    my $home = File::Spec->catdir($Bin, 'app-file-fixtures', 'one');
    local $ENV{PAGI_HOME} = $home;

    my $files = PAGI::App::File->app_path('static');
    isa_ok($files, 'PAGI::App::File');
    is(fetched_text($files, '/marker.txt'), 'caller one\n',
        'one path component resolves into a serving file root');

    my $nested = PAGI::App::File->app_path('static', 'nested');
    is(fetched_text($nested, '/marker.txt'), "caller one nested\n",
        'multiple path components resolve into a serving file root');

    my $whole_home = PAGI::App::File->app_path();
    is(fetched_text($whole_home, '/static/marker.txt'), 'caller one\n',
        'no path components serve application home');

    my $subclass = Local::AppFileSubclass->app_path('static');
    isa_ok($subclass, 'Local::AppFileSubclass');

    like(dies { PAGI::App::File::app_path($files, 'other') },
        qr/app_path.*class constructor/i,
        'object invocation is rejected before path resolution');
    like(dies { PAGI::App::File::app_path([], 'other') },
        qr/app_path.*class constructor/i,
        'unblessed reference invocation is rejected');
};

subtest 'component validation is the shared Utils contract' => sub {
    local $ENV{PAGI_HOME} = File::Spec->catdir($Bin, 'app-file-fixtures', 'one');
    like(dies { PAGI::App::File->app_path({}) },
        qr/app_path.*component 1.*relative/i,
        'a reference-valued component retains the shared positional diagnostic');
    like(dies { PAGI::App::File->app_path('static', '') },
        qr/app_path.*component 2.*relative/i,
        'a later invalid component reports its shared position');
};

subtest 'ordinary use sites retain independent caller origins' => sub {
    local $ENV{PAGI_HOME};
    delete $ENV{PAGI_HOME};

    is(fetched_text(TestApps::AppFile::One->files, '/marker.txt'), "caller one\n",
        'first caller serves its own application root');
    is(fetched_text(TestApps::AppFile::Two->files, '/marker.txt'), "caller two\n",
        'second caller serves its own application root');
};

subtest 'root-level test script uses script fallback' => sub {
    local $ENV{PAGI_HOME};
    delete $ENV{PAGI_HOME};
    my $files = PAGI::App::File->app_path('app-file-script-static');
    is(fetched_text($files, '/marker.txt'), "script caller\n",
        'main package call resolves beside the test script');
};

subtest 'relative caller source is fixed before a later chdir' => sub {
    my $other = tempdir(CLEANUP => 1);
    local $ENV{PAGI_HOME};
    delete $ENV{PAGI_HOME};
    local $ENV{PAGI_ENV} = 'production';
    open my $child, '-|', $^X,
        '-Ilib', '-It/app-file-fixtures/one/lib',
        '-MTestApps::AppFile::One', '-MPAGI::Test::Client', '-e',
        'chdir shift @ARGV or die $!; '
            . 'my $r = PAGI::Test::Client->new('
            . 'app => TestApps::AppFile::One->files)->get("/marker.txt"); '
            . 'print $r->text',
        $other
        or die "cannot start child perl: $!";
    my $output = do { local $/; <$child> };
    close $child;

    is($?, 0, 'child process completed');
    is($output, "caller one\n",
        'relative module source remains anchored at use time');
};

{
    package Local::IgnoredAppFileImport;
    PAGI::App::File->import('imaginary_export');
}
ok(!Local::IgnoredAppFileImport->can('imaginary_export'),
    'App::File import remains a no-export hook and ignores arguments');

done_testing;
```

Derive expected behavior from distinct fixture text and HTTP responses. Do not
assert directly on `$component->{root}`.

- [ ] **Step 3: Run the new test and verify RED**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/app-file.t'
```

Expected: FAIL because `PAGI::App::File` has no `app_path` method. If it fails
first for fixture syntax, test setup, or missing dependencies, correct the test
until the missing constructor is the observed failure.

- [ ] **Step 4: Factor the private load-time origin registrar**

In `lib/PAGI/Utils.pm`, replace the inline source-cache block in `import` with:

```perl
sub _remember_app_path_origin {
    my ($package, $source) = @_;
    return unless defined $package && !ref($package);
    return unless defined $source && !ref($source) && length($source);

    $APP_PATH_SOURCE{join("\0", $package, $source)} =
        File::Spec->canonpath(File::Spec->rel2abs($source));
    return;
}

sub import {
    my $class = shift;
    my ($package, $source) = caller;
    _remember_app_path_origin($package, $source);

    local $Exporter::ExportLevel = 1;
    return Exporter::import($class, @_);
}
```

Do not export or publicly document `_remember_app_path_origin`. Do not change
the cache key or `_app_path_from_origin` lookup.

- [ ] **Step 5: Implement the no-export import hook and class constructor**

Add `Carp` to `lib/PAGI/App/File.pm`:

```perl
use Carp qw(croak);
```

Before `new`, add:

```perl
sub import {
    my $class = shift;
    my ($package, $source) = caller;

    require PAGI::Utils;
    PAGI::Utils::_remember_app_path_origin($package, $source);
    return;
}

sub app_path {
    my ($class, @components) = @_;
    croak 'PAGI::App::File->app_path is a class constructor '
        . 'and requires a class invocant'
        if ref($class);

    my ($package, $source) = caller;
    require PAGI::Utils;
    my $root = PAGI::Utils::_app_path_from_origin(
        $package, $source, @components,
    );

    return $class->new(root => $root);
}
```

The ignored import argument list is intentional. Do not forward it to Exporter
or install caller symbols.

- [ ] **Step 6: Run the focused constructor gate**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/app-file.t t/utils-app-path.t t/endpoint-router.t'
```

Expected: PASS. Confirm the child-process `chdir` case and both distinct marker
responses pass. Output must contain no unexpected warnings.

- [ ] **Step 7: Document the constructor in App::File POD**

Extend the synopsis with both component and compiled-app forms:

```perl
    my $files = PAGI::App::File->app_path('static');
    my $app   = PAGI::App::File->app_path('static')->to_app;
```

Add an `app_path` section documenting:

```text
- returns a PAGI::App::File component object;
- class-only and subclass-preserving;
- no arguments select application home;
- all arguments are path components;
- advanced options require new(root => ...);
- PAGI_HOME and path semantics are shared with PAGI::Utils::app_path;
- each ordinary use PAGI::App::File records that file's caller origin;
- use PAGI::App::File () and require lack the relative-source-after-chdir
  guarantee, with PAGI_HOME as the escape hatch;
- the registrar and origin resolver are unsupported internals.
```

Do not describe the class constructor as returning the path string.

- [ ] **Step 8: Verify syntax, POD, focused regressions, and diff hygiene**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -c lib/PAGI/Utils.pm && perl -Ilib -c lib/PAGI/App/File.pm && podchecker lib/PAGI/Utils.pm && podchecker lib/PAGI/App/File.pm'
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/app-file.t t/utils-app-path.t t/endpoint-router.t t/00-load.t'
git diff --check
```

Expected: syntax and POD OK; focused tests PASS; diff check has no output. If
the direct `perl -c lib/PAGI/Utils.pm` command emits the repository's known
Utils/Lifespan circular compile warning, record it exactly and separately from
normal module-load output; do not misreport it as introduced behavior without
comparing the starting HEAD.

- [ ] **Step 9: Update the ledger and commit Task 1**

Record RED, GREEN, exact Files/Tests totals, syntax/POD evidence, and review
result in Task 1's row. Then stage only:

```bash
git add lib/PAGI/Utils.pm lib/PAGI/App/File.pm t/app-file.t \
  t/app-file-fixtures/one/lib/TestApps/AppFile/One.pm \
  t/app-file-fixtures/one/static/index.html \
  t/app-file-fixtures/one/static/marker.txt \
  t/app-file-fixtures/one/static/nested/marker.txt \
  t/app-file-fixtures/one/static/empty-dir/.keep \
  t/app-file-fixtures/two/lib/TestApps/AppFile/Two.pm \
  t/app-file-fixtures/two/static/marker.txt \
  t/app-file-script-static/marker.txt
git commit -m "feat: add App File application path constructor"
```

---

### Task 2: Safe Development File-Attempt Output

**Files:**
- Modify: `lib/PAGI/App/File.pm:105-172`
- Modify: `lib/PAGI/App/File.pm` (development diagnostic POD)
- Modify: `t/app-file.t`
- Test: `t/app-file.t`

**Interfaces:**
- Consumes: Task 1's `PAGI::App::File->app_path(@components)` and existing `to_app` request path.
- Produces: private `_development_file_attempt($file_path) -> undef`; exact `STDOUT` record `PAGI::App::File: attempting /absolute/candidate/path\n` for request-time development mode.

- [ ] **Step 1: Add independent output-capture and raw-event helpers**

Add these imports with the existing imports in `t/app-file.t`:

```perl
use Future;
use Cwd ();
```

Before `done_testing`, add:

```perl
sub capture_output {
    my ($code) = @_;
    my ($stdout, $stderr) = ('', '');
    my $value;
    {
        local *STDOUT;
        local *STDERR;
        open STDOUT, '>', \$stdout or die "cannot capture STDOUT: $!";
        open STDERR, '>', \$stderr or die "cannot capture STDERR: $!";
        $value = $code->();
    }
    return ($value, $stdout, $stderr);
}

sub run_native {
    my ($component, $method, $path) = @_;
    my @events;
    $component->to_app->(
        {
            type => 'http', method => $method, path => $path,
            raw_path => $path, root_path => '', headers => [],
            path_params => {},
        },
        sub { return Future->done({ type => 'http.disconnect' }) },
        sub { push @events, $_[0]; return Future->done },
    )->get;
    return \@events;
}
```

This captures real process streams and real App::File events. Do not mock the
diagnostic function.

- [ ] **Step 2: Write failing development diagnostic tests**

Add subtests using the existing first fixture. Compute ordinary expected paths
without calling the application-path helper under test:

```perl
my $one_static = Cwd::realpath(File::Spec->catdir(
    $Bin, 'app-file-fixtures', 'one', 'static',
));
my $file_component = TestApps::AppFile::One->files;
my $client = PAGI::Test::Client->new(app => $file_component);

subtest 'development logs final existing, missing, index, and HEAD candidates' => sub {
    local $ENV{PAGI_ENV} = 'development';

    my ($existing, $existing_out, $existing_err) = capture_output(sub {
        return $client->get('/marker.txt');
    });
    is($existing->status, 200, 'existing file still responds');
    is($existing->text, "caller one\n", 'existing body is unchanged');
    is($existing_out, 'PAGI::App::File: attempting '
        . File::Spec->catfile($one_static, 'marker.txt') . "\n",
        'existing file emits one exact STDOUT record');
    is($existing_err, '', 'diagnostic does not use STDERR');

    my ($missing, $missing_out) = capture_output(sub {
        return $client->get('/missing.txt');
    });
    is($missing->status, 404, 'missing response is unchanged');
    is($missing_out, 'PAGI::App::File: attempting '
        . File::Spec->catfile($one_static, 'missing.txt') . "\n",
        'missing candidate is visible');

    my ($index, $index_out) = capture_output(sub { return $client->get('/') });
    is($index->status, 200, 'index still responds');
    is($index_out, 'PAGI::App::File: attempting '
        . File::Spec->catfile($one_static, 'index.html') . "\n",
        'directory request logs selected index');

    my ($empty, $empty_out) = capture_output(sub {
        return $client->get('/empty-dir');
    });
    is($empty->status, 404, 'directory without an index remains 404');
    is($empty_out, 'PAGI::App::File: attempting '
        . File::Spec->catdir($one_static, 'empty-dir') . "\n",
        'index-free directory logs its directory candidate');

    my ($head, $head_out) = capture_output(sub {
        return $client->head('/marker.txt');
    });
    is($head->status, 200, 'HEAD still responds');
    is($head_out, $existing_out, 'HEAD uses the same candidate diagnostic');
};
```

Add exact silence tests:

```perl
subtest 'only exact request-time development mode logs' => sub {
    for my $mode (undef, '', 'production', 'none', 'Development') {
        local $ENV{PAGI_ENV};
        defined $mode ? ($ENV{PAGI_ENV} = $mode) : delete $ENV{PAGI_ENV};
        my ($response, $stdout, $stderr) = capture_output(sub {
            return $client->get('/marker.txt');
        });
        is($response->status, 200, "request succeeds for mode " . ($mode // 'unset'));
        is($stdout, '', "STDOUT is silent for mode " . ($mode // 'unset'));
        is($stderr, '', "STDERR is silent for mode " . ($mode // 'unset'));
    }
};

subtest 'requests rejected before filesystem service stay silent' => sub {
    local $ENV{PAGI_ENV} = 'development';
    for my $case (
        ['POST', '/marker.txt', 405, 'unsupported method'],
        ['GET', "/bad\0name", 400, 'null byte'],
        ['GET', '/../secret', 403, 'traversal component'],
        ['GET', '/.env', 403, 'hidden component'],
    ) {
        my ($method, $path, $status, $label) = @$case;
        my ($events, $stdout) = capture_output(sub {
            return run_native($file_component, $method, $path);
        });
        is($events->[0]{status}, $status, "$label keeps its response status");
        is($stdout, '', "$label produces no file-attempt output");
    }
};
```

Add the log-injection and native-file-event boundary test with a hand-derived
expected escape rather than reusing the production renderer:

```perl
subtest 'diagnostic escapes controls without changing the native candidate' => sub {
    local $ENV{PAGI_ENV} = 'development';
    my $path = "/bad\nname";
    my ($events, $stdout, $stderr) = capture_output(sub {
        return run_native($file_component, 'GET', $path);
    });

    is($events->[0]{status}, 404, 'control-bearing missing path stays a 404');
    is($stdout, 'PAGI::App::File: attempting '
        . File::Spec->catfile($one_static, 'bad') . '\\x0Aname' . "\n",
        'newline is visible text inside one physical record');
    is($stderr, '', 'escaped diagnostic remains STDOUT-only');
};

subtest 'development output does not rewrite a served file event' => sub {
    local $ENV{PAGI_ENV} = 'development';
    my ($events, $stdout) = capture_output(sub {
        return run_native($file_component, 'GET', '/marker.txt');
    });
    is($events->[1]{file}, File::Spec->catfile($one_static, 'marker.txt'),
        'server receives the original lexical candidate');
    is($stdout, 'PAGI::App::File: attempting '
        . File::Spec->catfile($one_static, 'marker.txt') . "\n",
        'native request emits the same one-line diagnostic');
};
```

- [ ] **Step 3: Run the diagnostic tests and verify RED**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/app-file.t'
```

Expected: FAIL because development requests emit no `STDOUT` record. Confirm
existing response assertions remain green inside the failing subtests.

- [ ] **Step 4: Implement one safe development record at the agreed boundary**

Add this private helper to `lib/PAGI/App/File.pm`:

```perl
sub _development_file_attempt {
    my ($file_path) = @_;
    return unless ($ENV{PAGI_ENV} // '') eq 'development';

    my $display = $file_path;
    $display =~ s/([\x00-\x1f\x7f])/sprintf('\\x%02X', ord($1))/ge;
    print STDOUT "PAGI::App::File: attempting $display\n";
    return;
}
```

Call it exactly once after the existing directory/index loop and immediately
before the `unless (-f $file_path && -r $file_path)` check:

```perl
        _development_file_attempt($file_path);

        unless (-f $file_path && -r $file_path) {
```

Do not move it before method/path validation, after `realpath`, or into the
server send path.

- [ ] **Step 5: Run the diagnostic and constructor GREEN gate**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/app-file.t t/utils-app-path.t t/endpoint-router.t'
```

Expected: PASS with no leaked diagnostic lines outside the capture subtests.

- [ ] **Step 6: Document development output in App::File POD**

Add a `DEVELOPMENT DIAGNOSTICS` section that includes the exact record:

```text
PAGI::App::File: attempting /Project-MyApp/static/css/app.css
```

Document exact, request-time `PAGI_ENV=development`; `STDOUT`; one record after
index selection and before file/readability checking; existing and missing
candidates; silence for rejected paths/methods and all other modes; safe
control escaping; lexical rather than resolved symlink paths; absolute-path
disclosure; and that this is not access logging and never changes responses.

- [ ] **Step 7: Verify Task 2 and commit**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -c lib/PAGI/App/File.pm && podchecker lib/PAGI/App/File.pm'
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/app-file.t t/utils-app-path.t t/endpoint-router.t t/00-load.t'
git diff --check
```

Record RED/GREEN counts, stream-capture evidence, syntax/POD checks, and review
result in Task 2's ledger row. Then:

```bash
git add lib/PAGI/App/File.pm t/app-file.t
git commit -m "feat: show App File attempts in development"
```

---

### Task 3: Migrate and Exercise the Relevant Example Applications

**Files:**
- Modify: `examples/15-large-application/lib/MyApp/Root.pm:3-9,50-56`
- Modify: `examples/15-large-application/README.md:47-60`
- Modify: `t/integration-large-application.t:76-88`
- Modify: `examples/app-01-file/app.pl:1-31`
- Modify: `examples/app-01-file/README.md`
- Create: `t/integration-app-file-demo.t`
- Modify: `Changes:1-10`
- Test: `t/integration-large-application.t`
- Test: `t/integration-app-file-demo.t`

**Interfaces:**
- Consumes: Task 1's component-returning class constructor and Task 2's request-time diagnostic.
- Produces: canonical module form `mount('/static' => PAGI::App::File->app_path('static'))`; canonical root-script form `PAGI::App::File->app_path('static')->to_app`.

- [ ] **Step 1: Change the large-example source assertions first**

In `t/integration-large-application.t`, replace the old utility-import and
`root => app_path(...)` assertions with:

```perl
    unlike($root_app, qr/use PAGI::Utils qw\(app_path\)/,
        'Root no longer needs the functional application path helper');
    like($root_app,
        qr/mount\('\/static'\s*=>\s*PAGI::App::File->app_path\('static'\)\)/,
        'static mount uses the concise App File component constructor');
    unlike($root_app,
        qr/PAGI::App::File->new\s*\(|File::Basename|File::Spec|__FILE__|\$STATIC_ROOT/,
        'Root contains no manual or expanded static-root construction');
```

Keep the existing runtime `/static/app.css` assertions unchanged.

- [ ] **Step 2: Create a failing integration test for the root-level file example**

Create `t/integration-app-file-demo.t`:

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

my $app_file = "$Bin/../examples/app-01-file/app.pl";
my $source = source_text($app_file);

like($source,
    qr/PAGI::App::File->app_path\('static'\)->to_app/,
    'root-level example uses script-fallback alternate constructor');
unlike($source,
    qr/File::Basename|File::Spec|dirname\s*\(|PAGI::App::File->new\s*\(/,
    'root-level example contains no manual or expanded static-root setup');

local $ENV{PAGI_HOME};
delete $ENV{PAGI_HOME};
local $ENV{PAGI_ENV} = 'production';
my $app = do $app_file;
my $load_error = $@ || $!;
ok(!$load_error, 'file example loads cleanly') or diag($load_error);
is(ref($app), 'CODE', 'file example returns a compiled PAGI app');

SKIP: {
    skip 'example did not load', 6 unless ref($app) eq 'CODE';
    my $client = PAGI::Test::Client->new(app => $app);
    my $index = $client->get('/');
    is($index->status, 200, 'index is served');
    like($index->text, qr/Welcome to PAGI::App::File/,
        'index comes from the example static root');
    is($client->get('/test.txt')->text,
        "Hello from PAGI::App::File!\n", 'plain fixture is served');
    is($client->get('/data.json')->status, 200, 'JSON fixture is served');
    is($client->get('/subdir/nested.txt')->status, 200,
        'nested fixture is served');
    is($client->get('/missing.txt')->status, 404,
        'missing fixture remains 404');
}

done_testing;
```

- [ ] **Step 3: Run both example tests and verify RED source shape**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-large-application.t t/integration-app-file-demo.t'
```

Expected: FAIL only on the new source-shape assertions. Existing runtime static
responses should still pass with the old setup.

- [ ] **Step 4: Migrate the large module example**

In `examples/15-large-application/lib/MyApp/Root.pm`:

1. remove `use PAGI::Utils qw(app_path);`; and
2. replace the expanded static mount with:

```perl
            mount('/static' => PAGI::App::File->app_path('static')),
```

Do not change routing order, the `/static` prefix, Compose, lifespan, or any
other route.

- [ ] **Step 5: Migrate the root-level file example**

In `examples/app-01-file/app.pl`, remove `File::Basename`, `File::Spec`, `$dir`,
and `new(root => ...)`. Keep the feature comments and finish with:

```perl
my $app = PAGI::App::File->app_path('static')->to_app;

$app;
```

This preserves the ordinary app-file return shape while demonstrating script
fallback.

- [ ] **Step 6: Update both example READMEs and Changes**

In the large-example README, replace the statement that Root passes the
functional `app_path('static')` result to `new` with:

```text
Root uses `PAGI::App::File->app_path('static')`, a component constructor that
derives application home from the calling `lib/MyApp/Root.pm`, appends the
platform-aware static component, and can be mounted directly. `PAGI_HOME`
remains the override for nonstandard deployments.
```

In `examples/app-01-file/README.md`, add a concise setup block and development
diagnostic:

```perl
PAGI::App::File->app_path('static')->to_app;
```

```text
PAGI_ENV=development prints one `PAGI::App::File: attempting ...` line to
STDOUT for each valid candidate. The line contains an absolute local path and
is intentionally disabled in production.
```

Add one `0.002003` Changes bullet covering the class constructor, per-use caller
origins, development diagnostic, and the two migrated examples. Do not claim a
PAGI-Server change or general static mounting framework.

- [ ] **Step 7: Run the example GREEN gate**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-large-application.t t/integration-app-file-demo.t t/app-file.t'
```

Expected: PASS. The large app must still serve `/static/app.css`; the root
example must serve index, plain, JSON, and nested fixtures through
`PAGI::Test::Client`.

- [ ] **Step 8: Verify example syntax and source hygiene**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -c examples/app-01-file/app.pl && perl -Ilib -Iexamples/15-large-application/lib -c examples/15-large-application/lib/MyApp/Root.pm'
rg -n "File::Basename|File::Spec|dirname\(|PAGI::Utils qw\(app_path\)|PAGI::App::File->new" examples/app-01-file/app.pl examples/15-large-application/lib/MyApp/Root.pm
git diff --check
```

Expected: both files compile; `rg` finds none of the removed setup patterns;
diff check has no output.

- [ ] **Step 9: Update the ledger and commit Task 3**

Record the example RED/GREEN totals, runtime paths exercised, syntax evidence,
and review result. Then:

```bash
git add Changes \
  examples/15-large-application/lib/MyApp/Root.pm \
  examples/15-large-application/README.md \
  examples/app-01-file/app.pl examples/app-01-file/README.md \
  t/integration-large-application.t t/integration-app-file-demo.t
git commit -m "examples: use App File application paths"
```

---

### Task 4: Contract Audit, Final Review, and Repository Verification

**Files:**
- Verify: all files changed by Tasks 1-3
- Verify: `docs/superpowers/specs/2026-08-11-app-file-app-path-design.md`
- Update: `.superpowers/sdd/2026-08-11-app-file-app-path/progress.md` (ignored execution evidence only)

**Interfaces:**
- Consumes: the complete three-commit feature range.
- Produces: evidence that the implementation matches the design, examples use the new constructor, and the repository suite passes once on the final tree.

- [ ] **Step 1: Audit the complete range against the design**

Run:

```bash
git status --short
git log --oneline main..HEAD
git diff --stat main...HEAD
git diff --check main...HEAD
rg -n "sub _remember_app_path_origin|sub app_path|sub import|_development_file_attempt|PAGI::App::File: attempting" lib/PAGI/Utils.pm lib/PAGI/App/File.pm t/app-file.t
rg -n "PAGI::App::File->app_path\('static'\)" examples/15-large-application examples/app-01-file t/integration-large-application.t t/integration-app-file-demo.t
```

Confirm explicitly:

```text
- one shared origin cache and resolver;
- package-plus-source registration for every ordinary use;
- no exported/private-origin public API;
- class-only object-returning constructor and subclass preservation;
- all constructor arguments are components;
- request-time exact development gate;
- one safe STDOUT record at the agreed request boundary;
- rejected requests and nondevelopment modes are silent;
- no response/file-event mutation;
- both examples migrated and runtime exercised;
- no PAGI-Server, Endpoint app_path, dependency, MIME, range, or security-algorithm scope creep.
```

- [ ] **Step 2: Run syntax, POD, and focused contract gates**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -c lib/PAGI/Utils.pm && perl -Ilib -c lib/PAGI/App/File.pm && podchecker lib/PAGI/Utils.pm && podchecker lib/PAGI/App/File.pm'
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/app-file.t t/utils-app-path.t t/endpoint-router.t t/integration-large-application.t t/integration-app-file-demo.t t/00-load.t'
git diff --check main...HEAD
```

Expected: syntax/POD OK, focused tests PASS, diff check clean. Record exact
Files/Tests totals and any known baseline-only compiler warning separately.

- [ ] **Step 3: Obtain independent whole-range review**

Package the `main...HEAD` feature range with the design and this plan. The reviewer must
check specification compliance, caller-origin correctness across multiple
files and `chdir`, import behavior, class/subclass semantics, control escaping,
diagnostic placement, stream destination, examples, documentation, tests,
Perl 5.18 compatibility, and scope creep.

Require findings grouped as Critical, Important, and Minor with file/line
references and an explicit ready/not-ready conclusion. Resolve all findings;
do not defer Minor findings silently. If a finding conflicts with the approved
design, record a deviation and obtain user direction before changing course.

- [ ] **Step 4: Run the one final repository-wide suite**

After the whole-range review is clean, run once on the final tree:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t'
```

The SSE end-to-end test requires permission to bind a local socket; run this
final gate outside a restricted socket sandbox when necessary. Expected:
`Result: PASS`. Record exact Files/Tests and timing. Do not repeat a valid green
run merely for confidence.

If the run finds a real defect, preserve the failure as RED, apply one scoped
TDD fix, obtain scoped re-review, and run one replacement full suite because
the tree changed. If the run is invalid only because the environment denied a
required socket, record that fact and replace it once in the correct
environment.

- [ ] **Step 5: Close execution tracking and finish the branch**

Mark Task 4 complete with focused, review, and full-suite evidence. Confirm:

```bash
git status --short
git diff --check main...HEAD
git log --oneline main..HEAD
```

Remove only this plan's ignored `.superpowers/sdd/2026-08-11-app-file-app-path`
workspace after verifying its exact path and contents. Then use
`superpowers:finishing-a-development-branch` to offer local merge, PR, or
preservation. Do not merge or push without the user's integration choice.
