# PAGI Examples

This directory contains progressively more advanced PAGI examples. Each subdirectory is prefixed with a two-digit number so you can follow along in order.

## Requirements
- Perl 5.32+ (for signature syntax) with `Future::AsyncAwait` and `IO::Async`
- A PAGI-capable server or the ability to plug these coderefs into your own harness (`bin/pagi-server-ref` runs everything in this directory using `lib/PAGI/Server/Ref.pm`)

Examples assume you understand the core spec (`docs/specs/main.mkdn`) plus the relevant protocol documents.

## Example List
1. `01-hello-http` – minimal HTTP response
2. `02-streaming-response` – chunked body, trailers, disconnect handling
3. `03-request-body` – reads multi-event request bodies
4. `04-websocket-echo` – handshake and echo loop
5. `05-sse-broadcaster` – server-sent events
6. `06-lifespan-state` – lifespan protocol with shared state
7. `07-extension-fullflush` – middleware using the `fullflush` extension
8. `08-tls-introspection` – prints TLS metadata when present
9. `09-psgi-bridge` – wraps a PSGI app for PAGI use (via `PAGI::App::WrapPSGI`)

Each example has its own `README.md` explaining how to run it and which spec sections to review.
