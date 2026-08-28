# HTTP Response Family and Streaming

**Date:** 2026-08-27

**Status:** Proposed design; user review required before implementation planning

**Scope:** Replace the all-purpose `PAGI::Response` body modes with a small,
extensible HTTP response family; make every response a complete terminal PAGI
application value; add concise factory exports; preserve explicit buffered and
streaming request-body APIs; define output-stream backpressure; reduce
`PAGI::Pages` to negotiated response policy; and reuse HTTP response values for
WebSocket denial and SSE decline without conflating HTTP streaming with live
protocol connections

## 1. Decision

PAGI-Tools will model an HTTP response as one value with one representation or
delivery strategy. The initial family is:

```text
PAGI::Response
PAGI::Response::Text
PAGI::Response::HTML
PAGI::Response::JSON
PAGI::Response::Problem
PAGI::Response::Redirect
PAGI::Response::Empty
PAGI::Response::File
PAGI::Response::Stream
```

`PAGI::Response::Writer` is a public support object created by Stream for one
active invocation. It is not a Response subclass, a handler return value, an
independently constructible response, or a `to_app` component.

The class API is canonical:

```perl
return PAGI::Response::JSON->new(
    { id => 1, name => 'Gala' },
    status => 200,
);
```

`PAGI::Response` also offers opt-in factory exports that construct those same
classes:

```perl
use PAGI::Response qw(json_response file_response stream_response);

return json_response({ id => 1, name => 'Gala' });
```

The factories do not introduce a second response model. They are concise Perl
spellings for constructors, return instances of the documented concrete
response classes, and have the same validation and behavior as direct
construction of those classes.

Every response implements `to_app`. A response may therefore be returned from
a normal Request handler or placed explicitly where PAGI expects an
application:

```perl
route('/health' => sub ($request) {
    return json_response({ ok => \1 });
});

mount('/manual',
    app => file_response('/srv/example/manual.pdf', inline => 1),
);
```

An ordinary Route target is also extended in one deterministic way: a coderef
continues to mean a Request handler, while an instantiated object with `to_app`
means a terminal application selected by that exact Route:

```perl
route('/' => file_response($manager_file, inline => 1));
```

A raw application coderef still requires the existing `raw` marker. The
implementation never inspects coderef signatures or arity.

Normal response transmission uses the full PAGI triplet:

```perl
await $response->respond($scope, $receive, $send);
```

`respond` and the app returned by `to_app` share exactly one emission path.
Response objects no longer store a scope, receive callback, send callback, or
connection state.

This is an intentional breaking redesign of unreleased PAGI-Tools APIs. Tests,
examples, documentation, and the user upgrade guide migrate together. No
compatibility aliases preserve the existing all-purpose body methods or the
Pages arity-overloaded endpoint convention.

## 2. Work map

| Repository | Work item | Branch | Base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | HTTP response family and streaming | `main` | `main@c5d0c301e2a59fb7451b3848e541b2fbfe1873de` | This design specification only | Documentation/design; no runtime change | None requested |

The eventual implementation is confined to PAGI-Tools unless it discovers a
protocol contradiction. The reviewed PAGI specification already supports the
required HTTP body, file, WebSocket-denial, and SSE-decline event shapes; this
design does not currently require a PAGI specification or PAGI::Server change.

Before implementation begins, its execution plan must record a fresh work map
with the then-current branch and base, production/test/document/example
ownership, deployment boundary, and push target.

The untracked alignment notes and `.superpowers/` evidence present beside this
design are unrelated user/session work and are not owned by this effort.

## 3. Governing and superseded designs

Where this design conflicts with earlier records, it supersedes:

- the Response vocabulary and compatibility decisions in the 2026-08-04
  Context/Response compatibility design;
- the single-class Response conclusions in the 2026-08-14 Pages response
  factory design;
- the retained Response/Pages seam recorded as `LATER-RESPONSE` and
  `LATER-PAGES` by the 2026-08-27 Request-first handler design; and
- the coderef-only ordinary Route target restriction in the 2026-08-26
  Starlette-aligned routing-composition design, but only for instantiated
  `to_app` objects.

The completed 2026-08-27 Context-removal design is a governing prerequisite,
not a superseded record. `PAGI::Context` and its subclasses remain removed.
This response work finishes the temporary seam that design deliberately left
behind by removing `PAGI::Request->response` and migrating the response
family. It must not recreate Context under another name.

These decisions remain in force:

- Request-first HTTP handlers and direct `PAGI::WebSocket`/`PAGI::SSE`
  handlers;
- explicit imports for router- and middleware-owned capabilities;
- Route as an exact, method-aware leaf;
- Mount as prefix ownership and application composition;
- Router as ordered child selection and owner of its NONE/PARTIAL outcomes;
- Compose as the deployed root, lifespan owner, response guard, error
  boundary, and final HEAD boundary;
- pure three-argument middleware;
- no exception-based HTTP control flow;
- route constraints validate without coercion;
- Pages owns stock response policy rather than application routing; and
- the compact routing declaration syntax remains recorded but unimplemented.

The response work must land after the implemented Request-first and
Starlette-aligned routing campaigns already present on this design's base. It
must not resurrect Context handlers, removed fallback middleware, `group`, or
pre-redesign Mount forms.

## 4. Why the current shape needs to change

### 4.1 One class contains competing body strategies

`PAGI::Response` currently combines:

- raw bytes;
- Unicode text and HTML encoding;
- JSON serialization;
- redirect construction;
- no-content responses;
- file descriptors;
- streaming callbacks;
- direct writer takeover;
- status, headers, cookies, and CORS helpers;
- scope storage and connection-derived `is_sent`; and
- native-application conversion.

Internally, `_body`, `_file`, and `_stream` compete for the same response. The
public class/instance factory duality lets the same object change from one
representation strategy into another. A value can begin as JSON, later become
a file response, and retain unrelated mutable state unless every path clears
every competing field correctly.

That makes extensions awkward. A specialized response such as a template,
CSV, archive, event stream, or future HTTP representation has no narrow seam;
it must participate in the entire all-purpose builder.

### 4.2 `PAGI::Pages` repeats response work and invocation work

Pages currently owns valuable policy—status copy, negotiation, safe details,
RFC 9457 fields, redirect rules, cache policy, and status-specific fields—but
also:

- UTF-8 encodes HTML and text itself;
- JSON-encodes ordinary and problem documents itself;
- creates a generic `PAGI::Response` and installs raw bytes;
- detects whether its first argument is a Request/scope source;
- returns an immediate Response in one shape;
- returns a one-argument handler in another shape; and
- arity-dispatches the same coderef as a native three-argument PAGI app.

This pulls representation, policy, handler adaptation, and application
adaptation into one module. It also erases the selected representation's class
identity: HTML, text, JSON, and problem JSON all emerge as the same generic
Response.

Pages should decide *what conventional response is appropriate*. The response
family should decide *how that representation is rendered and emitted*.

### 4.3 File and stream behavior deserve lifecycle classes

Buffered text and JSON are finite values. Files and streams are delivery
strategies with different request-time and failure behavior:

- a file may require stat metadata, range selection, ETag handling, and an
  efficient PAGI `file` event;
- a stream sends headers before its producer completes, observes send-Future
  backpressure, and cannot replace a partially sent response with a 500;
- a producer must be cleaned up on normal completion, failure, or disconnect;
  and
- request-body consumption must not race a second response-side consumer of
  `$receive`.

Keeping these as flags in a generic mutable object hides the lifecycle
difference. Dedicated classes make it explicit and independently testable.

### 4.4 WebSocket and SSE denial duplicate HTTP construction

`PAGI::WebSocket->deny` and `PAGI::SSE->decline` currently accept their own
`status`, `headers`, and `body` options. That duplicates a small, incomplete
HTTP response API and makes it difficult to reuse Pages, JSON/problem
rendering, cookies, and future response types.

Both PAGI protocols already define HTTP-response start/body event pairs. A
normal Response value should supply the denial document; the live protocol
object should own the state transition and event-prefix adaptation.

## 5. Starlette source lessons and deliberate divergences

This design follows Starlette's implementation rather than copying only its
surface names.

Starlette's base `Response` renders finite content, initializes headers, and
is itself an ASGI-callable application. `HTMLResponse` and
`PlainTextResponse` mostly select media type; `JSONResponse` overrides the
render seam. `StreamingResponse` and `FileResponse` override delivery and
lifecycle behavior. Routing separately adapts a `Request -> Response`
endpoint into an ASGI application. WebSocket denial accepts an ordinary
Response rather than another status/header/body mini-API.

Those boundaries transfer cleanly to PAGI:

- representation subclasses render finite values;
- delivery subclasses own streaming or file behavior;
- routing adapts Request handlers;
- Response remains independently usable as an application; and
- protocol denial consumes a Response value.

FastAPI demonstrates the appropriate higher-layer extension: application code
may return a Response directly, while a framework can separately declare a
response class and serialize ordinary return values into it. PAGI-Tools adopts
only the explicit Response-value layer. Automatic value serialization remains
a possible feature of a higher-level framework such as Thunderhorse, not the
core toolkit.

PAGI deliberately differs where the underlying protocol differs. In ASGI,
third-party SSE implementations commonly subclass `Response` because SSE is
modeled as an HTTP streaming response. PAGI has a first-class `sse` scope and
`sse.*` event family with start, event, comment, keepalive, close, connection
state, and decline operations. Therefore `PAGI::SSE` is not a subclass of
`PAGI::Response::Stream`. It remains a live protocol connection object.

