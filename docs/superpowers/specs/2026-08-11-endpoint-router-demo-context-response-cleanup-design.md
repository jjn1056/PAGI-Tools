# Endpoint Router Demo Context/Response Cleanup

## Decision

Make two focused clarity corrections in the canonical class-based Endpoint
Router demo:

1. Read the typed `user_id` capture through `$c->path_param('user_id')`, the
   Context convenience API used by the other modern examples, instead of
   reaching through `$c->request`.
2. In the native authentication middleware, construct the denied response
   through `$c->text('demo token required', status => 401)` and emit it with
   `respond($send)` instead of manually constructing HTTP start/body events.

Both forms use existing public APIs. The request contract and observable
response stay unchanged: a request without `X-Demo-Token: demo-token` receives
status 401, content type `text/plain; charset=utf-8`, body
`demo token required`, and a terminal body event.

## Scope

- Modify `examples/endpoint-router-demo/lib/MyApp/API.pm` only for the two
  approved API substitutions.
- Strengthen `t/integration-endpoint-router-demo.t` so the exact denied body,
  content type, and terminal event lifecycle are covered before the middleware
  is changed.
- Keep `async sub` on `home`, `index`, and `show`; this design deliberately
  does not address synchronous handler presentation.
- Add no middleware abstraction, compatibility behavior, dependency, raw
  route, or unrelated example cleanup.

## Verification

Use the existing integration test as the TDD boundary. First tighten its 401
assertions and confirm that the content-type expectation fails against the
manual response. Then apply the two API substitutions and confirm the complete
Endpoint demo integration test passes without warnings. Finish with syntax,
POD/diff hygiene as applicable, and a scoped review.
