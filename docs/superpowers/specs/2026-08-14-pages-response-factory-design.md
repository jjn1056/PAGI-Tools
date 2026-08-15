# PAGI Pages Response Factory Design

**Date:** 2026-08-14

**Status:** Draft for user review; self-reviewed against the source tree

**Source audit base:** `main` at `457037baf075b573a3468f5c03eda2f56355ee3a`

**Scope:** Add a negotiated, subclassable response factory for a short PAGI
welcome page and conventional HTTP error and redirect pages; correct the shared
Accept matching it uses and Context's malformed-versus-extension scope
classification; make Pages the source of generic first-party HTTP error and
redirect responses; remove the superseded `PAGI::App::NotFound` and
`PAGI::App::Redirect` applications

## 1. Decision

Add `PAGI::Pages`, a small response factory for conventional HTTP pages. It is
not a view system, a Router, middleware, or a second response implementation.
Every immediate Pages call returns an ordinary `PAGI::Response`:

```perl
my $response = PAGI::Pages->welcome($context);
my $response = PAGI::Pages->not_found($context);
my $response = PAGI::Pages->not_found($scope);
```

The caller that owns the native PAGI wire lifecycle still sends that response:

```perl
await PAGI::Pages->not_found($scope)->respond($send);
```

If no request Context or scope is supplied, the same method returns a plain
coderef that supports both existing PAGI invocation conventions:

```perl
my $endpoint = PAGI::Pages->not_found;

my $response = $endpoint->($context);               # Context handler
await $endpoint->($scope, $receive, $send);          # native PAGI app
```

Consequently the endpoint can be used without Router-specific adapters or a
new conversion protocol:

```perl
route('/' => PAGI::Pages->welcome);
route('/old' => PAGI::Pages->redirect('/new', status => 308));
mount('/gone' => PAGI::Pages->gone);
compose(app => PAGI::Pages->service_unavailable)->to_app;
```

Pages negotiates self-contained HTML, ordinary JSON for welcome and redirect
pages, RFC 9457 problem JSON for errors, or UTF-8 plain text. Stock HTML embeds
a quiet exact-status SVG favicon, so an ordinary browser does not make a second
favicon request. Pages owns the registered status catalog, safe default copy,
encoding, escaping, representation headers, cache defaults, redirect
construction, and status-specific HTTP validation. Subclasses own only
presentation hooks.

The first-party routing fallbacks, ErrorHandler, and other first-party
components that synthesize generic body-bearing HTTP errors or redirects use
`PAGI::Pages` for their built-in responses. The component still decides
*whether* a response is required and supplies its protocol facts; Pages owns
the conventional representation. Explicit application responses,
component-specific documents, and existing custom handler/body seams remain
authoritative.

`PAGI::Compose` continues installing routing and error middleware as
unconfigurable outer failsafes. Applications customize their official policy
by installing ordinary inner middleware whose handler may itself be a Pages
endpoint. No ambient Pages object, global renderer, or component-by-component
`pages` option is introduced.

Remove these superseded modules outright:

```text
PAGI::App::NotFound
PAGI::App::Redirect
```

There are no compatibility wrappers for them. Documentation, tests, and
examples migrate to Pages, ordinary handlers, or direct `PAGI::Response` use.

## 2. Motivation and Boundary

The repository currently repeats the same low-value response work in routing
fallbacks, ErrorHandler, small applications, examples, and user code:

- select a status and reason phrase;
- choose HTML, JSON, or text;
- escape and UTF-8 encode dynamic text;
- emit safe cache headers;
- construct RFC-required fields such as `Allow`;
- avoid leaking exception details and decoder diagnostics such as module
  filesystem paths and line numbers; and
- construct a correct redirect body and `Location` field.

Error handling also has a fragile secondary-failure path: an exception's
unguarded `status_code` accessor can throw or return an invalid status,
replacing the original exception before any safe response begins. Pages
integration gives ErrorHandler a guarded status-selection path whose own
failures still collapse to the final safe 500 response.

`PAGI::Response` deliberately remains literal and low-level:

```perl
PAGI::Response->text(
    'A valid access token is required.',
    status  => 401,
    headers => [
        ['WWW-Authenticate', 'Bearer realm="api"'],
        ['Cache-Control', 'no-store'],
    ],
);
```

Pages is the conventional layer above it:

```perl
PAGI::Pages->unauthorized(
    $scope,
    challenge => 'Bearer realm="api"',
    detail    => 'A valid access token is required.',
);
```

Both values are `PAGI::Response` objects. Pages merely centralizes the policy
and boilerplate that would otherwise be spread through the distribution and
small applications.

The dependency direction is one-way. `PAGI::Pages` may use `PAGI::Request`,
`PAGI::Request::Negotiate`, `PAGI::Response`, `PAGI::Headers`, and small
utility modules, but it does not load Router, Compose, Endpoint, App, or
Middleware packages. Those higher-level components depend inward on Pages.
This prevents the broad default-response adoption from creating load cycles.

This is intentionally a limited-use component. It is especially useful for:

- proofs of concept and demonstrations;
- safe framework failsafes;
- small sites that do not need a view layer;
- consistent API problem responses;
- reusable application-specific page subclasses; and
- terminal endpoints inside Router, Mount, Compose, or raw PAGI code.

It is not intended to replace application templates, internationalization
systems, or domain-specific error models.

## 3. Goals

- Return ordinary, independently mutable `PAGI::Response` values.
- Make one-off class calls as concise as `PAGI::Response->text(...)`.
- Provide a concise `welcome` endpoint for demonstrations and new projects.
- Support configured instances and presentation subclasses.
- Support Context handlers, native PAGI apps, Router targets, Mount targets,
  Compose targets, and direct raw response construction without a Pages-only
  adapter protocol.
- Negotiate HTML, RFC 9457 problem JSON for errors, ordinary JSON for welcome
  and redirects, and plain text from the current request.
- Provide a comprehensive current IANA 4xx/5xx convenience catalog.
- Keep unknown/private error statuses possible but explicit.
- Make named helpers enforce mandatory HTTP response fields.
- Provide polished, neutral, self-contained HTML suitable for demos and
  framework defaults without pretending to be an application brand.
- Embed a generic, subdued exact-status SVG favicon in stock HTML without
  causing another HTTP request or requiring binary assets.
- Keep synchronous construction bounded, in-memory, and small; asynchronous
  work remains in the surrounding handler and response transmission.
- Replace repeated first-party default-page implementations.
- Give generic first-party HTTP failures and redirects one encoding,
  negotiation, caching, and header-validation policy without changing which
  component owns the triggering decision.
- Make subclass rendering unable to corrupt wire status, encoding, or
  mandatory headers accidentally.
- Document complete, runnable examples for every supported composition form.

## 4. Non-goals

This work will not:

- add `not_found`, `redirect`, or other page methods to `PAGI::Context`;
- add Pages configuration options to `PAGI::Compose`;
- add a `to_handler` protocol or another general application coercion layer;
- add a view/template engine, layout language, or asset pipeline;
- add a general-purpose success-page builder beyond the fixed welcome page;
- infer a Home, Back, or Referer-based navigation target;
- infer RFC 9457 `instance` from the request URI;
- negotiate `Accept-Language` or ship a translation catalog;
- render WebSocket, SSE, or lifespan outcomes;
- add a public status-catalog introspection API in v1;
- add a global Context protocol registry, automatic protocol-module loading,
  or a general Context-factory injection mechanism;
- add runtime IANA lookups or update the catalog over the network;
- use `AUTOLOAD` for named status methods;
- turn every status code into a body-bearing page;
- replace explicit application responses with Pages output;
- replace protocol documents whose body is the component's public data model,
  such as health-check JSON, with a generic page; or
- make a mounted Pages endpoint participate in child route matching.

## 5. Construction and Invocation

### 5.1 Class and instance style

Every public page method supports class and instance invocation:

```perl
PAGI::Pages->not_found($context);

my $pages = MyApp::Pages->new(
    as      => 'auto',
    default => 'html',
);
$pages->not_found($context);
```

A class call uses a fresh default instance of the invoked class. It does not
use or populate a hidden singleton. This preserves subclass dispatch and
avoids shared request state.

The constructor accepts only:

```text
as       auto | html | json | text     default: auto
default  html | json | text            default: html
```

`default` is used only when `as` is `auto`. Unknown options, references, empty
values, and unsupported representation names croak at construction.

Pages instances are immutable request-independent policy values. Every
request produces a fresh response and fresh descriptor; compiled endpoints
may be invoked concurrently without shared request mutation.

### 5.2 Immediate response form

A first argument that is a `PAGI::Context::HTTP` or an HTTP scope hashref is a
request source. The method immediately returns a new `PAGI::Response` bound to
that scope:

```perl
my $response = PAGI::Pages->not_found($context);
my $response = PAGI::Pages->not_found($scope);
```

Supplying a scope does not send events. This distinction is part of the main
API contract and must be shown in the primary documentation:

```perl
my $response = PAGI::Pages->not_found($scope);
$response->headers->set('X-Request-ID' => $request_id);
await $response->respond($send);
```

A Context handler normally returns the response because its Router adapter
owns the send step:

```perl
async sub missing ($context) {
    return PAGI::Pages->not_found($context);
}
```

The request source must represent an HTTP scope whose `type` is explicitly
`http`, or a `PAGI::Context::HTTP` backed by such a scope. The PAGI specification
requires a scope type and requires applications to reject scope types they do
not support. Missing, WebSocket, SSE, lifespan, and unsupported scope types and
non-HTTP Context subclasses therefore croak before response construction with
a diagnostic naming the missing or received type.

### 5.3 Deferred endpoint form

