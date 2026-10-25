# A Framework on PAGI-Tools

`lib/Tiny.pm` is a small opinionated web framework built on PAGI-Tools, the
shape a Sinatra, Flask or FastAPI user expects, and `app.pl` is a notes
service written against it. It exists to answer one question of the
whipupitude gap analysis: when someone builds a framework on Tools, which
seams do they stand on, and what does each cost? Each piece of Tiny is
marked with the seam it uses.

## Run

```bash
pagi-server --app examples/framework-on-tools/app.pl --port 5000
```

## What the application looks like

```perl
use Tiny;

service notes => sub ($state) { { next => 1, by_id => {} } };
plugin 'Timing', name => 'notes';

around async sub ($req, $next) {
    my $sent = await $next->();
    $sent->headers->set('X-Powered-By', 'Tiny on PAGI-Tools');
    return $sent;
};

on_error 'Note::NotFound' => sub ($req, $exc) {
    return response('JSON', { error => 'no such note', id => $exc->id }, status => 404);
};

get '/notes' => name => 'notes', desc => 'List the notes', sub ($req) {
    my $notes = $req->svc('notes')->{by_id};
    return [ map { $notes->{$_} } sort { $a <=> $b } keys %$notes ];
};

get '/notes/{id:&Int}' => name => 'note', desc => 'One note', sub ($req) {
    return find_note($req, $req->param('id'));
};

raw '/raw' => async sub ($scope, $receive, $send) { ... };

get '/openapi.json' => openapi(title => 'Tiny notes');

tiny;
```

## The seams, and what each cost

| Tiny feature | Built on | Cost |
|---|---|---|
| verbs with one-Request handlers | `route($path => $endpoint, methods => [...])` | none; two routes on one path merge their `Allow` |
| the framework's own Request (`param`, `svc`) | a `PAGI::Request` subclass; `middleware('RequestClass', class => 'Tiny::Request')` puts it in the scope, and every handler below it gets one | one middleware line |
| plain-value returns (hashref is JSON, string is HTML) | `request_response` wrapping each handler, `response('JSON'...)`/`response('HTML'...)` | 5 lines |
| `before` hooks | the same wrapper | 4 lines |
| `around` with Starlette's `call_next` | a native middleware wrapping `$send`: `$next` starts the inner app and resolves on `http.response.start`; the start event is held until the hook returns | 38 lines of raw-protocol code, the only such code in Tiny, and the delicate part: replacing the response has to fail the held send to unwind the handler |
| services built at startup | Compose `lifespan => { startup }`, read with `$request->state` | none |
| typed path parameters | the compact `{id:&Int}`, or `constraints => { id => Int }` | `route()` looks a compact provider up in its caller, which is Tiny, so Tiny passes `declaration_package` (the application's package). Either form reaches the OpenAPI document: `route_table` reports each capture's constraints as declared |
| `on_error` class-to-response mapping | ErrorHandler's `catch`, each entry adapted to Tiny's handler shape | none; the entry gets a `Tiny::Request`: a route's error is answered at the route, with its own Request, and any other inside RequestClass, as Compose places the entries inside every application middleware. The most specific class answers, whatever the declaration order, and a status works as a key |
| plugins | a package with `register($app)` using the same hooks | none |
| the raw escape hatch | `route($path => as_app_object($code), methods => '*')` | none |
| an OpenAPI document | `PAGI::Routing::OpenAPI->document($compose)`, which reads `route_table` and each route's `meta => { openapi => {...} }` | none: Tiny keeps no generator of its own, so the document follows PAGI::Routing::OpenAPI's rules (an unrestricted `raw` route is a GET, HEAD folds into GET, two routes on one OpenAPI path are an error, an operationId is the method and the route's address, `get_notes`) |

Order matters and Tools leaves it to the framework: the `around` hooks wrap
the ErrorHandler, as Starlette's user middleware wraps its
ExceptionMiddleware, so a mapped error response passes through them too.
Written the other way round, `/notes/9` lost its `X-Powered-By`.
RequestClass comes first, so everything inside it, the ErrorHandler
included, gets a `Tiny::Request`.

Tiny is 175 code lines; the plugin 13; the application 47.

## Try

```bash
curl -i localhost:5000/notes
curl -i -X POST localhost:5000/notes -H 'Content-Type: application/json' -d '{"text":"buy milk"}'
curl -i localhost:5000/notes/1
curl -i localhost:5000/notes/9            # 404 from a thrown Note::NotFound
curl -i localhost:5000/notes/x            # 404: the Int constraint does not match
curl -i localhost:5000/admin              # 403 from the before hook
curl -i 'localhost:5000/admin?token=letmein'
curl -i -X PUT localhost:5000/notes/1     # 405, Allow: GET, HEAD, DELETE
curl -i localhost:5000/raw                # the raw application
curl -s localhost:5000/openapi.json | python3 -m json.tool
```

## See also

- `PAGI::Routing`, "HANDLERS" and "REVERSE ROUTING AND INSPECTION"
- `PAGI::Middleware::RequestClass`, how the Request subclass reaches every
  handler
- `PAGI::Middleware::ErrorHandler` and `PAGI::ErrorContext`
- `PAGI::Tools::Cookbook`, "An Application's Request Class"
- `examples/gut-check/04-everyday-middleware.pl`, middleware as plain
  functions without a `call_next`
