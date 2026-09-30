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
Router object; servers accept anything with `to_app`.

## Requirements

- Perl 5.18+ with `Future::AsyncAwait` for the distribution and most examples;
  `large-application`, `starlette-apples`, `process-streaming`,
  `auth-cookie-login`, `auth-extensions`, `auth-notes`, and `auth-jwt-sandbox`
  require Perl 5.40+
- A PAGI server to run examples against:
  ```
  cpanm PAGI::Server
  ```
  Then launch any example with:
  ```
  pagi-server --app examples/<name>/app.pl --port 5000
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
- `chat` - multi-user chat over HTTP, WebSocket and SSE: one-object handlers on declarative routes, a JSON API Router mounted at `/api`, live SSE notifications, application-wide logging

HTTP:

- `contact-form` - a POST handler parsing form fields and file uploads
- `static-files` - static file serving with `PAGI::App::File`
- `pages` - Compose-rooted `PAGI::Pages` demo covering class/configured/export factories, direct application Routes and Mount, a request-derived application return, negotiation, and lifespan
- `process-streaming` - streams an external command's output through `stream_response`/`pipe_from` with a four-line loop-agnostic `Future::IO` source, real pipe backpressure, and `on_close` cleanup that stops the child when the client disconnects
- `psgi-bridge` - a legacy PSGI application on a catch-all route beside native routes (via `PAGI::App::WrapPSGI`)
- `starlette-apples` - Perl 5.40 single-file apples CRUD application for direct comparison with the original Starlette version, using `Types::Standard` path constraints, Router-owned routing outcomes, and a PAGI-only NDJSON export

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
- `endpoint-class-demo` - ordinary modular objects returning immutable Router subtrees, with configured exact-leaf endpoint classes
- `large-application` - Perl 5.40+ Compose-rooted modular HTML application with named Person/Blogs Router application mounts, cross-component links, boundary-specific Router defaults, an opaque static-file mount, lifespan data, and a deferred-work ledger

Lifespan and background work:

- `lifespan-utils` - lifespan hooks via `PAGI::Utils`
- `test-lifespan-shutdown` - testing graceful lifespan shutdown hooks
- `background-tasks` - starting fire-and-forget work from ordinary handlers

Each example has its own `README.md` explaining how to run it.

## Authentication examples

- [auth-cookie-login](auth-cookie-login/README.md) — explicit application login
  policy with demo credentials, session-ID regeneration, logout destruction,
  and redirect flow.
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
