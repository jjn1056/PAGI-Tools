# Large Application Diagnostic Example Design

**Date:** 2026-08-06
**Status:** Approved for implementation planning

## 1. Purpose

Add a small but structurally realistic HTML application under `examples/` to
evaluate how PAGI::Tools feels when an application is divided into independently
compiled package components.

The example is diagnostic. It must use only APIs that ship today, document the
workarounds those APIs require, and turn observed friction into an evidence-based
gaps list. It must not change PAGI::Routing, PAGI::Compose, mount semantics, or
the server loader in this work package.

The intended future entry point resembles:

```text
pagi-server --lib /Project-MyApp/lib --module MyApp::Root \
    -e 'MyApp::Root->to_app'
```

`pagi-server` does not yet support that interface. The example therefore ships
a minimal `app.pl` loader while keeping all application behavior under `lib/`.

## 2. Goals

- Make `MyApp::Root->to_app` the only application entry point.
- Give Root, Person, and Blogs explicit package and URL ownership.
- Mount Person and Blogs as opaque PAGI application components rather than
  exposing their route arrays to their parents.
- Use PAGI::Compose lifespan startup to initialize shared application data.
- Render HTML pages with working links so reverse-routing boundaries are visible.
- Demonstrate local handler 404s, a nested catchall, a root catchall, and a
  child-owned 405.
- Maintain a concise gaps document that separates shipped behavior, desired
  behavior, workarounds, and future design work.
- Verify the application through the PAGI-Tools `PAGI::Test::Client`.

## 3. Non-goals

- Implement `pagi-server --lib`, `--module`, or `-e`.
- Change declarative router matching or opaque mount ownership.
- Implement cross-component reverse routing.
- Implement no-match bubbling.
- Add a component base class, role, higher-order framework, or new middleware.
- Add a template engine, persistence layer, mutable data API, WebSocket, or SSE.
- Treat an emitted HTTP 404 as routing control flow.

## 4. Chosen application model

Each route-owning package is a complete PAGI component with a class-level
`to_app` method. A parent mounts a child by class name:

```perl
mount('/person' => 'MyApp::Person');
mount('/{person_id}/blog' => 'MyApp::Person::Blogs');
```

PAGI::Utils resolves the class and invokes `to_app` during application
compilation. The parent knows the child's mount placement but not the child's
route tree.

Root is the only Compose boundary because it owns application lifespan. Person
and Blogs use `router(...)->to_app` directly. No local base class hides the
resulting component-shell boilerplate; the finished example will show whether
that repetition is substantial enough to justify later work.

## 5. Files and package responsibilities

```text
examples/15-large-application/
├── app.pl
├── README.md
├── GAPS.md
├── static/
│   └── app.css
└── lib/
    └── MyApp/
        ├── Data.pm
        ├── Root.pm
        ├── URL.pm
        ├── Person.pm
        └── Person/
            └── Blogs.pm
```

### 5.1 `app.pl`

The loader contains only normal strictness, the example-local library path,
the Root load, and the final application expression:

```perl
use strict;
use warnings;
use File::Basename qw(dirname);
use lib dirname(__FILE__) . '/lib';
use MyApp::Root ();

MyApp::Root->to_app;
```

### 5.2 `MyApp::Root`

Root owns:

- the application Compose boundary;
- lifespan startup and shutdown;
- `/`;
- the `/static` application mount;
- the `/person` application mount; and
- the final root `/*path` route.

Its structural shape is:

```perl
sub to_app {
    return compose(
        routes => [
            route('/' => \&home, name => 'home'),
            mount('/static' => _static_app()),
            mount('/person' => 'MyApp::Person'),
            route('/*path' => \&not_found),
        ],
        lifespan => {
            startup  => \&startup,
            shutdown => \&shutdown,
        },
    )->to_app;
}
```

The root catchall is an ordinary final route, not the router's generated
`not_found` callback. This distinction is necessary for the future bubbling
model: an unmatched child should eventually allow its parent to continue
scanning and select that route.

`_static_app()` builds a PAGI::App::File rooted at the example's `static/`
directory. The static mount remains an ordinary opaque native application.

### 5.3 `MyApp::Person`

Person owns `/person` relative routes:

```perl
sub to_app {
    return router(
        routes => [
            route('/' => \&list_people, name => 'index'),
            route('/{person_id}' => \&show_person,
                name        => 'show',
                constraints => { person_id => qr/\d+/ },
            ),
            mount('/{person_id}/blog' => 'MyApp::Person::Blogs',
                constraints => { person_id => qr/\d+/ },
            ),
        ],
    )->to_app;
}
```

