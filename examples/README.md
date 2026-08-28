# PAGI-Tools Examples

This directory contains example applications built on the PAGI toolkit — the
higher-level components (Endpoint, Middleware, Apps, Request/Response,
etc.) that live in this distribution.

Routing examples use three frontends over one immutable engine:
`PAGI::Routing` for functional declarations, `PAGI::App::Router` for a mutable
verb-method builder, and `PAGI::Endpoint::Router` for local methods on a
configured object. They share path Patterns, written declaration order,
metadata, Router-owned HTTP outcomes, and reverse routing. Native
three-channel route handlers are always marked `raw`. Deployed Router examples
let the selected Router own complete negotiated 404/405 outcomes and use
Compose for lifespan, application-error, and response-completion safeguards;
direct `to_app` remains the lower-level routing-component spelling. Runnable
examples normally return their Compose or Router object directly because
conforming servers accept components with `to_app`; examples compile
explicitly only when they need the resulting native coderef at another
application boundary.

## Requirements

- Perl 5.18+ with `Future::AsyncAwait` for the distribution and most examples;
  `15-large-application` and `starlette-apples` deliberately require Perl
  5.40+ for signatures
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

1. `09-psgi-bridge` - wraps a PSGI app for PAGI use (via `PAGI::App::WrapPSGI`)
2. `10-chat-showcase` - Compose-rooted chat demo with application-wide logging and a mutable HTTP/WebSocket/SSE target router
3. `13-contact-form` - form parsing and file uploads
4. `14-lifespan-utils` - lifespan hooks via `PAGI::Utils`
5. `15-large-application` - Perl 5.40+ Compose-rooted modular HTML application with named Person/Blogs Router application mounts, cross-component links, boundary-specific Router defaults, an opaque static-file mount, lifespan data, and a deferred-work ledger
6. `app-01-file` - static file serving with `PAGI::App::File`
7. `background-tasks` - running background work from within a PAGI app
8. `compose` - optional application root combining declarative routes, request-ID middleware, server-owned lifecycle state, automatic HEAD, and verified shutdown
9. `declarative-routing` - immutable `PAGI::Routing` tree with package handlers, a configured child Router mount, route middleware, boundary-specific HTTP defaults, and reverse URLs
10. `endpoint-demo` - high-level HTTP endpoint with `PAGI::Endpoint::HTTP`
11. `endpoint-router-demo` - composing Endpoint routes with callback children, explicit discoverable child Routers, `app_as`, and `http_default`
12. `full-demo` - kitchen-sink demo combining multiple toolkit features
13. `pages` - Compose-rooted `PAGI::Pages` demo covering Welcome, redirects, negotiated HTML/problem JSON/text errors, Route versus Mount, Request-returned Responses, raw `respond($send)`, and lifespan
14. `sse-dashboard` - server-sent events dashboard with `PAGI::Endpoint::SSE`
15. `test-lifespan-shutdown` - testing graceful lifespan shutdown hooks
16. `websocket-chat-v2` - WebSocket chat using `PAGI::Endpoint::WebSocket`
17. `websocket-echo-v2` - WebSocket echo using `PAGI::Endpoint::WebSocket`
18. `websocket-bidirectional` - full-duplex WebSocket with `PAGI::WebSocket`: a receive-loop (`each_text`) and an unsolicited server send-loop running concurrently, both routed through one serializing send queue -- the canonical pattern for any handler with more than one send-producer on the same socket
19. `starlette-apples` - Perl 5.40 single-file apples CRUD application for direct comparison with the original Starlette version, using `Types::Standard` path constraints and Router-owned routing outcomes

**Note on `websocket-chat-v2/public`:** this directory is a symlink to
`10-chat-showcase/public`. It works in git checkouts but is omitted from the
distribution tarball; copy the `public/` directory manually if you need it
outside a checkout.

Each example has its own `README.md` explaining how to run it.
