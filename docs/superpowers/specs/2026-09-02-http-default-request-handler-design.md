# HTTP Default Request Handler Contract

**Date:** 2026-09-02

**Status:** Approved design; ready for implementation planning

**Scope:** Make Router and Compose `http_default` use the same endpoint-value
contract as an HTTP Route while leaving true application positions unchanged

## 1. Decision

`http_default` is an HTTP handler position, not a generic application position.
It accepts the same two source shapes as an HTTP Route endpoint:

1. a bare coderef is a one-argument `PAGI::Request` handler; or
2. an instantiated object with `to_app` is an app object and receives the native
   PAGI triplet after compilation.

The common reusable response case stays direct:

```perl
my $routing = router(
    routes => [
        route('/apples' => \&list_apples),
    ],
    http_default => not_found(
        detail => 'That page does not exist in the Apple demo.',
    ),
);
```

A request-dependent custom default uses the same local-handler style as Route:

```perl
http_default => sub ($request) {
    return MyApp::Response::NotFound->new(
        path => $request->path,
    );
},
```

A native three-argument coderef is never inferred at this position. It must be
marked explicitly:

```perl
use PAGI::Utils qw(as_app_object);

http_default => as_app_object(
    async sub ($scope, $receive, $send) {
        # Native PAGI application handling.
    },
),
```

This is a deliberate breaking correction to an unreleased API. No compatibility
branch or coderef-arity inspection is added.

## 2. One Positional Grammar

PAGI-Tools documents application values using these terms:

- A **request handler** is a coderef receiving one `PAGI::Request` and returning
  a PAGI application value, immediately or through a Future.
- A **native PAGI coderef** receives `($scope, $receive, $send)`.
- An **app object** is an instantiated object whose `to_app` method returns a
  native PAGI coderef.

The position determines the meaning of a bare coderef:

| Position | Bare coderef | App object |
| --- | --- | --- |
| HTTP `route` endpoint | request handler | native PAGI application |
| Router or Compose `http_default` | request handler | native PAGI application |
| Mount `app` | native PAGI application | native PAGI application |
| Other explicitly named `app` positions | native PAGI application | native PAGI application |

This makes the rule visible in the declaration. Handler positions adapt CODE;
positions explicitly named `app` consume native applications. `as_app_object`
is the narrow escape hatch for putting a native coderef in a handler position.

Mount is not changed. A one-Request handler placed in Mount `app` still requires
the explicit `request_response($handler)` adapter from `PAGI::Routing`.

## 3. Runtime Semantics

At Router compilation:

- a CODE `http_default` is wrapped once through
  `PAGI::Routing::RequestResponse`;
- an app-object `http_default` has `to_app` called once per Router compilation;
- the built-in Pages 404 remains an app object and follows the same object path;
  and
- Route CODE endpoints and CODE `http_default` values use one shared internal
  compiler path so their adaptation cannot drift.

The request handler itself runs once for each HTTP NONE outcome. Its immediate
or Future-backed result must be a native PAGI coderef or app object. That result
is invoked against the exact request scope, receive channel, and send channel.
Consumed request-body events are not replayed.

The Router's `http_default` accessor continues returning the exact declared
value. Construction does not replace a handler with an adapter or call an app
object's `to_app` method.

## 4. Routing Boundaries

The change affects only HTTP NONE:

- FULL still invokes the selected Route or Mount;
- PARTIAL still produces the Router-owned 405 and authoritative `Allow` union;
- WebSocket and SSE misses retain their protocol-specific behavior;
- unknown scope types and lifespan behavior remain unchanged; and
- Router middleware continues wrapping the dispatcher, including the selected
  HTTP default.

`http_default` does not become a catch-all Route. It has no path pattern,
methods, constraints, name, or reverse-routing entry.

`PAGI::Compose` adopts this behavior automatically because its `http_default`
option constructs the owned root Router. Compose does not add a second adapter
or a different callable grammar.

## 5. Error Contract

Invalid values fail synchronously at Router or Compose construction. The
diagnostic identifies the accepted placement contract:

```text
router http_default must be a request handler coderef or app object (an instantiated object with to_app)
```

The general native-application validator remains unchanged for Mount `app`,
`to_app`, and other true app positions.

When a request handler returns an invalid value, the runtime diagnostic is
position-neutral:

```text
request handler must return a PAGI application: a native coderef or app object (an instantiated object with to_app)
```

No response event is emitted before that failure. Existing ErrorHandler and
ResponseGuard behavior remains responsible for deployment-level reporting.

## 6. Public Helper Consequences

`request_response($handler)` remains a public, explicit export from
`PAGI::Routing`. It is no longer needed merely to configure `http_default`, but
it remains useful when a request handler must occupy a native application
position:

```perl
mount('/legacy', app => request_response(\&legacy_handler));
```

`as_app_object($native_coderef)` remains in `PAGI::Utils`. App objects pass
directly to `http_default`; applying `as_app_object` to an existing app object
continues returning it with the already-documented warning.

## 7. Documentation and Example Migration

All live documentation must show the direct app-object case first, because it
is expected to be most common:

```perl
http_default => PAGI::Pages->not_found(detail => 'Missing'),
```

The local request-handler case follows:

```perl
http_default => sub ($request) {
    return MyApp::NotFoundResponse->new(path => $request->path);
},
```

Only advanced documentation shows `as_app_object` for a native default.

`examples/declarative-routing/app.pl` removes its now-unnecessary
`request_response` wrappers. `examples/starlette-apples` remains the canary for
the preferred direct Pages application form and must keep passing unchanged in
behavior. Other examples already using Pages or Response app objects need no
syntactic migration, but the repository-wide audit must verify them.

## 8. Superseded Decisions

This design supersedes only claims that Router or Compose `http_default` is a
native application position in:

- `2026-08-26-starlette-aligned-routing-composition-design.md`; and
- `2026-08-30-route-endpoints-and-application-valued-responses-design.md`.

Their decisions about HTTP NONE ownership, Route endpoint values, Mount app
values, Pages applications, response settlement, and `request_response` remain
in force.

## 9. Non-goals

- No coderef arity or signature introspection.
- No `http_default_handler` or `http_default_app` pair.
- No change to Mount, middleware, WebSocket, SSE, 405, or exception handling.
- No new Response or Pages API.
- No compatibility alias or warning-based dual interpretation.

## 10. Verification Outcomes

Implementation is complete only when tests establish that:

1. a bare CODE default receives exactly one `PAGI::Request`;
2. immediate and Future-backed handler results are both supported;
3. Pages, Response, and custom app objects work directly;
4. app-object `to_app` runs once per Router compilation, not per miss;
5. `as_app_object($native)` preserves native triplet invocation;
6. an invalid handler result fails before response emission;
7. FULL, PARTIAL, WebSocket, and SSE outcomes never invoke the HTTP default;
8. nested and reused Routers preserve boundary-local default ownership;
9. Compose forwards the identical contract through its owned root Router; and
10. the declarative-routing and Starlette apples examples pass their integration
    tests with the documented forms.
