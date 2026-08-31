# Request-First Handlers and Scope-Bound Helpers

**Date:** 2026-08-27

**Status:** Approved design; implementation planning follows

**Scope:** Replace `PAGI::Context` as the normal routing handler argument with
the existing protocol objects, move router- and middleware-specific
conveniences into explicit scope-bound helpers, and make HTTP request state and
connection access safer without redesigning `PAGI::Response`

## 1. Decision

Normal declarative HTTP handlers will receive a `PAGI::Request`:

```perl
async sub show_apple($request) {
    my $apple_id = $request->path_param('apple_id');
    my $apple = $request->state->get('apples_db')->{$apple_id};

    return PAGI::Response->json($apple) if $apple;
    return PAGI::Response->json(
        { error => 'Apple not found' },
        status => 404,
    );
}
```

Normal WebSocket and SSE handlers will receive `PAGI::WebSocket` and
`PAGI::SSE`, respectively. Raw routes and native applications retain the PAGI
three-argument contract `($scope, $receive, $send)`.

`PAGI::Request` will contain intrinsic HTTP request data and body consumption.
Capabilities supplied by a router or middleware will be obtained through
explicit, reusable helpers such as:

```perl
use PAGI::Routing::URL qw(url_for path_for);
use PAGI::Session qw(session);
use PAGI::Stash qw(stash);

my $canonical = url_for($request, 'show', { apple_id => 2 });
my $location  = path_for($request, 'show', { apple_id => 3 });
my $user_id   = session($request)->get('user_id');
my $trace_id  = stash($request)->get('trace_id');
```

Every scope-bound helper accepts either an unblessed PAGI scope hashref or a
blessed object whose `scope` method returns one. The same helpers therefore
work in a normal Request handler and in a raw PAGI application.

This design deliberately stops short of redesigning `PAGI::Response` and
`PAGI::Pages`. HTTP handlers continue returning an immediate or Future-backed
`PAGI::Response`; the routing adapter remains responsible for sending it. A
minimal Pages compatibility seam lets existing Pages endpoints accept a
`PAGI::Request`, but the broader response-factory design is a later phase.

This is an intentional breaking redesign of unreleased PAGI-Tools APIs. The
implementation updates tests, examples, and documentation rather than carrying
dual handler conventions.

## 2. Work map

| Repository | Ticket | Branch | Base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | Request-first handlers and scope helpers | `main` | `main@1d780068088ea0c9080e1e9ad72ab3321f9644bc` | This design plus predecessor-status reconciliation | Documentation/design; no runtime change | None unless separately authorized |

The eventual implementation is confined to PAGI-Tools. It does not change the
PAGI protocol or PAGI::Server. Before implementation begins, its execution
plan must record a fresh work map because the branch and base will differ from
this design-only commit.

The 2026-08-26 Starlette-aligned routing-composition campaign is already
implemented on this design's base in the 23-commit range ending at
`1d780068088ea0c9080e1e9ad72ab3321f9644bc`. This is the deliberately ordered
second migration: routing topology first, handler arguments and helper
ownership second. It is not a pair of unimplemented campaigns awaiting a
combined execution.

## 3. Governing and superseded designs

Where they conflict, this design supersedes:

- the Context-handler portions of the 2026-08-03 declarative-routing design;
- the Request/Context convenience-method allocations in the 2026-08-04
  Context/Response compatibility design;
- the Context-based reverse-routing surface of the 2026-08-08 Router-mount
  reverse-routing design;
- the Context construction and helper surface in the 2026-08-10 unified
  Router-frontends design;
- the Context examples in the 2026-08-14 Pages response-factory design;
- the Context portions of the 2026-08-16 Starlette apples example; and
- the normal Route handler argument described by the 2026-08-26
  Starlette-aligned routing-composition design.

The following decisions remain in force:

- Route matches paths and methods; Mount composes applications; Router selects
  ordered children; Compose owns the deployed root and lifespan;
- Router-owned HTTP NONE and PARTIAL outcomes;
- normal HTTP handlers return Responses while raw applications own protocol
  events;
- pure three-argument PAGI middleware at every middleware boundary;
- route constraints validate without coercing captured values;
- slash-addressed names, relative reverse lookup, query values, and fragments;
- shared compilation for functional, mutable, and Endpoint Router frontends;
- `PAGI::Pages` as the stock negotiated response factory; and
- `PAGI::Context`'s extensibility record for custom event types, until Context
  is removed in a later compatibility phase.

## 4. Why change the current design

### 4.1 Context combines unrelated owners

The current HTTP Context combines at least five concerns:

1. incoming HTTP request data and body parsing;
2. response construction and sending;
3. declarative Router reverse lookup;
4. middleware-installed session, stash, and CSRF facilities; and
5. server connection and transport state.

That is convenient when one framework owns all five concerns. PAGI-Tools is a
toolkit, however. A user can write a different Router, install a different
session representation, or use only the raw PAGI protocol. A neutral HTTP
request object should not imply that all those choices came with it.

The large Context also obscures where behavior originates. `$c->url_for` looks
like an HTTP operation even though it requires a compatible declarative Router
frame. `$c->session` looks intrinsic even though Session middleware must have
run first. `$c->buffered_amount` looks like request data even though it is an
optional outbound transport capability.

### 4.2 Protocol-specific objects already provide the clearer shape

PAGI-Tools already has `PAGI::Request`, `PAGI::WebSocket`, and `PAGI::SSE`.
Context subclasses mostly wrap those objects and forward methods. Passing the
protocol object directly removes a layer without discarding the useful work
already present in those classes.

The names are siblings rather than an inheritance tree:

```text
PAGI::Request      HTTP request and input body
PAGI::WebSocket    WebSocket connection and events
PAGI::SSE          SSE stream and events
PAGI::MCP          possible future event-type object
```

WebSocket, SSE, and a possible MCP event type are not kinds of HTTP Request.
Their common contract is deliberately small and duck typed: they expose their
PAGI `scope` when a protocol-neutral helper needs it.

### 4.3 Imports make capability ownership visible

This code says where reverse routing comes from:

```perl
use PAGI::Routing::URL qw(url_for);

my $href = url_for($request, '/person/show', { person_id => 42 });
```