Likewise, a future `PAGI::MCP` protocol object should not inherit HTTP status,
cookies, or body semantics merely because both can transmit data. An MCP-over-
HTTP representation may use or subclass Response; a distinct PAGI event type
should have its own protocol object.

## 6. Goals

The implementation must:

1. give each response value one clear representation or delivery strategy;
2. make the response family open to application and extension subclasses;
3. keep status, headers, cookies, and one emission contract on the base class;
4. make every response usable both as a returned handler value and a terminal
   PAGI application;
5. use the full `($scope, $receive, $send)` triplet for response emission;
6. make preconstructed buffered and file response applications safe for
   concurrent requests;
7. keep buffered input and output explicit rather than automatic;
8. make request and response streaming usable without dropping to raw PAGI;
9. preserve send-Future backpressure end to end without an unbounded queue;
10. keep file bodies out of Perl memory and preserve efficient server handoff;
11. let Pages return concrete HTML, text, JSON, problem, redirect, or empty
    responses;
12. remove Pages' arity-sniffing handler/native-app convention;
13. let WebSocket denial and SSE decline consume ordinary Response values;
14. provide concise, opt-in exports while keeping classes canonical;
15. keep Route and Mount ownership visibly different in code and docs;
16. migrate all first-party components, tests, examples, and documentation;
17. classify every current public Response-family capability as retained,
    deliberately replaced, or explicitly deferred before implementation; and
18. provide an upgrading guide for PAGI-Tools users and the Thunderhorse
    maintainer.

## 7. Non-goals and deferred ledger

This design does not:

- redesign Request parsing, State, Session, Stash, CSRF, URL, or Transport,
  except to remove the explicitly temporary `PAGI::Request->response` bridge;
- change the PAGI protocol's send-Future semantics;
- add a template engine, serializer registry, dependency injection system, or
  automatic content-negotiation registry;
- add FastAPI-style return-value serialization or declared response classes to
  Route;
- infer a response type from arbitrary returned Perl values;
- automatically buffer iterators, generators, filehandles, files, or streams;
- add JSON array streaming with hidden punctuation management;
- add JSON Lines, multipart/mixed, archive, compression, or templating
  subclasses in the first implementation;
- add background-task ownership to Response;
- make a Stream response consume `$receive` independently to detect
  disconnects;
- create a common superclass for Request, WebSocket, SSE, and future MCP
  protocol objects;
- make `PAGI::SSE` inherit from an HTTP StreamingResponse;
- make file responses legal WebSocket-denial or SSE-decline bodies;
- turn Pages back into middleware, Router, application container, or view
  framework;
- implement the deferred compact routing declaration syntax; or
- simplify the Apple example's lifespan state/data-store helper as part of
  this work.

The following remain explicit later possibilities:

| ID | Deferred work | Reason |
| --- | --- | --- |
| `LATER-TEMPLATES` | A template response subclass or view integration | Needs a concrete template engine and async rendering contract |
| `LATER-JSON-STREAM` | JSON Lines or structured incremental JSON | Standard JSON streaming needs a format-specific correctness design |
| `LATER-COMPRESSION` | Streaming compression response/middleware | Requires flush, Content-Length, range, and middleware-order analysis |
| `LATER-PROTOCOL-SHARING` | Extract shared writer/flow-control internals from HTTP, SSE, and WebSocket | Do this only after concrete duplicate algorithms remain |
| `LATER-MCP` | MCP application/protocol/response design | Must follow the transport chosen rather than inherit HTTP accidentally |
| `LATER-APPLE-DATA` | Replace the Apple demo's raw lifespan hash with a lexical fixture or repository object | Independent example/data-ownership decision |

## 8. Response hierarchy and responsibilities

### 8.1 Base `PAGI::Response`

The base class represents an already encoded finite byte body. It owns:

- status validation and default status 200;
- response headers and their ordered multi-value behavior;
- Content-Type and Content-Length policy;
- cookie construction and deletion;
- constructor option validation;
- repeatable response emission;
- `respond($scope, $receive, $send)`;
- `to_app`;
- the protected render/emission seams used by subclasses; and
- response metadata inspection.

Canonical construction is:

```perl
my $response = PAGI::Response->new(
    $bytes,
    status       => 200,
    content_type => 'application/octet-stream',
    headers      => [
        'X-Example' => 'value',
    ],
);
```

The base body must be an unblessed, defined byte scalar. It does not guess an
encoding. Unicode text belongs to Text or HTML; structured Perl data belongs
to JSON or Problem. Its default Content-Type is
`application/octet-stream`. Empty defaults to no Content-Type, Redirect to its
document representation, File infers from its selected filename/path, and
Stream defaults to `application/octet-stream` unless explicitly configured.
In Perl terms, a scalar carrying the internal UTF-8 character flag is rejected
by the byte APIs even when its current characters happen to be ASCII; callers
use Text/HTML or encode explicitly. The same rule applies to Writer `write`.

No body-bearing response may be constructed with a status whose HTTP semantics
forbid content, including 1xx, 204, 205, and 304. Empty is the explicit class
for those outcomes. The validation occurs before response start and does not
silently discard a supplied body.

The constructor no longer accepts or stores a scope. Remove `scope`,
`is_sent`, direct `writer($send)` takeover, `_self_or_new`, and the
class/instance finisher duality from Response. Remove the explicitly temporary
`PAGI::Request->response` factory as part of the same migration. Per-request
shared data belongs to the Request and scope helpers already designed in the
Request-first campaign.

`Response->scope` previously made Response participate in the shared
scope-source duck type used by Session, Stash, State, CSRF, URL, and Transport.
That is not compatible with reusable response values. One unchanged Response
may be emitted concurrently for several requests, so it has no single honest
scope to return; storing the construction scope would expose stale request
data, while changing it during emission would create a race. Normal handlers
pass their Request to scope helpers, protocol handlers pass WebSocket or SSE,
and raw applications pass the scope hashref directly. Response is deliberately
not a scope source.

Headers remain intentionally mutable before emission so middleware and raw
applications can add fields:

```perl
my $response = json_response($data);
$response->header('X-Request-ID' => $request_id);
await $response->respond($scope, $receive, $send);
```

Every emission takes an invocation-local snapshot. Emission never mutates the
response. Mutating a Response concurrently with its emission is unsupported;
serving an unchanged Response concurrently is supported.

The retained public metadata API is:

```text
status() / status($code)
has_status()
status_try($code)
headers()
header($name) / header($name, $value)
header_all($name)
has_header($name)
header_try($name, $value)
remove_header($name)
content_type() / content_type($value)
has_content_type()
content_type_try($value)
cookie($name, $value, %options)
delete_cookie($name, %options)
is_buffered()
body()
```

The `*_try` methods are non-overwriting chainers and return the Response:

- `status_try($code)` sets the status only when `has_status` is false. The
  implicit default returned by `status()` — normally 200 — does not count as
  explicitly set.
- `header_try($name, $value)` adds one header pair only when no value with that
  case-insensitive field name exists. If one or more values already exist, it
  does nothing; it never appends another value to a multi-value field.
- `content_type_try($value)` is equivalent to
  `header_try('Content-Type', $value)`.

When a value is applied, it receives the same validation as the corresponding
ordinary setter.

`header($name, $value)` appends, preserving repeated fields such as
Set-Cookie; callers use `headers->set` or `content_type` when replacement is
intended. `is_buffered` is true exactly when the complete body bytes are held
locally on the Response, including Empty and Redirect, and false for File and
Stream. `body` is a read-only encoded-byte accessor for buffered responses. It
croaks on File and Stream rather than returning a misleading partial value.
Body mutation happens only through construction of the appropriate response
class.

`to_app` captures a stable response snapshot when called. Later mutation of
the original Response does not mutate the compiled application. Calling
`to_app` again captures a fresh snapshot, consistent with the repository's
fresh-compilation model.

The current public `has_body_source` predicate is removed. It exists to ask
whether the mutable all-purpose builder has selected a body mode. In the new
model every constructed Response is already a complete representation or
delivery value; there is no useful incomplete state to inspect.

### 8.2 Representation subclasses

These classes buffer only their explicitly supplied finite value:

| Class | Input | Default Content-Type | Rendering |
| --- | --- | --- | --- |
| `PAGI::Response::Text` | Unicode scalar | `text/plain; charset=utf-8` | strict UTF-8 bytes |
| `PAGI::Response::HTML` | Unicode scalar | `text/html; charset=utf-8` | strict UTF-8 bytes |
| `PAGI::Response::JSON` | Perl value accepted by JSON::MaybeXS | `application/json` | UTF-8 JSON bytes |
| `PAGI::Response::Problem` | RFC 9457 hashref | `application/problem+json` | validated RFC 9457 UTF-8 JSON bytes |

`Problem` requires a hashref and accepts any valid subset of the RFC 9457
standard members plus extension members. The standard members are optional,
not collectively required. When absent, `type` has the RFC-defined effective
value `about:blank`. When present, `type` and `instance` must be URI-reference
strings, `title` and `detail` must be strings, and `status` must be an integer
HTTP status from 100 through 599. The document's `status` supplies the HTTP
status when no constructor `status` option is present. When both are present
they must be equal. Application extension members remain possible but cannot
replace or bypass validation of standard members. Validation does not
materialize omitted optional members in the serialized document: an absent
`type` remains absent on the wire while retaining the RFC-defined effective
value `about:blank`, and a constructor HTTP status does not inject a missing
document `status`.

The initial subclassing seam is deliberately small:

```perl
package MyApp::CSVResponse;
use parent 'PAGI::Response';

sub default_content_type { 'text/csv; charset=utf-8' }
sub render {
    my ($self, $rows) = @_;
    ...
    return $encoded_bytes;
}
```

