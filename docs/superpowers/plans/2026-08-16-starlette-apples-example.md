# Starlette Apples Comparison Example Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a runnable Perl 5.40 PAGI apples CRUD example that can be compared directly with the supplied Starlette application.

**Architecture:** A single `app.pl` owns the in-memory data, five Context handlers, an `/apples` child Router, a Pages welcome endpoint, and the outer Compose boundary. Compose supplies stock routing 404/405 outcomes; handler-owned resource misses remain application JSON.

**Tech Stack:** Perl 5.40 signatures, Future::AsyncAwait, Types::Standard/Type::Tiny, PAGI::Routing, PAGI::Compose, PAGI::Pages, PAGI::Test::Client, Test2::V0.

## Global Constraints

- The example requires Perl 5.40 or newer and uses signatures throughout its declared subs.
- Import `Int` from `Types::Standard`; declare typed paths as `/{apple_id:&Int}`.
- Keep the application in one file; add no controllers, base classes, roles, or helper framework.
- Do not add a wildcard route or custom routing-fallback middleware.
- Compose owns stock routing 404/405 responses and the authoritative 405 `Allow` field.
- Preserve the supplied Python source verbatim in the example README.
- Keep changes to the design/plan, `examples/starlette-apples`, `t/integration-starlette-apples.t`, and `examples/README.md`.
- Run the full suite once at the final gate; this repository is not campaigns-api.

## Work Map

| Repository | Ticket | Branch | Base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | Starlette apples comparison example | `feat/starlette-apples-example` | `main@3c2d101e78ffb3de5a75898ff3cad5ed8ddaaf25` | Design/plan, `examples/starlette-apples`, integration test, examples index | Examples, documentation, and tests only | `origin/feat/starlette-apples-example` (do not push without request) |

---

### Task 1: Implement the apples application through a failing integration test

**Files:**
- Create: `t/integration-starlette-apples.t`
- Create: `examples/starlette-apples/app.pl`

**Interfaces:**
- Consumes: `PAGI::Pages->welcome`, `route($path => $handler, methods => \@methods)`, `mount('/apples', router => $router, name => 'apples')`, `$c->request->json`, and `$c->json($data, %options)`.
- Produces: one Compose-rooted native PAGI coderef with welcome and mutable apples CRUD behavior.

- [ ] **Step 1: Write the failing integration test**

Create `t/integration-starlette-apples.t`:

