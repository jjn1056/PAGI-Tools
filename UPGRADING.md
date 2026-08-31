# Upgrading PAGI-Tools

This guide is the standalone handoff for existing applications moving to the
current PAGI::Tools release. It covers the shipped routing-composition and
application-error boundaries, the rooted file-serving security contract, and the
earlier unification of the
`PAGI::App::Router` and `PAGI::Endpoint::Router` frontends. Contracts shown in
Before examples have been removed. There is no compatibility mode and there
are no compatibility aliases.

Each After example uses behavior shipped by the current release. Examples use
ordinary synchronous subs where asynchronous work is not relevant; handlers
may still return a `Future` when their protocol operation is asynchronous.

## Breaking: use explicit middleware descriptions at core boundaries

The immutable core middleware lists in Route, Mount, Router, and Compose now
contain only descriptions made with `middleware(...)`. A description records
how middleware is constructed and later wrapped around the inner application;
it does not construct or run middleware at declaration time.

**Before (removed):** declarative core lists accepted concise strings,
coderefs, and configured wrapper objects directly.

```perl
middleware => ['RequestId', \&audit, $object]
```

**After (shipped):** make each core entry an explicit description.

```perl
middleware => [
    middleware('RequestId'),
    middleware(\&audit),
    middleware($object),
]
```

Short package names still resolve beneath `PAGI::Middleware::`. For a package
outside that namespace, use Plack's leading-`+` exact-package convention.

```perl
# Before: exact package
middleware('^MyApp::Middleware::Auth')

# After: Plack-familiar exact package
middleware('+MyApp::Middleware::Auth')
```

A coderef description can receive named configuration along with the inner
application. Its synchronous result, like an object's `wrap` result, must be
a PAGI application value: a native application coderef or an instantiated
object with `to_app`.

```perl
middleware(\&audit_factory, label => 'items')

sub audit_factory {
    my ($inner, %config) = @_;
    return MyApp::AuditBoundary->new(
        inner => $inner,
        label => $config{label},
    );
}
```

`PAGI::App::Router` and `PAGI::Endpoint::Router` remain higher-level
frontends and may retain their concise middleware forms; they materialize
explicit descriptions for the immutable core. `PAGI::Middleware::Builder` is
a separate concise composition API: it retains its own middleware records and
constructs or wraps them during `to_app`. This migration does not alter those
frontend declaration syntaxes or runtime behavior.

## Breaking: Route endpoints and application-valued responses

There are now four callable boundaries. The distinction is structural, not
an arity guess:

```text
Route CODE endpoint        -> one Request/WebSocket/SSE argument
Route to_app object        -> native PAGI application
Mount/Compose/default CODE -> native PAGI application
handler result             -> native CODE or instantiated to_app object
```

A PAGI application value is either a native
`($scope, $receive, $send)` coderef or an instantiated object with `to_app`.
Package names, unblessed references, callable overloads without `to_app`, and
Response-like duck types are not application values.

### Replace Route `raw` with an explicit application value

**Before (removed):** Route used an extra `raw` declaration mode.

```perl
route('/native', raw => $native_app);
```

**After (shipped):** a bare Route CODE is always a one-argument handler. Wrap
a native CODE with `as_app`; pass an instantiated application object directly.

```perl
use PAGI::Routing qw(route);
use PAGI::Utils qw(as_app);

route('/native' => as_app($native_app));
route('/items'  => MyApp::ItemsEndpoint->new);
```

`as_app($native_app)` without an explicit method declaration defaults to GET
plus automatic HEAD. Unrestricted native delegation is deliberate and uses
the scalar wildcard, not an array containing `'*'`:

```perl
route('/relay' => as_app($native_app), methods => '*');
```

HTTP method resolution is ordered:

1. Explicit `methods` wins and the endpoint capability is not consulted.
2. Otherwise, an application object with `allowed_methods` supplies a list-
   context snapshot taken once when the immutable Route is constructed.
3. Otherwise, the Route uses GET plus automatic HEAD.

Mutable App Router and Endpoint declarations retain the application object
without consulting `allowed_methods`. Each fresh `to_router` call constructs
fresh immutable Routes and therefore takes one fresh capability snapshot;
retaining that immutable Router retains the resulting method policy.

The capability must return a nonempty synchronous list of valid method
tokens. Normalization removes duplicates, canonicalizes case, adds HEAD for
GET, and preserves OPTIONS when the endpoint advertises it. A routed
`PAGI::Endpoint::HTTP` therefore contributes its verbs, GET-derived HEAD, and
OPTIONS to Router selection. Unsupported methods are Router PARTIAL outcomes:
the Router owns the 405 and the first-seen `Allow` union. The Endpoint still
owns automatic OPTIONS and its standalone or broadly mounted 405 behavior.
WebSocket and SSE Routes neither accept `methods` nor consult
`allowed_methods`.

### Return applications from Request handlers

**Before (removed):** handler dispatch required a nominal Response and used a
second emission protocol.

```perl
croak unless is_response($result);
await $result->respond($scope, $receive, $send);
```

**After (shipped):** an HTTP Route CODE receives exactly one
`PAGI::Request`. It may return an immediate or Future-backed native CODE or an
instantiated object with `to_app`. Response and Pages applications are the
ordinary choices.

```perl
use PAGI::Pages qw(not_found);
use PAGI::Response qw(json_response);

route('/items' => async sub {
    my ($request) = @_;
    return not_found(detail => 'No items') unless await has_items();
    return json_response(await load_items());
});
```

Returned arbitrary applications are advanced dynamic delegation. The
returned app receives the current HTTP scope unchanged and the remaining
receive stream. No Mount prefix is consumed, `path` and `root_path` are not
rewritten, and body events already consumed by the handler are not replayed.
The returned app receives no separate lifespan startup or shutdown. Its
routes, constraints, names, and schema metadata are opaque to the outer
Router; it may also apply a second method or routing policy, remain silent,
emit invalid events, or fail after response start. Its `to_app` is called once
per handler invocation and is never cached across requests. Put static or
expensive components directly in Route, Mount, Router `http_default`, or
Compose instead.

Immediate synchronous handlers are supported through `Future->wrap`, but they
run inline. CPU-heavy or blocking synchronous work blocks the event-loop
thread; choose an application-owned asynchronous or executor strategy.

### Invoke applications at a native triplet boundary

**Before (removed):** native applications called the Response-specific public
method, optionally guarded by `is_response`.

```perl
croak unless is_response($response);
await $response->respond($scope, $receive, $send);
```

**After (shipped):** use the application protocol for every application value.

```perl
use PAGI::Response qw(json_response);
use PAGI::Utils qw(invoke_app);

await invoke_app(
    json_response($data),
    $scope, $receive, $send,
);
```

`PAGI::Response` has no public `respond` method and `PAGI::Utils` has no
`is_response` predicate. `invoke_app` preserves the exact supplied triplet,
normalizes through `to_app`, and awaits immediate or Future-backed completion.
It does not install response-completion checks, HEAD suppression, scope
rewriting, exception replacement, or lifespan handling.

### Use source-free Pages factories

**Before (removed):** Pages factory calls took a Request or scope, old
`*_page` exports returned immediate Responses, and Request handlers needed a
native adapter at defaults.

```perl
use PAGI::Pages qw(not_found_page);
use PAGI::Routing qw(request_app);

return not_found_page($request, detail => 'Missing');
http_default => request_app(\&not_found_page);
```

**After (shipped):** class methods, configured-instance methods, and opt-in
exports are source-free factories for deferred HTTP applications.

```perl
use PAGI::Pages qw(not_found welcome);

route('/welcome' => welcome());

my $routing = router(
    routes       => \@routes,
    http_default => not_found(detail => 'Missing'),
);
```

For a custom one-Request default rather than a Pages application, adapt it
explicitly with `request_response(\&custom_not_found)` from `PAGI::Utils`.
Pages exports nothing by default. `:common` excludes collision-prone `status`
and `redirect`; import those individually or use the deliberately broad
`:all` bundle. A deliberate same-named import can replace a local function.

At a native triplet boundary, delegate a Pages value with `invoke_app`. As a
small server root, the exact CLI spelling is:

```bash
pagi-server -MPAGI::Pages -e 'PAGI::Pages->welcome'
```

Pages is HTTP-only; it does not handle lifespan. A bare Pages root throws on
the lifespan scope. PAGI::Server automatic lifespan mode treats that exception
as a decline and continues without sending later lifespan events; strict mode
rejects startup. Use Compose when the root needs startup/shutdown, final HEAD
policy, ErrorHandler, or response-completion guarding.

### Keep Route and Mount ownership distinct

Route matches one complete path, participates in HTTP methods and `Allow`, and
keeps the selected scope path unchanged. Mount consumes a matching prefix,
rewrites the child `path` and `root_path`, and owns the entire selected
subtree. Endpoint shape does not change this rule:

```text
Route('/manual') matches exactly /manual
Route('/*path')  is an explicit full-path wildcard leaf
Mount('/manual') owns /manual and every path below it
```

A File Response on `route('/manual' => $file)` is therefore one exact leaf. A
Directory component on `mount('/manual', app => $directory)` owns and receives
the rewritten subtree. Child 404/405 outcomes do not resume parent sibling
scanning.

### Preserve object and invocation ownership

`PAGI::Pages::Application` retains the exact configured Pages policy object,
and `Response->to_app` retains the exact Response object. PAGI does not clone,
freeze, reconstruct, or inspect arbitrary subclass storage. Deliberate later
mutation may affect later invocations; each invocation still derives its own
request-local descriptor, concrete Response, or delivery plan before its first
send. Concurrent mutation during derivation is unsupported.

Request `headers` likewise returns the exact cached `PAGI::Headers` object;
mutations are shared with `header`, `header_all`, `content_type`, and
`content_length`. Call `clone` explicitly for an isolated header container.
`PAGI::Lifespan` passes the exact incoming non-lifespan scope and installs or
adopts state on that same hashref; it does not promise a shallow request-scope
copy.

Stream HEAD requests still run the GET producer before the outer HEAD boundary
suppresses body events, which can be expensive. Declare an earlier lightweight
HEAD Route when that work should be avoided. File retains its deliberate
`protocol_response_capability` opt-out because WebSocket denial and SSE decline
cannot translate PAGI `file` or `fh` body events.

## Breaking: choose a concrete Response class

`PAGI::Response` is now the byte-oriented base of a concrete class family.
Every constructed object is already a complete reusable response value;
`ref($response)` identifies its representation or delivery behavior.

| Class | Factory | Memory/delivery |
| --- | --- | --- |
| `PAGI::Response` | `response` | buffers caller-supplied encoded bytes |
| `PAGI::Response::Text` | `text_response` | buffers strict UTF-8 text |
| `PAGI::Response::HTML` | `html_response` | buffers strict UTF-8 HTML |
| `PAGI::Response::JSON` | `json_response` | buffers one serialized finite Perl value |
| `PAGI::Response::Problem` | `problem_response` | buffers validated RFC 9457 JSON |
| `PAGI::Response::Redirect` | `redirect_response` | buffers a small redirect document |
| `PAGI::Response::Empty` | `empty_response` | buffers zero body bytes |
| `PAGI::Response::File` | `file_response` | request-time preflight and a server-owned `file` event |
| `PAGI::Response::Stream` | `stream_response` | fresh producer and sequential Writer per invocation |

