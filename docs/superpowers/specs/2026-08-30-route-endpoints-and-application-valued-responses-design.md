# Route Endpoints and Application-Valued Responses

**Date:** 2026-08-30

**Status:** Proposed design; awaiting review before implementation planning

**Scope:** Give Route one Starlette-aligned endpoint contract, make a Request
handler return a PAGI application value, remove the nominal Response-only
dispatch seam and public `respond` method, simplify Pages into deferred
application factories, and provide explicit utilities for native application
adaptation and invocation

## 1. Decision

PAGI-Tools will use one application boundary throughout routing and response
emission.

An HTTP Route endpoint accepts exactly one of:

1. a coderef, which is always a one-argument `PAGI::Request` handler; or
2. an instantiated object with `to_app`, which is a native PAGI application
   component selected at that exact Route.

```perl
route('/apples' => \&list_apples);
route('/manual' => file_response($manual));
route('/items'  => MyApp::ItemsEndpoint->new);
```

There is no Route `raw` mode and no coderef-arity inference. A programmer who
wants to place a native three-argument PAGI coderef in a Route wraps it
explicitly:

```perl
use PAGI::Utils qw(as_app);

route('/native' => as_app(async sub ($scope, $receive, $send) {
    ...
}));
```

The same classification applies to WebSocket and SSE leaf endpoints: a
coderef receives the normal one-argument protocol object, while a `to_app`
object owns the native triplet. `as_app` is the explicit bridge for a native
coderef. This keeps every leaf constructor predictable without retaining a
separate `raw` grammar.

A one-Request HTTP handler returns a PAGI application value, immediately or
through a Future:

```perl
async sub read_apple($request) {
    my $apple = apples_db($request)->{$request->path_param('apple_id')};

    return json_response($apple) if $apple;
    return json_response({ error => 'Apple not found' }, status => 404);
}
```

A returned application value is either:

- a native three-argument PAGI coderef; or
- an instantiated object whose `to_app` returns one.

Every `PAGI::Response` subclass is a supported, safe terminal application
value. `PAGI::Pages` factories also return safe deferred terminal application
components. Other PAGI applications may be returned deliberately, but that is
advanced dynamic delegation rather than an ordinary response shortcut. The
application author is responsible for the returned application's response
semantics.

`PAGI::Response` remains a `to_app` application family, but its public
`respond($scope, $receive, $send)` method is removed. Internal emission uses a
private seam. A raw PAGI application invokes any application value through a
shared helper:

```perl
use PAGI::Pages qw(welcome);
use PAGI::Utils qw(invoke_app);

my $app = async sub ($scope, $receive, $send) {
    return await invoke_app(
        welcome(),
        $scope, $receive, $send,
    );
};
```

This is an intentional breaking cleanup of unreleased PAGI-Tools APIs. Tests,
examples, documentation, and upgrading guidance migrate together. There is no
compatibility alias for Route `raw`, `Response->respond`, nominal
`is_response`, the current Pages source-first calls, or `request_app`.

## 2. Work map

| Repository | Work item | Branch | Base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | Route endpoints and application-valued responses | `main` | `main@2860b21ce0fb0c0831be9afd4a3adce4b43eb7bb` | This design specification only | Documentation/design; no runtime change | None requested |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI` | PAGI application and settlement contracts | released `main`; read-only | PAGI `0.002007`, core 0.5 / Www 0.4 | Normative reference only | Published on CPAN | None |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server` | PAGI loading and settlement conformance | released `main`; read-only | PAGI::Server `0.002011` | Integration reference only | Published on CPAN | None |

The implementation campaign is confined to PAGI-Tools. Before implementation
begins, its plan must record a fresh work map with the then-current branch,
base, ticket, owned files, deployment boundary, and push target. If a PAGI or
PAGI::Server defect is discovered, stop and open a separate work item rather
than silently expanding this campaign.

The untracked settlement and alignment notes currently beside this design are
user/session work and are not owned by this specification.

## 3. Governing and superseded designs

Where they conflict, this design supersedes:

- the Route `handler` versus `raw` target split in the 2026-08-03 declarative
  routing design;
- the `request_app` bridge retained by the 2026-08-26 Starlette-aligned
  routing and composition design;
- the nominal Response return contract in the 2026-08-27 Request-first
  handler design;
- the public `Response->respond` method, Route `raw` marker, and temporary
  component-target wording in the 2026-08-27 HTTP response family and
  streaming design; and
- Pages' source-first immediate-Response invocation surface in the 2026-08-14
  Pages design and the 2026-08-27 response design.

These decisions remain in force:

- `PAGI::Request` is the normal HTTP handler argument;
- `PAGI::WebSocket` and `PAGI::SSE` are the normal protocol handler arguments;
- Route is an exact complete-path leaf;
- Mount owns a path prefix, rewrites the child scope, and composes an app;
- Router selects ordered children and owns its NONE and PARTIAL outcomes;
- Compose owns the deployed root, lifespan, outer middleware, response guard,
  application-error boundary, and final HEAD boundary;
- middleware is pure three-argument app-to-app transformation;
- response classes have one representation or delivery strategy;
- File and Stream retain their request-time and settlement contracts;
- WebSocket denial and SSE decline consume compatible HTTP response apps;
- Pages owns negotiated conventional response policy; and
- no exception-based HTTP control flow is introduced.

The settlement addendum in
`.pagi-0.5-settlement-streaming-correction.md` remains authoritative
implementation context. This cleanup must preserve send-Future backpressure,
disconnect settlement, cancellation-isolated observers, denial/decline start
ownership, and File's denial-body opt-out.

## 4. Why the current shape is wrong

### 4.1 Perl needs an explicit spelling for Python callable categories

Starlette's `Route` accepts an endpoint callable. A function endpoint is
wrapped as `Request -> Response`; an `HTTPEndpoint` class is already an ASGI
application and receives the native triplet. Python can distinguish those
callable categories naturally.

Perl coderefs do not carry a reliable public arity or protocol contract. The
current API worked around that by adding `raw`, allowing component objects,
and retaining a separate `request_app` adapter. That makes the programmer
learn several placement-specific grammars.

