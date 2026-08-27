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

**After (shipped):** `disconnect_future` is modeled fully, matching
`PAGI::Request`/`PAGI::Context`'s own documented contract (see
`PAGI::Request`'s `disconnect_future` POD): it resolves with the reason on an
abnormal disconnect, and stays pending forever if first requested *after* a
clean completion, since there is no disconnect left to report.

```perl
# Before: this raced a Future that could never resolve on the mock, hiding
# a bug that would only surface against a real server.
await Future->wait_any($req->disconnect_future, $work);

# After: request it before the response completes, or use on_complete
# instead when you specifically need the "finished cleanly" case.
if ($req->is_connected) {
    await Future->wait_any($req->disconnect_future, $work);
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

my $app = PAGI::App::File->app_path('public')->to_app;
```

It owns validation, index and MIME selection, conditional and Range requests,
streaming `file` events, and negotiated stock errors.

**After (shipped custom raw boundary):** when authorization or response headers
require a custom handler, validate before any filesystem policy and emit only
the returned lexical path.

```perl
use Future;
use Future::AsyncAwait;
use PAGI::Pages;
use PAGI::Utils qw(path_from_root);

my $app = async sub {
    my ($scope, $receive, $send) = @_;
    my $untrusted_path = $scope->{path};

    my $path = path_from_root('/var/www/files', $untrusted_path);
    unless (defined $path) {
        my $response = PAGI::Pages->forbidden($scope);
        return await Future->wrap($response->respond($send));
    }

    # Replace the safe default with application-specific authorization.
    my $authorized = 0;
    unless ($authorized) {
        my $response = PAGI::Pages->forbidden($scope);
        return await Future->wrap($response->respond($send));
    }

    unless (-f $path && -r $path) {
        my $response = PAGI::Pages->not_found($scope);
        return await Future->wrap($response->respond($send));
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

`PAGI::Pages` now owns conventional first-party welcome, HTTP error, and
redirect representations. It returns an ordinary `PAGI::Response` when given a
Context or HTTP scope and a plain Context/native-PAGI endpoint coderef when no
request source is supplied.

### Replace the removed NotFound application

**Before (removed):**

```perl
PAGI::App::NotFound->new->to_app;
```

**After (shipped):**

```perl
use PAGI::Pages;

PAGI::Pages->not_found;
```

The replacement negotiates HTML, RFC 9457 problem JSON, or text and defaults
to `Cache-Control: no-store`. For an intentionally literal body, keep using a
direct Response instead:

```perl
PAGI::Response->text('No such page', status => 404)->to_app;
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
use PAGI::Pages;

PAGI::Pages->redirect(
    '/new',
    status         => 308,
    preserve_query => 1,
);
```

The old application preserved the incoming query by default. Pages defaults
`preserve_query` to `0`; opt in as above when query propagation is intended.
When enabled, Pages appends the raw query without re-encoding it and places it
before the first target fragment. Dynamic destinations move to an ordinary
Context handler or raw closure that computes the target and then calls Pages.

Pages redirects accept only 301, 302, 303, 307, and 308. Invalid configured
codes now fail at construction. The selected representation has a body and is
negotiated; use `PAGI::Response->redirect` when a literal empty redirect is the
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
middleware('ErrorHandler',
    handler => PAGI::Pages->internal_server_error(as => 'html'),
);
```

**Before (removed JSON selection):**

```perl
middleware('ErrorHandler', content_type => 'application/json');
```

**After (shipped):**

```perl
middleware('ErrorHandler',
    handler => PAGI::Pages->internal_server_error(as => 'json'),
);
```

**Before (removed text selection):**

```perl
middleware('ErrorHandler', content_type => 'text/plain');
```

**After (shipped):**

```perl
middleware('ErrorHandler',
    handler => PAGI::Pages->internal_server_error(as => 'text'),
);
```

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

There is no `pages` option on Compose and no Pages shortcut on Context. Supply
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

