# Starlette apples comparison

This example translates a small Starlette CRUD application into the current
PAGI::Tools shape. Starlette was the primary inspiration for PAGI's functional
routing API, so keeping the two applications together makes their similarities
and differences easier to evaluate.

## Original Starlette application

This is the original Python application supplied for the comparison:

```python
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

apples_db = {
    1: {"id": 1, "name": "Gala", "color": "Red/Yellow"},
    2: {"id": 2, "name": "Honeycrisp", "color": "Rosy Red"},
}

async def list_apples(request: Request) -> JSONResponse:
  return JSONResponse(list(apples_db.values()))

async def read_apple(request: Request) -> JSONResponse:
  apple_id = int(request.path_params["apple_id"])
  apple = apples_db.get(apple_id)
  if not apple:
    return JSONResponse({"error": "Apple not found"}, status_code=404)
  return JSONResponse(apple)

async def create_apple(request: Request) -> JSONResponse:
  data = await request.json()
  new_id = max(apples_db.keys(), default=0) + 1
  new_apple = {"id": new_id, **data}
  apples_db[new_id] = new_apple
  return JSONResponse(new_apple, status_code=201)

async def update_apple(request: Request) -> JSONResponse:
  apple_id = int(request.path_params["apple_id"])
  if apple_id not in apples_db:
    return JSONResponse({"error": "Apple not found"}, status_code=404)

  data = await request.json()
  apples_db[apple_id].update(data)
  return JSONResponse(apples_db[apple_id])

async def delete_apple(request: Request) -> JSONResponse:
  apple_id = int(request.path_params["apple_id"])
  if apple_id not in apples_db:
    return JSONResponse({"error": "Apple not found"}, status_code=404)

  deleted_apple = apples_db.pop(apple_id)
  return JSONResponse({"success": True, "deleted": deleted_apple})

app = Starlette(
    routes=[
        Route("/apples", list_apples, methods=["GET"]),
        Route("/apples", create_apple, methods=["POST"]),
        Route("/apples/{apple_id:int}", read_apple, methods=["GET"]),
        Route("/apples/{apple_id:int}", update_apple, methods=["PUT"]),
        Route("/apples/{apple_id:int}", delete_apple, methods=["DELETE"]),
    ]
)
```

## PAGI application

The corresponding PAGI application is in [`app.pl`](app.pl). It adds a `/`
route using the shared `PAGI::Pages` Welcome page, then mounts an apples Router
under `/apples`.

The final wildcard considered during design is intentionally absent. Compose
already turns routing evidence into negotiated Not Found and Method Not
Allowed responses. A wildcard route would be a real match, so it could hide a
method mismatch such as `PATCH /apples` and incorrectly turn the 405 into a
404.

| Starlette | PAGI::Tools |
| --- | --- |
| `Starlette(routes=[...])` | `compose(routes => [...])->to_app` |
| `Route(...)` | `route(...)` and an explicit `/apples` `mount(...)` boundary |
| `Request` | HTTP `$c` Context and `$c->request` |
| `JSONResponse(...)` | `$c->json(...)` |
| `{apple_id:int}` | `{apple_id:&Int}` from `Types::Standard` |
| converter validates and converts | constraint validates without coercion |
| application default 404/405 | Compose default NotFound/MethodNotAllowed |

These APIs are related, but they are not identical. The PAGI mount creates an
explicit namespace boundary that the flat Python route list does not have.
Starlette's `int` converter places an integer in `request.path_params`; PAGI's
`Int` constraint validates the decoded path capture but leaves the original
scalar for the handler.

That distinction is visible at the boundary. `/apples/999` matches a resource
route and returns the handler's JSON `{ "error": "Apple not found" }`.
`/apples/not-an-int` fails the route constraint, while `/elsewhere` matches no
route at all; Compose renders both routing misses. `Types::Standard::Int`
accepts `-1`, so `/apples/-1` reaches the handler and returns the application
JSON rather than a routing response.

## Run

This example requires Perl 5.40 or newer.

```bash
pagi-server --app examples/starlette-apples/app.pl --port 5000
```

## Try it

Open the Welcome page:

```bash
curl -i -H 'Accept: text/html' http://127.0.0.1:5000/
```

List and read apples:

```bash
curl -i http://127.0.0.1:5000/apples
curl -i http://127.0.0.1:5000/apples/1
```

Create, update, and delete an apple. In a freshly started process, the new
record receives ID 3:

```bash
curl -i -X POST \
  -H 'Content-Type: application/json' \
  -d '{"name":"Fuji","color":"Red"}' \
  http://127.0.0.1:5000/apples

curl -i -X PUT \
  -H 'Content-Type: application/json' \
  -d '{"color":"Crimson"}' \
  http://127.0.0.1:5000/apples/3

curl -i -X DELETE http://127.0.0.1:5000/apples/3
```

Compare an application-owned missing record with Compose-owned routing
outcomes:

```bash
curl -i http://127.0.0.1:5000/apples/999

curl -i \
  -H 'Accept: application/problem+json' \
  http://127.0.0.1:5000/apples/not-an-int

curl -i -X PATCH \
  -H 'Accept: application/problem+json' \
  http://127.0.0.1:5000/apples

curl -i \
  -H 'Accept: application/problem+json' \
  http://127.0.0.1:5000/elsewhere
```

The database is intentionally process-local mutable demo data. It has no
persistence, schema validation, or locking.