The proposed rule is smaller:

```text
CODE              normal one-argument endpoint
object with to_app native application endpoint
```

`as_app($code)` turns the otherwise ambiguous native coderef into the second
category. The distinction is explicit at the declaration and never depends on
reflection, prototypes, signatures, naming, or whether the coderef is named or
anonymous.

### 4.2 A Response already is an application

Every Response implements `to_app`. Requiring a handler result to be
nominally `isa PAGI::Response`, then calling a separate public `respond`
method, creates a second dispatch model after routing has already normalized
everything else to PAGI applications.

The nominal check also excludes useful response-like application components
such as deferred Pages policy. The current source-first Pages functions happen
to satisfy Route's one-Request handler signature, so policy construction and
endpoint adaptation collapse into the same function. That role conflation is
a symptom of the wrong boundary.

The useful invariant is not “the return value inherits from Response.” It is
“the return value can be normalized to a PAGI application and, for ordinary
usage, emits one valid terminal HTTP response.” Response subclasses guarantee
the second property. The general application contract supplies the first.

### 4.3 Public `respond` duplicates `to_app`

Today raw applications commonly write:

```perl
my $response = json_response($data);
return await $response->respond($scope, $receive, $send);
```

Elsewhere the same value is compiled and invoked:

```perl
my $app = $response->to_app;
return await $app->($scope, $receive, $send);
```

Those are two public ways to perform the same application invocation. They
force every Response subclass and every protocol adapter to preserve an extra
method solely for convenience. `invoke_app` provides that convenience once,
for every application value, without enlarging the Response interface.

### 4.4 Pages is currently policy, value, handler, and app adapter

Pages should answer one question: which conventional negotiated terminal
response should this request receive? Today it requires an explicit Request or
scope source and immediately returns a Response. Its exported source-first
functions therefore also happen to be valid one-Request Route handlers. Pages
does not inspect arity; the problem is that one function is serving as both
policy factory and endpoint adapter, with a separate native-placement story
on top.

After this change:

```perl
PAGI::Pages->welcome()
PAGI::Pages->not_found(detail => 'No such page')

welcome()
not_found(detail => 'No such page')
```

all return deferred immutable PAGI application components. Those components
perform negotiation when invoked with an HTTP scope and emit the selected
Response through private Response machinery.

### 4.5 Alignment governs the callable boundary, not Python syntax

The goal is the same conceptual split as Starlette:

- Route adapts a request function or invokes an application endpoint;
- Response is itself an application;
- Mount composes an application beneath a prefix; and
- the server runs an application.

Perl requires `to_app` and `as_app` where Python uses callable objects. Those
are language adaptations, not new routing concepts.

## 5. Goals

The implementation must:

1. give every leaf endpoint one deterministic CODE-versus-object rule;
2. remove the Route `raw` grammar and all arity inference;
3. normalize Route endpoints once per Router compilation;
4. resolve HTTP methods from explicit declarations, endpoint capability, or a
   safe GET+HEAD default while keeping 405 ownership in Router;
5. let Request handlers return immediate or Future-backed PAGI app values;
6. guarantee that every Response subclass remains a safe terminal result;
7. document arbitrary returned apps as a deliberate advanced sharp edge;
8. remove nominal Response gating and the public `respond` method;
9. centralize app normalization and invocation in `PAGI::Utils`;
10. make Pages class methods and exported functions equivalent deferred app
   factories;
11. preserve Response snapshot, File, Stream, HEAD, WebSocket-denial, SSE-
    decline, backpressure, and settlement behavior;
12. align `PAGI::Endpoint::HTTP` and the shared Router frontends;
13. make existing middleware work through the common app invocation path
    without redesigning middleware; and
14. migrate every first-party test, example, and current user document.

## 6. Non-goals and stop conditions

This campaign does not:

- add automatic serialization of ordinary Perl values;
- inspect coderef signatures, prototypes, symbol names, or pad contents;
- infer whether a coderef is a Request handler or native app;
- offload synchronous handlers automatically;
- design an executor or worker-pool interface;
- replay or clone a request body for a dynamically returned app;
- deliver lifespan to a handler-returned app;
- merge nested Router Allow policy into an outer Route;
- make arbitrary returned apps visible to reverse routing or schema discovery;
- cache a handler-returned app or its `to_app` result across requests;
- redesign middleware conventions beyond compatibility with the new helper;
- add exception-based response control flow; or
- redesign WebSocket/SSE protocol classes.

If implementation appears to require body replay, nested lifespan forwarding,
per-request signature heuristics, hidden app caches, response-event rollback,
or several special cases for one app class, stop. Those are signs that the
application-valued result has been made responsible for more than dynamic
delegation.

Touching many files is expected because the old seam is widespread. Repeated
local hacks to force incompatible models to coexist are not expected and
require design review before continuing.

## 7. Application values and shared utilities

`as_app`, `request_response`, and `invoke_app` are opt-in exports from
`PAGI::Utils` and are included in its existing `:all` bundle. They are not
exported by default. No duplicate spellings remain in `PAGI::Routing`.

### 7.1 Application value

An application value is exactly one of:

1. a coderef implementing `($scope, $receive, $send)`; or
2. a blessed object with a `to_app` method.

Package-name strings, unblessed hashrefs, classes not instantiated by the
caller, middleware-only objects, Response-like duck types without `to_app`,
and objects relying only on callable overloading are rejected.

For an object, `to_app` is synchronous and must return a coderef. Calling the
returned app may return an immediate value or a Future; callers normalize the
completion with `Future->wrap`.

### 7.2 `to_app($value)`

The existing `PAGI::Utils::to_app` remains the one normalization primitive:

```perl
my $native = to_app($value);
```

It returns a coderef unchanged. For an object it calls `to_app` once and
validates the result. Its diagnostics distinguish an invalid input value from
an invalid `to_app` result.

### 7.3 `as_app($code)`

`PAGI::Utils` adds:

```perl
my $component = as_app($native_coderef);
```

`as_app` accepts exactly one coderef and returns an opaque immutable object
with `to_app`. That method returns the exact original coderef. The adapter does
not wrap invocation, inspect arity, alter Future behavior, capture a scope, or
add protocol policy.