`PAGI::Context` no longer treats an unknown explicit scope type as HTTP. A
mapped type selects its registered Context subclass; an unmapped scalar type
uses the generic base Context and warns once per factory/type pair. Missing,
empty, or reference-valued scope types now croak as malformed. Applications
supporting an extension protocol should map it explicitly or deliberately
handle the generic Context; generic Contexts have no HTTP response API.

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

**After (shipped):** direct compilation sends the Router's own 404 and 405.
Compose supplies the separate root safety and lifecycle boundary.

```perl
# Router-complete outcomes: HTTP NONE/405 are sent here.
my $routing_app = $routing->to_app;

# Deployed application: adds ErrorHandler, response guard, HEAD, and lifespan.
my $app = compose(app => $routing)->to_app;
```

The bare Router still lacks the root ErrorHandler, response-completion guard,
and lifespan driver. It also does not turn silence from a selected raw app or
Mount target into a miss. Compose reports that silence as incomplete output
and renders 500 before response start.

For every HTTP target, Compose installs this exact outer-to-inner graph:

```text
HEAD wire boundary
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
        my ($context, $error) = @_;
        return $context->json({ error => 'request failed' });
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
use PAGI::Routing qw(router route);

my $immutable = router(routes => [
    route('/health' => sub { return $_[0]->text('ok') }),
]);

my $builder = PAGI::App::Router->new;
$builder->get('/health' => sub { return $_[0]->text('ok') });
my $builder_snapshot = $builder->to_router;

my $endpoint = MyApp::Endpoint->new(repository => $repository);
my $endpoint_snapshot = $endpoint->to_router;
```

Use `PAGI::Routing` for already-immutable composition, `PAGI::App::Router` for
incremental closure declarations, and `PAGI::Endpoint::Router` for handlers
bound to one configured object.

Why: one compiler now gives all three frontends the same matching, middleware,
metadata, reverse-routing, and Router-owned HTTP outcomes.

## App handlers now receive `$c`

**Before (removed):** an ordinary App route target was a native PAGI
application and owned all three channels.

```perl
$r->get('/people' => sub {
    my ($scope, $receive, $send) = @_;
    return send_people_response($scope, $receive, $send);
});
```

**After (shipped):** an ordinary HTTP handler receives one
`PAGI::Context::HTTP` and returns a `PAGI::Response` or a `Future` resolving to
one.

```perl
$r->get('/people' => sub {
    my ($c) = @_;
    return $c->json($repository->all_people);
});
```

Why: the shared compiler can validate and emit HTTP responses consistently
when ordinary handlers use the Context contract.

## Ask for native channels with `raw`

**Before (removed):** passing a native PAGI application as an ordinary route
target selected native channel ownership implicitly.

```perl
$r->get('/download' => $native_download_app);
```

**After (shipped):** mark native route ownership explicitly for HTTP,
WebSocket, or SSE.

```perl
$r->get('/download', raw => $native_download_app);
$r->websocket('/socket', raw => $native_socket_app);
$r->sse('/events', raw => $native_event_app);
```

Why: `raw` makes it visible that the target receives
`($scope, $receive, $send)` and emits its own protocol events.

Endpoint uses the same grammar, including after positional middleware. Use
`app_as` only when the native target is a local Endpoint method:

```perl
$r->get('/download' => [$self->middleware_as('audit')],
    raw => $self->app_as('download'));
```

The raw coderef is otherwise preserved rather than rebound. Ordinary Endpoint
method names still receive `($self, $c)`, and ordinary handler coderefs still
receive `($c)`.

## Generic `route` is path-first

**Before (removed):** the generic form put the HTTP method before the path.

```perl
$r->route('POST', '/jobs' => $job_app);
```

**After (shipped):** put the path first and supply the method set as an option.

