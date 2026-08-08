# Router Mount and Composed Reverse Routing Design

**Date:** 2026-08-08

**Status:** Approved design; awaiting written-spec review

## 1. Decision

Add an explicit routing-aware mount form:

```perl
mount('/person',
    router    => MyApp::Person->routing,
    namespace => 'person',
)
```

Unlike an opaque application mount, this form lets the containing
`PAGI::Routing::Router` inspect the child Router's named routes and build one
composed reverse-routing index. It remains a real Router boundary for request
dispatch: the child keeps its middleware, method handling, and generated
outcomes, and owns a request after its mount prefix matches.

The same work replaces dot-separated effective route names with slash-based
logical route addresses and adds relative route references to
`PAGI::Context->path_for` and `url_for`.

```perl
$c->path_for('show');
$c->path_for('../show');
$c->path_for('/person/blog/show');
```

This routing API has not been released. There is no compatibility alias or
deprecation layer for dotted names or the old positional reverse-routing
arguments. Tests, examples, and documentation change together.

Where this document conflicts with the names, namespaces, reverse-routing
signatures, or opaque-mount discussion in the 2026-08-03 declarative-routing
design, this document supersedes those sections. The existing route matching,
middleware, protocol, HEAD, and generated-response contracts otherwise remain
in force.

This specification solves only reverse routing across known Router mounts. It
does not solve cooperative no-match bubbling. The existing 404 and 405 design
will be reconsidered separately.

## 2. Motivation

`examples/15-large-application` currently assembles `MyApp::Root`,
`MyApp::Person`, and `MyApp::Person::Blogs` as separately compiled opaque
applications. That preserves modular dispatch, but each opaque mount hides its
child Router from the parent's resolver.

Consequently:

- Root cannot generate a Person URL by route name.
- Person cannot generate a Blogs URL by route name.
- Blogs cannot generate a Person or Root URL by route name.
- the example duplicates its four cross-component mount paths in
  `MyApp::URL`.

The child packages already have the information the parent needs: each can
return an immutable `PAGI::Routing::Router`. The missing operation is an
explicit mount that says, "this target is a Router and may participate in the
containing routing graph."

## 3. Goals

- Mount an actual `PAGI::Routing::Router` without flattening away its Router
  boundary.
- Make every named route in a composed Router graph addressable from request
  handlers in that graph.
- Keep logical route addresses independent from URL paths.
- Support absolute and relative logical route references.
- Let relative Context calls inherit useful matched path parameters.
- Fail early when composed path parameters or logical addresses collide.
- Keep Router descriptions immutable and reusable at more than one placement.
- Preserve child Router middleware, fallbacks, method decisions, and protocol
  behavior.
- Support named `params`, `query`, and `fragment` options consistently in
  `path_for` and `url_for`.
- Remove the `MyApp::URL` workaround from the large-application example.
- Document the difference among inline routes, Router mounts, and opaque
  application mounts prominently.

## 4. Non-goals

- Define a general reverse-routing provider protocol for arbitrary PAGI
  applications or other frameworks.
- Inspect a coderef, class name, or arbitrary `to_app` object to discover
  routes.
- Make opaque application mounts visible to the parent resolver.
- Add parameter-renaming maps such as `url_params` or `PathParamMap`.
- Permit duplicate path parameter names along one composed route.
- Add cooperative NONE/no-match bubbling through Router or application
  mounts.
- Change when a matched child Router owns a request.
- Redesign `not_found`, `method_not_allowed`, 404, or 405 behavior in this
  work.
- Build a route map during lifespan startup.
- Implement the deferred `PAGI::App` route-component base class.
- Add the proposed `pagi-server --module ... -e ...` loader.
- Add controller discovery, package-name routing, string method lookup, or
  other framework magic.
- Treat URL generation as authorization.

## 5. The three mount forms

`mount` has three explicit, mutually exclusive target forms.

### 5.1 Opaque application mount

```perl
mount('/static' => PAGI::App::File->new(root => $directory));
mount('/legacy' => 'MyApp::Legacy');
mount('/native' => $pagi_app);
```

The target is coerced through `PAGI::Utils::to_app`. Its implementation and
named routes remain opaque. After the prefix matches, the target owns the
request exactly as it does today.

Opaque application mounts accept `desc`, `constraints`, and `middleware` but
not `namespace`. A namespace on an unknowable child would imply reverse-route
visibility that does not exist, so the unreleased API rejects it instead of
silently ignoring it.

Passing a Router positionally is still deliberately opaque:

```perl
mount('/opaque' => $router);          # application contract
mount('/known', router => $router,    # routing-aware contract
    namespace => 'known');
```

The compiler does not guess intent from the target object's class.

### 5.2 Inline structural mount

```perl
mount('/api',
    routes => [
        route('/health' => \&health, name => 'health'),
    ],
    namespace => 'api',
)
```

`routes => [...]` remains a structural subtree of the containing Router. It
does not introduce an independently configured Router. The containing
Router's middleware and generated outcome handlers govern the subtree.
`namespace` remains optional for inline mounts.

### 5.3 Router mount

```perl
mount('/person',
    router     => MyApp::Person->routing,
    namespace  => 'person',
    middleware => [\&placement_middleware],
)
```

`router =>` accepts only a blessed object for which
`$object->isa('PAGI::Routing::Router')` is true. It does not accept a class
name, coderef, factory, route array, or arbitrary object with `to_app`.

