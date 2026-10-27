# A classic PAGI application in a module

`RawApp` is a `PAGI::App` whose `call` is the PAGI application itself,
called with `($scope, $receive, $send)`. There is no Compose and no router:
it reads the scope and sends the protocol's events directly. This is the
shape for an application that speaks the protocol itself and has a `lib/`
of its own; a Compose application subclasses `PAGI::App::Compose` instead.

Requires Perl 5.40.

```
pagi-server -I examples/raw-app/lib --app examples/raw-app/lib/RawApp.pm --port 5000
curl -i localhost:5000/
curl -i localhost:5000/hits          # counts up
websocat ws://localhost:5000/echo
```

or one request from the shell, with no server (the status and headers on
STDERR, the body on STDOUT; lifespan runs around it):

```
perl -I examples/raw-app/lib examples/raw-app/lib/RawApp.pm GET /hits
```

## What it handles

`call` dispatches on `$scope->{type}`:

- **lifespan**: at `lifespan.startup` it puts `{ count => 0 }` in the shared
  state. Each request's state is a shallow copy of it, so the count lives
  inside that container: a top-level value a request changed would change
  only its own copy.
- **http**: `/` and `/hits` for GET (and HEAD, whose body the server does not
  send); any other method is a 405 with `Allow`, any other path a 404.
- **websocket**: `/echo` accepts and echoes each text or bytes frame until
  the client disconnects; any other path is refused before
  `websocket.accept`, with a plain 404 response.
- **sse**: refused the same way, before `sse.start`.

`lib/RawApp/Send.pm` holds the two things it does more than once: reading
a request body to its end, and sending a whole text response, as UTF-8
bytes with its `Content-Length`.

The module ends with `__PACKAGE__->run_if_script` in place of `1;`, so
`pagi-server --app` loads it as an application and `perl` runs it as a
program. `t/example-raw-app.t` drives every case above through
`PAGI::Test::Client`, and the one request from the shell.