```perl
use strict;
use warnings;

use Test2::V0;
use FindBin qw($Bin);
use JSON::PP ();
use lib "$Bin/../lib";
use PAGI::Test::Client;

if ($] < 5.040) {
    plan skip_all => 'examples/starlette-apples requires Perl 5.40';
    exit 0;
}

my $app_file = "$Bin/../examples/starlette-apples/app.pl";
my $app = do $app_file;
my $load_error = $@ || $!;
ok(!$load_error, 'Starlette comparison example loads cleanly')
    or diag($load_error);
is(ref($app), 'CODE', 'example returns one Compose-rooted PAGI app');

subtest 'welcome, routing outcomes, and apples CRUD' => sub {
    plan skip_all => 'example did not load' unless ref($app) eq 'CODE';

    my $client = PAGI::Test::Client->new(app => $app);

    my $welcome = $client->get('/', headers => { Accept => 'text/html' });
    is($welcome->status, 200, 'welcome route responds');
    like($welcome->text, qr/<title>200 Welcome to PAGI<\/title>/,
        'root uses the shared Pages welcome endpoint');

    my $list = $client->get('/apples');
    is($list->status, 200, 'apple collection responds');
    is($list->json, [
        { id => 1, name => 'Gala', color => 'Red/Yellow' },
        { id => 2, name => 'Honeycrisp', color => 'Rosy Red' },
    ], 'collection preserves numeric ID order');

    my $gala = $client->get('/apples/1');
    is($gala->status, 200, 'apple detail responds');
    is($gala->json,
        { id => 1, name => 'Gala', color => 'Red/Yellow' },
        'detail returns the selected apple');

    my $missing_apple = $client->get('/apples/999');
    is($missing_apple->status, 404,
        'missing database record is an application 404');
    is($missing_apple->content_type, 'application/json; charset=utf-8',
        'resource miss retains the application JSON representation');
    is($missing_apple->json, { error => 'Apple not found' },
        'resource miss retains the application error shape');

    my $invalid_id = $client->get('/apples/not-an-int',
        headers => { Accept => 'application/problem+json' });
    is($invalid_id->status, 404,
        'failed Int constraint is a routing 404');
    is($invalid_id->content_type, 'application/problem+json',
        'routing miss uses Compose negotiation');
    is($invalid_id->json->{title}, 'Not Found',
        'routing miss uses the stock Pages title');
    ok(!exists $invalid_id->json->{error},
        'routing miss never reaches the application error branch');

    my $negative_id = $client->get('/apples/-1');
    is($negative_id->status, 404,
        'Types::Standard Int accepts negative integer text');
    is($negative_id->json, { error => 'Apple not found' },
        'negative integer reaches the resource handler unchanged');

    my $wrong_method = $client->patch('/apples',
        headers => { Accept => 'application/problem+json' });
    is($wrong_method->status, 405,
        'known collection with unsupported method is 405');
    is($wrong_method->header('Allow'), 'GET, HEAD, POST',
        'Compose preserves the child Router method union');
    is($wrong_method->json->{title}, 'Method Not Allowed',
        'Compose renders the stock method response');

    my $created = $client->post('/apples', json => {
        name  => 'Fuji',
        color => 'Red',
    });
    is($created->status, 201, 'create returns 201');
    is($created->json,
        { id => 3, name => 'Fuji', color => 'Red' },
        'create assigns the next numeric ID');

    my $updated = $client->put('/apples/3', json => {
        color => 'Crimson',
    });
    is($updated->status, 200, 'update responds');
    is($updated->json,
        { id => 3, name => 'Fuji', color => 'Crimson' },
        'update merges supplied members into the stored record');

    my $deleted = $client->delete('/apples/3');
    is($deleted->status, 200, 'delete responds');
    my $deleted_json = $deleted->json;
    ok(JSON::PP::is_bool($deleted_json->{success}),
        'delete success is a real JSON boolean');
    ok($deleted_json->{success}, 'delete success is true');
    is($deleted_json->{deleted},
        { id => 3, name => 'Fuji', color => 'Crimson' },
        'delete returns the removed record');

    my $after_delete = $client->get('/apples/3');
    is($after_delete->status, 404,
        'deleted record is no longer available');
    is($after_delete->json, { error => 'Apple not found' },
        'post-delete miss remains application output');

    my $unknown = $client->get('/elsewhere',
        headers => { Accept => 'application/problem+json' });
    is($unknown->status, 404, 'unknown root path uses Compose NotFound');
    is($unknown->content_type, 'application/problem+json',
        'root routing miss negotiates problem JSON');
    is($unknown->json->{title}, 'Not Found',
        'root routing miss uses the stock Pages response');
};

done_testing;
```

- [ ] **Step 2: Run the test and verify the intended RED failure**

Run:

```bash
prove -lv t/integration-starlette-apples.t
```

Expected: FAIL because `examples/starlette-apples/app.pl` does not exist; the load assertion reports that missing file.

- [ ] **Step 3: Implement the one-file application**

Create `examples/starlette-apples/app.pl`:

