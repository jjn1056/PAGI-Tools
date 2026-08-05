# Declarative routing

This is a small executable `PAGI::Routing` application. It demonstrates the
ordinary shape without turning the example into a framework:

- handlers loaded normally from `MyApp::Routes::Home` and passed as fully
  qualified coderefs;
- an inline `/api` mount with the `api` route-name namespace;
- a numeric path constraint;
- one pure route middleware descriptor;
- custom 404 and 405 handlers;
- named `path_for` and request-aware `url_for` generation; and
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
application, middleware-placement, mount, reverse-routing, and matched-route
metadata recipes live in `PAGI::Routing` and `PAGI::Tools::Cookbook`.