Person intentionally has no final catchall. An unknown numeric person ID is a
FULL route match whose handler returns a Person-specific HTML 404. A path that
matches no Person declaration exposes today's opaque-mount ownership behavior.

### 5.4 `MyApp::Person::Blogs`

Blogs owns routes relative to `/person/{person_id}/blog`:

```perl
sub to_app {
    return router(
        routes => [
            route('/' => \&list_blogs, name => 'index'),
            route('/{blog_id}' => \&show_blog,
                name        => 'show',
                constraints => { blog_id => qr/\d+/ },
            ),
            route('/*path' => \&blogs_not_found),
        ],
    )->to_app;
}
```

The two Blogs 404 cases are deliberately different:

- an unknown numeric `blog_id` fully matches `show_blog`, which returns a
  Blogs-specific 404 response; and
- a deeper or otherwise unmatched path selects Blogs' explicit catchall.

Neither case may bubble. Both are handled outcomes.

### 5.5 `MyApp::Data`

Data is a small read-only repository object over mock people and blog fixtures.
It exposes:

```perl
$data->people;
$data->person($person_id);
$data->blogs_for($person_id);
$data->blog($person_id, $blog_id);
```

Fixture records contain only scalar values. Query methods return fresh
array/hash structures so a handler cannot mutate application-wide fixtures by
accident. Missing records return `undef`; an empty person's blog list returns
an empty arrayref.

### 5.6 `MyApp::URL`

URL is the application-owned workaround for cross-component links. It exposes
class methods:

```perl
MyApp::URL->people;
MyApp::URL->person($person_id);
MyApp::URL->blogs($person_id);
MyApp::URL->blog($person_id, $blog_id);
```

ID inputs must be defined decimal strings. Invalid values fail synchronously
rather than being interpolated into paths. This module intentionally duplicates
the application's mount structure; `GAPS.md` identifies that duplication as
evidence for cross-component reverse routing.

## 6. URL tree

```text
/                                           Root home
/person                                     Person list
/person/{person_id}                         Person detail
/person/{person_id}/blog                    Blog list
/person/{person_id}/blog/{blog_id}          Blog detail
/static/app.css                             Static stylesheet
/*path                                      Root catchall
```

GET is the default HTTP method, including the router's automatic HEAD support.
All person and blog path parameters use anchored numeric constraints.

## 7. Lifespan and shared state

Root's startup callback creates one `MyApp::Data` object and stores it in the
server-owned state hash:

```perl
$state->{data} = MyApp::Data->new;
```

Shutdown removes that entry. Root, Person, and Blogs retrieve the repository
through `$c->state->{data}`. Opaque mount rewriting preserves the shared state
reference, so no component constructor arguments or package globals are
needed.

The application requires server state support. PAGI::Compose already reports
`lifespan.startup.failed` when configured lifespan callbacks are run without a
valid server-provided state hash; the example adds no alternate state model.

Mounted child packages are independently compilable components, but their
request handlers depend on the Root-provided `state->{data}` service contract.

## 8. HTML and link generation

Pages are deliberately small server-rendered HTML documents with a shared
stylesheet. No external template dependency is introduced. Fixture values are
application-controlled; handlers do not echo unmatched wildcard input into
HTML.

Links demonstrate both the working local mechanism and the current gap:

- Person list to Person detail uses Person's named `show` route through
  `$c->path_for`.
- Blogs list to Blog detail uses Blogs' named `show` route through
  `$c->path_for`.
- Root to Person, Person to Blogs, and Blogs back to Person cross opaque router
  frames and therefore use `MyApp::URL`.

The HTML navigation path is:

```text
/ -> /person -> /person/1 -> /person/1/blog
   -> /person/1/blog/{blog_id}
```

## 9. Routing outcomes

| Request shape | Owner | Required result |
|---|---|---|
| Unknown numeric person ID | Person `show_person` | Person HTML 404; final |
| Unknown numeric blog ID | Blogs `show_blog` | Blogs HTML 404; final |
| Deeper unknown Blogs path | Blogs catchall route | Blogs HTML 404; final |
| Unknown root path | Root catchall route | Root HTML 404; final |
| Unmatched path below Person | Person generated outcome today | Default child 404; GAP-02 |
| Wrong method for a child route | Child router | 405 with `Allow: GET, HEAD`; final |
| Missing static asset | PAGI::App::File | File app response; final |

Only a genuine routing NONE may eventually bubble. A PARTIAL match remains a
child-owned 405. A FULL handler, an explicit catchall, or any application that
emits a 404 has handled the request and must never be overturned.