A framework with its own Router need not emulate a Request method or populate
private PAGI::Routing metadata. It can expose its own URL builder. Conversely,
a raw PAGI application using PAGI::Routing can opt into the same helper by
passing `$scope`.

This follows the compositional style already used by `PAGI::Compose`: a small
core object plus explicitly imported tools, rather than one object accumulating
every feature in the distribution.

### 4.4 Starlette alignment governs topology, not every method

The 2026-08-26 design aligns Route, Mount, Router, middleware, and application
composition with Starlette because those responsibilities transfer cleanly.
Starlette also exposes router-, application-, and middleware-owned facilities
through its Request, including URL generation, session, and mutable state.
PAGI-Tools deliberately does not copy that part of the surface.

In a Perl toolkit, an import makes optional capability ownership visible at the
top of the file. Keeping Request neutral also lets a higher-level framework add
its own controller conveniences or use a different Router without first
undoing PAGI::Routing coupling. Alignment therefore means familiar routing
concepts retain familiar responsibilities; it does not mean API-by-API parity
with Starlette's Request object.

## 5. Goals

This design must:

1. make the normal handler argument match the selected protocol;
2. keep HTTP input parsing and negotiation on `PAGI::Request`;
3. keep raw PAGI application and middleware signatures unchanged;
4. remove declarative-Router URL generation from the neutral Request surface;
5. give Router users a concise object and functional URL API;
6. make Stash, Session, CSRF, State, and Transport follow one source contract;
7. make scope-bound helpers cheap, identity-free facades whose backing data is
   selected solely by the supplied scope;
8. replace typo-prone Request state hash access with a strict wrapper while
   providing a temporary, warned hash-dereference bridge;
9. preserve current body-consumption behavior and Response return behavior;
10. migrate every first-party Router frontend, example, and relevant document;
    and
11. provide a focused upgrading guide suitable for PAGI-Tools users and the
    Thunderhorse maintainer.

## 6. Non-goals and deferred ledger

The following work is explicitly outside this implementation:

| ID | Deferred work | Reason |
| --- | --- | --- |
| `LATER-RESPONSE` | Redesign `PAGI::Response`, its factory spellings, or the send boundary | Response deserves a separate review after the handler input is simplified |
| `LATER-PAGES` | Add full object/export parity to `PAGI::Pages` or redesign Pages around Request | This phase adds only the minimal Request source seam required by normal handlers |
| `LATER-CONTEXT` | Delete the `PAGI::Context` class family | Routing stops constructing it now; removal and any final compatibility accounting are separate |
| `LATER-AUTH` | Design `PAGI::Auth`, authentication middleware, identity, permission enforcement, and configurable 401/403 challenges | Authentication is more than parsing an Authorization field and belongs with the later response policy work |
| `LATER-THUNDERHORSE` | Modify Thunderhorse itself | This repository supplies an upgrade document; the external framework migrates separately |
| `LATER-ALIASES` | Remove deprecated `query`, `raw_query`, `form`, and `raw_form` aliases | Alias cleanup is independent of handler migration |
| `LATER-RAW` | Remove `PAGI::Request->raw` in favor of `scope` | This duplicate escape hatch does not block the new contract |
| `LATER-ROUTER-PROVIDER` | Define a universal URL-generation provider contract for unrelated Routers | The first version is honestly named and coupled to `PAGI::Routing` |
| `LATER-CONTEXT-EXTENSIONS` | Decide how a generic Context replacement registers custom event types such as MCP | Direct protocol objects remove the immediate need for a generic factory |

This design does not add `$request->needs_auth`, `$request->url`,
`PAGI::Request::JSON`, value-flow middleware, exception-based HTTP control
flow, or a common superclass for all protocol objects.

## 7. Handler contracts

### 7.1 Contract table

| Declaration | Normal argument | Completion contract |
| --- | --- | --- |
| `route($path => $handler)` | `PAGI::Request` | Return an immediate Response or a Future resolving to a Response |
| `websocket($path => $handler)` | `PAGI::WebSocket` | Perform protocol operations through the object; immediate or Future completion is awaited |
| `sse($path => $handler)` | `PAGI::SSE` | Perform protocol operations through the object; immediate or Future completion is awaited |
| `route($path, raw => $app)` | `($scope, $receive, $send)` | Native PAGI application contract |
| Mount child application | `($scope, $receive, $send)` | Native PAGI application contract |
| Any middleware | wraps `($scope, $receive, $send)` | Pure PAGI app-to-app transformation |

The routing compiler constructs exactly one selected protocol object for the
leaf's exact scope:

```perl
# HTTP adapter, conceptually
my $request  = PAGI::Request->new($scope, $receive);
my $returned = $handler->($request);
my $response = await Future->wrap($returned);

croak 'handler did not return a response'
    unless PAGI::Utils::is_response($response);

await Future->wrap($response->respond($send));
```

The HTTP Request intentionally has no `$send`. A handler that must own event
ordering, send manually, or return without a Response uses `raw => $app`.

WebSocket and SSE objects retain `$receive` and `$send` internally because
their public purpose is to operate a bidirectional connection or stream. Their
handlers are not Response factories.

### 7.2 Immediate and Future-backed handlers

All three normal handler adapters use `Future->wrap` around the handler's
return. A synchronous HTTP handler may return a Response directly; an
`async sub` may return it through its Future. WebSocket and SSE handlers may
likewise complete immediately or asynchronously.

The adapter must not apply `await` directly to a plain Response or other
immediate value.

### 7.3 Router defaults and Pages endpoints

A Router `http_default` remains a native application, not a Request handler.
Router-generated 405 remains Router-owned. Pages endpoint coderefs retain their
dual use:

- one `PAGI::Request` argument returns a Response for a normal HTTP Route; and
- three native PAGI arguments send the Response for `app`, `raw`, Mount, and
  middleware application positions.

The required Pages change is narrow: any blessed request source with a
`scope()` method returning an unblessed HTTP scope is accepted anywhere Pages
currently accepts `PAGI::Context::HTTP`. No renderer, catalog, negotiation,
favicon, or endpoint-shape redesign belongs to this phase.

