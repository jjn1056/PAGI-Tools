# Endpoint lifecycles

One spelling at every route, `endpoint('Class', %args)`, and three ways an
endpoint class can be built. The caller never knows which; the class's
author decides.

| Class | How it is built | It answers |
| --- | --- | --- |
| `NotesApp::Note`, `NotesApp::Watch` | no `BUILD_APP`: `->new(%args)` for each request, or each WebSocket connection | one request, or one connection |
| `NotesApp::Notes` | `BUILD_APP` returns a builder, which runs per request and fills `current_user` from it | one request |
| `NotesApp::Health` | `BUILD_APP` returns `->new(version => '1.0')`, built once, when the application is built | every request (its hit counter is shared, per worker) |

## The contract

`endpoint('Class', %args)` loads `Class` (a class already defined, as in a
single-file app, needs no file) and then:

- with no `BUILD_APP`, calls `Class->new(%args)` for each request (each
  connection, for WebSocket and SSE). The object belongs to that request, so
  it may keep that request's state on `$self`;
- otherwise calls `Class->BUILD_APP(%args)` once:
  - an object with `to_app` (an endpoint, a Response, any app object) is put
    at the route as it is, and answers every request, concurrently. This is
    how a class shares one object:

    ```perl
    sub BUILD_APP ($class, %args) { $class->new(%args) }
    ```

  - a coderef is a builder: it is called with a `PAGI::Request` for each
    request (each connection, for WebSocket and SSE) and returns the app
    object that answers it. It may return any app object, a refusal
    included:

    ```perl
    sub BUILD_APP ($class, %args) {
        return sub ($request) {
            return response('Text', 'no token', status => 403)
                unless $request->header('X-Token');
            return $class->new(%args);
        };
    }
    ```

The builder reads only what the request already carries (headers, cookies,
query and path parameters, state). The WebSocket builder gets a Request too,
not the WebSocket: the object it builds accepts, sends and closes.

`endpoint()` runs when the application is built (in `NotesApp`'s `routes`),
before lifespan startup, so the store
built at startup is reached at request time through `$request->state` and
`$websocket->state`.

## Moo and Moose

The framework calls only your `new` or `BUILD_APP`, so Moo's `required` and
`default` work. `NotesApp::Notes` requires `current_user`, and a builder that
forgot it fails on that request; `NotesApp::Health` requires `version`, and
because its object is built once, a missing one fails when the application
is built. A
Moose class extending an Endpoint base needs `use MooseX::NonMoose` after
`use Moose`; `endpoint()` refuses one without it.

## Methods

`PUT /notes` is a 405 with `Allow: GET, HEAD, OPTIONS, POST`. The Router
answers it from `NotesApp::Notes->allowed_methods`, asked of the class, so no
object is built for a method the class does not have. `OPTIONS` reaches the
endpoint, which answers 204 with `Allow`; `HEAD` is answered by `get`.

## Run

The application is `lib/NotesApp.pm`, a `PAGI::App::Compose`:

```bash
pagi-server -I examples/endpoint-lifecycle/lib \
    --app examples/endpoint-lifecycle/lib/NotesApp.pm --port 5000
```

```text
$ curl -i -H 'X-User: alice' -H 'Content-Type: application/json' -d '{"text":"buy milk"}' localhost:5000/notes
HTTP/1.1 201 Created
Location: /notes/1
Content-Type: application/json
content-length: 43
date: Mon, 12 Oct 2026 16:55:19 GMT
Server: PAGI::Server/0.003000

{"author":"alice","id":1,"text":"buy milk"}

$ curl -i localhost:5000/notes
HTTP/1.1 200 OK
X-Page-Size: 50
Content-Type: application/json
content-length: 45
date: Mon, 12 Oct 2026 16:55:19 GMT
Server: PAGI::Server/0.003000

[{"author":"alice","id":1,"text":"buy milk"}]

$ curl -i localhost:5000/notes/1
HTTP/1.1 200 OK
Content-Type: application/json
content-length: 43
date: Mon, 12 Oct 2026 16:55:19 GMT
Server: PAGI::Server/0.003000

{"author":"alice","id":1,"text":"buy milk"}

$ curl -i -X PUT localhost:5000/notes
HTTP/1.1 405 Method Not Allowed
Content-Type: text/plain; charset=utf-8
content-length: 18
allow: GET, HEAD, OPTIONS, POST
date: Mon, 12 Oct 2026 16:55:19 GMT
Server: PAGI::Server/0.003000

Method Not Allowed

$ curl -i localhost:5000/health
HTTP/1.1 200 OK
Content-Type: application/json
content-length: 40
date: Mon, 12 Oct 2026 16:55:19 GMT
Server: PAGI::Server/0.003000

{"hits":1,"status":"ok","version":"1.0"}

$ curl -i localhost:5000/health
HTTP/1.1 200 OK
Content-Type: application/json
content-length: 40
date: Mon, 12 Oct 2026 16:55:19 GMT
Server: PAGI::Server/0.003000

{"status":"ok","version":"1.0","hits":2}
```

The curl lines are in `lib/NotesApp.pm`'s header. `t/example-endpoint-lifecycle.t`
proves the three lifecycles, including two overlapping POSTs that each answer
with their own user, and two requests to `NotesApp::Note` that each keep their
own note on `$self`.