Repeated calls produce distinct wrapper objects. A wrapper can be reused and
compiled at any application position. Its public promise is `to_app`; its
concrete implementation package is not a subclassing API.

### 7.4 `invoke_app($value, $scope, $receive, $send)`

`PAGI::Utils` adds an async application invocation helper:

```perl
await invoke_app($value, $scope, $receive, $send);
```

It:

1. validates and normalizes `$value` through `to_app`;
2. invokes the resulting coderef with the exact supplied triplet;
3. awaits immediate or Future-backed completion through `Future->wrap`; and
4. returns no response value of its own.

It does not validate response event completeness, rewrite scopes, install a
HEAD boundary, catch application exceptions, or provide lifespan. Those
remain responsibilities of the surrounding component or Compose root.

The name is deliberately `invoke_app`, not `respond`: the accepted value may
be a Router, Healthcheck, protocol endpoint, or another application that is
not nominally a Response.

### 7.5 `request_response($handler)`

`PAGI::Utils` adds the explicit Request-handler adapter used by Route:

```perl
my $component = request_response(async sub ($request) {
    return json_response({ ok => \1 });
});
```

It accepts exactly one coderef and returns an instantiated
`PAGI::Routing::RequestResponse` application component. The class name and
contract are public for diagnostics and composition; subclassing it is not an
initial extension seam.

This helper replaces `PAGI::Routing::request_app`. It is rarely needed in
normal routing because Route adapts CODE endpoints automatically. It remains
useful when a one-Request handler must occupy a native application position:

```perl
router(
    routes       => \@routes,
    http_default => request_response(\&custom_not_found),
);
```

The common Pages default needs no adapter because Pages already returns an
application component:

```perl
http_default => PAGI::Pages->not_found(
    detail => 'That page does not exist.',
),
```

## 8. Route API

### 8.1 Canonical object construction

The canonical immutable object API names the endpoint field directly:

```perl
my $route = PAGI::Routing::Route->new(
    path       => '/items/{id:&Int}',
    endpoint   => \&show_item,
    methods    => ['GET'],
    name       => 'show',
    constraints => {},
    middleware => [],
    desc       => 'Show one item',
);
```

`path` and `endpoint` are required. Unknown, duplicate, malformed, or odd
options croak at construction. `endpoint` is preserved for introspection.
`target` and `is_raw` are removed from the public declaration model.

The functional constructor remains the ordinary concise spelling:

```perl
route('/items/{id:&Int}' => \&show_item,
    methods => ['GET'],
    name    => 'show',
    desc    => 'Show one item',
);
```

The functional and object forms produce equivalent Route descriptions.

`PAGI::Routing::Route->new` constructs an HTTP Route. The exported
`websocket(...)` and `sse(...)` functions remain the public constructors for
those protocol leaves and apply the same CODE-versus-`to_app` classification.
This campaign does not add public `WebSocketRoute` or `SSERoute` classes merely
to make the constructor spellings symmetrical.

### 8.2 Endpoint classification

Classification occurs only from the top-level value shape:

| Endpoint value | Meaning |
| --- | --- |
| named function coderef | one-argument protocol handler |
| anonymous coderef | one-argument protocol handler |
| `as_app($native_coderef)` | native PAGI application endpoint |
| instantiated object with `to_app` | native PAGI application endpoint |
| package-name string | error |
| unblessed reference | error |

For HTTP, the one argument is `PAGI::Request`. For WebSocket it is
`PAGI::WebSocket`; for SSE it is `PAGI::SSE`. No constructor inspects the
coderef's signature.

### 8.3 Method defaults

HTTP methods follow an explicit-option, endpoint-capability, safe-default
order:

1. An explicit `methods` option always wins. The endpoint capability is not
   consulted.
2. Otherwise, an application-object endpoint with `allowed_methods` supplies
   its declared methods.
3. Otherwise, every endpoint defaults to GET with automatic HEAD.

Unrestricted matching is always explicit through the scalar
`methods => '*'`. The wildcard is a declaration mode, not an HTTP method
token: `['*']` and `['GET', '*']` croak.

```perl
# GET + automatic HEAD
route('/apples' => \&list_apples);

# Uses $endpoint->allowed_methods, including its OPTIONS policy
route('/items' => MyApp::ItemsEndpoint->new);

# GET + automatic HEAD because Response has no allowed_methods capability
route('/manual' => file_response($manual));

# Deliberately unrestricted native application
route('/relay' => as_app($native), methods => '*');
```

`allowed_methods` is an HTTP Route metadata capability. Route calls it once in
list context during immutable Route construction, before any request or
`to_app` compilation. The returned list must be nonempty, synchronous, and
contain valid HTTP method tokens. It is normalized through the same path as an
explicit method list: case is canonicalized, duplicates are removed, and GET
supplies HEAD. A Future, reference, wildcard token, empty list, or malformed
method croaks at construction. The result is a snapshot of that endpoint
instance; later endpoint mutation cannot change an already declared Route.

WebSocket and SSE leaves ignore `allowed_methods`. Those protocols do not
accept Route `methods`, and an application object used there is not queried
for an HTTP-only capability.

Resolved methods participate in normal FULL/PARTIAL selection. In particular,
`PAGI::Endpoint::HTTP->allowed_methods` exposes every implemented verb, GET's
HEAD fallback, and OPTIONS. A method outside that set is a Router-level
PARTIAL, so the Router owns the 405 response and first-seen Allow union. The
Endpoint's internal 405 remains useful when the Endpoint is standalone,
mounted as an opaque application, or explicitly placed behind broader Route
methods. OPTIONS matches the Route and reaches the Endpoint's automatic or
overridden OPTIONS handling.

This deliberately improves on Starlette's unrestricted default for every
non-function ASGI endpoint. That default is appropriate for a self-dispatching
class but unsafe for a terminal Response such as File. PAGI uses an optional
capability where the endpoint has method knowledge, a safe GET+HEAD default
where it does not, and `'*'` when the author intentionally delegates all
methods.