`default_content_type` and `render` are the supported subclass hooks and must
retain these names. Delivery internals used only by first-party File and Stream
classes remain private and are not an application subclassing contract. Finite
representation subclasses transform one construction value into bytes; they
do not send events, read request bodies, or manage connection state.

JSON object member order is unspecified and is not part of the response
contract. The first-party encoder does not sort keys solely to stabilize
presentation. Applications requiring canonical bytes for signatures, hashes,
or byte-stable caches should provide a specialized Response subclass with that
explicit contract.

Text and HTML always encode Unicode input as strict UTF-8. The current
`Response->send($text, charset => $name)` custom-charset convenience is
retired deliberately. Arbitrary character encodings remain possible by
encoding explicitly and constructing the byte-oriented base Response:

```perl
return response(
    Encode::encode('iso-8859-1', $text),
    content_type => 'text/plain; charset=iso-8859-1',
);
```

This keeps the Text and HTML render contracts invariant while preserving the
underlying capability.

### 8.3 Semantic and delivery subclasses

`PAGI::Response::Redirect` owns a validated redirect status, a validated URI
reference, the `Location` field, and a small safe default body. It supports
301, 302, 303, 307, and 308. Pages may instead return HTML, Text, or JSON with a
Location field when negotiation requires that representation; semantic status
does not override representation identity.

`PAGI::Response::Empty` owns a bodyless response. It defaults to 204 and
rejects content/body combinations forbidden by the selected status.

`PAGI::Response::File` owns delivery of one already selected trusted file. It
does not interpret the request path as a filesystem path. It owns MIME
selection, filename/content-disposition, stat metadata, ETag, supported
conditional requests, one strict byte range, and efficient PAGI `file` event
handoff.

`PAGI::Response::Stream` owns response-start timing, a per-invocation producer,
sequential body chunks, cleanup, and abnormal termination.

`File` and `Stream` use the same status/header/cookie and `to_app` contracts as
the base class, but do not render their contents into a buffered body.

## 9. Constructor and export API

### 9.1 Canonical class constructors

```perl
PAGI::Response->new($bytes, %options)
PAGI::Response::Text->new($characters, %options)
PAGI::Response::HTML->new($characters, %options)
PAGI::Response::JSON->new($value, %options)
PAGI::Response::Problem->new($problem, %options)
PAGI::Response::Redirect->new($location, %options)
PAGI::Response::Empty->new(%options)
PAGI::Response::File->new($path, %options)
PAGI::Response::Stream->new($producer, %options)
```

Common options are:

```text
status
headers
content_type
```

Only classes for which an option is meaningful accept it. Unknown, duplicate,
or malformed option lists croak at construction. A subclass may add explicit
options without weakening base validation.

Initial class-specific options are deliberately narrow:

| Class | Additional options |
| --- | --- |
| Redirect | `status` (301/302/303/307/308), `content_type` override |
| Empty | `status` (defaults 204) |
| File | `filename`, `inline`, `offset`, `length`, `handle_ranges`, `etag` |
| Stream | no delivery-specific options beyond producer and common metadata |

For File, `handle_ranges` defaults true. `etag` accepts false to disable, true
or omission for an automatically generated tag, or a validated explicit
entity-tag string. `filename` produces an attachment Content-Disposition
unless `inline` is true; `inline` without a filename still emits an inline
disposition.

`offset` and `length` preserve the current fixed-slice capability, but they do
not manufacture HTTP Range semantics. They define the physical window backing
the Response's complete logical representation: offset defaults to zero and
length defaults to the remainder of the file. A normal request receives 200,
no Content-Range, and a Content-Length equal to the configured window. This is
useful when the application intentionally exposes one region of a larger file
without advertising that storage detail to the client.

When a client supplies a valid Range header and `handle_ranges` is enabled,
the request range applies within that logical window. For example, configured
`offset => 1024, length => 65536` plus client `Range: bytes=100-199` produces
`Content-Range: bytes 100-199/65536` and a physical file event with
`offset => 1124, length => 100`. Unsatisfiable ranges are measured against the
logical window. FileResponse owns calculated Content-Length and Content-Range:
supplying either through `headers`, or supplying status 206 without a valid
request range plan, croaks instead of being overwritten or duplicated.

Internal App::File reuse must call the same window/range-plan implementation
rather than grow a second slicing grammar. The documentation must name the
logical-versus-physical distinction and explain why a configured slice is not
automatically a 206 response.

An automatically generated ETag identifies the logical representation, not
only the underlying filesystem object. Its input therefore includes the file
metadata plus configured offset and length, so two windows of the same file do
not receive the same entity tag. Client ranges within one window retain that
window's ETag. A caller supplies an explicit tag through the `etag` option;
putting `ETag` directly in `headers` croaks rather than competing with
FileResponse ownership.

Headers use the repository's canonical even-length flat array form at the
public constructor boundary. The implementation normalizes once to
`PAGI::Headers`. It must not silently accept both flat pairs and nested pairs
on neighboring response classes.

### 9.2 Factory exports

`PAGI::Response` exports nothing by default and supports:

```perl
use PAGI::Response qw(
    response
    text_response
    html_response
    json_response
    problem_response
    redirect_response
    empty_response
    file_response
    stream_response
);
```

The mappings are exact:

| Export | Constructs |
| --- | --- |
| `response` | `PAGI::Response` |
| `text_response` | `PAGI::Response::Text` |
| `html_response` | `PAGI::Response::HTML` |
| `json_response` | `PAGI::Response::JSON` |
| `problem_response` | `PAGI::Response::Problem` |
| `redirect_response` | `PAGI::Response::Redirect` |
| `empty_response` | `PAGI::Response::Empty` |
| `file_response` | `PAGI::Response::File` |
| `stream_response` | `PAGI::Response::Stream` |

`:all` exports all nine. No short `json`, `text`, `file`, or `stream` names are
introduced; the `_response` suffix makes ownership readable and avoids common
application-subroutine collisions.

Each concrete subclass may export its one matching factory as an optional
convenience, but `PAGI::Response` is the documented facade and the only place
with an `:all` bundle.

Imported factories are ordinary functions with the fixed class mappings above.
They never inspect the caller or dynamically select an application subclass.
Application subclasses use their constructor — for example,
`MyApp::CSVResponse->new(...)` — or define their own explicit factory export.
Constructor dispatch preserves the subclass identity; first-party factory
functions do not.

## 10. Emission and application contract

### 10.1 `respond`

```perl
await $response->respond($scope, $receive, $send);
```

`respond` requires:

- an unblessed PAGI scope hashref whose explicit type is `http`;
- receive and send coderefs; and
- a Response instance.

It returns a Future. It sends exactly one response start and one terminal body
event, except that Stream may send multiple body events and File uses one
implicitly terminal `file` event. Every call to `$send` is awaited.

Construction and preflight validation failures occur before response start
where possible. A failed `$send` Future is propagated unchanged. Once response
start succeeds, rendering or delivery failures abort the response and fail the
Future; they do not attempt to send a replacement 500.

The old `respond($send)` spelling is removed. A response may need scope for
File ranges and conditions and may need connection metadata for streaming
cleanup. Making the full triplet canonical prevents another partial API from
growing around special cases.

### 10.2 `to_app`

```perl
my $app = $response->to_app;
await $app->($scope, $receive, $send);
```

`to_app` synchronously validates/captures a stable response configuration and
returns a native async PAGI application coderef. It emits no events during
compilation. The app invokes the same emission machinery as `respond`.

Response `to_app` is useful at application positions but is not a complete
deployed-root framework. Compose remains the documented root because it owns
lifespan, the final HEAD boundary, application exceptions, and incomplete
responses.

A Response application is HTTP-only, while Mount matches every protocol. If a
Response application receives a WebSocket, SSE, lifespan, or unknown scope, it
croaks before emitting an event. The diagnostic names the scope type and
recommends mounting a protocol-aware application or adding an explicit guard.

This is a defined application failure, not a defined wire response. PAGI
requires the server to close the connection promptly and permits
protocol-specific error handling, but does not guarantee a WebSocket 403 or an
SSE decline response. Applications requiring controlled WebSocket denial or
SSE decline must compose that policy explicitly. The Cookbook shows a small
guard application that delegates HTTP scopes to the Response and declines
WebSocket/SSE handshakes through the ordinary denial path. That policy lives in
the application, not in Response.

Like other PAGI components, a bare response application constructs the full
GET-equivalent response for HEAD. The enclosing Router/Compose HEAD boundary
suppresses wire body/file bytes *outside* application middleware so middleware
can calculate the same headers as GET. Response must not perform an inner HEAD
suppression that would cause Content-Length or compression middleware to see
an empty body.

### 10.3 Route and Mount ownership

The documentation for Route and Mount must show these examples together:

```perl
# Exact URL leaf. Only / reaches this response.
route('/' => file_response($index_file, inline => 1));

# Explicit Route catchall. This is a real route match.
route('/*path' => \&not_found, methods => ['GET']);

# Prefix composition. /manual and every /manual/... path belong to this app.
mount('/manual', app => file_response($manual_file, inline => 1));

# Root-prefix composition. If selected, the app owns the whole remaining tree.
mount('/', app => $spa_app);
```

An ordinary Route target accepts exactly:

1. a coderef Request handler; or
2. an instantiated object with `to_app`.

A raw application coderef still uses:

```perl
route('/metrics' => raw => $native_app);
```

No `app =>` marker is added to Route. Perl value shape already distinguishes an
instantiated component from a coderef, while it cannot distinguish two coderef
contracts. Package-name strings remain invalid application values.

