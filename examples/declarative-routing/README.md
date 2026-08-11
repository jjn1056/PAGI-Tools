# Declarative routing

This is a small executable `PAGI::Routing` application. It demonstrates the
ordinary shape without turning the example into a framework:

- handlers loaded normally from `MyApp::Routes::Home` and passed as fully
  qualified coderefs;
- an inline `/api` mount whose local `api` name segment composes the absolute
  logical address `/api/item`;
- a numeric path constraint;
- one bare pure route middleware factory, normalized to an inspectable description;
- custom 404 and 405 handlers;
- absolute slash-addressed `path_for` and request-aware `url_for` generation
  (both return strings and perform no protocol I/O); and
- a final `$routing->to_app` expression, so `app.pl` evaluates to the native
  PAGI application coderef a server expects.

Run it from the distribution root:

```sh
pagi-server examples/declarative-routing/app.pl --port 5000
```

Then try:

```sh
curl -i http://127.0.0.1:5000/
curl -i http://127.0.0.1:5000/api/items/42
curl -i -X POST http://127.0.0.1:5000/api/items/42
curl -i http://127.0.0.1:5000/missing
```

The example stays HTTP-only on purpose. The complete `websocket`, `sse`, raw
application, three-form mount (including modular `router =>` children),
relative reverse-routing, query/fragment, and matched-route metadata recipes
live in `PAGI::Routing` and `PAGI::Tools::Cookbook`.