`PAGI::Response` exports nothing by default. Import individual factories or
`:all`; each concrete subclass may export only its matching factory. Factory
functions always construct the fixed first-party class. Application subclasses
use their own constructor or export their own named factory.

### Complete spelling map

There are no compatibility aliases for the removed forms.

| Before | After |
| --- | --- |
| `$request->response` | construct the desired concrete Response directly |
| `PAGI::Response->new($scope)` as a mutable builder/scope source | construct a complete response; pass Request/protocol/scope to Session, Stash, State, CSRF, URL, or Transport helpers |
| `PAGI::Response->text($s)` | `text_response($s)` |
| `PAGI::Response->html($s)` | `html_response($s)` |
| `PAGI::Response->json($v)` | `json_response($v)` |
| `PAGI::Response->send($s, charset => $name)` | explicitly encode and pass bytes plus Content-Type to `response(...)` |
| `PAGI::Response->send_raw($b)` | `response($b)` |
| `PAGI::Response->redirect($uri)` | `redirect_response($uri)` |
| `PAGI::Response->empty(...)` | `empty_response(...)` |
| `PAGI::Response->send_file($p)` with immediate `-f`/`-r` checks | `file_response($p)`; filesystem validation is deferred to request-time preflight, so applications requiring startup validation must perform it explicitly |
| `PAGI::Response->stream($cb)` | `stream_response($cb)` |
| `$response->writer($send)` | `stream_response(async sub ($writer) { ... })` |
| `$response->respond($send)` | `invoke_app($response, $scope, $receive, $send)` |
| `$response->scope` | use the active Request/protocol object, or raw `$scope` |
| `$response->is_sent` | use `$request->connection->response_started` or raw `pagi.connection` |
| `$response->has_body_source` | no replacement: every constructed Response is already complete |
| `$response->cors(...)` | `PAGI::Middleware::CORS`, or ordinary `header` for a literal field |
| Canonically sorted keys from `PAGI::Response->json(...)` | JSON object member order is unspecified; use a specialized Response subclass when canonical bytes are required |
| `PAGI::App::File->app_path('static')` | `PAGI::App::File->from_app_path('static')`; the utility function `app_path(...)` continues to return a path string |
| Pages factory called with a Request/scope | call the source-free factory and use its application value directly |
| `http_default` wrapped around a Pages handler | `http_default => PAGI::Pages->not_found(...)` |
| `$ws->deny(status => ..., body => ...)` | `$ws->deny($response)` |
| `$sse->decline(status => ..., body => ...)` | `$sse->decline($response)` |

Package-name strings are still not application values. Load a package,
construct the component explicitly, and pass the object or coderef required by
that position.

### Construct once and return the value

**Before (removed):** a Request supplied a mutable accumulator and generic
finishers selected its body mode.

```perl
my $response = $request->response;
return $response->status(201)->json($item);
```

**After (shipped):** choose the class at construction.

```perl
use PAGI::Response qw(json_response);

return json_response(
    $item,
    status  => 201,
    headers => ['Location' => $location],
);
```

Common options are `status`, `content_type`, and a flat `headers` arrayref.
Unknown, duplicate, odd, and malformed options fail synchronously. Metadata
methods remain available before emission, but Response stores no request scope,
connection, receive/send callback, or Writer. `to_app` retains the exact
configured Response object. Each invocation derives a request-local delivery
plan before its first send; concurrent mutation during derivation remains
unsupported.

For a custom charset, make byte ownership explicit:

```perl
use Encode qw(encode);
use PAGI::Response qw(response);

return response(
    encode('ISO-8859-1', $text),
    content_type => 'text/plain; charset=iso-8859-1',
);
```

JSON is still UTF-8 JSON, but object-member order is not a contract. Tests
should decode and compare values. Signatures, hashes, or byte-stable caches need
a specialized Response subclass with a canonical encoder.

### Native applications use the application protocol

**Before (removed):** Response retained request state and accepted only send.

```perl
my $response = PAGI::Response->new($scope)
    ->status(201)
    ->json($data);
await $response->respond($send);
```

**After (shipped):** construction is request-independent; invocation state is
supplied only through application delegation.

```perl
use PAGI::Response qw(json_response);
use PAGI::Utils qw(invoke_app);

my $response = json_response(
    $data,
    status  => 201,
    headers => ['X-Request-ID' => $scope->{request_id}],
);
await invoke_app($response, $scope, $receive, $send);
```

Normal Route and Endpoint handlers return application values and do not emit
them directly; Response objects are the common case. `to_app` exposes the exact
Response as one native HTTP-only application.
Calling that application with WebSocket, SSE, lifespan, or an unknown scope
fails before emission; that application error does not promise a denial wire
response. Compose protocol-aware policy explicitly when controlled denial is
required.

### Move CORS policy out of Response

**Before (removed):** one Response method mixed request-origin, credential,
preflight, cache-variation, and header policy.

```perl
return text_response('ok')->cors(
    origin      => 'https://app.example',
    credentials => 1,
);
```

**After (shipped):** wrap the application with CORS middleware.

```perl
use PAGI::Middleware::Builder;

my $app = builder {
    enable 'CORS',
        origins     => ['https://app.example'],
        credentials => 1;
    $routing;
};
```

Use ordinary `header('Access-Control-Expose-Headers' => 'X-Request-ID')` only
when the requirement is one unconditional literal field rather than CORS
policy.

### Await Stream writes and treat disconnect as state

```perl
use Future::AsyncAwait;
use PAGI::Response qw(stream_response);

return stream_response(async sub ($writer) {
    await $writer->write("id,name\n");
    for my $row (@rows) {
        await $writer->write($row);  # one outstanding write
    }
});
```

Each write Future is the primary backpressure boundary. Starting another write
before it settles fails; no hidden queue is created. Transport watermarks are
optional. Writer returns neutral fallbacks when no invocation transport exists,
while the separate `transport($request)` helper returns `undef` for an absent
optional capability.

PAGI 0.002007 send settlement means the server accepted the event into outbound
processing or finished discarding it after disconnect. It does not mean the
client received the event. Writer awaits the send, then checks connection
state. That ordering is race-free: a discarded pending send resolves after the
state transition, returns normally, and does not increment `bytes_written`.
Disconnect never manufactures a write failure; genuine validation/resource
failures still propagate. Stream may cancel its own pending producer, never a
send Future, consumes no competing receive loop, and runs asynchronous cleanup
once. Ordinary HTTP Stream has no WebSocket/SSE reconnection behavior.

Under PAGI 0.002007 each returned `disconnect_future()` observer is
cancellation-isolated. Call the accessor again to obtain an observer for each
race and pass it directly to `Future->wait_any`; do not add a redundant
cancellation shield.

HEAD normally runs the complete GET producer behind the outer body-suppression
boundary. Put a lightweight explicit HEAD Route before an expensive streaming
GET Route to avoid that work.

### Separate selected File from request-path resolution

`file_response($path)` accepts one trusted path already selected by application
logic. `PAGI::App::File` resolves untrusted URL paths under a configured root
and owns traversal, hidden-file, index, missing, forbidden, and method policy.

File construction checks option shapes only. Existence, readability, metadata,
conditions, logical-window bounds, and client ranges are checked during each
request's preflight. This lets a reusable response follow file replacement and
rotation. Applications that require configuration mistakes to fail at startup
must perform explicit `-f`/`-r` checks during startup or lifespan handling.

`offset` and `length` define the physical window backing one complete logical
representation. The ordinary response is 200 with that logical length and no
Content-Range. Only a valid client Range is measured within the logical window
and produces 206. File uses an opaque PAGI `file` event and therefore opts out
of protocol denial adaptation.

### Pages factories return native apps

Pages factories are source-free and return deferred HTTP applications:

```perl
use PAGI::Pages qw(welcome not_found);
use PAGI::Routing qw(route mount);

route('/welcome' => welcome());
mount('/missing', app => not_found(detail => 'Missing'));
```

Native code delegates through the application protocol:

```perl
use PAGI::Utils qw(invoke_app);

my $application = PAGI::Pages->not_found(as => 'text');
await invoke_app($application, $scope, $receive, $send);
```

A custom one-Request default uses `request_response($handler)`. A Pages
application needs no adapter at `http_default`, Mount `app`, Compose `app`, or
a Route. Route and Mount continue to own different path shapes:

```text
Route('/x')       exact complete path leaf
Route('/*path')   explicit real catchall leaf
Mount('/x')       selected owner of /x and its complete subtree
```

### Deny WebSocket/SSE handshakes with Responses

```perl
use PAGI::Response qw(problem_response);

await $websocket->deny(
    problem_response({ title => 'Unauthorized', status => 401 }),
);

await $sse->decline(
    problem_response({ title => 'Not Found', status => 404 }),
);
```

Base, finite subclasses, Empty, Redirect, Stream, and subclasses preserving the
inherited `body-events-v1` event vocabulary are eligible. Buffering is a
separate concern. File is rejected before start because PAGI Www denial bodies
allow ordinary body events and explicitly exclude `file`/`fh`.

WebSocket still owns extension support and the policy-close fallback. SSE
decline is valid only before start and discards deferred keepalive when mapped
start commits. Mapped-start settlement commits the response slot, meaning the
server accepted/settled the event, not that the client received it. A pending
body send at disconnect resolves normally under PAGI 0.002007; post-commit cleanup
follows protocol/connection state and disconnect watchers rather than inferred
send failure. Genuine send failures still propagate.

HTTP Stream is a finite request's response body. WebSocket and live SSE own
their independent long-lived protocols, event formatting, keepalive, and
reconnection semantics.

### Apple application: why every boundary changed

The runnable `examples/starlette-apples/app.pl` and Cookbook carry the complete
After source. The response-facing changes are structural rather than cosmetic:

| Before | After and reason |
| --- | --- |
| root handler calls the generic file finisher | exact root Route receives `file_response($manager_file)` directly; File is already a `to_app` component |
| CRUD handlers call the generic JSON finisher | handlers return `json_response(...)`, preserving concrete class identity |
| Pages factories accepted request sources | source-free `welcome()` and other Pages factories return deferred applications |
| top-level `compose(routes => ...)` supplies stock fallback only | explicit Router owns `http_default => not_found(...)` while Compose owns root safety/lifespan |
| a catch-all might present the root 404 | `http_default` runs only on NONE, preserving 405/Allow for known paths |
| the `/apples` prefix appears in local reverse names | inside logical namespace `/apples`, local `read` resolves to `/apples/read`; there is no namespace deduplication |

The `/apples` Mount owns that complete subtree. Child 404/405 outcomes never
resume parent sibling scanning. The root file Route owns `/` only; a terminal
Mount would own its full selected subtree and ignore the remaining child path.

### Framework-author and Thunderhorse response handoff

The native PAGI application and middleware contract is unchanged:
`($scope, $receive, $send)`. Thunderhorse-facing changes are at the handler and
value boundaries:

- HTTP handlers receive `PAGI::Request` and return an immediate or
  Future-backed application value, commonly a concrete `PAGI::Response`.
- WebSocket/SSE handlers receive their direct protocol objects. Pre-start
  rejection passes a concrete Response to `deny`/`decline`.
- If Thunderhorse accepts ordinary Perl return values, its own controller layer
  must select/serialize them into an explicit Response class. PAGI-Tools does
  not infer a response type from return shape.
- Native app positions take native CODE or instantiated `to_app` objects.
  Adapt a one-Request default with `request_response($handler)`; do not infer
  coderef arity or pass package-name strings as applications.
- Helper ownership follows Request/protocol/native scope. Never make Response a
  scope source or cache a per-request Response accumulator.
- Use `ref($response)`/`isa` for representation policy, `is_buffered` for memory
  strategy, and `protocol_response_capability` for denial event vocabulary;
  those are independent questions.
- Thunderhorse may retain its own Controller/Router URL builder. PAGI::Tools URL
  helpers use `pagi.routing` frames, but a higher layer need not manufacture
  those frames for its own routing model.

`PAGI::Test::Response` remains a captured-wire decoder for tests. It is not the
production Response value and must not be accepted from application handlers.

## Breaking: replace the `PAGI` Context family with the protocol owner

The Context class family has been removed without a compatibility layer. There
is no replacement Context base class, factory hook, type map, or generic event
dispatcher. Normal callbacks receive the object that owns their protocol;
for this campaign, the callback-signature change applies to class Endpoint
frontends. Ordinary declarative and App Router callbacks already received the
direct protocol object and remain unchanged. Raw applications and every
middleware wrapper keep the native `($scope, $receive, $send)` contract
unchanged.

### Change class Endpoint callback signatures

**Before (removed):** class Endpoint callbacks received a Context wrapper.

```perl
# PAGI::Endpoint::HTTP
async sub get { my ($self, $ctx) = @_; ... }

# PAGI::Endpoint::WebSocket
async sub on_receive { my ($self, $ctx, $data) = @_; ... }
sub on_disconnect    { my ($self, $ctx, $code, $reason) = @_; ... }

# PAGI::Endpoint::SSE
async sub on_connect { my ($self, $ctx) = @_; ... }
sub on_disconnect    { my ($self, $ctx) = @_; ... }
```

**After (shipped):** use `PAGI::Request`, `PAGI::WebSocket`, and `PAGI::SSE`
directly.

```perl
use PAGI::Response qw(json_response);

async sub get {
    my ($self, $request) = @_;
    return json_response({ path => $request->path });
}

async sub on_receive {
    my ($self, $websocket, $data) = @_;
    await $websocket->send_json($data);
}
sub on_disconnect { my ($self, $websocket, $code, $reason) = @_; ... }

async sub on_connect {
    my ($self, $sse) = @_;
    await $sse->send_event(data => 'ready');
}
sub on_disconnect { my ($self, $sse) = @_; ... }
```

Ordinary declarative and App Router callbacks are not a Context-removal
migration. At the campaign base they already used these signatures, which
remain current:

```perl
$router->get('/'       => sub { my ($request)   = @_; ... });
$router->websocket('/' => sub { my ($websocket) = @_; ... });
$router->sse('/'       => sub { my ($sse)       = @_; ... });
```

Endpoint `on_disconnect` hooks remain deliberately synchronous. Do not return a
Future from them; finish asynchronous cleanup in an owned task or before the
protocol loop ends.

### Build Responses directly

**Before (removed):** `PAGI::Context::HTTP` lazily cached one detached Response
behind `response`/`resp`. Its complete response-construction shortcut set was
`text`, `html`, `json`, and `redirect`; each mutated that cached value and
returned it. The other HTTP-specific additions were `request`/`req`, guarded
`respond`, and `method`; scope, helper, connection, dispatch, and raw-channel
methods were inherited from the base class.

```perl
return $ctx->text('Created', status => 201);
return $ctx->html('<h1>Created</h1>', status => 201);
return $ctx->json($data, status => 201);
return $ctx->redirect('/items');

my $response = $ctx->response;
$response->status_try(500);
await $ctx->respond($response);
```

`status_try` was a Response method, not a Context method. Likewise the mutable
`empty`, `send`, `send_raw`, `stream`, `writer`, and `send_file` builder seams
were reachable through `response`; they were never Context
response-construction shortcuts.

**After (shipped):** construct and return one complete concrete Response. In
an explicit native application, delegate with all three invocation channels.

```perl
use PAGI::Response qw(
    html_response json_response redirect_response text_response
);
use PAGI::Utils qw(invoke_app);

return text_response('Created', status => 201);
return html_response('<h1>Created</h1>', status => 201);
return json_response($data, status => 201);
return redirect_response('/items');

my $response = json_response($data, status => 201);
await invoke_app($response, $scope, $receive, $send);
```

There is no per-callback cached response accumulator or Context-owned send
guard, and `PAGI::Request->response` has been removed. ErrorHandler receives a
complete Response from a custom renderer and preserves an explicitly selected
status; its precedence behavior is described below.

### Distinguish the two former Context `send` meanings

**Before (removed):** the base Context `send` method returned the raw send
coderef. HTTP and WebSocket inherited that accessor, so code called the
returned coderef to emit a native event. `PAGI::Context::SSE` alone overrode
the same method name: its `send($data)` emitted a data-only SSE event.
`raw_send` was the unambiguous raw-coderef accessor on every Context type.

```perl
# Base, HTTP, and WebSocket Context: accessor, then coderef call.
my $raw_send = $ctx->send;
await $raw_send->($event);

# SSE Context: protocol method, not the raw accessor.
await $ctx->send('Hello world');
my $sse_raw_send = $ctx->raw_send;
await $sse_raw_send->($event);
```

**After (shipped):** native applications and middleware already receive the
raw channel lexically and call it directly. Normal WebSocket and SSE handlers
use their direct protocol object's typed methods; `PAGI::SSE->send($data)`
retains the former SSE data-only behavior.

```perl
my $native_app = async sub {
    my ($scope, $receive, $send) = @_;
    await $send->($event);
};

await $websocket->send_text('Hello world');
await $sse->send('Hello world');
```

### Import optional capabilities from their owners

**Before (removed):** one object presented URL generation, stash, session,
state, CSRF, connection flow control, and transport as intrinsic methods.

```perl
my $path  = $ctx->path_for('show', { id => 42 });
my $stash = $ctx->stash;
my $user  = $ctx->session->get('user');
my $db    = $ctx->state->{db};
return $ctx->text('Forbidden', status => 403)
    unless $ctx->csrf_verify($submitted);
$ctx->on_drain(\&resume);
```

**After (shipped):** pass the direct protocol object to the owning helper.

```perl
use PAGI::CSRF qw(csrf);
use PAGI::Response qw(text_response);
use PAGI::Routing::URL qw(path_for url_for);
use PAGI::Session qw(session);
use PAGI::Stash qw(stash);
use PAGI::State qw(app_state);
use PAGI::Transport qw(transport);

my $path  = path_for($request, 'show', { id => 42 });
my $url   = url_for($request, 'show', { id => 42 });
my $user  = session($request)->get('user');
my $db    = app_state($request)->get('db');
my $guard = csrf($request);
stash($request)->set(result => $result);
stash($websocket)->set(subscription => $subscription);
stash($sse)->set(subscription => $subscription);

return text_response('Forbidden', status => 403)
    unless $guard->verify($submitted);

my $flow = transport($request);
$flow->on_drain(\&resume) if $flow;
```

`scope`, protocol input methods, connection state, and path/query/header
accessors stay on their direct Request, WebSocket, or SSE owner. `session`,
`csrf`, and routing URLs require their supplying middleware or Router metadata;
`stash` is scope-backed; `app_state` and `transport` return `undef` when their
optional capability is absent.

A blessed `PAGI::State` is not a hashref even while the temporary compatibility
overload permits hash dereference:

```perl
ref(app_state($request)) eq 'HASH';  # false
my $hashref = app_state($request)->data;
```

Use `->data` for HashRef type constraints, serializers, and exact `ref` checks.

### Update ErrorHandler callbacks

**Before (removed):** a custom renderer received Context and commonly returned
one of its response shortcuts.

```perl
handler => sub {
    my ($context, $error) = @_;
    return $context->json({ error => 'request failed' });
}
```

**After (shipped):** it receives `($request, $error)`. Return a complete
Response value; ErrorHandler applies its fallback status only when the returned
value retained the default status.

```perl
use PAGI::Response qw(json_response);

handler => sub {
    my ($request, $error) = @_;
    return json_response(
        { error => 'request failed' },
        status => 503,
    );
}
```

ErrorHandler derives a fallback status from a valid exception `status_code` or
its configured status. An explicit response status wins. ErrorHandler emits
the result; callbacks must return the value rather than sending it themselves.

### Remove Context extension and dispatch machinery

**Before (removed):** applications could override the Endpoint factory, assert
a protocol dynamically, reach through to raw channels, or register handlers on
one generic dispatcher.

```perl
sub context_class { 'MyApp::Context' }

sub _type_map {
    my ($class) = @_;
    return {
        %{$class->SUPER::_type_map},
        myproto => 'MyApp::ProtocolContext',
    };
}

$ctx->assert_websocket;
my $receive = $ctx->receive;
my $send = $ctx->raw_send;
my $event = await $receive->();
await $send->($event);
$ctx->on('app.notify' => \&notify);
await $ctx->run;
```

**After (shipped):** Endpoint construction is fixed to the direct Request,
WebSocket, and SSE objects. Use their typed send/receive methods. A custom
protocol supplies and documents its own object, while a native application or
middleware continues to own the raw channels explicitly:

```perl
my $app = async sub {
    my ($scope, $receive, $send) = @_;
    return await MyApp::Protocol->new($scope, $receive, $send)->run;
};
```

The removed surface includes Context constructors and subclasses, Endpoint
factory overrides, protocol assertions, the overrideable type map, the cached
HTTP Response accumulator and guarded `respond`, generic
`on`/`on_default`/`on_error` dispatch, `stop`, the inherited `receive` and
`raw_send` channel accessors, the base/HTTP/WebSocket `send` raw-coderef
accessor, and SSE's overriding `send($data)` protocol method. Lexical raw
channels and direct `PAGI::SSE->send($data)` remain available; do not introduce
a replacement hook that recreates this all-purpose ownership boundary.

## Running against PAGI-Server 0.002007

`PAGI::Test::Client` and its `PAGI::Test::WebSocket`/`PAGI::Test::SSE`/
`PAGI::Test::ConnectionState` companions are meant to be a faithful mock of a
real PAGI server. This release closes the gaps between them and the
released `PAGI-Server` 0.002007: the mock used to be looser than the real
server across most of the send path, which let a test suite pass against
behavior a live server would reject or handle differently. If your own tests
exercise apps through the test kit, expect some of them to start failing --
correctly, because they were passing on a mock server that was wrong.

### `disconnect_future` no longer resolves after a clean completion

