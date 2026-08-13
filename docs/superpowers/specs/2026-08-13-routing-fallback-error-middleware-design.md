# Routing Fallback and Application Error Middleware Design

**Date:** 2026-08-13

**Status:** Approved design; awaiting written-spec review

**Scope:** Replace Router-owned HTTP 404/405 handlers with request-local routing
evidence and ordinary middleware; make `PAGI::Compose` install minimal outer
404, 405, and application-error failsafes

## 1. Decision

`PAGI::Routing::Router` and its mutable frontends will stop turning an
exhausted HTTP route search directly into a response. A routing search that
completes without selecting an application records request-local facts and
returns normally without starting a response.

Three ordinary middleware classes own the corresponding response policies:

```text
PAGI::Middleware::Routing::NotFound
PAGI::Middleware::Routing::MethodNotAllowed
PAGI::Middleware::ErrorHandler
```

Applications may attach these middleware at a Compose, Router, or Mount
boundary. The same class and lifecycle apply at every boundary; there are no
parallel Router callbacks.

`PAGI::Compose` automatically wraps every target with minimal instances of all
three as outer failsafes. These defaults are mandatory, deliberately plain,
and not configured through Compose constructor options. Author-supplied
instances run inside the failsafes and get the first opportunity to produce an
official application response. Once an inner layer starts a response, every
outer fallback is inert.

Consequently:

- remove `not_found` and `method_not_allowed` from
  `PAGI::Routing::Router`;
- remove the same constructor options from `PAGI::App::Router` and therefore
  `PAGI::Endpoint::Router`;
- do not add `not_found`, `method_not_allowed`, or `server_error` options to
  `compose`;
- do not detect author middleware and suppress Compose defaults;
- do not add switches that disable individual Compose failsafes;
- retain ordinary catchall routes for applications that intentionally want
  catchall *routing* behavior; and
- retain direct Router/application compilation as the lower-level escape hatch
  for authors who do not want Compose's application-boundary guarantees.

This design applies to HTTP scopes. Existing WebSocket and SSE route-miss,
denial, close, and post-upgrade error semantics remain unchanged in this work.
Cross-protocol fallback unification requires its own design because an HTTP
response, a WebSocket denial/close, and an SSE decline do not share one wire
lifecycle.

The trace is passed explicitly to fallback handlers rather than adding routing
methods to `PAGI::Context`. Context must remain usable with applications and
third-party routers that do not implement this first-party routing contract.
The existing low-level `$context->scope` accessor can still expose the
collector to middleware authors; the design adds no convenience method that
would imply every Context has routing support.

## 2. Why the Current Shape Is Wrong

The shared routing compiler currently creates a plain-text 404 handler and a
plain-text 405 handler for every Router that does not provide custom handlers.
Those generated handlers are compiled as Context handlers, seed a cached
Response, and require special `Allow` provenance and repair logic.

That shape has four costs:

1. Every Router silently becomes a terminal application policy boundary.
2. Nested Routers cannot let an enclosing application-wide policy render an
   unresolved request without special bubbling rules.
3. The Router API duplicates what ordinary middleware already does better:
   global policy, subsystem policy, and mount-occurrence policy.
4. Adding another selection dimension such as request or response media type
   pressures the Router constructor to gain another generated-outcome callback.

A route-table miss is also valuable development information. A pleasant
default 404 can hide an omitted route or misplaced mount. Compose should keep a
valid response from leaking to the server, but its built-in response should
look like a failsafe that asks the author to install application policy, not
like the recommended public error page.

## 3. Decision History

The final design follows this sequence. This section is normative context for
implementation choices: if an implementation shortcut recreates a rejected
branch, it is contrary to the design even when its surface syntax looks
similar.

### 3.1 Start: move policy out of Router

The initial observation was that Router-level `not_found` and
`method_not_allowed` overlap application error handling and make nested routing
too eager to terminate. The first proposal moved generated responses to the
application boundary.

### 3.2 Rejected: every Router raises an HTTP condition

Having each Router raise `HTTPCondition(status => 404)` still lets a child
prematurely assign an HTTP meaning before the complete routing boundary has
finished. It also makes normal route exhaustion look like an exceptional
control flow path.

Exceptions remain correct for actual application failures. They are not the
normal Router-decline protocol in this design.

### 3.3 Refined: normal unanswered completion with explicit evidence

Literal silence alone is ambiguous:

```text
no route matched
matched Context handler returned no Response
matched raw application returned without starting a response
opaque mounted application returned without starting a response
```

Only the first is a routing decline. The compiler therefore records trusted,
request-local routing evidence. A matched Context handler without a Response
still croaks. A selected raw or opaque application that completes silently is
an incomplete PAGI response and ultimately becomes a 500.

### 3.4 Refined: Routers record facts, not HTTP conclusions

An early trace proposal stored `outcome => 'not_acceptable'`. That was rejected
because a child Router or an early candidate cannot decide the final result of
an enclosing search. Routers may record that a path, method, or future
representation candidate matched or was rejected. They do not store status
codes such as 404, 405, 406, or 415.

The trace is diagnostic evidence. It is not a public `$next` protocol and is
not trusted as the return value of an opaque application.

### 3.5 HTTP check: 404 and 405 are not symmetrical