`namespace` is required and nonempty for every Router mount. Requiring it:

- makes the placement addressable;
- prevents common `index` and `show` collisions;
- makes multiple placements of one Router unambiguous; and
- keeps the logical hierarchy visible at the composition point.

The allowed Router-mount options are `router`, `namespace`, `desc`,
`constraints`, and `middleware`.

### 5.4 Constructor validation

A mount must supply exactly one of:

1. a positional application target;
2. `routes => [...]`; or
3. `router => $router`.

Zero targets, multiple target forms, an invalid Router object, or a missing
Router namespace croak during construction with an error that names the
invalid form.

This deliberately replaces the current documented rule that `routes` must
immediately follow the path to select the inline form. The new parser uses the
argument-list parity to distinguish a positional target plus options from a
named option list, then requires exactly one named selector in the latter.
`routes` or `router` may appear anywhere in a well-formed named option list;
option order does not change the result.

A malformed positional or named option tail croaks `mount option list must be
key/value pairs`. The parser must detect that shape before constructing an
option hash; it must not report an `unknown mount option` whose alleged option
name is a stringified coderef or object.

`PAGI::Routing::Mount` adds a `router` accessor. Exactly one of `target`,
`routes`, or `router` is defined. Existing `is_raw` remains true only for the
opaque application form and false for both inspectable forms.

## 6. Router-boundary semantics

A Router mount is transparent only to structural inspection and reverse
routing. It is not flattened for dispatch.

After its path prefix matches:

- the child Router owns the request;
- its Router middleware runs;
- its own route scan decides FULL, PARTIAL, or NONE;
- its own `method_not_allowed` handler renders its generated 405;
- its own `not_found` handler renders its generated 404;
- the parent does not resume sibling scanning; and
- the parent does not union its own partial methods with the child's methods.

Middleware order is:

```text
outer Router middleware
  -> Router-mount middleware
    -> child Router middleware
      -> inline-mount middleware, route middleware, and handler
```

The first item in each middleware list remains outermost within that list.
Generated child 404 and 405 responses pass through child Router middleware,
Router-mount middleware, and outer Router middleware.

The existing idempotent `PAGI::Routing::HeadBoundary` remains the one final
wire boundary. Nested Router compilation must preserve its private scope
marker so all participating middleware observes the unsuppressed GET
representation before a HEAD body is removed.

WebSocket and SSE dispatch retain their existing Router semantics. A Router
mount does not adapt or reinterpret protocol events.

## 7. Logical route addresses

### 7.1 Address construction

Every route `name` and every mount `namespace` is one logical address segment.
Slash is the only hierarchy separator.

```perl
mount('/person', router => $people, namespace => 'person')
route('/{person_id}' => \&show, name => 'show')
```

Together they define the absolute logical address:

```text
/person/show
```

Names and namespaces:

- must be nonempty scalar strings;
- must not contain `/`; and
- must not equal `.` or `..`.

Dots have no structural meaning. A segment such as `v1.1` is one segment,
although simple identifier-like names are recommended.

The effective address of every named leaf must be unique in a composed Router
graph. Collisions croak while the containing Router builds its resolver and
name both conflicting effective URL patterns.

Routes that differ only by HTTP method still need distinct names if both are
named. Sharing one URL pattern does not make two leaves one logical target.

### 7.2 Address grammar

A route reference is split on `/`.

- `/person/blog/show` starts at the current resolver root.
- `show` starts at the current containing logical namespace.
- `blog/show` starts at the current containing logical namespace.
- `.` means the current logical namespace.
- `..` means its parent.
- `.` and `..` are legal at any segment position and are normalized from left
  to right, so `./show` and `blog/../show` are valid references.
- traversal above the resolver root croaks.
- empty interior segments, repeated slashes, and trailing slashes croak.
- Provided normalization stays within the resolver root, `/`, bare `.`, bare
  `..`, and any reference whose input ends in `.` or `..` name the resulting
  logical namespace rather than a route and therefore croak. For example,
  `../..` from `/person/blog` resolves to the root namespace but does not name
  a leaf. Bare `..` at the resolver root instead fails the above-root check.

Resolution is exact. It does not fall back to an ancestor, search sibling
namespaces, try a global spelling after a relative miss, or choose the nearest
partial match.

There is no overlap folding. From `/person/blog`, the relative reference
`person/show` means `/person/blog/person/show`, not `/person/show`; callers use
`../show` or the absolute `/person/show` spelling. Route references are logical
names, not URI paths, and are never percent-decoded. A segment containing the
literal characters `%2F` therefore does not introduce another separator.

### 7.3 The current containing namespace

For a named route, the current containing namespace is the route's absolute
logical address without its final segment.

For an unnamed route, including an explicit catchall, it is the logical
namespace contributed by the enclosing mounts. This lets a Blogs catchall use
`path_for('index')` even though the catchall itself has no name.

The compiler also establishes a current namespace while entering each Router
or inline mount. A custom generated 404 or 405 handler therefore resolves
relative names from the Router placement that owns the outcome, even though
there is no FULL named leaf. Its inheritance snapshot contains captures from
the Router and inline mount prefixes actually consumed before the generated
outcome; it does not choose an arbitrary PARTIAL leaf merely to inherit that
leaf's captures.

This namespace is derived from immutable compiled placement data and the
request's matched route metadata. It is not inferred from the request URL.