This one-versus-three-argument endpoint is an explicitly retained Pages
interoperability exception. It bridges the normal-handler and native-app
positions already supported by Pages; it is not precedent for arity-dependent
return types in new helper APIs and remains reviewable under `LATER-PAGES`.

## 8. `PAGI::Request` public surface

### 8.1 Constructor and identity

```perl
my $request = PAGI::Request->new($scope, $receive);
```

Construction requires an unblessed hashref whose explicit type is `http` and a
receive coderef. It does not accept `$send`, infer a missing type, or act as a
factory for custom event types.

`scope` is the canonical raw escape hatch and returns the exact scope hashref.
`raw` remains temporarily as the existing alias under `LATER-RAW`.

### 8.2 Intrinsic scalar and tuple data

Request retains or gains these accessors:

```text
method          path             raw_path
query_string    scheme           http_version
client          server           host
scope           raw
```

`server` returns the PAGI scope's local endpoint tuple unchanged:

```perl
[$host, $port]
[$unix_socket_path, undef]
```

It is not the public Host header, a canonical authority, or an object suitable
for constructing external URLs. `host` continues to delegate canonical Host
selection and duplicate/invalid-field handling to `PAGI::Authority`.
`PAGI::Routing::URL` also uses `PAGI::Authority`; it never substitutes
`server` for invalid public authority data.

### 8.3 Headers, cookies, parameters, and predicates

Request retains:

```text
headers         header           header_all
content_type    content_length
cookies         cookie
query_params    query_param      raw_query_params    raw_query_param
path_params     path_param
is_get          is_post          is_put              is_patch
is_delete       is_head          is_options
is_json         is_form          is_multipart
accepts         preferred_type
bearer_token    basic_auth
```

`headers` remains an independent `PAGI::Headers` snapshot. Raw scope header
pairs remain available through `scope`. Path parameters remain on Request even
though a Router populated them: they are incoming matched request data, and the
shape is useful to any Router that follows the public `scope->{path_params}`
convention. They do not imply access to PAGI::Routing reverse lookup.

`bearer_token` and `basic_auth` remain credential parsers only. They do not
establish identity, enforce authorization, or construct a challenge.

### 8.4 Body consumption

Request retains:

```text
body_stream       multipart_stream
body              text              json
form_params       form_param
raw_form_params   raw_form_param
uploads           upload            upload_all
```

Body parsing belongs on Request because all representations share one receive
channel and one consumption state machine. Splitting the public API into
`PAGI::Request::JSON`, `PAGI::Request::Form`, and similar wrappers would make
exclusive consumption and caching harder to see without changing the
underlying constraint.

Existing mutual-exclusion, size-limit, UTF-8, buffering, and cache semantics
remain in force. Internal implementation modules may organize parsers; that
does not alter the Request API.

### 8.5 State and connection

Request exposes only these cross-cutting intrinsic capabilities directly:

```perl
$request->has_state;
$request->state;             # PAGI::State or undef
$request->connection;        # server connection object or undef
$request->is_disconnected;   # boolean, or undef when unsupported
```

State is application-lifespan data copied into the request scope. Connection
state is server-supplied information about this request. Both therefore belong
on Request even though standalone helpers also accept the scope.

`is_disconnected` returns `undef` when `pagi.connection` is absent; absence is
unknown capability, not proof of disconnection. When present it returns the
inverse of the connection object's `is_connected` result.

Advanced connection operations remain available through `connection`, such as
`disconnect_reason`, callbacks, and `disconnect_future`. Request no longer
duplicates them. Outbound flow-control forwarding leaves Request entirely and
moves to `PAGI::Transport`.

### 8.6 Methods not added to Request

Request does not gain:

```text
path_for        url_for          url
stash           session          csrf_token       csrf_verify
transport       buffered_amount  high_water_mark  low_water_mark
on_high_water   on_drain         is_writable
html            respond          send
```

It also gains no other Context-style outgoing-response factory shortcuts.
Request's retained `json` is an input-body parser. New documentation spells
outgoing factories through `PAGI::Response` or `PAGI::Pages`.

The existing `response` convenience is not recommended in new documentation,
but its final removal is governed by `LATER-RESPONSE`, not this migration. The
response examples in this design use `PAGI::Response` explicitly so the next
phase can reconsider that surface independently.

## 9. `PAGI::State`

### 9.1 Presence and construction

```perl
use PAGI::State qw(app_state);

my $state_a = PAGI::State->new($request);
my $state_b = app_state($request);
my $state_c = app_state($scope);
```

Perl 5.10 and later reserve `state` as a declarator. Under `use v5.40`, a call
spelled `state($request)` silently parses as a state-variable declaration
rather than invoking an imported function. The export is therefore named
`app_state`; no `state` function is exported.

All three expressions return equivalent State facades over the exact scope's
backing hash. Object identity is unspecified. If the scope has no `state` key,
they return `undef`. An existing empty hashref is present state and returns a
valid facade. A present non-hashref state is a contract error and croaks.

`$request->has_state` tests valid presence. `$request->state` delegates to the
same construction rules and therefore returns an equivalent object or `undef`.

### 9.2 Read-oriented interface

```perl
my $db      = $state->get('db');
my $feature = $state->get('feature', undef);

if ($state->exists('metrics')) { ... }
my @keys = $state->keys;
my $raw  = $state->data;
```

`get($key)` croaks if the key is missing. `get($key, $default)` returns the
default, including an explicit `undef`, when missing. `exists`, `keys`, and
`data` follow the established Stash/Session spellings.

State deliberately has no `set` or `delete`. Compose/lifespan produces a
request-local shallow copy of top-level state. Mutating that top-level copy
suggests application-wide persistence that does not exist. A referenced
service object, connection pool, cache, or fixture may of course be mutated
through its own API. Request-local mutation belongs in `PAGI::Stash`.

### 9.3 Temporary hashref compatibility

Only Request's state transition receives a compatibility bridge:

```perl
# Deprecated, temporarily works
my $db = $request->state->{db};

# Canonical
my $db = $request->state->get('db');
```