Mount retains exactly one of `app` or `routes`. It always owns the complete
matched prefix subtree. A terminal mounted response ignores the rewritten
remaining child path, which is occasionally useful but must be stated plainly.
A developer who wants only one complete path normally wants Route, not Mount.

Once a Mount prefix is selected, child misses do not resume parent sibling
scanning. A parent wildcard does not catch a miss inside a selected `/apples`
child Router.

## 11. Buffered output is explicit

Only these operations buffer output:

- base Response copies one supplied byte scalar;
- Text and HTML encode one supplied Unicode scalar;
- JSON and Problem serialize one supplied finite Perl value; and
- Redirect may build one small finite default document.

Response construction never consumes an iterator, async iterator, source
object, filehandle, callback, or Request body stream to discover whether it is
finite. Such values require File or Stream explicitly.

JSON is buffered because ordinary JSON syntax represents one complete value.
Incremental JSON arrays require error-sensitive punctuation and completion
rules and are not smuggled into `json_response`. Applications that need an
incremental format should use Stream with a format such as JSON Lines, or a
future format-specific subclass.

Content-Length for buffered responses is calculated from encoded byte length,
not Perl character count. Any user-supplied Content-Length and
Transfer-Encoding are normalized according to the existing smuggling-safe
policy so only the authoritative byte length is emitted.

Stream never calculates Content-Length. An explicitly supplied stream
Content-Length is preserved and becomes the application's promise; a mismatch
is a delivery error that middleware/server diagnostics may report. File
calculates the selected full or ranged byte length from request-time metadata.

## 12. Streaming request input

The current Request distinction remains:

```perl
my $bytes = await $request->body;  # buffers the complete body
my $data  = await $request->json;  # buffers, then decodes one JSON value

my $input = $request->body_stream; # incremental pull interface
while (defined(my $chunk = await $input->next_chunk)) {
    ...
}
```

Buffered and streaming consumption are mutually exclusive. Starting one form
locks out the other with a direct diagnostic. `body_stream` retains size
limits, byte counts, decoding options, truncation reporting, `stream_to`, and
`stream_to_file`.

This response redesign must audit and tighten `BodyStream::stream_to` so it
awaits exactly immediate or Future-backed sinks under the repository's normal
Future contract. Duck typing through unrelated methods such as `get` must not
create an undocumented awaitable protocol.

The existing blocking nature of `stream_to_file` remains documented. This
work does not invent a cross-platform asynchronous filesystem API.

## 13. Streaming response output

### 13.1 Producer form

The primary API is a per-invocation producer callback:

```perl
return stream_response(
    async sub ($writer) {
        await $writer->write("id,name\n");
        await $writer->write("1,Gala\n");
    },
    content_type => 'text/csv; charset=utf-8',
);
```

The Response sends start before invoking the producer, matching Starlette's
StreamingResponse lifecycle. Normal producer completion automatically closes
the writer with one terminal empty body event. Explicit `close` is idempotent.

The producer callback is invoked independently for each response application
invocation. The Stream object stores configuration and callback, not a writer,
send callback, or active connection. A producer that closes over shared
mutable or one-shot state is responsible for that ordinary application-level
concurrency choice.

The first implementation accepts only the writer-callback form. It does not
also accept a naked iterator/source value. One construction grammar keeps
cleanup and per-request reuse explicit. Source objects are relayed through
`pipe_from` inside the producer.

### 13.2 Writer contract

`PAGI::Response::Writer` exposes:

```text
write($bytes)        -> Future
write_text($chars)   -> Future
pipe_from($source)   -> Future
close()              -> Future
is_closed()          -> Bool
is_disconnected()    -> Bool or undef
disconnect_reason()  -> String or undef
bytes_written()      -> nonnegative integer
on_close($callback)  -> self
buffered_amount()    -> nonnegative integer
high_water_mark()    -> nonnegative integer or undef
low_water_mark()     -> nonnegative integer or undef
is_writable()        -> Bool
on_high_water($cb)   -> self
on_drain($cb)        -> self
```

`write` accepts encoded bytes and sends one `http.response.body` event with
`more => 1`. `write_text` strictly UTF-8 encodes one character scalar before
delegating to `write`. Neither method buffers multiple chunks.

`bytes_written` counts bytes whose send Future settled as accepted for
delivery while the connection still reported connected. It does not claim
that the client received those bytes, does not count the terminal empty event,
and does not increment for a failed or detected post-disconnect write.

Writer permits exactly one outstanding write. Starting another write before
the prior write Future settles croaks rather than relying on PAGI's unspecified
overlapping-send behavior or building a hidden queue.

Every write waits for the PAGI `$send` Future. Resolution means that the
server accepted the event for delivery, not that the client received its
bytes. Under PAGI, that Future may remain pending while server buffers are
above a watermark. Therefore:

```perl
await $writer->write($chunk);
```

is the response-side backpressure mechanism. The writer must not hide the
Future, resolve before `$send`, or enqueue unbounded pending chunks. Calling
`write` without awaiting its Future is application misuse and must be called
out prominently in POD and examples.

The transport methods delegate to the invocation's `pagi.transport`, matching
WebSocket and SSE. They let push-style sources pause at the high watermark and
resume on drain rather than producing another chunk. When no transport handle
is available, `buffered_amount` returns zero, the watermarks return `undef`,
`is_writable` returns true, and the callback registrations are quiet chainable
no-ops. This does not weaken the primary rule: ordinary producers self-pace by
awaiting each write.

`pipe_from` accepts an object with `next_chunk` returning an immediate value or
a Future. It repeatedly:

1. awaits the next source chunk;
2. stops on `undef`;
3. skips or sends empty chunks according to the documented BodyStream rule;
4. awaits `write`; and only then
5. requests the next source chunk.

That order creates bounded pull-through flow control.

### 13.3 Streaming input to streaming output

A Request body can be relayed without raw PAGI:

```perl
async sub echo_upload($request) {
    my $input = $request->body_stream(max_bytes => 100 * 1024 * 1024);

    return stream_response(
        async sub ($output) {
            await $output->pipe_from($input);
            die 'upload was truncated' if $input->truncated;
        },
        content_type => 'application/octet-stream',
    );
}
```

This remains sequential: the next request chunk is not pulled until the prior
response chunk's send Future settles. It introduces no complete-body buffer
and no hidden queue.

The example is a flow-control demonstration, not a general recommendation to
echo request bodies before fully validating them. Applications own any
transactionality or security requirement that demands complete validation
before response start.

### 13.4 Disconnects and failures

Stream does not launch an independent `$receive` loop for disconnects. A
Request BodyStream may already own `$receive`, and competing consumers can
steal events from one another. It observes the invocation's
`pagi.connection` object instead. A conforming PAGI HTTP server provides that
object; isolated direct harnesses without it retain output behavior but
`is_disconnected` returns `undef` and proactive disconnect observation is not
available.

At Writer construction, Stream registers a synchronous `on_disconnect`
callback that records the reason, marks the writer disconnected, and resolves
an internal signal. The callback does not perform asynchronous cleanup itself.
The Stream runner races that signal against the producer Future without
consuming `$receive`:

- when disconnect wins, it requests cancellation of pending producer work,
  marks the writer aborted, emits no terminal success event, and awaits local
  cleanup exactly once; the Stream application then completes without a
  replacement response because the server already owns the abnormal
  disconnect outcome;
- `write` checks connection state before and after awaiting `$send`, because
  PAGI defines a post-disconnect send as a successful no-op rather than a
  disconnect error;
- a genuine failed send Future still fails the current write and producer;
- normal close sends the terminal event once;
- an exception after response start marks the writer aborted, runs local
  cleanup once, sends no false terminal success event, and is rethrown; and
- `on_close` cleanup callbacks may be immediate or Future-backed, are awaited,
  and cannot replace the primary delivery error. Callback failures are
  reported but do not prevent later cleanup callbacks from running.

If the producer fails after start, ErrorHandler cannot send a replacement 500.
The connection abort and original error report are the honest outcome.

An ordinary HTTP Stream never reconnects. A later request creates a fresh
Writer and producer invocation. `PAGI::SSE` continues to own EventSource
`Last-Event-ID`, retry, keepalive, and reconnection behavior; WebSocket
reconnection remains client/application policy. Stream does not duplicate or
inherit either live protocol lifecycle.

## 14. File response and static-file application

### 14.1 One selected file versus a path-resolving app

`PAGI::Response::File` sends one trusted, already selected path:

```perl
return file_response(
    '/srv/reports/monthly.pdf',
    filename => 'monthly.pdf',
);
```

`PAGI::App::File` maps untrusted request paths into a configured root, applies
hidden/traversal/index policy, and chooses missing/forbidden responses:

```perl
mount('/static',
    app => PAGI::App::File->from_app_path('static'),
);
```

The names distinguish their return values deliberately:

```perl
use PAGI::Utils qw(app_path);

my $path = app_path('public', 'index.html');          # absolute path string
my $app  = PAGI::App::File->from_app_path('static'); # rooted file app
```

The unreleased `PAGI::App::File->app_path` class constructor is renamed to
`from_app_path` and is not retained as an alias.

They are not interchangeable. `PAGI::App::File` should eventually use
FileResponse after it safely resolves a regular file. This centralizes MIME,
ETag, range, conditional, Content-Disposition, and PAGI file-event behavior
without moving request-path security into Response.

### 14.2 File lifecycle

File construction validates option shapes but does not read the complete file
or open a long-lived handle. Request-time preparation validates the selected
path sufficiently to choose status and headers before response start. Actual
delivery uses PAGI's `file` body event so the server can stream or use
zero-copy mechanisms and the send Future remains pending until server file use
is complete.