### 7.4 Logical addresses are not URL paths

Mount paths and logical namespaces remain independent:

```perl
mount('/internal/v3/people',
    router    => $people,
    namespace => 'person',
)
```

The logical address can be `/person/show` while the generated URL path is
`/internal/v3/people/{person_id}`. Moving a component does not require
renaming its local routes, and changing a namespace does not change request
matching.

## 8. Composed resolver behavior

The containing Router builds a placement-specific resolver by recursively
visiting:

- its direct routes;
- inline `routes => [...]` mounts; and
- `router => $router` mounts.

Local node validation happens when each child description is constructed.
Constructing the containing `router(...)` performs the complete recursive
placement traversal and therefore reports composed address collisions,
duplicate effective path parameters, and cycles before `to_app`. Compilation
resolves middleware and builds fresh request applications; it does not defer
route discovery to lifespan or first request.

Traversal stops at every positional opaque application mount, even when the
target happens to be a Router object.

A transparent Router mount participates in the containing resolver's one
request-local routing frame. It does not create a second independent resolver
root. This is what lets a Blogs handler resolve `/home` and `../show`.

An opaque application mount may still invoke a separately compiled Router
which creates a later `pagi.routing` frame. In that case Context reverse
routing uses the innermost compatible frame, and absolute `/...` references
stop at that frame's resolver root. Relative traversal never crosses an
opaque boundary.

The composed resolver records, for each placement:

- the effective URL pattern;
- the canonical absolute logical address, when named;
- the containing logical namespace;
- the route kind;
- the original immutable leaf;
- the mount chain and descriptions;
- the required path parameter names and constraints; and
- the placement needed to compile the child Router without mutating it.

`named_routes` is keyed by canonical absolute logical address:

```perl
my $routes = $root->named_routes;
my $leaf = $routes->{'/person/blog/show'};
```

`route_named` accepts a route reference from the Router's root namespace.
`Router->path_for` also resolves from the Router's root namespace because it
has no current request placement.

## 9. Reverse-routing API

The reverse-routing calls use named options only:

```perl
$router->path_for($reference,
    params   => \%path_params,
    query    => \%query_params,
    fragment => $fragment,
);

$c->path_for($reference,
    params   => \%path_params,
    query    => \%query_params,
    fragment => $fragment,
);

$c->url_for($reference,
    params   => \%path_params,
    query    => \%query_params,
    fragment => $fragment,
);
```

All options are optional. Unknown options, an odd option list, non-hash
`params` or `query`, or a reference-valued `fragment` fail with
operation-specific diagnostics.

The old positional forms are removed before release:

```perl
# Removed
$c->path_for('show', { id => 1 }, { page => 2 });

# Canonical
$c->path_for('show',
    params => { id => 1 },
    query  => { page => 2 },
);
```

`path_for` returns an application path reference and may include a query and
fragment. Context `path_for` also applies the selected routing frame's
`root_path` exactly once. Router `path_for` remains request-independent and
does not know any external mount placement.

`url_for` adds the request-aware scheme and authority through the existing
`PAGI::Authority` contract. HTTP and SSE targets use HTTP(S); WebSocket
targets use WS(S). Proxy interpretation remains middleware work.

Query keys are emitted in deterministic sorted order using the existing
UTF-8 percent-encoding rules. Query keys and values must be scalars; undef is
encoded as an empty value. Multiple values per key are not added in this work.

If `fragment` is present and defined, it must be a scalar and is UTF-8
percent-encoded as one URI component before `#` is appended. An empty scalar
produces a terminal `#`; undef omits the fragment. Fragments are never sent to
the server and never affect route lookup. Output order is always path, query,
then fragment.

## 10. Relative parameter inheritance

Only a relative Context reverse-routing call may inherit matched path
parameters.

For a relative reference, Context:

1. resolves the target logical address;
2. starts with the routing frame's current request-local capture snapshot,
   which contains complete effective leaf captures after FULL and only
   consumed mount-prefix captures for a generated outcome without FULL;
3. selects only keys required by the target pattern;
4. overlays explicit `params`, with explicit values winning;
5. rejects explicit keys not required by the target; and
6. renders and constraint-checks the complete target pattern.

Absolute Context references and all Router-object calls inherit nothing.
Query parameters and fragments never inherit.

```perl
# Current request: /person/42/blog/7
# Current logical route: /person/blog/show

$c->path_for('index');
# /person/42/blog/

$c->path_for('../show');
# /person/42

$c->path_for('show', params => { blog_id => 8 });
# /person/42/blog/8

$c->path_for('/person/blog/show');
# error: absolute references do not inherit person_id or blog_id
```

The capture snapshot is a fresh request-local hash and is not aliased to
`scope->{path_params}`. Middleware or application code that replaces or
mutates `path_params` after matching cannot silently change inherited URL
generation. `pagi.routing` remains public read-only metadata; directly
mutating its private working values is outside the contract.

Inheritance is convenience, not trust. A captured tenant, account, or user ID
does not prove the current principal may access the generated target. Handlers
must still perform authorization.

## 11. Reused path parameter names

Parameter names must be unique along each composed effective route pattern.

```perl
mount('/person/{id}',
    router => router(routes => [
        route('/blog/{id}' => \&show, name => 'show'),
    ]),
    namespace => 'person',
)
```

