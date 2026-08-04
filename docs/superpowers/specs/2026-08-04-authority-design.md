# Authority Validation and Resolution

**Date:** 2026-08-04
**Status:** Draft for user review
**Scope:** One authority parser for request accessors, absolute URLs, and the
currently supported protocol surfaces of Host-aware middleware

## 1. Summary

PAGI-Tools will add `PAGI::Authority` as the single implementation of inbound
Host cardinality, authority validation, and scope-server fallback formatting.
`PAGI::Request->host`, the new base `PAGI::Context->host`, declarative routing
URL generation, `PAGI::Middleware::TrustedHosts`,
`PAGI::Middleware::HTTPSRedirect`, and trusted Host rewriting in
`PAGI::Middleware::ReverseProxy` will delegate to it.

The change is security hardening. A Host header is not an ordinary
last-value-wins field: a duplicate or malformed Host is ambiguous and must not
be selected, ignored, or converted into a URL. Existing generic header methods
remain available as the explicit raw-header path.

This design does not extend the scope types processed by existing middleware.
Cross-protocol proxy normalization and Host rejection remain in the separate
proxy/Host compatibility design because they require protocol-specific failure
events and a migration policy.

## 2. Relationship to declarative routing

Authority hardening is a prerequisite for declarative routing. The routing
resolver will call `PAGI::Authority->from_scope($scope)` and will contain no
Host scan, authority grammar, or server fallback implementation of its own.

Routing still does not parse `Forwarded` or `X-Forwarded-*`. Deployments put
trusted proxy normalization before routing. The resolver consumes only the
normalized `scheme`, `headers`, and `server` already present in its scope.

## 3. Shipped behavior being corrected

The distribution currently has several incompatible interpretations:

- `PAGI::Request->host` delegates to the last-value lookup
  `$request->header('host')`.
- `PAGI::Middleware::TrustedHosts` performs its own first-value scan.
- `PAGI::Middleware::HTTPSRedirect` performs another first-value scan and
  invents `localhost` when Host is absent.
- `PAGI::Middleware::ReverseProxy` rewrites every existing Host pair and can
  therefore retain duplicate Host fields. Its shallow scope clone can also
  retain a stale `pagi.request.headers` snapshot after replacing the header
  array.
- Without this prerequisite, routing would add a fourth authority parser.

Valid existing `PAGI::Request->host` results remain valid. Duplicate and
malformed input changes from an arbitrary/raw result to a synchronous failure.
The middleware changes described below turn validation failures into HTTP 400
responses on the HTTP scopes they already process.

## 4. Goals

- Give Host one case-insensitive cardinality and validation rule.
- Provide the same `$c->host` behavior on HTTP, WebSocket, and SSE Contexts.
- Preserve a valid explicit Host port and safely format server fallback data.
- Fail closed rather than converting malformed attacker-controlled input into
  a redirect or absolute URL.
- Keep proxy trust and allowlist policy in their owning middleware.
- Prevent stale header snapshots when ReverseProxy replaces request headers.
- Avoid a new non-core URI parsing dependency.

## 5. Non-goals

This change does not:

- Change the generic last-value semantics of `header($name)`,
  `PAGI::Headers->get($name)`, or raw header access.
- Parse `Forwarded`, choose a value from `X-Forwarded-*` chains, or decide
  whether a proxy is trusted.
- Add Host accessors to `PAGI::WebSocket` or `PAGI::SSE`; the common Context
  accessor is the supported cross-protocol spelling.
- Extend ReverseProxy, TrustedHosts, or HTTPSRedirect to scope types they
  currently pass through.
- Add IPv6 zone identifiers, IPvFuture, Unicode hostnames, percent-encoded
  registered names, or alternate numeric-IP spellings.
- Canonicalize DNS case, resolve DNS, apply IDNA, or decide whether a validated
  host is trusted.
- Change PAGI server request-parsing obligations. A conforming server should
  reject malformed HTTP before application dispatch; this layer remains a
  defense for synthetic scopes and imperfect upstreams.

## 6. Public API

`PAGI::Authority` exports nothing. It is called with class methods:

```perl
my $safe = PAGI::Authority->validate($value);

my $host = PAGI::Authority->host_from_scope($scope);
# undef when Host is absent

my $authority = PAGI::Authority->from_scope($scope);
# valid Host, or a formatted scope->{server} fallback when Host is absent
```

### 6.1 `validate`

`validate($value)` accepts one defined scalar authority value, validates it,
and returns its safe string form. It croaks on an undefined, referenced, empty,
or malformed value. It preserves valid hostname spelling and an explicit port;
it does not perform gratuitous case or address normalization.

