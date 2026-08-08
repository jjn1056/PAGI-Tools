# Gaps Exposed by the Modular Application

This ledger separates behavior now supported for known Router mounts from
work that remains deferred for opaque applications or routing outcomes.

## GAP-01: Known-Router reverse discovery is resolved; opaque apps remain terminal

**Desired behavior:** A parent assigns each known Router placement a stable
namespace, and application code addresses named leaves below that placement.
For example, the Blogs index has the composed logical address
`/person/blog/index`. Placement namespaces, not package names, identify the
route because one Router may be reused at multiple placements.

**Shipped behavior:** The explicit
`mount('/prefix', router => $router, namespace => '...')` form is inspected by
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

## GAP-02: Cooperative no-match bubbling through component mounts

**Desired behavior:** When a routing-aware mounted component has a genuine
NONE result, it declines without sending and its parent resumes
declaration-order scanning. A child FULL match, PARTIAL method match, explicit
catchall, or emitted response remains final. Arbitrary native PAGI
applications remain terminal unless they explicitly adopt a future
cooperative contract.

**Shipped behavior:** Once a Router-mount prefix matches, the child owns FULL,
PARTIAL, and NONE. A child NONE sends that Router's generated or custom 404;
the parent does not resume scanning or union allowed methods.

**Evidence:** `GET /person/1/unmatched` returns the Person Router's plain
`Not Found` response instead of reaching Root's branded catchall. In contrast,
an unknown numeric blog is handled by `show_blog`, and a deeper Blogs path is
handled by Blogs' explicit catchall; both correctly remain local. A wrong
method remains a child 405 with `Allow: GET, HEAD`.

**Current workaround:** None. The example records shipped behavior rather than
buffering events or treating an emitted 404 as control flow.

**Follow-on status:** Unsolved and deferred. Cooperative no-match bubbling and
the broader 404/405 model require a separate routing-component decline design.

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