An earlier explicit HEAD Route may still win before a GET-supplied automatic
HEAD candidate. An unrestricted Route cannot contribute a PARTIAL method
mismatch.

### 8.4 Route and Mount remain different

Endpoint shape never changes path ownership:

```text
Route('/manual')       matches exactly /manual
Route('/*path')        is an explicit full-path wildcard leaf
Mount('/manual')       owns /manual and the complete subtree below it
```

Thus:

```perl
route('/manual' => file_response($file));
```

selects the File application only for that complete path, while:

```perl
mount('/manual', app => PAGI::App::Directory->new(root => $root));
```

delegates every matching path beneath the prefix after Mount rewrites the
child scope. Documentation for both constructors must show this contrast.

### 8.5 Compilation lifetime

Router compilation preserves the declared endpoint and records its normalized
kind for introspection.

- A CODE endpoint is wrapped in one `RequestResponse` component and compiled
  once per enclosing Router `to_app` call.
- A static `to_app` endpoint is compiled once per enclosing Router `to_app`
  call.
- An implicit `allowed_methods` capability has already been called and
  snapshotted once at Route construction; compilation does not call it again.
- Route middleware wraps the compiled application once in the existing order.
- A value returned later by a Request handler is normalized and invoked for
  that request only.

Two Router `to_app` calls therefore produce independent endpoint and
middleware compilation. One compiled Router safely serves concurrent requests
without storing per-request endpoint results.

## 9. `RequestResponse` adapter

### 9.1 HTTP invocation algorithm

For each selected HTTP request, the adapter:

1. validates that the scope is HTTP;
2. constructs or reuses the compatible request-local `PAGI::Request` facade;
3. invokes the handler with exactly that Request;
4. awaits an immediate or Future-backed result with `Future->wrap`;
5. validates that the result is an application value;
6. normalizes it with `to_app` for this invocation;
7. calls it with the exact original scope, receive, and send; and
8. awaits immediate or Future-backed application completion.

It never calls the handler twice, never calls a returned object's `to_app`
twice, and never caches the returned app across requests.

An invalid result croaks before response start with a direct diagnostic such
as:

```text
request endpoint must return a PAGI application: a coderef or instantiated object with to_app
```

If a returned app starts a response and then fails, ordinary PAGI
post-response-start error semantics apply. The adapter cannot replace or roll
back committed events. Compose's outer error and completion guards retain
their existing responsibilities.

### 9.2 Returned Response apps

Response subclasses are the normal and guaranteed-safe return values:

```perl
return text_response('ok');
return json_response($data, status => 201);
return file_response($path, inline => 1);
return stream_response(async sub ($writer) { ... });
```

They emit one terminal HTTP response, reject unsupported scope types, preserve
invocation-local snapshots, and follow the existing body, File, Stream,
backpressure, disconnect, and settlement contracts.

### 9.3 Returned arbitrary apps: advanced dynamic delegation

The adapter intentionally accepts any application value, so this is legal:

```perl
async sub health_or_details($request) {
    return PAGI::App::Healthcheck->new if $request->query_param('brief');
    return json_response(await load_details());
}
```

It is not automatically safe to return every PAGI app. The programmer must
understand all of these consequences:

- the returned app receives the current HTTP scope unchanged;
- no Mount prefix is consumed and `path`/`root_path` are not rewritten;
- it receives the remaining request stream, not a replayable body;
- if the handler already consumed body events, those events are gone;
- it receives no separate lifespan startup or shutdown;
- a returned Router or endpoint may apply a second method/routing policy;
- its names and routes are opaque to the outer Router's reverse index,
  introspection, constraints, and future schema tools;
- it may emit no response, multiple responses, or protocol-invalid events;
- it may start a response and then fail, after which replacement is
  impossible; and
- `to_app` is called per handler invocation, so expensive static construction
  belongs directly in Route, Mount, or Compose.

These are ordinary consequences of dynamic application delegation, not
features for the adapter to mask. Introductory docs show Response and Pages
returns. Arbitrary Router, Endpoint, Healthcheck, or application returns live
in an explicitly labelled advanced section.

## 10. Response application contract

### 10.1 Public surface

Every `PAGI::Response` subclass remains an independently usable application
component through `to_app`. The public `respond` method is removed. Response
continues to expose construction, metadata, header, cookie, body inspection,
subclass rendering, snapshot, and `protocol_response_capability` contracts
already defined by the response-family design.

Response delivery moves behind a protected/private emission seam used by:

- `Response->to_app`;
- first-party File and Stream subclasses;
- HeadBoundary;
- WebSocket denial and SSE decline adaptation; and
- first-party middleware only through normal application invocation.

The private seam is not a second public application protocol. Subclasses use
the documented representation and delivery hooks, not a public `respond`
compatibility method.

### 10.2 Snapshot timing

`Response->to_app` captures a stable snapshot when called.

- A Response placed directly in Route is snapshotted at Router compilation.
- A Response returned from a handler is snapshotted when that result is
  invoked for the request.
- Calling `to_app` again captures a new snapshot.
- An unchanged compiled snapshot can serve concurrent invocations.

Mutation after a particular `to_app` call does not affect that compiled app.
This is the same fresh-compilation contract as the existing response-family
design.

### 10.3 Protocol denial and settlement preservation

WebSocket `deny` and SSE `decline` continue to accept compatible Response
values. Their mapping adapters may invoke private Response emission machinery
or intercept the app's HTTP body events, but the observable contract does not
change:

- only `body-events-v1` responses are adaptable;
- File remains ineligible because PAGI denial responses do not use `file` or
  `fh` body forms;
- denial/decline start owns the response slot when its mapped send Future
  resolves, meaning the server validated and accepted the event, not that the
  client received it;
- failure before start settlement preserves pending protocol state;
- start settlement prevents accept/start or a second denial/decline;
- a mapped body send parked on backpressure may resolve at disconnect rather
  than fail; and
- cleanup keys off protocol disconnect/connection state, never a fabricated
  send failure.

Removing public `respond` must not change those state transitions or weaken
the PAGI 0.5 settlement rules.

### 10.4 Staged removal

