# App::File Application-Path Constructor Design

**Date:** 2026-08-11
**Status:** Proposed for user review

## 1. Purpose

Make the common static-file case concise without weakening the existing
application-home rules:

```perl
mount('/static' => PAGI::App::File->app_path('static'));
```

`PAGI::App::File->app_path(@path_parts)` is a narrow alternate constructor. It
finds the calling application's home through the existing `PAGI::Utils`
contract, constructs a platform-aware root beneath that home, and returns a
configured `PAGI::App::File` object.

Also make static-file mistakes easier to diagnose in development. When
`PAGI_ENV` is exactly `development`, each valid file attempt prints the final
lexical candidate path to `STDOUT` before the app decides whether it can serve
that candidate.

These two changes address the ordinary case. They do not replace `new`, add a
general path object, or turn `PAGI::App::File` into a static-mount framework.

## 2. Public constructor

### 2.1 Shape and return value

The new API is:

```perl
use PAGI::App::File;

my $home   = PAGI::App::File->app_path();
my $static = PAGI::App::File->app_path('static');
my $assets = PAGI::App::File->app_path('static', 'assets');
```

It is equivalent in intent to:

```perl
use PAGI::Utils qw(app_path);

my $static = PAGI::App::File->new(
    root => app_path('static'),
);
```

The method returns an object, not a path string and not a compiled PAGI
coderef. Existing composition points already accept objects with `to_app`, so
the canonical mount does not need an explicit `->to_app`:

```perl
mount('/static' => PAGI::App::File->app_path('static'));
```

Calling the constructor with no path parts is valid and uses the application
home itself as the file root.

The invoked class constructs the result. A subclass therefore retains its
type:

```perl
my $files = MyApp::StaticFile->app_path('static');
# ref($files) eq 'MyApp::StaticFile'
```

`PAGI::App::File->new` retains its existing behavior, including resolving an
existing root through `Cwd::realpath`. The alternate constructor promises the
same result as passing the application path to `new`; it does not introduce a
second root-storage contract.

### 2.2 Deliberately narrow argument grammar

Every argument after the class name is a logical path component. The alternate
constructor has no options hash, trailing hash reference, named arguments, or
method coercion:

```perl
PAGI::App::File->app_path('static', 'images'); # valid
PAGI::App::File->app_path('static', { index => ['home.html'] }); # invalid component
```

Applications that need nondefault file behavior use the explicit constructor:

```perl
use PAGI::Utils qw(app_path);

my $files = PAGI::App::File->new(
    root          => app_path('static'),
    handle_ranges => 0,
    index         => ['home.html'],
);
```

Path-component validation, joining, `PAGI_HOME` precedence, and diagnostics
come from the shared `PAGI::Utils` implementation. In particular, undefined,
empty, reference-valued, absolute, and separately volumed components croak
under the existing positional component contract.

### 2.3 Class-only invocation

`app_path` is a class constructor. An object invocation croaks clearly before
path resolution:

```perl
my $files = PAGI::App::File->new(root => '/srv/files');
$files->app_path('other'); # croaks: class constructor only
```

This prevents an existing object from looking like it is being mutated or
cloned. An unblessed reference is rejected by the same class-only check. A
normal class string, including a subclass, proceeds to path resolution and
then calls `$class->new(root => $path)`.

## 3. Stable caller-origin resolution

### 3.1 Why a normal wrapper is insufficient

`PAGI::Utils::app_path` is caller-sensitive. If `PAGI::App::File->app_path`
simply called that public function, the utility would see
`PAGI::App::File.pm` as its caller and resolve the installed PAGI::Tools home,
not the application home.

Capturing `caller` inside the class method fixes the ordinary case but loses an
existing guarantee. A module can be loaded from a relative source such as
`lib/MyApp/Root.pm`, after which the process may change directory before its
`routing` method runs. Resolving that relative source only at constructor-call
time would anchor it to the new working directory. `PAGI::Utils` already avoids
this drift by remembering an absolute source location at import time.

### 3.2 Shared internal registration seam

Factor the existing import-time source capture into one private
`PAGI::Utils` helper. The intended internal operation is conceptually:

```perl
PAGI::Utils::_remember_app_path_origin($package, $source);
```

The helper accepts the caller package and source file, validates that both are
usable non-reference strings, makes the source absolute and platform-canonical
at that moment, and records it in the existing application-path origin table.
Unusable import metadata is ignored; the public resolver later gives its
existing `set PAGI_HOME` diagnostic if no usable origin exists.