**Before (unreliable):** `disconnect_future` on `PAGI::Test::ConnectionState`
was always `undef`, so any code that raced it against other work silently
never took that branch. Application code written against the documented
contract but only ever tested against the mock could reach production having
never actually exercised its disconnect-race path.

**After (shipped):** `disconnect_future` is modeled fully on the optional
`pagi.connection` handle: it resolves with the reason on an
abnormal disconnect, and stays pending forever if first requested *after* a
clean completion, since there is no disconnect left to report.

```perl
# Before: this raced a Future that could never resolve on the mock, hiding
# a bug that would only surface against a real server.
await Future->wait_any($req->connection->disconnect_future, $work);

# After: request it before the response completes, or use on_complete
# instead when you specifically need the "finished cleanly" case.
my $connection = $req->connection;
if ($connection && $connection->is_connected) {
    await Future->wait_any($connection->disconnect_future, $work);
}
```

### Sends are strict -- no lenient mode

**Before (silently absorbed):** an illegal event on the HTTP, WebSocket, SSE,
or lifespan `$send` -- a duplicate `http.response.start`, a body before
start, an undeclared `http.response.trailers`, a result reported for the
wrong lifespan phase -- was silently accepted by the test kit. An app that
returned without reaching a legal terminal state hard-died with a generic
"forgot to await" message instead of being reported the way a live server
reports it.

**After (shipped):** every `PAGI::Test::*` `$send` now fails the returned
`Future` for an illegal event, mirroring the shared `PAGI::SendValidation`
core also used by the development `Lint` middleware. An app that returns
without reaching a legal terminal state is now reported as an abnormal
`server_error` disconnect with a warning, not a hard die; an app that never
sends `http.response.start` at all now yields the server's synthesized 500
backstop instead of a phantom empty 200.

```perl
# Before: a bug like this passed silently under test.
await $send->({ type => 'http.response.start', status => 200, headers => [] });
await $send->({ type => 'http.response.start', status => 200, headers => [] }); # duplicate -- ignored

# After: the second call's Future fails, the way a real server rejects it.
await $send->({ type => 'http.response.start', status => 200, headers => [] });
await $send->({ type => 'http.response.start', status => 200, headers => [] }); # dies here
```

If an application throws *after* its HTTP response already reached a legal
terminal state, the test kit now returns the real, already-complete response
(`on_complete` fires, not `on_disconnect`) instead of overwriting it with a
synthetic 500 -- nothing on the wire was corrupted, so nothing is replaced.
An exception before the response is complete keeps the existing 500 +
`server_error` behavior.

The strictness pass also tightened several `PAGI::Test::WebSocket`/
`PAGI::Test::SSE` behaviors that hit test-writing users directly -- a test
that used to rely on the old lenient shape now hangs or fails instead of
silently passing:

- **`Test::WebSocket`'s synthesized `websocket.disconnect` is delivered
  exactly once**, with a truthful `code` and `reason` (previously repeated
  on every subsequent `receive` call, with the reason dropped). A test app
  that keeps calling `receive` after disconnect now hangs -- correctly,
  since a real transport has gone silent -- instead of getting a phantom
  disconnect on every call.
- **An app `websocket.send` after the app's own `websocket.close` now fails
  the Future** (was silently appended to the client's readable stream). A
  send after the *test/peer* side closed is now a tolerated no-op instead --
  dropped, not delivered, but does not fail the app's Future.
- **`websocket.close` sent before `websocket.accept` (a portable denial) no
  longer croaks** `"WebSocket connection not accepted"`; `Test::WebSocket`
  reports the closed/denied state instead.
- **`Test::SSE` recognizes an app's decline** (`sse.http.response.start` /
  `.body`) instead of croaking `"SSE connection not started"` -- `sse`
  returns a `Test::Response` with the declined status/body, and no
  `sse.disconnect` is delivered (the stream never started).
- **`Test::SSE`'s synthesized `sse.disconnect` is delivered exactly once**,
  with an explicit `reason` (default `client_closed`), instead of being
  repeated reason-less on every subsequent `receive` call.

### The rest of this release's breaking changes

Everything else `[BREAKING]` in this release, in one place. Several of these
have their own dedicated section elsewhere in this guide (linked below); the
rest are covered only here.

- **Development middleware.** `PAGI::Middleware::Lint` no longer keeps its
  own copy of send-sequencing state -- it delegates to the shared
  `PAGI::SendValidation` core. In strict mode a shared-core violation now
  rejects the event outright instead of warning and forwarding it.
- **Removed middleware and apps.** `PAGI::Middleware::WebSocket::RateLimit`,
  `PAGI::App::SSE::Pubsub`, `PAGI::App::WebSocket::Broadcast`, and
  `PAGI::App::WebSocket::Chat` are removed outright, with no replacement
  shipped in this release -- they impersonated server lifecycle events they
  could not keep faithful, or taught a send pattern (holding and calling
  another scope's `send`) the PAGI spec now rules out. See the Cookbook's
  "In-Loop WebSocket Rate Limiting" recipe for the in-loop replacement and
  its "Real-Time Fan-Out (Pub/Sub)" section for the fan-out guidance; real
  multi-scope fan-out is the scope of the coming PAGI-Channels distribution,
  not this toolkit.
- **`PAGI::App::WebSocket::Echo`'s `on_disconnect`** now receives `($scope,
  $code, $reason)` instead of `($scope, $code)`.
- **Request bodies.** `PAGI::Request`'s `body`/`text`/`json`/`form_params`
  (and the equivalent `PAGI::Middleware` body helpers) no longer treat a
  mid-body `http.disconnect` as a clean end of body -- they now croak with
  `"Request body incomplete: client disconnected mid-body ($reason)"`. An
  immediate disconnect before any body bytes ever arrive is still a
  legitimate empty body.
- **`PAGI::Test::Client` HTTP responses** are now H1-flavored: app-supplied
  `Transfer-Encoding`/`Connection` headers are stripped with a warning, and
  every scope now advertises an `extensions` key.
- **`PAGI::Compose::ResponseGuard`** now fails a response typed
  `awaiting_trailers` if it declares `trailers => 1` but never sends them,
  and rejects a body sent before response start as a failed `Future` from
  `send` (was a synchronous `die`).
- Also see the dedicated sections below for the Pages/NotFound/Redirect
  migration, the Router/Endpoint::Router frontend rewrite, and the rooted
  file-serving contract -- all `[BREAKING]` in this same release.

## Rooted file-serving security contract

Rooted file components now share one lexical request-path contract. The
following Before material is migration history, not current security advice.

### Replace manual request-path deletion

**Before (historical and unsafe; do not copy):** handlers commonly deleted
dot text, concatenated the result with a root, guessed a MIME type, and read
the complete file into memory.

```perl
my $path = $scope->{path};
$path =~ s/\.\.//g;
my $file = "$root/$path";
open my $fh, '<:raw', $file or die $!;
```

**After (shipped default):** give conventional static-file ownership to one
`PAGI::App::File`.

```perl
use PAGI::App::File;

my $app = PAGI::App::File->from_app_path('public')->to_app;
```

It owns validation, index and MIME selection, conditional and Range requests,
streaming `file` events, and negotiated stock errors.

**After (shipped custom native boundary):** when authorization or response headers
require a custom handler, validate before any filesystem policy and emit only
the returned lexical path.

```perl
use Future;
use Future::AsyncAwait;
use PAGI::Pages qw(forbidden not_found);
use PAGI::Utils qw(invoke_app path_from_root);

my $app = async sub {
    my ($scope, $receive, $send) = @_;
    my $untrusted_path = $scope->{path};

    my $path = path_from_root('/var/www/files', $untrusted_path);
    unless (defined $path) {
        my $response = forbidden();
        return await invoke_app($response, $scope, $receive, $send);
    }

    # Replace the safe default with application-specific authorization.
    my $authorized = 0;
    unless ($authorized) {
        my $response = forbidden();
        return await invoke_app($response, $scope, $receive, $send);
    }

    unless (-f $path && -r $path) {
        my $response = not_found();
        return await invoke_app($response, $scope, $receive, $send);
    }

    await Future->wrap($send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'application/octet-stream']],
    }));
    return await Future->wrap($send->({
        type => 'http.response.body', file => $path, more => 0,
    }));
};
```

`path_from_root` performs no I/O, does not require the result to exist, and
does not resolve symlinks. The PAGI server opens a later `file` event.
Configured symlinks therefore extend administrator authority beyond the
lexical root. Use a dedicated root that attackers cannot modify and enforce
appropriate ownership and permissions. Those practices reduce unintended
exposure and pathname races; neither the helper nor the file components claim
physical confinement.

### Rename the hidden-file policy

**Before (removed option):**

```perl
PAGI::App::Directory->new(root => $root, show_hidden => 1);
```

**After (shipped):**

```perl
PAGI::App::Directory->new(root => $root, allow_hidden => 1);
```

`allow_hidden` governs both direct serving and directory listings. With the
default false value, hidden request components are forbidden and hidden index
candidates are skipped.

### Audit byte-range request assumptions

**Before:** the File/Static parser searched for an unanchored range-shaped
substring, treated `bytes=-N` as starting at byte zero, and could silently
accept malformed or multi-range input.

**After:** File owns one strict shared parser for exactly one ASCII
`bytes=start-end` interval. Open-ended and last-`N` suffix forms are supported;
an oversized end is clamped. Empty or repeated Range fields, empty or
zero-length suffixes, non-ASCII digits, malformed values, reversed/beyond-end
intervals, and comma-separated multi-ranges receive 416 with
`Content-Range: bytes */N`. Static delegates the same behavior, and HEAD keeps
the corresponding GET status and headers without file bytes. Applications that
need multipart byte ranges must implement a separate response policy.

### Audit directory-listing URLs and filename identity

**Before:** relative entry links from a slashless or mounted directory could
resolve against the wrong browser base, and a listing could expose a filesystem
name that the public request grammar could not retrieve under the same identity.

**After:** HTML entry and parent links are absolute, encoded request paths built
from PAGI `root_path` plus `path`, so navigation remains inside the mount.
Listings omit separator-bearing, all-dot, platform-absolute/volumed, and invalid
UTF-8 byte names, while `allow_hidden` continues to govern ordinary dot names.
JSON and HTML therefore expose only names that round-trip losslessly through the
same public request grammar.

### Audit status, symlink, method, and mapping assumptions

| Before | After |
|---|---|
| File NUL request -> 400 | common unsafe-path 403 |
| outward symlink rejected | trusted configured symlink served |
| Directory missing -> failed-realpath 403 | missing 404 |
| Directory POST listing -> 200 | 405, `Allow: GET, HEAD` |
| `show_hidden` listing-only option | `allow_hidden` serving/listing policy |
| Static hidden files allowed | hidden files forbidden by default |
| textual/hash-order XSendfile mapping | component-aware most-specific mapping |
| unmatched hash emits raw proxy path | original PAGI file event continues |

The XSendfile source mapping is normalized as a filesystem path, matches at
component boundaries, chooses the longest normalized source prefix, and uses
lexical source-prefix order only to break equal-specificity ties. An unmatched
hash mapping declines interception and forwards the original response start
and `file` event. Review proxy mappings as trusted administrator configuration,
not as authorization.

See `PAGI::App::File`, `PAGI::App::Directory`, `PAGI::Middleware::Static`,
`PAGI::Middleware::XSendfile`, and the authenticated recipe in
`PAGI::Tools::Cookbook` for the live contracts.

## Pages response factory and default response migrations

`PAGI::Pages` owns conventional first-party welcome, HTTP error, and redirect
representations. Every Pages function or method is a source-free factory that
returns a deferred HTTP application. It never changes meaning by arity.

### Replace the removed NotFound application

**Before (removed):**

```perl
PAGI::App::NotFound->new->to_app;
```

**After (shipped):**

```perl
use PAGI::Pages qw(not_found);