Public `respond` removal is the final implementation phase, not a prerequisite
for Route endpoint normalization or deferred Pages applications. The earlier
phases may use the existing method internally while the application-valued
contract is established.

The final phase is mechanically constrained:

1. preserve the existing emission algorithms and move or rename only their
   invocation seam;
2. do not restructure File planning, Stream production, Writer cancellation,
   protocol mapping, or disconnect cleanup while removing the method;
3. migrate external first-party callers through `invoke_app`;
4. immediately run the existing Response, File, Stream, WebSocket-denial,
   SSE-decline, cancellation, and settlement tests; and
5. stop for design review if removal requires behavioral special cases or
   repeated workarounds.

`invoke_app` is longer than a direct `respond` call in a raw application. That
is an acknowledged ergonomics cost of retaining only one public application
interface. The common Request-handler and declarative Route cases become
shorter; raw callers receive one generic invocation helper that works for
every PAGI application value.

## 11. Pages application factories

### 11.1 One factory contract

Pages class methods, configured-instance methods, and exported functions
return deferred immutable PAGI applications:

```perl
PAGI::Pages->welcome()
PAGI::Pages->not_found(detail => 'No such page')

my $pages = MyApp::Pages->new(as => 'auto', default => 'text');
$pages->not_found(detail => 'No such page')

use PAGI::Pages qw(welcome not_found);
welcome()
not_found(detail => 'No such page')
```

A Request or scope is not a factory argument:

```perl
welcome($request);              # error
PAGI::Pages->welcome($request); # error
```

Negotiation uses the scope supplied later when the returned application is
invoked. Request-derived option values may be calculated by a handler and
passed as ordinary options, but the Request itself is never passed to Pages.

The imported and qualified styles are semantically identical:

```perl
route('/welcome' => welcome());

# Same component behavior:
route('/welcome' => PAGI::Pages->welcome());
```

Exports call the documented first-party class factory. A configured instance
or subclass method retains its explicit configuration and overridable
presentation hooks. The factory result snapshots that policy so later
mutation of the factory does not race an invocation.

The current `welcome_page`, `not_found_page`, and related source-first handler
exports are removed rather than retained as a second model. The canonical
export names are the same concise names as the class methods.

Pages exports nothing by default. Qualified class or configured-instance
calls are the canonical collision-free form for shared packages. Individual
bare functions remain opt-in Perl conveniences. The existing `:common` bundle
contains the frequently used, less generic page names but excludes collision-
prone names such as `status` and `redirect`; those remain individually
importable and are included in the deliberately broad `:all` bundle. POD must
call out that an explicit import can still replace a same-named local function.

### 11.2 Request-time behavior

The deferred Pages component performs no request I/O at construction. On HTTP
invocation it:

1. builds the Request/negotiation view from the supplied scope;
2. applies Pages policy and the captured options;
3. constructs the selected concrete Response subclass; and
4. invokes that Response through the common internal app path.

Pages therefore retains content negotiation without requiring the caller to
pass a Request into the factory.

### 11.3 Placement examples

As a Route endpoint:

```perl
route('/welcome' => welcome());
```

As a Router default:

```perl
router(
    routes       => \@routes,
    http_default => not_found(detail => 'No such page'),
);
```

As a Mount application when prefix ownership is actually intended:

```perl
mount('/demo', app => welcome());
```

As the whole server application:

```text
pagi-server -MPAGI::Pages -e 'PAGI::Pages->welcome'
```

PAGI::Server's `-M` loads the module before `-e`; `-e` accepts either a native
coderef or an instantiated object with `to_app`. The separate module-name app
form calls the named package's `new` method and is not the form shown here.

Pages and Response have identical protocol breadth: both are HTTP-only
applications and throw on lifespan, WebSocket, SSE, or unknown scope types.
Under PAGI's default automatic lifespan mode, throwing on the lifespan scope
is a conforming decline: the server continues startup and does not send later
lifespan events. Under an operator-selected strict lifespan mode, that same
decline is a fatal startup failure. The bare command is therefore appropriate
for a small demo in automatic mode; an application requiring startup,
shutdown, final HEAD handling, error policy, or response-completion guarding
uses Compose.

## 12. Application positions outside Route

Route's endpoint is the only position that adapts a bare CODE as a
one-argument handler. Native application positions keep one simpler contract:

| Position | Coderef meaning | Object meaning |
| --- | --- | --- |
| Route `endpoint` | one-argument protocol handler | native `to_app` app |
| Mount `app` | native three-argument app | native `to_app` app |
| Router `http_default` | native three-argument app | native `to_app` app |
| Compose `app` | native three-argument app | native `to_app` app |
| Middleware inner/outer app | native three-argument app | normalized where that API permits objects |

This is why `http_default => not_found(...)` works directly: the Pages factory
returns an object with `to_app`. A bare custom Request handler at that position
uses `request_response(\&handler)` explicitly.

## 13. Endpoint classes and Router frontends

### 13.1 `PAGI::Endpoint::HTTP`

HTTP endpoint verb methods return the same application values as functional
Request handlers:

```perl
async sub get($self, $request) {
    return json_response({ action => 'reading item' });
}

async sub post($self, $request) {
    my $data = await $request->json;
    return json_response({ action => 'created item', data => $data });
}
```

`dispatch` awaits the selected method once, validates an application value,
and returns it. The endpoint app invokes it through `invoke_app`; it does not
require `isa PAGI::Response` and does not call `respond`.

Automatic OPTIONS and 405 outcomes use Pages/Response application values
through the same path. HEAD-to-GET behavior and method discovery remain
unchanged unless a separate Endpoint design says otherwise.

Route accepts an instantiated Endpoint object:

```perl
route('/items' => MyApp::ItemsEndpoint->new);
```

The object form is important: application positions do not load or invoke a
package name implicitly. `PAGI::Endpoint::HTTP->to_app` must operate on the
supplied instance rather than silently allocate a different singleton and
discard constructor state.

### 13.2 Other Router frontends

