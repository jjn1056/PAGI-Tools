# Gaps Exposed by the Modular Application

This example intentionally uses only APIs currently shipped by PAGI::Tools.
The entries below separate desired application behavior from current behavior
and from the workaround used by the example.

## GAP-01: Reverse routing across opaque component mounts

**Desired behavior:** A parent can assign a stable name to an opaque component
placement, and application code can address named routes below that placement.
For example, a Blogs mount named `blogs` could expose `blogs.index`. The
placement name, not the package name, identifies the URL because one component
may be mounted more than once.

**Shipped behavior:** An opaque application mount has no route name and hides
the mounted router's named leaves from the parent resolver.
`PAGI::Context->path_for` and `url_for` use the innermost compatible routing
frame, so Person cannot reverse a Blogs route and Blogs cannot reverse a Person
route.

**Evidence:** Person list links to Person detail and Blogs list links to Blog
detail with local `$c->path_for`. Root-to-Person, Person-to-Blogs, and
Blogs-to-Person links cannot use those local resolvers.

**Current workaround:** `MyApp::URL` owns the cross-component paths. This
keeps literal mount paths out of handlers but duplicates the mount structure in
application code.

**Follow-on status:** Requires a separate core design. This example does not
define the metadata or lookup protocol.

## GAP-02: Cooperative no-match bubbling through component mounts

**Desired behavior:** When a routing-aware mounted component has a genuine
NONE result, it declines without sending and its parent resumes
declaration-order scanning. A child FULL match, PARTIAL method match, explicit
catchall, or emitted response remains final. Arbitrary native PAGI
applications remain terminal unless they explicitly adopt a future cooperative
contract.

**Shipped behavior:** Once an opaque application mount prefix matches, that
mount owns the request. If the mounted router has no matching route, it sends
its generated 404 before the parent can resume.

**Evidence:** `GET /person/1/unmatched` returns the Person router's plain
`Not Found` response instead of reaching Root's explicit branded catchall.
In contrast, an unknown numeric blog is handled by `show_blog`, and a deeper
Blogs path is handled by Blogs' explicit catchall; both correctly remain local.
A wrong method remains a child 405 with `Allow: GET, HEAD`.

**Current workaround:** None. The example records shipped behavior rather than
buffering events or treating an emitted 404 as control flow.

**Follow-on status:** Requires a separate routing-component decline design.

## GAP-03: Repeated component shell

Person and Blogs repeat a short set of imports plus a method that passes their
route array through `router` and then `to_app`. The repetition is visible, but two
small components do not justify a base class, role, or new core constructor.
This remains an observation rather than a proposed PAGI::Tools feature.

The application-local `MyApp::View` helper already removes unrelated HTML
document-shell duplication, so this observation is specifically about
component construction.

If larger applications reveal repeated lifecycle, middleware, configuration,
or inspection contracts in addition to this small wrapper, a higher-order
framework built on PAGI::Tools may be the right place to address them.

## Deferred server loader

The desired command shape is:

```text
pagi-server --lib /Project-MyApp/lib --module MyApp::Root \
    -e 'MyApp::Root->to_app'
```

That syntax is not currently shipped. It belongs to PAGI::Server loader work,
not to the PAGI::Tools composition gaps above. This example uses `app.pl`.
