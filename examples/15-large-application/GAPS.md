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

The separate approved design at
`docs/superpowers/specs/2026-08-06-pagi-app-base-design.md` defines an optional
route-component base class. Its implementation remains deferred and must be
rechecked against the completed Router-mount contract before planning. The
application-local `MyApp::View` helper already removes unrelated HTML
document-shell duplication.

## Server module-and-expression loader

The desired command shape is:

```text
pagi-server --lib /Project-MyApp/lib --module MyApp::Root \
    -e 'MyApp::Root->to_app'
```

That syntax is not currently shipped. It belongs to PAGI::Server loader work,
not to the PAGI::Tools composition gaps above. This example uses `app.pl`.
