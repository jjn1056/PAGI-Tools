# Large Modular HTML Application

This example structures a larger PAGI::Tools application as an inspectable
Router graph. All application behavior lives under `lib/`; `app.pl` only loads
`MyApp::Root` and returns `MyApp::Root->to_app`. That method retains the
inspectable `PAGI::Compose` description; a conforming server compiles its
`to_app` boundary once while loading the application.

This example requires Perl 5.40+ and Type::Tiny. Those are example/test
requirements: the PAGI::Tools distribution itself still supports Perl 5.18
and does not depend on Type::Tiny at runtime.

## Run it

From the PAGI-Tools checkout, use the currently shipped file loader:

`app.pl` still locates `lib` because bootstrap happens before `PAGI::Utils` or
`MyApp::Root` can be loaded.

```bash
pagi-server --app examples/15-large-application/app.pl --port 5000
```

Then open <http://localhost:5000/>.

This module-and-expression loader shape remains deferred and is not currently
available:

```text
pagi-server --lib /Project-MyApp/lib --module MyApp::Root \
    -e 'MyApp::Root->to_app'
```

## Application tree

```text
lib/MyApp/
├── Data.pm
├── Root.pm
├── View.pm
├── Person.pm
└── Person/
    └── Blogs.pm
```

- `MyApp::Root`, `MyApp::Person`, and `MyApp::Person::Blogs` each expose a
  `routing()` method that returns an immutable `PAGI::Routing::Router`
  description.
- `MyApp::Root` is the one Compose boundary. Its `to_app()` returns the
  composition of `MyApp::Root->routing` with startup and shutdown callbacks.
- Root mounts Person with `app =>` and name `person`; Person mounts Blogs with
  `app =>` and name `blog`. The application values are immutable Router
  objects, so these mounts form one inspectable reverse-routing graph.
- Root mounts `PAGI::App::File` with `app =>` at `/static`. That mount stays an
  opaque application boundary: the resolver knows its prefix but does not
  inspect named routes below it.
- Root uses `PAGI::App::File->from_app_path('static')`, a component constructor that
  derives application home from the calling `lib/MyApp/Root.pm`, appends the
  platform-aware static component, and can be mounted directly. `PAGI_HOME`
  remains the override for nonstandard deployments.
- `MyApp::Data` is created during startup and shared through
  `$request->state->get('data')`. `MyApp::View` renders the shared HTML
  document shell without introducing a template engine.
- Root and Blogs adapt named Request handlers with `request_response(...)` for
  their Router `http_default` values. Each handler returns a source-free
  `not_found(...)` application. The details
  identify which selected Router owns an unmatched path without turning a
  wildcard into a normal route.
- Root's named `/pagi` route returns `welcome()`. The home
  page reaches it through a generated `path_for('/pagi')` link, demonstrating an
  ordinary Pages application returned from a selected Request handler without
  replacing the application's branded or domain-specific missing pages.

## Named address map

Logical route addresses are stable names for the composed graph, not URL
paths. The mount names contribute `person` and `blog`:

| Logical address | URL pattern | Source package |
|---|---|---|
| `/home` | `/` | `MyApp::Root` |
| `/pagi` | `/pagi` | `MyApp::Root` |
| `/person/index` | `/person/` | `MyApp::Person` |
| `/person/show` | `/person/{person_id}` | `MyApp::Person` |
| `/person/blog/index` | `/person/{person_id}/blog/` | `MyApp::Person::Blogs` |
| `/person/blog/show` | `/person/{person_id}/blog/{blog_id}` | `MyApp::Person::Blogs` |

Handlers import `path_for` and `url_for` from `PAGI::Routing::URL` and pass the
current Request explicitly. Calls inside a component use relative addresses
and inherit the matched `person_id` or `blog_id`; graph-wide links such as
Home use absolute addresses such as `/home`. The two distinct parameter names
avoid collisions in the composed path.

Person and Blog identifiers demonstrate inline constraint providers:

```perl
use Types::Standard qw(Int);

route('/{person_id:&Int}' => \&show_person, name => 'show');
route('/{blog_id:&Int}'   => \&show_blog,   name => 'show');
```