`PAGI::State` supplies `%{}` overload returning its backing hashref. The first
use at each package/file/line callsite in a process emits a deprecation warning.
Set `PAGI_SILENCE_STATE_HASHREF_WARNING=1` to suppress that warning only; the
overload behavior is unchanged. The environment value must be exactly `1`.

The overload preserves hash-dereference syntax, not hashref identity. The
facade remains blessed, so `ref($request->state) eq 'HASH'` is false, HashRef
type constraints reject it, and serializers or cloning tools may treat it as
an object. Code that requires an actual hashref uses the explicit, unprotected
`$request->state->data` escape hatch during migration. The upgrading guide must
call out this limitation rather than describing the bridge as transparent.

The bridge does not change `$scope->{state}`, which remains an ordinary
hashref, and does not alter `PAGI::Context->state` while Context remains in the
distribution. Its eventual removal is documented but not assigned an invented
version in this design.

Existing `PAGI::WebSocket->state` and `PAGI::SSE->state` hashref access also
remains unchanged in this Request-focused phase. New protocol-neutral examples
that want strict access use `app_state($websocket)` or
`app_state($sse)`. Harmonizing the direct WebSocket/SSE convenience methods can be considered with
`LATER-CONTEXT`; it is not allowed to delay direct protocol handler arguments.

## 10. Shared scope-source contract

### 10.1 Accepted sources

Every helper constructor introduced or normalized by this design accepts
exactly one source:

1. an unblessed scope hashref; or
2. a blessed object with `scope()` returning an unblessed scope hashref.

```perl
PAGI::Stash->new($scope);
PAGI::Stash->new($request);
PAGI::Stash->new($websocket);
PAGI::Stash->new($sse);
```

Package-name strings, blessed hashrefs without `scope`, malformed scope
returns, missing sources, and extra constructor arguments croak with the helper
class and accepted shapes in the diagnostic. Existing constructors that
silently ignore extra arguments become strict.

Helpers may impose an additional capability requirement after resolving the
scope. Session and CSRF require their middleware-installed keys. URL requires a
compatible routing frame. State and Transport return `undef` when their
optional scope capability is absent. Stash creates its request-local backing
hash lazily.

The governing rule is capability ownership: absence returns `undef` when the
underlying PAGI or application capability is optional; construction croaks
when the caller explicitly requests a helper whose meaningful operation
requires a provider contract. State and Transport are optional, Stash is
self-provisioning, and URL, Session, and CSRF require their Router or middleware
provider.

Existing Stash and Session `from_data` test constructors remain direct-data
constructors. They do not use scope caching, do not require a scope lifetime,
and are not generalized to the other helpers by this design.

### 10.2 Exports

Exports are opt-in and use uppercase `:ALL` only:

```perl
use PAGI::Routing::URL qw(url url_for path_for);
use PAGI::Stash       qw(stash);
use PAGI::Session     qw(session);
use PAGI::CSRF        qw(csrf);
use PAGI::State       qw(app_state);
use PAGI::Transport   qw(transport);
```

No helper exports by default. The named export in each module is equivalent to
calling that module's constructor. `url_for` and `path_for` are the only
additional delegated operations in this phase because they are sufficiently
common and have unambiguous return types.

This design does not add arity-dependent behavior such as:

```perl
url($request);                    # object
url($request, 'show', @args);     # string -- rejected design
```

`url($source)` always returns a `PAGI::Routing::URL`. String-producing calls
are spelled `url_for($source, ...)` and `path_for($source, ...)`.

### 10.3 Cheap facades without identity semantics

Scope-bound helpers are cheap facades constructed per call. The public
contract guarantees equivalent behavior over the same backing capability, not
object identity:

```perl
my $a = url($scope);
my $b = url($scope);

$a->path_for('show', { id => 1 })
    eq $b->path_for('show', { id => 1 });  # guaranteed

refaddr($a) == refaddr($b);                # unspecified
```

Stash, Session, State, CSRF, and Transport already obtain their meaningful
data or handle from the supplied scope. URL obtains the existing Resolver from
the routing frame; constructing a URL facade does not compile or rebuild the
Resolver. No helper object or helper-cache record is stored in the scope.

This keeps shallow-cloned mount scopes naturally separate: each facade reads
the exact scope supplied to its constructor. Implementations may introduce an
invisible optimization later if measurement justifies it, but must not expose
referential identity or require cache lifecycle semantics. A URL facade reads
request-selection metadata when an operation runs so constructing it before
final leaf metadata is installed cannot freeze a stale ancestor frame.

## 11. `PAGI::Routing::URL`

### 11.1 API

```perl
use PAGI::Routing::URL qw(url url_for path_for);

my $urls = url($request);

my $path = $urls->path_for(
    '/account/user/show',
    { account_id => 7, user_id => 42 },
    { tab => 'profile' },
    'details',
);

my $absolute = $urls->url_for(
    'show',
    query    => { tab => 'profile' },
    fragment => 'details',
);

my $same_path = path_for($request, '/account/user/show',
    { account_id => 7, user_id => 42 });
my $same_url = url_for($request, 'show',
    query => { tab => 'profile' });
```

The helper preserves the existing handler-bound reverse semantics formerly on
Context:

- absolute slash addresses start at the resolver root and inherit no captures;
- relative addresses start at the current logical namespace;
- `.` and `..` normalize exactly under the existing grammar;
- relative references inherit only captures required by the target;
- explicit path params override inherited captures;
- compact `(\%params, \%query, $fragment)` and named
  `(params => ..., query => ..., fragment => ...)` forms remain valid;
- `path_for` includes the compiled routing boundary's `root_path` exactly once;
- `url_for` uses the named route kind to select HTTP/HTTPS or WS/WSS;
- authority selection and validation delegate to `PAGI::Authority`; and
- unknown names, missing params, extra params, invalid constraints, malformed
  query/fragment arguments, and incompatible routing metadata croak.

`PAGI::Routing::Router->path_for` remains available for placement-independent
generation from a Router's local root. It does not inherit request captures or
know an external mount placement.

The current scope-bound algorithm must be moved behind a neutral Resolver/URL
operation rather than copied out of Context. Internal names and diagnostics
that currently say `reverse_for_context` or `Context reverse operation` are
renamed to describe scope-bound URL generation. While Context remains
installed, its old methods may delegate to `PAGI::Routing::URL`; the dependency
must not point in the opposite direction.

