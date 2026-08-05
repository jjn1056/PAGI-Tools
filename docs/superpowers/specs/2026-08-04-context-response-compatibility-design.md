# Context and Response Compatibility

**Date:** 2026-08-04
**Status:** Needs design; extracted from the declarative-routing review
**Scope:** A staged compatibility and deprecation design for the shipped
`PAGI::Context` and `PAGI::Response` APIs

## 1. Relationship to declarative routing

This work is independent of declarative routing and is not a prerequisite for
it. The routing API uses the currently shipped Context and Response contracts.

The proposals below preserve the material extracted from the original routing
draft. They are not approved behavior. Before implementation, this design must
define compatibility principles, deprecation periods, exact old and new
semantics, and migration tests for released applications.

## 2. Unresolved compatibility decisions

- Whether base Context `send` and `receive` remain aliases during a deprecation
  period after `raw_send` and `raw_receive` are introduced.
- Whether `$c->headers` can change type compatibly, or whether a new accessor
  must carry the `PAGI::Headers` object.
- How changing missing `$c->state` from an empty hashref to `undef` interacts
  with `PAGI::Endpoint::Router` and existing applications.
- The exact compatibility semantics of `PAGI::Response->send`, `send_raw`, and
  any proposed `body` getter/setter. The shipped `send` is not currently an
  alias for `text`, and it handles content type and options differently.
- Which query names are canonical across Request, WebSocket, and SSE, including
  the status of currently deprecated Request names and primary WebSocket names.

## 3. Raw callbacks

The extracted proposal made `$c->raw_send` and `$c->raw_receive` the canonical
raw channel accessors and removed `send` and `receive` as raw accessors from the
base Context. Protocol-specific high-level methods would retain names that
describe actions: SSE `$c->send(...)` would remain actual SSE event emission,
WebSocket would use typed send/receive methods, and HTTP would use `respond`.

This requires a deprecation design; removing the base accessors outright is not
approved.

## 4. `PAGI::Response`

The extracted proposal described a Response as a detached local value with:

- `body($bytes)` as a raw-byte body setter.
- `text($characters, charset => ...)` as an encoded text-body setter.
- `html`, `json`, `empty`, `stream`, and related builders modifying local
  response state.
- `respond($send)` emitting the accumulated HTTP response events and returning
  a Future for their completion.

It also proposed retaining `send` as a compatibility alias to `text` and
`send_raw` as an alias to `body`. That description does not match the shipped
semantics and remains unresolved. The final design must specify option handling,
content-type behavior, charset behavior, and whether `body()` with no arguments
is a getter.

## 5. Query data

The extracted proposal sought one parser and cache over
`scope->{query_string}` for HTTP, WebSocket, and SSE, with shared parameter and
raw-parameter accessors. The final name set and compatibility aliases remain to
be decided against the deployed Request and WebSocket APIs.

## 6. Headers

The extracted proposal was:

- `header($name)` for the last value or `undef`.
- `header_all($name)` for every value.
- `headers()` for a `PAGI::Headers` snapshot/object.
- `raw_headers()` for the original wire-pair representation.

Because `$c->headers` currently returns raw scope pairs, the final design must
either retain that behavior or provide a staged migration with a defensible
compatibility period.

## 7. State and stash

The extracted proposal made `$c->state` return the scope's application-state
hashref when present and `undef` otherwise, with `$c->has_state` distinguishing
presence. Application lifespan state and per-request `stash` would remain
separate concepts.

Because the shipped method returns an empty hashref when state is absent and
`PAGI::Endpoint::Router` seeds state, the final design must cover both direct
and indirect compatibility effects.

## 8. Scope selection

The extracted proposal retained the missing-type HTTP default for compatibility
but made an explicit unrecognized scope type croak. This behavior still needs
compatibility tests and approval.

## 9. Required migration tests and documentation

The eventual test and documentation plan must cover:

- Raw callback names and any deprecation aliases.
- SSE `send` as event emission versus Response local-state methods.
- Exact `send`, `send_raw`, `text`, and proposed `body` behavior.
- Query parsing, caching, canonical names, aliases, and warnings by protocol.
- Header object and raw-wire representations without an accidental type break.
- Missing and present state, `has_state`, and Endpoint Router integration.
- Migration notes for every breaking name or semantic change.

Every helper must document whether it changes local state, returns a callback,
or emits and awaits protocol events.

## 10. Sequencing requirement

No implementation plan should be written until the compatibility policy and
each old/new method contract are approved. The resulting plan must use staged
deprecations where released code would otherwise fail or silently change
behavior.
