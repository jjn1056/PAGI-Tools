# Large Modular HTML Application

This example structures a larger PAGI::Tools application as an inspectable
Router graph. All application behavior lives under `lib/`; `app.pl` only loads
`MyApp::Root` and returns `MyApp::Root->to_app`.

## Run it

From the PAGI-Tools checkout, use the currently shipped file loader:

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
- `MyApp::Root` is the one Compose boundary. Its `to_app()` composes
  `MyApp::Root->routing` with startup and shutdown callbacks.
- Root mounts Person with `router =>` and namespace `person`; Person mounts
  Blogs with `router =>` and namespace `blog`. These known Router mounts form
  one inspectable reverse-routing graph.
- Root mounts `PAGI::App::File` positionally at `/static`. That mount stays an
  opaque application boundary: the resolver knows its prefix but does not
  inspect named routes below it.
- `MyApp::Data` is created during startup and shared through
  `$c->state->{data}`. `MyApp::View` renders the shared HTML document shell
  without introducing a template engine.

## Named address map

Logical route addresses are stable names for the composed graph, not URL
paths. The mount namespaces contribute `person` and `blog`:

| Logical address | URL pattern | Source package |
|---|---|---|
| `/home` | `/` | `MyApp::Root` |
| `/person/index` | `/person/` | `MyApp::Person` |
| `/person/show` | `/person/{person_id}` | `MyApp::Person` |
| `/person/blog/index` | `/person/{person_id}/blog/` | `MyApp::Person::Blogs` |
| `/person/blog/show` | `/person/{person_id}/blog/{blog_id}` | `MyApp::Person::Blogs` |

Handlers generate every application link through Context `path_for` or
`url_for`. Calls inside a component use relative addresses and inherit the
matched `person_id` or `blog_id`; graph-wide links such as Home use absolute
addresses such as `/home`. The two distinct parameter names avoid collisions
in the composed path.

## Outcomes worth trying

- `/person/999` is a Person handler-owned 404.
- `/person/1/blog/999` is a Blogs handler-owned 404.
- `/person/1/blog/not/a/route` is handled by Blogs' explicit catchall.
- `/outside` is handled by Root's ordinary explicit catchall.
- `/person/1/unmatched` is still the Person Router's generated child 404:
  matched child Router boundaries own NONE, so no-match bubbling remains
  deferred as GAP-02.
- `/static/missing.css` remains owned by the opaque file application rather
  than being reinterpreted by Root.

## Test it

```bash
prove -lv t/integration-large-application.t
```

The integration test uses `PAGI::Test::Client->run`, including lifespan
startup and shutdown. It begins navigation at `/`, extracts exact-label hrefs
from the rendered HTML, and follows the generated links through the complete
Root, Person, and Blogs graph without starting a live server.