### 11.2 Ownership boundary

The class is named `PAGI::Routing::URL`, not `PAGI::URL`, because it consumes
PAGI::Routing's versioned frame contract. A different Router is free to expose
another builder. It does not have to populate PAGI::Routing metadata to make a
nominally neutral `$request->url_for` work.

Thunderhorse's controller/router URL surface is an example of that legitimate
independence. This design supplies an upgrade path for Thunderhorse users; it
does not replace Thunderhorse's own named-route implementation.

## 12. Stash, Session, and CSRF

### 12.1 Stash

```perl
use PAGI::Stash qw(stash);

stash($scope)->set(trace_id => $trace_id);       # middleware/raw app
my $trace_id = stash($request)->get('trace_id'); # normal handler
```

Stash retains its mutable `get`, `set`, `exists`, `delete`, `keys`, and `data`
API and lazily creates `scope->{'pagi.stash'}`. Its constructor/factory uses
strict source arity and returns a cheap facade over that backing hash.

### 12.2 Session

```perl
use PAGI::Session qw(session);

my $cart = session($request)->get('cart', []);
session($request)->set(cart => [@$cart, $apple_id]);
```

Session retains its current data and lifecycle API. Construction requires
Session middleware to have installed `pagi.session`; absence croaks with a
diagnostic naming the required middleware capability. Its constructor/factory
uses strict source arity and returns a cheap facade over that backing hash.

### 12.3 CSRF

```perl
use PAGI::CSRF qw(csrf);

my $token = csrf($request)->token;
return PAGI::Pages->forbidden($request)
    unless csrf($request)->verify($submitted);
```

`PAGI::CSRF` is a new read/verify facade over the capability installed by
`PAGI::Middleware::CSRF`. It provides:

```text
token
verify($submitted)
```

`verify` preserves the existing timing-safe comparison and false result for
missing or empty submitted values. Constructing the helper without the
middleware-installed `csrf_token` key, or with a token that is not a defined
nonempty plain scalar, croaks clearly instead of returning a helper that can
never succeed. The middleware remains responsible for token issuance and
enforcement modes; the helper does not create tokens or send a response.

## 13. Connection and `PAGI::Transport`

### 13.1 Incoming lifecycle

`$request->connection` returns the optional server connection-state object.
`$request->is_disconnected` is the one convenience retained for the common
question. Code needing reasons, futures, or lifecycle callbacks uses the
connection object explicitly:

```perl
if (defined(my $disconnected = $request->is_disconnected)
        && $disconnected) {
    return PAGI::Response->status(499);
}

my $connection = $request->connection;
$connection->on_disconnect(\&cancel_query) if $connection;
```

This avoids forwarding an evolving server interface through Request.

### 13.2 Outbound flow control

```perl
use PAGI::Transport qw(transport);

my $flow = transport($request);
if ($flow && !$flow->is_writable) {
    $flow->on_drain(\&resume_producer);
}
```

`PAGI::Transport->new($source)` and `transport($source)` return a cheap facade
over `scope->{'pagi.transport'}`, or `undef` when the optional transport handle
is absent. The facade provides:

```text
buffered_amount
high_water_mark
low_water_mark
on_high_water($callback)
on_drain($callback)
is_writable
```

The facade follows the PAGI transport capability levels. A present handle must
implement `buffered_amount`; otherwise construction croaks. Watermark methods
return `undef` when the server does not implement them. Callback registration
is a no-op returning the Transport object when the corresponding optional
callback method is absent. `is_writable` returns true when no high-water mark is
available; otherwise it compares buffered amount against that mark.

Awaiting the Future returned by send/write operations remains the primary
backpressure mechanism. Transport is optional introspection for producers that
need proactive pause/resume behavior; it does not make sending synchronous and
does not guarantee that bytes reached the client.

## 14. Compiler and frontend integration

### 14.1 Shared compiler

The declarative compiler changes protocol materialization once. Functional
Routing, `PAGI::App::Router`, and `PAGI::Endpoint::Router` must all inherit the
same behavior rather than implementing three adapters.

The compiler:

1. completes matching and installs the selected leaf's public `path_params`
   and PAGI::Routing frame;
2. constructs the protocol object from the exact selected scope;
3. invokes the normal handler with that one object;
4. awaits immediate or Future-backed completion through `Future->wrap`;
5. validates and sends HTTP Responses; and
6. leaves raw targets and middleware on the native PAGI signature.

Every helper consumes the exact selected scope passed to it. Mount-created
child scopes therefore use their own path, root path, routing frame, and
capabilities without cache inheritance or replacement logic.

### 14.2 Endpoint Router

Endpoint Router remains the method-oriented frontend. Its route methods now
receive a Request, WebSocket, or SSE object according to route kind. Existing
middleware helpers remain pure PAGI middleware.

The existing `new_context` convenience is removed and replaced by the
exact-purpose `new_request($scope, $receive)`. It constructs a strict HTTP
`PAGI::Request`; it is useful inside a native Endpoint application or pure
middleware that has already established the scope is HTTP. It is not invoked
by compiled route dispatch, and overriding it affects only explicit calls.
Non-HTTP native code constructs or receives its protocol object explicitly.

### 14.3 Middleware

Middleware continues to receive and return native PAGI applications. This
design does not add a `$request` middleware signature:

```perl
sub with_logging($app) {
    return async sub ($scope, $receive, $send) {
        my $started = time;
        await $app->($scope, $receive, $send);
        log_elapsed(time - $started);
    };
}
```

A middleware that wants a helper passes `$scope` to it. A middleware that
constructs `PAGI::Request` itself must understand body-consumption ownership;
ordinary request manipulation should prefer scope and standalone helpers.

## 15. Complete apples example

The migrated comparison example should have this shape. It deliberately uses
Perl 5.40 signatures and `Types::Standard::Int`, just like the current example.
The Response spelling is provisional under `LATER-RESPONSE`; the Request and
helper spellings are the decisions being approved here.