```perl
$r->route('/jobs' => sub {
    my ($c) = @_;
    return $c->json($jobs->create($c->request));
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
$r->mount('/people', routes => sub {
    my ($people) = @_;
    $people->get('/{id}' => sub { return $_[0]->text('person') })
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
$r->mount('/api', routes => sub {
    my ($api) = @_;
    $api->get('/people' => sub { return $_[0]->json($people->all) })
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
use PAGI::Routing qw(middleware);

$r->get('/admin' => [
    'RequestId',
    $logging_factory,
    $configured_auth_object,
    middleware('Session', cookie_name => 'sid'),
] => sub { return $_[0]->text('admin') });
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

## Use lifespan state through `$c->state`

**Before (removed):** Endpoint created a private state hash and injected it
into requests.

```perl
$self->state->{database} = connect_database();
my $database = $self->state->{database};
```

**After (shipped):** let the server or `PAGI::Compose` own lifespan state and
read the supplied hash through the request Context.

```perl
use PAGI::Compose qw(compose);

my $app = compose(
    app => $endpoint->to_app,
    lifespan => {
        startup  => sub { $_[0]{database} = connect_database() },
        shutdown => sub { $_[0]{database}->disconnect },
    },
)->to_app;

sub list_people {
    my ($self, $c) = @_;
    return $c->json($c->state->{database}->people);
}
```

Why: server-owned lifespan state has an explicit startup and shutdown lifetime
and retains one identity across the requests that receive it.

## `context_class` is gone; `new_context` is local only

**Before (removed):** overriding `context_class` changed the class Endpoint
used to build Context objects for compiled handlers.

```perl
sub context_class { return 'MyApp::Context' }
```

**After (shipped):** compiled routes always receive the shared protocol-specific
Contexts, while `new_context` is only an explicit convenience helper.

```perl
my $manual_context = $endpoint->new_context($scope, $receive, $send);

$r->get('/normal' => sub {
    my ($c) = @_;  # PAGI::Context::HTTP from the shared compiler
    return $c->text('ok');
});
```

Why: removing the compiler override keeps Context construction identical across
all frontends while leaving manual Context construction available locally.

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
my $container = $c->scope->{'pagi.routing'};
die 'unsupported routing metadata' unless $container->{version} == 1;
my $current_frame = $container->{frames}[-1];
```

Prefer `$c->path_for(...)` when the goal is reverse routing rather than metadata
inspection.

Why: the frame stack and its mount ancestry can describe nested immutable
routers, captures, logical placement, and the selected leaf without mutating
shared descriptions.

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
$r->get('/tags/{name}' => sub { return $_[0]->text('tag') })
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

## Raw routes and opaque mounts are different

**Before (removed):** ordinary route targets and mounts both accepted native
applications without making their different ownership rules explicit.

```perl
$r->get('/health' => $native_health_app);
$r->mount('/legacy' => $legacy_app);
```

**After (shipped):** use an exact, method-aware raw route for one leaf and an
opaque mount for a protocol-wide prefix boundary.

```perl
$r->get('/health', raw => $native_health_app);
$r->mount('/legacy', app => $legacy_app);
```

A raw route keeps `path` and `root_path` unchanged, participates in HTTP 405
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

This distinction applies to Mount `app`, `raw`, Router `http_default`, and
Compose `app`. A package-name application is rejected synchronously rather
than guessed.

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
mount('/x', app => $app);
mount('/x', routes => sub {
    my ($child) = @_;
    $child->get('/' => sub { return $_[0]->text('child') });
});
```

The callback form is available in the mutable App and Endpoint frontends. It
runs once during declaration, receives a fresh child builder bound to the same
Endpoint object when applicable, and ignores its return value. Both `/x` and
`/x/` reach the child `/` leaf without redirecting.

## Deliberate Starlette differences and deferred schema work

PAGI adopts the Route/Mount/Router concepts, not Starlette API identity.
Ordinary handlers receive an explicit Context; `raw`, Mount `app`, Router
`http_default`, and Compose `app` are native three-channel application
positions. Constraints validate without coercion. Logical names use slash
addresses and relative Context lookup. SSE is first-class. Middleware is pure
PAGI app-to-app wrapping at Route, Mount, Router, and Compose boundaries.

Starlette's single multiprotocol Router `default` was considered and
deliberately not copied. PAGI's HTTP-only default preserves stock WebSocket
and SSE misses. Compose, not Router, owns root lifespan.
OpenAPI and schema support remain deferred until a concrete consumer is
designed; `schema`,
`include_in_schema`, registries, and placeholder metadata are not shipped.
