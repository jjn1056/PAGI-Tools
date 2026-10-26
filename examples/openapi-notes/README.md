# A notes API with a generated OpenAPI document

> **Early beta.** `PAGI::Routing::OpenAPI` is new, and its interface may still
> change incompatibly in a later release; this example will change with it.

A small JSON API whose `/openapi.json` is generated from its routes by
`PAGI::Routing::OpenAPI`: paths, typed path parameters, operationIds,
summaries and security come from the routes themselves, and the request and
response bodies from each route's `meta`. Hand the document to a client
generator and the client works against the running API (see "Generating a
client").

This example requires Perl 5.40 or newer and `Type::Tiny`. Run it from the
distribution root:

```console
pagi-server --lib lib -I examples/openapi-notes/lib --app examples/openapi-notes/lib/NotesApp.pm --port 5000
```

```console
curl -s localhost:5000/openapi.json | python3 -m json.tool
curl -s localhost:5000/notes/
curl -s -X POST localhost:5000/notes/ -H 'Authorization: Bearer writer' \
     -H 'Content-Type: application/json' -d '{"text":"buy milk"}'
curl -s localhost:5000/notes/1
curl -s -X DELETE localhost:5000/notes/1 -H 'Authorization: Bearer writer'
```

The demo bearer tokens are `writer` (may add and delete notes) and `reader`
(may not). Reading is public.

## How it is built

```
lib/NotesApp.pm         the application: a PAGI::App::Compose, served by openapi(...)
lib/NotesApp/Notes.pm   the notes API: a Router from a class method, with meta per route
public/index.html       a page served by a separate application at /static
```

The parts of one application are Routers, with one Compose at the root.
`NotesApp::Notes->routing` returns a Router, and the root mounts it at
`/notes`. A mount is transparent to a Router, so the root's `route_table`,
`path_for` and its OpenAPI document see every route in it.

`/static` is a `PAGI::App::File`, a separate application. Routing does not
see into a mounted application, so the document leaves it out; a mounted
application describes itself.

The root adds the document in its `application` hook, which receives the
composition its hooks declare and returns the application to serve:

```perl
sub application ($self, $composition) {
    return openapi($composition,
        title           => 'Notes',
        version         => '1.0.0',
        security_scheme => [bearer => { type => 'http', scheme => 'bearer' }],
        components      => { schemas => NotesApp::Notes->schemas },
    );
}
```

`openapi` returns a new Compose: the document as a `GET /openapi.json` route,
the application's routes mounted behind it, and its middleware and lifespan
kept. The document is a route of the application, so its middleware (CORS,
logging, error handling) applies to it, and HEAD works; it is built from the
composition before that route is added, so it never describes itself. For a
small application in one script it is just
`openapi(compose(routes => [...]), title => ..., version => ...)`.

## The document

Each piece comes from one place:

| In the document | From |
|---|---|
| `/notes/{id}` | the mount `/notes` and the route `/{id:&Int}` |
| `"type": "integer"` | the `&Int` constraint (Types::Standard `Int`) |
| `operationId` `get_notes_show` | the method and the route's address, `/notes/show` |
| `summary` | the route's `desc` |
| `security` | the `Requires` middleware on the route |
| `requestBody`, `responses` | the route's `meta => { openapi => {...} }` |
| `components.schemas` | `NotesApp::Notes->schemas`, given as `components` |
| `components.securitySchemes` | the `security_scheme` option |

Two operations of it:

```json
{
  "/notes/" : {
    "post" : {
      "operationId" : "post_notes_create",
      "requestBody" : {
        "content" : { "application/json" : { "schema" : { "$ref" : "#/components/schemas/NewNote" } } },
        "required" : true
      },
      "responses" : {
        "201" : {
          "content" : { "application/json" : { "schema" : { "$ref" : "#/components/schemas/Note" } } },
          "description" : "The new note"
        }
      },
      "security" : [ { "bearer" : [ "notes:write" ] } ],
      "summary" : "Add a note"
    }
  },
  "/notes/{id}" : {
    "get" : {
      "operationId" : "get_notes_show",
      "parameters" : [
        { "in" : "path", "name" : "id", "required" : true, "schema" : { "type" : "integer" } }
      ],
      "responses" : {
        "200" : {
          "content" : { "application/json" : { "schema" : { "$ref" : "#/components/schemas/Note" } } },
          "description" : "The note"
        },
        "404" : {
          "content" : { "application/json" : { "schema" : { "$ref" : "#/components/schemas/Error" } } },
          "description" : "No such note"
        }
      },
      "summary" : "One note"
    }
  }
}
```

Every route declares its responses, with schemas, so a generated client
returns typed models rather than untyped data.

## Generating a client

With the API running, save its document:

```console
curl -s localhost:5000/openapi.json > openapi.json
```

A Python client with [openapi-python-client](https://github.com/openapi-generators/openapi-python-client):

```console
uvx openapi-python-client generate --path openapi.json --output-path notes-client --overwrite
```

```python
from notes_client import AuthenticatedClient
from notes_client.api.default import post_notes_create, get_notes_show
from notes_client.models import NewNote

client = AuthenticatedClient(base_url="http://localhost:5000", token="writer")
note = post_notes_create.sync(client=client, body=NewNote(text="buy milk"))
print(get_notes_show.sync(client=client, id=note.id))
```

Or with [openapi-generator](https://github.com/OpenAPITools/openapi-generator), any of its languages:

```console
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/local" \
    openapitools/openapi-generator-cli generate -i /local/openapi.json -g python -o /local/openapi-client
```

`t/integration-openapi-notes-clients.t` does both against a running server,
and drives each client through the whole API (it runs with `RELEASE_TESTING`
when `uv` and Docker are available). `t/example-openapi-notes.t` checks the
API and the exact document in-process.