The example above croaks because the effective pattern contains two different
captures named `id`. The first release does not guess which value a caller
means and does not add a mapping option.

The canonical spelling is explicit at the route declarations:

```perl
mount('/person/{person_id}',
    router => router(routes => [
        route('/blog/{blog_id}' => \&show, name => 'show'),
    ]),
    namespace => 'person',
)
```

The check applies only along one ancestor-to-leaf pattern. Sibling routes may
use the same local parameter name. Constraint behavior remains validate-only;
URL generation never coerces a parameter.

The known prefix of a terminal opaque application mount is included in this
validation even though traversal stops at its target. Opacity hides the
target's internals, not parameter names declared by PAGI::Routing itself; an
opaque mount must not silently overwrite an ancestor capture before handing
the child its scope.

## 12. Router immutability, reuse, and cycles

A Router object describes local routes. It never stores its parent path,
absolute namespace, current match, or active placement.

The same object can therefore be mounted more than once:

```perl
my $people = MyApp::Person->routing;

my $root = router(routes => [
    mount('/authors', router => $people, namespace => 'authors'),
    mount('/editors', router => $people, namespace => 'editors'),
]);
```

The root resolver publishes `/authors/show` and `/editors/show`. A handler in
the shared child uses request-local matched placement, so relative `show`
stays under the active placement.

Calling `$people->path_for('show', params => {...})` outside a request returns
the child's local `/...` path and cannot include `/authors` or `/editors`.
Request handlers should use Context reverse routing when placement matters.

Every `to_app` call compiles a fresh application graph. Every placement of a
reused Router receives fresh Router, mount, and route middleware instances.
Runtime middleware state is not shared merely because the immutable Router
description is shared.

Ordinary immutable Router instances form a DAG by construction: a Router mount
can only receive an already constructed Router, so the public constructors
cannot create a true cycle. Because `router =>` accepts Router subclasses and
`routes` is a virtual method, recursive traversal still defensively tracks
active ancestor identities. A pathological subclass that returns a mount of
itself croaks with the logical and URL mount chain. Reusing the same Router in
separate sibling branches remains valid.

## 13. Request metadata

The existing version-1 `pagi.routing` container remains the metadata boundary.
This work adds placement information to its request-local frame and match
records rather than introducing another scope key.

The frame always tracks the current logical namespace and an unaliased capture
snapshot for Context reverse routing. A FULL leaf replaces them with that
leaf's containing namespace and complete effective captures. Entering an
inline or Router mount advances them to that placement, which also gives
generated child outcomes a deterministic relative base.

At minimum, a matched leaf record exposes:

```perl
{
    kind              => 'route',
    route             => '/person/{person_id}/blog/{blog_id}',
    name              => '/person/blog/show',
    logical_namespace => '/person/blog',
    desc              => $declared_desc,
}
```

`name` remains undef for an unnamed leaf, while `logical_namespace` remains
available. The request-local parameter snapshot used by Context is not added
as an advertised logging field; callers that need matched values already have
`path_params`.

The word `name` is intentionally relative at declaration time and absolute in
matched metadata: `PAGI::Routing::Route->name` returns the declared local
segment such as `show`, while the match record's `name` returns the composed
address such as `/person/blog/show`. The match record's
`logical_namespace` plus the declaration name explains that derivation.

Each Router mount appends its declared path, namespace, and description to the
frame's mount chain. Parent middleware can inspect the final child match after
awaiting downstream because the frame is shared only within that request.

No resolver, mount array, match hash, or capture snapshot may be shared across
concurrent requests.

## 14. Full modular application

The target application shape is:

```text
Project-MyApp/
├── app.pl
├── static/
│   └── app.css
└── lib/
    └── MyApp/
        ├── Data.pm
        ├── Root.pm
        ├── Person.pm
        ├── View.pm
        └── Person/
            └── Blogs.pm
```

`MyApp::URL` disappears. Named routing is the source of truth for links.

### 14.1 `app.pl`

```perl
use strict;
use warnings;
use File::Basename qw(dirname);
use lib dirname(__FILE__) . '/lib';
use MyApp::Root ();

MyApp::Root->to_app;
```

### 14.2 `MyApp::Root`

Root follows the same `routing` convention as its children. `routing` returns
the inspectable Router description; `to_app` adds the one application-root
Compose/lifespan boundary and compiles it.

```perl
package MyApp::Root;

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;
use PAGI::App::File;
use PAGI::Compose qw(compose);
use PAGI::Routing qw(router route mount);
use MyApp::Data;
use MyApp::Person ();
use MyApp::View ();

my $STATIC_ROOT = File::Spec->catdir(
    dirname(__FILE__), '..', '..', 'static',
);

sub startup {
    my ($state, $scope) = @_;
    $state->{data} = MyApp::Data->new;
    return;
}

sub shutdown {
    my ($state, $scope) = @_;
    delete $state->{data};
    return;
}

sub home {
    my ($c) = @_;
    my $people_path = $c->path_for('/person/index');
    my $count = scalar @{$c->state->{data}->people};

    return $c->html(MyApp::View->document(
        'My PAGI People',
        qq{    <h1>My PAGI People</h1>\n}
            . qq{    <p>This application contains $count people.</p>\n}
            . qq{    <p><a href="$people_path">Browse people</a></p>},
    ));
}

sub not_found {
    my ($c) = @_;
    return $c->html(
        MyApp::View->document(
            'Root page not found',
            "    <h1>Root page not found</h1>\n"
                . '    <p>No root route matched this path.</p>',
        ),
        status => 404,
    );
}

sub routing {
    my ($class) = @_;

    return router(
        routes => [
            route('/' => \&home,
                name => 'home',
                desc => 'HTML landing page',
            ),
            mount('/static' => PAGI::App::File->new(
                root => $STATIC_ROOT,
            )),
            mount('/person',
                router    => MyApp::Person->routing,
                namespace => 'person',
                desc      => 'People section',
            ),
            route('/*path' => \&not_found,
                desc => 'Final root catchall',
            ),
        ],
        desc => 'MyApp root routes',
    );
}

sub to_app {
    my ($class) = @_;

    return compose(
        app      => $class->routing,
        lifespan => {
            startup  => \&startup,
            shutdown => \&shutdown,
        },
    )->to_app;
}

1;
```

