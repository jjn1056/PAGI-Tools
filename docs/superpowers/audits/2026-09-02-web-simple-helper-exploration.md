# Web::Simple Helper Exploration

**Date:** 2026-09-02
**Status:** Deferred; neither helper is approved for implementation
**Scope:** Possible future routing and middleware conveniences inspired by
`Web::Simple` 0.033

## Purpose

Two `Web::Simple` helpers were considered after the Route, Router, Mount, and
Compose responsibilities had been tightened:

- `redispatch_to`, which restarts internal dispatch rather than sending an
  HTTP redirect; and
- `response_filter`, which transforms the result produced by the remainder of
  a dispatch chain.

This note preserves the useful findings without adding either feature to the
current application-valued routing work. The current API should be allowed to
settle before either idea is reopened.

References:

- <https://metacpan.org/pod/Web::Simple#redispatch_to>
- <https://metacpan.org/release/MSTROUT/Web-Simple-0.033/source/examples/bloggery/bloggery.cgi>
- `Web::Dispatch::Wrapper` in the `Web::Simple` 0.033 distribution

## What Web::Simple Does

`redispatch_to($path)` constructs a middleware-like wrapper. When reached, it
shallow-copies the PSGI environment, replaces `PATH_INFO`, and invokes the
application dispatcher again from its beginning. The request method, query,
body handle, and other environment state remain the same. It is an internal
dispatch operation, not a 3xx response.

`response_filter { ... }` also constructs a wrapper around the rest of the
current dispatch chain. It receives the value returned by that chain and can
replace it while the value bubbles outward. This is inexpensive in
`Web::Simple` because its dispatcher is explicitly a recursive value-flow
system and ordinary PSGI responses are returned values.

## Possible Named-Route Redispatch

If PAGI::Tools revisits redispatch, it should target a named route rather than
an arbitrary URL string:

```perl
sub legacy_person ($request) {
    return redispatch_to(
        $request,
        '/people/show',
        params => {
            person_id => $request->path_params->{person_id},
        },
    );
}
```

The existing Resolver could then provide absolute and relative name lookup,
mount-aware path construction, inherited parameters, constraint validation,
and safety when a target route's URL pattern changes.

Named lookup does not solve the central control-flow problem. The agreed
meaning is a genuine routing restart:

1. Middleware belonging to the source Route, Mount, and nested Router unwinds.
2. The target is not invoked inside that abandoned middleware stack.
3. The root Router restarts selection and applies only the target branch's
   Route, Mount, and nested-Router middleware.
4. Root Router middleware may remain around the overall request once.

A nested call to the Router is therefore incorrect. For example, redispatching
from an admin-only source route to a public target must not leave the source
route's authorization middleware wrapped around the target or run root access
logging twice.

One possible non-exception implementation is a private request-local control
cell installed by the outer Router. A redispatch application records a named
target and emits no response. Normal returns unwind the abandoned branch; the
root dispatch loop observes the cell and starts a new selection pass. This is
only a design lead, not a ratified mechanism.

Any future design must settle at least:

- the exact Router boundary that owns the restart;
- absolute and relative named-route resolution;
- rebuilding `path`, `raw_path`, `root_path`, `path_params`, and routing
  metadata;
- preservation of method, query, headers, and the remaining receive stream;
- behavior after request-body consumption;
- rejection after a response has started;
- loop detection and a bounded redispatch count;
- protocol scope (initial discussion covered HTTP only); and
- middleware before/after effects during normal stack unwinding.

Redispatch cannot roll back work already performed by the source handler or
middleware. Database writes, logging, counters, and consumed request bytes
remain real even though the source routing branch is abandoned.

The tentative first-version preference was to preserve the original HTTP
method, query, headers, and remaining receive stream while replacing the path
and rebuilding routing metadata. That preference was not fully reviewed or
approved.

Static path aliases remain the responsibility of
`PAGI::Middleware::Rewrite`; they are not a sufficient reason to add
redispatch.

## Response Filtering

A direct `response_filter` port is not small under PAGI. PAGI applications
emit response events instead of returning a completed response value. A
filter must explicitly choose whether it:

- changes only `http.response.start`;
- transforms body chunks incrementally; or
- buffers a complete body before transforming it.

Those choices have different behavior for streaming, opaque file/filehandle
bodies, latency, memory, backpressure, incomplete responses, and disconnects.
The unqualified name `response_filter` would conceal that distinction.

The existing primitives already express the honest PAGI mechanisms:

- `PAGI::Middleware::Helpers::wrap_send`;
- `PAGI::Middleware::BufferedResponse::stream_transform_response`; and
- `PAGI::Middleware::BufferedResponse::buffer_whole_response`.

Any future convenience should remain middleware and should name its buffering
or streaming contract. A higher-order framework may provide shorter syntax;
core PAGI::Tools should not recreate Web::Simple's value-flow abstraction on
top of the event protocol merely to retain the old helper's spelling.

## Current Decision

Do not implement either helper in the current worktree campaign. Revisit
`redispatch_to` only when a concrete dynamic-forward use case justifies a new
Router control-flow contract. Revisit response-filter syntax only when a
specific repeated middleware pattern demonstrates that the existing explicit
helpers are too cumbersome.
