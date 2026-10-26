# PAGI-Tools Examples

This directory contains example applications built on the PAGI toolkit — the
higher-level components (Endpoint, Middleware, Apps, Request/Response,
etc.) that live in this distribution.

Every example is built the same way. A route's handler takes one object: an
HTTP `route` handler receives a `PAGI::Request` and returns a Response, a
`websocket` handler receives a `PAGI::WebSocket`, and an `sse` handler receives
a `PAGI::SSE`. A `mount` takes a complete PAGI application, such as a Router or
`PAGI::App::File`. Raw three-channel applications are rare here: only
`protocol-refusal` wraps one with `as_app_object`, because the application
forms it accepts are its subject. Runnable examples return their Compose or
Router object; servers accept anything with `to_app`. A single-file example
is an `app.pl`; one with its own `lib/` is a `PAGI::App::Compose` in
`lib/<App>.pm`, served with that `lib/` on the path, and has no `app.pl`. The
two framework demos keep an `app.pl`: their `lib/` is the framework, standing
in for one installed from CPAN.

## Requirements

- Perl 5.24+ with `Future::AsyncAwait` for the distribution and most examples;
  `large-application`, `starlette-apples`, `gut-check`, `content-negotiation`, `upload-streaming`, `process-streaming`,
  `webhook-receiver`, `signed-requests`, `modify-form-post`, `method-override`, `tenant-orders`, `framework-on-tools`, `framework-wrap-style`, `request-class`, `starlette-endpoint`, `endpoint-lifecycle`, `escape-hatches`, `raw-app`, `internal-tool`, `auth-cookie-login`, `auth-extensions`, `auth-notes`, `auth-jwt-sandbox`, and `openapi-notes`
  require Perl 5.40+
- A PAGI server to run examples against:
  ```
  cpanm PAGI::Server
  ```
  Then launch a single-file example with:
  ```
  pagi-server --app examples/<name>/app.pl --port 5000
  ```
  and one with a `lib/` (its README names the module) with:
  ```
  pagi-server -I examples/<name>/lib --app examples/<name>/lib/<App>.pm --port 5000
  ```