### 14.3 `MyApp::Person`

```perl
package MyApp::Person;

use strict;
use warnings;
use utf8;
use PAGI::Routing qw(router route mount);
use MyApp::Person::Blogs ();
use MyApp::View ();

sub list_people {
    my ($c) = @_;
    my @items;

    for my $person (@{$c->state->{data}->people}) {
        my $path = $c->path_for('show',
            params => { person_id => $person->{id} },
        );
        push @items,
            qq{      <li><a href="$path">$person->{name}</a></li>};
    }

    return $c->html(MyApp::View->document(
        'People',
        "    <h1>People</h1>\n    <ul>\n"
            . join("\n", @items)
            . "\n    </ul>",
    ));
}

sub show_person {
    my ($c) = @_;
    my $person_id = $c->path_param('person_id');
    my $person = $c->state->{data}->person($person_id);

    unless ($person) {
        my $people_path = $c->path_for('index');
        return $c->html(
            MyApp::View->document(
                'Person not found',
                qq{    <a href="$people_path">People</a>\n}
                    . '    <h1>Person not found</h1>',
            ),
            status => 404,
        );
    }

    # Relative resolution finds /person/blog/index and inherits person_id.
    my $blogs_path = $c->path_for('blog/index');
    my $home_path = $c->path_for('/home');

    return $c->html(MyApp::View->document(
        $person->{name},
        qq{    <a href="$home_path">Home</a>\n}
            . qq{    <h1>$person->{name}</h1>\n}
            . qq{    <p>$person->{summary}</p>\n}
            . qq{    <a href="$blogs_path">Read blogs</a>},
    ));
}

sub routing {
    my ($class) = @_;

    return router(
        routes => [
            route('/' => \&list_people,
                name => 'index',
                desc => 'List people',
            ),
            route('/{person_id}' => \&show_person,
                name        => 'show',
                desc        => 'Show one person',
                constraints => { person_id => qr/\d+/ },
            ),
            mount('/{person_id}/blog',
                router      => MyApp::Person::Blogs->routing,
                namespace   => 'blog',
                desc        => 'Blogs for one person',
                constraints => { person_id => qr/\d+/ },
            ),
        ],
        desc => 'Person routes',
    );
}

1;
```

### 14.4 `MyApp::Person::Blogs`

```perl
package MyApp::Person::Blogs;

use strict;
use warnings;
use PAGI::Routing qw(router route);
use MyApp::View ();

sub list_blogs {
    my ($c) = @_;
    my $person_id = $c->path_param('person_id');
    my $data = $c->state->{data};
    my $person = $data->person($person_id);

    unless ($person) {
        return $c->html(
            MyApp::View->document(
                'Blogs not found',
                '    <h1>Blogs not found</h1>',
            ),
            status => 404,
        );
    }

    my @items;
    for my $blog (@{$data->blogs_for($person_id)}) {
        # blog_id is explicit; person_id is inherited from the match.
        my $path = $c->path_for('show',
            params => { blog_id => $blog->{id} },
        );
        push @items,
            qq{      <li><a href="$path">$blog->{title}</a></li>};
    }

    # ../show resolves from /person/blog to /person/show and inherits person_id.
    my $person_path = $c->path_for('../show');

    return $c->html(MyApp::View->document(
        "Blogs by $person->{name}",
        qq{    <a href="$person_path">$person->{name}</a>\n}
            . "    <h1>Blogs</h1>\n    <ul>\n"
            . join("\n", @items)
            . "\n    </ul>",
    ));
}

sub show_blog {
    my ($c) = @_;
    my $person_id = $c->path_param('person_id');
    my $blog_id = $c->path_param('blog_id');
    my $blog = $c->state->{data}->blog($person_id, $blog_id);

    unless ($blog) {
        my $blogs_path = $c->path_for('index');
        return $c->html(
            MyApp::View->document(
                'Blog not found',
                qq{    <a href="$blogs_path">Blogs</a>\n}
                    . '    <h1>Blog not found</h1>',
            ),
            status => 404,
        );
    }

    my $home_path = $c->path_for('/home');
    my $person_path = $c->path_for('../show');
    my $blogs_path = $c->path_for('index');
    my $canonical = $c->url_for('show',
        query    => { view => 'full' },
        fragment => 'comments',
    );

    return $c->html(MyApp::View->document(
        $blog->{title},
        qq{    <a href="$home_path">Home</a> / }
            . qq{<a href="$person_path">Person</a> / }
            . qq{<a href="$blogs_path">Blogs</a>\n}
            . qq{    <article><h1>$blog->{title}</h1>}
            . qq{<p>$blog->{body}</p></article>\n}
            . qq{    <a href="$canonical">Comments view</a>},
    ));
}

sub blogs_not_found {
    my ($c) = @_;

    # The unnamed catchall still has /person/blog as its containing namespace.
    my $blogs_path = $c->path_for('index');
    return $c->html(
        MyApp::View->document(
            'Blogs section not found',
            qq{    <a href="$blogs_path">Blogs</a>\n}
                . '    <h1>Blogs section not found</h1>',
        ),
        status => 404,
    );
}

sub routing {
    my ($class) = @_;

    return router(
        routes => [
            route('/' => \&list_blogs,
                name => 'index',
                desc => 'List one person\'s blogs',
            ),
            route('/{blog_id}' => \&show_blog,
                name        => 'show',
                desc        => 'Show one blog',
                constraints => { blog_id => qr/\d+/ },
            ),
            route('/*path' => \&blogs_not_found,
                desc => 'Blogs-local catchall',
            ),
        ],
        desc => 'Blog routes',
    );
}

1;
```