The table remains keyed by both package and reported source file. It is not one
global application home and not one origin per `PAGI::App::File` class:

```text
(MyApp::Root,  lib/MyApp/Root.pm)  -> /project/lib/MyApp/Root.pm
(MyApp::Admin, lib/MyApp/Admin.pm) -> /project/lib/MyApp/Admin.pm
```

The package-plus-source key also permits a package that is deliberately split
across more than one source file to retain distinct origins.

`PAGI::Utils::import` delegates its current source-capture work to this helper;
its public exports and behavior do not change.

### 3.3 `PAGI::App::File` import convention

`PAGI::App::File` adds an `import` method that exports nothing. Each ordinary:

```perl
use PAGI::App::File;
```

registers that use site's package and source through the shared private helper.
Perl calls `import` for every `use`, even after `require` has loaded the module,
so many application files can use the constructor independently without
overwriting one another.

The import method preserves the module's no-export surface. It exists only to
record origin metadata and does not make symbols available in the caller.
Import arguments remain ignored, matching the module's current inherited
no-op import behavior; this feature does not create a symbol-import grammar.

A source file that calls this alternate constructor should itself use
`PAGI::App::File`. Loading the class elsewhere, calling it after
`use PAGI::App::File ()`, or relying only on `require` bypasses import-time
registration. The method still uses its immediate caller package and source,
so those forms work while that reported source is usable. They do not promise
relative-source stability after a later `chdir`; `PAGI_HOME` is the explicit
escape hatch for that unusual loading pattern.

### 3.4 Constructor data flow

At each `PAGI::App::File->app_path(@parts)` call:

1. reject a reference invocant;
2. capture the immediate caller package and source file;
3. load `PAGI::Utils` if an import hook did not already load it;
4. pass the caller package, caller source, and components to the existing
   private origin-aware application-path resolver; and
5. return `$class->new(root => $resolved_path)`.

This deliberately reuses the same resolver as the exported function and the
`PAGI::Endpoint::Router` helper. There is no second path algorithm, public
caller-depth parameter, public origin override, or direct manipulation of the
origin table by `PAGI::App::File`.

A subclass may override `app_path` through ordinary Perl method dispatch. Such
an override affects that subclass only; it does not change `PAGI::Utils` or the
base constructor.

## 4. Development file-attempt diagnostic

### 4.1 Mode and timing

The diagnostic is enabled only when this expression is true at request time:

```perl
($ENV{PAGI_ENV} // '') eq 'development'
```

The comparison is exact and case-sensitive. `production`, `none`, an unset or
empty variable, and all other values are silent. Checking per request means
the environment in effect for that request controls the behavior; compiling
the app does not freeze the mode.

`pagi-server` already resolves its mode and sets `PAGI_ENV` before loading the
application. No server change is required.

For a valid HTTP `GET` or `HEAD`, `PAGI::App::File` keeps this order:

1. reject unsupported methods;
2. reject null bytes, traversal components, and hidden components;
3. join the validated request path beneath the configured root;
4. when the candidate is a directory, select the first configured index entry
   that is a file;
5. emit the development diagnostic once; and
6. perform the existing file/readability and resolved-path security checks.

Rejected methods and rejected paths do not emit a candidate because the app
does not attempt filesystem service for them. Existing files, missing files,
and candidates later rejected by the resolved-path check do emit one line.

### 4.2 Format

The output is one `STDOUT` line:

```text
PAGI::App::File: attempting /Project-MyApp/static/css/app.css
```

The implementation performs one print operation ending in `\n`. It does not
write this diagnostic to `STDERR`, use `warn`, include request headers, or
change the response.

The candidate is the lexical path built beneath the configured root. It is not
the later `realpath` result. Consequently, a symlink candidate that is later
rejected logs its in-root lexical name rather than disclosing its resolved
external target.

For `/`, a discovered index file is the logged candidate. If the directory has
no configured index file, the directory candidate itself is logged before the
request becomes a 404.

### 4.3 One-line integrity

The request path is untrusted input and may contain decoded control characters.
Before printing, the diagnostic representation escapes ASCII control
characters, including carriage return and line feed, into visible hexadecimal
escapes. The ordinary platform path remains human-readable, including native
path separators. This preserves the promised one-record-per-line shape and
prevents a crafted development request from injecting additional diagnostic
lines or terminal controls.

