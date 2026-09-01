# Declarative routing

This is a small executable `PAGI::Routing` application. It demonstrates the
ordinary shape without turning the example into a framework:

- handlers loaded normally from `MyApp::Routes::Home` and passed as fully
  qualified coderefs, receiving `PAGI::Request` directly;
- a separately configured `/api` Router mounted with `app =>`, whose local
  `api` name segment composes the absolute logical address `/api/item`;
- a numeric path constraint;
- one pure route middleware factory captured in an explicit inspectable description;
- distinct root and API Router `http_default` endpoints rendered through
  `PAGI::Pages`, plus the child Router's authoritative stock 405 and `Allow`;
- absolute slash-addressed `path_for($request, ...)` and request-aware
  `url_for($request, ...)` from `PAGI::Routing::URL` (both return strings and
  perform no protocol I/O); and
- a final `compose(router => $routing)` expression, so `app.pl` evaluates to an
  inspectable `PAGI::Compose` object that a conforming server compiles once
  through its `to_app` method.

Each selected Router owns exhaustion at its own boundary. An API constraint
miss receives `No API route matched`; an unknown root path receives
`No root route matched`. A method mismatch never invokes `http_default`: the
API Router renders its negotiated stock Method Not Allowed response with
`Allow: GET, HEAD`. Compose adds application error, completion, and lifespan
safety without interpreting those Router outcomes.

Run it from the distribution root:

```sh
pagi-server examples/declarative-routing/app.pl --port 5000
```

Then try:

```sh
curl -i http://127.0.0.1:5000/
curl -i http://127.0.0.1:5000/api/items/42
curl -i -H 'Accept: application/problem+json' \
  -X POST http://127.0.0.1:5000/api/items/42
curl -i -H 'Accept: application/problem+json' \
  http://127.0.0.1:5000/missing
```

The example stays HTTP-only on purpose. The complete `websocket`, `sse`, raw
application, `mount(app => ...)`, `mount(routes => ...)`, relative
reverse-routing, query/fragment, and matched-route metadata recipes live in
`PAGI::Routing` and `PAGI::Tools::Cookbook`.