`MyApp::Data` and `MyApp::View` remain the fixture store and HTML document
helper already used by the example. They require no routing-specific API.

### 14.5 Resulting address map

```text
Logical address              URL pattern
---------------------------  ---------------------------------------------
/home                        /
/person/index                /person/
/person/show                 /person/{person_id}
/person/blog/index           /person/{person_id}/blog/
/person/blog/show            /person/{person_id}/blog/{blog_id}
```

For a request matched at `/person/42/blog/7`:

```perl
$c->path_for('show');
# /person/42/blog/7

$c->path_for('show', params => { blog_id => 8 });
# /person/42/blog/8

$c->path_for('index');
# /person/42/blog/

$c->path_for('../show');
# /person/42

$c->path_for('/home');
# /

$c->path_for('../../home');
# /

$c->path_for('../../../home');
# error: route reference traverses above the resolver root

$c->path_for('/person/blog/show');
# error: absolute references do not inherit person_id or blog_id

$c->path_for('/person/blog/show',
    params => { person_id => 9, blog_id => 3 },
);
# /person/9/blog/3

$c->url_for('show',
    query    => { view => 'full' },
    fragment => 'comments',
);
# https://example.test/person/42/blog/7?view=full#comments
```

## 15. Documentation requirements

The implementation updates all routing POD and examples rather than leaving
the new behavior discoverable only from tests.

### 15.1 `PAGI::Routing` POD

Add:

- the three-form mount table;
- an explicit positional-Router-versus-`router =>` example;
- Router-mount namespace requirements;
- slash logical address grammar;
- relative resolution examples;
- parameter inheritance and its authorization warning;
- duplicate composed parameter diagnostics;
- Router reuse and placement behavior;
- query/fragment examples; and
- the Router boundary/no-bubbling rule.

Replace every dotted effective-name example and every positional
`path_for`/`url_for` example.

### 15.2 Class POD

Update:

- `PAGI::Routing::Mount` with the new form, accessor, validation, and dispatch
  boundary;
- `PAGI::Routing::Router` with composed inspection and local-versus-mounted
  path generation;
- `PAGI::Routing::Resolver` with slash addresses, recursive Router traversal,
  and relative resolution;
- `PAGI::Context` with current namespace, inheritance, absolute behavior,
  query, fragment, and failure cases; and
- routing metadata documentation with `name` and `logical_namespace`.

Each reverse helper states that it performs no protocol I/O. It reads compiled
metadata and returns a string or croaks; it does not send a redirect or mutate
a response.

### 15.3 Large-application example

Revise `examples/15-large-application` to match section 14:

- remove `MyApp::URL`;
- add `routing` methods;
- make Root's `to_app` compose `app => $class->routing` with lifespan;
- use `router =>` mounts for Person and Blogs;
- use named links across all three packages;
- retain the opaque static-file mount;
- retain the explicit Blogs catchall; and
- explain that Root's catchall still cannot catch a child Router's generated
  NONE result.

Update the example-local `examples/15-large-application/GAPS.md` as follows:

- replace GAP-01's dotted `blogs.index` placement example with the composed
  slash address `/person/blog/index`, mark the known-Router case resolved, and
  distinguish remaining opaque application mounts;
- retain GAP-02 as the open cooperative no-match-bubbling problem; and
- revise GAP-03 to point to the separate
  `2026-08-06-pagi-app-base-design.md`, which records the approved but deferred
  base-class design. GAP-03 currently calls the repeated shell an observation,
  not a proposal, so the update must not claim that `GAPS.md` already carried
  the deferral.

### 15.4 Integration documentation and testing

The example README keeps the real current launch command and labels the
Plack-like `pagi-server --module ... -e ...` spelling as deferred.

The repo-root `t/integration-large-application.t` must continue to use
`PAGI::Test::Client->run` with lifespan enabled. Today it issues hardcoded
requests, regex-matches hardcoded `href` values in returned pages, and tests
the `MyApp::URL` literals separately; it does not extract and follow a rendered
link. The revised test must follow those links. This is a deliberate
strengthening: it proves that the generated target and the assembled mount
agree without duplicating the expected path in the test, across
Root-to-Person, Person-to-Blogs, Blogs-to-Person, and Blogs-to-Root navigation.

