# Application Path Helper Design

**Date:** 2026-08-11
**Status:** Proposed for user review

## 1. Purpose

Add one small path facility that finds an application's conventional home
directory and builds paths beneath it. Functional applications import it from
`PAGI::Utils`; method-oriented applications inherit the same facility from
`PAGI::Endpoint::Router`. This removes repeated `__FILE__`, `dirname`, and `..`
arithmetic from application packages such as
`examples/15-large-application/lib/MyApp/Root.pm`.

The intended application layout is:

```text
/Project-MyApp
├── app.pl
├── static/
└── lib/
    └── MyApp/
        └── Root.pm
```

Both `app.pl` and `MyApp::Root` should identify `/Project-MyApp` as the
application home.

## 2. Decision

Export an optional `app_path` function from `PAGI::Utils`:

```perl
use PAGI::Utils qw(app_path);

my $home       = app_path();
my $static     = app_path('static');
my $stylesheet = app_path('static', 'app.css');
```

`app_path()` returns the detected application home as an absolute path string.
With arguments, it appends the supplied path components and returns the
resulting absolute path string.

`app_path` joins components with Perl's platform-aware `File::Spec` APIs. User
code does not concatenate `/`, `\\`, or another platform separator. The final
component may identify either a file or a directory; the helper performs no
filesystem lookup and does not attach type semantics to the returned string.

`app_path` joins only the components supplied by its caller. Portable call
sites should pass each logical component separately:

```perl
app_path('static', 'images', 'logo.svg');
```

They should not encode a platform separator in one component:

```perl
app_path('static/images/logo.svg'); # discouraged
```

The helper is included in `PAGI::Utils`'s `:all` export bundle but is not
exported by default.

`PAGI::Endpoint::Router` exposes the same operation as an inherited helper:

```perl
package MyApp::Endpoint;

use parent 'PAGI::Endpoint::Router';

sub routes {
    my ($self, $r) = @_;
    my $static_root = $self->app_path('static');
    ...;
}
```

The method accepts either an object or class invocant and returns the same
ordinary absolute path string as the function. It is a convenience frontend,
not a second detection or path-building implementation.

## 3. Application-home detection

Both public frontends use the following precedence. The exported function
supplies its immediate caller package and source file as the detection origin.
The Endpoint method supplies its concrete loaded class and source as described
in section 3.4. All remaining detection and path construction is shared.

### 3.1 Explicit `PAGI_HOME`

When `PAGI_HOME` is defined and nonempty, it is the application home. A
relative value is made absolute relative to the process's current working
directory. This is the explicit escape hatch for installed distributions,
fatpacked or virtual module paths, unusual source layouts, wrapper helpers, and
deployments that change directory before resolving a relative source filename.

An empty `PAGI_HOME` is treated as unset. The value need not name an existing
directory.

### 3.2 Conventional module layout

Otherwise, the resolver inspects its origin package and source file. For a
package such as `MyApp::Root`, it converts the package name into path components
(`MyApp`, `Root.pm`) and compares those components with the end of the origin
filename.

When they match, `app_path` removes the package components and then removes a
trailing `lib` and, when present, a trailing `blib`. Examples:

```text
/Project-MyApp/lib/MyApp/Root.pm
    -> /Project-MyApp

/Project-MyApp/blib/lib/MyApp/Root.pm
    -> /Project-MyApp
```

The comparison and reconstruction use `File::Spec` path decomposition rather
than literal separator matching. Comparisons honor the current platform's
case-tolerance rules.

The helper removes only structural components proven by the package/file
suffix. It does not search upward for the first directory named `lib`, because
an unrelated ancestor can have that name.

### 3.3 Script fallback

If the package-derived suffix does not match, the application home is the
directory containing the origin source file. This covers a direct function
call from a normal entry script:

```text
/Project-MyApp/app.pl
    -> /Project-MyApp
```

This fallback is intentionally local and predictable. It does not scan parent
directories for marker files or directory names.