`&Int` means “call the imported `Int` package function once while constructing
this source route, then normalize its returned Type::Tiny object into a
predicate closure that retains and calls the object.” Matching and reverse
routing validate but never convert values;
handlers still receive the original decoded scalar. `Types::Standard::Int`
accepts a leading minus sign, so it is intentionally broader than the old
`qr/\d+/` declaration. An application requiring positive database identifiers
would normally expose a narrower local provider such as `&PersonId`.

## Outcomes worth trying

- `/pagi` is the stock Pages Welcome response reached from the generated home
  link.
- `/person/999` is a Person handler-owned 404.
- `/person/-1` matches `&Int` and is also a Person handler-owned 404.
- `/person/not-an-integer` fails `&Int`; the selected Person Router renders its
  stock negotiated Pages-backed 404.
- `/person/1/blog/999` is a Blogs handler-owned 404.
- `/person/1/blog/not/a/route` is handled by Blogs' custom Router default.
- `/outside` is handled by Root's custom Router default.
- `/person/1/unmatched` is owned and completed by the selected Person Router.
  The parent does not resume and Root's custom policy does not replace it.
- A method mismatch under a selected child reaches that Router's automatic 405
  with only that child's first-seen `Allow` union; discarded parent partials
  do not leak into it.
- `/static/missing.css` remains owned by the opaque file application rather
  than being reinterpreted by Root.

## Test it

```bash
prove -lv t/integration-large-application.t
```

The integration test uses `PAGI::Test::Client->run`, including lifespan
startup and shutdown. It begins navigation at `/`, extracts exact-label hrefs
from the rendered HTML, and follows the generated Pages, Root, Person, and
Blogs links without starting a live server.

## Starlette comparison

This was the idiomatic Python/Starlette comparison used while evaluating the
PAGI application shape. It deliberately uses module-level route lists and
`Mount(..., routes=...)`, not independently mounted `Starlette` sub-apps. That
keeps one application lifespan and one visible reverse-routing graph.