## 16. Required errors

Diagnostics must identify enough context to fix the declaration. Required
failure classes include:

- mount has zero or multiple target forms;
- mount has a malformed positional or named key/value tail;
- a Router object appears directly inside structural `routes`, in which case
  the diagnostic recommends
  `mount('/prefix', router => $router, namespace => '...')` rather than the
  old positional opaque form;
- opaque application mount supplies `namespace`;
- `router` target is not a `PAGI::Routing::Router`;
- Router mount lacks a namespace;
- name or namespace contains `/` or is `.`/`..`;
- duplicate absolute logical address, with both effective URL patterns;
- duplicate path parameter along an effective composed pattern;
- defensive Router-cycle detection for a subclass-supplied recursive route
  graph, with mount/address ancestry;
- malformed route reference;
- traversal above resolver root;
- unknown exact logical address;
- relative Context reference without a compatible routing frame and current
  logical namespace;
- missing required target parameter;
- explicit extra target parameter;
- constraint failure naming the target and parameter;
- malformed `params` or `query`;
- unknown reverse-routing option; and
- reference-valued fragment.

No failure silently falls back to another namespace or opaque ancestor.

## 17. Test requirements

### 17.1 Construction and introspection

- All three mount forms construct and expose only their applicable target
  accessor.
- Every invalid combination of positional target, `routes`, and `router`
  fails.
- Named `routes` and `router` selectors work in any option order, and malformed
  positional or named tails produce the documented key/value diagnostic.
- A Router object placed directly in structural `routes` is rejected with
  guidance to use the named `router =>` mount form.
- Opaque application mounts reject `namespace` rather than implying hidden
  route visibility.
- Router targets require a `PAGI::Routing::Router` instance (or subclass) and
  a namespace.
- Route names and namespaces enforce the segment grammar.
- `named_routes` and `route_named` expose canonical slash addresses.
- Returned arrays and hashes remain defensive copies and source leaf identity
  is preserved.

### 17.2 Composition validation

- Nested inline and Router mounts produce the expected address/path table.
- Duplicate addresses report both placements.
- Duplicate parameters fail only when repeated along the same effective path.
- Duplicate parameters on a known opaque-mount prefix also fail before the
  target can receive an overwritten capture.
- An opaque mount hides all inner names.
- A positional Router target remains opaque.
- A local test subclass whose `routes` method returns a Router mount of the
  same object exercises the defensive cycle guard; mounting one ordinary
  Router in two sibling placements succeeds.

### 17.3 Dispatch ownership

- Prefix-matching Router mounts terminate parent scanning.
- Child FULL, PARTIAL, and NONE decisions use child behavior.
- Child and parent method sets are not unioned.
- Child custom 404/405 handlers remain child-owned.
- A response explicitly returned by a handler, including a 404, passes through
  unchanged.
- Router-mount, child Router, inline, and route middleware execute in the
  documented order.
- HEAD suppression remains outermost and preserves body-derived headers.
- WebSocket and SSE mounts retain existing denial/decline behavior.

### 17.4 Reverse resolution

- Absolute, bare, child, and interior `.`/`..` references resolve exactly,
  including `./show` and `blog/../show`.
- Above-root, unknown, repeated-slash, empty-segment, and trailing-slash
  references fail.
- `/`, bare `.`, bare `..`, and references ending at a namespace after
  `.`/`..` normalization fail because they do not name a route leaf.
- Unnamed catchalls retain their containing namespace.
- Custom generated 404/405 handlers resolve from their owning Router
  namespace without borrowing captures from an arbitrary PARTIAL leaf.
- Router-object generation is local and request-independent.
- Context generation includes `root_path` exactly once.
- HTTP/SSE and WebSocket schemes remain correct.
- Query and fragment values are deterministically encoded.
- The removed positional reverse API fails clearly.

### 17.5 Parameter inheritance

- Relative Context calls inherit only target-required captures.
- Explicit params override inherited values.
- Absolute and Router calls inherit nothing.
- Query and fragment values never inherit.
- Missing and extra params fail.
- Mutating `scope->{path_params}` after matching does not alter the recorded
  capture snapshot.
- Two concurrent requests through one compiled app do not share captures,
  match metadata, or current namespace.

### 17.6 Reuse and compilation

- The same child Router mounted twice resolves relative links through the
  active placement.
- Each placement receives independently compiled middleware instances.
- Two outer `to_app` calls produce independent graphs.
- Child Router descriptions remain unchanged after composition and requests.

### 17.7 Example integration

Using `PAGI::Test::Client` with lifespan:

- `/` links to `/person/`;
- `/person/` links to each Person detail;
- Person detail links to that person's Blogs index;
- Blogs index links back to Person and to each Blog detail;
- Blog detail links to Root, Person, Blogs, and its query/fragment URL;
- the Blogs explicit catchall remains local;
- Root's catchall handles paths outside matched mounts;
- a child NONE still demonstrates the deferred no-match-bubbling gap; and
- startup data exists during requests and is removed at shutdown.

## 18. Adversarial review

### 18.1 Is `mount` overloaded beyond recognition?

No. All three forms answer the same question: what owns requests below this
prefix? Their selectors are mutually exclusive, construction-time values.
The docs must show them together because a positional Router and `router =>`
look similar while intentionally choosing different contracts.

### 18.2 Can a complex application silently collide namespaces?