```perl
#!/usr/bin/env perl
use v5.40;

use Future::AsyncAwait;
use List::Util qw(max);
use Types::Standard qw(Int);

use PAGI::Compose qw(compose);
use PAGI::Pages;
use PAGI::Response;
use PAGI::Routing qw(route mount);
use PAGI::Routing::URL qw(url url_for path_for);

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
    my @apples = map {
        +{
            %{$db->{$_}},
            url => url_for($request, 'read', { apple_id => $_ }),
        }
    } sort { $a <=> $b } keys %$db;

    return PAGI::Response->json(\@apples);
}

async sub read_apple($request) {
    my $apple_id = $request->path_param('apple_id');
    my $apple = apples_db($request)->{$apple_id};

    return PAGI::Response->json($apple) if $apple;
    return PAGI::Response->json(
        { error => 'Apple not found' },
        status => 404,
    );
}

async sub create_apple($request) {
    my $db = apples_db($request);
    my $data = await $request->json;
    my $new_id = max(0, keys %$db) + 1;
    my $new_apple = { id => $new_id, %$data };
    $db->{$new_id} = $new_apple;

    my $location = path_for($request, 'read', { apple_id => $new_id });
    return PAGI::Response->json(
        $new_apple,
        status  => 201,
        headers => [Location => $location],
    );
}

async sub update_apple($request) {
    my $db = apples_db($request);
    my $apple_id = $request->path_param('apple_id');
    return PAGI::Response->json(
        { error => 'Apple not found' }, status => 404,
    ) unless exists $db->{$apple_id};

    my $data = await $request->json;
    $db->{$apple_id} = { %{$db->{$apple_id}}, %$data };
    return PAGI::Response->json($db->{$apple_id});
}

async sub delete_apple($request) {
    my $db = apples_db($request);
    my $apple_id = $request->path_param('apple_id');
    return PAGI::Response->json(
        { error => 'Apple not found' }, status => 404,
    ) unless exists $db->{$apple_id};

    my $deleted_apple = delete $db->{$apple_id};
    return PAGI::Response->json({
        success => \1,
        deleted => $deleted_apple,
    });
}

compose(
    routes => [
        route('/' => PAGI::Pages->welcome,
            name => 'home', desc => 'PAGI welcome page'),
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
            desc => 'Apples API namespace'),
    ],
    lifespan => {
        startup => \&startup,
    },
);
```

The example uses both delegated exports and the object form. A longer handler
may choose:

```perl
my $urls = url($request);
my $self = $urls->url_for('read', { apple_id => $apple_id });
my $edit = $urls->url_for('update', { apple_id => $apple_id });
```

Repeated `url($request)` calls may return different facade objects, but each
uses the same Resolver already installed in the request's routing frame. No
Resolver compilation occurs per helper call.

## 16. Error behavior and diagnostics

Construction-time and request-time failures must identify the owning API:

| Condition | Required behavior |
| --- | --- |
| Request scope is missing, blessed, malformed, or non-HTTP | Request construction croaks before handler invocation |
| Normal HTTP handler returns `undef` or a non-Response | Adapter croaks `handler did not return a response` |
| Handler returns failed Future | Original failure propagates to the enclosing error boundary |
| Helper source has wrong shape or arity | Constructor/factory croaks with helper class and accepted source forms |
| `scope()` returns a non-hash or blessed hash | Helper croaks; it does not guess |
| Optional State or Transport capability is absent | Factory returns `undef` |
| Present State value is not a hashref | State construction croaks |
| Session or CSRF middleware capability is absent | Helper construction croaks and names the missing capability |
| URL routing frame is absent, malformed, or unsupported version | URL operation croaks and names PAGI::Routing requirement |
| URL authority is invalid or duplicated | `PAGI::Authority` error propagates |

No helper sends a response merely because a capability is absent. ErrorHandler
and Pages remain responsible for translating application failures where the
application has installed those boundaries.

## 17. Concurrency, lifetime, and security

1. Protocol objects and helpers are request scoped. No package-global mutable
   object may hold the active scope, routing frame, state, session, or stash.
2. No helper objects or helper-cache records are written into the scope.
3. Concurrent requests through one compiled application must receive distinct
   Request, State, URL, Stash, Session, CSRF, and Transport objects.
4. A helper reads only the exact scope or backing capability supplied at
   construction; shallow-cloned child scopes do not inherit facade state.
5. State's raw `data` and `%{}` compatibility bridge are deliberate
   jailbreaks. Documentation must say that typo protection no longer applies
   after using them.
6. URL capture inheritance is a construction convenience, never an
   authorization decision. Every generated target still requires normal
   authorization.
7. CSRF verification remains timing safe. The helper must not log tokens or
   include expected/submitted values in diagnostics.
8. Request body methods continue to prevent two consumers from independently
   reading the same receive stream.

## 18. Upgrading

### 18.1 Normal HTTP handlers

Before:

```perl
async sub create_apple($c) {
    my $data = await $c->request->json;
    return $c->json($data, status => 201);
}
```

After:

```perl
async sub create_apple($request) {
    my $data = await $request->json;
    return PAGI::Response->json($data, status => 201);
}
```

### 18.2 Reverse routing

Before:

```perl
my $path = $c->path_for('show', { person_id => 42 });
my $url  = $c->url_for('show', query => { tab => 'posts' });
```

After:

```perl
use PAGI::Routing::URL qw(path_for url_for);

my $path = path_for($request, 'show', { person_id => 42 });
my $url  = url_for($request, 'show', query => { tab => 'posts' });
```

### 18.3 State

Before:

```perl
my $db = $c->state->{db};
```

Transitional Request code:

```perl
my $db = $request->state->{db};  # works, warns once per callsite
```

Canonical code:

```perl
my $db = $request->state->get('db');
```

The compatibility overload preserves only dereference syntax. It does not
preserve hashref identity:

```perl
ref($request->state) eq 'HASH';          # false
$request->state->data;                   # actual hashref escape hatch
```

HashRef type constraints, serializers, cloning libraries, and APIs that test
`ref($value) eq 'HASH'` must receive `->data` during migration or be updated to
consume the State interface.

### 18.4 Stash, Session, and CSRF

