# Proxy and Host Middleware Cross-Protocol Compatibility

**Date:** 2026-08-04
**Status:** Needs design; extracted from the declarative-routing review
**Scope:** Compatibility policy for extending shipped proxy normalization and
Host validation beyond HTTP scopes

## 1. Relationship to declarative routing

This work is independent of declarative routing and is not a prerequisite for
it. `PAGI::Routing` generates absolute URLs from the normalized scheme,
authority, and server information already present in request scope.

The routing design does not parse proxy headers and does not change the scope
types handled by existing middleware.

## 2. Shipped behavior

`PAGI::Middleware::ReverseProxy` and `PAGI::Middleware::TrustedHosts` currently
process only scopes whose type is `http`. WebSocket, SSE, lifespan, and unknown
scope types pass through without proxy normalization or Host validation.

Applications may rely on this pass-through behavior. In particular, enabling
`TrustedHosts` does not currently reject a WebSocket or SSE scope with a
different, missing, or otherwise disallowed Host header.

## 3. Proposed capability

The extracted routing proposal would make trusted proxy normalization and Host
validation apply consistently to header-bearing HTTP, WebSocket, and SSE
scopes. Potential behavior includes:

- Applying trusted `X-Forwarded-*` normalization to all three protocols.
- Replacing or inserting the Host header from a trusted forwarded authority.
- Mapping forwarded HTTP/HTTPS schemes to WS/WSS for WebSocket scopes.
- Validating Host for WebSocket and SSE rather than passing them through.
- Sending protocol-correct rejection events for invalid or missing authority.

These are unapproved possibilities, not routing requirements.

## 4. Compatibility questions

Before implementation, this design must decide:

- Whether cross-protocol handling is opt-in, becomes a new default after a
  deprecation period, or requires new middleware classes.
- Whether existing `allow_empty` and trusted-proxy configuration applies
  unchanged to WebSocket and SSE.
- The response status and event family for invalid SSE authority.
- Whether WebSocket rejection uses the optional HTTP-denial extension when
  available and which pre-acceptance close behavior applies otherwise.
- How forwarded HTTP/HTTPS schemes map to WS/WSS and how already-native WS/WSS
  values are handled.
- Whether RFC `Forwarded` remains unsupported or is designed separately.
- How the behavior is introduced without silently rejecting traffic that
  currently passes through.

## 5. Required tests and documentation

The eventual plan must cover:

- Existing HTTP behavior without regression.
- Explicit compatibility tests proving the current WebSocket/SSE pass-through
  behavior before any migration.
- Missing, valid, and invalid Host values for every supported protocol.
- Trusted and untrusted proxy sources.
- Forwarded scheme, authority, client, and server normalization.
- Protocol-correct WebSocket and SSE rejection behavior.
- Middleware order, deployment migration, and security consequences.

## 6. Sequencing requirement

No implementation plan should be written until the compatibility stance and
protocol-specific failure behavior are approved. Declarative routing may ship
without this work.