When no request source is supplied, the method validates and captures its
page options and returns a plain unblessed coderef. The coderef is both a
Context handler and a native PAGI application:

```perl
my $endpoint = PAGI::Pages->not_found(
    detail => 'That page does not exist.',
);
```

When its first argument is a compatible HTTP Context, it returns a Response.
It tolerates trailing callback metadata so it can be supplied directly to
first-party fallback and error middleware:

```perl
my $response = $endpoint->($context);
my $response = $endpoint->($context, $routing_snapshot);
my $response = $endpoint->($context, $original_exception);
```

Trailing callback metadata is ignored by Pages. Applications that need it to
choose copy or extensions use an explicit wrapper callback.

When called with one compatible HTTP scope, the endpoint returns an unsent
Response. When called with the native PAGI triplet, it constructs and sends
the Response and returns the Future from `respond`:

```perl
my $response = $endpoint->($scope);
await $endpoint->($scope, $receive, $send);
```

The raw triplet requires coderef receive/send channels and an HTTP scope.
Other invocation shapes croak clearly. There is no `to_app` method because the
endpoint already is a native PAGI coderef.

### 5.4 Route, Mount, and Compose

The deferred coderef requires no changes to the current target conventions:

```perl
route('/old' => PAGI::Pages->redirect('/new', status => 308));

mount('/gone' => PAGI::Pages->gone);

my $app = compose(
    app => PAGI::Pages->service_unavailable(retry_after => 300),
)->to_app;
```

Documentation must distinguish exact routes from opaque mounts immediately
beside these examples:

```text
route('/old' => ...)
    exact path; normal route method matching and diagnostics

mount('/old' => ...)
    owns /old and the complete /old/... subtree; every HTTP method reaches
    the terminal Pages application
```

`PAGI::App::File` consumes the remaining mounted path to select a file. A
mounted Pages endpoint ignores the remaining path and unconditionally renders
its configured terminal response. The two values are both mountable apps but
are not interchangeable route-selection mechanisms.

## 6. Public API

### 6.1 Welcome method

`welcome` supplies a deliberately small demonstration and starter page:

```perl
route('/' => PAGI::Pages->welcome);

my $response = PAGI::Pages->welcome($context);
```

It always returns status 200 and uses this fixed stock content:

```text
Welcome to PAGI

PAGI is a spiritual successor to PSGI for asynchronous Perl applications. It
connects servers, frameworks, and applications across HTTP, WebSocket, and
Server-Sent Events.

Read the PAGI documentation →
https://metacpan.org/pod/PAGI
```

The HTML representation renders the final line as a link whose label is
`Read the PAGI documentation →`. The text representation includes the label
and URL. The JSON representation is an ordinary `application/json` document:

```json
{
  "title": "Welcome to PAGI",
  "detail": "PAGI is a spiritual successor to PSGI for asynchronous Perl applications. It connects servers, frameworks, and applications across HTTP, WebSocket, and Server-Sent Events.",
  "documentation": "https://metacpan.org/pod/PAGI"
}
```

The fixed documentation target is part of the base class's stock welcome-page
contract. Applications wanting different success-page content use their own
handler or subclass presentation; v1 does not grow a generic success-page API.

### 6.2 General error method

`status` is the general 4xx/5xx constructor:

```perl
$pages->status($context, 404, %options);  # Response
$pages->status($scope,   404, %options);  # Response
$pages->status(          404, %options);  # deferred endpoint
```

For a current registered catalog status, Pages supplies its standard title,
safe default detail, and `about:blank` problem type.

For an unknown, unassigned, unused, obsoleted, or private 400-599 status, the
caller must supply all of:

```text
type
title
detail
```

The type must be an absolute URI other than `about:blank`. This prevents Pages
from inventing semantics or misusing RFC 9457's generic status type:

```perl
PAGI::Pages->status(
    $context,
    599,
    type   => 'https://example.com/problems/upstream-timeout',
    title  => 'Upstream Connection Timeout',
    detail => 'The reporting gateway could not connect upstream.',
);
```

Codes outside 400-599 croak. Redirects use the separate redirect API.

### 6.3 Named error methods

Each current meaningful IANA 4xx/5xx status has an ordinary explicit method.
There is no `AUTOLOAD`, dynamic fallback, or typo recovery.

| Code | Method | Registered title |
|---:|---|---|
| 400 | `bad_request` | Bad Request |
| 401 | `unauthorized` | Unauthorized |
| 402 | `payment_required` | Payment Required |
| 403 | `forbidden` | Forbidden |
| 404 | `not_found` | Not Found |
| 405 | `method_not_allowed` | Method Not Allowed |
| 406 | `not_acceptable` | Not Acceptable |
| 407 | `proxy_authentication_required` | Proxy Authentication Required |
| 408 | `request_timeout` | Request Timeout |
| 409 | `conflict` | Conflict |
| 410 | `gone` | Gone |
| 411 | `length_required` | Length Required |
| 412 | `precondition_failed` | Precondition Failed |
| 413 | `content_too_large` | Content Too Large |
| 414 | `uri_too_long` | URI Too Long |
| 415 | `unsupported_media_type` | Unsupported Media Type |
| 416 | `range_not_satisfiable` | Range Not Satisfiable |
| 417 | `expectation_failed` | Expectation Failed |
| 421 | `misdirected_request` | Misdirected Request |
| 422 | `unprocessable_content` | Unprocessable Content |
| 423 | `locked` | Locked |
| 424 | `failed_dependency` | Failed Dependency |
| 425 | `too_early` | Too Early |
| 426 | `upgrade_required` | Upgrade Required |
| 428 | `precondition_required` | Precondition Required |
| 429 | `too_many_requests` | Too Many Requests |
| 431 | `request_header_fields_too_large` | Request Header Fields Too Large |
| 451 | `unavailable_for_legal_reasons` | Unavailable For Legal Reasons |
| 500 | `internal_server_error` | Internal Server Error |
| 501 | `not_implemented` | Not Implemented |
| 502 | `bad_gateway` | Bad Gateway |
| 503 | `service_unavailable` | Service Unavailable |
| 504 | `gateway_timeout` | Gateway Timeout |
| 505 | `http_version_not_supported` | HTTP Version Not Supported |
| 506 | `variant_also_negotiates` | Variant Also Negotiates |
| 507 | `insufficient_storage` | Insufficient Storage |
| 508 | `loop_detected` | Loop Detected |
| 511 | `network_authentication_required` | Network Authentication Required |

IANA currently registers 418 as unused and 510 as obsoleted. They do not get
named helpers. A deliberate use goes through the strict custom `status` form.

