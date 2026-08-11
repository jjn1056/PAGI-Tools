# Remaining Example App::File Migration Design

**Date:** 2026-08-11

## Goal

Make every example application that serves files with `PAGI::App::File` use
the new application-relative constructor, while preserving each example's
existing routing and runtime behavior. Also remove redundant `use warnings`
pragmas from the Perl 5.40 large application.

## Current State

Two examples already use the constructor:

- `examples/app-01-file/app.pl` compiles the returned component with
  `PAGI::App::File->app_path('static')->to_app`.
- `examples/15-large-application/lib/MyApp/Root.pm` mounts
  `PAGI::App::File->app_path('static')` directly.

Four example applications still construct a file root manually:

- `examples/endpoint-demo/app.pl`
- `examples/sse-dashboard/app.pl`
- `examples/13-contact-form/app.pl`
- `examples/endpoint-router-demo/lib/MyApp/Main.pm`

The six Perl source files in `examples/15-large-application` use `v5.40` and
then repeat `use warnings`. `use v5.40` already enables both strictures and
warnings, so the extra pragma is redundant.

## Design

### Constructor shape follows how the consumer uses the file application

Root-level scripts that retain and invoke a native PAGI application compile
the component explicitly:

```perl
my $static_app = PAGI::App::File->app_path('public')->to_app;
```

Routers mount the component directly and do not call `to_app`:

```perl
$router->mount('/' => PAGI::App::File->app_path('public'));
```

This gives each example the shortest correct form without hiding the
component-versus-application distinction.

### Per-example changes

`endpoint-demo/app.pl` mounts the `public` component directly. Its
`File::Basename` and `File::Spec` imports become unused and are removed.

`sse-dashboard/app.pl` stores the compiled `public` application because its
manual dispatcher invokes that coderef. Its path imports become unused and
are removed.

`13-contact-form/app.pl` compiles the `public` component for its manual
dispatcher. Its existing `dirname`/`File::Spec` calculation remains for the
writable `uploads` directory; `app_path` is not a general path-returning
helper and must not replace that calculation.

`endpoint-router-demo/lib/MyApp/Main.pm` mounts the `public` component
directly. The caller-origin convention removes the complete
`lib/MyApp/Main.pm` suffix, so `app_path('public')` resolves to the example's
top-level `public` directory. Its now-unused path imports are removed.

### Perl 5.40 headers

Remove `use warnings;` from these files, leaving `use v5.40;` as the single
language-version declaration:

- `examples/15-large-application/app.pl`
- `examples/15-large-application/lib/MyApp/Data.pm`
- `examples/15-large-application/lib/MyApp/Root.pm`
- `examples/15-large-application/lib/MyApp/Person.pm`
- `examples/15-large-application/lib/MyApp/Person/Blogs.pm`
- `examples/15-large-application/lib/MyApp/View.pm`

This does not disable warnings; Perl 5.40 enables them lexically as part of
`use VERSION`.

### Documentation

Update the four affected example READMEs where needed to show or explain the
new static-file form. Keep the documentation focused on each example's main
purpose; do not turn every README into an `App::File` tutorial. Update
`Changes` with the completed example migration and Perl 5.40 header cleanup.

## Verification

Add one focused integration test that inventories every example source using
`PAGI::App::File` and proves:

- no example uses `PAGI::App::File->new`;
- root-level dispatchers use `app_path('public')->to_app`;
- router consumers mount the returned component without `to_app`;
- the contact form retains an explicit writable upload path;
- every large-application Perl source uses `v5.40` without a redundant
  `use warnings` line.

The test also loads `endpoint-demo`, `sse-dashboard`, and `13-contact-form`
through their normal entry points and uses `PAGI::Test::Client` to request each
static index page. Existing `t/integration-endpoint-router-demo.t` continues
to prove the class-based example's runtime behavior and gains the
module-layout constructor source-shape assertion.

Run focused example and constructor tests during implementation. Run the full
repository suite once on the final reviewed tree.

## Scope Boundaries

- Do not convert unrelated examples to Perl 5.40 or signatures.
- Do not replace the contact form upload-directory path with `App::File`.
- Do not change routing, endpoint, SSE, upload, or lifespan behavior.
- Do not change the `PAGI::App::File` implementation or public API.
- Do not change dependency metadata.
- Preserve unrelated working-tree files.

## Rejected Alternatives

Leaving one manual `PAGI::App::File->new(root => ...)` example would weaken
the examples' role as canonical guidance now that the application-relative
constructor exists.

Expanding the pass into a general Perl 5.40/signature modernization would mix
an example API migration with unrelated style work. Only the already-modern
large application receives the redundant pragma cleanup.