```perl
#!/usr/bin/env perl
use v5.40;

use Future::AsyncAwait;
use JSON::MaybeXS ();
use List::Util qw(max);
use Types::Standard qw(Int);

use PAGI::Compose qw(compose);
use PAGI::Pages;
use PAGI::Routing qw(router route mount);

my %apples_db = (
    1 => { id => 1, name => 'Gala',       color => 'Red/Yellow' },
    2 => { id => 2, name => 'Honeycrisp', color => 'Rosy Red' },
);

async sub list_apples($c) {
    my @ids = sort { $a <=> $b } keys %apples_db;
    return $c->json([map { $apples_db{$_} } @ids]);
}

async sub read_apple($c) {
    my $apple_id = $c->path_param('apple_id');
    my $apple = $apples_db{$apple_id};
    return $c->json($apple) if $apple;
    return $c->json({ error => 'Apple not found' }, status => 404);
}

async sub create_apple($c) {
    my $data = await $c->request->json;
    my $new_id = max(0, keys %apples_db) + 1;
    my $new_apple = { id => $new_id, %$data };
    $apples_db{$new_id} = $new_apple;
    return $c->json($new_apple, status => 201);
}

async sub update_apple($c) {
    my $apple_id = $c->path_param('apple_id');
    return $c->json({ error => 'Apple not found' }, status => 404)
        unless exists $apples_db{$apple_id};

    my $data = await $c->request->json;
    $apples_db{$apple_id} = {
        %{$apples_db{$apple_id}},
        %$data,
    };
    return $c->json($apples_db{$apple_id});
}

async sub delete_apple($c) {
    my $apple_id = $c->path_param('apple_id');
    return $c->json({ error => 'Apple not found' }, status => 404)
        unless exists $apples_db{$apple_id};

    my $deleted_apple = delete $apples_db{$apple_id};
    return $c->json({
        success => JSON::MaybeXS::true(),
        deleted => $deleted_apple,
    });
}

my $apples = router(
    routes => [
        route('/' => \&list_apples,
            methods => ['GET'], name => 'list', desc => 'List apples'),
        route('/' => \&create_apple,
            methods => ['POST'], name => 'create', desc => 'Create an apple'),
        route('/{apple_id:&Int}' => \&read_apple,
            methods => ['GET'], name => 'read', desc => 'Read an apple'),
        route('/{apple_id:&Int}' => \&update_apple,
            methods => ['PUT'], name => 'update', desc => 'Update an apple'),
        route('/{apple_id:&Int}' => \&delete_apple,
            methods => ['DELETE'], name => 'delete', desc => 'Delete an apple'),
    ],
    desc => 'Apples API',
);

compose(
    routes => [
        route('/' => PAGI::Pages->welcome,
            name => 'home', desc => 'PAGI welcome page'),
        mount('/apples',
            router => $apples,
            name   => 'apples',
            desc   => 'Apples API namespace'),
    ],
)->to_app;
```

- [ ] **Step 4: Run the integration test and verify GREEN**

Run:

```bash
prove -lv t/integration-starlette-apples.t
```

Expected: PASS. The 405 must report exactly `Allow: GET, HEAD, POST`; the invalid typed path must use problem JSON; the negative ID must use the application JSON shape.

- [ ] **Step 5: Commit the tested application**

```bash
git add examples/starlette-apples/app.pl t/integration-starlette-apples.t
git commit -m "docs: add Starlette apples comparison app"
```

### Task 2: Document the Python comparison and index the example

**Files:**
- Create: `examples/starlette-apples/README.md`
- Modify: `examples/README.md`

**Interfaces:**
- Consumes: the runnable `examples/starlette-apples/app.pl` from Task 1.
- Produces: the verbatim Python reference, explicit conceptual mappings, and runnable request examples.

- [ ] **Step 1: Write the comparison README**

Create `examples/starlette-apples/README.md` with these sections and facts:

1. Title it `# Starlette apples comparison` and state that the example exists to compare the current PAGI::Tools shape with its primary inspiration.
2. Under `## Original Starlette application`, include this exact source without corrections:

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