The established trusted-tree pathname race remains the PAGI file-event model:
the server opens the path after application inspection. This design does not
silently replace it with blocking application-owned handle I/O.

File supports GET-equivalent headers, HEAD through the enclosing boundary,
ETag/If-None-Match, configured logical windows through `offset`/`length`, and
the existing strict single-range behavior within the selected window. A
configured window by itself is a complete 200 representation, not an
advertised client range; Section 9.1 defines the header and physical-offset
arithmetic. Its implementation should be extracted from `PAGI::App::File`
rather than written independently and allowed to drift.

The first implementation preserves the existing ETag/If-None-Match
conditional feature set. Adding Last-Modified/If-Modified-Since or If-Range is
separate HTTP-cache work and must not be implied merely because Starlette
supports a broader file surface.

Missing or forbidden paths are not guessed by FileResponse as stock 404/403
policy after arbitrary application selection. Construction/preflight failures
croak before response start; `PAGI::App::File` continues owning negotiated
missing/forbidden outcomes for untrusted routed paths.

## 15. Pages after the split

### 15.1 Pages owns policy, not transport adaptation

Pages retains:

- the welcome descriptor;
- the IANA-derived status catalog;
- default safe title/detail copy;
- HTML/text/JSON selection from Accept;
- RFC 9457 problem members;
- redirect target/query policy;
- cache defaults;
- mandatory fields such as Allow and WWW-Authenticate;
- exact-status favicon generation;
- subclassable presentation hooks; and
- synchronous, bounded descriptor/render policy.

Pages stops:

- encoding all representations into raw bytes itself;
- creating a generic Response and calling `send_raw`;
- returning a different value based on whether a source was supplied;
- producing an arity-sniffing endpoint coderef; and
- directly owning native PAGI transmission.

Every page method requires an explicit request metadata source and returns one
unsent concrete Response. Accepted sources are `PAGI::Request`,
`PAGI::WebSocket`, `PAGI::SSE`, or an unblessed `http`, `websocket`, or `sse`
scope. WebSocket and SSE sources are accepted because their pre-start
handshakes can produce an HTTP denial/decline response; Pages still returns an
HTTP Response and never emits a live protocol event:

```perl
my $response = PAGI::Pages->not_found($request);
my $response = PAGI::Pages->not_found($scope, as => 'text');
my $response = PAGI::Pages->unauthorized($websocket, as => 'json');
```

Selected results include:

| Negotiated result | Response class |
| --- | --- |
| HTML page | `PAGI::Response::HTML` |
| text page | `PAGI::Response::Text` |
| ordinary JSON page | `PAGI::Response::JSON` |
| RFC 9457 error | `PAGI::Response::Problem` |
| bodyless status | `PAGI::Response::Empty` |
| simple conventional redirect | `PAGI::Response::Redirect` or representation response with Location, according to negotiation |

Pages may call the response render seam; it does not call `$send`.

### 15.2 Pages exports

Pages exports nothing by default. It offers function forms whose names make
their result explicit:

```perl
use PAGI::Pages qw(
    welcome_page
    status_page
    redirect_page
    not_found_page
    unauthorized_page
    internal_server_error_page
);
```

Each function requires the same explicit source as its class method and
delegates exactly:

```perl
not_found_page($request, detail => 'Missing')
PAGI::Pages->not_found($request, detail => 'Missing')
```

`:common` exports welcome, status, redirect, not-found, unauthorized,
forbidden, method-not-allowed, conflict, too-many-requests,
internal-server-error, bad-gateway, and service-unavailable page functions.
`:all` exports every named status-page function plus the generic functions.
No functions are exported by default.

These functions can be normal handlers without an adapter convention:

```perl
route('/welcome' => \&welcome_page);
```

They accept one Request in that position and return a Response. They are not
native PAGI apps and do not arity-switch when called with three arguments.
Raw code constructs a response from `$scope`, then emits it explicitly.

Consequently, a Pages method/function is no longer placed directly in a native
application option such as Mount, Compose `app`, or Router `http_default`.
First-party Router defaults call Pages with the active scope and emit the
returned Response internally. An application-owned native default uses the
named adapter `request_app`, exported by `PAGI::Routing`:

```perl
use PAGI::Routing qw(router route mount request_app);

my $routing = router(
    routes       => \@routes,
    http_default => request_app(\&root_not_found),
);
```

`request_app($handler)` converts one coderef Request handler into a native
PAGI application. It is the same adaptation the Route compiler performs for
normal HTTP handlers, exported under a name: construct `PAGI::Request` from
the scope and receive, invoke the handler, await the immediate or
Future-backed Response, and emit it with the full triplet. It croaks unless
given a coderef, and the produced application croaks if the handler does not
return a Response. It composes at any native application position:

```perl
mount('/missing', app => request_app(\&not_found_page));
```

This is not arity magic and not a second handler convention: the conversion
is explicit, named, and value-shape deterministic, exactly like `to_app`.
Pages itself gains no application adapter; the adapter belongs to Routing,
which owns the handler contract.

### 15.3 Subclassing

Configured Pages instances and presentation subclasses remain supported:

```perl
my $pages = MyApp::Pages->new(as => 'auto', default => 'html');

sub missing($request) {
    return $pages->not_found(
        $request,
        detail => 'That record is not available.',
    );
}
```

Pages hooks return representation values—Unicode HTML/text or Perl structures
for JSON/problem—and the concrete response class performs encoding. Hooks may
not return Futures; asynchronous lookup belongs in the handler before calling
Pages.

## 16. WebSocket denial and SSE decline

### 16.1 Response-valued API

Replace the duplicate option mini-APIs with:

```perl
await $websocket->deny(
    problem_response(
        {
            type   => 'about:blank',
            title  => 'Unauthorized',
            status => 401,
            detail => 'A bearer token is required.',
        },
        status  => 401,
        headers => ['WWW-Authenticate' => 'Bearer'],
    ),
);

await $sse->decline(
    PAGI::Pages->not_found($sse),
);
```

`deny` and `decline` require a `PAGI::Response` instance. They validate that the
response can be represented using byte body events before sending anything.
Buffered, Empty, Redirect, and Stream responses are eligible. File responses
are rejected before response start because the PAGI denial protocols permit
`body` chunks but not `file` or `fh` events.

The live protocol object creates this request-local emission scope:

```perl
my $http_scope = {
    %{$protocol->scope},
    type   => 'http',
    method => 'GET',
};
```

This is a shallow top-level clone: all existing handshake metadata — including
headers, path, query string, scheme, authority, client/server information,
extensions, state, and `pagi.connection` — is preserved, while `type` and
`method` are replaced. Nested values retain their existing references. The
original WebSocket or SSE scope is never mutated.

`GET` is a synthetic Response-emission method, not a claim about the original
WebSocket handshake method; an HTTP/2 WebSocket may have originated as extended
`CONNECT`. It ensures denial and decline Responses use ordinary body-producing
semantics rather than HEAD semantics. The protocol object then invokes the
Response through an internal send adapter that maps:

```text
http.response.start  -> websocket.http.response.start | sse.http.response.start
http.response.body   -> websocket.http.response.body  | sse.http.response.body
```

Only those event types are accepted. A response attempting trailers, file,
fh, or another HTTP event fails before an invalid protocol event is emitted.

### 16.2 Protocol state remains authoritative

WebSocket owns whether the denial extension is available and whether accept
has occurred. Without the extension, `deny($response)` ignores the custom
wire representation, sends the documented policy close fallback, and marks
the connection closed.

SSE decline is core and sends the adapted response. It remains valid only
before `sse.start`. Pending keepalive state is discarded and no live stream
event follows the terminal decline.

Both methods await every adapted send Future, preserve multi-chunk `more`
flags, mark the protocol object closed exactly once, and propagate failures.

### 16.3 Why SSE does not subclass Stream

`PAGI::Response::Stream` represents one ordinary HTTP response body.
`PAGI::SSE` represents a selected live protocol scope with event formatting,
Last-Event-ID, keepalive, reconnect semantics, connection callbacks, and a
decline-before-start state transition.

They share the need to respect send-Future backpressure, but inheritance would
also share the wrong HTTP status/body lifecycle. The implementation may reuse
small internal functions if genuine duplication remains; it must not create a
public common superclass merely to share `await $send`.

## 17. Before and after: focused response examples

### 17.1 Buffered JSON

Before:

```perl
return PAGI::Response->json(
    { error => 'Apple not found' },
    status => 404,
);
```

After, class form:

```perl
return PAGI::Response::JSON->new(
    { error => 'Apple not found' },
    status => 404,
);
```

After, factory form:

```perl
return json_response(
    { error => 'Apple not found' },
    status => 404,
);
```

### 17.2 File route

Before:

```perl
sub apple_manager($request) {
    return PAGI::Response->send_file($manager_file, inline => 1);
}

route('/' => \&apple_manager);
```

After:

```perl
route('/' => file_response($manager_file, inline => 1));
```

### 17.3 Raw emission

Before:

```perl
async sub app($scope, $receive, $send) {
    my $response = PAGI::Response->new($scope)
        ->status(201)
        ->header('X-Request-ID' => $scope->{request_id})
        ->json($data);

    await $response->respond($send);
}
```

After:

```perl
async sub app($scope, $receive, $send) {
    my $response = json_response(
        $data,
        status  => 201,
        headers => ['X-Request-ID' => $scope->{request_id}],
    );

    await $response->respond($scope, $receive, $send);
}
```