The functional Router, `PAGI::App::Router`, and `PAGI::Endpoint::Router`
materialize the same immutable Route descriptions and therefore expose the
same endpoint categories, method defaults, compilation lifetime, and return
contract. A frontend may offer stylistic helpers, but may not reinterpret a
CODE endpoint as a native app or reject a valid `to_app` endpoint.

Legacy shorthand that maps a local method into middleware is migrated only as
needed to produce the same native middleware app. Its broader ergonomics are
deferred to the next middleware review.

## 14. Synchronous handlers and execution

A non-async Request handler may return an application value immediately:

```perl
sub health($request) {
    return json_response({ ok => \1 });
}
```

The adapter uses `Future->wrap`, so immediate and Future-backed results both
work. It does not move synchronous code to a worker. A blocking handler blocks
the event-loop thread.

Starlette offloads synchronous function endpoints and synchronous
`HTTPEndpoint` methods to a thread pool. PAGI-Tools deliberately defers that
feature until it has an explicit executor abstraction with cancellation,
request-context, database-handle, error, and shutdown semantics. Forking a
handler automatically is not an acceptable approximation: closures, handles,
event-loop state, and results do not cross that boundary safely by default.

The POD must warn that CPU-heavy or blocking synchronous handlers need an
application-selected async/executor strategy.

## 15. Middleware scope

Pure middleware remains:

```text
native app -> native app
```

Middleware that emits a stock response uses `invoke_app` instead of calling
`Response->respond`:

```perl
return await invoke_app(
    json_response({ error => 'Unauthorized' }, status => 401),
    $scope, $receive, $send,
);
```

First-party middleware is migrated to the common helper. Existing response
replacement, start interception, HEAD handling, streaming, and exception
semantics remain intact. This campaign does not invent a one-Request
middleware signature, redesign local-method middleware, or add handler-value
flow through `$next`.

If migration reveals that a middleware genuinely needs a protected Response
emission hook rather than normal application invocation, stop and identify the
specific protocol requirement. Do not add `respond` back under another name.

## 16. Apple example

### 16.1 Current shape

The current example needs two adapters around the otherwise simple model:

```perl
use PAGI::Pages qw(welcome_page not_found_page);
use PAGI::Routing qw(route mount router request_app);

sub root_not_found($request) {
    return not_found_page(
        $request,
        detail => 'That page does not exist in the Apple demo.',
    );
}

compose(
    app => router(
        routes => [
            route('/' => file_response($manager_file, inline => 1),
                name => 'home'),
            route('/welcome' => \&welcome_page,
                name => 'welcome'),
            mount('/apples', routes => [ ... ]),
        ],
        http_default => request_app(\&root_not_found),
    ),
    lifespan => { startup => \&startup },
);
```

`welcome_page` is a source-first immediate-response factory whose signature
also happens to satisfy Route's one-Request handler contract, while
`request_app` converts another such handler back into an application. Response
values are simultaneously treated as a special nominal return type and as
`to_app` objects.

### 16.2 Proposed shape

```perl
#!/usr/bin/env perl
use v5.40;

use Future::AsyncAwait;
use List::Util qw(max);
use Types::Standard qw(Int);

use PAGI::Compose qw(compose);
use PAGI::Pages qw(welcome not_found);
use PAGI::Response qw(file_response json_response);
use PAGI::Routing qw(route mount router);
use PAGI::Routing::URL qw(url_for path_for);
use PAGI::Utils qw(app_path);

my $manager_file = app_path('public', 'index.html');

sub startup($state, $scope) {
    $state->{apples_db} = {
        1 => { id => 1, name => 'Gala',       color => 'Red/Yellow' },
        2 => { id => 2, name => 'Honeycrisp', color => 'Rosy Red' },
    };
    return;
}

sub apples_db($request) {
    my $state = $request->state
        or die 'starlette-apples requires Compose lifespan state';
    return $state->get('apples_db');
}

async sub list_apples($request) {
    my $db = apples_db($request);
    return json_response([
        map {
            +{
                %{$db->{$_}},
                url => url_for($request, 'read', { apple_id => $_ }),
            }
        } sort { $a <=> $b } keys %$db
    ]);
}

async sub read_apple($request) {
    my $id = $request->path_param('apple_id');
    my $apple = apples_db($request)->{$id};

    return json_response($apple) if $apple;
    return json_response({ error => 'Apple not found' }, status => 404);
}

async sub create_apple($request) {
    my $db = apples_db($request);
    my $data = await $request->json;
    my $id = max(0, keys %$db) + 1;
    my $apple = { id => $id, %$data };
    $db->{$id} = $apple;

    return json_response(
        $apple,
        status  => 201,
        headers => [
            Location => path_for($request, 'read', { apple_id => $id }),
        ],
    );
}

async sub update_apple($request) {
    my $db = apples_db($request);
    my $id = $request->path_param('apple_id');

    return json_response({ error => 'Apple not found' }, status => 404)
        unless exists $db->{$id};

    my $data = await $request->json;
    $db->{$id} = { %{$db->{$id}}, %$data };
    return json_response($db->{$id});
}

async sub delete_apple($request) {
    my $db = apples_db($request);
    my $id = $request->path_param('apple_id');

    return json_response({ error => 'Apple not found' }, status => 404)
        unless exists $db->{$id};

    return json_response({
        success => \1,
        deleted => delete $db->{$id},
    });
}

compose(
    app => router(
        routes => [
            route('/' => file_response($manager_file, inline => 1),
                name => 'home',
                desc => 'Apple manager SPA',
            ),
            route('/welcome' => welcome(),
                name => 'welcome',
                desc => 'PAGI welcome page',
            ),
            mount('/apples',
                routes => [
                    route('/' => \&list_apples,
                        methods => ['GET'], name => 'list'),
                    route('/' => \&create_apple,
                        methods => ['POST'], name => 'create'),
                    route('/{apple_id:&Int}' => \&read_apple,
                        methods => ['GET'], name => 'read'),
                    route('/{apple_id:&Int}' => \&update_apple,
                        methods => ['PUT'], name => 'update'),
                    route('/{apple_id:&Int}' => \&delete_apple,
                        methods => ['DELETE'], name => 'delete'),
                ],
                name => 'apples',
                desc => 'Apples API namespace',
            ),
        ],
        http_default => not_found(
            detail => 'That page does not exist in the Apple demo.',
        ),
    ),
    lifespan => { startup => \&startup },
);
```

