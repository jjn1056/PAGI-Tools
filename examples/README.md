# PAGI-Tools Examples

This directory contains example applications built on the PAGI toolkit — the
higher-level components (Endpoint, Middleware, Apps, Request/Response,
etc.) that live in this distribution.

Routing examples use immutable `PAGI::Routing` declarations and explicit
configured Router boundaries where a subtree owns its own paths and HTTP
outcomes. They share path Patterns, written declaration order, metadata,
Router-owned HTTP outcomes, and reverse routing. Native three-channel Route
endpoints are always wrapped with `as_app_object`; native Mount applications are
passed directly. Compose supplies lifespan, application-error, and
response-completion safeguards around its declared routes. Runnable examples
normally return their Compose or Router object directly because conforming
servers accept components with `to_app`; examples compile explicitly only when
they need the resulting native coderef at another application boundary.

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
2. `10-chat-showcase` - Compose-rooted chat demo with application-wide logging and direct immutable HTTP/WebSocket/SSE declarations
3. `13-contact-form` - form parsing and file uploads
4. `14-lifespan-utils` - lifespan hooks via `PAGI::Utils`
5. `15-large-application` - Perl 5.40+ Compose-rooted modular HTML application with named Person/Blogs Router application mounts, cross-component links, boundary-specific Router defaults, an opaque static-file mount, lifespan data, and a deferred-work ledger
6. `app-01-file` - static file serving with `PAGI::App::File`
7. `background-tasks` - running background work from within a PAGI app
8. `compose` - optional application root combining declarative routes, request-ID middleware, server-owned lifecycle state, automatic HEAD, and verified shutdown
9. `declarative-routing` - immutable `PAGI::Routing` tree with package handlers, a configured child Router mount, route middleware, boundary-specific HTTP defaults, and reverse URLs
10. `endpoint-demo` - direct HTTP, WebSocket, and SSE endpoint-class leaves under declarative routing
11. `endpoint-class-demo` - ordinary modular objects returning immutable Router subtrees, with configured exact-leaf endpoint classes
12. `full-demo` - kitchen-sink demo using direct Request, WebSocket, and SSE handlers plus a streaming Response
13. `pages` - Compose-rooted `PAGI::Pages` demo covering class/configured/export factories, direct application Routes and Mount, a request-derived application return, native `as_app_object` plus `invoke_app`, negotiation, and lifespan
14. `process-streaming` - streams an external command's output through `stream_response`/`pipe_from` with a four-line loop-agnostic `Future::IO` source, real pipe backpressure, and `on_close` cleanup that stops the child when the client disconnects
15. `sse-close` - direct `PAGI::SSE` application with an explicit close and client-facing sentinel event
16. `sse-dashboard` - server-sent events dashboard with `PAGI::Endpoint::SSE`
17. `starlette-apples` - Perl 5.40 single-file apples CRUD application for direct comparison with the original Starlette version, using `Types::Standard` path constraints and Router-owned routing outcomes
18. `test-lifespan-shutdown` - testing graceful lifespan shutdown hooks
19. `websocket-bidirectional` - full-duplex WebSocket with `PAGI::WebSocket`: a receive-loop (`each_text`) and an unsolicited server send-loop running concurrently, both routed through one serializing send queue -- the canonical pattern for any handler with more than one send-producer on the same socket
20. `websocket-chat-v2` - WebSocket chat using `PAGI::Endpoint::WebSocket`
21. `websocket-echo-v2` - WebSocket echo using `PAGI::Endpoint::WebSocket`

**Note on `websocket-chat-v2/public`:** the v2 example carries ordinary copies
of the shared chat frontend assets so it remains runnable from CPAN tarballs,
which cannot preserve the source checkout's former directory symlink.

Each example has its own `README.md` explaining how to run it.