Examples assume you understand the core spec
(see the [PAGI project](https://github.com/jjn1056/pagi) for spec documents)
plus the relevant protocol documents.

Note: Low-level protocol examples (hello-http, streaming-response, websocket-echo
handshake, SSE broadcaster, lifespan-state, extension-fullflush, tls-introspection,
job-runner, utf8) shipped with the `PAGI-Server` distribution — they demonstrate
raw PAGI protocol details that belong alongside the server implementation.

## Example List

Start here:

- `full-demo` - the runnable companion to the QUICK TOUR in `PAGI::Tools`: HTTP, streaming and NDJSON Responses, WebSocket and SSE handlers, links built from route names, and lifespan state
- `chat` - (a PAGI::App::Compose in `lib/ChatApp.pm`) multi-user chat over HTTP, WebSocket and SSE: one-object handlers on declarative routes, a JSON API Router mounted at `/api`, live SSE notifications, application-wide logging

HTTP:

- `contact-form` - a POST handler parsing form fields and file uploads
- `internal-tool` - Perl 5.40 task board, the everyday HTML workflow: Template Toolkit pages, a form re-rendered with its errors, redirect after POST, a session flash, CSRF on every form, a static stylesheet; the same application in Flask in its README, with line counts
- `webhook-receiver` - Perl 5.40 whip-it-up GitHub-style webhook receiver: HMAC over the raw body, a JSONL log, a status page and a JSON view, written cold with a clock running; the same program in Flask and Go in its README
- `signed-requests` - Perl 5.40 signed CI deliveries: a middleware checks an HMAC over the body as the routes read it, through the receive it hands them, and fails the read of the last chunk (Starlette's body-limit shape): a JSON event through `$request->json` and an artifact streamed to disk, with the same application in Starlette (`app.py`)
- `modify-form-post` - Perl 5.40 middleware that rewrites a form POST's body before the route reads it, with the same application in Starlette (`app.py`): it reads the whole form, then hands the route a receive that delivers the rewritten body
- `method-override` - Perl 5.40 notes renamed and deleted from plain HTML forms that name the method in their action URL (`?_method=PUT`); `MethodOverride` reads the header and the query, never the body, so the route reads its own form; with the same application in Starlette (`app.py`)
- `tenant-orders` - Perl 5.40 an orders API behind four middleware that each read the request through a Request of their own -- headers, query, and the body read ahead and handed on -- while the route reads the body through its own; a Request writes nothing to the scope, so each reads what it was handed; with the same application in Starlette (`app.py`)
- `upload-streaming` - streaming uploads, bytes or text: a binary file kept exactly as sent, CSV imports decoded by the client's charset with `strict` and `strip_bom` (cp1252, UTF-8 with a BOM, UTF-16) and parsed with Text::CSV, NDJSON read by line with `each_line`, a lenient transform, a 415 for a charset the stream cannot decode, and `truncated` for a hang-up
- `content-negotiation` - one notes resource for browsers, htmx and API clients: the ContentNegotiation middleware on a mount picks HTML or JSON from Accept, refuses with the app's own 406 problem and sends Vary; `respond_to` names each representation; htmx gets fragments with `Vary: HX-Request`; a POST reads a form or JSON by Content-Type; `/health` stays outside the negotiation
- `static-files` - static file serving with `PAGI::App::File`
- `pages` - Compose-rooted `PAGI::Pages` demo covering class/configured/export factories, direct application Routes and Mount, a request-derived application return, negotiation, and lifespan
- `process-streaming` - streams an external command's output with a four-line loop-agnostic `Future::IO` source as the `response('Stream', ...)` content, real pipe backpressure, and `on_close` cleanup that stops the child when the client disconnects
- `psgi-bridge` - a legacy PSGI application on a catch-all route beside native routes (via `PAGI::App::WrapPSGI`)
- `starlette-apples` - Perl 5.40 single-file apples CRUD application for direct comparison with the original Starlette version, using `Types::Standard` path constraints, Router-owned routing outcomes, and a PAGI-only NDJSON export
- `gut-check` - Perl 5.40 applications each paired with a runnable Starlette version (thrown HTTP errors, a CRUD resource, a WebSocket/SSE/HTTP broadcast hub, everyday and bundled middleware, streaming formats, sessions, upload relay, negotiation), with measured behaviour and line counts, what the comparison found, and what changed

WebSocket and SSE:

- `websocket-echo` - the smallest WebSocket application: one route, one handler
- `websocket-bidirectional` - a receive loop and a server-initiated send loop on the same socket; `PAGI::WebSocket` sends one at a time, so the two need no coordination
- `sse-dashboard` - live metrics pushed to every connected dashboard over SSE
- `sse-close` - ending an SSE stream explicitly, with a client-facing sentinel event
- `protocol-refusal` - all six application forms accepted by WebSocket `deny` and SSE `decline`, exposed as twelve executable routes

Structuring applications:

- `compose` - optional application root combining declarative routes, request-ID middleware, server-owned lifecycle state, automatic HEAD, and verified shutdown
- `declarative-routing` - immutable `PAGI::Routing` tree with package handlers, a configured child Router mount, route middleware, boundary-specific HTTP defaults, and reverse URLs
- `endpoint-demo` - HTTP, WebSocket, and SSE endpoint classes as route leaves, with per-route middleware
- `raw-app` - Perl 5.40 a classic PAGI application in a module: a PAGI::App whose `call` is the application itself, with no Compose, handling lifespan, http and websocket scopes and refusing what it does not serve; `run_if_script` serves it with `--app` and runs one request from the shell
- `endpoint-class-demo` - a PAGI::App::Compose in `lib/MyApp.pm`, no `app.pl` (`run_if_script`: served with `--app`, runnable for one request from the shell): ordinary modular objects returning immutable Router subtrees, with configured exact-leaf endpoint classes
- `starlette-endpoint` - Perl 5.40 Starlette's class-based HTTPEndpoint example, ported line for line: `endpoint('MyHttpRoute')` at a route; the Python beside it in the README, with both curl transcripts (PUT 405 with Allow, HEAD, OPTIONS 204)
- `endpoint-lifecycle` - Perl 5.40 (a PAGI::App::Compose in `lib/NotesApp.pm`) one `endpoint()` spelling for three lifecycles: plain and WebSocket classes built fresh for each request or connection (state on `$self`), a Moo HTTP endpoint whose builder fills a required per-request attribute next to shared route config, and one object shared on purpose with `BUILD_APP`
- `framework-on-tools` - Perl 5.40 small Sinatra/FastAPI-shaped framework (`lib/Tiny.pm`) built on Tools, and a notes app on it: a Request subclass, plain-value returns, `before` and `around` (call_next) hooks, startup services, typed path parameters, exception mapping, a plugin, a raw escape hatch and an OpenAPI document from the Router; the README lists each seam and its cost
- `framework-wrap-style` - Perl 5.40 a wrap-style framework (`lib/Mini.pm`), the shape Thunderhorse and Responder have: a Request subclass, a mutable response staged on the empty `PAGI::Response` and built with one call, its own router re-dispatching one request through chained matches, a 401 exception carrying its challenge, a 204 and a bodyless redirect without Empty, and a page turned into a response
- `openapi-notes` - Perl 5.40 (`PAGI::Routing::OpenAPI` is early beta) a notes API whose `/openapi.json` comes from `openapi(...)`: typed path parameters, operationIds, security from `Requires` and bodies from route `meta`; a Router part under one PAGI::App::Compose, a mounted static application left out, and generated Python clients driving it end to end
- `request-class` - Perl 5.40 an application's own Request subclass with two helpers, set once by `middleware('RequestClass')` and received by a plain route, an Endpoint::HTTP method and a route inside a mount, with no handler wrapped
- `escape-hatches` - Perl 5.40 the easy way, then each step down to raw PAGI in one app: a handler returning a response, one reading the raw scope and connection, one answering with a hand-written application mid-request, a raw application mounted at a route, and raw middleware editing events
- `large-application` - Perl 5.40+ Compose-rooted modular HTML application (`MyApp::Root`, a PAGI::App::Compose, is the application) with named Person/Blogs Router application mounts, cross-component links, boundary-specific Router defaults, an opaque static-file mount, lifespan data, and a deferred-work ledger

Lifespan and background work:

- `lifespan-utils` - lifespan hooks via `PAGI::Utils`
- `test-lifespan-shutdown` - testing graceful lifespan shutdown hooks
- `background-tasks` - work the client does not wait for: started at once, or after the response is delivered (`on_complete`)
- `state-lifetimes` - Perl 5.40 a members list whose application state declares how long each value lives: an async connection and store built once per worker on first use (`singleton`), who is asking looked up once per request and shared by a middleware and the handler (`per_request`), a fresh form per submission (`factory`), and shutdown closing only what a request opened

Each example has its own `README.md` explaining how to run it.

## Authentication examples

- [auth-cookie-login](auth-cookie-login/README.md) — session cookie login with
  demo credentials: the `Requires` middleware redirects anonymous visitors to
  the login route with `?next=`, plus session-ID regeneration, a local-only
  `next` check, and logout destruction.
- [auth-notes](auth-notes/README.md) — introductory opaque-token API with public
  notes, identity checks, explicit read/write grants, and ordinary challenge
  responses. Includes fixed in-memory services and an acceptance-test matrix.
- [auth-jwt-sandbox](auth-jwt-sandbox/README.md) — two runnable JWT learning
  applications using Authentication v1: an inline three-route comparison and a
  group-protected variant with a shared browser walkthrough. Crypt::JWT is an
  example-local optional dependency.
- [auth-extensions](auth-extensions/README.md) — six small, executable companions
  for custom users, Basic backend objects, context placement, ordinary response
  forms, protocol admission, and challenge headers.