The shorter imported style is merely Perl style. This is equivalent:

```perl
route('/welcome' => PAGI::Pages->welcome());
```

The improvement is structural, not merely fewer lines:

- Route has one endpoint rule;
- Pages produces an application directly;
- `http_default` receives the application it already requires;
- Response factories remain plain handler returns and direct components;
- no source-first Pages function exists; and
- no nominal Response-only dispatch path remains.

The example's lifespan-backed hash store is intentionally unchanged. Its data
encapsulation is a separate example-design question.

## 17. Diagnostics and validation

Construction-time errors must identify the placement and accepted shapes:

```text
route endpoint must be a coderef or instantiated object with to_app
as_app application must be a coderef
request_response handler must be a coderef
router http_default must be a native coderef or instantiated object with to_app
PAGI::Response::X->to_app must return a coderef
```

Invocation-time errors distinguish:

- handler threw before returning;
- handler returned an invalid application value;
- returned object's `to_app` threw;
- returned object's `to_app` returned a non-coderef;
- returned application failed before response start;
- returned application failed after response start; and
- returned application completed without a valid response, when the
  surrounding Compose response guard observes that condition.

Errors retain the original exception and do not replace it with a cleanup or
logging failure. No diagnostic should claim that a valid arbitrary app is a
Response.

## 18. Migration and documentation

The upgrading guide must include before/after entries for:

### 18.1 Route raw app

```perl
# Before
route('/native', raw => $native_app);

# After
route('/native' => as_app($native_app));
```

Both forms default to GET+HEAD. A native application intended to receive every
HTTP method declares that explicitly:

```perl
route('/native' => as_app($native_app), methods => '*');
```

### 18.2 Handler return and emission

```perl
# Before
croak unless is_response($result);
await $result->respond($scope, $receive, $send);

# After
await invoke_app($result, $scope, $receive, $send);
```

### 18.3 Raw application emission

```perl
# Before
await json_response($data)->respond($scope, $receive, $send);

# After
await invoke_app(json_response($data), $scope, $receive, $send);
```

### 18.4 Pages

```perl
# Before
use PAGI::Pages qw(not_found_page);
return not_found_page($request, detail => 'Missing');

# After
use PAGI::Pages qw(not_found);
return not_found(detail => 'Missing');
```

### 18.5 Router default

```perl
# Before
http_default => request_app(\&not_found_page)

# After
http_default => not_found(detail => 'Missing')
```

For a custom Request handler:

```perl
http_default => request_response(\&custom_not_found)
```

### 18.6 Endpoint object

```perl
# Before or ambiguous
route('/items' => 'MyApp::ItemsEndpoint')
route('/items', raw => MyApp::ItemsEndpoint->to_app)

# After
route('/items' => MyApp::ItemsEndpoint->new)
```

The guide must explain method resolution: explicit methods win; otherwise an
HTTP object may supply a snapshotted `allowed_methods`; otherwise the safe
default is GET+HEAD; and unrestricted matching requires scalar
`methods => '*'`. It must also explain that a routed `PAGI::Endpoint::HTTP`
now contributes its verbs and OPTIONS to Router selection and Allow unions,
so Router owns unsupported-method 405s at that boundary.

POD updates include at least:

- `PAGI::Routing`, Route, Mount, Router, and application positions;
- `PAGI::Utils` app normalization/adaptation/invocation helpers;
- the complete Response family and subclassing guide;
- Pages factory, negotiation, class, configured-instance, and export forms;
- `PAGI::Endpoint::HTTP` and both Router frontends;
- WebSocket denial and SSE decline;
- Compose, Middleware Builder, Tutorial, Cookbook, and UPGRADING;
- the Route-versus-Mount exact-path/prefix distinction; and
- the arbitrary-returned-app sharp edge.

Historical superpowers specs remain historical and are not rewritten. Current
POD, examples, tests, Changes, and upgrading documentation must describe only
the new model.

## 19. Examples and repository migration

Every maintained example using `request_app`, `Response->respond`, old Pages
exports, or Route `raw` must migrate. The implementation plan starts from a
fresh repository search rather than relying only on this initial inventory.

Known examples include:

- `examples/starlette-apples`;
- `examples/15-large-application`;
- `examples/declarative-routing`;
- `examples/pages`;
- `examples/endpoint-router-demo` and `examples/endpoint-demo`;
- `examples/websocket-chat-v2`;
- `examples/background-tasks`;
- `examples/13-contact-form`;
- `examples/14-lifespan-utils`; and
- `examples/test-lifespan-shutdown`.

Each migrated example must use the clearest placement rather than applying
`invoke_app` mechanically everywhere. A static response/application belongs
directly in Route or Mount; a Request-derived response is returned from the
handler; a native app uses `as_app` only at a Route endpoint; and a raw
three-argument dispatcher uses `invoke_app` when it actually needs to delegate.

The Starlette apples README retains the original Python application and adds
an updated focused comparison explaining the callable-to-Perl mapping.

## 20. Required tests

The implementation plan owns the granular test matrix. At the design level,
verification must establish these outcomes:

- every application utility enforces its declared CODE/object boundary,
  preserves the exact triplet, and correctly awaits immediate and
  Future-backed completion without arity inference;
- functional and object Route construction preserve the original endpoint,
  declaration order, exact-leaf ownership, middleware order, constraints, and
  independent compilation;
- explicit methods, snapshotted `allowed_methods`, GET+HEAD fallback, and
  scalar `'*'` follow the precedence and validation rules in section 8.3;
- a routed Endpoint contributes HEAD and OPTIONS, unsupported methods produce
  Router-owned PARTIAL/405 outcomes, and Allow unions retain deterministic
  first-seen ordering;
- WebSocket and SSE endpoints never consult the HTTP method capability;
- Request handlers return immediate or Future-backed Response and general app
  values with the documented per-invocation compilation, failure, remaining-
  body, unchanged-scope, and concurrency behavior;