The catalog is a checked-in, versioned implementation table. It is not taken
from a potentially divergent reason-phrase module and is never fetched at
runtime. The POD links to the
[IANA HTTP Status Code Registry](https://www.iana.org/assignments/http-status-codes/http-status-codes.xhtml)
and states the registry date used by the implementation.

### 6.4 Redirect methods

`redirect` accepts only the meaningful body-bearing Location redirect codes:

```perl
$pages->redirect($context, $target, status => 302, %options);
$pages->redirect($scope,   $target, status => 302, %options);
$pages->redirect(          $target, status => 302, %options);
```

Named conveniences are:

| Code | Method | Registered title |
|---:|---|---|
| 301 | `moved_permanently` | Moved Permanently |
| 302 | `found` | Found |
| 303 | `see_other` | See Other |
| 307 | `temporary_redirect` | Temporary Redirect |
| 308 | `permanent_redirect` | Permanent Redirect |

The named redirect methods take the same immediate/deferred forms but do not
accept a conflicting `status` option. Codes 300, 304, 305, 306, and arbitrary
3xx values are not Pages redirect constructors.

## 7. Page Descriptor and Options

### 7.1 Normalized descriptor

All entry points build a fresh internal descriptor before rendering. An error
descriptor has this shape:

```perl
{
    kind       => 'error',
    status     => 404,
    title      => 'Not Found',
    detail     => 'The requested resource could not be found.',
    type       => 'about:blank',
    instance   => undef,
    extensions => {},
    headers    => [],
}
```

Welcome descriptors carry `kind => 'welcome'`, status 200, the fixed title,
detail, and documentation URI. Redirect descriptors carry
`kind => 'redirect'`, the final Location, and redirect kind. Every descriptor
therefore contains the exact status used by the stock favicon as well as the
wire response. The descriptor is request-local and is not exposed as mutable
instance state. Renderer hooks receive a shallow request-local value and may
not retain it as shared state.

### 7.2 Welcome options

`welcome` accepts only:

```text
as
headers
cache_control
```

`as` and `headers` have the same meaning and validation as on other Pages
methods. The welcome page emits no Cache-Control field by default; an explicit
`cache_control` is allowed. Its status and stock semantic content are fixed.

### 7.3 Common error options

Named errors and `status` accept:

```text
as             auto | html | json | text
detail         Unicode scalar
type           absolute problem-type URI
title          Unicode scalar
instance       URI-reference scalar
extensions     hashref of JSON-compatible extension members
headers        even-length arrayref [name => value, ...]
cache_control  field-value scalar
```

`as` overrides constructor policy for one call. `detail` replaces the safe
catalog detail in all representations.

`instance` is never inferred. It is included only when explicitly supplied.
URI and URI-reference options are ASCII wire values; callers percent encode
non-ASCII data. They reject control characters and Perl reference values.
`type` must be absolute, while `instance`, `blocked_by`, and `login_url` may be
relative where their underlying field or representation permits it.

For a registered status, `type` and `title` must either both be absent or both
be supplied. Supplying both changes the problem from the standard
`about:blank` status problem to an application-defined problem type. A custom
type must be absolute and cannot be `about:blank`. Supplying a custom title
alone or type alone croaks.

`extensions` are emitted as top-level RFC 9457 extension members in problem
JSON. They are not shown by the stock HTML or text renderers. The exact
reserved members `type`, `title`, `status`, `detail`, and `instance` cannot
appear in `extensions`.
Extension values must be encodable by the selected JSON implementation;
failure croaks before response start.

For status 511, `login` is additionally reserved whether or not `login_url` is
present. `login_url` is the sole input for that extension and its corresponding
HTML/text link; accepting an independent extension would let the three
representations disagree.

There is no `message` alias. The same RFC term `detail` controls human-facing
copy in every representation.

### 7.4 Redirect options

Redirect methods accept:

```text
as
status                 generic redirect only
detail
headers
cache_control
preserve_query         Boolean; default false
```

Problem `type`, `instance`, and `extensions` do not apply to redirect JSON.
Redirect JSON is an ordinary document, not a problem document.

### 7.5 Semantic HTTP options

The following named options are accepted only by their relevant statuses:

```text
challenge       401 or 407; scalar or arrayref of challenges
allow           405; method scalar or arrayref
length          416; non-negative selected-representation byte length
upgrade         426; protocol scalar or arrayref
retry_after     413, 429, 503, or redirects; delay-seconds or HTTP-date
blocked_by      451; URI-reference identifying the blocking entity
login_url       511; URI-reference to the network login resource
```

Using one on an unrelated status croaks rather than silently emitting a field
with unclear semantics.

Raw standards headers may instead be supplied through the flat
`[name => value, ...]` `headers` list; final validation examines the merged
result. If a semantic option and raw headers both provide the same
single-valued field, construction croaks. Authentication challenges may be
represented by multiple field lines.

`allow` accepts one method or an arrayref, validates HTTP token syntax,
uppercases methods, removes duplicates, and preserves first-seen order.
`challenge` accepts one nonempty scalar or an arrayref of nonempty scalars.
`upgrade` accepts one protocol token or an arrayref, removes duplicates, and
preserves first-seen order. `length` is a non-negative integer. URI-bearing
semantic options reject controls and delimiter characters that would escape
their generated field syntax. All validation occurs when an immediate
Response or deferred endpoint is constructed when the required information is
already available; request-dependent validation occurs before response start.

## 8. Content Negotiation

### 8.1 Representation families

Pages uses the existing `PAGI::Request` negotiation implementation rather
than adding another Accept parser.

The three server representations are:

```text
html   text/html; charset=utf-8
json   application/problem+json      errors
       application/json              welcome and redirects
text   text/plain; charset=utf-8
```

For errors, both `application/problem+json` and the pragmatic
`application/json` alias select the JSON family. The emitted content type
remains `application/problem+json`, as per RFC 9457. An explicit
`application/problem+json;q=0` excludes the family even if the alias is
otherwise acceptable; Pages does not override an exact rejection of the
representation it will actually send during normal selection. If that leaves
no acceptable representation, the total-failure rule in section 8.2 still
uses the configured default.

Welcome and redirect JSON are selected by `application/json` and matching
wildcards only. `application/problem+json` alone does not select them because
neither is a problem document. Both emit `application/json`.

### 8.2 Automatic selection

With `as => auto`:

- a missing `Accept` field selects `default`;
- `*/*` selects `default`;
- explicit ranges, q-values, specificity, and exclusions use the existing
  Request negotiation rules;
- equal-quality matches prefer the configured `default`, then HTML, JSON, and
  text in that server order;
- `Vary: Accept` is merged into the final response; and
- if the client excludes every offered representation, Pages renders its
  configured default rather than recursively generating a 406.

That last rule is deliberate failsafe behavior. RFC 9110 permits an origin to
disregard an unacceptable preference and send a default representation. A
page factory invoked while handling another failure must always be able to
produce a response.

With fixed `as => html|json|text`, Pages ignores `Accept` and does not add
`Vary: Accept`.

### 8.3 Shared negotiation correction

Pages does not work around defects with a private parser. The shared
`PAGI::Request::Negotiate` implementation is corrected so `best_match`
computes each supported type's effective quality from its most-specific
matching media range, then chooses the positive-quality supported type with
the highest effective quality in server order. For a concrete requested type,
`accepts_type` returns true only when that type's most-specific matching Accept
range has positive effective quality. A requested wildcard retains the
documented bidirectional behavior: it returns true when at least one media type
covered by that wildcard has positive effective quality. A zero-quality range
overrides less-specific positive ranges only for the media types it covers.

This fixes the current case where a positive wildcard can incorrectly revive
an exact exclusion:

```text
Accept: text/html;q=0, */*;q=1
```

`text/html` has effective quality zero and is not acceptable. Existing public
Request negotiation tests gain exact-exclusion, type-wildcard-exclusion, and
server-order tie cases. They also retain and extend the wildcard-query tests to
cover a positive concrete member, an exact exclusion under a positive global
wildcard, a completely excluded type family, and a positive concrete exception
inside an otherwise excluded family. Pages then layers only its documented
JSON-family alias rule on top of the shared primitive.

### 8.4 Language

Stock titles, details, HTML language metadata, and text are English. Pages
does not inspect `Accept-Language`, emit `Vary: Accept-Language`, or provide a
translation registry in v1. Applications may provide localized copy
explicitly or subclass rendering. Automatic localization is a separate future
design.

## 9. Rendering and Subclassing

### 9.1 Template methods

The supported presentation hooks are:

```perl
sub render_html    { my ($self, $page) = @_; ... }  # Unicode text
sub render_text    { my ($self, $page) = @_; ... }  # Unicode text
sub render_problem { my ($self, $page) = @_; ... }  # hashref
sub render_json    { my ($self, $page) = @_; ... }  # hashref
sub favicon_href   { my ($self, $page) = @_; ... }  # URI scalar or undef
```

The base class calls exactly one representation hook per response.
`render_problem` is used only for error JSON; `render_json` is used for welcome
and redirect JSON. Stock `render_html` additionally calls `favicon_href`.
Hook exceptions propagate normally. Hooks do not receive `$send`, do not start
a response, and do not return `PAGI::Response`. Hooks are synchronous. A hook
that returns a `Future` is rejected with a clear diagnostic before response
start rather than producing a mixed immediate/Future return contract.

The base class validates each result, UTF-8 encodes text itself, encodes JSON,
constructs the final Response, and retains authority over:

- actual status;
- representation Content-Type;
- Content-Length;
- negotiation and Vary;
- redirect Location;
- cache policy;
- mandatory status headers; and
- RFC 9457 `status` agreement with the wire status.

`render_problem` may add or transform extension members, but the final payload
must be a hashref. The base class reasserts the descriptor's standard members
and actual status after the hook, so a subclass cannot publish a problem status
that differs from the HTTP response. `render_json` must also return a hashref;
the base class retains authority over a redirect's status and final Location.
A welcome-page subclass may replace its presentation fields just as it may
replace the stock HTML or text.

These are distinct hooks because RFC 9457 problems and ordinary success or
redirect documents have different invariants. A subclass may implement either
without branching on `kind` inside one catch-all JSON renderer.

### 9.2 Stock HTML

The base HTML is a polished but neutral, responsive card-style page suitable
for a demo or small application. It contains:

- HTML5 doctype and `<html lang="en">`;
- status code;
- registered or custom title;
- safe detail;
- the fixed documentation link on the welcome page;
- self-contained inline styling; and
- no external fonts, images, scripts, or assets.

It does not infer or render Back, Home, Referer, or request-URI links. Pages
cannot know a safe or useful application destination. Redirect pages show one
escaped link to the explicit Location. A 511 page shows an escaped login link
only when `login_url` was supplied. Subclasses may add application navigation.

Every dynamic value is HTML escaped, including titles, details, redirect
targets, and explicit URLs. The default renderer contains no script.

### 9.3 Stock text

Text output has a stable minimal shape:

```text
404 Not Found

The requested resource could not be found.
```

It ends with one newline. Dynamic text is UTF-8 encoded by the base class.
Redirect text includes the final Location. No ANSI styling is emitted.

### 9.4 Stock JSON

Error JSON follows
[RFC 9457](https://www.rfc-editor.org/rfc/rfc9457.html):

```json
{
  "type": "about:blank",
  "title": "Not Found",
  "status": 404,
  "detail": "The requested resource could not be found."
}
```

`instance` is omitted unless supplied. Validated extensions are merged at the
top level. The wire status and JSON `status` always agree. Default production
details never expose stack traces, filesystem paths, SQL, secrets, request
headers, or other internal state.

Redirect JSON is intentionally not RFC 9457:

```json
{
  "status": 308,
  "location": "/new",
  "detail": "The requested resource has moved."
}
```

Welcome JSON is likewise an ordinary document, using the exact shape in
section 6.1. It does not contain a problem `type` or numeric `status` member.

### 9.5 Stock exact-status favicon

Every stock HTML document contains an explicit embedded favicon:

```html
<link rel="icon" type="image/svg+xml" href="data:image/svg+xml,...">
```

The stock icon is a generic status indicator, not PAGI branding. It contains
the descriptor's exact three-digit status: the leading family digit is large
and the final two digits are smaller. Thus a welcome page shows `200`, a
permanent redirect shows `308`, a missing page shows `404`, and a network
authentication error shows `511`. The glyph is off-white (`#faf8f1`) on a
rounded square with these subdued family colors:

| Family | Name | Background |
|---|---|---|
| 2xx | sage | `#566f60` |
| 3xx | slate | `#566a78` |
| 4xx | muted mustard | `#8a7743` |
| 5xx | muted burgundy | `#82505a` |

The icon communicates the exact status through text and its category through
both the leading digit and color; color is not the sole signal.

`favicon_href($page)` receives the normalized descriptor, including its exact
status. The base implementation selects the static family color and inserts a
freshly stringified, already-validated three-digit numeric status into a small
static SVG template. It percent-encodes that bounded ASCII SVG into a data URI;
it does not copy unchecked request text into XML. A subclass may return another
URI-reference or `undef` to omit the link. Returned scalars reject control
characters and are HTML attribute escaped. There is no per-call favicon option.

A subclass overriding only `favicon_href` keeps the stock document and changes
the icon. A subclass overriding `render_html` owns the complete document,
including whether it calls `favicon_href`. Applications with a strict Content
Security Policy that disallows `data:` images must override the hook with a
same-origin asset or return `undef`.

Embedding the icon prevents the ordinary browser fallback request for
`/favicon.ico`; an explicit client request for that path still reaches normal
routing. No standalone favicon route or asset is installed.

The approved prototype's complete SVG `link` element is 645 bytes. Equivalent
transparent 32-pixel PNGs rasterized from the same artwork produced complete
base64 `link` elements between 1,231 and 1,395 bytes, averaging 1,336 bytes;
the SVG prototype was 51.7% smaller on average. The empty control
`<link rel="icon" href="data:,">` is 31 bytes. These measurements justify SVG
over committed PNG assets; they are design-review evidence, not golden test
fixtures or a permanent payload-size contract.

### 9.6 Synchronous work budget

Response construction is intentionally synchronous, matching
`PAGI::Response->text`, `html`, and `json`. This does not make CPU work
nonblocking: wrapping the same operations in a `Future` would still execute
them on the event loop while making every common call require `await`.

The stock request path is therefore restricted to bounded in-memory work:

- inspect the already-populated HTTP scope and request headers;
- negotiate among the three fixed representations;
- validate scalar options and headers with precompiled/static validators;
- assemble and escape short stock strings;
- encode one small JSON document or UTF-8 text body; and
- construct the ordinary `PAGI::Response`.

It must not perform filesystem or network access, invoke subprocesses, discover
templates, dynamically load renderers, parse a status catalog, rasterize an
icon, or base64-encode icon data per request. Stock copy, status metadata,
HTML/CSS fragments, the SVG template, and its four family colors are checked-in
constants. Constructing and percent-encoding one bounded SVG from the validated
numeric status is permitted. The implementation should avoid a general
template engine or intermediate object graph for these fixed pages.

Any application or subclass requiring asynchronous data obtains it before
calling Pages:

```perl
async sub missing ($context) {
    my $detail = await fetch_safe_detail();
    return PAGI::Pages->not_found($context, detail => $detail);
}
```

Only the eventual wire operation is asynchronous:

```perl
my $response = PAGI::Pages->not_found($scope);
await $response->respond($send);
```

This boundary keeps the convenient immediate Response API without presenting
Pages as a suitable place for I/O or expensive application rendering.

## 10. HTTP Fields and Cache Policy

### 10.1 Pages-owned fields

The following fields are owned by Pages and rejected when supplied through
the raw `headers` option:

```text
Content-Type
Content-Length
Transfer-Encoding
Location
Cache-Control
Connection
```

Their canonical inputs are `as`, the explicit redirect target, automatic
negotiation, `cache_control`, and Pages' HTTP/1.1-only 426 construction.
Rejecting raw duplicates keeps the merge deterministic, avoids CL/TE
ambiguity, and prevents a caller-supplied hop-by-hop Connection field from
contradicting Upgrade signaling.

`Vary` is accepted through `headers`; automatic negotiation parses it and
merges `Accept` case-insensitively without discarding other field names or
creating duplicate tokens.

All header names are compared case-insensitively. Pages performs stricter
input validation before adding values to the intentionally opaque
`PAGI::Headers` container. Control characters, invalid names, malformed or
odd flat lists, wide-character field values, and reference-valued field
names/values croak before response start. The PAGI server remains the final
wire validator.

### 10.2 Error caching

Every 4xx/5xx Pages response defaults to:

```text
Cache-Control: no-store
```

This is a safe framework default even for status codes HTTP otherwise permits
to be cached heuristically. A caller may deliberately replace it:

```perl
PAGI::Pages->gone(
    $context,
    cache_control => 'public, max-age=86400',
);
```

Statuses 428, 429, 431, and 511 must not be stored under their defining RFC.
For those statuses Pages forces `no-store`; a conflicting `cache_control`
croaks.

Redirects add no Cache-Control field by default. In particular, Pages does not
disable the ordinary cache semantics of 301 and 308. An explicit
`cache_control` is allowed.

The welcome page also adds no Cache-Control field by default. It follows
ordinary 200 response semantics and accepts an explicit `cache_control`.

### 10.3 Mandatory and advisory fields

The final merged response enforces:

| Status | Requirement |
|---:|---|
| 401 | at least one `WWW-Authenticate` challenge; mandatory |
| 405 | exactly one normalized `Allow` field; mandatory; empty is legal |
| 407 | at least one `Proxy-Authenticate` challenge; mandatory |
| 426 | `Upgrade` and HTTP/1.1 connection signaling; mandatory |

The semantic mappings are:

```text
401 challenge  -> WWW-Authenticate
405 allow      -> Allow
407 challenge  -> Proxy-Authenticate
426 upgrade    -> Upgrade plus Connection: Upgrade
```

Missing mandatory information croaks. Raw headers may satisfy the requirement
where allowed by section 7.5.

A raw `Upgrade` field may satisfy 426; Pages still adds the owned
`Connection: Upgrade` field after validating HTTP/1.1. A raw `Connection`
field is rejected under section 10.1 and cannot override that signaling.

For 426, Pages examines the request scope's HTTP version. HTTP/2 and HTTP/3
prohibit `Upgrade` and `Connection`, while HTTP/1.0 does not support the
HTTP/1.1 Upgrade mechanism. `upgrade_required` therefore works only for
HTTP/1.1 and croaks for other explicit versions rather than emitting a
malformed or ineffective response. An absent version follows the existing
`PAGI::Request` default of HTTP/1.1.

Pages also makes recommended/optional fields easy without making them
mandatory:

| Status | Option | Result |
|---:|---|---|
| 413, 429, 503 | `retry_after` | `Retry-After` |
| 416 | `length` | `Content-Range: bytes */N` |
| 451 | `blocked_by` | `Link: <URI>; rel="blocked-by"` |
| 511 | `login_url` | representation link to network login resource |

`retry_after` also applies to redirects. Integer delay values must be
non-negative. Date values must be a valid IMF-fixdate; implementation may use
the distribution's existing `HTTP::Date` dependency to validate the calendar
value but must reject obsolete or arbitrary date-like sender spellings.

For 511, `login_url` becomes an escaped link in HTML, a labeled URI in text,
and a top-level `login` extension member in problem JSON.

The 407 and 511 POD explicitly note that they are proxy/network-interception
responses rather than ordinary origin-application errors.

### 10.4 Mutable Response escape hatch

Pages validates and owns the Response it constructs, but the returned value is
an ordinary mutable `PAGI::Response`. A caller may deliberately change its
status, headers, content type, or body before sending:

```perl
my $response = PAGI::Pages->not_found($scope);
$response->headers->set('X-Request-ID' => $request_id);
```

Pages does not re-run semantic validation from `PAGI::Response->respond`.
Changing Pages-owned or status-mandatory fields after construction is the
documented low-level escape hatch, and the caller owns resulting protocol
correctness. The MethodNotAllowed middleware's existing send proxy remains the
one exception: it authoritatively repairs `Allow` on a final 405 event.

## 11. Redirect Correctness

The target is an absolute or relative ASCII URI-reference scalar; non-ASCII
characters must be percent encoded. Pages rejects wide characters and
references containing control characters before constructing `Location`.
It does not require an absolute URI, infer a host, or authorize the target.
Applications remain responsible for preventing open redirects when targets
are influenced by users.

`preserve_query` defaults to false. When true, Pages appends the incoming raw
encoded query string without decoding or re-encoding it. It correctly places
the query before a fragment:

```text
target:   /search?sort=date#results
incoming: q=perl
result:   /search?sort=date&q=perl#results
```

It handles targets with no query, an existing empty query, an existing query,
and fragments. Empty incoming query strings change nothing. The final target
is used consistently for `Location` and the selected response body.

The HTML link escapes the URI-reference as HTML text and attribute data.
Text uses the validated scalar. JSON uses ordinary JSON escaping. None of
these body transformations alter the actual Location field value.

## 12. First-party Integration

### 12.1 Routing NotFound

`PAGI::Middleware::Routing::NotFound` retains its conditional routing-trace
semantics and custom `handler` contract. Its built-in renderer delegates to
`PAGI::Pages->not_found($context, ...)`.

Production uses the safe catalog detail. Development supplies its current
bounded method/path/attempt diagnostics as `detail`; Pages negotiates their
HTML, JSON, or text representation. The middleware remains responsible for
deciding when a trusted routing decline is a 404.

The POD comparison with removed `PAGI::App::NotFound` is deleted and replaced
with Pages terminal-endpoint examples.

### 12.2 Routing MethodNotAllowed

`PAGI::Middleware::Routing::MethodNotAllowed` retains matching policy,
snapshot calculation, and its authoritative send-boundary `Allow`
normalization for every custom response-like value.

Its built-in renderer delegates to:

```perl
PAGI::Pages->method_not_allowed(
    $context,
    allow  => $snapshot->allowed_methods,
    detail => $safe_or_development_detail,
);
```

The response proxy remains authoritative so an author-provided handler cannot
accidentally emit a stale `Allow`. Pages' own final validation independently
makes direct 405 use valid.

### 12.3 ErrorHandler

`PAGI::Middleware::ErrorHandler` retains:

```text
development
on_error
status
handler
```

Remove the `content_type` option. The built-in renderer now negotiates through
Pages. A fixed representation uses the existing handler seam:

```perl
middleware('ErrorHandler',
    handler => PAGI::Pages->internal_server_error(as => 'json'),
);
```

The migration guide gives exact replacements for each former content type.
No `pages`, `as`, or renderer option is added to ErrorHandler.

Without a custom handler, ErrorHandler chooses a safe registered catalog
status and calls Pages. For ordinary exceptions this is 500. An exception's
`status_code` is preserved only when it is a current registered 4xx/5xx status
that can be validly rendered without missing mandatory protocol information.
Bare 401, 405, 407, and 426 exception statuses fall back to 500. Unknown,
unused, obsoleted, non-error, malformed, and reference-valued status codes also
fall back to 500. The original error still reaches `on_error`; framework
diagnostics identify a rejected claimed status without exposing either value
in production output.

The same distinction applies to ErrorHandler's configured `status`. Without a
custom `handler`, construction accepts only a registered error Pages can render
without missing mandatory external facts; configuring 401, 405, 407, 426, or a
non-catalog status croaks and explains that a handler is required. With a
custom handler, `status` remains the seed supplied to that handler and Pages
places no restriction on it.

Calling an exception object's `status_code` is itself guarded. A throwing
method, failed Future-like value, reference, or otherwise invalid result is a
rejected claim and cannot replace the original exception or escape the safe
500 path.

Development passes the safely stringified exception and existing diagnostic
copy as `detail`. Production uses the catalog's safe detail. ErrorHandler
continues to own environment resolution, logging, response-start detection,
and post-start rethrow semantics; Pages never reads `PAGI_ENV`.

If Pages construction, negotiation, subclass rendering, JSON encoding, or
response construction throws while the outer ErrorHandler is rendering,
ErrorHandler emits one final hardcoded UTF-8 plain-text 500 with no-store. That
tiny path is intentionally below Pages and contains no dynamic exception text.
If even the final send fails, the original/current failure propagates to the
server; ErrorHandler does not attempt a second response.

### 12.4 Compose

Compose's wrapper graph and lack of fallback configuration remain unchanged.
Its stock NotFound, MethodNotAllowed, and ErrorHandler instances now inherit
Pages negotiation and neutral presentation.

An application that wants a subclass installs ordinary inner middleware:

```perl
my $pages = MyApp::Pages->new;

compose(
    app => $routing,
    middleware => [
        middleware('Routing::NotFound',
            handler => $pages->not_found),
        middleware('Routing::MethodNotAllowed',
            handler => sub ($context, $snapshot) {
                return $pages->method_not_allowed(
                    $context,
                    allow => $snapshot->allowed_methods,
                );
            }),
        middleware('ErrorHandler',
            handler => $pages->internal_server_error),
    ],
)->to_app;
```

No Compose option identifies the subclass, and Compose does not detect or
remove its outer failsafes. An inner response makes those outer layers inert;
an inner renderer failure can still be recovered by the stock outer 500.

### 12.5 Distribution-wide default response adoption

The adoption rule is deliberately semantic rather than based only on status
code:

> When a first-party component's own default branch would synthesize a
> generic body-bearing HTTP error or Location redirect, the component
> delegates construction of that default response to `PAGI::Pages`.

The component continues to own the condition, status choice, and facts it has
computed. Pages owns representation negotiation, safe default copy, encoding,
Content-Length, cache policy, Location construction, and validation of
status-specific fields. The ordinary response then goes through the same
`respond($send)` path as any direct Pages use.

This rule does not add `pages`, `renderer`, or `as` options to every component,
and no component discovers a Pages subclass through scope or global state.
Applications that need one branded policy use the existing handler/body seam
where one exists, arrange pass-through to an application-owned fallback, or
replace that component response with explicit application policy. Ordinary
routing/error middleware provides the reusable boundary for the cases it
already owns; this spec does not pretend that arbitrary already-sent component
responses can be restyled by a generic outer wrapper. A future injection
design requires a separate motivating use case.

The following defaults migrate in this change:

| Component | Default response delegated to Pages | Component-owned facts retained |
|---|---|---|
| `PAGI::App::File` | 400, 403, 404, 405, 416 | 405 supplies `Allow: GET, HEAD`; 416 supplies the selected file length |
| `PAGI::App::Directory` | pre-delegation 403 responses; File defaults only after a resolved file or index target is delegated | directory safety/listing decision remains local |
| `PAGI::App::URLMap` | no-default HTTP 404 | mount selection and opaque-boundary behavior remain unchanged |
| `PAGI::App::Proxy` | backend-connect 502 | connection decision remains local; demo-only warning is unchanged |
| `PAGI::App::Loader` | HTTP load-failure 500 | loading, warnings, and reload behavior remain local |
| `PAGI::App::WrapCGI` | HTTP process-start 500 | CGI execution and response parsing remain local |
| `PAGI::App::Throttle` | default HTTP 429 | `retry_after` and enabled rate-limit fields; `on_limit` remains authoritative |
| `PAGI::Middleware::Static` | 403, 404, 500, 416 | pass-through behavior remains local; 416 supplies file length |
| `PAGI::Middleware::Auth::Basic` | default 401 | generated Basic challenge and configured realm |
| `PAGI::Middleware::Auth::Bearer` | default 401 | generated Bearer challenge, configured realm, and safe failure detail |
| `PAGI::Middleware::CSRF` | enforced default 403 | validation and `enforce => 'app'` behavior remain local |
| `PAGI::Middleware::ContentNegotiation` | strict-mode 406 | supported-type list remains in the safe detail; matching delegates to the shared Request negotiator |
| `PAGI::Middleware::FormBody` | body-limit 413 | configured size limit and request consumption remain local |
| `PAGI::Middleware::JSONBody` | body-limit 413 and invalid-JSON 400 | parsing decision remains local; raw decoder diagnostics are no longer exposed |
| `PAGI::Middleware::Maintenance` | built-in 503 | `retry_after` and bypass/enabled decisions remain local |
| `PAGI::Middleware::RateLimit` | default 429 | `retry_after` and `X-RateLimit-*` fields |
| `PAGI::Middleware::ReverseProxy` | forwarded-authority 400 | trust and normalization decisions remain local |
| `PAGI::Middleware::TrustedHosts` | missing Host, structurally malformed or duplicate Host, and allowlist-rejected Host 400 | host policy remains local |
| `PAGI::Middleware::HTTPSRedirect` | invalid-authority 400 and redirect | authority validation, HSTS behavior, redirect code, path, and query |
| `PAGI::Middleware::Rewrite` | redirect-mode response | rule selection, redirect code, rewritten path, and incoming query |
| `PAGI::Endpoint::HTTP` | automatic 405 | the endpoint's complete `allowed_methods` result |

Every raw application or middleware sender passes the original request scope
to Pages so negotiation observes the same request. Private send helpers are
reshaped as necessary to accept that scope; this is not public API.

The File and Static 416 branches pass `length => $size`, producing
`Content-Range: bytes */$size`. File's 405 passes `allow => [qw(GET HEAD)]`.
Endpoint::HTTP passes its already-computed method list. Authentication
middleware passes its generated challenge through the semantic `challenge`
option, so Pages' header validation also rejects a realm that would inject a
field delimiter. Each authentication middleware remains responsible for
scheme-specific quoting; Basic and Bearer both use quote/backslash-safe realm
construction before Pages validates the final field.

RateLimit and Throttle use `retry_after` and the flat `headers` option to
retain their existing rate-limit metadata. Maintenance uses Pages only when
neither `body` nor `content_type` was explicitly supplied; either existing
option selects the existing literal custom-response branch, while
`retry_after` remains effective in both branches. `on_limit` continues to win
over Throttle's default.

Directory resolves and checks the candidate before delegating to File. A
missing or otherwise unresolvable path therefore remains Directory's
pre-delegation 403 branch; it does not reach File's 404. A directory without an
index is rendered as a 200 listing before File's method gate, so its POST
behavior does not reach File's 405. Pages adoption preserves those existing
trigger decisions. Tests must not infer File behavior for branches that never
delegate.

JSONBody's invalid-input detail becomes the stable, safe sentence `The request
body is not valid JSON.` rather than interpolating the decoder exception into
a client response. Other component details may retain concise facts already
safe for clients, but never include a filesystem path, credential, token,
exception, or raw rejected header value.

ContentNegotiation replaces its private best-match loop with
`PAGI::Request::Negotiate->best_match` while retaining the existing
`pagi.preferred_content_type` and `pagi.accepted_types` scope shapes. This
makes the middleware share section 8.3's exact-exclusion and server-order
rules. Its strict branch constructs and sends a Pages 406 directly; it does not
redispatch through ContentNegotiation. The middleware's application
representation set and Pages' error representation set are independent. If a
request rejects every application representation but accepts a Pages
representation, Pages selects that representation. For example,
`Accept: application/json` against an XML-only application produces an
`application/problem+json` 406. If the request also rejects every Pages
representation, Pages uses its documented failsafe default. Pages never
generates another 406 from failed page negotiation, so neither path recurses.

HTTPSRedirect and Rewrite delegate the *unmodified logical target* plus
`preserve_query => 1` to Pages rather than concatenating a query themselves.
This retains their documented query-preserving behavior and fixes query
placement when a rewrite target contains a fragment. Their constructors
validate `redirect_code` against Pages' supported 301/302/303/307/308 set so
bad configuration fails before a request.

Only HTTP default branches delegate to Pages. A component that also receives
WebSocket, SSE, or lifespan scopes must not emit Pages HTTP events there.
Existing valid pass-through or protocol-specific behavior stays intact. Three
pre-existing malformed fallbacks are made explicit rather than routing them
through Pages:

- Loader failure on a non-HTTP scope croaks that the application could not be
  loaded for that scope type.
- URLMap exhaustion with no configured default on a non-HTTP scope croaks that
  it has no default for that scope type.
- Throttle exhaustion on a non-HTTP scope without `on_limit` croaks that the
  built-in rate-limit response is HTTP-only and names `on_limit` as the escape
  hatch.

These branches currently emit `http.response.*` events on incompatible
channels. Clear failure is safer, does not invent protocol policy, and gives
each case a deterministic test.

The following superficially similar responses do **not** migrate:

- `PAGI::App::Healthcheck` and `PAGI::Middleware::Healthcheck` responses,
  including their 503 forms, because their JSON bodies are the health-check
  protocol consumed by infrastructure;
- bodyless 204, 304, conditional, range-success, and CORS preflight responses;
- WebSocket/SSE denials, closes, routing misses, and streaming start events;
- `PAGI::Test::Client`'s synthetic infrastructure failure;
- examples whose literal response is the behavior being taught;
- `PAGI::Response`'s low-level construction examples, except where a nearby
  comparison to Pages materially helps; and
- application-authored or callback-provided bodies, including Context CSRF
  examples and component custom handlers.

This boundary matters more than maximizing the count of Pages call sites. A
503 health document is an application protocol; a 503 maintenance fallback is
a conventional page.

### 12.6 Removed applications

Delete:

```text
lib/PAGI/App/NotFound.pm
lib/PAGI/App/Redirect.pm
```

Remove live references from `lib/`, `t/`, `examples/`, `Changes`, and generated
public documentation. Add `PAGI::Pages` to `t/00-load.t`; neither removed module
is currently listed there. Replace unconditional NotFound apps with a Pages
endpoint. Replace Redirect apps with a Pages endpoint or a small raw closure
when destination calculation requires request-specific application logic.

The repository-wide removal includes the concrete references in
`PAGI::App::Cascade` POD, `PAGI::Middleware::Builder` POD,
`PAGI::Middleware::Routing::NotFound` POD, `PAGI::Tools::Cookbook`,
`t/app/02-routing.t`, `examples/test-lifespan-shutdown/app.pl`, and `Changes`.
The final live-source search is scoped to `lib/`, `t/`, `examples/`, `Changes`,
the root README, and distribution configuration so a less obvious shipped link
or example cannot retain a dead package name.

`MANIFEST` is generated by Dist::Zilla and ignored by Git, so implementation
does not edit it directly. The built distribution must contain `PAGI::Pages`
and must not contain either removed module. Historical files under
`docs/superpowers/` are intentionally exempt from replacement and search
assertions: `dist.ini` prunes `docs/`, and those records continue describing
the code and decisions that existed when they were written.

The old Redirect app's `preserve_query => 1` default is intentionally not
retained. Pages defaults it to false and implements fragment-safe merging.

### 12.7 Context scope-type resolution

Correct `PAGI::Context`'s current unknown-to-HTTP fallback as part of the
protocol boundary this work depends on. Context is a value wrapper and cannot
know every scope type a future application may support; it must neither reject
all extensions nor misclassify them as HTTP.

`PAGI::Context->_resolve_class` follows this contract:

- a missing, undefined, empty, or reference-valued `scope->{type}` croaks as a
  malformed PAGI scope;
- a type present in the invoking class's `_type_map` selects that mapped class;
- an explicit unmapped scalar type selects the base `PAGI::Context` class and
  emits one warning per factory-class/type pair per process; and
- a subclass may continue overriding `_type_map` or `_resolve_class` for richer
  protocol-specific behavior.

For example:

```perl
PAGI::Context->new({ type => 'http' }, $receive, $send);
# PAGI::Context::HTTP

PAGI::Context->new({ type => 'myapp.mcp' }, $receive, $send);
# generic PAGI::Context with type "myapp.mcp"; warns once

PAGI::Context::HTTP->new({ type => 'myapp.mcp' }, $receive, $send);
# generic PAGI::Context, never PAGI::Context::HTTP; warns once for this factory

PAGI::Context->new({}, $receive, $send);
# croaks: PAGI scope type is required
```

Returning a generic Context does not declare that the surrounding application
supports that protocol. The application, router, or endpoint remains
responsible for accepting the scope deliberately or throwing as required by
the PAGI specification. Protocol-owning first-party components retain their
explicit supported-type gates. Pages accepts only explicit HTTP.

The warning names the factory class and received type. Repeated scopes of the
same type through the same factory class do not flood request logs. An
application deliberately using its own generic Context subclass for a custom
protocol may retain that class and silence the warning by mapping the type
explicitly:

```perl
package MyApp::Context;
use parent 'PAGI::Context';

sub _type_map ($class) {
    return {
        %{ $class->SUPER::_type_map },
        'myapp.mcp' => 'MyApp::Context',
    };
}
```

Custom event types inside an existing HTTP, WebSocket, SSE, or other scope do
not participate in Context-class selection; `_resolve_class` dispatches only
on the connection scope's `type`. A future standardized MCP or other protocol
package may map its assigned scope type to a protocol-specific subclass. A
global registry, automatic module discovery, and Router-level Context-factory
injection remain separate designs.

## 13. Security and Failure Properties

- Stock HTML escapes every descriptor-derived dynamic value in the appropriate
  text or attribute context. A subclass overriding `render_html` owns escaping
  within its returned document.
- All text and HTML hooks return Unicode; the base class performs strict UTF-8
  encoding and calculates byte-correct Content-Length through Response.
- Problem payload encoding failures occur before response start.
- Redirect targets reject control characters and are independently escaped in
  bodies; Pages does not claim to prevent application-level open redirects.
- The stock favicon interpolates only a freshly stringified status that has
  already passed Pages' numeric and range validation into an otherwise static
  SVG template. It never copies unchecked request text into XML. Custom
  `favicon_href` results reject controls and are HTML-attribute escaped;
  applications with CSP rules that disallow `data:` images have the documented
  override or omission seam.
- Raw header input receives Pages' strict preflight validation before entering
  the opaque shared header container.
- Caller-supplied Content-Length and Transfer-Encoding are rejected.
- Problem extensions cannot replace standard members.
- Problem `status` always matches the wire status.
- `instance` is never inferred, avoiding accidental disclosure of private
  request targets or query strings.
- Production default detail never includes an exception, route pattern,
  filesystem path, header, database value, or environment value.
- Error responses default to no-store; RFC-mandated non-storage statuses
  cannot weaken that policy.
- A deferred endpoint captures only immutable recipe/configuration values and
  creates fresh request values on every call.
- A mounted Pages endpoint rejects non-HTTP scopes instead of emitting invalid
  HTTP events on WebSocket, SSE, or lifespan channels.
- The 426 helper rejects protocols other than HTTP/1.1 rather than emitting
  forbidden or ineffective connection-specific fields.

### 13.1 HEAD ownership

Pages does not suppress a body merely because an immediate Response's bound
scope says HEAD. Response bodies must remain visible to enclosing middleware
that calculates GET-equivalent headers such as compression or Content-Length;
the outermost HEAD boundary owns wire suppression.

Routing and Compose install the final `PAGI::Routing::HeadBoundary`, which
suppresses the wire body without rewriting `HEAD` to `GET`.
`PAGI::Middleware::Head` is not equivalent and must not be recommended here:
it rewrites the method and can bypass a custom HEAD route.

A deferred Pages endpoint is a native HTTP application, but it is not by
itself a complete multi-protocol server root. The supported root deployment is:

```perl
my $app = compose(
    app => PAGI::Pages->not_found,
)->to_app;
```

Compose supplies lifespan handling and the correct final HEAD boundary. A
framework invoking the endpoint directly owns an equivalent final wire
boundary: the inner application retains method `HEAD`, while response bodies,
sendfile events, streaming chunks, and trailers are suppressed only after all
body-derived headers have been calculated. A raw caller that directly invokes
`response->respond($send)` has the same responsibility.
`PAGI::Routing::HeadBoundary` remains an internal compiler utility rather than
new application API.

## 14. Documentation and Examples

### 14.1 PAGI::Pages POD

The module POD contains complete examples, not isolated expression fragments,
for all of these forms:

1. Class-style one-off Response from Context.
2. The welcome endpoint in a small runnable demo.
3. Configured instance and presentation subclass, including favicon override.
4. Returning a Response from an async `$context` handler.
5. Constructing, modifying, and explicitly sending a Response in raw PAGI.
6. Using a deferred endpoint in `route`.
7. Using a deferred endpoint in `mount`, with the subtree warning adjacent.
8. Using a deferred endpoint as `compose(app => ...)`.
9. Invoking a deferred endpoint directly with an HTTP PAGI triplet, labeled as
   HTTP-only embedding rather than a complete server root.
10. Deploying the same endpoint as a server root through Compose, which owns
    lifespan and the final HEAD boundary.
11. Supplying Pages endpoints to NotFound and ErrorHandler middleware.
12. Wrapping MethodNotAllowed to use the routing snapshot's method union.
13. HTML, ordinary JSON/problem+json, and text negotiation with concrete
    Accept fields.
14. Fixed `as` and automatic fallback behavior.
15. Custom RFC 9457 type/title/detail/instance/extensions.
16. Every mandatory status-specific option and its emitted header.
17. Redirect query preservation before fragments.
18. Safe response modification before `respond($send)`.
19. Embedded stock favicons, a same-origin subclass override, and `undef`
    suppression for strict CSP applications.

The main synopsis explicitly explains *why* `$scope` alone returns an unsent
Response: callers may inspect or add application headers before the raw send
step. It contrasts that ownership with Router-managed Context handlers.

### 14.2 Cross-document updates

Update:

- `PAGI::Tools::Tutorial` response/error/redirect material;
- `PAGI::Tools::Cookbook` fallback, ErrorHandler, redirect, and raw-app recipes;
- `PAGI::Routing`, `PAGI::Compose`, and routing middleware POD;
- `PAGI::Response` SEE ALSO and low-level-versus-conventional comparison;
- POD for every component in section 12.5 whose built-in output now
  negotiates through Pages, including the retained custom-response seams;
- module/load lists and distribution metadata;
- the upgrade guide and Changes; and
- example READMEs that currently hand-roll default pages.

`PAGI::Pages` and `PAGI::Response` cross-link each other. Routing NotFound
cross-links Pages and no longer references removed `PAGI::App::NotFound`.

### 14.3 Examples

Update examples where Pages removes repeated default code without hiding the
application's real teaching point. In particular, keep
`examples/15-large-application` current:

- use Pages for appropriate root or nested terminal pages;
- keep intentional branded/custom catchall behavior when it demonstrates
  routing ownership;
- show a Pages response returned from `$c`;
- show a response modified before sending only in an example where raw wire
  ownership is itself relevant; and
- do not replace application-domain pages merely to maximize Pages usage.

At least one small runnable example demonstrates route, mount, Compose, and raw
forms together and includes the welcome page plus requests for HTML, JSON, and
text.

## 15. Migration

The upgrade documentation contains before/after recipes.

### 15.1 NotFound application

```perl
# Before
PAGI::App::NotFound->new->to_app;

# After
PAGI::Pages->not_found;
```

For custom literal output where negotiation is unwanted, direct
`PAGI::Response` remains appropriate.

### 15.2 Redirect application

```perl
# Before
PAGI::App::Redirect->new(
    to             => '/new',
    status         => 308,
    preserve_query => 1,
)->to_app;

# After
PAGI::Pages->redirect(
    '/new',
    status         => 308,
    preserve_query => 1,
);
```

Dynamic targets move to a normal handler or raw closure. The guide calls out
the new secure default `preserve_query => 0`.

### 15.3 ErrorHandler content type

```perl
# Before
middleware('ErrorHandler', content_type => 'application/json');

# After
middleware('ErrorHandler',
    handler => PAGI::Pages->internal_server_error(as => 'json'),
);
```

Equivalent examples cover HTML and text. Authors who want request negotiation
remove `content_type` and use the new built-in default.

### 15.4 Automatic default response appearance

Compose's built-in 404, 405, and 500 responses change from fixed plain or
ErrorHandler-configured output to Accept-negotiated Pages output. They retain
safe no-store behavior. Applications whose tests assert literal fallback body
strings must assert semantic status/headers or install an explicit handler.

### 15.5 Other first-party defaults

The upgrade guide includes a table matching section 12.5. It states that the
trigger and status are unchanged, while the default body, Content-Type,
Content-Length, Vary, and cache policy may change because Pages now performs
negotiation and encoding consistently.

It calls out these less-obvious migrations explicitly:

- File's automatic 405 now includes its required `Allow: GET, HEAD` field.
- File and Static invalid ranges now include `Content-Range: bytes */N` when
  the representation length is known.
- JSONBody no longer exposes decoder exception text.
- ContentNegotiation now uses the shared Request matching rules, including
  exact q=0 exclusions and deterministic server-order ties.
- Basic/Bearer realm values now pass strict response-header validation.
- HTTPSRedirect and Rewrite place preserved queries before a target fragment.
- Redirect codes outside 301/302/303/307/308 now fail at construction.
- Maintenance's explicitly supplied `body` or `content_type`, Throttle's
  `on_limit`, and every existing custom routing/error handler remain literal
  and unnegotiated.
- Loader, URLMap, and Throttle no longer emit HTTP events from the named
  non-HTTP fallback cases; they fail with the diagnostics in section 12.5.

Applications that asserted a built-in English body may fix the representation
with an existing custom hook or update tests to assert the status, required
fields, and selected media type. There is intentionally no global switch back
to the old collection of component-specific bodies.

## 16. Test Requirements

### 16.1 Construction and invocation

- Class calls return fresh Response values.
- Welcome supports every documented class, instance, immediate, and deferred
  invocation form and always returns status 200.
- Instance calls honor constructor policy.
- Subclass class calls instantiate and dispatch through the subclass.
- Immediate Context and scope calls return unsent Responses.
- Deferred calls return plain coderefs.
- Deferred Context calls return Responses and tolerate fallback/error metadata.
- Deferred scope-only calls return Responses.
- Deferred raw triplets send complete responses and settle their Future.
- Invalid arities, receive/send shapes, malformed scope structures, and
  missing or explicit non-HTTP scope types fail with stable diagnostics.
- Context requires a nonempty scalar scope type, maps built-in and subclass
  `_type_map` entries, and returns the base `PAGI::Context` class for an
  explicit unmapped type rather than blessing it as the invoking class.
- A generic custom-protocol Context preserves its raw scope and receive/send
  channels, does not expose HTTP response helpers, and is rejected by Pages.
- The first unmapped type through each factory class warns with the class and
  type; subsequent scopes of the same pair do not warn, while an explicit map
  to an application Context subclass suppresses the warning entirely.
- One endpoint handles concurrent in-flight requests without state leakage.

### 16.2 Composition forms

- A Pages endpoint works as an exact Route handler.
- The same endpoint works as an opaque Mount application.
- A mount owns descendant paths while a route does not.
- The same endpoint works as a Compose target.
- The same endpoint sends the expected response when invoked directly with an
  HTTP native PAGI triplet.
- Direct lifespan invocation fails with the documented non-HTTP diagnostic and
  emits no HTTP events.
- A server-root example wraps the endpoint in Compose and completes lifespan
  startup and shutdown.
- HEAD preserves the calculated GET headers and suppresses body events through
  the existing outer HEAD boundary.
- The Compose-wrapped root retains custom HEAD routing and suppresses only the
  final wire body. Direct raw `respond` is not misrepresented as owning HEAD.

### 16.3 Negotiation

- Missing Accept and `*/*` choose configured default.
- Explicit HTML, problem+json, application/json, and text preferences work.
- q-values, specificity, exclusions, and ties follow section 8.
- Shared `best_match` and `accepts_type` honor exact q=0 exclusions over
  positive wildcards and retain server order on effective-quality ties.
- `accepts_type` retains bidirectional wildcard queries: `text/html` satisfies
  a `text/*` query; exact q=0 excludes that exact concrete query; a
  `text/*;q=0` range excludes a `text/*` query despite a positive `*/*`; and a
  more-specific positive `text/html` exception makes that wildcard query true.
- Error JSON honors the application/json alias but an explicit
  problem+json q=0 rejection wins.
- Problem+json alone does not select welcome or redirect JSON.
- Completely unacceptable ranges use configured default.
- Auto merges `Vary: Accept` without duplicates.
- Fixed `as` ignores Accept and omits Vary.
- Errors emit problem+json; welcome and redirects emit application/json.

### 16.4 Rendering

- Every named status, when supplied any status-mandatory options, returns its
  registered code/title and nonempty safe detail.
- Stock HTML is complete, self-contained, English, and escapes every
  descriptor-derived dynamic value; subclass documentation makes
  custom-renderer escaping responsibility explicit.
- Stock HTML contains no inferred navigation and loads no external resources;
  the Welcome page's explicit documentation hyperlink is permitted.
- Welcome HTML/text/JSON contains the exact short stock copy and documentation
  target, and its HTML link is safely escaped.
- Welcome accepts only its three documented options and has no default cache
  field.
- Redirect/511 explicit links are safely escaped.
- Text has stable layout and one terminal newline.
- Unicode produces valid UTF-8 and byte-correct Content-Length.
- Problem JSON contains correct standard members and optional instance.
- Extensions are top-level and cannot replace reserved members.
- Status 511 reserves the `login` extension for `login_url`.
- JSON `status` cannot diverge from wire status through a subclass.
- `render_json` may customize welcome presentation but cannot replace a
  redirect's status or Location.
- Stock HTML embeds an `image/svg+xml` data URI and does not reference
  `/favicon.ico`, a checked-in image asset, or an external resource.
- A light semantic test decodes representative stock SVG data URIs and confirms
  that they contain the descriptor's exact three-digit status. It includes one
  registered status and a custom valid `599`, which must render `599` rather
  than the generic `5xx` label.
- Favicon tests intentionally do not freeze exact SVG markup, byte count,
  geometry, typography, or colors. No image-decoding dependency or golden
  binary fixture is added.
- The approved leading-digit/trailing-digits proportions, typography, colors,
  and browser-tab legibility remain design-review properties rather than pixel
  claims made by the automated suite.
- `favicon_href` sees the exact request-local status, accepts a safe custom URI,
  returns `undef` to omit the element, rejects controls, and escapes attributes.
- A full `render_html` override owns favicon inclusion and is not modified by
  the base class.
- Renderer return-shape and encoding failures occur before response start.
- Every renderer and favicon hook rejects a returned `Future`; async prerequisite
  work is demonstrated in the surrounding handler.
- Stock construction performs no request-time file access, image rasterization,
  dynamic renderer loading, network access, or subprocess invocation; the only
  favicon work is bounded interpolation and percent-encoding against a static
  SVG template and family-color table.
- A post-construction Response mutation remains possible and is documented as
  the caller-owned protocol escape hatch.

### 16.5 Status catalog and fields

- Every table entry in section 6.3 has a real ordinary method and `can` finds it.
- Typos fail normally; no AUTOLOAD catches them.
- 418 and 510 have no named methods.
- Strict custom 400-599 statuses require type/title/detail.
- Out-of-range and nonnumeric statuses fail.
- 401 and 407 require the correct challenge field.
- 405 always emits exactly one normalized Allow, including the legal empty case.
- 426 requires upgrade metadata on HTTP/1.1 and rejects HTTP/1.0, HTTP/2, and
  HTTP/3.
- 416 length, 451 blocked-by, 511 login URL, and Retry-After map correctly.
- Semantic/raw single-field conflicts fail.
- Pages-owned raw headers fail case-insensitively.
- Invalid header names/values and CRLF injection fail.

### 16.6 Cache behavior

- Every error defaults to no-store.
- Non-mandatory statuses accept explicit cache policy.
- 428, 429, 431, and 511 reject weaker/conflicting cache policy.
- Redirects add no cache policy by default.
- Redirects accept explicit cache policy.
- Welcome adds no cache policy by default and accepts an explicit policy.

### 16.7 Redirects

- Generic redirect accepts only 301, 302, 303, 307, and 308.
- Named helpers pin their status and reject a conflicting status option.
- Relative and absolute URI references work.
- Control characters fail.
- Query preservation defaults off.
- Raw incoming query is appended without re-encoding.
- Existing query, empty query, fragment, and query-plus-fragment cases work.
- Location and rendered body use the same final target.
- HTML, text, and JSON target escaping are independent and correct.

### 16.8 First-party integration

- NotFound built-in delegates to Pages and retains trace matching semantics.
- MethodNotAllowed built-in delegates to Pages and retains authoritative Allow.
- Custom routing handlers remain untouched.
- ErrorHandler built-in negotiates through Pages.
- ErrorHandler no longer accepts `content_type`.
- Registered exception status codes are preserved where valid.
- unknown/unused/mandatory-information exception statuses, including bare
  401/405/407/426, safely become 500.
- Built-in ErrorHandler configuration rejects statuses Pages cannot render
  completely; a custom handler retains the existing status seed escape hatch.
- A throwing or invalid `status_code` method safely becomes 500 without
  replacing the original exception.
- development details are visible only under middleware development policy.
- production details never expose original exception text.
- a Pages rendering failure reaches the hardcoded safe 500 path.
- a failure after response start is reported and rethrown without a second start.
- Compose defaults negotiate and remain inert around author responses.
- An inner Pages subclass handler wins without removing the outer failsafe.
- Every component row in section 12.5 has a focused integration test proving
  that its existing trigger still selects the same status and supplies its
  component-owned semantic fields to Pages.
- Representative app, middleware, authentication, parsing, file/range,
  redirect, and endpoint defaults each negotiate at least HTML, problem JSON,
  and text across the integration matrix; the shared Pages unit matrix need
  not be repeated for every status at every call site.
- File/Static 416, File/Endpoint 405, Basic/Bearer 401, both rate-limit
  implementations, Maintenance 503, and redirect query/fragment preservation
  assert their specific required or retained fields.
- TrustedHosts covers missing, structurally invalid or duplicate, and
  structurally valid but allowlist-rejected Host fields through Pages-backed
  400 responses.
- Directory missing paths retain its pre-delegation Pages-backed 403; POST to a
  listing directory retains the existing 200 listing outside Pages; POST and
  invalid Range against resolved delegated file/index targets exercise File's
  Pages-backed 405 and 416 respectively.
- Basic and Bearer realm tests cover quotes, backslashes, and rejected field
  delimiters without producing malformed challenge fields.
- Maintenance custom body/content-type, Throttle `on_limit`, and all routing
  custom handlers bypass Pages unchanged.
- JSONBody invalid input never exposes its decoder exception.
- ContentNegotiation retains its public scope values while sharing Request
  negotiation semantics. In strict mode, an XML-only application with
  `Accept: application/json` emits exactly one problem-JSON 406; with
  `Accept: image/png` it emits exactly one default-format 406; and
  `Accept: */*;q=0` reaches the strict branch after the shared negotiator fix.
  The downstream application is never called in these cases.
- Health-check JSON, 204/304 responses, WebSocket/SSE responses, and explicit
  application bodies remain byte-for-byte outside the adoption boundary.
- Loader, URLMap, and Throttle non-HTTP fallback tests assert the exact clear
  failures in section 12.5 and never observe `http.response.*` events.

### 16.9 Removal and documentation

- A Dist::Zilla build contains `PAGI::Pages` and excludes both removed module
  files; no source `MANIFEST` edit is expected.
- `t/00-load.t` loads Pages; no nonexistent legacy load-list entries are
  removed.
- The scoped live-source search in section 12.6 contains no obsolete reference;
  historical Superpowers plans and specs remain unchanged.
- POD examples compile; runnable examples execute under the documented Perl.
- Documentation exercises route, mount, Compose, Context, raw construction,
  raw sending, subclassing, middleware, negotiation, and mandatory headers.
- `examples/15-large-application` integration tests continue following real
  links and asserting its intended nested fallback ownership.

## 17. Rejected Alternatives and Adversarial Findings

### 17.1 Add Context convenience methods

`$context->not_found` is concise but cannot choose which Pages subclass or
application presentation policy it should use. Injecting a Pages object into
every Context would couple raw applications and third-party routers to one
optional rendering policy. It is deferred until a concrete dependency-
injection design exists.

### 17.2 Return a Pages-specific endpoint object

An object with `to_handler` and `to_app` would be inspectable, but `to_handler`
would establish a new framework-wide conversion convention solely for Pages.
A plain coderef already satisfies both stable invocation signatures and works
with Route, Mount, Compose, and raw PAGI. The lost introspection has no current
consumer and is accepted.

### 17.3 Teach Router about Pages

Special-casing a Pages value in Router would make the same component behave
differently outside that Router and would recreate parallel handler/raw target
rules. The deferred coderef avoids any Router change.

### 17.4 Make Pages methods send when `$send` is passed

Having `not_found($scope, $send)` perform I/O would make the public method
return a Response in one form and a Future in another. The immediate public
form always constructs a Response. Explicit `respond($send)` preserves the
Response ownership model; only a previously requested deferred app coderef
performs the raw adapter step.

### 17.5 Keep the two App classes as wrappers

Compatibility wrappers would leave two ways to express the same terminal
policy and preserve Redirect's surprising query default. The modules have no
known consumers and are removed. Migration is mechanical.

### 17.6 Configure Pages through Compose

Adding `pages`, `not_found`, `method_not_allowed`, or `server_error` options to
Compose creates a second customization mechanism beside ordinary middleware.
Inner middleware is already reusable at Compose, Router, and Mount boundaries
and retains the outer recovery layer.

### 17.7 Renderer strategy objects or callback bags

Independent renderer objects are composable but add several cooperating
objects to a small convenience layer. Constructor callback bags are concise
for one-offs but weaken named subclass behavior and grow without a clear
boundary. Four representation template methods plus the narrow favicon hook
keep ordinary customization Perlish and small. A future strategy layer can be
added without changing the response API if real consumers require it.

### 17.8 Automatic 406 on failed page negotiation

Generating a 406 while already rendering an error creates recursive failure
policy and can leave the application unable to answer. HTTP permits sending a
default representation instead. Pages records that behavior as an explicit
failsafe rule.

### 17.9 Automatic Back/Home links

Pages does not know the application's navigation graph. Referer is
untrustworthy as application policy and can disclose or return users to an
undesired location. Only explicit redirect and network-login targets become
links.

### 17.10 Automatic localization

Language negotiation needs translations, locale fallback, Content-Language,
Vary behavior, and stable localized RFC 9457 titles. English-only stock output
is honest and leaves that feature for a focused future contribution.

### 17.11 Blind 426 generation

RFC 9110 requires Upgrade signaling for 426, while HTTP/2 and HTTP/3 forbid the
corresponding connection-specific fields. Emitting only part of the required
response or relying on a server to strip fields would be invalid. Pages rejects
426 on those protocols.

### 17.12 Add a Pages option to every first-party component

Constructor-level `pages => $object` or `as => $format` options would make
each File, authentication, parsing, proxy, and utility component a second
configuration surface for application presentation. The options would be
inconsistent on components that already have custom bodies or callbacks and
would still not solve whole-application branding cleanly. Defaults therefore
delegate to the stock Pages class. Applications use a routing/error middleware
boundary where that boundary owns the failure, an existing component-specific
custom-response seam, pass-through, or explicit application code. There is no
claim that one outer middleware can restyle every component response without
intercepting and buffering it.

## 18. Sources

- [PAGI documentation](https://metacpan.org/pod/PAGI)
- [PAGI core specification](https://metacpan.org/pod/PAGI::Spec)
- [PAGI extension specification](https://metacpan.org/pod/PAGI::Spec::Extensions)
- [IANA HTTP Status Code Registry](https://www.iana.org/assignments/http-status-codes/http-status-codes.xhtml)
- [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110.html)
- [RFC 9113: HTTP/2](https://www.rfc-editor.org/rfc/rfc9113.html)
- [RFC 9114: HTTP/3](https://www.rfc-editor.org/rfc/rfc9114.html)
- [RFC 9457: Problem Details for HTTP APIs](https://www.rfc-editor.org/rfc/rfc9457.html)
- [RFC 6585: Additional HTTP Status Codes](https://www.rfc-editor.org/rfc/rfc6585.html)
- [RFC 7725: HTTP Status Code 451](https://www.rfc-editor.org/rfc/rfc7725.html)