my $not_found_app = not_found(detail => 'No such page');
```

The replacement negotiates HTML, RFC 9457 problem JSON, or text and defaults
to `Cache-Control: no-store`. For an intentionally literal body, keep using a
direct Response instead:

```perl
use PAGI::Response qw(text_response);

text_response('No such page', status => 404)->to_app;
```

### Replace the removed Redirect application

**Before (removed):**

```perl
PAGI::App::Redirect->new(
    to             => '/new',
    status         => 308,
    preserve_query => 1,
)->to_app;
```

**After (shipped):**

```perl
use PAGI::Pages qw(redirect);

my $redirect_app = redirect(
    '/new',
    status         => 308,
    preserve_query => 1,
);
```

The old application preserved the incoming query by default. Pages defaults
`preserve_query` to `0`; opt in as above when query propagation is intended.
When enabled, Pages appends the raw query without re-encoding it and places it
before the first target fragment. Dynamic destinations move to an ordinary
Request handler that computes the target and returns the Pages application.

Pages redirects accept only 301, 302, 303, 307, and 308. An invalid code fails
when the factory is invoked. The selected representation has a body and is
negotiated; use `redirect_response` when a literal empty redirect is the
application contract.

### Replace ErrorHandler content_type

The `content_type` option has been removed. The built-in response now
negotiates through Pages. Use the existing `handler` seam to fix a
representation.

**Before (removed HTML selection):**

```perl
middleware('ErrorHandler', content_type => 'text/html');
```

**After (shipped):**

```perl
use PAGI::Response qw(html_response);

middleware('ErrorHandler',
    handler => sub {
        my ($request, $error) = @_;
        return html_response(
            '<h1>Internal Server Error</h1>',
            status => 500,
        );
    },
);
```

**Before (removed JSON selection):**

```perl
middleware('ErrorHandler', content_type => 'application/json');
```

**After (shipped):**

```perl
use PAGI::Response qw(problem_response);

middleware('ErrorHandler',
    handler => sub {
        my ($request, $error) = @_;
        return problem_response({
            title  => 'Internal Server Error',
            status => 500,
        });
    },
);
```

**Before (removed text selection):**

```perl
middleware('ErrorHandler', content_type => 'text/plain');
```

**After (shipped):**

```perl
use PAGI::Response qw(text_response);

middleware('ErrorHandler',
    handler => sub {
        my ($request, $error) = @_;
        return text_response(
            'Internal Server Error',
            status => 500,
        );
    },
);
```

The wrapper adapts ErrorHandler's `($request, $error)` callback to its required
concrete Response. It may inspect `$error` when deliberately choosing safe
response fields. Source-free Pages values are applications and belong at
Route, Mount, Router-default, or Compose application boundaries instead.

To use request negotiation, remove `content_type` and do not install a
representation-fixing handler. Existing custom handlers remain authoritative
and literal.

Without a custom handler, an exception's `status_code` is kept only when it is
a registered Pages error that needs no missing protocol facts. Bare 401, 405,
407, and 426 claims now fall back to safe 500, as do unknown, unused,
obsoleted, non-error, malformed, reference-valued, throwing, or failed-Future
claims. A configured `status` follows the same restriction unless a custom
handler is supplied; with a handler it remains that handler's seed value.

### Update Router and Compose default appearance assertions

Router now owns mandatory HTTP 404 and 405 outcomes; Compose owns the root 500
failsafe. Their stock representations negotiate through Pages instead of using
fixed plain or ErrorHandler-configured bodies. Status choice and `no-store`
behavior remain, and Router's 405 carries the authoritative `Allow` union.
Tests that asserted a built-in English body should assert status, required
fields, and selected media type, or install an explicit handler at a supported
policy seam.

There is no `pages` option on Compose. Supply
a Pages endpoint as Router `http_default` to customize HTTP NONE, and install
ordinary ErrorHandler middleware for application exception policy. Router's
built-in PARTIAL/405 outcome has no fallback-middleware override. Compose's
stock outer ErrorHandler remains installed and recovers if an inner application
renderer fails before response start.

### Audit changed first-party defaults

The triggering condition and status remain owned by each component below.
Only its stock generic HTTP error or Location-redirect branch moved to Pages.
Consequently the default body, `Content-Type`, byte `Content-Length`, `Vary`,
and cache fields may change through consistent negotiation and encoding.

| Component | Stock default now delegated to Pages | Facts or custom branch preserved |
|---|---|---|
| `PAGI::App::File` | 403, 404, 405, 416 | 405 supplies `Allow: GET, HEAD`; 416 supplies selected file length |
| `PAGI::App::Directory` | listing `opendir` permission 403 plus inherited File 403, 404, 405, and 416 | File owns request-path policy, location Results, indexes, and delegated responses; Directory owns only eligible listing rendering and listing I/O |
| `PAGI::App::URLMap` | no-default HTTP 404 | mount selection and opaque ownership remain local |
| `PAGI::App::Proxy` | backend-connect 502 | connection decision and demo warning remain local |
| `PAGI::App::Loader` | HTTP load-failure 500 | loading, warnings, and reload policy remain local |
| `PAGI::App::WrapCGI` | HTTP process-start 500 | CGI execution and parsed CGI responses remain literal |
| `PAGI::App::Throttle` | default HTTP 429 | `retry_after`, enabled rate-limit fields, and `on_limit` |
| `PAGI::Middleware::Static` | 403, 404, 416 | pass-through remains local; 416 supplies selected file length |
| `PAGI::Middleware::Auth::Basic` | default 401 | generated Basic challenge and configured realm |
| `PAGI::Middleware::Auth::Bearer` | default 401 | generated Bearer challenge, realm, and safe failure detail |
| `PAGI::Middleware::CSRF` | enforced default 403 | validation and `enforce => 'app'` application responses |
| `PAGI::Middleware::ContentNegotiation` | strict-mode 406 | supported-type detail and existing scope metadata |
| `PAGI::Middleware::FormBody` | body-limit 413 | limit and request consumption remain local |
| `PAGI::Middleware::JSONBody` | body-limit 413; invalid-JSON 400 | parsing decision remains local; decoder exception text is no longer exposed |
| `PAGI::Middleware::Maintenance` | built-in 503 | `retry_after` and bypass/enabled decisions; explicit `body` or `content_type` keeps the literal branch |
| `PAGI::Middleware::RateLimit` | default 429 | `retry_after` and `X-RateLimit-*` fields |
| `PAGI::Middleware::ReverseProxy` | forwarded-authority 400 | trust and normalization decisions remain local |
| `PAGI::Middleware::TrustedHosts` | missing, malformed, duplicate, or rejected Host 400 | host policy remains local |
| `PAGI::Middleware::HTTPSRedirect` | invalid-authority 400 and redirect | authority/HSTS policy, code, path, and query remain local |
| `PAGI::Middleware::Rewrite` | redirect-mode response | rule selection, code, rewritten path, and incoming query remain local |
| `PAGI::Endpoint::HTTP` | automatic 405 | complete computed `allowed_methods` result |

File's automatic 405 now includes its required `Allow: GET, HEAD`. File and
Static invalid-range responses now include `Content-Range: bytes */N` when the
selected representation length is known. JSONBody's stable client detail is
`The request body is not valid JSON.` rather than the raw decoder diagnostic.

ContentNegotiation now uses `PAGI::Request::Negotiate` for the same effective
quality rules as Pages. An exact `q=0` exclusion overrides less-specific
positive wildcards, and equal-quality matches retain server order. Its strict
406 is a Pages response selected independently from the application's offered
types; total page-representation rejection uses Pages' failsafe default rather
than recursing into another 406.

Basic and Bearer realms are quote/backslash escaped for their schemes and then
strictly validated as response-header values. HTTPSRedirect and Rewrite pass
the unmodified logical target plus `preserve_query => 1`, so an incoming query
is now placed before a target fragment. Their redirect codes are validated at
construction against the five Pages redirect statuses.

Stock changed representations are distinct from preserved custom branches.
Maintenance uses Pages only when neither `body` nor `content_type` was supplied;
either option retains its literal response. Throttle's `on_limit`, every
custom routing/error handler, application-authored body, callback response,
and explicit Response remain authoritative and unnegotiated. Healthcheck
documents, bodyless 204/304/conditional/range-success responses, CORS
preflights, WebSocket/SSE protocol outcomes, and literal teaching examples do
not become Pages output.

Only HTTP defaults use Pages. Three formerly malformed non-HTTP fallbacks now
fail clearly instead of emitting `http.response.*` events on another protocol:

- Loader load failure croaks that the application could not be loaded for the
  received scope type.
- URLMap exhaustion without a default croaks that it has no default for the
  received scope type.
- Throttle exhaustion without `on_limit` croaks that its built-in response is
  HTTP-only and names `on_limit` as the escape hatch.

### Account for related negotiation and scope-type hardening

Concrete Accept matching now uses the most-specific effective quality, so a
positive wildcard no longer revives an exact `q=0` exclusion. Wildcard queries
still succeed when at least one covered concrete type has positive effective
quality, including a positive concrete exception inside an excluded family.

Defined unknown scope types are never treated as HTTP. Missing, empty, or
reference-valued scope types croak as malformed. Applications supporting an
extension protocol should validate it explicitly and construct the custom
protocol object they own.

## Routing composition redesign

This redesign lands inside unreleased `0.002003`, before the next CPAN release,
with no compatibility layer. Route matches a complete URL leaf. Mount composes
an application under a prefix. Router selects and owns routing outcomes.
Middleware wraps behavior. Compose owns the application root and lifespan.

### Replace Router callbacks with Router outcomes

Routers now own HTTP NONE and PARTIAL. NONE invokes `http_default`, or the
stock negotiated Pages 404 when no custom default is declared. PARTIAL emits
the built-in negotiated 405 with one authoritative `Allow` union.

**Before (removed):** Router construction accepted response callbacks.

```perl
my $routing = router(
    routes                 => \@routes,
    not_found              => \&not_found,
    method_not_allowed     => \&method_not_allowed,
);
```

**After (shipped):** configure the Router's HTTP-only default. Method Not
Allowed remains Router-owned.

```perl
use PAGI::Routing qw(router);