Not within the visible Router graph. Every Router mount requires a namespace,
all effective logical addresses must be unique, and errors identify both
placements. Opaque application mounts remain unknowable; pretending otherwise
would reintroduce the original ambiguity under a false guarantee.

### 18.3 Does a required namespace prevent useful reuse?

It enables it. The same child can appear as `authors` and `editors` without
mutating the child. An unnamed Router placement would make `index`, `show`, and
relative ancestry depend on surrounding declarations and is therefore
rejected.

### 18.4 Does relative lookup become fuzzy magic?

No. It uses filesystem-like syntax, one known current namespace, and exact
normalization. A failed relative target fails. It never searches ancestors or
tries an absolute name as a fallback.

### 18.5 Can repeated parameter names be mapped automatically?

They could, but the mapping policy would complicate matching, metadata,
inheritance, reverse generation, and third-party adoption. The first version
fails and asks the application to choose unambiguous names such as
`person_id` and `blog_id`. A pure middleware mapping helper can be evaluated
later if real external Router integrations justify it.

### 18.6 Can inherited IDs create a security vulnerability?

Inheritance can make an unsafe link convenient, but it cannot grant access by
itself. Documentation explicitly separates URL construction from
authorization. Values are still encoded and constraint-checked; handlers must
authorize the target resource normally.

### 18.7 Can middleware mutate `path_params` and redirect links?

Not accidentally. Context inherits from a separate request-local match
snapshot. Explicitly mutating internal `pagi.routing` metadata is a jailbreak
outside the supported contract and is documented as such.

### 18.8 Does Router reuse leak the first placement?

No placement is stored on the Router. The outer resolver creates placement
records, and the request frame selects the active one. Tests cover sibling
reuse, concurrent requests, and fresh middleware compilation.

### 18.9 What if a Router contains itself?

The normal constructors cannot create that graph because every Router target
already exists before its parent. The resolver nevertheless tracks active
ancestor identities to defend against a Router subclass whose `routes` method
fabricates a self-mount. The cycle test uses that explicit subclass pathology.
Identity seen in a completed sibling branch is not a cycle, so legitimate
reuse works.

### 18.10 What happens at an opaque child inside a known Router?

Discovery stops. Routes before and beside the opaque mount remain known;
routes inside it do not. Relative and absolute lookup cannot cross that
boundary. This limitation is honest and keeps the contract narrow enough for
the first implementation.

### 18.11 Does `router =>` accidentally change 404/405 semantics?

No. It intentionally preserves child ownership after a prefix match. That
means the large application's Root catchall still does not see a Person
Router's NONE result. This is visible in the example and remains separate work
rather than being smuggled into reverse routing.

### 18.12 Why not build the route map during lifespan?

The route graph is immutable configuration known before requests. Building it
when the containing Router is constructed gives deterministic early errors and
keeps `Router->path_for` and inspection usable without starting an
application.
Lifespan remains for runtime resources such as the example's data store.

### 18.13 Do named options add unnecessary boilerplate?

They make the expanded API legible and remove positional ambiguity among path
params, query params, and fragments. Typical inherited relative calls remain
short: `$c->path_for('index')`. Explicit values become self-documenting where
they matter.

### 18.14 Does `routing` duplicate `to_app` package boilerplate?

Only the application root needs both in this example. Child packages expose
Router descriptions through `routing`; Root exposes the same inspection hook
and adds Compose/lifespan in `to_app`. The deferred `PAGI::App` design may
later reduce this shell, but it must adapt to this routing contract rather than
shape it prematurely.

### 18.15 Can a child Router generate its mounted absolute path by itself?

No, because one Router may have many placements. A child Router object returns
local paths. Context has the active placement and is the canonical API inside
handlers. This distinction must be prominent in Router POD.

### 18.16 Why do absolute Context references not inherit captures?

An absolute reference expresses a deliberate jump to a graph-wide target.
Requiring its parameters makes that jump self-contained and prevents a
same-named capture in the current branch from silently changing the target.
Relative spelling is the explicit signal that current route context should be
reused.

## 19. Repository-wide migration

Because the declarative routing API is unreleased, implementation changes the
repository in one coherent pass:

- effective route names become canonical slash addresses;
- dotted namespace joins are removed;
- opaque mounts no longer accept ignored namespaces;
- `routes` no longer has to immediately follow the mount path; named mount
  selector options are order-independent;
- the structural-routes Router diagnostic recommends `router =>` rather than
  positional opaque mounting;
- reverse-routing calls use named options;
- all routing unit and integration tests are updated;
- all POD examples are updated;
- all examples are updated;
- the large application removes `MyApp::URL`; and
- no compatibility code, warnings, aliases, or dual lookup index is added.

Legacy `PAGI::App::Router->uri_for` and
`PAGI::Endpoint::Router->uri_for` are separate APIs and do not change as part
of this work.

## 20. Deferred work

After this feature is implemented and the large application is cleanly using
it, revisit these independently:

1. cooperative no-match bubbling and the broader 404/405 model;
2. whether an external reverse-routing provider contract has demonstrated
   consumers;
3. an optional path-parameter mapping middleware for external components;
4. the deferred `PAGI::App` route-component base class;
5. route-walking/introspection APIs driven by a real consumer; and
6. `pagi-server --lib`, `--module`, and `-e` loading.

None is a prerequisite for the Router-mount and composed reverse-routing
contract in this specification.