The comparison follows Starlette's current
[routing](https://www.starlette.io/routing/) and
[lifespan](https://www.starlette.io/lifespan/) APIs. It is illustrative Python
kept beside the real Perl application; it is not installed or tested as part
of PAGI::Tools.

```text
Project-MyApp/
├── static/
│   └── app.css
└── myapp/
    ├── data.py
    ├── view.py
    ├── blogs.py
    ├── person.py
    └── root.py
```

### `myapp/data.py`

```python
from typing import TypedDict


class Data:
    def __init__(self) -> None:
        self._people = {
            1: {
                "id": 1,
                "name": "Ada Lovelace",
                "summary": "Mathematician and writer",
            },
            2: {
                "id": 2,
                "name": "Grace Hopper",
                "summary": "Computer scientist and naval officer",
            },
            3: {
                "id": 3,
                "name": "Margaret Hamilton",
                "summary": "Software engineer",
            },
        }
        self._blogs = {
            1: {
                101: {
                    "id": 101,
                    "title": "Notes on the Analytical Engine",
                    "body": (
                        "A machine may compose elaborate and scientific "
                        "pieces of music."
                    ),
                },
                102: {
                    "id": 102,
                    "title": "Poetical Science",
                    "body": (
                        "Imagination helps us discover what computation "
                        "can express."
                    ),
                },
            },
            2: {
                201: {
                    "id": 201,
                    "title": "Compilers and Clear Languages",
                    "body": (
                        "Programming languages should help people state "
                        "ideas clearly."
                    ),
                },
            },
            3: {},
        }

    def people(self) -> list[dict[str, object]]:
        return list(self._people.values())

    def person(self, person_id: int) -> dict[str, object] | None:
        return self._people.get(person_id)

    def blogs_for(self, person_id: int) -> list[dict[str, object]] | None:
        if person_id not in self._people:
            return None
        return list(self._blogs.get(person_id, {}).values())

    def blog(
        self,
        person_id: int,
        blog_id: int,
    ) -> dict[str, object] | None:
        if person_id not in self._people:
            return None
        return self._blogs.get(person_id, {}).get(blog_id)


class AppState(TypedDict):
    data: Data
```

### `myapp/view.py`

```python
from html import escape


def html_text(value: object) -> str:
    return escape(str(value))


def html_href(value: object) -> str:
    return escape(str(value), quote=True)


def document(title: str, body: str) -> str:
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html_text(title)}</title>
  <link rel="stylesheet" href="/static/app.css">
</head>
<body>
  <main class="page">
{body}
  </main>
</body>
</html>
"""
```

### `myapp/blogs.py`

```python
from starlette.requests import Request
from starlette.responses import HTMLResponse
from starlette.routing import Route

from .data import AppState
from .view import document, html_href, html_text


async def list_blogs(request: Request[AppState]) -> HTMLResponse:
    person_id = request.path_params["person_id"]
    data = request.state["data"]
    person = data.person(person_id)

    if person is None:
        return HTMLResponse(
            document("Blogs not found", "    <h1>Blogs not found</h1>"),
            status_code=404,
        )

    items = []
    for blog in data.blogs_for(person_id) or []:
        path = request.url_for(
            "person:blog:show",
            person_id=person_id,
            blog_id=blog["id"],
        )
        items.append(
            f'      <li><a href="{html_href(path)}">'
            f'{html_text(blog["title"])}</a></li>'
        )

    person_path = request.url_for("person:show", person_id=person_id)
    body = (
        f'    <a href="{html_href(person_path)}">'
        f'{html_text(person["name"])}</a>\n'
        "    <h1>Blogs</h1>\n    <ul>\n"
        + "\n".join(items)
        + "\n    </ul>"
    )
    return HTMLResponse(
        document(f'Blogs by {person["name"]}', body)
    )


async def show_blog(request: Request[AppState]) -> HTMLResponse:
    person_id = request.path_params["person_id"]
    blog_id = request.path_params["blog_id"]
    blog = request.state["data"].blog(person_id, blog_id)

    if blog is None:
        blogs_path = request.url_for(
            "person:blog:index",
            person_id=person_id,
        )
        return HTMLResponse(
            document(
                "Blog not found",
                f'    <a href="{html_href(blogs_path)}">Blogs</a>\n'
                "    <h1>Blog not found</h1>",
            ),
            status_code=404,
        )

    home_path = request.url_for("home")
    person_path = request.url_for("person:show", person_id=person_id)
    blogs_path = request.url_for(
        "person:blog:index",
        person_id=person_id,
    )
    canonical = (
        request.url_for(
            "person:blog:show",
            person_id=person_id,
            blog_id=blog_id,
        )
        .include_query_params(view="full")
        .replace(fragment="comments")
    )

    body = (
        f'    <a href="{html_href(home_path)}">Home</a> / '
        f'<a href="{html_href(person_path)}">Person</a> / '
        f'<a href="{html_href(blogs_path)}">Blogs</a>\n'
        f'    <article><h1>{html_text(blog["title"])}</h1>'
        f'<p>{html_text(blog["body"])}</p></article>\n'
        f'    <a href="{html_href(canonical)}">Comments view</a>'
    )
    return HTMLResponse(document(str(blog["title"]), body))


async def blogs_not_found(request: Request[AppState]) -> HTMLResponse:
    person_id = request.path_params["person_id"]
    blogs_path = request.url_for(
        "person:blog:index",
        person_id=person_id,
    )
    return HTMLResponse(
        document(
            "Blogs section not found",
            f'    <a href="{html_href(blogs_path)}">Blogs</a>\n'
            "    <h1>Blogs section not found</h1>",
        ),
        status_code=404,
    )


routes = [
    Route("/", list_blogs, name="index"),
    Route("/{blog_id:int}", show_blog, name="show"),
    Route("/{path:path}", blogs_not_found),
]
```

### `myapp/person.py`

```python
from starlette.requests import Request
from starlette.responses import HTMLResponse
from starlette.routing import Mount, Route

from .blogs import routes as blog_routes
from .data import AppState
from .view import document, html_href, html_text


async def list_people(request: Request[AppState]) -> HTMLResponse:
    items = []
    for person in request.state["data"].people():
        path = request.url_for("person:show", person_id=person["id"])
        items.append(
            f'      <li><a href="{html_href(path)}">'
            f'{html_text(person["name"])}</a></li>'
        )

    body = (
        "    <h1>People</h1>\n    <ul>\n"
        + "\n".join(items)
        + "\n    </ul>"
    )
    return HTMLResponse(document("People", body))


async def show_person(request: Request[AppState]) -> HTMLResponse:
    person_id = request.path_params["person_id"]
    person = request.state["data"].person(person_id)

    if person is None:
        people_path = request.url_for("person:index")
        return HTMLResponse(
            document(
                "Person not found",
                f'    <a href="{html_href(people_path)}">People</a>\n'
                "    <h1>Person not found</h1>",
            ),
            status_code=404,
        )

    blogs_path = request.url_for(
        "person:blog:index",
        person_id=person_id,
    )
    home_path = request.url_for("home")
    body = (
        f'    <a href="{html_href(home_path)}">Home</a>\n'
        f'    <h1>{html_text(person["name"])}</h1>\n'
        f'    <p>{html_text(person["summary"])}</p>\n'
        f'    <a href="{html_href(blogs_path)}">Read blogs</a>'
    )
    return HTMLResponse(document(str(person["name"]), body))


routes = [
    Route("/", list_people, name="index"),
    Route("/{person_id:int}", show_person, name="show"),
    Mount(
        "/{person_id:int}/blog",
        routes=blog_routes,
        name="blog",
    ),
]
```

### `myapp/root.py`

```python
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import HTMLResponse
from starlette.routing import Mount, Route
from starlette.staticfiles import StaticFiles

from .data import AppState, Data
from .person import routes as person_routes
from .view import document, html_href


STATIC_ROOT = Path(__file__).resolve().parent.parent / "static"


@asynccontextmanager
async def lifespan(app: Starlette) -> AsyncIterator[AppState]:
    yield {"data": Data()}


async def home(request: Request[AppState]) -> HTMLResponse:
    people_path = request.url_for("person:index")
    count = len(request.state["data"].people())
    body = (
        "    <h1>My PAGI People</h1>\n"
        f"    <p>This application contains {count} people.</p>\n"
        f'    <p><a href="{html_href(people_path)}">'
        "Browse people</a></p>"
    )
    return HTMLResponse(document("My PAGI People", body))


async def root_not_found(request: Request[AppState]) -> HTMLResponse:
    return HTMLResponse(
        document(
            "Root page not found",
            "    <h1>Root page not found</h1>\n"
            "    <p>No root route matched this path.</p>",
        ),
        status_code=404,
    )


routes = [
    Route("/", home, name="home"),
    Mount(
        "/static",
        app=StaticFiles(directory=STATIC_ROOT),
        name="static",
    ),
    Mount("/person", routes=person_routes, name="person"),
    Route("/{path:path}", root_not_found),
]


app = Starlette(routes=routes, lifespan=lifespan)
```

Run that version with an ASGI server such as Uvicorn:

```bash
uvicorn myapp.root:app
```

The comparison highlights a few deliberate differences:

- Starlette modules expose ordinary `routes` lists; PAGI packages return
  immutable Router descriptions with Router-level metadata and behavior.
- Starlette's named mounts compose colon-qualified names such as
  `person:blog:show`; PAGI composes slash addresses such as
  `/person/blog/show` and additionally supports relative lookup.
- Starlette URL generation requires every path parameter explicitly. PAGI's
  Request-bound URL helper may inherit matched parameters, which enables calls
  such as `path_for('show')` and `path_for('../show')`.
- Starlette's `int` converter both validates and converts the value to a
  Python integer. PAGI's `&Int` provider obtains a Type::Tiny constraint once
  during route construction; it validates without coercing the decoded scalar
  and accepts signed integers such as `-1`.
- Starlette adds query parameters and a fragment by transforming the returned
  URL object. PAGI accepts query and fragment values directly in `url_for`.
- The illustrative Starlette modules retain explicit root and Blogs catchall
  routes. The executable PAGI version instead configures Router
  `http_default` endpoints, so missing-path policy remains an outcome rather
  than masquerading as a successful wildcard match.