my $routing = router(
    routes       => \@routes,
    http_default => $not_found_app,
);
my $app = $routing->to_app;
```

Those removed names are rejected as unknown Router options. They are not
ignored, warned about, or retained as aliases. The removal applies equally to
the immutable, App, and Endpoint Router frontends.

Use a different `http_default` when one reusable subsystem owns different 404
presentation:

```perl
my $api = router(
    routes       => \@api_routes,
    http_default => $api_not_found_app,
);
```

The default is a native app coderef or instantiated `to_app` object. It runs
only for HTTP NONE—not PARTIAL, WebSocket, SSE, selected exceptions, or a
handler-returned 404. GET contributes HEAD to the generated 405 union.

### Distinguish direct Router safety from the application root

**Before (removed behavior):** a bare Router could finish an unmatched request
without sending any response.

```perl
my $app = $routing->to_app;
```

**After (shipped):** direct compilation sends the Router's own 404 and 405 and
installs its own HeadBoundary. Compose supplies a separate outer, idempotent
application-root HEAD boundary plus root safety and lifecycle.

```perl
# Router-complete outcomes: HTTP NONE/405 are sent here.
my $routing_app = $routing->to_app;

# Deployed application: adds an outer HEAD owner, ErrorHandler, guard, lifespan.
my $app = compose(app => $routing)->to_app;
```

The bare Router still lacks the root ErrorHandler, response-completion guard,
and lifespan driver. It also does not turn silence from a selected application or
Mount target into a miss. Compose reports that silence as incomplete output
and renders 500 before response start.

For every HTTP target, Compose installs this exact outer-to-inner graph:

```text
outer idempotent application-root HEAD boundary
  Compose ErrorHandler failsafe
    response-completion guard
      author Compose middleware, in listed order
        target Router or application
```

These automatic layers are mandatory and deliberately stock. Compose has no
`not_found`, `method_not_allowed`, `server_error`, disable, or replacement-
detection options. Router 404/405 responses travel outward through author
middleware. Install official error policy inside request IDs, access logging,
and security-header middleware so those wrappers observe its 500 response:

```perl
middleware => [
    'RequestId',
    'AccessLog',
    'SecurityHeaders',
    middleware('ErrorHandler',
        handler  => \&site_server_error,
        on_error => \&report_error),
]
```

The automatic emergency bodies sit outside the author stack and therefore do
not travel inward through it. Their production output is safe and generic.

### Choose routing-aware or opaque Mount ownership explicitly

Once any Mount prefix wins, that occurrence owns the request; the parent never
resumes later route scanning. Every Mount now has exactly one named target:
`app` or `routes`.

**Before (removed positional target):**

```perl
mount('/legacy' => $legacy_router->to_app)
```

**After (shipped, inspectable Router application):** retain the immutable
Router object under `app`. Its 404/405 responses remain child-owned and its
names remain visible to the parent resolver.

```perl
mount(
    '/legacy',
    app  => $legacy_router,
    name => 'legacy',
)
```

Occurrence-specific policy belongs directly on the Mount:

```perl
mount(
    '/legacy',
    app        => $legacy_router,
    name       => 'legacy',
    middleware => [
        $legacy_headers,
    ],
)
```

**After (shipped, intentionally opaque):** pass a native app coderef or another
instantiated component through the same `app` option.

```perl
mount('/legacy', app => $legacy_app)
```

An opaque Mount hides child names but still owns its selected output. Silence
is an application lifecycle error, not a signal to resume the parent. Raw
route targets remain exact method-aware leaves rather than prefix mounts.

`routes => [...]` and mutable `routes => sub { my ($child) = @_; ... }` are
exact shorthand for a real child Router application. The callback runs once
during declaration, receives a fresh child builder, and ignores its return
value. Both `/legacy` and `/legacy/` normalize to child path `/`.

### Complete Router children placed in URLMap

`PAGI::App::URLMap` mounts and its `default` target are always opaque.

**Before:**

```perl
my $map = PAGI::App::URLMap->new;
$map->mount('/api' => $api_router->to_app);
```

**After (also shipped):** the spelling remains valid because URLMap has its
own opaque two-argument API.

```perl
my $map = PAGI::App::URLMap->new;
$map->mount('/api' => $api_router->to_app);
```

The same rule applies to `default`. Routers now render their own 404/405, but
URLMap does not inspect their names or resume a parent route scan. Use
declarative `mount('/api', app => $api_router)` when reverse discovery matters.

### Cascade catches responses, not Router decline

Router entries advance only when their ordinary 404/405 response status appears
in `catch`.

```perl
my $routing = PAGI::App::Cascade->new(
    apps  => [$static_app, $api_router->to_app, $site_router->to_app],
    catch => [404, 405],
);
```

**After (shipped):** the spelling stays valid and there is one rule: an
explicit non-final response advances only when its status appears in `catch`.

```perl
my $routing = PAGI::App::Cascade->new(
    apps => [$static_app, $api_router->to_app, $site_router->to_app],
);

my $app = compose(app => $routing)->to_app;
```

A final Router response passes through unchanged. An arbitrary silent child is
an incomplete-application error, not an implicit miss. Non-caught responses
stream their start and body chunks as they
arrive instead of waiting for whole-child completion. A later exception is
therefore observably after response start and must propagate. Caught responses
are suppressed, awaited through their terminal body, and only then advance.

### Update ErrorHandler lifecycle expectations

**Before (removed behavior):** an exception after
`http.response.start` was warned about and swallowed, so callers could observe
normal completion even though the response was incomplete.

```perl
# Earlier tests could expect this failed stream to complete normally.
await $wrapped->($scope, $receive, $send);
```

**After (shipped):** ErrorHandler awaits reporting, emits no replacement
response, and rethrows the original exception for the server to abort the
stream.

```perl
my $future = Future->wrap($wrapped->($scope, $receive, $send));
die 'reporting was not awaited' if $future->is_ready;
$reporting_finished->done;
my $error = dies { $future->get };
is(refaddr($error), refaddr($original_error));
is($response_starts, 1);
```

```perl
my $errors = middleware(
    'ErrorHandler',
    handler => sub {
        my ($request, $error) = @_;
        return PAGI::Response::json_response({ error => 'request failed' });
    },
    on_error => sub {
        my ($error) = @_;
        return $reporter->record($error); # immediate value or Future
    },
);
```

Before response start, a database throw or failed Future is reported and then
rendered by the custom or built-in handler. After response start, the renderer
is never called: `on_error` must settle first, its own failure is contained,
and the original database exception is rethrown unchanged. Tests that formerly
expected normal completion must now expect that failure and exactly one
response-start event.

Ordinary ErrorHandler construction keeps static `development => 0`; it does
not consult `PAGI_ENV`. Compose's private outer failsafe resolves development
mode per handled request and falls back to safe production output if
environment resolution itself fails. Every built-in Pages-backed
representation adds `Cache-Control: no-store`, uses UTF-8 octets encoded once,
and `Content-Length` counts the emitted bytes. A custom renderer owns its own
content type and cache policy.

### Keep catch-all routing distinct from NotFound policy

**Before (too broad for error policy):** a final route was sometimes used only
to manufacture the application's missing-page response.

```perl
route('/*path' => \&missing_page, methods => ['GET'])
```

**After (shipped application policy):** use the owning Router's HTTP default.

```perl
my $routing = router(
    routes       => \@routes,
    http_default => $missing_page_app,
);
```

Retain an ordinary catch-all when it really is a selected resource, such as an
SPA shell:

```perl
route('/*path' => \&spa_shell, methods => ['GET'])
```

It participates in declaration order, captures, method matching, and route
middleware. A GET-only catch-all gives an unknown POST a method partial; a
`methods => '*'` catch-all can deliberately supersede earlier partials.

`http_default` runs only after its Router reaches NONE. It does not make a
parent catch-all resume after a selected Mount already owns the path.

Router exhaustion is now an ordinary application outcome: HTTP NONE uses the
Router's `http_default` or stock 404, and HTTP PARTIAL uses the built-in 405.
The `pagi.routing` scope value is reserved for selected reverse-routing
metadata; it is not a status or decline channel.

## Choose a frontend: three descriptions, one engine

**Before (removed):** the App frontend owned the matcher while the Endpoint
frontend added a separate handler, middleware, Context, and state adaptation
layer around it.

```perl
my $app_router = PAGI::App::Router->new;
my $app = $app_router->to_app;

my $endpoint_app = MyApp::Endpoint->to_app;
```

**After (shipped):** choose an immutable functional description, a mutable
closure builder, or a method-oriented Endpoint, then compile the same immutable
`PAGI::Routing::Router` model.

```perl
use PAGI::Response;
use PAGI::Routing qw(router route);

my $immutable = router(routes => [
    route('/health' => sub { return PAGI::Response::text_response('ok') }),
]);

my $builder = PAGI::App::Router->new;
$builder->get('/health' => sub { return PAGI::Response::text_response('ok') });
my $builder_snapshot = $builder->to_router;

my $endpoint = MyApp::Endpoint->new(repository => $repository);
my $endpoint_snapshot = $endpoint->to_router;
```

Use `PAGI::Routing` for already-immutable composition, `PAGI::App::Router` for
incremental closure declarations, and `PAGI::Endpoint::Router` for handlers
bound to one configured object.

Why: one compiler now gives all three frontends the same matching, middleware,
metadata, reverse-routing, and Router-owned HTTP outcomes.

## Router handlers now receive direct protocol objects

**Before (removed):** an ordinary App route target was a native PAGI
application and owned all three channels.

```perl
$r->get('/people' => sub {
    my ($scope, $receive, $send) = @_;
    return send_people_response($scope, $receive, $send);
});
```

**After (shipped):** an ordinary HTTP handler receives one strict
`PAGI::Request` and returns an application value, immediately or through a
`Future`. Response objects are the common case; native CODE and other
instantiated `to_app` objects are also valid. WebSocket and SSE handlers receive
`PAGI::WebSocket` and `PAGI::SSE` respectively.

```perl
use PAGI::Response;

$r->get('/people' => sub {
    my ($request) = @_;
    return PAGI::Response::json_response($repository->all_people);
});
```

Why: the shared compiler can validate and emit HTTP responses consistently
without rebuilding the all-purpose Context object around intrinsic HTTP input,
Router behavior, middleware data, and response construction.

`PAGI::Request->new($scope, $receive)` now requires an unblessed HTTP scope
with an explicit scalar `type => 'http'` and a receive coderef. It does not
accept WebSocket/SSE scopes or metadata-only construction. Normal Router
dispatch constructs Request directly; native applications may construct it when
they opt into the HTTP input API.

### Import optional capabilities from their owners

Router and middleware facilities are no longer presented as intrinsic Request
methods:

```perl
# Before
my $path = $c->path_for('show', { person_id => 42 });
my $url  = $c->url_for('show', query => { tab => 'posts' });
my $db   = $c->state->{db};
my $user = $c->session->get('user');
$c->stash->set(result => $result);
return $c->text('Forbidden', status => 403)
    unless $c->csrf_verify($submitted);
```

The replacement names the owner of each capability:

```perl
use PAGI::CSRF qw(csrf);
use PAGI::Pages;
use PAGI::Routing::URL qw(path_for url_for);
use PAGI::Session qw(session);
use PAGI::Stash qw(stash);
use PAGI::State qw(app_state);
use PAGI::Transport qw(transport);

