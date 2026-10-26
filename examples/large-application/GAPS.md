# Gaps Exposed by the Modular Application

This ledger retains only work that the example still leaves deferred. Known
Router reverse discovery, Router-owned 404/405 outcomes, custom
`http_default` presentation, and selected-Mount ownership are shipped and are
therefore no longer listed as gaps.

Normal HTTP route handlers now receive `PAGI::Request`, while reverse routing
is an explicit `PAGI::Routing::URL` capability and lifespan data uses strict
`PAGI::State`. The example no longer needs a broad Context merely to combine
those independent owners, so that migration is also no longer a gap.

## Optional route-component base class

Person and Blogs still repeat a small package shell around `routing()`, while
Root separately owns the application Compose and lifespan boundary. This file
records the repetition as evidence; it did not propose or approve a base
class.

A separate approved design (kept with the project's local design documents,
not in this distribution) defines an optional route-component base class. Its implementation remains deferred and must be
rechecked against the completed Router-mount contract before planning. The
application-local `MyApp::View` helper already removes unrelated HTML
document-shell duplication.

## Server module loader

Resolved by `PAGI::App::Compose`: `MyApp::Root` is the application, and the
module is served directly,

```text
pagi-server -I examples/large-application/lib \
    --app examples/large-application/lib/MyApp/Root.pm
```

with no `app.pl` to locate `lib`. A `--module`/`-e` loader is not shipped and
this example no longer needs one.