This rendering is diagnostic-only. It does not alter the path used for file
selection or the emitted file event.

### 4.4 Disclosure boundary

The diagnostic intentionally exposes an absolute application filesystem path
on `STDOUT`. Its purpose is local development diagnosis, and the POD calls out
that disclosure. Production and unrecognized modes stay silent by default.
This feature is not access logging, an audit trail, or a substitute for the
existing access-log middleware.

## 5. Canonical examples

### 5.1 Large application module

`examples/15-large-application/lib/MyApp/Root.pm` changes from:

```perl
use PAGI::App::File;
use PAGI::Utils qw(app_path);

mount('/static' => PAGI::App::File->new(
    root => app_path('static'),
));
```

to:

```perl
use PAGI::App::File;

mount('/static' => PAGI::App::File->app_path('static'));
```

This is the conventional `lib/MyApp/Root.pm` case and removes the now-redundant
utility import. Its README explains that the class constructor returns a
component object and derives the home from the calling application module.

### 5.2 Root-level file application

`examples/app-01-file/app.pl` removes `File::Basename`, `File::Spec`, and its
manual `dirname(__FILE__)` construction. Its app becomes:

```perl
use PAGI::App::File;

PAGI::App::File->app_path('static')->to_app;
```

This demonstrates script fallback and the fact that a top-level server entry
still needs `->to_app` when returning the compiled coderef itself. Its README
documents the development diagnostic.

Only these two examples migrate. In particular, the Endpoint demo remains an
example of the inherited Endpoint application-path helper, and advanced
examples that set file options keep `new(root => ...)`.

## 6. Documentation

`PAGI::App::File` POD documents:

- the class-only alternate constructor and object return value;
- the no-argument and multiple-component forms;
- the simple mount form without `->to_app`;
- `new(root => ...)` as the advanced configuration path;
- equivalence to the shared `PAGI::Utils` path contract;
- the ordinary `use PAGI::App::File` caller-registration convention;
- the `use Module ()`/`require` relative-source caveat and `PAGI_HOME` escape;
- subclass construction;
- exact development-mode detection, output destination, format, and timing;
- the absolute-path disclosure and one-line escaping boundary; and
- that development diagnostics do not change responses or replace access
  logging.

`PAGI::Utils` keeps the origin registrar and origin-aware resolver documented
as unsupported internal seams. Its public `app_path` contract and exports do
not change.

The two example READMEs and relevant integration assertions are updated to
match their new source shape and preserve runtime coverage.

## 7. Testing

Add focused PAGI-Tools tests for the touched component rather than relying
only on PAGI-Server's sibling-distribution integration suite.

### 7.1 Constructor and origin tests

Tests cover:

1. the method returns a `PAGI::App::File` object;
2. a subclass invocation returns that subclass;
3. an object or other reference invocant croaks as class-only;
4. no components select the application home;
5. multiple components use the shared platform-aware join behavior;
6. invalid components retain the shared positional diagnostics;
7. `PAGI_HOME` takes first precedence;
8. a conventional package under `lib/` finds the directory above `lib`;
9. two different source files that each use `PAGI::App::File` retain
   independent caller origins;
10. caller origins loaded through relative source paths stay fixed after
    `chdir`;
11. a root-level script call uses script fallback; and
12. the returned component serves a fixture through `PAGI::Test::Client`, so
    tests prove consumer behavior rather than only inspecting its private
    `root` field.

Fixtures use distinct content where needed so an origin mix-up cannot make two
applications confirm the same path accidentally.

### 7.2 Diagnostic tests

Build an app once and vary localized `PAGI_ENV` values at request time. Capture
`STDOUT` and `STDERR` independently. Tests cover:

1. an existing file logs its final candidate once and still returns 200;
2. a missing file logs its candidate once and still returns 404;
3. a directory request logs the selected index path;
4. `HEAD` follows the same logging contract;
5. production, none, unset, empty, and differently cased values are silent;
6. unsupported methods, null bytes, traversal components, and hidden
   components are silent;
7. a candidate containing control characters remains one physical output line
   and visibly escapes those characters;
8. the diagnostic appears only on `STDOUT`; and
9. development logging does not alter response events or the `file` path sent
   to the server.

Existing file-serving behavior touched by the insertion point is characterized
locally: index selection, successful serving, missing files, and security
rejections retain their current statuses and response shapes.