- every Response subclass preserves snapshot, HEAD, File, range, Stream,
  backpressure, disconnect, cancellation, denial, decline, and settlement
  behavior through `to_app` and `invoke_app`;
- the final mechanical `respond` removal passes the existing lifecycle and
  cancellation suites before any later cleanup proceeds;
- Pages class, configured-instance, subclass, and opt-in export forms produce
  equivalent deferred behavior, negotiate at invocation, reject old
  source-first forms, and decline non-HTTP scopes—including lifespan—without
  emitting protocol events;
- direct Pages deployment starts under automatic lifespan mode and is rejected
  under strict lifespan mode;
- Endpoint::HTTP and all Router frontends share endpoint classification,
  method capability, app-valued results, and instance-lifetime behavior;
- every maintained example and tested Tutorial/Cookbook snippet migrates and
  the apples integration continues covering CRUD, reverse links, welcome,
  custom default, method outcomes, and constraints; and
- final searches over current code, examples, POD, Changes, and upgrading docs
  find no unintended `request_app`, public `respond`, `is_response`, old Pages
  export, or Route `raw` usage. Historical design records are exempt.

Task-focused tests run after each implementation unit. The repository's full
suite runs once at the final integration boundary; there is no project-specific
reason to run it twice.

## 21. Adversarial review and rulings

### 21.1 “Any returned PAGI app is too broad”

This is the strongest objection. An arbitrary app can consume the remaining
body, apply another method policy, remain opaque to introspection, or emit an
invalid response.

The design keeps the broad structural contract because it is the closest PAGI
equivalent of returning an ASGI-callable Response and enables useful dynamic
delegation. It does not pretend all apps are equally suitable. Response
subclasses and Pages are the guaranteed safe ordinary path; arbitrary apps
are documented as advanced, uncached, opaque delegation with explicit sharp
edges. The adapter adds validation of app shape, not speculative behavioral
policing.

### 21.2 “Route objects overlap with Mount”

Both can invoke an app, but they do not own the same path. Route selects one
exact method-aware leaf; Mount consumes a prefix, rewrites the scope, and owns
the subtree. This is the same meaningful overlap present when Starlette Route
selects an `HTTPEndpoint` ASGI app. Docs must teach path ownership, not ban
application endpoints.

### 21.3 “Use one coderef convention everywhere”

Native application positions already have an unambiguous three-argument
contract. Route is specifically the adapter boundary that makes the common
one-Request handler concise. Treating every Route CODE as native would make
ordinary handlers verbose; guessing arity would make behavior magical.
`as_app` is the small explicit language bridge.

### 21.4 “Keep `respond` because it is convenient”

Convenience is real, but a Response-only method preserves the false idea that
emission is a second protocol. `invoke_app` is equally direct and works for all
application values. One normalization/invocation helper also gives middleware,
Endpoint, Pages, and raw apps one tested failure and Future contract.

### 21.5 “Compile every returned object once”

There is no stable lifetime at which to cache a dynamically returned object's
app. It may capture request-specific options or mutable response state.
Per-invocation `to_app` is honest. Static or expensive components belong at
Route, Mount, Router default, or Compose where compilation occurs once per
enclosing `to_app` call.

### 21.6 “Automatically offload synchronous handlers”

Starlette's behavior is useful, but PAGI-Tools has no executor contract today.
Silently forking or selecting an implementation-specific thread pool would
create larger lifecycle and handle-safety problems than it solves. Immediate
returns remain supported; blocking work is documented until an executor is
designed separately.

### 21.7 “Preserve old Pages handler exports as aliases”

Aliases would preserve two mental models: source-first immediate response
construction and source-free deferred application construction. The API is
unreleased and the examples are migrating together. Removing the old form is
clearer than carrying a source-first alias indefinitely.

## 22. Source references

The Starlette comparison is grounded in its current routing and endpoint
contracts rather than only surface resemblance:

- [Starlette Routing](https://www.starlette.io/routing/) documents function
  endpoints, `Route`, `Mount`, reverse lookup, and method declarations;
- [Starlette Endpoints](https://www.starlette.io/endpoints/) documents
  `HTTPEndpoint` and `WebSocketEndpoint` as ASGI applications with method or
  encoding dispatch;
- [Starlette route source](https://github.com/Kludex/starlette/blob/main/starlette/routing.py)
  shows the runtime distinction between function/method endpoints and native
  ASGI application callables; and
- [Starlette response source](https://github.com/Kludex/starlette/blob/main/starlette/responses.py)
  shows Response, FileResponse, and StreamingResponse as independently
  callable ASGI applications.

PAGI's published specifications remain authoritative for event validity,
application completion, send-Future settlement, response-start ownership,
File body events, WebSocket denial, and SSE decline. Starlette guides the
toolkit's composition boundaries; it does not override PAGI wire semantics.

## 23. Acceptance criteria

The design is complete when:

- Route endpoint means CODE handler or instantiated application object with no
  `raw` branch;
- `as_app`, `request_response`, and `invoke_app` are the only named bridges
  required for their respective boundaries;
- Request handlers return application values and every Response subclass is a
  safe ordinary result;
- invalid results fail before invocation with a useful diagnostic;
- direct and dynamic application compilation lifetimes are pinned by tests;
- Route method resolution follows explicit declaration, snapshotted
  `allowed_methods`, then GET+HEAD, with Router-owned PARTIAL/405 outcomes;
- public `Response->respond` and nominal `is_response` dispatch are gone;
- Pages factories return deferred applications with equivalent class/import
  styles, preserve negotiation, export nothing by default, and decline every
  non-HTTP scope;
- Route-versus-Mount path ownership and method defaults are explicit;
- Endpoint::HTTP and all Router frontends share the contract;
- middleware uses common application invocation without a redesign;
- File, Stream, HEAD, denial/decline, backpressure, and settlement behavior is
  unchanged;
- the apples and other maintained examples use the new model naturally;
- current docs and upgrading guidance contain no contradictory old contract;
  and
- the implementation is clean enough that no replay, caching, reflection, or
  special-case hack was needed to force the design to work.
