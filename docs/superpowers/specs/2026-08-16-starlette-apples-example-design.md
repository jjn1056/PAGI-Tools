# Starlette Apples Comparison Example Design

**Date:** 2026-08-16

## Purpose

Add one small, self-contained PAGI application that translates the supplied
Starlette apples CRUD application closely enough to compare the two shapes.
The example is diagnostic as well as instructional: it should make ceremony,
ownership, response construction, path typing, and routing outcomes easy to
compare without hiding PAGI behind an application-specific framework.

This work adds an example only. It does not change routing, Compose, Context,
Pages, middleware, or server behavior.

## Work Map

| Repository | Ticket | Branch | Base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | Starlette apples comparison example | `feat/starlette-apples-example` | `main@3c2d101e78ffb3de5a75898ff3cad5ed8ddaaf25` | This design/plan, `examples/starlette-apples`, its integration test, and the examples index | Examples, documentation, and tests only | `origin/feat/starlette-apples-example` (do not push without request) |

## Files and Responsibilities

### `examples/starlette-apples/app.pl`

One executable Perl 5.40 application. Keeping the database, handlers, route
declarations, and Compose boundary together is deliberate: the supplied
Starlette application is one file, and splitting the PAGI version into classes
would make the comparison about project layout instead of framework shape.

### `examples/starlette-apples/README.md`

Contains the supplied Python program verbatim, followed by the PAGI run
instructions, curl examples, and a short comparison of corresponding concepts.
The README must distinguish observed shipped behavior from design opinion.

### `t/integration-starlette-apples.t`

Executes the real example through `PAGI::Test::Client`. It verifies public HTTP
behavior rather than grepping implementation text. On Perl older than 5.40 it
skips before loading the example.

### `examples/README.md`

Adds the new runnable example to the repository index without reorganizing
unrelated entries.

## Application Shape

The example uses the functional declarative frontend and one explicit routing
namespace:

```perl
use v5.40;
use Future::AsyncAwait;
use JSON::MaybeXS ();
use List::Util qw(max);
use Types::Standard qw(Int);

use PAGI::Compose qw(compose);
use PAGI::Pages;
use PAGI::Routing qw(router route mount);

my $apples = router(
    routes => [
        route('/' => \&list_apples,  methods => ['GET']),
        route('/' => \&create_apple, methods => ['POST']),
        route('/{apple_id:&Int}' => \&read_apple,
            methods => ['GET']),
        route('/{apple_id:&Int}' => \&update_apple,
            methods => ['PUT']),
        route('/{apple_id:&Int}' => \&delete_apple,
            methods => ['DELETE']),
    ],
);

compose(
    routes => [
        route('/' => PAGI::Pages->welcome),
        mount('/apples', router => $apples, name => 'apples'),
    ],
)->to_app;
```

The final implementation may add route names and descriptions when they make
the declarations easier to inspect, but it must not add abstraction wrappers,
base classes, controller packages, or a second construction style.

## Data and Handlers

The lexical `%apples_db` starts with the two supplied records. It remains
process-local mutable demo data; persistence, concurrency control, schema
validation, and production storage are explicitly out of scope.

All five CRUD handlers are `async sub` declarations with Perl 5.40 signatures,
matching the visual rhythm of the Python handlers even where a handler does
not need to await anything.

- `list_apples($c)` returns an array of records ordered by numeric database key.
  Perl hash iteration order must not leak into the public response.
- `read_apple($c)` returns the selected record or application JSON
  `{ "error": "Apple not found" }` with status 404.
- `create_apple($c)` awaits `$c->request->json`, assigns one greater than the
  current maximum key, stores the record, and returns it with status 201. As in
  the Python dict expression, a caller-supplied `id` member appears after the
  generated member and therefore wins inside the stored response value; this
  example deliberately does not add schema policy absent from the source.
- `update_apple($c)` returns the same application-owned missing-resource 404 or
  awaits JSON, merges the supplied members into the record, and returns it.
- `delete_apple($c)` returns the same missing-resource 404 or removes the record
  and returns `{ "success": true, "deleted": ... }`. The boolean is a real JSON
  boolean, not the number `1`.

The handlers use `$c->json(...)` rather than constructing `PAGI::Response`
directly. The missing-resource 404 is domain output because the typed resource
route matched and the database lookup failed.

## Path Constraint Semantics

The application imports `Int` from the correctly named CPAN module
`Types::Standard` and declares `/{apple_id:&Int}`. The provider is resolved
once while constructing each route and normalized to the Router's internal
constraint predicate.