3. Under `## PAGI application`, point to [`app.pl`](app.pl), explain the added `/` Pages welcome endpoint, and state that the final wildcard requested during design was intentionally removed because Compose already renders routing-aware 404/405 outcomes.
4. Include this comparison table:

```markdown
| Starlette | PAGI::Tools |
| --- | --- |
| `Starlette(routes=[...])` | `compose(routes => [...])->to_app` |
| `Route(...)` | `route(...)` and an explicit `/apples` `mount(...)` boundary |
| `Request` | HTTP `$c` Context and `$c->request` |
| `JSONResponse(...)` | `$c->json(...)` |
| `{apple_id:int}` | `{apple_id:&Int}` from `Types::Standard` |
| converter validates and converts | constraint validates without coercion |
| application default 404/405 | Compose default NotFound/MethodNotAllowed |
```

5. Explain that `/apples/999` is handler-owned application JSON, while `/apples/not-an-int` and `/elsewhere` are routing misses handled by Compose. Explain that `Types::Standard::Int` accepts `-1`, so `/apples/-1` reaches the handler with the original scalar.
6. Under `## Run`, include:

```bash
pagi-server --app examples/starlette-apples/app.pl --port 5000
```

7. Under `## Try it`, include working `curl` commands for `GET /`, list, read, create, update, delete, `/apples/999`, `/apples/not-an-int`, `PATCH /apples`, and `/elsewhere`. JSON write requests must include `Content-Type: application/json`; problem-response demonstrations must include `Accept: application/problem+json`.
8. End by stating that the example is intentionally process-local mutable demo data without persistence, schema validation, or locking.

- [ ] **Step 2: Add the example to the repository index**

In `examples/README.md`:

- Update the Perl 5.40 requirement bullet to name both `15-large-application` and `starlette-apples`.
- Append list item 19: `` `starlette-apples` - Perl 5.40 single-file apples CRUD application for direct comparison with the original Starlette version, using `Types::Standard` path constraints and Compose-owned routing outcomes ``.

- [ ] **Step 3: Verify the documentation against the executable behavior**

Run the commands below and compare the README claims to the real responses:

```bash
prove -lv t/integration-starlette-apples.t
perl -Ilib -c examples/starlette-apples/app.pl
```

Expected: integration PASS and syntax OK. No README curl command may describe a route, method, body, or content type contradicted by the integration test.

- [ ] **Step 4: Commit the documentation**

```bash
git add examples/starlette-apples/README.md examples/README.md
git commit -m "docs: compare PAGI apples app with Starlette"
```

### Task 3: Final verification and scope audit

**Files:**
- Verify: all files owned by this plan.
- Modify: `docs/superpowers/plans/2026-08-16-starlette-apples-example.md` only to mark completed checklist items.

**Interfaces:**
- Consumes: the tested application and human documentation from Tasks 1-2.
- Produces: a clean example-only branch ready for integration.

- [ ] **Step 1: Run focused behavior and syntax gates**

```bash
prove -lv t/integration-starlette-apples.t
perl -Ilib -c examples/starlette-apples/app.pl
perl -Ilib -c t/integration-starlette-apples.t
```

Expected: PASS and syntax OK under Perl 5.40 or newer.

- [ ] **Step 2: Run the complete repository suite once**

```bash
prove -lr t/
```

Expected: all tests pass, with only the existing documented `RELEASE_TESTING` skip. Do not repeat the suite.

- [ ] **Step 3: Audit scope and whitespace**

```bash
git diff --check main...HEAD
git diff --name-only main...HEAD
git status --short
```

Expected: only the design, plan, new example directory, integration test, and examples index appear; tracked status is clean.

- [ ] **Step 4: Record completed plan state**

Change every completed checklist marker in this plan from `[ ]` to `[x]`, stage it with `git add -f`, and commit:

```bash
git add -f docs/superpowers/plans/2026-08-16-starlette-apples-example.md
git commit -m "test: record Starlette apples verification"
```
