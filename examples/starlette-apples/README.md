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

The corresponding PAGI application is in [`app.pl`](app.pl). It serves a small
dependency-free apple manager from [`public/index.html`](public/index.html),
keeps the shared `PAGI::Pages` Welcome page at `/welcome`, and mounts an apples
Router under `/apples`.

```perl
#!/usr/bin/env perl
use v5.40;

use Future::AsyncAwait;
use List::Util qw(max);
use Types::Standard qw(Int);

use PAGI::Compose qw(compose);
use PAGI::Pages qw(welcome not_found);
use PAGI::Response qw(file_response json_response);
use PAGI::Routing qw(route mount router);
use PAGI::Routing::URL qw(url_for path_for);
use PAGI::Utils qw(app_path);

my $manager_file = app_path('public', 'index.html');

sub startup($state, $scope) {
    $state->{apples_db} = {
        1 => { id => 1, name => 'Gala',       color => 'Red/Yellow' },
        2 => { id => 2, name => 'Honeycrisp', color => 'Rosy Red' },
    };
    return;
}

sub apples_db($request) {
    my $state = $request->state
        or die 'starlette-apples requires Compose lifespan state';
    return $state->get('apples_db');
}

async sub list_apples($request) {
    my $db = apples_db($request);

    return json_response([
        map {
            +{
                %{$db->{$_}},
                url => url_for(
                    $request,
                    'read',
                    { apple_id => $_ },
                ),
            }
        } sort { $a <=> $b } keys %$db
    ]);
}

async sub read_apple($request) {
    my $id = $request->path_param('apple_id');
    my $apple = apples_db($request)->{$id};

    return json_response($apple) if $apple;
    return json_response(
        { error => 'Apple not found' },
        status => 404,
    );
}

async sub create_apple($request) {
    my $db = apples_db($request);
    my $data = await $request->json;
    my $id = max(0, keys %$db) + 1;
    my $apple = { id => $id, %$data };
    $db->{$id} = $apple;

    return json_response(
        $apple,
        status  => 201,
        headers => [
            Location => path_for(
                $request,
                'read',
                { apple_id => $id },
            ),
        ],
    );
}

async sub update_apple($request) {
    my $db = apples_db($request);
    my $id = $request->path_param('apple_id');

    return json_response(
        { error => 'Apple not found' },
        status => 404,
    ) unless exists $db->{$id};

    my $data = await $request->json;
    $db->{$id} = { %{$db->{$id}}, %$data };
    return json_response($db->{$id});
}

async sub delete_apple($request) {
    my $db = apples_db($request);
    my $id = $request->path_param('apple_id');

    return json_response(
        { error => 'Apple not found' },
        status => 404,
    ) unless exists $db->{$id};

    return json_response({
        success => \1,
        deleted => delete $db->{$id},
    });
}

compose(
    app => router(
        routes => [
            route('/' => file_response($manager_file, inline => 1),
                name => 'home',
                desc => 'Apple manager SPA',
            ),
            route('/welcome' => welcome(),
                name => 'welcome',
                desc => 'PAGI welcome page',
            ),
            mount('/apples',
                routes => [
                    route('/' => \&list_apples,
                        methods => ['GET'], name => 'list'),
                    route('/' => \&create_apple,
                        methods => ['POST'], name => 'create'),
                    route('/{apple_id:&Int}' => \&read_apple,
                        methods => ['GET'], name => 'read'),
                    route('/{apple_id:&Int}' => \&update_apple,
                        methods => ['PUT'], name => 'update'),
                    route('/{apple_id:&Int}' => \&delete_apple,
                        methods => ['DELETE'], name => 'delete'),
                ],
                name => 'apples',
            ),
        ],
        http_default => not_found(
            detail => 'That page does not exist in the Apple demo.',
        ),
    ),
    lifespan => { startup => \&startup },
);
```

The static root file, `/welcome` Pages value, CRUD JSON values, and custom root
404 are direct application values. The exact root file and `/welcome` remain
Route endpoints, while `/apples` is a subtree-owning child Router. The custom
root 404 is the Router's `http_default`, so it handles unknown paths without
swallowing the 405 for a known path such as `PUT /welcome`.

| Starlette | PAGI::Tools |
| --- | --- |
| `JSONResponse(value)` | `json_response($value)` |
| `FileResponse(path)` | `file_response($path)` |
| response is ASGI-callable | response implements `to_app` |
| `Route('/', endpoint)` | exact `route('/' => handler-or-component)` |
| `Mount('/x', app=...)` | subtree-owning `mount('/x', app => ...)` |
| `StreamingResponse(iterator)` | `stream_response(async sub ($writer) { ... })` |

These APIs are related, but they are not identical. The PAGI mount creates an
explicit namespace boundary that the flat Python route list does not have.
Perl imports also make ownership visible: `PAGI::Response` exports explicit
response factories, while `PAGI::Routing::URL` owns reverse routing rather than
making either capability intrinsic to Request. Starlette's `int` converter
places an integer in `request.path_params`; PAGI's `Int` constraint validates
the decoded path capture but leaves the original scalar for the handler.

That distinction is visible at the boundary. `/apples/999` matches a resource
route and returns the handler's JSON `{ "error": "Apple not found" }`.
`/apples/not-an-int` fails the route constraint, while `/elsewhere` matches no
route at all; the apples child and custom root default render those misses at
their respective boundaries. Unknown methods such as `DELETE /elsewhere`
remain 404. The child owns `PATCH /apples` and its `Allow: GET, HEAD, POST`.
Both `/apples` and `/apples/` reach the child `/` index.
`Types::Standard::Int` accepts `-1`, so `/apples/-1` reaches the handler and
returns the application JSON rather than a routing response.

## Run

This example requires Perl 5.40 or newer.

```bash
pagi-server --app examples/starlette-apples/app.pl --port 5000
```

## Try it

Open the apple manager in a browser:

```text
http://127.0.0.1:5000/
```

The SPA lists, creates, edits, and deletes apples through the same JSON routes
shown below. The shared PAGI Welcome page remains available separately:

```bash
curl -i -H 'Accept: text/html' http://127.0.0.1:5000/welcome
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

Compare an application-owned missing record with Router-owned routing
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

Compose lifespan owns the process-local mutable demo data. `apples_db()`
checks that the server supplied lifespan state and dies with a direct setup
diagnostic if this application is deployed without that boundary. The data
has no persistence, schema validation, or locking.