my $path    = path_for($request, 'show', { person_id => 42 });
my $url     = url_for($request, 'show', query => { tab => 'posts' });
my $db      = app_state($request)->get('db');
my $user    = session($request)->get('user');
my $result  = stash($request)->get('result');
my $token   = csrf($request)->token;
my $flow    = transport($request);  # undef when the server supplied none

return PAGI::Pages->forbidden
    unless csrf($request)->verify($submitted);
```

Pages factories do not accept the Request or native scope. There is no exported `state`
function: under `use v5.40`, a call spelled `state (...)` is parsed as Perl's `state`
declaration and silently does not call an imported sub. Use `app_state` or the
method form `$request->state`.

`PAGI::State` is a strict facade. The transitional spelling
`$request->state->{db}` still dereferences through overload and warns once per
package/file/line. Set `PAGI_SILENCE_STATE_HASHREF_WARNING` to exactly `1` to
suppress that warning temporarily. The overload does not make the facade a
real hashref:

```perl
ref($request->state) eq 'HASH';  # false
my $hashref = $request->state->data;
```

Pass `->data` to HashRef type constraints, serializers, cloning libraries, and
code guarded by `ref($value) eq 'HASH'` while migrating.

Session and CSRF croak when their required middleware-owned data is absent.
State and Transport return `undef` when the optional capability is absent.
Stash is created lazily in the request scope.

### Connection and transport are separate optional capabilities

```perl
# Before
$c->on_disconnect(\&cancel);
$c->on_drain(\&resume);

# After
my $connection = $request->connection;
$connection->on_disconnect(\&cancel) if $connection;

my $flow = transport($request);
$flow->on_drain(\&resume) if $flow;
```

`$request->is_disconnected` is tri-state: true after a supplied connection
disconnects, false while it remains connected, and `undef` when the server did
not provide `pagi.connection`. Test `defined` when unsupported must differ from
connected. Advanced connection methods move behind `$request->connection`;
outbound buffering, watermarks, and drain callbacks move behind
`transport($request)`.

### Pages factories are source-free

`PAGI::Pages` functions and methods return deferred native HTTP applications.
Pass them directly to Route, Mount, Router defaults, Compose, or `invoke_app`.
There is no arity-dependent Pages bridge.

### Direct protocol ownership is now complete

The former wrapper class family is removed by this release. Normal HTTP
handlers return an application value. A native application delegates through
`invoke_app($value, $scope, $receive, $send)`; Response exposes no separate
public emission protocol.

### Framework-author and Thunderhorse handoff

The PAGI protocol contract is unchanged: a native application or middleware
still receives `($scope, $receive, $send)`. This is a PAGI-Tools handler API
break, not a change to PAGI itself.

Framework adapters should account for these points:

- HTTP Route callbacks now receive `PAGI::Request`; WebSocket and SSE callbacks
  receive their direct protocol objects.
- Request construction is HTTP-only and takes exactly `($scope, $receive)`.
- Removed wrapper subclasses, type maps, and construction overrides have no
  replacement in shared Router dispatch.
- Router URL generation belongs to `PAGI::Routing::URL`. Thunderhorse may keep
  its own Controller/Router URL builder and need not manufacture
  `pagi.routing` frames for it.
- State is a `PAGI::State` facade with the temporary warned hash-dereference
  bridge described above.
- HTTP handlers still return an application value directly or through a
  Future. Response construction uses the concrete class/factory family and
  native delegation passes all three channels.
- The former Context family is removed by this release without a deferred
  compatibility review or replacement hook.

A higher-level framework may deliberately attach its own conveniences to its
own handler/controller object. The neutral PAGI Request does not require that
framework to adopt PAGI::Routing or expose middleware capabilities as Request
methods.

## Replace the removed Route `raw` mode with `as_app`

**Before (removed):** native Route ownership used either an implicit coderef
or the later `raw` declaration mode.

```perl
$r->get('/download' => $native_download_app);
$r->get('/download', raw => $native_download_app);
```

**After (shipped):** wrap native CODE explicitly for HTTP, WebSocket, or SSE.

```perl
use PAGI::Utils qw(as_app);

$r->get('/download' => as_app($native_download_app));
$r->websocket('/socket' => as_app($native_socket_app));
$r->sse('/events' => as_app($native_event_app));
```

Why: an explicit application value makes it visible that the target receives
`($scope, $receive, $send)` and emits its own protocol events.

Endpoint uses the same grammar, including after positional middleware. Use
`app_as` only when the native target is a local Endpoint method:

```perl
$r->get('/download' => [$self->middleware_as('audit')],
    as_app($self->app_as('download')));
```

The wrapped coderef is preserved rather than rebound. Ordinary Endpoint
method names receive `($self, $request_or_protocol)`, and ordinary handler
coderefs receive `($request_or_protocol)`.

## Generic `route` is path-first

**Before (removed):** the generic form put the HTTP method before the path.

```perl
$r->route('POST', '/jobs' => $job_app);
```

**After (shipped):** put the path first and supply the method set as an option.

```perl
use PAGI::Response;

$r->route('/jobs' => sub {
    my ($request) = @_;
    return PAGI::Response::json_response($jobs->create($request));
}, methods => ['POST']);
```

Why: the path-first form aligns generic HTTP declarations with `get`, `post`,
`websocket`, `sse`, and the immutable routing constructors.

## Names are slash-addressed

**Before (removed):** names and nested prefixes were joined with dots.

```perl
$r->get('/people/{id}' => $show_app)->name('people.show');
my $path = $r->uri_for('people.show', { id => 42 });
```

**After (shipped):** each declaration contributes one local name segment and
nested references use canonical slash addresses.

```perl
use PAGI::Response;

$r->mount('/people', routes => sub {
    my ($people) = @_;
    $people->get('/{id}' => sub { return PAGI::Response::text_response('person') })
        ->name('show');
})->name('people');

my $path = $r->path_for('/people/show', { id => 42 });
```

Why: slash addresses provide one unambiguous logical path for routes and
inspectable mounts.

## `name` replaces `as` and mount `namespace`

**Before (removed):** an inspectable child was mounted positionally and its
names were imported afterward with `as`.

```perl
$r->mount('/api' => $child_router)->as('api');
my $path = $r->uri_for('api.people.show', { id => 42 });
```

**Removed metadata vocabulary:** public mount `namespace` values and accessors
are not part of the new description model.

**After (shipped):** put the immutable child Router in `app` and give that
Mount its local name with the universal modifier.

```perl
$r->mount('/api', app => $child_router)->name('api');
my $path = $r->path_for('/api/people/show', { id => 42 });
```

Why: one `name` operation now assigns local logical segments to routes and
Mounts without a second import mechanism.

## Replace `group` with a real child Router Mount

**Before (removed):** a group callback received its parent builder, and its
declarations were flattened into the parent's protocol collections.

```perl
$r->group('/api' => sub {
    my ($same_router) = @_;
    $same_router->get('/people' => $people_app);
});
```

**After (shipped):** `routes` receives a fresh child builder retained as one
real Router application at the Mount's declaration position.

```perl
use PAGI::Response;

$r->mount('/api', routes => sub {
    my ($api) = @_;
    $api->get('/people' => sub { return PAGI::Response::json_response($people->all) })
        ->name('people');
})->name('api');
```

The callback return value is ignored. The child owns its own stock/custom 404
and built-in 405; this is no longer transparent inline dispatch.

## Load and construct packages explicitly

**Before (removed):** group and mount string targets could load packages and
construct routing behavior as a side effect.

```perl
$r->group('/users' => 'MyApp::Routes::Users');
$r->mount('/admin' => 'MyApp::Admin');
```

**After (shipped):** load dependencies normally, construct configured objects,
and pass the exact object at a routing-aware boundary.

```perl
use MyApp::Endpoint::Users;
use MyApp::Endpoint::Admin;

my $users = MyApp::Endpoint::Users->new(repository => $repository);
my $admin = MyApp::Endpoint::Admin->new(policy => $policy);

$r->mount('/users', app => $users->to_router)->name('users');
$r->mount('/admin', app => $admin->to_router)->name('admin');
```

Why: explicit loading and construction make configuration, object identity,
dependency failures, and recursive router graphs visible to the application.

## Declaration order now governs routes and mounts

**Before (removed):** the old App Router kept separate HTTP, WebSocket, SSE,
and mount collections, checked protocol routes before mounts, and sorted mounts
longest-prefix-first.

```perl
$r->mount('/api'    => $broad_app);
$r->mount('/api/v2' => $v2_app);  # tried first because its prefix is longer
```

**After (shipped):** all declarations retain their written positions, so the
first full match owns dispatch.

```perl
$r->mount('/api',    app => $broad_app);
$r->mount('/api/v2', app => $v2_app);  # unreachable below /api while broad is first

# Reverse these declarations when /api/v2 must win.
```

Why: one declaration order makes route-versus-mount ownership and overlapping
prefix behavior inspectable without kind-specific precedence rules.

## Middleware has four universal forms

**Before (removed):** App routing lists accepted a factory coderef or an object
with `wrap`, while other routing surfaces had different accepted forms.

```perl
$r->get('/admin' => [
    $logging_factory,
    $configured_auth_object,
] => $admin_app);
```

**After (shipped):** every Router, Mount, route, and protocol route accepts a
class name, factory coderef, configured wrapping object, or explicit
description.

```perl
use PAGI::Response;
use PAGI::Routing qw(middleware);

$r->get('/admin' => [
    'RequestId',
    $logging_factory,
    $configured_auth_object,
    middleware('Session', cookie_name => 'sid'),
] => sub { return PAGI::Response::text_response('admin') });
```

Why: one native app-to-app middleware contract can wrap HTTP, WebSocket, SSE,
Mount, Route, Router, and Compose boundaries consistently.

## Endpoint middleware is native PAGI middleware

**Before (removed):** an Endpoint route middleware name selected a
response-valued method receiving `($self, $c, $next)`.

```perl
$r->get('/admin' => ['authenticate'] => 'admin');

sub authenticate {
    my ($self, $c, $next) = @_;
    my $response = $next->()->get;
    return $response;
}
```

**After (shipped):** Endpoint lists use the same synchronous app factory or
wrapping-object forms as every other routing surface.

```perl
$r->get('/admin' => [$auth_factory] => 'admin');

sub build_auth_factory {
    my ($policy) = @_;
    return sub {
        my ($inner_app) = @_;
        return sub {
            my ($scope, $receive, $send) = @_;
            return $policy->allows($scope)
                ? $inner_app->($scope, $receive, $send)
                : deny($send);
        };
    };
}
```

Why: native middleware controls downstream calls and channel wrapping without a
second response-valued execution model.

## Use `middleware_as` for a local middleware method

**Before (removed):** a bare string in an Endpoint middleware list was treated
as a local value-flow middleware method name.

```perl
$r->get('/account' => ['authenticate'] => 'account');
```

**After (shipped):** adapt a local method explicitly into a native middleware
factory.

```perl
sub routes {
    my ($self, $r) = @_;
    $r->get('/account' => [
        $self->middleware_as('authenticate'),
    ] => 'account');
}