Before:

```perl
my $user = $c->session->get('user');
$c->stash->set(result => $result);
return $c->text('Forbidden', status => 403)
    unless $c->csrf_verify($submitted);
```

After:

```perl
use PAGI::Session qw(session);
use PAGI::Stash qw(stash);
use PAGI::CSRF qw(csrf);

my $user = session($request)->get('user');
stash($request)->set(result => $result);
return PAGI::Pages->forbidden($request)
    unless csrf($request)->verify($submitted);
```

### 18.5 Connection and transport

Before:

```perl
$c->on_disconnect(\&cancel);
$c->on_drain(\&resume);
```

After:

```perl
my $connection = $request->connection;
$connection->on_disconnect(\&cancel) if $connection;

my $flow = transport($request);
$flow->on_drain(\&resume) if $flow;
```

Direct Request methods `is_connected`, `disconnect_reason`, `on_disconnect`,
`on_complete`, and `disconnect_future` move behind `connection`. Direct
`buffered_amount`, watermark, callback, and `is_writable` methods move behind
`transport`. Unlike the old convenience, `is_disconnected` returns `undef`
rather than true when the server provides no connection capability.

### 18.6 Thunderhorse handoff

The upgrade document must include a dedicated framework-author section that
separates PAGI protocol stability from PAGI-Tools API breakage. It must cover:

- HTTP Route callbacks now receive `PAGI::Request`;
- WebSocket and SSE callbacks receive their direct protocol objects;
- raw PAGI applications and middleware are unchanged;
- Request construction takes `($scope, $receive)` and is HTTP-only;
- Router URL generation is now an explicit `PAGI::Routing::URL` capability;
- Thunderhorse may keep its own Controller/Router URL builder;
- Request state is a `PAGI::State` wrapper with a warned temporary hash bridge;
- Context-specific subclassing or type-map hooks no longer affect Routing;
- Response return behavior is unchanged in this phase; and
- `LATER-RESPONSE` and `LATER-CONTEXT` will require separate follow-up review.

## 19. Documentation and example migration

The implementation updates at least:

- `PAGI::Routing`, Route, Compiler, and Router POD;
- `PAGI::Request`, `PAGI::WebSocket`, and `PAGI::SSE` POD;
- `PAGI::App::Router` and `PAGI::Endpoint::Router` POD;
- `PAGI::Stash`, `PAGI::Session`, CSRF middleware, and connection/transport
  documentation;
- `PAGI::Pages` invocation examples that currently say Context handler;
- README, Tutorial, Cookbook, and `UPGRADING.md`;
- `Changes` under the still-unreleased version;
- `examples/starlette-apples`, including its copied Perl listing in README;
- `examples/15-large-application` and its Starlette comparison;
- Endpoint Router demo and all smaller examples that use `$c`; and
- generated/load tests for every new public module and export bundle.

Documentation must use `$request`, `$websocket`, and `$sse` rather than a
generic `$c` where the protocol is known. Raw application examples retain
`$scope`, `$receive`, and `$send`.

The Starlette apples README must keep the original Python source verbatim for
comparison and explain which remaining differences come from explicit Perl
imports and the intentionally deferred Response redesign.

## 20. Test requirements

### 20.1 Handler adapters

Tests must prove:

- synchronous and async HTTP handlers receive `PAGI::Request`;
- body parsing uses the selected Request's receive channel;
- immediate and Future-backed Responses are both accepted;
- `undef`, arbitrary values, and failed Futures follow documented errors;
- HTTP Responses are sent exactly once;
- WebSocket handlers receive one `PAGI::WebSocket` bound to exact scope/IO;
- SSE handlers receive one `PAGI::SSE` bound to exact scope/IO;
- immediate and Future-backed WS/SSE completion is awaited;
- raw routes and middleware still receive exactly three native arguments; and
- all three Router frontends inherit the shared behavior.

### 20.2 Request surface

Tests must cover:

- strict HTTP constructor validation;
- new `server` accessor on TCP and Unix-socket tuples;
- `host` continuing through `PAGI::Authority` duplicate/invalid handling;
- retained headers, cookies, query, path, body, form, upload, negotiation, and
  credential-parser behavior;
- explicit `scope` escape hatch;
- `is_disconnected` true, false, and unsupported/undef cases;
- advanced lifecycle access through `connection`; and
- absence of newly rejected Router/middleware convenience methods.

### 20.3 State

Tests must cover:

- absent state returns undef and `has_state` is false;
- empty present state returns a wrapper and `has_state` is true;
- malformed present state croaks;
- strict/default get, exists, keys, and data;
- lack of set/delete;
- `%{}` returns the original backing hash;
- State methods continue to work before and after hash dereference without
  recursively invoking the overload for their own private storage;
- one warning per package/file/line callsite;
- exact-value environment suppression;
- no warning suppression when the variable is missing, empty, or not `1`;
- raw `$scope->{state}` and surviving Context behavior remain hashref-based;
- `ref($state) eq 'HASH'` remains false while `->data` returns the backing
  hashref; and
- equivalent data with unspecified facade identity across repeated calls.

### 20.4 Helper facades

Each helper must be tested with a scope and each applicable protocol object.
Tests must cover:

- accepted source shapes and strict rejection of every malformed shape;
- rejection of extra constructor/factory arguments;
- no default exports, named exports, and uppercase `:ALL`;
- `app_state` invokes the function under `use v5.40` and no `state` function is
  exported;
- equivalent behavior with no referential-identity guarantee;
- no helper object or helper-cache record added to the scope;
- exact backing data selection for parent and shallow-cloned child scopes;
- missing optional versus required capability behavior; and
- concurrency through one compiled application without cross-request leakage.

### 20.5 URL

Reuse and extend the existing reverse-routing matrix for:

- absolute and relative names;
- `.` and `..` normalization and namespace-only failures;
- reused parameter names and capture inheritance;
- explicit param override;
- compact and named params/query/fragment forms;
- HTTP, HTTPS, WS, and WSS target schemes;
- `root_path` and nested Mount placement exactly once;
- duplicate/invalid Host rejection through `PAGI::Authority`;
- constraint validation during reverse generation;
- opaque/non-PAGI Router failure;
- construction before final leaf selection without stale-frame output;
- Router `path_for` remaining placement independent; and
- functional exports matching object methods byte for byte.

