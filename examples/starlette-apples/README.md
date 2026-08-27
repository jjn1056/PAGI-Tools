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

```perl
#!/usr/bin/env perl
use v5.40;

use Future::AsyncAwait;
use List::Util qw(max);
use Types::Standard qw(Int);

use PAGI::Compose qw(compose);
use PAGI::Pages;
use PAGI::Response;
use PAGI::Routing qw(route mount);
use PAGI::Routing::URL qw(url url_for path_for);

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
    my @apples = map {
        +{
            %{$db->{$_}},
            url => url_for($request, 'read', { apple_id => $_ }),
        }
    } sort { $a <=> $b } keys %$db;

    return PAGI::Response->json(\@apples);
}

async sub read_apple($request) {
    my $apple_id = $request->path_param('apple_id');
    my $apple = apples_db($request)->{$apple_id};

    return PAGI::Response->json($apple) if $apple;
    return PAGI::Response->json(
        { error => 'Apple not found' },
        status => 404,
    );
}

async sub create_apple($request) {
    my $db = apples_db($request);
    my $data = await $request->json;
    my $new_id = max(0, keys %$db) + 1;
    my $new_apple = { id => $new_id, %$data };
    $db->{$new_id} = $new_apple;

    my $location = path_for($request, 'read', { apple_id => $new_id });
    return PAGI::Response->json(
        $new_apple,
        status  => 201,
        headers => [Location => $location],
    );
}

async sub update_apple($request) {
    my $db = apples_db($request);
    my $apple_id = $request->path_param('apple_id');
    return PAGI::Response->json(
        { error => 'Apple not found' }, status => 404,
    ) unless exists $db->{$apple_id};

    my $data = await $request->json;
    $db->{$apple_id} = { %{$db->{$apple_id}}, %$data };
    return PAGI::Response->json($db->{$apple_id});
}

async sub delete_apple($request) {
    my $db = apples_db($request);
    my $apple_id = $request->path_param('apple_id');
    return PAGI::Response->json(
        { error => 'Apple not found' }, status => 404,
    ) unless exists $db->{$apple_id};

    my $deleted_apple = delete $db->{$apple_id};
    return PAGI::Response->json({
        success => \1,
        deleted => $deleted_apple,
    });
}

compose(
    routes => [
        route('/' => PAGI::Pages->welcome,
            name => 'home', desc => 'PAGI welcome page'),
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
            desc => 'Apples API namespace'),
    ],
    lifespan => {
        startup => \&startup,
    },
);
```

The handlers above use the compact delegated functions. A longer handler can
keep the equally explicit facade form:

```perl
my $urls = url($request);
my $self = $urls->url_for('read', { apple_id => $apple_id });
my $edit = $urls->url_for('update', { apple_id => $apple_id });
```

Each call is local to this request and reuses the Resolver already installed
in its routing frame; it does not recompile the route graph.

The final wildcard considered during design is intentionally absent. Each
Router already renders negotiated Not Found and Method Not Allowed outcomes. A
wildcard route would be a real match, so it could hide a method mismatch such
as `PATCH /apples` and incorrectly turn the 405 into a 404.

| Starlette | PAGI::Tools |
| --- | --- |
| `Starlette(routes=[...])` | `compose(routes => [...])`, retained as a component object |
| `Route(...)` | `route(...)` leaves inside one `mount('/apples', routes => [...])` child Router |
| `Request` | `PAGI::Request` passed directly to the handler |
| `JSONResponse(...)` | `PAGI::Response->json(...)` |
| `{apple_id:int}` | `{apple_id:&Int}` from `Types::Standard` |
| converter validates and converts | constraint validates without coercion |
| root application default 404/405 | selected root or child Router renders Not Found/Method Not Allowed |

These APIs are related, but they are not identical. The PAGI mount creates an
explicit namespace boundary that the flat Python route list does not have.
Perl imports also make ownership visible: `PAGI::Response` owns response
construction and `PAGI::Routing::URL` owns reverse routing rather than making
either capability intrinsic to Request. A broader Response redesign remains a
separate deferred project; this example uses the current explicit factory.
Starlette's `int` converter places an integer in `request.path_params`; PAGI's
`Int` constraint validates the decoded path capture but leaves the original
scalar for the handler.

That distinction is visible at the boundary. `/apples/999` matches a resource
route and returns the handler's JSON `{ "error": "Apple not found" }`.
`/apples/not-an-int` fails the route constraint, while `/elsewhere` matches no
route at all; the apples child and root Router render those misses at their
respective boundaries. The child also owns `PATCH /apples` and its
`Allow: GET, HEAD, POST`. Both `/apples` and `/apples/` reach the child `/`
index. `Types::Standard::Int` accepts `-1`, so `/apples/-1` reaches the handler
and returns the application JSON rather than a routing response.

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