### 3.4 Endpoint class resolution

An inherited method cannot simply call the public `app_path` function: its
immediate package would be `PAGI::Endpoint::Router`, incorrectly making the
installed PAGI::Tools distribution the application. The Endpoint helper
therefore identifies the concrete class from its object or class invocant and
looks up that class's loaded source path through `%INC` using the ordinary
`MyApp::Endpoint` to `MyApp/Endpoint.pm` conversion.

That concrete class and source path are passed to the same internal resolver
used by the exported function. A conventional class such as:

```text
/Project-MyApp/lib/MyApp/Endpoint.pm
```

therefore resolves to `/Project-MyApp`, even though `app_path` is implemented
in the inherited base class.

If the concrete class has no `%INC` entry because it was declared inline in a
script, the helper uses the source file of the method call as its script
fallback. If neither source is usable and `PAGI_HOME` is unset, it croaks with
the same explicit-override guidance as the function.

The shared origin-aware resolver is an internal implementation seam, not an
additional exported function or public class-argument form.

## 4. Path construction contract

After detecting the home, `app_path`:

1. makes the home absolute with `File::Spec->rel2abs`;
2. applies `File::Spec->canonpath` for the platform's lexical cleanup; and
3. joins supplied child components with `File::Spec->catfile` and canonicalizes
   the result.

The helper does not require the home or child path to exist. It does not call
`abs_path`/`realpath`, resolve symbolic links, create directories, open files,
or verify that the result remains beneath the detected home. In particular,
`canonpath` does not collapse `..` components. `app_path` is a convenient path
builder, not a filesystem sandbox or authorization boundary.

Each supplied child component must be a defined, non-reference scalar and must
be nonempty. It must not itself be an absolute path or carry a separate volume
specifier on platforms that support volumes. Invalid components croak with an
error that identifies the argument position and the `app_path` contract.
Calling `app_path()` with no child components is valid and returns the home.

If the selected origin does not contain a usable source filename and
`PAGI_HOME` is unset, detection croaks with guidance to set `PAGI_HOME`; it does
not silently use the current working directory as the application home.

## 5. Caller convention

The exported `app_path` function is intentionally caller-sensitive.
Applications should invoke it directly from their entry script or application
package:

```perl
package MyApp::Root;

use PAGI::Utils qw(app_path);

my $STATIC_ROOT = app_path('static');
```

A local wrapper changes the immediate caller and therefore changes convention
detection:

```perl
sub project_file { app_path(@_) }
```

Applications that need such a wrapper should set `PAGI_HOME` explicitly.
Endpoint subclasses should use their inherited `$self->app_path(...)` helper,
which deliberately resolves the concrete Endpoint class. This first version
does not add a caller-depth option, a public class argument, a path object, or
a subclass hook. Those features add API surface to solve uncommon cases
already covered by the Endpoint helper or `PAGI_HOME`.

## 6. Canonical static-file example

`examples/15-large-application/lib/MyApp/Root.pm` changes from:

```perl
use File::Basename qw(dirname);
use File::Spec;

my $STATIC_ROOT = File::Spec->catdir(
    dirname(__FILE__), '..', '..', 'static',
);

mount('/static' => PAGI::App::File->new(
    root => $STATIC_ROOT,
));
```

to:

```perl
use PAGI::Utils qw(app_path);

mount('/static' => PAGI::App::File->new(
    root => app_path('static'),
));
```

The example's `app.pl` continues to locate its own `lib` directory before
`PAGI::Utils` or `MyApp::Root` can be loaded. `app_path` is an application
resource-path helper, not a replacement for bootstrap-time `use lib` or the
planned `pagi-server --lib` support.

Only the large-application example is migrated in this work. Other examples
with local path arithmetic are useful follow-up candidates, but converting all
of them is not required to validate or ship the helper.

## 7. Documentation

`PAGI::Utils` POD documents:

- the no-argument and component forms;
- the `PAGI_HOME`, module-layout, and script-fallback precedence;
- portable component usage;
- the direct-caller convention and wrapper caveat;
- the lack of existence checks, side effects, symlink resolution, and sandbox
  guarantees; and
- the relationship to application bootstrap (`use lib` remains separate).

`PAGI::Endpoint::Router` POD documents:

- `$self->app_path()` and `$self->app_path(@components)`;
- equivalence with the `PAGI::Utils` function;
- concrete-class resolution for inherited helpers;
- inline-class fallback and `PAGI_HOME`; and
- that overriding the ordinary method changes only that Endpoint subclass's
  explicit helper calls, not routing compilation.

The large-application README explains that its static root is derived from the
standard `lib/MyApp/Root.pm` layout and that `PAGI_HOME` handles a nonstandard
deployment layout.

## 8. Testing

Add focused function and Endpoint-helper tests covering:

1. `PAGI_HOME` takes precedence over caller detection;
2. an absolute `PAGI_HOME` is preserved modulo platform canonicalization;
3. a relative `PAGI_HOME` is made absolute from the current working directory;
4. an empty `PAGI_HOME` falls through to convention detection;
5. a package loaded from `lib/MyApp/Root.pm` finds the directory above `lib`;
6. a package loaded from `blib/lib/MyApp/Root.pm` finds the directory above
   `blib`;
7. a direct script-style call falls back to the caller file's directory;
8. no arguments return the home;
9. multiple components produce the value expected from `File::Spec` on the
   running platform;
10. undefined, empty, reference-valued, absolute, and separately volumed child
    components croak clearly;
11. a nonexistent child path is returned without filesystem side effects; and
12. `app_path` is available through explicit import and the `:all` bundle, but
    is not a default export;
13. an Endpoint object helper resolves from its concrete subclass's `%INC`
    source rather than from `PAGI::Endpoint::Router.pm`;
14. an Endpoint class invocant has the same behavior as an instance;
15. an inline Endpoint subclass uses its method caller's script source; and
16. the Endpoint helper honors `PAGI_HOME` and shares function validation and
    path-joining behavior.

Update the large-application integration test, if necessary, to continue
proving `/static/app.css` is served from the detected root. The test must not
derive its expected result with the same helper in a way that could make a
wrong detection algorithm confirm itself.

## 9. Non-goals

- No `PAGI::Home` object or new path-object dependency.
- No new runtime dependency; the implementation uses core `File::Spec`.
- No separate `app_dir` and `app_file` APIs.
- No second Endpoint-specific detection algorithm or path representation.
- No project-root search based on marker files, directory names, or the current
  working directory beyond resolving a relative `PAGI_HOME`.
- No implicit directory creation or resource loading.
- No static-file mounting helper.
- No `pagi-server` loader changes.
- No sweep converting every existing example.
- No security claim that paths built from untrusted components remain inside
  application home.

## 10. Alternatives considered

### `app_home()` returning only a string

This makes home detection reusable but leaves every caller importing
`File::Spec` and repeating path joining. It does not remove enough of the
ceremony that motivated the feature.

### A `PAGI::Home` path object

An object could stringify to the home and expose `child`/`rel_file` methods,
closely resembling `Mojo::Home`. It also starts a general filesystem
abstraction, adds method and coercion policy, and may invite a new dependency.
The current need is satisfied by one function returning ordinary path strings.

### Searching ancestors for `lib`, `static`, or a marker file

Ancestor discovery looks convenient but is ambiguous in monorepos, installed
module trees, and paths with unrelated `lib` ancestors. Exact package/file
suffix removal is deterministic; `PAGI_HOME` covers layouts outside that
convention.

## 11. Success criteria

The design succeeds when the canonical large application can configure its
static mount with `app_path('static')`, the same helper behaves correctly when
called from a root-level script or a conventional `lib/` package, path joining
is platform-aware, an Endpoint subclass gets the equivalent result through
`$self->app_path('static')`, and unusual deployments have an explicit
`PAGI_HOME` override without introducing a new application or filesystem
abstraction.