The full triplet supplies invocation-local method, headers, connection state,
and transport flow-control capabilities without storing them on the Response.
Response does not consume `$receive`; taking the complete native application
contract keeps `respond` and `to_app` on one emission path. Ordinary Route and
Endpoint handlers continue to return the Response and do not call `respond`
themselves.

### 17.4 Output streaming

Before:

```perl
return PAGI::Response->new
    ->content_type('text/csv')
    ->stream(async sub ($writer) {
        await $writer->write($header);
        await $writer->write($_) for @rows;
    });
```

After:

```perl
return stream_response(
    async sub ($writer) {
        await $writer->write($header);
        for my $row (@rows) {
            await $writer->write($row);
        }
    },
    content_type => 'text/csv',
);
```

The explicit loop in both examples matters: each write is awaited before the
next row is produced.

### 17.5 WebSocket denial

Before:

```perl
async sub on_connect($websocket) {
    return await $websocket->accept if valid_token($websocket);

    my $body = JSON::MaybeXS::encode_json({
        type   => 'https://example.test/problems/authentication',
        title  => 'Authentication required',
        status => 401,
        detail => 'Supply a bearer token.',
    });

    await $websocket->deny(
        status  => 401,
        headers => [
            'content-type'     => 'application/problem+json',
            'content-length'   => length($body),
            'www-authenticate' => 'Bearer',
            'cache-control'    => 'no-store',
        ],
        body => $body,
    );
}
```

After:

```perl
async sub on_connect($websocket) {
    return await $websocket->accept if valid_token($websocket);

    await $websocket->deny(
        problem_response(
            {
                type   => 'https://example.test/problems/authentication',
                title  => 'Authentication required',
                status => 401,
                detail => 'Supply a bearer token.',
            },
            headers => [
                'WWW-Authenticate' => 'Bearer',
                'Cache-Control'    => 'no-store',
            ],
        ),
    );
}
```

ProblemResponse validates and encodes the document and calculates the byte
length. WebSocket remains responsible for pre-accept state, extension support,
event-prefix adaptation, and the existing policy-close fallback.

### 17.6 Response is no longer a scope source

Before:

```perl
async sub create_apple($request) {
    my $response = $request->response;
    my $session  = PAGI::Session->new($response);
    my $stash    = PAGI::Stash->new($response);

    $stash->set(created_by => $session->get('user_id'));
    return $response->status(201)->json($apple);
}
```

After:

```perl
async sub create_apple($request) {
    my $session = PAGI::Session->new($request);
    my $stash   = PAGI::Stash->new($request);

    $stash->set(created_by => $session->get('user_id'));
    return json_response($apple, status => 201);
}
```

A raw application passes `$scope` to those helpers. A reusable Response cannot
truthfully carry one request scope.

### 17.7 SSE decline

Before:

```perl
await $sse->decline(
    status  => 404,
    headers => ['Content-Type' => 'text/plain; charset=utf-8'],
    body    => 'Apple not found',
);
```

After, explicit representation:

```perl
await $sse->decline(
    text_response('Apple not found', status => 404),
);
```

After, negotiated Pages policy:

```perl
await $sse->decline(
    not_found_page(
        $sse,
        detail => 'That apple does not exist.',
    ),
);
```

SSE adapts the Response events, discards pending keepalive state, closes
exactly once, and never starts the live event stream.

## 18. Before: current Apple response shape

The current example contains this response-facing structure:

```perl
use PAGI::Pages;
use PAGI::Response;

my $manager_file = app_path('public', 'index.html');

sub apple_manager($request) {
    return PAGI::Response->send_file($manager_file, inline => 1);
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

compose(
    routes => [
        route('/' => \&apple_manager,
            name => 'home', desc => 'Apple manager SPA'),
        route('/welcome' => PAGI::Pages->welcome,
            name => 'welcome', desc => 'PAGI welcome page'),
        mount('/apples',
            routes => [
                route('/' => \&list_apples,
                    methods => ['GET'], name => 'list'),
                route('/{apple_id:&Int}' => \&read_apple,
                    methods => ['GET'], name => 'read'),
            ],
            name => 'apples'),
    ],
    lifespan => { startup => \&startup },
);
```

The full example also has create, update, and delete handlers. They repeat the
same generic JSON factory pattern. Pages' no-source call returns an endpoint
coderef whose meaning changes by invocation arity.

## 19. After: complete Apple application shape

This is the intended full shape after this response work. It deliberately
retains the existing lifespan-backed `apples_db` helper so the response change
can be evaluated independently. Whether that helper should become a lexical
demo fixture or a repository object is `LATER-APPLE-DATA`.

```perl
#!/usr/bin/env perl
use v5.40;

use Future::AsyncAwait;
use List::Util qw(max);
use Types::Standard qw(Int);

use PAGI::Compose qw(compose);
use PAGI::Pages qw(welcome_page not_found_page);
use PAGI::Response qw(file_response json_response);
use PAGI::Routing qw(route mount router request_app);
use PAGI::Routing::URL qw(url_for path_for);
use PAGI::Utils qw(app_path);

my $manager_file = app_path('public', 'index.html');

sub startup($state, $scope) {
    $state->{apples_db} = {
        1 => { id => 1, name => 'Gala',       color => 'Red/Yellow' },
        2 => { id => 2, name => 'Honeycrisp', color => 'Rosy Red' },
    };
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
                url => url_for(
                    $request,
                    'apples/read',
                    { apple_id => $_ },
                ),
            }
        } sort { $a <=> $b } keys %$db
    ]);
}

async sub read_apple($request) {
    my $id = $request->path_param('apple_id');
    my $apple = apples_db($request)->{$id};

    return json_response($apple) if $apple;
    return json_response(
        { error => 'Apple not found' },
        status => 404,
    );
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
            Location => path_for(
                $request,
                'apples/read',
                { apple_id => $id },
            ),
        ],
    );
}

async sub update_apple($request) {
    my $db = apples_db($request);
    my $id = $request->path_param('apple_id');

    return json_response(
        { error => 'Apple not found' },
        status => 404,
    ) unless exists $db->{$id};

    my $data = await $request->json;
    $db->{$id} = { %{$db->{$id}}, %$data };
    return json_response($db->{$id});
}

async sub delete_apple($request) {
    my $db = apples_db($request);
    my $id = $request->path_param('apple_id');

    return json_response(
        { error => 'Apple not found' },
        status => 404,
    ) unless exists $db->{$id};

    return json_response({
        success => \1,
        deleted => delete $db->{$id},
    });
}

sub root_not_found($request) {
    return not_found_page(
        $request,
        detail => 'That page does not exist in the Apple demo.',
    );
}

compose(
    app => router(
        routes => [
            # Exact root only. The response is an instantiated to_app
            # component.
            route('/' => file_response($manager_file, inline => 1),
                name => 'home',
                desc => 'Apple manager SPA',
            ),

            # A normal one-argument function, not an arity-switching
            # endpoint.
            route('/welcome' => \&welcome_page,
                name => 'welcome',
                desc => 'PAGI welcome page',
            ),

            # Mount owns the complete /apples subtree after its prefix
            # matches.
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

        # Router NONE outcome: a custom 404 through the named adapter.
        http_default => request_app(\&root_not_found),
    ),
    lifespan => { startup => \&startup },
);
```

The custom root 404 is the Router's `http_default`, not a wildcard Route. A
catchall Route would be a FULL/PARTIAL candidate: method-limited it turns
unknown-path non-GET requests into spurious 405s, and unrestricted it
swallows the 405s of known root paths. `http_default` fires only on NONE, so
`DELETE /junk` is a 404 and `PUT /welcome` is a 405 with the correct `Allow`
union. The `/apples` Mount owns its subtree, so child 404 and 405 outcomes
remain child Router outcomes rather than falling through to
`root_not_found`. A wildcard Route remains available for an author who truly
wants a route that owns a path family.

The example README must retain the original Python Starlette application and
update the comparison table:

| Starlette | PAGI::Tools after this design |
| --- | --- |
| `JSONResponse(value)` | `json_response($value)` / `PAGI::Response::JSON->new($value)` |
| `FileResponse(path)` | `file_response($path)` / `PAGI::Response::File->new($path)` |
| response is ASGI-callable | response implements `to_app` |
| `Route('/', endpoint)` | exact `route('/' => handler-or-component)` |
| `Mount('/x', app=...)` | subtree-owning `mount('/x', app => ...)` |
| `StreamingResponse(iterator)` | `stream_response(async sub ($writer) { ... })` |

## 20. Error handling and validation

### 20.1 Construction errors

Invalid status, headers, media type, body shape, JSON value, problem document,
redirect target, path, stream callback, or options croak synchronously at
construction where the error is knowable.

No constructor performs protocol I/O. File existence/metadata that may vary by
request is validated during preflight before response start where possible.
`PAGI::App::File` continues converting path-resolution misses and forbidden
paths into its Pages-backed 404/403 policy. A direct FileResponse is given a
trusted selected path; disappearance or access failure before start propagates
as an application/resource error rather than pretending to be path routing.

### 20.2 Handler return validation

The Router HTTP adapter accepts an immediate `PAGI::Response` instance or a
Future resolving to one. A response subclass is naturally accepted through
`isa`. Other objects and plain values fail with a direct diagnostic before
send.

The Route constructor separately recognizes instantiated `to_app` objects as
application targets. This does not mean a handler may return any arbitrary
`to_app` component; normal handler completion still requires a Response.

### 20.3 Wire failures

Every send Future is awaited. Validation/resource failures from `$send` are
propagated. After the response has started, the implementation must never send
a second response start or disguise truncation as successful completion.

