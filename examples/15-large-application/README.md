# Large Modular HTML Application

This example shows one way to structure a larger PAGI::Tools application as
opaque package components. All application behavior lives under `lib/`;
`app.pl` only loads `MyApp::Root` and returns `MyApp::Root->to_app`.

## Run it

From the PAGI-Tools checkout:

```bash
pagi-server --app examples/15-large-application/app.pl --port 5000
```

Then open <http://localhost:5000/>.

This future loader shape is intentionally not available yet:

```text
pagi-server --lib examples/15-large-application/lib \
    --module MyApp::Root -e 'MyApp::Root->to_app'
```

## Application tree

```text
lib/MyApp/
├── Data.pm
├── Root.pm
├── URL.pm
├── View.pm
├── Person.pm
└── Person/
    └── Blogs.pm
```

- `MyApp::Root` is the Compose boundary. It owns lifespan, `/`,
  `/static`, the Person mount, and the final root catchall.
- `MyApp::Person` is an independently compiled router mounted at
  `/person`.
- `MyApp::Person::Blogs` is another independently compiled router mounted by
  Person at `/{person_id}/blog`.
- `MyApp::Data` is created during startup and shared through
  `$c->state->{data}`.
- `MyApp::URL` centralizes links that cross opaque component boundaries.
- `MyApp::View` renders the shared HTML document shell without introducing a
  template engine.

## Routes

| Path | Owner |
|---|---|
| `/` | Root |
| `/person` | Person |
| `/person/{person_id}` | Person |
| `/person/{person_id}/blog` | Blogs |
| `/person/{person_id}/blog/{blog_id}` | Blogs |
| `/static/app.css` | PAGI::App::File |

Person list links to Person detail with Person's local named route. Blogs list
links to Blog detail with Blogs' local named route. Links that cross an opaque
mount use `MyApp::URL`; [GAPS.md](GAPS.md) explains why.

## Outcomes worth trying

- `/person/999` is a Person handler-owned 404.
- `/person/1/blog/999` is a Blogs handler-owned 404.
- `/person/1/blog/not/a/route` is handled by Blogs' explicit catchall.
- `/outside` is handled by Root's explicit catchall.
- `/person/1/unmatched` shows today's generated child 404 because opaque
  mount no-match bubbling is not yet available.

## Test it

```bash
prove -lv t/integration-large-application.t
```

The integration test uses `PAGI::Test::Client->run`, including lifespan
startup and shutdown. It does not start a live server.