sub authenticate {
    my ($self, $inner_app) = @_;
    return sub {
        my ($scope, $receive, $send) = @_;
        $self->check_scope($scope);
        return $inner_app->($scope, $receive, $send);
    };
}
```

Why: the adapter keeps method binding explicit while preserving the universal
native middleware contract.

## Use lifespan state through `PAGI::State`

**Before (removed):** Endpoint created a private state hash and injected it
into requests.

```perl
$self->state->{database} = connect_database();
my $database = $self->state->{database};
```

**After (shipped):** let the server or `PAGI::Compose` own lifespan state and
read it through the strict Request State facade.

```perl
use PAGI::Compose qw(compose);
use PAGI::Response;
use PAGI::State qw(app_state);

my $app = compose(
    app => $endpoint->to_app,
    lifespan => {
        startup  => sub { $_[0]{database} = connect_database() },
        shutdown => sub { $_[0]{database}->disconnect },
    },
)->to_app;

sub list_people {
    my ($self, $request) = @_;
    return PAGI::Response::json_response(
        app_state($request)->get('database')->people,
    );
}
```

Why: server-owned lifespan state has an explicit startup and shutdown lifetime
and retains one identity across the requests that receive it.

## Removed Endpoint construction hooks

**Before (removed):** overriding `context_class` changed the class Endpoint
used to build Context objects for compiled handlers.

```perl
sub context_class { return 'MyApp::Context' }
```

**After (shipped):** compiled routes receive direct protocol objects.
`PAGI::Endpoint::Router->new_request($scope, $receive)` is an explicit HTTP-only
convenience for native middleware or application code that wants the Request
API; compiled dispatch does not call it. There is no `new_context` alias.

```perl
use PAGI::Response;

my $manual_request = $endpoint->new_request($scope, $receive);

$r->get('/normal' => sub {
    my ($request) = @_;  # PAGI::Request from the shared compiler
    return PAGI::Response::text_response('ok');
});
```

Why: removing the compiler override keeps protocol construction identical
across all frontends while leaving explicit HTTP Request construction locally
available where a native adapter needs it.

## Mount nested Endpoint objects through `app`

**Before (removed):** compiling a nested Endpoint to an app first made it an
opaque mount whose routes and names were hidden from its parent.

```perl
$r->mount('/people' => MyApp::People->to_app);
```

**After (shipped):** construct the child and mount its immutable Router
snapshot when the parent must discover names.

```perl
my $people = MyApp::People->new(repository => $repository);
$r->mount('/people', app => $people->to_router)->name('people');

my $show = $endpoint->to_router
    ->path_for('/people/show', { id => 42 });
```

Why: a routing-aware object mount retains child metadata, reverse names, shared
materialization, identity reuse, and cycle diagnostics.

## Route middleware works for HTTP, WebSocket, and SSE

**Before (removed):** Endpoint rejected route-level middleware for WebSocket
and SSE declarations.

```perl
$r->websocket('/chat' => ['authenticate'] => 'chat'); # rejected
$r->sse('/events' => ['authenticate'] => 'events');   # rejected
```

**After (shipped):** use the same native middleware entry on every protocol
route.

```perl
my $auth = $self->middleware_as('authenticate');

$r->get('/account'       => [$auth] => 'account');
$r->websocket('/chat'    => [$auth] => 'chat');
$r->sse('/events'        => [$auth] => 'events');
```

Why: middleware now wraps the native application boundary, which exists for
all three protocols.

## Read `pagi.routing`, not `pagi.router`

**Before (removed):** matched App routes published a small route hash at the
old scope key.

```perl
my $route_path = $scope->{'pagi.router'}{route};
```

**After (shipped):** the shared compiler publishes a versioned routing
container whose frame stack records the current routing owner and any
compatible ancestor owners.

```perl
my $container = $request->scope->{'pagi.routing'};
die 'unsupported routing metadata' unless $container->{version} == 1;
my $current_frame = $container->{frames}[-1];
```

Prefer `path_for($request, ...)` from `PAGI::Routing::URL` when the goal is
reverse routing rather than metadata inspection.

Why: the frame stack and its mount ancestry can describe nested immutable
routers, captures, logical placement, and the selected leaf without mutating
shared descriptions.

An inspectable Router Mount appends a distinct child boundary frame that keeps
the root Resolver and root entry `root_path`. An opaque Mount keeps its terminal
Mount match in the parent frame; if its native target is a separately compiled
Router, that Router appends its own frame/container boundary with its own
Resolver and entry `root_path` when the incoming metadata is compatible.

## Retain a `to_router` snapshot for stable inspection

**Before (removed):** named-route inspection and generation read the mutable
App Router's internal tables directly.

```perl
my $routes = $r->named_routes;
my $path = $r->uri_for('people.show', { id => 42 });
```

**After (shipped):** materialize once and use that immutable object for a
coherent inspection view.

```perl
my $routing = $r->to_router;
my $route = $routing->route_named('/people/show');
my $path = $routing->path_for('/people/show', { id => 42 });
my $app = $routing->to_app;
```

Why: each frontend `to_router` call creates a fresh snapshot, so retaining one
keeps route identity, inspection, reverse routing, and compilation aligned.

## Generated paths validate and encode parameters

**Before (removed):** route generation substituted path values without applying
the route's full constraints or percent-encoding path parameters.

```perl
$r->get('/tags/{name}' => $tag_app)->name('tag.show');
my $path = $r->uri_for('tag.show', { name => 'Perl tools' });
```

**After (shipped):** `path_for` validates the complete effective path and
percent-encodes path, query, and fragment values.

```perl
use PAGI::Response;

$r->get('/tags/{name}' => sub { return PAGI::Response::text_response('tag') })
    ->name('show')
    ->constraints(name => qr/\A[[:print:]]+\z/);

my $path = $r->path_for('/show',
    { name => 'Perl tools' },
    { from => 'upgrade guide' },
    'examples');
# /tags/Perl%20tools?from=upgrade%20guide#examples
```

Why: generated paths now obey the same parameter contract as dispatch and are
safe to place in URI path, query, and fragment components.

## Application Routes and opaque Mounts are different

**Before (removed):** ordinary route targets and mounts both accepted native
applications without making their different ownership rules explicit.

```perl
$r->get('/health' => $native_health_app);
$r->mount('/legacy' => $legacy_app);
```

**After (shipped):** use an exact, method-aware application Route for one leaf and an
opaque mount for a protocol-wide prefix boundary.

```perl
use PAGI::Utils qw(as_app);

$r->get('/health' => as_app($native_health_app));
$r->mount('/legacy', app => $legacy_app);
```

An application Route keeps `path` and `root_path` unchanged, participates in HTTP 405
selection, and publishes leaf metadata; an opaque mount strips its prefix,
extends `root_path`, owns every protocol at that prefix, and hides its internals.

Why: choosing between a leaf and a prefix boundary determines matching,
methods, path rewriting, metadata visibility, and downstream ownership.

## Mount accessors now describe one application

**Before (removed):** callers inspected dispatch mode through `router`,
`target`, or `is_raw`.

```perl
my $router = $mount->router;
my $target = $mount->target;
my $raw    = $mount->is_raw;
```

**After (shipped):** every Mount has one base application.

```perl
my $app = $mount->app;
my $middleware = $mount->middleware;
```

There is no mode flag. `routes` constructs a child Router and stores it as the
same `app` value used by explicit application Mounts.

## Application strings and middleware strings are different contracts

**Before (rejected):** an application position does not load, construct, or
call a package.

```perl
mount('/legacy', app => 'MyApp::Legacy');
```

**After (shipped):** instantiate the application explicitly.

```perl
use MyApp::Legacy;
mount('/legacy', app => MyApp::Legacy->new);
```

Middleware strings remain accepted because the middleware descriptor defines
loading, construction, configuration, and `wrap` behavior:

```perl
middleware('RequestId', header => 'X-Request-ID');
```

This distinction applies to Route application values, Mount `app`, Router `http_default`, and
Compose `app`; `PAGI::Test::Client`'s `app`; `PAGI::Lifespan`'s `app`/`wrap`
target; `PAGI::Middleware::Builder`'s final fallback and Mount targets; and
URLMap/Cascade application entries. A package-name application is rejected
synchronously rather than guessed.

Construct once and pass the same explicit object at these boundaries:

```perl
use MyApp::Legacy;
use PAGI::Lifespan;
use PAGI::Middleware::Builder;
use PAGI::Test::Client;

my $legacy = MyApp::Legacy->new;

my $client = PAGI::Test::Client->new(app => $legacy);
my $with_lifespan = PAGI::Lifespan->wrap($legacy,
    startup => sub { my ($state) = @_; $state->{ready} = 1 },
);
my $built = builder {
    mount '/legacy' => $legacy;
    $legacy;
};
```

## Removed routing fallback machinery

`PAGI::Routing::Trace`, its Recorder/Snapshot family, and
`PAGI::Middleware::Routing::NotFound` /
`PAGI::Middleware::Routing::MethodNotAllowed` are removed, not deprecated.
The `pagi.routing` scope convention now carries only selected route and reverse
lookup metadata. It is not a decline channel. Compose no longer creates a
Trace or installs automatic 404/405 middleware; the selected Router owns
those outcomes.

## Exact current Mount spellings

These accepted forms are deliberately explicit:

```perl
use PAGI::Response;

mount('/x', app => $app);

# Immutable functional constructor: structural nodes in an arrayref.
mount('/x', routes => [
    route('/' => sub { return PAGI::Response::text_response('child') }),
]);

# Mutable App/Endpoint builder: one declaration-time callback.
$r->mount('/x', routes => sub {
    my ($child) = @_;
    $child->get('/' => sub { return PAGI::Response::text_response('child') });
});
```

The functional form accepts an arrayref, never a callback. The callback form is
available only in the mutable App and Endpoint frontends. It runs once during
declaration, receives a fresh child builder bound to the same Endpoint object
when applicable, and ignores its return value. Both `/x` and `/x/` reach the
child `/` leaf without redirecting.

## Deliberate Starlette differences and deferred schema work

PAGI follows Starlette's Route/Mount/Router/application topology, not every
method on Starlette Request. `PAGI::Request` owns HTTP input; imports identify
the Router or middleware that supplies optional behavior. Ordinary handlers
receive direct Request, WebSocket, or SSE objects; `as_app`, Mount `app`, Router
`http_default`, and Compose `app` are native three-channel application
positions. Constraints validate without coercion. Logical names use slash
addresses and relative `PAGI::Routing::URL` lookup. SSE is first-class. Middleware is pure
PAGI app-to-app wrapping at Route, Mount, Router, and Compose boundaries.

Starlette's single multiprotocol Router `default` was considered and
deliberately not copied. PAGI's HTTP-only default preserves stock WebSocket
and SSE misses. Compose, not Router, owns root lifespan.
OpenAPI and schema support remain deferred until a concrete consumer is
designed; `schema`,
`include_in_schema`, registries, and placeholder metadata are not shipped.