This is the entry point for a Host-like value that a consumer has already
selected under its own trust policy, such as ReverseProxy's trusted
`X-Forwarded-Host` value.

### 6.2 `host_from_scope`

`host_from_scope($scope)` examines the raw ordered header pairs using an ASCII
case-insensitive comparison:

- No Host pair returns `undef`.
- Exactly one Host pair is passed to `validate` and returned.
- More than one Host pair croaks, even when the values are identical or the
  field-name casing differs.

Malformed header-array or pair shapes croak as incompatible scope input. A Host
pair with an undefined value is malformed, not absent.

### 6.3 `from_scope`

`from_scope($scope)` first calls `host_from_scope`:

- A valid Host is returned unchanged, including any explicit default port.
- A duplicate or malformed Host croaks; `scope->{server}` is never used to hide
  a present invalid Host.
- Only an absent Host permits fallback to `scope->{server}`.

The server fallback must be an arrayref of one or two elements containing a
usable host and optional port. A defined port must be an integer from 0 through
65535. An IPv6 server host is emitted in brackets. A server-derived port is
omitted when it is the default for the scope scheme: 80 for `http`/`ws` and 443
for `https`/`wss`. Other defined ports are included. A missing scheme follows
the existing Context default of `http`; an unrecognized scheme does not cause
Authority to invent a default port. If neither source is usable,
`from_scope` croaks.

## 7. Accepted authority grammar

The supported grammar is intentionally narrower than every theoretical URI
registered name because these values are used in security checks, redirects,
and absolute URLs.

Accepted hosts are:

- A nonempty ASCII registered name containing only letters, digits, `.`, `_`,
  `-`, or `~`. Dot-separated labels must be nonempty, apart from one optional
  trailing root dot. Punycode is ordinary ASCII and is accepted.
- A dotted-decimal IPv4 address. A four-part digits-and-dots candidate must
  have four octets in the range 0 through 255.
- A bracketed IPv6 literal accepted by Perl's core `Socket` IPv6 parser.

Any accepted host may have `:` followed by a nonempty decimal port in the range
0 through 65535. An explicit port is retained, including 80 or 443.

Rejected input includes:

- Empty values; whitespace; control or non-ASCII bytes.
- `/`, `?`, `#`, `@`, backslash, comma, percent escapes, and other characters
  outside the supported registered-name alphabet.
- Userinfo, a missing or empty host, an empty port, a nondigit port, or an
  out-of-range port.
- Unbracketed IPv6, malformed IP literals, IPv6 zone identifiers, and
  IPvFuture. A value made only of digits and dots must be a valid four-octet
  IPv4 address; alternate numeric-IP spellings such as `127.1` and a bare
  decimal integer are rejected rather than accepted as registered names.

Server fallback parsing uses the same hostname and address rules, except that
an IPv6 host in the structured server tuple may arrive without brackets and is
bracketed for output.

## 8. Request and Context accessors

`PAGI::Request->host` delegates to
`PAGI::Authority->host_from_scope($request->raw)`.

The base `PAGI::Context` gains:

```perl
my $host = $c->host;
```

It delegates to `PAGI::Authority->host_from_scope($c->scope)`. Because the
method lives on the base class, HTTP, WebSocket, and SSE Contexts share the same
behavior. It returns the complete validated Host field value, not merely a bare
hostname; an explicit port remains present.

Both accessors return `undef` only for an absent Host and propagate Authority's
synchronous exception for duplicate or malformed Host input. Callers that
intentionally need raw last-value behavior may use `header('host')` and must
take responsibility for its ambiguity.

No authority result is stored in scope. Middleware can shallow-clone scope and
replace headers, so caching a derived authority without tying it to the exact
header-array identity would risk stale results. Header lists are small and the
scan is linear.

## 9. Middleware integration

### 9.1 TrustedHosts

On the HTTP scopes it currently handles, TrustedHosts calls
`host_from_scope`. An absent Host continues through the existing `allow_empty`
policy. A duplicate or malformed Host produces the middleware's generic HTTP
400 response; parser diagnostics are not exposed to the client. A valid
complete Host value continues through the middleware's existing case-insensitive
allowlist policy.

The middleware's non-HTTP pass-through behavior is unchanged by this design.

### 9.2 HTTPSRedirect

When HTTPSRedirect needs to construct a redirect, it calls `from_scope` rather
than scanning Host or defaulting to `localhost`. It uses a valid Host, or a
validated server fallback only when Host is absent. Duplicate, malformed, or
unresolvable authority produces a generic HTTP 400 response instead of a
redirect or an ErrorHandler-visible exception.

Its existing type gates and exclusion behavior remain unchanged.

### 9.3 ReverseProxy

