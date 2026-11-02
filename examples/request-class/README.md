# An Application's Request Class

`NotesApp::Request` is a `PAGI::Request` subclass with two helpers the
application uses everywhere: `$request->notes`, the store built at startup,
and `$request->page`, the `?page=` number checked once. One middleware line
puts the class in the scope, and every handler below it receives one:

```perl
compose(
    middleware => [middleware('RequestClass', class => 'NotesApp::Request')],
    routes => [...],
);
```

## Run

```bash
pagi-server --app examples/request-class/app.pl --port 5000
```

## What it shows

- **A plain route.** `route('/notes' => \&list_notes)`: the bare handler
  gets a `NotesApp::Request`, with no `request_response` wrapper.
- **An Endpoint::HTTP class.** `NotesApp::Note`'s `get` and `delete`
  methods get one too.
- **A mount.** `/admin/stats` is a route inside `mount('/admin', ...)`: the
  class travels in the scope, so the mount inherits it.

## Where it reaches, and what to watch

- A misspelt class (`class => 'NotesApp::Reqeust'`) dies when the
  application is built, not on the first request.
- RequestClass sets the scope key `pagi.request.factory`. Everything below
  it that hands a Request to your code uses it: route and `http_default`
  handlers, Endpoint::HTTP methods, `refuse` handlers, `deny`/`decline`
  handlers on WebSocket and SSE routes, an ErrorHandler `handler` listed
  after RequestClass. An Authentication backend gets a
  `PAGI::HTTPConnection`, not the class.
- Middleware listed before RequestClass does not see it. List it first.
- An application mounted below it gets the class too, even one written by
  someone else.
- The class's constructor is also called for WebSocket and SSE scopes (a
  `deny` handler gets one), so do not make `new` HTTP-only.
- `request_response($handler, request_factory => ...)` still wins for its
  one handler.
- The route tree does not show the class: it is set by middleware, not
  declared at a route.

For one or two helpers, a function that takes the request is simpler and
needs no middleware: `NoteStore->for_request($request)` in
`examples/gut-check/02-notes-resource.pl`.

## Without the middleware

RequestClass is a convenience. A hand-written middleware sets the same key:

```perl
my $notes_requests = middleware(sub ($app) {
    async sub ($scope, $receive, $send) {
        await $app->(clone_scope($scope, {
            'pagi.request.factory' => sub ($scope, $receive) { NotesApp::Request->new($scope, $receive) },
        }), $receive, $send);
    }
});
```

## Try

```bash
curl -i -X POST localhost:5000/notes -d '{"text":"buy milk"}'
curl -i 'localhost:5000/notes?page=1'
curl -i 'localhost:5000/notes?page=x'      # page 1: not a number
curl -i localhost:5000/notes/1
curl -i localhost:5000/admin/stats
curl -i -X DELETE localhost:5000/notes/1
```

## See also

- `PAGI::Middleware::RequestClass`
- `PAGI::Routing::RequestResponse`, `request_factory` for one handler
- `PAGI::Tools::Cookbook`, "An Application's Request Class"
- `examples/framework-on-tools`, a framework whose Request subclass arrives
  the same way
