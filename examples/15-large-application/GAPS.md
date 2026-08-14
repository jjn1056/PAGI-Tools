# Gaps Exposed by the Modular Application

This ledger separates behavior now supported for known Router mounts from
work that remains deferred for opaque applications or routing outcomes.

## GAP-01: Known-Router reverse discovery is resolved; opaque apps remain terminal

**Desired behavior:** A parent assigns each known Router placement a stable
name, and application code addresses named leaves below that placement.
For example, the Blogs index has the composed logical address
`/person/blog/index`. Placement names, not package names, identify the
route because one Router may be reused at multiple placements.

**Shipped behavior:** The explicit
`mount('/prefix', router => $router, name => '...')` form is inspected by
the containing resolver. Root therefore discovers the complete five-address
graph and Context can reverse between Root, Person, and Blogs from the active
request namespace. A positional application mount remains opaque: traversal
stops at its known prefix even when its target happens to compile a Router.

**Evidence:** Root links to `/person/index`; Person links relatively to
`blog/index`; Blogs links relatively to `../show` and absolutely to `/home`.
The integration test extracts and follows those rendered links. The static
file application remains positional and opaque, and its 404 stays locally
owned.

**Current workaround:** None is needed across the known Person and Blogs
Router mounts. Links into named routes hidden below an opaque application
still require an application-specific external contract or a routing-aware
mount instead.

**Follow-on status:** Resolved for known Router mounts. Discovery below opaque
application mounts remains intentionally unsupported; a generalized external
reverse-routing provider is deferred until it has demonstrated consumers.

## GAP-02: Trusted child declines are resolved; sibling resumption remains deferred

**Shipped behavior:** A selected routing-aware child can complete without
sending when it publishes trusted NONE or PARTIAL evidence. That evidence
reaches the enclosing routing fallback middleware or Compose boundary, which
renders the application's 404 or 405. Arbitrary silent native applications do
not acquire this control-flow meaning.

**Ownership boundary:** Selecting the Person or Blogs Mount still transfers
ownership to that child. The parent does not resume declaration-order sibling
scanning after child NONE, and it does not union a selected child's PARTIAL
methods with discarded parent candidates. Root's ordinary catchall is a real
route, not an enclosing fallback, so it does not handle paths already owned by
Person or Blogs.

**Evidence:** `GET /person/not-an-integer` and
`GET /person/1/unmatched` publish trusted child NONE evidence and receive the
root Compose automatic `Not Found` response rather than Root's branded
catchall. An unknown numeric blog remains a handler-owned 404, while a deeper
Blogs path remains owned by Blogs' explicit catchall. A wrong method under the
selected Blogs child reaches Compose's automatic 405 with exactly
`Allow: GET, HEAD`. The integration test exercises each of these boundaries.

**Current workaround:** None is needed for trusted child NONE/PARTIAL evidence
or application-level 404/405 rendering. An application that wants sibling
resumption must express that ownership explicitly rather than relying on an
emitted 404 or arbitrary silent completion as control flow.

**Follow-on status:** Resolved for trusted decline propagation and enclosing
fallback policy. Resuming parent sibling scans and combining method evidence
across the selected Mount boundary remain intentionally unsupported.

## GAP-03: Optional route-component base class is separately deferred

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

## Deferred server loader

The desired command shape is:

```text
pagi-server --lib /Project-MyApp/lib --module MyApp::Root \
    -e 'MyApp::Root->to_app'
```

That syntax is not currently shipped. It belongs to PAGI::Server loader work,
not to the PAGI::Tools composition gaps above. This example uses `app.pl`.