ReverseProxy first applies its existing trusted-proxy decision. Authority does
not inspect forwarding headers and cannot make an untrusted proxy trusted.

For a trusted request, ReverseProxy collects `X-Forwarded-Host` field lines
case-insensitively. No field leaves Host unchanged. More than one field produces
HTTP 400 even when the values are identical. With exactly one field,
ReverseProxy:

1. Rejects a comma-containing value through Authority rather than treating it
   as a chain.
2. Calls `PAGI::Authority->validate($forwarded_host)`.
3. On failure, emits a generic HTTP 400 response and does not invoke downstream.
4. On success, removes every existing Host pair and appends exactly one Host
   pair containing the validated value, even when the incoming scope had no
   Host pair.
5. Deletes the inherited `pagi.request.headers` entry from the shallow-cloned
   scope whenever it replaces the header array.

That cache invalidation is required because `PAGI::Request`, `PAGI::WebSocket`,
and `PAGI::SSE` use the same scope key for lazy header snapshots. Downstream
access must rebuild from the replacement array.

This design does not otherwise redesign `X-Forwarded-*` chain selection or
extend ReverseProxy beyond its shipped scope-type gate.

## 10. Error boundary

Authority methods croak synchronously on invalid structure or data. They never
return a partially parsed value and never place untrusted input verbatim in a
diagnostic where controls could reach logs.

Direct application access through `$request->host`, `$c->host`, and routing
`url_for` propagates that exception. Normal ErrorHandler placement may turn it
into an application error response.

Host-aware HTTP middleware catches only the Authority operation it invokes and
translates validation failure into its generic HTTP 400 response. It does not
catch failures from downstream applications or unrelated middleware work.

## 11. Compatibility and release notes

This is an intentional security behavior change:

- Valid `PAGI::Request->host` results retain their spelling and explicit port.
- Missing Host still returns `undef` from `Request->host` and the new
  `Context->host`.
- Duplicate or malformed Host now croaks through those accessors instead of
  returning an arbitrary raw value.
- TrustedHosts rejects ambiguous Host rather than potentially accepting the
  first value.
- HTTPSRedirect no longer generates `https://localhost/...` merely because
  Host is absent; it uses a valid server fallback or returns 400.
- Trusted ReverseProxy rewriting produces exactly one validated Host and
  invalidates the stale request-header cache.

`Changes` and the Request, Context, and middleware POD must identify the
hardening explicitly. Documentation must distinguish `host` as a validated
semantic accessor from `header('host')` as the raw last-value escape hatch.

## 12. Required tests

Focused Authority tests cover:

- Missing, single, duplicate-identical, duplicate-conflicting, and mixed-case
  Host field names.
- Every accepted registered-name, IPv4, bracketed-IPv6, and port form.
- Every rejected byte class, delimiter, address form, and port form.
- Preservation of valid spelling and explicit default ports.
- Server fallback hostnames, IPv4, unbracketed IPv6, missing ports, default
  port omission, nondefault ports, malformed tuples, and missing authority.
- Proof that malformed or duplicate Host never falls back to server.
- Proof that input scopes and header arrays are not mutated.

Accessor tests run the same missing/valid/invalid/duplicate matrix through
`PAGI::Request->host` and HTTP, WebSocket, and SSE `$c->host`.

Middleware integration tests cover:

- TrustedHosts allowlist, `allow_empty`, malformed Host, and both duplicate
  forms, with a 400 and no downstream call on failure.
- HTTPSRedirect Host preference, server fallback, no `localhost` invention,
  explicit ports, IPv6, and 400 failures.
- Trusted and untrusted ReverseProxy paths; valid, missing, malformed,
  comma-containing, and repeated forwarded Host input; replacement of zero,
  one, and multiple incoming Host pairs with exactly one pair.
- A scope whose `pagi.request.headers` snapshot was populated before
  ReverseProxy, proving downstream Request access observes the rewritten Host
  rather than stale cached data.
- Existing non-HTTP pass-through behavior for each middleware, proving this
  prerequisite did not silently perform the deferred cross-protocol extension.

Routing tests consume `PAGI::Authority->from_scope` and repeat only routing's
scheme-selection and URL-composition responsibilities, not Authority's entire
grammar matrix.

## 13. Sequencing

Implement and release this authority-hardening slice before declarative
routing. Then update the declarative routing design and implementation plan to
name `PAGI::Authority` as a dependency and remove their direct Host validation
work.

The later proxy/Host cross-protocol compatibility design depends on this
module. It must reuse Authority rather than introduce protocol-specific Host
parsers, but it still owns migration policy and HTTP/WebSocket/SSE rejection
events.