PAGI constraints validate decoded captures and do not coerce them. A handler
therefore receives the original scalar text. Perl hash lookup makes explicit
integer coercion unnecessary here. The README must contrast this with
Starlette's converter path, which converts a matched value before placing it in
`request.path_params`.

`Types::Standard::Int` accepts negative integer text. Consequently
`/apples/-1` reaches `read_apple` and returns the application-owned
`Apple not found` JSON, while `/apples/not-an-int` fails the constraint and
becomes a routing miss. The integration test pins this distinction because it
is a useful comparison finding, not an incidental implementation detail.

## Routing Outcomes and the Rejected Wildcard

There is no final `/*path` route.

Compose already installs routing-aware NotFound and MethodNotAllowed failsafes.
The mounted child Router publishes its local evidence into the request-local
trace, and the outer Compose boundary renders the result when no inner
middleware or handler responds.

The observable outcomes are:

| Request | Owner | Result |
| --- | --- | --- |
| `GET /` | Pages endpoint | Negotiated 200 Welcome page |
| `GET /apples` | `list_apples` | Application JSON list |
| `GET /apples/999` | `read_apple` | Application JSON 404, `Apple not found` |
| `GET /apples/not-an-int` | Compose NotFound | Negotiated stock routing 404 |
| `PATCH /apples` | Compose MethodNotAllowed | Negotiated stock 405 and `Allow: GET, HEAD, POST` |
| `GET /elsewhere` | Compose NotFound | Negotiated stock routing 404 |

The originally requested final custom catchall was rejected after review. An
all-method wildcard is a later FULL match and hides earlier method PARTIAL
evidence, turning a legitimate 405 such as `PATCH /apples` into 404. A GET-only
wildcard makes unknown non-GET requests method mismatches against the wildcard.
An ordinary route therefore cannot mean "run only if routing as a whole found
nothing." Compose already owns that routing outcome correctly.

Namespace-specific NotFound or MethodNotAllowed middleware remains possible,
but this first comparison example does not install it because it does not need
a representation or policy different from the application default.

## README Comparison

The README begins with the supplied Starlette program in a fenced Python block,
unchanged. It then points to `app.pl` and compares:

| Starlette | PAGI::Tools |
| --- | --- |
| `Starlette(routes=[...])` | `compose(routes => [...])->to_app` |
| `Route(...)` | `route(...)` plus the explicit `/apples` `mount(...)` boundary |
| `Request` | HTTP `$c` Context and `$c->request` |
| `JSONResponse(...)` | `$c->json(...)` |
| `{apple_id:int}` | `{apple_id:&Int}` using `Types::Standard` |
| converter validates and converts | constraint validates without coercion |
| application default 404/405 | Compose default NotFound/MethodNotAllowed |

The comparison must not claim that the two systems are identical. In
particular, the PAGI mount is an intentional namespace boundary not present in
the flat supplied Python declarations, and the path-typing semantics differ.

The README includes commands for starting the app and exercising welcome,
list, read, create, update, delete, missing resource, invalid typed path,
unknown route, and wrong method behavior.

## Test Design

The integration test loads the application once and performs one ordered CRUD
scenario so mutable demo state is deterministic:

1. `GET /` returns the Pages welcome HTML.
2. `GET /apples` returns Gala and Honeycrisp in numeric ID order.
3. `GET /apples/1` returns Gala.
4. `GET /apples/999` returns application JSON 404 with `Apple not found`.
5. `GET /apples/not-an-int` with problem JSON negotiation returns Compose's
   routing 404 and never the application error shape.
6. `GET /apples/-1` reaches the typed route and returns the application error
   shape, demonstrating validation without conversion or unsigned semantics.
7. `PATCH /apples` returns 405 with `Allow: GET, HEAD, POST`.
8. `POST /apples` creates ID 3 and returns 201.
9. `PUT /apples/3` updates and returns the stored record.
10. `DELETE /apples/3` returns a real JSON true value and the deleted record.
11. A subsequent `GET /apples/3` returns the application missing-resource 404.
12. `GET /elsewhere` with problem JSON negotiation returns Compose's routing
    404.

The test asserts status, relevant headers/content type, and literal response
data. It does not assert source formatting or reproduce Pages/Router unit tests.

## Non-Goals

- No changes to PAGI public APIs or routing semantics.
- No custom global or `/apples` fallback middleware in this first example.
- No final wildcard route.
- No persistence, request schema, model class, dependency injection, or locking.
- No WebSocket, SSE, lifespan callback, static files, reverse routing, or
  middleware unrelated to routing outcomes.
- No attempt to make the Python and Perl line counts artificially equal.