A client disconnect is not inferred from a send failure: PAGI defines sends
after disconnect as no-ops. Stream observes `pagi.connection` as specified in
Section 13.4. Other response classes complete their finite emission normally;
the server-owned connection object remains authoritative for the actual
delivery outcome.

ErrorHandler may render a safe 500 only when no response has started. The
existing outer response guard remains the owner of silent incomplete apps.

### 20.4 Invalid protocol use

- Response rejects non-HTTP scopes.
- Pages rejects lifespan, unknown extension, and other sources that cannot
  represent an HTTP request or pre-start HTTP handshake.
- WebSocket denial rejects post-accept calls.
- SSE decline rejects post-start calls.
- File response is rejected as denial/decline content before start.
- Stream writes after close fail.
- A second terminal event is a no-op only where explicitly documented as
  idempotent local close; it is not sent again.

## 21. Middleware and HEAD

Response instances construct the corresponding GET representation for HEAD.
They do not suppress their own body when nested. Router/Compose's outermost
HeadBoundary remains authoritative so response and router middleware observe
the full representation and can calculate identical GET/HEAD headers.

This order is required:

```text
HeadBoundary
  ErrorHandler / response guard where applicable
    router and author middleware
      selected Response application
```

Tests must cover middleware that computes a body-derived header and assert
that GET and HEAD headers agree while HEAD emits no body, file, or trailer
bytes.

Response classes do not absorb CORS, compression, authentication, caching
policy, or general body transformation merely because the current generic
Response has convenience methods. Cookies and literal response fields belong
on Response. Cross-request policy remains middleware.

The existing `Response->cors(...)` helper is removed without an alias. It
combines request-origin validation, credentials rules, preflight behavior,
cache variation, and response fields, so it is policy rather than response
representation. Application-wide CORS uses `PAGI::Middleware::CORS`. A caller
that truly needs one literal `Access-Control-*` field can use the ordinary
validated `header` API. The implementation must migrate every documented use
and test the middleware replacement; it must not silently discard the
capability.

## 22. Rejected alternatives

### 22.1 Keep one fluent Response with more methods

Rejected. It retains competing body modes and makes every future representation
modify the central class. The current implementation already demonstrates the
state-clearing and lifecycle burden.

### 22.2 Make helpers return generic Response values

Rejected. `json_response` returning generic Response would shorten spelling
without creating the extension seam. Concrete class identity is part of the
design.

### 22.3 Put every class directly under `PAGI::*Response`

Rejected for the first-party package layout. `PAGI::JSONResponse` and
`PAGI::FileResponse` resemble Starlette names but scatter one family across the
top-level namespace. `PAGI::Response::JSON` and `PAGI::Response::File` make
inheritance, discovery, and ownership explicit. Factory exports provide the
short everyday spelling.

### 22.4 Infer response type from returned values

Rejected. Automatically turning hashrefs into JSON or scalars into text is a
higher-level framework policy and makes mistakes silently valid. PAGI-Tools
handlers return explicit response values.

### 22.5 Make SSE inherit StreamingResponse

Rejected. That mirrors ASGI's HTTP-only SSE representation but conflicts with
PAGI's first-class `sse` scope and state machine.

### 22.6 Keep `deny(%opts)` and `decline(%opts)` beside response-valued forms

Rejected. Two ways to construct the same HTTP denial preserve duplication and
force future features to update both paths. Callers construct a Response.

### 22.7 Add `to_handler`

Rejected. Normal functions already return Responses, and Response already has
an application contract through `to_app`. Another adapter convention would
recreate the Pages dual-role problem.

`request_app` is not this rejected adapter: it converts in the opposite
direction (Request handler to native app), it is the Route compiler's own
adaptation under an explicit name, and nothing about it is arity- or
shape-sniffed at call time.

### 22.8 Require `route('/' => app => $response)`

Rejected. A blessed `to_app` component is distinguishable from a coderef, so
an additional marker adds ceremony without resolving ambiguity. Coderef apps
remain explicitly `raw`.

### 22.9 Automatically buffer stream sources

Rejected. It hides memory use, destroys progressive delivery, and defeats
backpressure. Buffered and streaming classes remain explicit.

### 22.10 Start a response-side receive loop for disconnects

Rejected. Request-body streaming may already consume `$receive`. Competing
consumers create lost-event races. `pagi.connection` provides the
non-destructive disconnect signal; send failures continue to report
validation, resource, and transport errors but are not used to infer client
disconnect.

## 23. Implementation scope and migration surfaces

The implementation plan must inventory at least:

- `lib/PAGI/Response.pm` and the new response subclass modules;
- `lib/PAGI/Request.pm`, removing only its temporary `response` bridge;
- `lib/PAGI/Pages.pm` and its catalog/render tests;
- `lib/PAGI/Request/BodyStream.pm`;
- `lib/PAGI/WebSocket.pm` and `lib/PAGI/SSE.pm`;
- `lib/PAGI/Routing/Route.pm`, Router/compiler HTTP response adaptation, and
  direct node compilation;
- `lib/PAGI/Endpoint/HTTP.pm` and every Endpoint frontend that constructs or
  emits an HTTP response;
- `lib/PAGI/App/File.pm`, Directory, and Static integration;
- first-party middleware and apps constructing responses, including
  `PAGI::Middleware::CORS` documentation;
- ErrorHandler, its full-triplet emission seam, and routing stock responses;
- all Response, Pages, streaming, WebSocket-denial, SSE-decline, routing,
  Compose, file-serving, and upgrade tests;
- all examples, especially `examples/starlette-apples`,
  `examples/15-large-application`, Pages examples, streaming examples, and
  Endpoint Router demos;
- `PAGI::Tools`, Tutorial, Cookbook, module POD, README, UPGRADING, and
  Changes; and
- Thunderhorse-facing migration examples.

Historical design documents remain historical and are not rewritten. Live
documentation and executable examples must not retain obsolete factory,
`respond($send)`, Pages endpoint, or denial `%opts` spellings.

Before production edits, the implementation must make a machine-assisted
inventory of the current public Response, Pages, File, WebSocket, SSE,
Endpoint, Routing, ErrorHandler, and middleware surfaces. Each item must be
classified as retained, deliberately replaced by this design, or explicitly
deferred. An unclassified disappearance is a release blocker; omission from a
new class sketch is not authorization to remove functionality.

The plan should separate this into reviewable phases rather than one large
Response commit:

1. base response family and exports;
2. buffered subclasses and Router return adaptation;
3. Stream/Writer and BodyStream relay;
4. File response and App::File reuse;
5. Pages policy migration and exports;
6. WebSocket/SSE denial integration;
7. first-party consumers and examples;
8. docs/upgrading; and
9. exhaustive audit, full suite, and distribution build.

This ordering is advisory until the implementation plan verifies dependencies.

## 24. Required tests

### 24.1 Base and buffered classes

- exact class identity for every class and export;
- no default exports and complete `:all`;
- byte versus Unicode validation;
- strict UTF-8 encoding and byte Content-Length;
- explicit base-byte Response preserves caller-selected non-UTF-8 encodings
  while Text/HTML reject a variable charset option;
- JSON round-trip semantics, UTF-8 bytes, unspecified object-member order, and
  JSON failure diagnostics;
- RFC 9457 optional-member, effective `about:blank`, URI-reference, extension,
  and HTTP-status agreement validation;
- header ordering, duplicates, cookies, and Content-Length/TE safety;
- immediate and Future-backed send completion;
- repeated and concurrent emission of one unchanged response;
- `to_app` snapshot independence from later mutation;
- full-triplet validation and non-HTTP rejection;
- class subclass render hooks without event ownership;
- Request and protocol objects remain valid scope sources while Response does
  not;
- Response has no CORS policy helper while `PAGI::Middleware::CORS` preserves
  ordinary, credentialed, and preflight behavior; and
- every inventoried public capability is retained, deliberately replaced, or
  explicitly deferred.

### 24.2 Routing and composition

- Response objects accepted as exact Route targets;
- coderefs remain handlers unless marked raw;
- arbitrary `to_app` handler return values remain invalid;
- package strings remain invalid;
- Route `/` does not match `/child`;
- Route `/*path` is an explicit catchall;
- `request_app` converts a Request handler to a native app, rejects
  non-coderefs, and its app croaks on a non-Response handler return;
- `request_app` results work at `http_default`, Mount `app`, and Compose
  `app` positions;
- a WebSocket or SSE scope reaching a Response application croaks with the
  documented diagnostic;
- Mount `/` and `/prefix` own their complete selected subtrees;
- mounted terminal responses ignore remaining child paths as documented;
- parent scan does not resume after selected Mount child 404/405;
- middleware order and concurrent reuse; and
- GET/HEAD body-derived header parity with zero HEAD body/file bytes.

### 24.3 Streaming

- Writer is created only by Stream and is neither a Response subclass nor a
  handler return/application value;
- headers sent before producer invocation;
- each write Future remains pending until its send Future settles;
- a second overlapping write fails without enqueueing;
- no next source pull before prior write settlement;
- no hidden buffering/unbounded queue;
- transport buffered amount, watermark, writable, high-water, and drain
  delegation plus absent-capability fallbacks;
- automatic terminal event on normal producer completion;
- explicit close idempotence;
- write-after-close failure;
- producer failure after start aborts without a terminal success event;
- failed send preserves the primary error and runs cleanup once;
- immediate and Future-backed on-close callbacks;
- connection disconnect before producer start, during unrelated producer work,
  during a pending write, and after normal completion;
- post-disconnect send no-op is detected through connection state rather than
  misclassified as a successful delivered chunk;