### 20.6 Stash, Session, CSRF, and Transport

Tests must preserve existing Stash/Session behavior while adding factory and
scope-source coverage. CSRF tests must include middleware-present, middleware-absent,
matching, mismatching, missing, empty, and timing-safe comparison paths without
exposing token values. Transport tests must cover optional absence, every
delegated method, callback chaining, writable threshold boundaries, malformed
handles, and the statement that awaiting send remains the primary flow-control
contract.

### 20.7 Integration and documentation

Integration tests must exercise:

- the complete apples CRUD application through `PAGI::Test::Client`;
- generated absolute links and Location paths;
- lifespan state availability and mutation through its referenced fixture;
- nested large-application reverse links;
- a direct Pages normal handler receiving Request;
- Endpoint Router HTTP, WebSocket, SSE, route middleware, and helper use;
- raw application use of URL, Stash, Session, CSRF, State, and Transport where
  applicable; and
- executable upgrading examples.

Final searches over live code, tests, examples, README, Tutorial, Cookbook,
UPGRADING, and Changes must find no normal Route handler documented as
receiving Context. Historical design records are not rewritten.

## 21. Migration sequence constraints

The later implementation plan must preserve a buildable sequence:

1. introduce and test the shared scope-source normalization machinery;
2. add State, Transport, CSRF, and functional factories while normalizing
   Stash and Session;
3. add `PAGI::Routing::URL` by moving, not reimplementing, current
   Context-bound reverse logic;
4. finish Request's intrinsic surface and minimal Pages Request acceptance;
5. change the shared routing compiler to direct protocol objects;
6. migrate App Router and Endpoint Router seams;
7. migrate tests and examples in behavior-sized commits;
8. write the full upgrading guide and cross-document reconciliation; and
9. perform focused review, full-suite verification, build/archive inspection,
   and final live-surface searches.

The URL move must avoid two independently evolving implementations. Context
may temporarily delegate its old `path_for` and `url_for` methods to the new URL
helper while Context remains installed, but normal Routing must not construct
Context and new documentation must not recommend those methods.

## 22. Adversarial review and rejected alternatives

### 22.1 Put everything on Request

Rejected. It recreates Context under a more familiar name and forces unrelated
Routers and middleware to mimic PAGI-Tools internals.

### 22.2 Add `$request->url` as a thin alias

Rejected. An imported Perl function does not automatically become a method,
and an actual method would couple Request to PAGI::Routing. `url($request)` is
concise, explicit, and honest about ownership.

### 22.3 Overload `url` by arity

Rejected. Returning an object with one argument and a string with more
arguments makes refactoring change the return type invisibly. Separate
`url_for` and `path_for` exports are only a few characters longer.

Pages' existing one-argument normal-handler and three-argument native-app
endpoint is a deliberately retained interoperability exception. It bridges two
framework invocation positions rather than offering two ordinary caller-facing
return types. `LATER-PAGES` will reconsider that dual contract; this design
does not generalize it to new helper APIs.

### 22.4 Rename Request to `PAGI::HTTP`

Rejected. `HTTP` could mean a request, a response, a protocol namespace, or a
combined connection. Request is precise. WebSocket/SSE/MCP remain siblings,
not Request subclasses.

### 22.5 Create `PAGI::Request::JSON` and representation objects

Rejected. These views all consume one receive stream. Keeping body
representations on Request makes exclusivity visible and matches established
HTTP framework practice.

### 22.6 Put helper storage on the Request object only

Rejected. Raw PAGI applications and middleware would lose the same helpers,
and constructing through `$scope` would produce a second object. The exact
scope is the common lifetime boundary.

### 22.7 Require helper identity or cache facades in scope

Rejected. No helper's semantics require referential identity, and the Router
Resolver already lives in its routing frame. Public identity would require
weak references, clone replacement, cache-key protection, and lifetime rules
without measured benefit. Cheap per-call facades leave future invisible
performance optimization possible without expanding the contract.

### 22.8 Let State mutate top-level values

Rejected. Lifespan state is shallow-copied per request. Stash is the explicit
request-local mutable namespace; persistent services should expose their own
methods.

### 22.9 Put all connection and transport methods on Request

Rejected. It duplicates two optional server-owned interfaces and makes future
PAGI additions require Request forwarding changes. One common disconnect query
is retained; advanced operations use the owning object/facade.

### 22.10 Add authentication response shortcuts now

Rejected. Credential parsing, identity, authorization, and 401/403 response
policy are separate concerns. A premature `$request->needs_auth` would again
combine them and couple Request to Response/Pages.

### 22.11 Remove Context immediately

Rejected for this phase. Routing must stop depending on it now, but a final
repository and downstream audit should govern deletion. Deferring the class
removal does not justify retaining it in new handler paths.

## 23. Acceptance criteria

The design is complete when the implementation can demonstrate all of the
following:

1. every normal route handler receives the selected protocol object directly;
2. every raw route and middleware remains native three-argument PAGI;
3. HTTP handler Responses preserve immediate/Future behavior and one send;
4. Request contains intrinsic HTTP input, state, and minimal connection access,
   but no Router URL, session, stash, CSRF, transport, or response shortcuts in
   the recommended surface;
5. State catches missing-key typos and provides the documented temporary
   warned hash bridge;
6. all scope-bound helpers share one strict source contract without public
   identity or scope-cache semantics;
7. URL behavior matches the existing reverse-routing contract without a second
   resolver implementation;
8. Stash, Session, CSRF, State, and Transport work from Request and raw scope;
9. shallow scope cloning and concurrent requests select only their own backing
   capabilities without helper records in scope;
10. Pages requires only the narrow Request-source compatibility change;
11. the apples and large-application examples are fully migrated and tested;
12. the upgrading guide contains the Thunderhorse/framework-author handoff;
13. deferred Response, Pages, Auth, Context-removal, and universal-provider work
    remains clearly ledgered rather than leaking into implementation; and
14. the full test suite and distribution build pass with no stale live Context
    handler documentation.