Future bubbling is cooperative and limited to routing-aware components.
Arbitrary native applications remain terminal after their mount prefix takes
ownership. The design must not buffer response events or infer routing state
from an HTTP status code.

## 10. Gaps document

`examples/15-large-application/GAPS.md` uses numbered entries with these fields:

- desired behavior;
- shipped behavior;
- evidence in this example;
- current workaround; and
- follow-on design status.

It begins with:

### GAP-01: Cross-component reverse routing

Opaque application mounts cannot be named and do not expose child named routes
through their placement. Context reverse routing consults only the innermost
router frame. A Person handler therefore cannot address a Blogs route, and a
Blogs handler cannot address a Person route, with today's `path_for`/`url_for`.

The desired direction is placement-based naming, such as a parent assigning
the Blogs mount the name `blogs` and application code addressing
`blogs.index`. Package identity is not a sufficient route identity because the
same component may be mounted more than once.

The current workaround is `MyApp::URL`.

### GAP-02: Cooperative hierarchical no-match bubbling

After an opaque application mount prefix matches, the mounted application owns
the request. A child declarative router with no matching route sends its
generated 404 before its parent can resume declaration-order scanning.

The desired behavior is for a routing-aware child NONE to decline without
sending, allowing the parent to resume declaration-order scanning. Root's
explicit catchall handles the request when no later sibling handles it first.
Child FULL, PARTIAL, and explicit catchall outcomes remain final.
Native opaque applications do not participate unless a future explicit
cooperative contract says otherwise.

There is no workaround in this example; the integration test records the
shipped result.

### GAP-03: Component-shell ergonomics observation

The repeated imports, route construction, and `router(...)->to_app` wrapper in
Person and Blogs are recorded as an observation. It is promoted to a proposed
framework gap only after the completed example demonstrates enough weight to
justify a helper. This work package introduces no base class or constructor
shortcut.

The planned server `--lib`/`--module`/`-e` loader is listed as deferred external
work, not as a PAGI::Tools composition gap.

## 11. Testing

Add `t/integration-large-application.t`. It must use the PAGI-Tools
`PAGI::Test::Client`; no custom wire harness or live server is used.

The test must:

1. Add the example's `lib/` directory to `@INC` and load `MyApp::Root`.
2. Confirm `MyApp::Root->to_app` returns a native coderef.
3. Load `app.pl` with `do` and confirm it returns a native coderef.
4. Exercise the app through `PAGI::Test::Client->run($app, sub { ... })`, which
   starts and stops lifespan around the request assertions.
5. Confirm startup installed a `MyApp::Data` object in client state and shutdown
   removed it from the same state hash.
6. Follow every HTML navigation link from Root through a Blog detail page.
7. Verify Person's same-router link and Blogs' same-router link contain paths
   generated by their local named routes.
8. Verify the cross-component links produced by `MyApp::URL`.
9. Fetch `/static/app.css` and verify its content type and a recognizable rule.
10. Verify the response/status distinctions in section 9, including the child
    405 and `Allow: GET, HEAD`.
11. Include a clearly named assertion showing that an unmatched Person path
    currently receives the child router's generated 404 rather than Root's
    branded catchall. The assertion is evidence for GAP-02 and contains no
    intentional test failure.

Focused verification:

```text
prove -lv t/integration-large-application.t
```

Repository verification:

```text
prove -lr t
```

## 12. Documentation

The example README explains:

- the package tree and URL ownership;
- why Root uses Compose while child packages use routers directly;
- how lifespan supplies `MyApp::Data`;
- local named-route links versus cross-component URL helpers;
- how to run the example with the currently shipped file loader; and
- that the desired `--lib`/`--module`/`-e` command is future syntax, not a
  shipped server capability.

The checked-out repository command is:

```text
perl -Ilib bin/pagi-server --app \
    examples/15-large-application/app.pl --port 5000
```

`examples/README.md` gains one list entry describing the example as a
Compose-rooted, package-component HTML application with opaque mounted routers,
lifespan state, working links, and a documented gaps ledger.

## 13. Acceptance criteria

- `app.pl` contains no application behavior and returns
  `MyApp::Root->to_app`.
- All real application code is under `examples/15-large-application/lib`.
- Root, Person, and Blogs are separate opaque PAGI components.
- Shared fixtures are initialized through Compose lifespan state.
- All specified pages, links, static content, 404 cases, and 405 behavior are
  verified with `PAGI::Test::Client`.
- `GAPS.md` accurately documents current behavior without claiming planned
  capabilities are shipped.
- No core module behavior changes in the implementation diff.
- The focused integration test and full repository test suite pass.