- disconnect reason and tri-state capability reporting;
- producer cancellation and exactly-once asynchronous cleanup on disconnect;
- `pipe_from` with immediate/Future chunks, empty chunks, EOF, failure, and
  truncated BodyStream;
- request buffered/streaming mutual exclusion; and
- no competing response-side receive consumption;
- every invocation receives a fresh Writer and producer; and
- ordinary Stream performs no SSE or WebSocket reconnection behavior.

### 24.4 Files

- `PAGI::Utils::app_path` returns a path string while
  `PAGI::App::File->from_app_path` returns a rooted application, and the old
  class-method spelling is absent;
- no body buffering;
- MIME, disposition, ETag, conditional, and strict range behavior;
- full-file and configured-window delivery, including 200 without
  Content-Range and correct physical offsets;
- client ranges within full files and configured windows, including 304, 206,
  and 416;
- automatic ETags distinguish logical windows while client ranges retain the
  selected window tag, and explicit ETags use the dedicated option;
- rejection of caller-supplied Content-Length/Content-Range and unplanned 206;
- HEAD through boundary;
- send Future failure propagation;
- App::File traversal/hidden/index policy remains authoritative;
- FileResponse never interprets a URL path as a filesystem path;
- App::File delegates selected file delivery without duplicated range logic;
  and
- File response rejected before WebSocket/SSE denial start.

### 24.5 Pages

- every negotiation result has the correct concrete response class;
- class and export forms agree;
- no-source method calls fail rather than returning endpoint coderefs;
- exported page functions work as ordinary one-Request handlers;
- three-argument invocation is rejected;
- HTML/text/JSON/problem/redirect/empty behavior preserved;
- mandatory status fields, hostile text, cache policy, favicons, and redirect
  safety preserved;
- configured subclasses remain request-independent and concurrent;
- HTTP, WebSocket, and SSE metadata sources select representations without
  changing protocol state; and
- unknown/lifespan metadata sources are rejected.

### 24.6 WebSocket and SSE

- buffered, streaming, redirect, problem, and empty response adaptation;
- the emission-scope clone replaces only `type` and `method`, preserves all
  other top-level metadata and nested identities, and never mutates the
  original protocol scope;
- exact event-prefix mapping and multi-body `more` preservation;
- no File/fh events;
- extension-absent WebSocket fallback;
- post-accept/post-start rejection;
- SSE pending keepalive cleanup;
- protocol state closed exactly once;
- send failure propagation; and
- existing live WebSocket/SSE send backpressure remains unchanged.

### 24.7 Examples and upgrade

- Apple app behavior and README source synchronization;
- exact `/` file Route versus subtree Mount behavior;
- `/welcome`, CRUD, custom root `http_default` (404 for unknown paths, 405
  preserved for known paths), child 404, and child 405;
- all example applications compile and their focused integrations pass;
- executable before/after upgrade examples for every removed spelling,
  including Response scope-source and CORS migrations; and
- live-source searches find no obsolete Response finisher, Pages endpoint,
  `respond($send)`, or denial `%opts` use outside explicit historical tests.

### 24.8 Final verification

After independent review of each correction:

- run the focused changed-test gate;
- run the repository full suite once under the project Perl;
- handle socket sandbox restrictions using the repository's established
  evidence discipline rather than rerunning indiscriminately;
- run one distribution build;
- inspect archive contents, metadata, prerequisites, and exclusions;
- restore any build-generated tracked side effects;
- run `git diff --check`; and
- verify the worktree contains no unexpected tracked changes.

## 25. Documentation requirements

The primary Response POD must begin with the class model and both class/export
spellings. It must explain buffered versus streaming memory behavior before
showing convenience examples.

The Route and Mount PODs must place their ownership comparison side by side:

```text
Route('/x')       exact complete path leaf
Route('/*path')   explicit real catchall leaf
Mount('/x')       selected owner of /x and its complete subtree
```

The streaming POD must prominently state that `await $writer->write(...)` is
the primary backpressure boundary, forbid overlapping writes, and show
request-to-response `pipe_from` without raw PAGI. It must separately document
transport watermark controls, connection-based disconnect detection,
exactly-once asynchronous cleanup, and the fact that ordinary HTTP Stream has
no reconnection semantics.

Pages POD must say it returns concrete Responses and is neither an app nor an
arity-overloaded endpoint. It must show `\&welcome_page`, an explicit class
call in a handler, and raw construction followed by full-triplet `respond`.

WebSocket and SSE POD must show response-valued denial/decline, extension
fallback, state restrictions, and the File exclusion.

FileResponse and App::File POD must cross-link and explain selected file versus
untrusted request-path resolution.

UPGRADING must include at least:

| Before | After |
| --- | --- |
| `$request->response` | construct the desired concrete Response directly |
| `PAGI::Response->new($scope)` as a mutable builder/scope source | construct a complete response; pass Request/protocol/scope to Session, Stash, State, CSRF, URL, or Transport helpers |
| `PAGI::Response->text($s)` | `text_response($s)` or `PAGI::Response::Text->new($s)` |
| `PAGI::Response->html($s)` | `html_response($s)` |
| `PAGI::Response->json($v)` | `json_response($v)` |
| `PAGI::Response->send($s, charset => $name)` | explicitly encode and pass bytes plus Content-Type to `response(...)` |
| `PAGI::Response->send_raw($b)` | `response($b)` |
| `PAGI::Response->redirect($uri)` | `redirect_response($uri)` |
| `PAGI::Response->empty(...)` | `empty_response(...)` |
| `PAGI::Response->send_file($p)` | `file_response($p)` |
| `PAGI::Response->stream($cb)` | `stream_response($cb)` |
| `$response->writer($send)` | `stream_response(async sub ($writer) { ... })` |
| `$response->respond($send)` | `$response->respond($scope, $receive, $send)` |
| `$response->scope` | use the active Request/protocol object, or raw `$scope` |
| `$response->is_sent` | use `$request->connection->response_started` or raw `pagi.connection` |
| `$response->has_body_source` | no replacement: every constructed Response is already complete |
| `$response->cors(...)` | `PAGI::Middleware::CORS`, or ordinary `header` for a literal field |
| Canonically sorted keys from `PAGI::Response->json(...)` | JSON object member order is unspecified; use a specialized Response subclass when canonical bytes are required |
| `PAGI::App::File->app_path('static')` | `PAGI::App::File->from_app_path('static')`; the utility function `app_path(...)` continues to return a path string |
| `route('/x' => PAGI::Pages->not_found)` | `route('/x' => \&not_found_page)` or an explicit handler |
| `http_default => PAGI::Pages->not_found` | `http_default => request_app(\&not_found_page)` |
| `$ws->deny(status => ..., body => ...)` | `$ws->deny($response)` |
| `$sse->decline(status => ..., body => ...)` | `$sse->decline($response)` |

The guide must explicitly note that Response no longer stores scope, that
`ref($response)` now identifies a concrete subclass, that fixed FileResponse
offset/length defines a logical representation rather than an automatic 206,
and that package-name strings are still not application values.

## 26. Success criteria

The redesign succeeds when:

- a new user can identify a response's representation/delivery behavior from
  its class or factory name;
- the common Apple handlers are as concise as their Starlette equivalents
  without inferring return types;
- the Apple root file needs no boilerplate Request handler;
- exact Route selection and Mount subtree ownership remain obvious;
- Pages contains policy and presentation hooks but no arity-based application
  adapter;
- large request and response bodies can flow incrementally through documented
  objects without raw PAGI;
- response writes naturally apply PAGI send-Future backpressure, expose
  transport watermarks, and stop/clean up on connection-reported disconnect;
- File delivery remains server-efficient;
- WebSocket and SSE denials reuse the same response construction vocabulary;
- first-party and application subclasses have a narrow supported seam;
- every preexisting public capability is retained, deliberately replaced with
  a documented equivalent, or explicitly approved as removed; and
- no new all-purpose context, response registry, handler adapter, or protocol
  inheritance hierarchy is introduced.

The result should feel recognizably inspired by Starlette's source-level
separation while remaining honest about PAGI's protocol model and Perl's
strengths: explicit package ownership, deterministic value-shape dispatch,
opt-in exports, and small composable objects.

## 27. Source references for a fresh implementation session

The implementation session should re-check current upstream source rather than
assuming these links are frozen APIs:

- Starlette Response family and emission source:
  <https://github.com/Kludex/starlette/blob/main/starlette/responses.py>
- Starlette Request-handler-to-ASGI adaptation:
  <https://github.com/Kludex/starlette/blob/main/starlette/routing.py>
- Starlette WebSocket denial response documentation:
  <https://www.starlette.io/websockets/#send-denial-response>
- Starlette response documentation:
  <https://www.starlette.io/responses/>
- `sse-starlette` EventSourceResponse, as evidence for ASGI's HTTP-streaming
  SSE model rather than a PAGI inheritance requirement:
  <https://github.com/sysid/sse-starlette>
- FastAPI custom response classes, as evidence for higher-layer automatic
  serialization remaining outside the core response value:
  <https://fastapi.tiangolo.com/advanced/custom-response/>
- RFC 9457 problem-details members and extension rules:
  <https://www.rfc-editor.org/rfc/rfc9457.html#section-3>

The authoritative local PAGI event contracts are:

- `../PAGI/lib/PAGI/Spec/Www.pod`, HTTP response body/file events;
- the same document's WebSocket Denial Response extension; and
- the same document's SSE decline events.

The implementation must follow the locally checked-out PAGI specification if
an upstream framework example conflicts with PAGI's event model.