[RFC 9110 section 15.5.5](https://www.rfc-editor.org/rfc/rfc9110.html#name-404-not-found)
defines what a 404 response means, but HTTP does not know that an application
uses a route table and does not require a framework route miss to be rendered
in one particular way.

[RFC 9110 section 15.5.6](https://www.rfc-editor.org/rfc/rfc9110.html#name-405-method-not-allowed)
says a recognized method that is unsupported by the target resource should be
a 405. Once a 405 is sent, the origin server **must** generate an `Allow`
header listing the resource's currently supported methods. PAGI therefore
supplies a compliant 405 failsafe and treats the computed method union as
authoritative for a routing-generated 405.

By contrast, RFC 9110 explicitly allows a server whose available
representations do not satisfy `Accept` either to send 406 or to disregard the
preference and send a default representation. Future `provides` evidence must
therefore remain policy input rather than an automatic Compose status.

### 3.6 Refined: middleware interprets evidence; Compose does not

Compose installs and orders the default middleware. Compose itself does not
inspect route attempts or choose among 404, 405, 406, and 415. The installed
`Routing::NotFound` and `Routing::MethodNotAllowed` middleware interpret the
currently enclosed routing boundary after it completes normally without a
response.

This distinction keeps Compose small and makes the same policy reusable on a
Router or one Mount occurrence.

### 3.7 Rejected: callback options on Compose

This API was rejected:

```perl
compose(
    not_found          => \&not_found,
    method_not_allowed => \&method_not_allowed,
    server_error       => \&server_error,
);
```

It creates a second policy mechanism beside middleware and invites one new
Compose option for every later HTTP selection or failure condition.

### 3.8 Rejected: detect replacement middleware

Compose middleware entries may be class names, configured descriptions,
objects with `wrap`, or opaque factory coderefs. A factory or caller-owned
class can provide the same policy without naming a first-party class. Detecting
only known first-party descriptors would make equivalent middleware produce a
different outer safety graph, and suppressing the outer layer would also lose
recovery when an author renderer fails. The inference becomes especially
misleading at nested boundaries.

Compose therefore never removes a default based on the author's middleware
list.

### 3.9 Final: nested inert failsafes

The automatic layers stay installed outside author middleware:

```text
Compose ErrorHandler failsafe
  private response-completion guard
    Compose Routing::NotFound failsafe
      Compose Routing::MethodNotAllowed failsafe
        author Compose middleware
          Router/application target
```

An author middleware response flows outward and makes each failsafe inert. If
an author renderer throws, the outer ErrorHandler still produces a safe 500.
The extra wrappers have a small per-request cost, accepted in exchange for one
uniform composition model and a reliable application boundary.

The built-in fallback responses intentionally do not flow outward through
author middleware because they sit outside it. They are emergency responses,
not the application's official policy. Applications that need request IDs,
access logging, security headers, or other ordinary response processing on
404/405/500 install author fallback middleware inside those ordinary layers.

The accepted runtime cost is bounded and visible: one request-local collector,
summary updates during matching, and one send-observation closure per installed
fallback/error boundary. Production does not allocate detailed attempt records,
re-run the matcher, inspect middleware classes, or render more than one
response. Performance work may later reduce allocations while preserving these
observable boundaries; it must not recover speed by merging policy APIs or
sharing mutable request state.

## 4. Goals

- Give all three Router frontends one nonterminal HTTP route-exhaustion model.
- Make ordinary middleware the only first-party customization mechanism for
  route-not-found, method-not-allowed, and application exceptions.
- Allow the same middleware at Compose, Router, and Mount boundaries.
- Preserve mount ownership and declaration-order matching.
- Preserve deterministic union-`Allow` behavior across same-path route
  declarations.
- Keep explicit handler responses untouched.
- Distinguish routing decline, handler bugs, opaque-app bugs, and exceptions.
- Give Compose a complete HTTP application-boundary guarantee.
- Make detailed route diagnostics useful in development without exposing
  internal patterns or exception text in production.
- Leave a narrow evidence model that first-party `consumes`/`provides`
  matching can extend later without redesigning middleware control flow.

## 5. Non-goals

This work will not:

- add `consumes`, `provides`, 406, or 415 routing behavior;
- define a third-party route-evidence publishing contract;
- make an opaque mounted application cooperatively decline;
- resume parent route scanning after a matched Mount's child declines;
- add per-route 404 or 405 callbacks;
- add status-specific helpers to `PAGI::Context` or `PAGI::Response`;
- add `routing_trace`, `not_found`, or `method_not_allowed` methods to
  `PAGI::Context`;
- make Compose negotiate the representation of an author's fallback;
- replace an explicit response returned by a matched handler;
- infer that an arbitrary app's silent completion means 404;
- redesign WebSocket or SSE misses and application exceptions;
- add a generalized response-valued `$next` tier; or
- optimize away author/default wrapper pairs through inspection or magic.

## 6. HTTP Request Outcomes

For HTTP requests, the complete decision tree is:

```text
Did an inner layer start a response?
|
+-- yes ----------------------------------------------------> pass it through
|
+-- no
    |
    +-- did execution throw?
    |   |
    |   +-- before response start --------------------------> ErrorHandler renders
    |   |                                                      500/default status
    |   |
    |   +-- after response start ---------------------------> report and rethrow;
    |                                                          status cannot change
    |
    +-- normal completion
        |
        +-- active route candidates matched the path but
        |   rejected the request method --------------------> MethodNotAllowed
        |                                                      renders 405 + Allow
        |
        +-- routing-aware search explicitly exhausted with
        |   no complete path candidate ---------------------> NotFound renders 404
        |
        +-- selected handler/raw/opaque app completed
        |   without a complete response --------------------> completion guard throws;
        |                                                      ErrorHandler renders 500
        |
        +-- no trusted routing evidence --------------------> completion guard throws;
                                                               ErrorHandler renders 500
```

A matched normal Context handler already has the stronger existing invariant:
it must return an immediate or Future-backed `PAGI::Response`. Returning
`undef`, manually starting a response and returning `undef`, or returning an
unrecognized value croaks with the shared handler diagnostic and takes the
exception branch.

## 7. Request-local Routing Evidence

### 7.1 Collector ownership and scope transport

The shared compiler gains a request-local evidence collector. Compose installs
a fresh collector after preparing the HEAD wire boundary but before its
ErrorHandler, completion guard, routing fallbacks, author middleware, and
target. Each first-party routing fallback also ensures that a compatible
collector exists before taking its checkpoint, so it can wrap a directly
compiled Router outside Compose. A directly compiled Router installs one only
when no compatible first-party collector is already present. Nested
routing-aware Routers reuse the same collector.

The collector is transported downward through a reserved first-party scope
extension named:

```perl
$scope->{'pagi.routing.trace'}
```

This is separate from the existing `$scope->{'pagi.routing'}` frame container
used for matched-route metadata and reverse routing. Neither key changes the
contract or value shape of the other.

The value is a first-party `PAGI::Routing::Trace` collector with public
read-only checkpoint/snapshot methods and no public mutation API. Compiler
writes require an unforgeable lexical capability; an application cannot
manufacture trusted observations merely by placing a similarly shaped hash or
object in scope. An incompatible incoming value is replaced at the first
Compose, first-party fallback, or Router boundary.

The collector reference is deliberately shared through shallow scope copies so
outer middleware sees observations recorded downstream. It is fresh for every
request and contains no application-global mutable state.

An opaque Mount and a raw route do not receive the parent collector as a
publisher channel. Their child scope is shielded from the parent collector.
The compiler records only that the opaque/raw target was selected. If a
first-party Router is passed through an explicitly opaque position, its
internal trace is not merged into the parent merely because its class happens
to be recognizable.

Routing::NotFound and Routing::MethodNotAllowed attached to an opaque Mount or
raw Route therefore remain inert: that target cannot report a trusted routing
decline at that boundary. ErrorHandler remains useful there because exceptions
do not depend on routing evidence.

### 7.2 Boundary checkpoints

Each fallback middleware takes a collector checkpoint immediately before it
invokes its inner application. After normal unanswered completion it obtains a
read-only snapshot covering only observations made inside that checkpoint.

This gives boundary-local semantics without mutating or clearing the shared
ledger:

- Compose middleware sees the complete application target beneath it;
- Router middleware sees that Router and its selected routing-aware children;
- Mount middleware sees that one mounted occurrence and its selected child;
- enclosing middleware can still inspect the broader search; and
- concurrent requests cannot share checkpoints or observations.

The observer API is:

```perl
my $collector  = $scope->{'pagi.routing.trace'};
my $checkpoint = $collector->checkpoint;

await $inner->($scope, $receive, $send);

my $snapshot = $collector->snapshot($checkpoint);
```

`checkpoint` returns an opaque marker owned by that collector. `snapshot`
rejects a marker from another request or collector. Neither method changes
matching state or consumes evidence, so overlapping middleware boundaries may
take independent snapshots safely. These two methods are the supported seam
for future author or first-party fallback middleware; code must not inspect the
collector's representation.

Internally, compiler observations form nested append-only routing frames. A
dispatcher appends a frame-begin record, candidate-attempt records, an optional
selected-child link, and one frame-completion record. An enclosing summary
follows the selected routing-aware child link rather than flattening every
partial candidate in every ancestor. This is how a child method union remains
authoritative after its Mount wins and how discarded parent partials remain
diagnostic-only.

The append-only ledger is not dispatch control flow. The compiler still uses
its local FULL/PARTIAL scan and Mount ownership rules to select work. Trace
records describe that work after each decision; changing or omitting a record
must never cause another route to run.

### 7.3 Public snapshot API

Fallback handlers receive a read-only `PAGI::Routing::Trace::Snapshot` as their
second argument. The minimum public query API is:

```perl
$trace->routing_declined;    # trusted routing-aware search ended unanswered
$trace->path_matched;        # active complete path candidate exists
$trace->method_matched;      # active candidate accepted the request method
$trace->allowed_methods;     # fresh arrayref, deterministic first-seen order
$trace->attempts;            # fresh arrayref of diagnostic attempt records
$trace->details_available;   # whether detailed attempts were collected
$trace->truncated;           # detailed attempt limit was reached
```

These methods report facts, not an HTTP outcome. There is intentionally no
`status`, `outcome`, `not_found`, `method_not_allowed`, or
`not_acceptable` accessor.

`allowed_methods` describes only the active exhausted search. Earlier partial
matches that were superseded by a later FULL route or a winning Mount remain
optional diagnostic attempts but do not contribute to the authoritative
method union.

A Mount-prefix match is not itself a complete path candidate. If a selected
routing-aware child exhausts without a leaf path candidate, the enclosing
boundary's active evidence remains `path_matched == false`.

### 7.4 Diagnostic attempt records

Summary facts required by fallback middleware are always collected. Detailed
attempt records are collected only when `PAGI::Utils::is_development()` is
true. The collector resolves that dynamic environment gate lazily on its first
compiler observation, after Compose's ErrorHandler has been entered. They are
bounded to the first 256 records per request; reaching the limit sets
`truncated` without changing matching or summary facts.

An attempt may identify a logical namespace, declaration-local pattern,
effective name, declaration description, candidate kind, and which matching
dimensions accepted or rejected the request. It must not copy request bodies,
authorization values, cookie values, database values, or decoded capture
values into the ledger.

Outside development, `attempts` returns an empty arrayref and
`details_available` is false. Author middleware still receives the stable
summary queries. Built-in production responses never expose route patterns,
namespaces, source packages, constraints, or exception text.

The detailed schema is explicitly extensible. A later first-party design may
add request-content or response-representation observations, but this design
does not reserve a status mapping for them.

## 8. Router Compiler Behavior

### 8.1 Successful selection

A FULL normal route continues to record matched-route metadata, construct the
proper Context, require a Response for HTTP handlers, and emit it. A FULL raw
route or opaque Mount continues to invoke its native PAGI application.

An explicit 404, 405, 406, 415, or 500 returned by a matched Context handler is
a complete application response. Routing fallback middleware does not inspect
or replace it. A matched-handler 405 is outside the compiler-generated 405
path; its author remains responsible for a correct `Allow` header, with
`PAGI::Middleware::Lint` free to diagnose omissions separately.

### 8.2 Exhausted path search

When a routing-aware HTTP search has no FULL candidate and no path-matched
method partial, its dispatcher records a normal routing decline with no
complete path candidate and returns without calling `$send`.

The Router no longer invokes a generated `not_found` handler.

### 8.3 Exhausted method search

When one or more complete path candidates reject only the request method, the
dispatcher records:

- that the active search matched the path;
- that it did not accept the method; and
- the union of allowed methods in deterministic first-seen order.

GET continues to contribute HEAD under the shared automatic-HEAD contract.
The dispatcher returns without calling `$send`; it does not seed a Response or
repair headers itself.

### 8.4 Full candidates supersede partial candidates

The existing FULL/PARTIAL scan remains. A later FULL candidate wins over
earlier partial candidates. If that FULL candidate is a routing-aware Mount,
its child's final active evidence controls fallback interpretation. Discarded
parent partials may appear in development attempts but must not leak into the
child result's `allowed_methods`.

### 8.5 Mount ownership

Once an inline subtree, routing-aware Router Mount, or opaque Mount wins as a
FULL prefix candidate, that Mount owns the request. If a routing-aware child
declines, the parent does not resume scanning later siblings. The decline
passes outward through middleware attached to:

1. the child Router;
2. the Mount occurrence;
3. enclosing Router boundaries; and
4. the Compose application boundary.

The first applicable fallback that responds ends the request. This preserves
the current mount-ownership model and avoids recreating generalized `$next`
control flow.

An opaque Mount cannot publish trusted evidence or cooperatively decline. If
it completes without a response, the private Compose completion guard treats
that as an incomplete application response and raises an application error.

### 8.6 Direct Router compilation

`$router->to_app` remains the explicit conversion to a native app coderef, but
it no longer installs a public 404 or 405 policy. A naked compiled Router can
therefore complete without a response on an unresolved request. Documentation
must call it a routing component that needs fallback middleware or an enclosing
Compose boundary before it is a complete public HTTP application.

This low-level behavior is intentional. Compose is the convenience boundary
that promises safe defaults.

## 9. `PAGI::Middleware::Routing::NotFound`

### 9.1 Construction

The middleware accepts one optional configuration key:

```perl
middleware(
    'Routing::NotFound',
    handler => \&not_found,
)
```

`handler` must be a coderef when supplied. Unknown options croak at middleware
construction. With no handler, the middleware uses its plain built-in
renderer.

### 9.2 Lifecycle

For an HTTP request the middleware:

1. takes a trace checkpoint;
2. wraps `$send` to observe whether `http.response.start` occurs;
3. invokes and awaits its inner application;
4. immediately rethrows any exception unchanged;
5. returns inertly if a response started;
6. obtains the checkpoint snapshot after normal unanswered completion;
7. returns inertly unless the snapshot reports a trusted routing decline with
   no complete path candidate; and
8. invokes its renderer and emits the returned Response.

Non-HTTP scopes pass through untouched. Calling the constructor or `wrap` does
not inspect environment, create a Context, or perform protocol I/O.

### 9.3 Handler contract

The handler receives exactly:

```perl
async sub not_found ($context, $trace) { ... }
```

`$context` is a `PAGI::Context::HTTP` built from the middleware's boundary
scope and original channels. `$trace` is the read-only checkpoint snapshot.
The handler must return an immediate or Future-backed `PAGI::Response`. Manual
response emission plus `undef` is invalid for the same reason it is invalid in
normal Context handlers.

The handler may return any status. This allows a deliberate redirect,
authentication result, or concealed 404 policy. The middleware does not force
the result back to 404.

Before invoking the handler, the middleware seeds that Context's cached
Response status to 404. Ordinary `$context` response helpers therefore retain
the expected status when the author omits an explicit `status` option. An
explicit status supplied by the handler wins. This is local handler setup, not
the generated Router-handler path removed by this design.

### 9.4 Built-in renderer

Outside development the built-in response is minimal:

```http
HTTP/1.1 404 Not Found
Content-Type: text/plain; charset=utf-8
Cache-Control: no-store

No application fallback handled this route.
```

In development it includes the method, requested path, bounded attempt
details, and direct advice to install application fallback middleware. All
dynamic text is safely encoded. It must not expose headers, cookies, bodies,
capture values, or arbitrary scope extensions.

The built-in renderer is a failsafe and debugging aid. Documentation must not
present it as the normal way to brand a site's 404 page.

### 9.5 Boundary examples required in POD

The middleware POD must show all three supported placements:

```perl
# Application-wide policy
compose(
    routes => \@routes,
    middleware => [
        middleware(
            'Routing::NotFound',
            handler => \&site_not_found,
        ),
    ],
);

# Reusable subsystem policy
router(
    routes => \@api_routes,
    middleware => [
        middleware(
            'Routing::NotFound',
            handler => \&api_not_found,
        ),
    ],
);

# Policy for one mounted occurrence
mount(
    '/api/v1',
    router     => $api,
    name       => 'v1',
    middleware => [
        middleware(
            'Routing::NotFound',
            handler => \&legacy_not_found,
        ),
    ],
);
```

The same three-level explanation and a cross-link belong in the
MethodNotAllowed and ErrorHandler POD.

Attaching either routing fallback as Route middleware is legal middleware-list
syntax but has no useful fallback effect: the wrapper is entered only after
that Route is FULL and selected. Its POD must say to use Router or Mount
middleware for local routing policy.

## 10. `PAGI::Middleware::Routing::MethodNotAllowed`

### 10.1 Construction and handler

Construction mirrors NotFound:

```perl
middleware(
    'Routing::MethodNotAllowed',
    handler => \&method_not_allowed,
)
```

The handler receives `($context, $trace)` and must return an immediate or
Future-backed Response. `allowed_methods` is always available in this handler
and returns a fresh arrayref.

Before invoking the handler, the middleware seeds the Context's cached
Response status to 405. It does not seed `Allow` into mutable Context state;
the authoritative field is applied to the emitted start event after the
handler returns.

### 10.2 Lifecycle

The middleware uses the same checkpoint, send observation, exception
propagation, and normal-completion lifecycle. It applies only when the active
snapshot says:

```text
routing_declined == true
path_matched     == true
method_matched   == false
allowed_methods  is a nonempty arrayref
```

It does not act on an explicit 405 sent by a selected handler or arbitrary
native application.

### 10.3 `Allow` invariant

If this middleware's renderer returns status 405, its outgoing
`http.response.start` contains exactly one authoritative `Allow` field derived
from the snapshot's deterministic method union. A missing, incomplete,
duplicated, or conflicting renderer-provided `Allow` is replaced.

The field value is the methods joined with comma followed by one space, in the
snapshot's first-seen order. Current route declarations reject an empty method
set, so a routing-generated 405 always has at least one advertised method.

If the renderer returns a status other than 405, the middleware does not add
the computed `Allow` field and removes no unrelated application header.

This lets an application customize the representation without accidentally
breaking the protocol requirement. An application that deliberately wishes to
conceal supported methods returns another status, commonly 404, rather than an
inaccurate 405.

Enforcement is local to the `Routing::MethodNotAllowed` instance that invokes
the renderer. Compose's outer default does not rewrite an arbitrary 405 emitted
by a matched handler, unrelated middleware, raw route, or opaque application.
Those are explicit application responses; `PAGI::Middleware::Lint` may warn
when one omits `Allow`.

### 10.4 Built-in renderer

The built-in response is:

```http
HTTP/1.1 405 Method Not Allowed
Allow: GET, HEAD, PUT
Content-Type: text/plain; charset=utf-8
Cache-Control: no-store

Method Not Allowed
```

Development output includes the request method and safe route-attempt metadata.
Production output remains minimal.

## 11. `PAGI::Middleware::ErrorHandler`

### 11.1 Role in this design

The existing ErrorHandler remains the application-exception middleware rather
than adding a competing `ServerError` class. This work strengthens and
documents it for use at Compose, Router, and Mount boundaries.

Because it reacts to thrown execution rather than route exhaustion,
ErrorHandler is also meaningful as Route middleware around one selected
handler. Routing::NotFound and Routing::MethodNotAllowed are not: Route
middleware runs only after that route has been selected.

It does not inspect routing evidence to turn normal declines into 404 or 405.
If an enclosed Router completes normally without a response, ErrorHandler
returns normally so an enclosing routing fallback can act.

### 11.2 Custom renderer

Add an optional `handler` callback while retaining the documented
`development`, `on_error`, `content_type`, and default-status configuration:

```perl
middleware(
    'ErrorHandler',
    handler  => \&render_server_error,
    on_error => \&report_error,
)
```

The rendering handler receives exactly `($context, $error)` and must return an
immediate or Future-backed Response. The production-safe existing renderer is
used when no handler is supplied. Existing blessed exception status handling
remains; this routing design neither introduces nor removes application-thrown
HTTP exception conventions.

Before invoking a custom handler, ErrorHandler seeds the Context's cached
Response with the status selected from its existing configuration and blessed
exception contract. An explicit handler status wins.

`on_error` is reporting, not rendering. An exception thrown by `on_error` must
not replace the original application exception.

### 11.3 Before response start

When the enclosed application throws before `http.response.start`,
ErrorHandler:

1. records the original exception;
2. invokes `on_error` when configured;
3. invokes its custom or built-in renderer; and
4. emits the returned Response.

If an author-supplied ErrorHandler renderer itself throws, that new exception
propagates to an enclosing ErrorHandler. Compose's automatic outer instance is
therefore still able to produce its minimal safe response.

Production output contains no exception text or stack. Development output may
include both, escaped for its selected representation.

### 11.4 After response start

Once `http.response.start` has been sent, a replacement 500 response is
impossible. ErrorHandler reports the original exception, does not invoke a
response renderer, and rethrows so the server can abort or terminate the
incomplete response. It never sends a second response start.

### 11.5 Normal unanswered completion

An ordinary ErrorHandler instance does not convert a trusted Router decline
into an error. Complete-response enforcement at the Compose boundary is
performed by the private guard described below.

This separation is required for local composition:

```text
child Router declines normally
child ErrorHandler returns normally
Mount or parent NotFound handles the decline
```

## 12. Compose Automatic Failsafes

### 12.1 Installed for every target

Compose installs its automatic layers for both forms:

```perl
compose(routes => \@routes)
compose(app    => $native_or_component_app)
```

The routing fallbacks act only on trusted routing evidence. A silent arbitrary
native app therefore cannot be mistaken for a 404.

Lifespan and non-HTTP scopes pass through these HTTP middleware without being
rendered as HTTP errors.

### 12.2 Exact ordering

From outermost to innermost, the compiled HTTP path is:

```text
HEAD wire boundary
fresh routing collector preparation
Compose ErrorHandler failsafe
private response-completion guard
Compose Routing::NotFound failsafe
Compose Routing::MethodNotAllowed failsafe
author Compose middleware, in declared wrapper order
target Router or application
```

The ErrorHandler is outermost among error policy so it catches exceptions from
author middleware, both routing fallbacks, and the completion guard. It
receives the collector-bearing scope, which leaves low-level route evidence
available to custom reporting without making ErrorHandler interpret it. The
HEAD wire boundary stays outside all response producers so generated fallback
and error bodies are suppressed correctly while calculated headers remain
intact.

### 12.3 Private response-completion guard

The guard is a Compose compiler invariant, not a public fallback class or
customization mechanism. It records HTTP response lifecycle events around all
routing fallbacks, author middleware, and the target.

After normal completion:

- no `http.response.start` is an incomplete application response;
- response start without a terminal `http.response.body` event is an
  incomplete application response; an absent or false `more` value is
  terminal, including a sendfile-shaped body event whose payload is expressed
  by `file`, `offset`, and `length` rather than `body`; and
- a terminal body event completes the application response.

For either incomplete case the guard throws a typed internal error. The outer
ErrorHandler renders 500 only when response start has not occurred. If start
already occurred, ErrorHandler reports and rethrows as required by section
11.4.

The guard gives Compose its complete-application promise without teaching
ErrorHandler that every locally unanswered Router is broken.

### 12.4 Default configuration

Compose's automatic instances use:

- the built-in NotFound renderer;
- the built-in MethodNotAllowed renderer;
- the production-safe ErrorHandler renderer outside development;
- development diagnostics only when
  `PAGI::Utils::is_development()` is true; and
- no application callback options.

They do not perform content negotiation. Default bodies are UTF-8 plain text
and contain `Cache-Control: no-store`.

Environment selection is dynamic per request through
`PAGI::Utils::is_development()`, matching the canonical PAGI environment
contract. An invalid nonempty `PAGI_ENV` therefore takes the application-error
path before target dispatch rather than silently selecting production
diagnostics; the automatic ErrorHandler reports it and emits the safe response.

### 12.5 No suppression or disabling

Compose does not inspect author descriptors, classes, objects, or factories to
decide whether a replacement exists. It always installs the outer layers. No
`defaults`, `without`, `not_found`, `method_not_allowed`, or `server_error`
Compose option is added.

An author who wants no automatic application boundary uses direct Router/native
application composition and installs every required layer explicitly.

## 13. Author Customization and Middleware Ordering

### 13.1 Application-wide policy

The recommended complete application order is:

```perl
my $app = compose(
    routes => \@routes,
    middleware => [
        'RequestId',
        'AccessLog',
        middleware(
            'ErrorHandler',
            handler  => \&site_server_error,
            on_error => \&report_error,
        ),
        middleware(
            'Routing::NotFound',
            handler => \&site_not_found,
        ),
        middleware(
            'Routing::MethodNotAllowed',
            handler => \&site_method_not_allowed,
        ),
    ],
)->to_app;
```

Middleware entries preserve existing declared wrapper order: earlier entries
are outer. In this example, official 404/405/500 responses travel through
AccessLog and RequestId. The author ErrorHandler encloses both author routing
fallbacks, so a renderer exception becomes the author's 500; Compose's outer
ErrorHandler remains the final recovery layer if that renderer also fails.

POD must explain that placing a fallback earlier or later changes which other
middleware observes its response. No special reordering is performed.

### 13.2 Router policy

```perl
my $api = router(
    routes => \@api_routes,
    middleware => [
        middleware(
            'ErrorHandler',
            handler => \&api_server_error,
        ),
        middleware(
            'Routing::NotFound',
            handler => \&api_not_found,
        ),
        middleware(
            'Routing::MethodNotAllowed',
            handler => \&api_method_not_allowed,
        ),
    ],
);
```

This policy applies to the Router and the routing-aware children selected
inside it. If none of these middleware responds, trusted decline evidence
remains available to an enclosing Mount, parent Router, or Compose boundary.

### 13.3 Mount-occurrence policy

```perl
mount(
    '/api/v1',
    router     => $api,
    name       => 'v1',
    middleware => [
        middleware(
            'Routing::NotFound',
            handler => \&legacy_api_not_found,
        ),
    ],
)
```

The same Router can be mounted elsewhere with a different renderer. Mount
middleware applies to that occurrence only.

### 13.4 Catchall route versus NotFound middleware

An ordinary catchall remains legal:

```perl
route('/*path' => \&spa_shell)
```

It participates in declaration order and is selected as a real route. It is
appropriate for an SPA shell or another resource that intentionally owns every
remaining path.

`Routing::NotFound` instead runs only after its enclosed routing-aware search
declines. It is the recommended application or subsystem error policy. A
parent catchall does not resume beneath a Mount that already owns a prefix;
Router- or Mount-boundary NotFound middleware handles that nested decline.

## 14. Competition Gut Check

The design follows the common "framework discovers, application renders"
shape while using one Perlish middleware mechanism at every boundary.

- [Starlette](https://www.starlette.io/exceptions/) turns route misses and
  method partials into handled HTTP exceptions at the application layer and
  lets exception handlers customize their representation. Mounted Starlette
  applications may establish their own application policy.
- [FastAPI](https://fastapi.tiangolo.com/tutorial/handling-errors/) uses the
  same Starlette exception boundary with an API-oriented default and global
  handler overrides.
- [Django REST Framework](https://www.django-rest-framework.org/api-guide/exceptions/)
  generates `MethodNotAllowed`, negotiates an API response, and supports a
  global exception handler plus per-view handling.
- [Rails](https://guides.rubyonrails.org/configuring.html#config-action-dispatch-rescue-responses)
  maps routing/controller exceptions to HTTP statuses at its application
  exception boundary.
- [ASP.NET Core status-code pages](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/error-handling#usestatuscodepages)
  most closely resemble the response split: endpoint routing establishes a
  status while middleware supplies a body, with pipeline branches providing
  local policy.

PAGI's intentional differences are:

- one middleware class works at Compose, Router, and Mount boundaries rather
  than requiring application handlers, controller overrides, and subapps as
  separate APIs;
- deterministic union-`Allow` considers all active same-path declarations,
  rather than relying on one first partial route; and
- a custom routing-generated 405 cannot accidentally discard the authoritative
  `Allow` header while retaining status 405.

## 15. Documentation Changes

Update at least:

- `PAGI::Routing` Router construction and lifecycle POD;
- `PAGI::Routing::Router` POD;
- `PAGI::Routing::Trace` and `PAGI::Routing::Trace::Snapshot` POD;
- `PAGI::App::Router` and Builder constructor documentation;
- `PAGI::Endpoint::Router` inherited-router discussion;
- `PAGI::Compose` target, middleware, ordering, and guarantee documentation;
- `PAGI::Middleware::Routing::NotFound` POD;
- `PAGI::Middleware::Routing::MethodNotAllowed` POD;
- `PAGI::Middleware::ErrorHandler` POD;
- middleware authoring/cookbook material;
- `UPGRADING.md` for removal of Router callbacks;
- `Changes`; and
- affected examples, especially the large nested application.

The two routing middleware documents must each include the application,
Router, and Mount examples from section 9.5 and explain mount ownership.
ErrorHandler must show the same boundary placements with a database failure
example and the before/after-response-start distinction.

The upgrade guide must show:

```perl
# Before
router(
    routes                 => \@routes,
    not_found              => \&not_found,
    method_not_allowed     => \&method_not_allowed,
)

# After: application policy
compose(
    app => router(routes => \@routes),
    middleware => [
        middleware('Routing::NotFound',
            handler => \&not_found),
        middleware('Routing::MethodNotAllowed',
            handler => \&method_not_allowed),
    ],
)
```

It must also show the Router-level spelling for users who intentionally want
subsystem policy rather than application policy.

## 16. Verification Requirements

### 16.1 Router selection and evidence

Tests must prove:

- no path candidate records a trusted routing decline and sends nothing;
- same-path method partials record deterministic union methods;
- GET contributes HEAD;
- a later FULL candidate supersedes prior partial evidence;
- a winning routing-aware Mount propagates only its active child summary;
- parent scanning does not resume after a selected Mount declines;
- development attempts retain discarded candidates for diagnostics without
  changing active summary facts;
- attempt details are absent outside development and bounded/truncated in
  development;
- capture values, headers, cookies, and bodies are absent from attempts;
- concurrent requests share no collector, checkpoint, or snapshot state; and
- malformed/incompatible incoming trace values are not trusted.

### 16.2 Opaque and raw applications

Tests must prove:

- opaque and raw targets cannot append trusted parent evidence;
- passing a Router through an opaque position does not merge its trace into
  the parent;
- a silent selected raw target is not converted into 404 or 405;
- a silent opaque Mount is not converted into 404 or 405; and
- a normal Context handler returning no Response remains an application error.

### 16.3 NotFound middleware

Cover default and custom renderers at Compose, Router, and Mount boundaries;
immediate and Future-backed responses; exception propagation; non-HTTP
pass-through; explicit responses untouched; nested decline propagation; and
development versus production-safe bodies.

### 16.4 MethodNotAllowed middleware

Cover all NotFound lifecycle cases plus:

- exact first-seen `Allow` order;
- one authoritative `Allow` header when a custom 405 omits, duplicates, or
  conflicts with it;
- no computed `Allow` when a custom renderer changes status;
- no rewriting of an explicit handler-generated 405; and
- no 405 from discarded partials when a later FULL route or Mount wins.

### 16.5 ErrorHandler and completion guard

Cover:

- a database-like failed Future before response start becomes a custom or
  built-in response;
- synchronous exceptions behave identically;
- routing fallback middleware rethrows exceptions rather than interpreting
  the trace;
- `on_error` failure does not replace the original exception;
- an author renderer failure reaches the outer Compose ErrorHandler;
- an exception after response start never sends a second start and is
  rethrown;
- a missing terminal body is reported and rethrown after start;
- a silent arbitrary Compose app becomes 500;
- a silent selected raw or opaque target becomes 500;
- a normal local Router decline passes through an ordinary ErrorHandler; and
- HEAD fallback/error responses preserve calculated headers while suppressing
  body bytes and sendfile bodies at the outer wire boundary.

### 16.6 Compose ordering and inert duplication

Tests must prove the exact wrapper order and that:

- Compose installs all three defaults for both `routes` and `app` targets;
- author application fallback responses prevent default fallback emission;
- author 404/405/500 responses travel through earlier outer author middleware;
- crude Compose-generated defaults intentionally do not travel through author
  middleware;
- attaching first-party middleware never causes duplicate response starts;
- Compose does not inspect or suppress author descriptors/factories; and
- no new Compose callback or disable options are accepted.

Run focused routing, middleware, Compose, App Router, Endpoint Router, Context,
HEAD, lint, example integration, documentation, and upgrade-guide tests, then
the repository suite once on the final reviewed tree.

## 17. Scope and Migration Consequences

This is an intentional breaking change to the unreleased unified routing
shape. Tests, examples, POD, cookbook code, the large application example, and
the upgrade guide must move together. Do not retain compatibility aliases for
Router constructor callbacks.

The existing generated-handler compiler paths, Response seeding, 404/405
handler compilation, and generated-`Allow` provenance repair should be removed
rather than left dormant.

The existing `PAGI::Middleware::ErrorHandler` remains the public class and must
be evolved rather than duplicated by a new `ServerError` class. Existing
documented configuration continues to work unless a separate review identifies
a direct contradiction with the response-start safety rules in this design.

## 18. Rejected Alternatives

### Keep Router callbacks

This preserves existing behavior but keeps two policy APIs, terminal nested
Routers, generated-handler machinery, and pressure for future callback fields.

### Raise typed 404/405 exceptions from each Router

This makes ordinary exhaustion exceptional and lets a nested Router assign the
HTTP conclusion too early. Real application exceptions continue to propagate;
route decline does not use them.

### Treat any silent application as NotFound

This hides matched-handler, raw-app, and opaque-app bugs as 404. Only a trusted
routing-aware decline can activate routing fallback middleware.

### Let Compose interpret the trace directly

That couples the composer to every routing selection dimension and prevents
the same policy from working unchanged on Router and Mount boundaries.
Compose installs middleware; middleware interprets evidence.

### Add Compose callback options

This is concise initially but creates two ways to configure the same behavior
and expands Compose every time a new HTTP condition appears.

### Detect and remove duplicated middleware

Descriptors, objects, and opaque factories do not reveal semantic intent.
Detection also makes a nested middleware declaration unexpectedly alter the
outer application graph.

### Add disable flags

The failsafes are cheap and inert after a response. Disabling them weakens the
meaning of Compose and creates configurations that can leak an incomplete PAGI
application. Direct composition is the explicit lower-level alternative.

### One combined application-errors middleware

One convenience object could group 404, 405, and 500 callbacks, but it
recombines routing policy and operational failure after this design separates
their lifecycles. Such a bundle can be considered later if real applications
show repeated boilerplate; it is not part of this work.