### 7.3 Regression and example tests

- Existing `PAGI::Utils` and Endpoint application-path tests remain green after
  factoring the shared registration helper.
- The large-application integration test continues to fetch its static CSS and
  asserts the concise constructor source shape.
- The file-app example receives a focused integration/source-shape assertion
  proving the root-level script form serves its existing fixtures.
- Syntax and POD checks cover both changed modules.
- The repository suite runs on the merged implementation.

No PAGI-Server source or test change is required for this design. Its existing
cross-distribution static-file suite remains useful downstream coverage.

## 8. Compatibility and security

The public change is additive. `new`, `to_app`, response behavior, and existing
file options retain their contracts. Defining a no-export `import` hook adds
caller bookkeeping to ordinary `use PAGI::App::File` without exporting names
or performing filesystem I/O. The bookkeeping stores canonical source-path
strings for the process lifetime, matching the existing `PAGI::Utils` origin
cache.

The constructor uses the existing application's path validation contract. It
does not check that constructor path parts remain beneath application home and
does not turn trusted configuration into a sandbox. Request-time traversal and
symlink protections remain the responsibility of `PAGI::App::File`'s existing
serving path.

Development output can reveal absolute deployment paths. It is strictly gated
by exact `PAGI_ENV=development`, renders untrusted controls safely, and logs the
lexical candidate rather than an escaped symlink target. Applications must not
enable development mode where that disclosure is unacceptable.

The implementation uses Perl 5.18-compatible syntax and core path facilities.
It adds no dependency.

## 9. Non-goals

- No path-object abstraction.
- No automatic static mount or URL prefix.
- No options accepted by the alternate constructor.
- No `to_app` return from `app_path`; it returns a component object.
- No public caller depth, caller package, source-file, or origin-registration
  API.
- No change to `PAGI::Endpoint::Router->app_path`, which still returns a path
  string.
- No caller-origin search through arbitrary stack frames.
- No filesystem existence check or directory creation during application-path
  construction.
- No general App::File refactor, security rewrite, or MIME/range change.
- No access-log integration or configurable diagnostic logger in this narrow
  version.
- No PAGI-Server change.
- No migration of every static-file example.

## 10. Alternatives considered

### Resolve only from method-time `caller`

This is smaller but reintroduces relative-source drift after `chdir`, a bug the
shared utility already solved. The class shortcut should not be less reliable
than the explicit utility form it replaces.

### Add a public caller-depth or origin override to `PAGI::Utils`

This permits general wrappers but expands a deliberately narrow public API and
makes callers responsible for stack details. The private origin seam and
`PAGI_HOME` cover the actual need without committing to a general wrapper
protocol.

### Resolve from the invoked File subclass through `%INC`

That model is correct for `PAGI::Endpoint::Router`, whose application subclass
is itself the origin. It is wrong for direct
`PAGI::App::File->app_path('static')`: the invoked class lives in the
PAGI::Tools distribution, while the desired home belongs to the application
call site.

### Cache one home in `PAGI::App::File`

A single cache breaks applications assembled from multiple packages or
multiple application roots in one process. Per-package is still insufficient
for intentionally split packages. The existing package-plus-source origin key
is the appropriate identity.

### Accept constructor options after path parts

A trailing hash reference or parity-based grammar makes a frequent shortcut
harder to read and weakens the rule that every argument is a path component.
Advanced callers already have the explicit `new(root => ...)` form.

### Send diagnostics to `STDERR` or a logger callback

Those are conventional logging designs, but the requested development aid is
specifically visible on `STDOUT`. A configurable logging abstraction would be
larger than this feature; exact development gating and safe one-line rendering
keep the requested behavior bounded.

## 11. Success criteria

The design succeeds when both of these applications serve their static roots
without manual path arithmetic:

```perl
# root-level app.pl
PAGI::App::File->app_path('static')->to_app;

# lib/MyApp/Root.pm router component
mount('/static' => PAGI::App::File->app_path('static'));
```

Both forms must retain the shared `PAGI_HOME`, conventional-layout,
script-fallback, validation, and relative-source stability contracts. Multiple
caller files must coexist without origin collisions. In development, a valid
file attempt must emit exactly one safe `STDOUT` line naming the final lexical
candidate while production and rejected requests remain silent. Existing
file-serving responses and the complete PAGI-Tools test suite must remain
green.
