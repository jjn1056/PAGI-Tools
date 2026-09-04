# Authentication Outcomes and Challenge Construction Design

**Date:** 2026-09-04

**Status:** Draft for user review; self-reviewed against the source tree and
the cited standards/framework documentation

**Source audit base:** `main` at
`cd19251ce1e7cd9c734d4e092c77872d4e4c04c1`

**Scope:** Phase 1 of PAGI-Tools authentication work: add semantic
authentication challenge and authorization-forbid outcomes, strict Basic and
Bearer challenge construction, an extensible generic challenge builder, and a
public way to materialize a deferred Pages application as a concrete Response
for HTTP, WebSocket denial, SSE decline, or a future request-like protocol.

## 1. Decision

PAGI-Tools will add a narrow authentication-outcome layer. `PAGI::Auth` is
the exported umbrella with five opt-in factories:

```perl
use PAGI::Auth qw(
    challenge forbid
    basic bearer custom_challenge
);
```

`challenge` means that the request lacks acceptable authentication
credentials. It produces a negotiated 401 Pages application and requires at
least one structured authentication challenge:

```perl
return challenge(
    challenges => [bearer(realm => 'api')],
    detail      => 'A valid access token is required.',
);
```

`forbid` means that the authenticated identity is not authorized to perform
the operation. It produces a negotiated 403 Pages application:

```perl
return forbid(
    detail => 'You may read apples, but you may not delete them.',
);
```

OAuth Bearer insufficient-scope responses may include the corresponding
challenge:

```perl
return forbid(
    challenges => [bearer(
        realm => 'api',
        error => 'insufficient_scope',
        scope => ['apples:write'],
    )],
    detail => 'The apples:write scope is required.',
);
```

The challenge factories return immutable `PAGI::Auth::Challenge` values, not
raw strings. `PAGI::Auth` serializes those values into one
`WWW-Authenticate` field line per challenge and delegates representation,
encoding, caching, and HTTP response construction to `PAGI::Pages`.

Applications that need a configured or subclassed Pages policy use the
separate `PAGI::Auth::Outcomes` policy object. This leaves the natural
`PAGI::Auth->new($source)` constructor shape available for Phase 2's likely
identity facade.

`PAGI::Pages::Application` gains one synchronous materialization method:

```perl
my $response = $page_application->response_for($source);
```

`$source` is an unblessed scope hashref or an object with `scope()`, including
`PAGI::Request`, `PAGI::WebSocket`, and `PAGI::SSE`. It supplies request
metadata only. All response and presentation policy remains at the original
`challenge` or `forbid` call.

This gives the three first-party request protocols one outcome vocabulary:

```perl
my $failure = challenge(
    challenges => [bearer(realm => 'api')],
);

# HTTP Request handler: return the application value.
return $failure;

# WebSocket endpoint, before accept:
return await $ws->deny($failure->response_for($ws));

# SSE endpoint, before start:
return await $sse->decline($failure->response_for($sse));
```

No authentication middleware, credential parser, identity object,
authorization policy engine, or scope helper is added in this phase. Those
belong to the separately specified Phase 2 and will consume this outcome
layer rather than recreate it.

## 2. Overall goal and place in PAGI-Tools

PAGI-Tools is a toolkit beneath application frameworks. Its core request,
response, routing, and middleware pieces must remain usable independently and
must not assume one identity provider, token format, policy language, session
model, or router.

Authentication failures currently fall through the cracks between those
pieces. An application or middleware author has to remember:

- whether the condition is 401 or 403;
- when `WWW-Authenticate` is mandatory;
- how to quote Basic realms safely;
- how Bearer `invalid_token` differs from `insufficient_scope`;
- how to preserve multiple challenges as separate field lines;
- how to negotiate HTML, text, and RFC 9457 problem JSON;
- how to emit the same informational failure during a WebSocket handshake or
  before an SSE stream starts; and
- how not to leak credentials or internal validation failures in the body.

The current `PAGI::Middleware::Auth::Basic` and
`PAGI::Middleware::Auth::Bearer` each implement part of that work privately.
They also conflate credential extraction, validation, path selection, scope
state, enforcement, and rendering. Their `pagi.auth` shapes differ, their
header-selection behavior differs from `PAGI::Request`, synchronous and
Future-backed validators are not treated consistently, and the Bearer
middleware contains a deliberately limited JWT implementation. Preserving
those implementations is not the architectural goal.

This phase first extracts the stable, standards-driven part: describing an
authentication or authorization failure as an ordinary reusable PAGI
application. Phase 2 can then replace or retire the old middleware around a
normalized identity/provider contract without also inventing response policy.

The dependency direction is deliberately one-way:

```text
Phase 2 identity/provider middleware
                |
                v
       PAGI::Auth outcomes
                |
                v
          PAGI::Pages
                |
                v
          PAGI::Response
```

`PAGI::Pages`, `PAGI::Response`, `PAGI::WebSocket`, and `PAGI::SSE` do not
depend on `PAGI::Auth`. The Auth outcome packages are policy layered above the
existing response family, not a new response family and not a protocol
dispatcher.

## 3. Research that informed the design

This design follows a local source audit, an ASGI/Starlette review, and a
cross-framework review of current authentication practice.

### 3.1 HTTP standards

[RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html) defines the load-bearing
distinction:

- 401 means the request lacks valid authentication credentials and MUST carry
  at least one `WWW-Authenticate` challenge;
- 403 means the server understood the request but refuses to fulfill it,
  commonly because supplied credentials are insufficient;
- a server may use 404 instead of 403 when it wishes to conceal a resource's
  existence; and
- multiple challenges can occur, while putting each challenge on its own
  field line avoids known interoperability problems with combined values.

[RFC 7617](https://www.rfc-editor.org/rfc/rfc7617.html) defines Basic
authentication realm and optional `charset="UTF-8"` challenge parameters.

[RFC 6750](https://www.rfc-editor.org/rfc/rfc6750.html) defines Bearer
resource-error semantics:

- absent authentication normally produces 401 with a Bearer challenge and no
  error code;
- an expired, revoked, malformed, or otherwise invalid token normally
  produces 401 with `error="invalid_token"`;
- a malformed token request uses `error="invalid_request"` and normally 400;
  and
- insufficient privileges normally produce 403 with
  `error="insufficient_scope"` and may advertise the required scope.

[RFC 9470](https://www.rfc-editor.org/rfc/rfc9470.html) extends Bearer and
related OAuth challenges with `error="insufficient_user_authentication"`,
`acr_values`, and `max_age` for step-up authentication. [RFC
9728](https://www.rfc-editor.org/rfc/rfc9728.html) adds the
`resource_metadata` challenge parameter used for protected-resource metadata
discovery, including MCP authorization deployments. These extensions show
that Bearer's registered parameter and error spaces cannot be treated as
permanently closed.

[RFC 9457](https://www.rfc-editor.org/rfc/rfc9457.html) supplies the problem
JSON representation already implemented by `PAGI::Pages`. This design reuses
that representation rather than creating an authentication-specific JSON
envelope.

### 3.2 Framework practice

The review found a broad distinction between acquiring an identity and
materializing an authorization outcome:

- Starlette separates authentication backends from permission enforcement and
  exposes authentication state on the connection. Its decorator defaults to
  a 403 response and supports a custom status or redirect, but its exception
  route is not adopted here because Perl exceptions would add action at a
  distance to an ordinary response decision. See the
  [Starlette authentication documentation](https://github.com/Kludex/starlette/blob/main/docs/authentication.md).
- FastAPI changed its HTTP credential helpers in 0.122.0 from a legacy 403 to
  the standards-aligned 401 plus `WWW-Authenticate`, demonstrating that this
  distinction matters to real clients. See
  [FastAPI's compatibility note](https://fastapi.tiangolo.com/how-to/authentication-error-status-code/).
- ASP.NET Core explicitly models `Challenge` and `Forbid` authorization
  results and lets applications customize their final response through an
  authorization middleware result handler. See
  [Microsoft's authorization result documentation](https://learn.microsoft.com/en-us/aspnet/core/security/authorization/customizingauthorizationmiddlewareresponse?view=aspnetcore-10.0).
- Spring Security separates credential acquisition through an
  `AuthenticationEntryPoint` from access-denied handling. See the
  [Spring Security authentication architecture](https://docs.spring.io/spring-security/reference/servlet/authentication/architecture.html).

The common vocabulary is therefore worth adopting, but the control mechanism
must remain Perlish and PAGI-native: return an application value instead of
throwing a framework exception or mutating an ambient response.

### 3.3 PAGI protocol review

The existing protocol objects already own the difficult connection work:

- `PAGI::WebSocket->deny($response)` validates a concrete Response, uses the
  WebSocket HTTP-response extension when advertised, and otherwise performs a
  policy close;
- `PAGI::SSE->decline($response)` emits a concrete HTTP response before the
  stream starts;
- both adapters map the Response's body-event capability without changing the
  server-owned send Future; and
- their start-commit and disconnect cleanup follow the PAGI 0.5 settlement
  contract.

Authentication must not duplicate or bypass those lifecycles. Its only
missing piece is turning the same deferred informational page used by HTTP
into the concrete Response those protocol methods intentionally require.

## 4. Work map

| Repository | Work item | Branch | Base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | Phase 1 authentication outcomes and challenge construction | `feature/authentication-outcomes-phase1` | local `main` at `c4c007f7a0603c2e36cd88266f2289db4f3baa12` | This design; later `PAGI::Auth`, challenge value/builders, Pages materialization seam, tests, examples, POD, Cookbook/Tutorial, Changes | PAGI-Tools only; no PAGI specification or PAGI::Server change | Local feature branch until the user requests a PR |

The implementation plan must refresh this map against current `main` before
editing and again before push. The untracked settlement/audit notes currently
in the working tree are unrelated user files and must remain untouched.

## 5. Terminology

This design uses these terms consistently:

**Authentication** establishes who or what is making the request.

**Authorization** decides whether that identity may perform an operation.

**Challenge** is the semantic outcome that acceptable authentication is
missing. Its HTTP representation is 401 and includes one or more
`WWW-Authenticate` challenges.

**Forbid** is the semantic outcome that the request is understood but not
authorized. Its ordinary HTTP representation is 403. It does not imply that
retrying the same credentials will succeed.

**Authentication challenge value** is one structured
`PAGI::Auth::Challenge`, such as `Basic realm="Staff"` or
`Bearer realm="api"`. It is not itself a response.

**Outcome application** is the deferred HTTP-only
`PAGI::Pages::Application` returned by `challenge()` or `forbid()`.

**Materialization** is the synchronous conversion of that deferred Pages
application into one concrete `PAGI::Response` using request metadata from a
scope or protocol object. It does not emit events.

Challenge and forbid are response outcomes, not proof that authentication or
authorization middleware ran. Phase 1 never infers identity state.

## 6. Goals

The implementation must:

1. make correct 401 and 403 outcomes concise in Request handlers;
2. make malformed Basic, Bearer, and extension-scheme challenge construction
   fail before response emission;
3. preserve one wire field line per challenge in declaration order;
4. enforce the status-sensitive Bearer error distinctions from RFC 6750;
5. reuse Pages negotiation, RFC 9457 JSON, escaping, UTF-8 encoding, favicon,
   cache policy, and mandatory-header validation;
6. support HTTP, WebSocket denial, and SSE decline without protocol-specific
   auth response classes;
7. let a custom request-like protocol reuse Pages materialization later
   without making Auth or Pages aware of that protocol;
8. keep response configuration at outcome construction and request metadata
   at materialization;
9. support configured `PAGI::Pages` instances and presentation subclasses;
10. use explicit returned values rather than exceptions, ambient mutation, or
    hidden redirects;
11. keep credentials, tokens, and validator diagnostics out of generated
    response bodies and challenge fields by default; and
12. give Phase 2 one stable outcome API without constraining its identity,
    provider, or policy design.

## 7. Non-goals

Phase 1 does not:

- parse an `Authorization` field;
- decide whether duplicate credential fields are valid;
- validate a password, API key, JWT, opaque token, certificate, or session;
- fetch JWKS, rotate keys, validate OAuth issuers/audiences, or implement an
  identity provider;
- add or normalize `pagi.auth` scope state;
- define principal, claims, roles, permissions, or scope-accessor objects;
- add `has_scope`, `has_any_scope`, `has_all_scopes`, or `missing_scopes`;
- protect path prefixes or select which routes require authentication;
- preserve the current Basic/Bearer middleware as the future architecture;
- remove or redesign that middleware before Phase 2 is approved;
- add auth methods to `PAGI::Request`, `PAGI::Response`, `PAGI::WebSocket`,
  `PAGI::SSE`, Router, Route, Mount, or Compose;
- define proxy authentication (407/`Proxy-Authenticate`);
- automatically redirect browsers to a login page based on `Accept`;
- add a login route, logout route, callback route, cookie, or session policy;
- choose 404 concealment automatically;
- use exceptions as routine auth control flow;
- add an authentication challenge registry or dynamic scheme loader;
- accept arbitrary preformatted challenge strings in the semantic outcome
  API; or
- change PAGI protocol events, settlement, backpressure, disconnect, denial,
  or decline behavior.

Login redirects and concealed 404s remain explicit application policy:

```perl
return redirect('/login'); # deliberate browser flow
return not_found();        # deliberate resource concealment
```

They are not alternate spellings of `challenge()` or `forbid()`.

## 8. Public packages and exports

### 8.1 `PAGI::Auth`

`PAGI::Auth` is the functional umbrella and Exporter. It is not itself a
response-policy object. It exports nothing by default.

```perl
our @EXPORT_OK = qw(
    challenge forbid
    basic bearer custom_challenge
);

our %EXPORT_TAGS = (
    outcomes   => [qw(challenge forbid)],
    challenges => [qw(basic bearer custom_challenge)],
    all        => [@EXPORT_OK],
);
```

There is no `:common` bundle. `challenge` and `forbid` are ordinary words and
must be imported deliberately.

`PAGI::Auth` has no `new` method and is not the configured outcome-policy
object in Phase 1. This deliberately reserves the natural
`PAGI::Auth->new($source)` shape for the normalized identity facade being
considered in Phase 2. Adding response policy must not force that later helper
into an overloaded constructor.

The three-package split is intentional rather than package growth for its own
sake: `PAGI::Auth` is the opt-in functional vocabulary,
`PAGI::Auth::Outcomes` is configured response policy, and
`PAGI::Auth::Challenge` is an immutable protocol value. The Phase 2 identity
facade is an already identified ecosystem requirement analogous to the
request-bound Session, State, Stash, CSRF, and URL helpers, not a hypothetical
reason invented solely to reserve a name here.

### 8.2 `PAGI::Auth::Outcomes` and configured Pages policy

```perl
my $outcomes = PAGI::Auth::Outcomes->new(
    pages => MyApp::Pages->new(as => 'auto', default => 'json'),
);
```

The constructor accepts only optional `pages`. Its value must be a blessed
`PAGI::Pages` instance. The default is a fresh `PAGI::Pages->new` instance.
The supplied policy is retained by identity; it is not cloned, frozen, or
reconstructed. Its documented mutation and concurrency rules remain the
caller's responsibility.

The Outcomes object stores no Request, scope, credentials, identity,
receive/send callbacks, or connection state. One configured instance may
construct outcome applications concurrently.

`challenge` and `forbid` work as `PAGI::Auth::Outcomes` class or instance
methods. A class call uses a fresh default instance of the invoked class.
Exported `PAGI::Auth` functions delegate to the base
`PAGI::Auth::Outcomes` class and never infer a caller subclass.

Challenge builders work as exported functions or fully qualified
`PAGI::Auth::basic(...)`-style package functions. They do not depend
on an Outcomes instance or its retained Pages policy.

The vocabulary is deliberate: `challenge()` constructs the 401 outcome,
`challenges` supplies one or more structured values, and
`PAGI::Auth::Challenge` names that value type. The scheme-specific builders
use the shorter `basic()` and `bearer()` names so the common expression does
not read as `challenge(challenges => [bearer_challenge(...)])`. All of these
ordinary words remain opt-in exports.

Subclasses may override `new`, `challenge`, or `forbid` through ordinary Perl
inheritance. Version one adds no renderer hooks to
`PAGI::Auth::Outcomes`; visual customization belongs to the retained Pages
subclass.

### 8.3 `PAGI::Auth::Challenge`

The three challenge builders return a blessed, immutable
`PAGI::Auth::Challenge`. It exposes:

```text
scheme
header_value
```

`scheme` returns the validated authentication scheme with its declared case.
`header_value` returns the completely serialized field value.

The class does not overload stringification, hash dereference, or code
invocation. It has no public general constructor in version one. Consumers
create values through the three checked builders. This prevents an accidental
string interpolation from silently bypassing semantic validation.

Internal metadata may distinguish Basic, Bearer, and generic values so that
the outcome factory can enforce Bearer's status-sensitive rules. That metadata
is not a public registry or subclass protocol in Phase 1.

## 9. Challenge builders

### 9.1 Shared syntax rules

All challenge builders are synchronous and perform no request I/O. Invalid
input croaks at construction, before a Pages application or response event
exists.

They apply these shared rules:

- the authentication scheme and parameter names use the RFC 9110 `token`
  grammar;
- a field value may not contain CR, LF, NUL, another control character, DEL,
  or non-ASCII data;
- parameter names are compared case-insensitively and duplicates are rejected;
- parameter values are emitted as quoted strings with `\` and `"` escaped;
- output is deterministic;
- the builders never accept a complete raw `WWW-Authenticate` string; and
- no builder logs or stores credentials.

The strict ASCII rule is deliberately conservative. Authentication challenges
are protocol fields, not presentation text. Localized or rich user-facing
information belongs in the negotiated Pages `detail` and presentation hooks.

### 9.2 Basic

```perl
my $value = basic(realm => 'Staff');
# Basic realm="Staff"

my $utf8 = basic(
    realm   => 'Staff',
    charset => 'UTF-8',
);
# Basic realm="Staff", charset="UTF-8"
```

`realm` is required and must be a defined scalar satisfying the shared value
rules. An empty realm is legal but discouraged and documented as such.

`charset` is optional. When supplied, its only accepted value is the exact
case-insensitive string `UTF-8`; serialization uses `UTF-8`. The builder does
not add `charset` by default because RFC 7617 defines it as advisory and an
application should opt into the credential-decoding expectation deliberately.

No other Basic parameters are accepted. Output parameter order is `realm`,
then `charset`.

### 9.3 Bearer

```perl
my $missing = bearer(realm => 'api');

my $invalid = bearer(
    realm             => 'api',
    error             => 'invalid_token',
    error_description => 'The access token is no longer valid',
    error_uri         => 'https://example.test/docs/auth/invalid-token',
);

my $scope = bearer(
    realm => 'api',
    error => 'insufficient_scope',
    scope => ['apples:write', 'inventory:write'],
);
```

Accepted options are:

```text
realm
scope
error
error_description
error_uri
params
```

At least one of `realm`, `scope`, `error`, or one entry in `params` is required
because a Bearer challenge must contain at least one auth parameter.
`error_description` and `error_uri` require `error`.

The builder recognizes these standardized errors and retains their outcome
semantics:

```text
invalid_request
invalid_token
insufficient_scope
insufficient_user_authentication
```

Another `error` value is accepted as an extension when it is a nonempty RFC
9110 token. Unknown extension errors are structurally valid but carry no
status classification known to PAGI-Tools. They therefore do not receive
outcome-specific rejection beyond the rules for the standardized errors.
This keeps future standards and private profiles usable without making the
generic builder an unchecked Bearer escape hatch.

`scope` must be a nonempty arrayref of unique, nonempty scope tokens. Scope
tokens are case-sensitive, so only exact duplicates are rejected. Each
token contains only `%x21 / %x23-5B / %x5D-7E`, as required by RFC 6750; in
particular, it contains no ASCII space, quote, backslash, control character,
DEL, or non-ASCII data. The serialized parameter joins the values with one
ASCII space while preserving declaration order. Duplicate tokens croak rather
than being silently removed.

The four recognized `error` values satisfy the token grammar. An extension
error must satisfy that grammar explicitly. `error_description` contains only
`%x20-21 / %x23-5B / %x5D-7E`. `error_uri` contains only
`%x21 / %x23-5B / %x5D-7E` and must be a syntactically valid absolute URI.
RFC 6750's ABNF admits a URI-reference while its semantic prose describes an
absolute URI identifying a human-readable page. This API deliberately accepts
the useful, unambiguous absolute-URI subset. The builder does not fetch or
dereference it.

`params` is an optional nonempty unblessed hashref for registered or private
Bearer extensions. Parameter names use the RFC 9110 token grammar and may not
collide case-insensitively with `realm`, `scope`, `error`,
`error_description`, or `error_uri`. Keys that differ only by case croak.
Values must be defined non-reference ASCII scalars satisfying the shared
quoted-string safety rules; serialization always quotes and escapes them.
PAGI-Tools validates the generic field shape but does not invent semantic
validation for an extension it does not own.

For example, current standards can be represented without bypassing Bearer
validation:

```perl
my $step_up = bearer(
    realm  => 'api',
    error  => 'insufficient_user_authentication',
    params => {
        acr_values => 'urn:example:strong',
        max_age    => 300,
        resource_metadata =>
            'https://api.example/.well-known/oauth-protected-resource',
    },
);
```

The caller remains responsible for extension-specific requirements. For
example, RFC 9470 requires `max_age` to represent a nonnegative integer, and
RFC 9728 defines the meaning and URL requirements of `resource_metadata`.

First-party parameter order is always:

```text
realm, scope, error, error_description, error_uri
```

Extension parameters follow in case-insensitive ASCII lexical order. Order has
no semantic meaning but stable output improves diagnostics and tests.

### 9.4 Generic extension scheme

```perl
my $demo = custom_challenge(
    scheme => 'DemoToken',
    params => {
        realm => 'demo',
        mode  => 'interactive',
    },
);
# DemoToken mode="interactive", realm="demo"

my $negotiate = custom_challenge(
    scheme  => 'Negotiate',
    token68 => $opaque_challenge_data,
);

my $bare = custom_challenge(scheme => 'Mutual');
```

`scheme` is required. `params` is an optional nonempty unblessed hashref.
`token68` is an optional nonempty scalar following RFC 9110's `token68`
grammar. `params` and `token68` are mutually exclusive. Omitted `params` and
`token68` produce a bare scheme challenge; explicitly supplying an empty
`params` hash croaks rather than silently becoming the omitted form.

`scheme` must not be `Basic` or `Bearer`, compared case-insensitively. Those
schemes have strict first-party builders and using the generic path would
silently bypass their scheme-specific validation. Bearer extensions use the
checked `params` and open-error seams on `bearer()` rather than the generic
builder.

Generic parameters are serialized in case-insensitive ASCII lexical order.
Keys that differ only by case croak. The builder always quotes parameter
values; it does not attempt to infer whether token notation would be shorter.

This is the explicit extension seam for custom registered or private schemes.
There is no registry, package lookup, fallback method, or automatic loader.
Basic and Bearer callers should use their strict builders so the additional
scheme-specific validation remains available.

## 10. Outcome factories

### 10.1 Shared options

`challenge` and `forbid` accept these Pages presentation options:

```text
as
detail
type
title
instance
extensions
headers
cache_control
```

Their meanings and validation are exactly the corresponding `PAGI::Pages`
error options. The factories do not reimplement them.

Both additionally accept:

```text
challenges
```

`challenges` may be one `PAGI::Auth::Challenge` or a nonempty arrayref of
those values. Array order becomes `WWW-Authenticate` field-line order.
Undefined values, raw strings, unblessed hashes, empty arrays, nested arrays,
and other blessed objects croak with a diagnostic naming the option and
position.

The `headers` option must not contain `WWW-Authenticate` in either factory.
The semantic challenge list is the sole owner of that field. Applications
that intentionally need a raw or unusual status/header combination may use
`PAGI::Pages` or a Response directly; that is the explicit lower-level escape
hatch.

Internally, `forbid` serializes its checked challenge values and supplies the
resulting repeated `WWW-Authenticate` pairs through Pages' ordinary `headers`
path because Pages only synthesizes challenges itself for statuses 401 and
407. This internal use does not reopen the field to callers: caller headers
are validated first, and only Auth's structured values may add the field.

Neither factory accepts `status`, Pages' singular `challenge` option, or proxy
authentication options.

### 10.2 Challenge outcome

```perl
my $application = challenge(
    challenges => [
        basic(realm => 'Staff'),
        bearer(realm => 'api'),
    ],
    detail => 'Authenticate using either supported scheme.',
);
```

`challenge` requires `challenges` and fixes status 401. It serializes each
structured value separately and calls the retained Pages policy's
`unauthorized` factory. Pages continues to enforce that 401 has at least one
challenge.

For a Bearer value used in `challenge`:

- an absent `error` is valid and is the normal missing-credentials response;
- `error="invalid_token"` is valid;
- `error="insufficient_user_authentication"` is valid for a step-up
  authentication challenge;
- `error="invalid_request"` croaks and directs the caller to an explicit 400
  response; and
- `error="insufficient_scope"` croaks and directs the caller to `forbid`;
  and
- an unknown extension error is accepted because Auth cannot infer the status
  semantics of a future standard or private profile.

The default title and detail come from Pages' 401 catalog. The factory does
not mention whether credentials were absent, expired, revoked, or malformed
unless the caller deliberately selects the corresponding safe Bearer error or
supplies presentation detail.

### 10.3 Forbid outcome

```perl
my $application = forbid(
    detail => 'This account cannot delete apples.',
);
```

`forbid` fixes status 403. `challenges` is optional because general
authorization failure does not require a `WWW-Authenticate` field.

When a Bearer challenge is supplied to `forbid`, it must use
`error="insufficient_scope"` or an unknown extension error whose defining
profile assigns 403 semantics. A Bearer challenge with no error,
`invalid_token`, `invalid_request`, or `insufficient_user_authentication`
croaks with a diagnostic naming the correct outcome/status. Generic and Basic
challenges remain syntactically legal because RFC 9110 permits
`WWW-Authenticate` on responses other than 401 when different credentials
might affect the response. Their use on 403 is deliberately explicit and
documented as uncommon. Auth validates the status semantics it knows; an
application using an extension error owns that extension's status rules.

The default title and detail come from Pages' 403 catalog.

### 10.4 Returned value

Both factories return an ordinary reusable `PAGI::Pages::Application` app
object. They never return a concrete Response eagerly because representation
selection depends on the later request scope.

In a Request handler:

```perl
async sub delete_apple ($request) {
    return forbid(detail => 'Apple deletion is not permitted.')
        unless current_user_may_delete($request);

    return json_response({ success => \1 });
}
```

In a native three-argument PAGI app:

```perl
use Future::AsyncAwait;
use PAGI::Auth qw(challenge bearer);
use PAGI::Utils qw(invoke_app);

my $app = async sub ($scope, $receive, $send) {
    return await invoke_app(
        challenge(challenges => [bearer(realm => 'api')]),
        $scope, $receive, $send,
    );
};
```

The second spelling is intentionally the ordinary application-invocation
escape hatch. Auth does not add `respond`, `send`, or another emission method.

## 11. Pages materialization

### 11.1 Public method

`PAGI::Pages::Application` gains:

```perl
my $response = $application->response_for($source);
```

It requires exactly one source. The source is either:

- an unblessed scope hashref; or
- a blessed object whose `scope()` method returns an unblessed scope hashref.

The scope must contain a defined, non-reference, nonempty `type`. A lifespan
scope is rejected because it is lifecycle control rather than a request.
HTTP, WebSocket, SSE, and unknown/custom request-like types are otherwise
accepted. Acceptance of a custom type does not imply that any first-party
protocol object can emit the resulting Response; the custom protocol owns
that adapter.

This follows the existing `PAGI::Utils::Scope::scope_from_source` convention.
That helper resolves a source but does not validate its protocol type. The
shared internal Pages materialization operation must use it for source
resolution and then own the type/lifespan validation described above. Neither
`response_for` nor `to_app` may grow a separate source grammar.

### 11.2 Behavior

`response_for` synchronously:

1. resolves the source scope;
2. calls the retained descriptor factory once with the original source scope;
3. derives an HTTP metadata view for Pages negotiation and validation;
4. calls the retained Pages policy once; and
5. returns one fresh concrete `PAGI::Response` subclass.

For an HTTP source the metadata view is the original scope. For another
request-like protocol it is a shallow top-level view in which `type` is
`http`; `method` preserves an existing defined non-reference scalar and
otherwise becomes `GET`; and `path` preserves an existing defined
non-reference scalar and otherwise becomes `/`.

All other scope entries, including repeated headers, query string, scheme,
authority data, extensions, and routing metadata, remain available. The
original scope is never mutated. The shallow metadata view does not clone or
freeze nested values; request metadata is caller-owned under the ordinary
PAGI rules.

One derived cache is deliberately invalidated in a synthesized non-HTTP view:
`pagi.request.headers` is omitted. `PAGI::Request` caches a `PAGI::Headers`
there, while the current WebSocket and SSE accessors cache a
`Hash::MultiValue` under the same key. A protocol-specific cached facade is
not valid after the view changes the scope to HTTP. Pages therefore rebuilds
the HTTP header facade from the retained raw repeated header pairs. The
original protocol scope and its cache are unchanged.

`response_for` performs no receive, send, filesystem, network, session,
credential, or other asynchronous I/O. A descriptor or renderer returning a
Future continues to croak under the existing synchronous Pages contract.

Every call creates a fresh descriptor and concrete Response. There is no
scope cache, helper-object cache, identity guarantee, or response reuse.

### 11.3 No materialization options

The complete signature is exactly:

```perl
$application->response_for($source)
```

It accepts no `%options`. Request information comes from the source;
presentation and auth policy come from the original factory:

```perl
my $failure = challenge(
    challenges => [bearer(realm => 'api')],
    as          => 'json',
    detail      => 'A token is required.',
);

my $response = $failure->response_for($ws);
```

Allowing late `as`, `detail`, header, or challenge overrides would create two
configuration sites and unclear precedence. A caller that needs another
representation constructs another outcome application.

WebSocket clients often provide no useful `Accept` field. SSE clients often
send `Accept: text/event-stream`, which Pages cannot itself render. In both
cases the existing Pages total-rejection rule chooses the configured default
representation. Applications may select `as => 'json'` or `as => 'text'` at
outcome construction when they require a fixed denial format.

### 11.4 One implementation path

`PAGI::Pages::Application->to_app` remains HTTP-only. Its returned app must use
the same internal materialization operation as `response_for`, then delegate
the concrete Response through `PAGI::Utils::invoke_app`. The shared operation
owns source resolution, required scalar type validation, lifespan rejection,
descriptor creation, metadata-view construction, and response construction.
The `to_app` entry point adds only its narrower exact-HTTP requirement before
invoking that operation.

The implementation must not maintain two descriptor/response construction
paths. `response_for` exposes an operation Pages already performs privately;
it does not introduce a second response model.

The method is intentionally specific to deferred Pages applications. This
phase does not add a universal `to_response` protocol to all app objects.

`PAGI::Response::_respond_for_protocol` also derives an HTTP-shaped scope, but
for a different purpose: it maps an already concrete Response into a protocol
denial/decline event family. It does not perform Pages negotiation or
descriptor construction and must not depend on Pages. The two internal views
remain separate so the one-way `Auth -> Pages -> Response` dependency is not
reversed; the implementation and POD must state this distinction rather than
claim that every HTTP-shaped internal scope has one owner.

## 12. Protocol use

### 12.1 HTTP

A Request handler returns the outcome application directly:

```perl
async sub account ($request) {
    return challenge(
        challenges => [basic(realm => 'Accounts')],
    ) unless authenticated($request);

    return html_response('<h1>Account</h1>');
}
```

RequestResponse invokes the returned app against the original HTTP triplet.
Pages negotiates at that point. No eager concrete Response or outcome object
bound to the Request is required.

### 12.2 WebSocket

An endpoint must deny before `accept`:

```perl
async sub handle ($self, $ws) {
    unless ($self->may_connect($ws)) {
        my $failure = challenge(
            challenges => [bearer(realm => 'chat')],
            as          => 'json',
        );
        return await $ws->deny($failure->response_for($ws));
    }

    await $ws->accept;
    # ... normal socket lifecycle ...
}
```

`response_for` supplies only the concrete Response. `deny` remains responsible
for capability validation, WebSocket HTTP-response event mapping,
start-commit state, send-Future settlement, disconnect observation, close
callbacks, and fallback policy close when the server lacks the denial
extension.

A mapped body send parked on server backpressure may resolve during
disconnect under the PAGI settlement contract. Auth cleanup must therefore
remain keyed to WebSocket disconnect/close state, not inferred from a failed
send Future. This design adds no competing watcher or lifecycle.

### 12.3 SSE

An endpoint must decline before stream start:

```perl
async sub handle ($self, $sse) {
    unless ($self->may_subscribe($sse)) {
        my $failure = forbid(
            detail => 'This account cannot subscribe to the audit stream.',
            as     => 'text',
        );
        return await $sse->decline($failure->response_for($sse));
    }

    await $sse->start;
    # ... normal stream lifecycle ...
}
```

`decline` retains ownership of SSE HTTP-response event mapping, start-commit
state, keepalive cleanup, send-Future settlement, disconnect observation, and
close callbacks. Auth adds no SSE event, retry, reconnection, or keepalive
behavior.

### 12.4 Concrete-response capability

`deny` and `decline` continue requiring a nominal concrete `PAGI::Response`
with the `body-events-v1` protocol response capability. Pages currently
selects `Empty`, `HTML`, `JSON`, `Problem`, or `Text`, all of which satisfy
that contract.

They do not detect and invoke arbitrary objects that happen to provide
`response_for`. That convenience would establish a new deferred-response
protocol inside two lifecycle-sensitive adapters and couple them to Pages-like
materialization. The explicit `response_for($ws)` or `response_for($sse)` call
keeps the transition from deferred application to concrete Response visible;
`deny` and `decline` continue owning emission only.

`PAGI::Response::File` deliberately opts out. The PAGI denial-response
definitions permit only body events and do not use file/fh forms. This phase
does not weaken that rule or teach protocol adapters to read files.

The `on_start_committed` point remains send-Future resolution for the mapped
response-start event. Under PAGI 0.5 that means the server validated and
accepted the event and the denial owns the response slot; it does not mean the
client received the bytes.

## 13. Status and challenge matrix

| Situation | Outcome | Status | Challenge rule |
| --- | --- | --- | --- |
| No credentials supplied | `challenge` | 401 | Bearer challenge has no `error`; Basic or generic also allowed |
| Unsupported auth scheme | `challenge` | 401 | Applicable challenges, no Bearer error information |
| Expired/revoked/invalid Bearer token | `challenge` | 401 | Bearer `error="invalid_token"` |
| Valid token needs stronger or more recent user authentication | `challenge` | 401 | Bearer `error="insufficient_user_authentication"`, with applicable extension parameters |
| Malformed Bearer transport/request | explicit Pages/Response | 400 | Bearer `error="invalid_request"`; not represented by `challenge` |
| Authenticated but generally unauthorized | `forbid` | 403 | No challenge required |
| Bearer token lacks required scope | `forbid` | 403 | Bearer `error="insufficient_scope"`, optional required `scope` |
| Extension-defined Bearer failure | defining profile decides | profile-defined | Builder validates generic syntax; application owns extension semantics not known to PAGI-Tools |
| Conceal protected resource | explicit `not_found()` | 404 | Application policy; not inferred by Auth |
| Interactive login flow | explicit `redirect()` | chosen 3xx | Application policy; never selected from `Accept` |
| Credential provider/database/network failure | throw/fail | 500 path | Operational error, not challenge or forbid |

The last row is important for Phase 2: invalid credentials are an expected
authentication result; an unavailable identity provider is an application
failure. A middleware must not turn operational failure into a misleading 401.

## 14. Validation and failure behavior

All constructor, builder, option, and cross-outcome validation happens
synchronously before any response event is emitted. Diagnostics must identify:

- the public factory;
- the invalid option or challenge position;
- the expected shape or allowed value; and
- when applicable, the correct outcome/status.

Examples:

```text
PAGI::Auth basic requires realm
PAGI::Auth bearer extension error must use the token grammar
PAGI::Auth challenge challenges[1] must be a PAGI::Auth::Challenge
PAGI::Auth challenge cannot use Bearer insufficient_scope; use forbid
PAGI::Auth forbid Bearer challenge requires error=insufficient_scope
PAGI::Pages::Application response_for does not accept a lifespan scope
```

No constructor silently drops an unknown option, normalizes an unknown Bearer
error, combines duplicate scope tokens, accepts a Future, calls an object
stringifier, or falls back from an invalid structured challenge to a raw
string.

Renderer or policy exceptions propagate normally. In a composed HTTP root,
the existing ErrorHandler owns safe 500 behavior. A failure before WebSocket
denial or SSE decline start leaves the existing protocol object pending under
its current state machine. A failure after response-start commit follows the
existing report/rethrow and settlement rules. Auth does not catch, replace, or
reinterpret those errors.

## 15. Security considerations

### 15.1 Header safety

Challenge builders own authentication field serialization. They reject CRLF,
control characters, malformed token/token68 syntax, case-insensitive duplicate
parameters, malformed Bearer fields, and invalid error URIs before the field
reaches `PAGI::Headers` or a server. Bearer extension parameters pass through
the same checked name, value, quoting, and collision rules; the escape hatch
is extensible but not raw.

Each challenge becomes a separate field line. Auth never joins challenge
values with commas because commas also separate auth parameters and combined
challenge parsing has known interoperability problems.

### 15.2 Information disclosure

`challenge` and `forbid` do not accept or inspect raw credentials. The default
body never contains a password, token, claims, authorization field, validator
exception, filesystem path, stack trace, or identity-provider response.

`error_description` is public protocol text. Callers must not place secrets or
internal diagnostics in it. The strict Bearer builder validates syntax but
cannot determine whether prose is sensitive; the POD must say so directly.

Detailed authentication failure reasons may help an attacker distinguish an
unknown account, wrong password, expired credential, or disabled identity.
The default Pages details remain deliberately generic. More specific details
are an explicit caller decision.

### 15.3 Caching and transport

The outcome layer inherits Pages' `Cache-Control: no-store` default for error
responses. A caller may use the existing Pages `cache_control` option only
under its normal validation; authentication documentation recommends keeping
`no-store`.

Basic authentication must be used over TLS. Bearer tokens must be protected
in transit and must not be placed in URLs or logs. Those requirements are
documented even though credential handling itself belongs to Phase 2.

### 15.4 Authorization concealment

The toolkit does not automatically replace 403 with 404. Resource-existence
concealment is domain policy and may affect observability, caching, and client
behavior. An application that needs it returns `not_found()` deliberately.

## 16. Subclassing and extension

### 16.1 Presentation extension

An application customizes auth pages with an ordinary Pages subclass:

```perl
package MyApp::Pages;
use parent 'PAGI::Pages';

sub render_problem {
    my ($self, $page) = @_;
    return {
        code    => 'AUTH_' . $page->{status},
        message => $page->{detail},
    };
}

my $outcomes = PAGI::Auth::Outcomes->new(
    pages => MyApp::Pages->new(as => 'json'),
);

return $outcomes->challenge(
    challenges => [bearer(realm => 'api')],
);
```

Auth does not copy Pages' renderer hooks or add parallel JSON/HTML callbacks.

### 16.2 Authentication-scheme extension

A custom scheme uses `custom_challenge`:

```perl
my $value = custom_challenge(
    scheme => 'CompanySignature',
    params => {
        realm     => 'billing',
        algorithm => 'ed25519',
    },
);

return challenge(challenges => [$value]);
```

If a scheme needs validation more specific than the generic token and quoted
parameter grammar, its distribution should provide its own builder that
ultimately delegates to `custom_challenge`. Phase 1 does not make
`PAGI::Auth::Challenge` subclassing a public extension contract.

### 16.3 Protocol extension

A future `mcp`, `jsonrpc`, or application-defined request-like protocol may
call `response_for($custom_protocol_object)` to obtain the same concrete HTTP
representation, then adapt that Response through its own explicitly defined
denial/error channel. Pages does not load the protocol class and Auth does not
interpret its events.

This is intentionally asymmetric: materializing a representation is generic;
emitting it safely is protocol-specific.

## 17. Relationship to existing authentication code

Phase 1 is additive. It does not claim that the existing
`PAGI::Middleware::Auth::Basic` and `PAGI::Middleware::Auth::Bearer` are the
future provider architecture, and it does not expand their contracts.

The implementation may make a narrowly mechanical replacement of their
private challenge-string formatting with the new builders only if it does not
change credential extraction, validator execution, scope state, path
selection, or async behavior. The implementation plan must treat that as an
optional isolated task with focused tests, not as implicit middleware redesign.
Leaving the middleware unchanged until Phase 2 is acceptable and is the
preferred low-risk default.

The documentation must distinguish:

- `PAGI::Auth`, which constructs authentication/authorization outcomes; and
- `PAGI::Middleware::Auth::*`, which currently attempts credential
  authentication and enforcement.

Phase 2 will audit whether to replace or remove the middleware outright. No
Phase 1 compatibility promise prevents that decision.

## 18. Phase 2 dependency boundary

The separate Phase 2 spec will define:

- one normalized auth state and identity contract;
- absent, authenticated, and invalid-credential states;
- credential extractor and verifier/provider responsibilities;
- duplicate Authorization handling;
- immediate and Future-backed verifier results;
- HTTP, WebSocket, and SSE scope installation;
- roles, permissions, and scope helpers, including exact semantics for
  `has_scope`, `has_any_scope`, `has_all_scopes`, and `missing_scopes`;
- operational-error propagation;
- middleware placement and route-boundary use;
- raw-token retention/redaction policy;
- migration or removal of the existing Basic/Bearer middleware; and
- an upgrading guide for current users.

Phase 2 must consume `challenge()` and `forbid()` for default outcomes or
accept caller-supplied application values with equivalent roles. It must not
copy Basic/Bearer serialization or Pages response rendering.

This spec does not predetermine whether Phase 2 uses one middleware class,
separate extractor/provider middleware, or framework-layer policy adapters.
That question remains open for the Phase 2 design review.

## 19. Documentation and examples

### 19.1 Complete migrated flagship application

The public API is not review-ready without the complete migrated flagship
application. `examples/starlette-apples/app.pl` becomes the following program.
Its `/apples/auth-required` route deliberately demonstrates only Phase 1's
outcome construction: it always returns a challenge and does not pretend to
parse or verify credentials. The existing CRUD behavior remains unchanged;
Phase 2 will provide the identity/provider layer that can select this outcome
from real authentication state.

```perl
#!/usr/bin/env perl
use v5.40;

use Future::AsyncAwait;
use Types::Standard qw(Int);

use AppleApp::Middleware qw(with_apples_api_header);
use AppleApp::Model qw(apple_model);
use PAGI::Auth qw(challenge bearer);
use PAGI::Compose qw(compose);
use PAGI::Pages qw(welcome not_found);
use PAGI::Response qw(file_response json_response ndjson_response);
use PAGI::Routing qw(route mount middleware);
use PAGI::Routing::URL qw(url_for path_for);
use PAGI::Utils qw(app_path);

my $manager_file = app_path('public', 'index.html');

sub startup($state, $scope) {
    $state->{apples} = apple_model();
    return;
}

sub apples($request) {
    my $state = $request->state
        or die 'starlette-apples requires Compose lifespan state';
    return $state->get('apples');
}

async sub list_apples($request) {
    my $apples = apples($request);

    return json_response([
        map {
            +{
                %$_,
                url => url_for(
                    $request,
                    'read',
                    { apple_id => $_->{id} },
                ),
            }
        } @{$apples->all}
    ]);
}

async sub export_apples($request) {
    my $items = apples($request)->all;

    return ndjson_response(async sub ($writer) {
        for my $apple (@$items) {
            last if $writer->is_disconnected;
            await $writer->write_item($apple);
        }
    });
}

async sub read_apple($request) {
    my $id = $request->path_param('apple_id');
    my $apple = apples($request)->find($id);

    return json_response($apple) if $apple;
    return json_response(
        { error => 'Apple not found' },
        status => 404,
    );
}

async sub create_apple($request) {
    my $data = await $request->json;
    my $apple = apples($request)->create($data);

    return json_response(
        $apple,
        status  => 201,
        headers => [
            Location => path_for(
                $request,
                'read',
                { apple_id => $apple->{id} },
            ),
        ],
    );
}

async sub update_apple($request) {
    my $id = $request->path_param('apple_id');
    my $apples = apples($request);

    return json_response(
        { error => 'Apple not found' },
        status => 404,
    ) unless $apples->find($id);

    my $data = await $request->json;
    my $apple = $apples->update($id, $data);

    return json_response(
        { error => 'Apple not found' },
        status => 404,
    ) unless $apple;

    return json_response($apple);
}

async sub delete_apple($request) {
    my $id = $request->path_param('apple_id');
    my $apple = apples($request)->delete($id);

    return json_response(
        { error => 'Apple not found' },
        status => 404,
    ) unless $apple;

    return json_response({
        success => \1,
        deleted => $apple,
    });
}

async sub authentication_required($request) {
    return challenge(
        challenges => [bearer(realm => 'apples')],
        detail      => 'A valid access token is required.',
    );
}

compose(
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
                route('/export' => \&export_apples,
                    methods => ['GET'], name => 'export'),
                route('/auth-required' => \&authentication_required,
                    methods => ['GET'], name => 'auth_required'),
                route('/{apple_id:&Int}' => \&read_apple,
                    methods => ['GET'], name => 'read'),
                route('/{apple_id:&Int}' => \&update_apple,
                    methods => ['PUT'], name => 'update'),
                route('/{apple_id:&Int}' => \&delete_apple,
                    methods => ['DELETE'], name => 'delete'),
            ],
            name       => 'apples',
            middleware => [middleware(\&with_apples_api_header)],
        ),
    ],
    http_default => not_found(
        detail => 'That page does not exist in the Apple demo.',
    ),
    middleware => [middleware('RequestId')],
    lifespan => { startup => \&startup },
    desc     => 'Starlette apples comparison application',
);
```

The example README must identify `/apples/auth-required` as an outcome-only
demonstration, show its separate `WWW-Authenticate: Bearer realm="apples"`
field, and point forward to Phase 2 rather than teaching ad hoc credential
parsing in a handler. Its Test Client coverage must exercise the route in
HTML, text, and problem-JSON forms while retaining the existing CRUD,
streaming, middleware, URL-generation, and lifespan coverage.

### 19.2 Remaining documentation and examples

Implementation updates must include:

1. complete `PAGI::Auth` POD covering every exported factory, validation
   rule, status mapping, and export tag;
2. `PAGI::Auth::Outcomes` POD covering configured Pages policy, class and
   instance invocation, and every outcome option;
3. `PAGI::Auth::Challenge` POD explaining that the value is structured,
   immutable, non-stringifying, and not a response;
4. `PAGI::Pages::Application` POD for `response_for`, including exactly what
   it does and does not do in the response lifecycle;
5. cross-links from `PAGI::Pages`, `PAGI::Response`, `PAGI::WebSocket::deny`,
   and `PAGI::SSE::decline`;
6. Cookbook recipes for HTTP Basic challenge, Bearer missing token, Bearer
   invalid token, insufficient scope, multiple challenges, explicit login
   redirect, deliberate 404 concealment, WebSocket denial, and SSE decline;
7. a concise Tutorial example that uses the high-level outcome without
   teaching credential validation prematurely;
8. one runnable example that exercises HTTP, WebSocket, and SSE outcomes with
   PAGI Test Client coverage;
9. an example of configured custom Pages presentation; and
10. `Changes` and any appropriate distribution metadata.

The existing SSE authorization recipe near
`PAGI::Tools::Cookbook`'s event-source examples currently declines with a bare
401 text response and no `WWW-Authenticate` field. It must be migrated to the
structured Auth outcome path and retained as an explicit regression example.

Examples must say whether a snippet is an HTTP Request handler, WebSocket
endpoint, SSE endpoint, or native three-argument PAGI app. They must not mix
those invocation shapes without naming the adapter.

The docs must also explain that `response_for` only sets up a concrete local
Response. It does not send response events. `deny`, `decline`, or
`invoke_app` owns actual emission depending on the surrounding lifecycle.

## 20. Verification requirements

The implementation plan must include focused tests for these observable
outcomes.

### 20.1 Challenge builders

- Basic realm quoting and optional UTF-8 charset;
- required, unknown, duplicate, reference-valued, control-character, DEL,
  non-ASCII, and malformed options;
- Bearer deterministic parameter order;
- all three RFC 6750 Bearer error codes, RFC 9470
  `insufficient_user_authentication`, an unknown extension error, and every
  cross-option dependency;
- scope order, duplicate rejection, and grammar;
- error-description grammar and the deliberate absolute error-URI rule;
- extension parameter name/value grammar, reserved-name collision,
  case-insensitive duplicate rejection, deterministic ordering, and the
  at-least-one-parameter rule;
- RFC 9470 and RFC 9728 extension examples without bypassing the Bearer
  builder;
- generic bare scheme, parameter, and token68 forms;
- params/token68 exclusivity and case-insensitive duplicate keys; and
- immutable value accessors with no stringification overload.

### 20.2 Outcomes

- one structured challenge and multiple challenges;
- separate `WWW-Authenticate` field lines in declaration order;
- 401 always has at least one challenge;
- 403 works without a challenge;
- known Bearer status/error matrix enforcement and explicit non-inference for
  unknown extension errors;
- raw `WWW-Authenticate` rejection in `headers`;
- Auth-owned 403 challenges passing through Pages' repeated raw-header path
  without admitting caller-owned `WWW-Authenticate`;
- configured Pages instance and subclass identity;
- HTML, text, and RFC 9457 JSON negotiation;
- fixed `as`, repeated Accept fields, total rejection, `Vary: Accept`, and
  `Cache-Control: no-store`;
- immediate construction with no request I/O; and
- reusable outcome applications under concurrent requests.

### 20.3 Materialization

- unblessed HTTP, WebSocket, SSE, and custom typed scope sources;
- `PAGI::Request`, `PAGI::WebSocket`, `PAGI::SSE`, and a custom object with
  `scope()`;
- missing/invalid type, blessed scope, invalid source, throwing `scope()`, and
  lifespan rejection;
- exactly one descriptor and policy call per materialization;
- fresh concrete Responses from repeated calls;
- no source mutation and correct HTTP metadata defaults;
- WebSocket and SSE `headers()` called before `response_for`, proving that the
  protocol-specific `pagi.request.headers` cache is omitted from the
  synthesized HTTP view and raw repeated headers are rebuilt correctly;
- no options accepted by `response_for`;
- Future-returning descriptor/renderer rejection; and
- `to_app` and `response_for` sharing one materialization path.

### 20.4 Protocol integration

- HTTP Request handler return and native `invoke_app` use;
- WebSocket denial with and without the server denial-response extension;
- SSE decline before start;
- negotiated/default/fixed representations from protocol headers;
- concrete Response capability validation;
- start-send failure leaves WebSocket/SSE pending and retryable;
- response-start commit owns the denial/decline slot;
- body send/backpressure/disconnect follows the existing settlement contract;
- terminal close/callback behavior remains unchanged; and
- no auth-specific receive loop, close watcher, buffering, or event mapping.

### 20.5 Regression boundary

Focused suites for Pages, Response, WebSocket, SSE, RequestResponse, Compose,
and existing authentication middleware must pass. The full distribution suite
must pass once at the final campaign boundary. PAGI specification and
PAGI::Server suites are not in scope because this feature consumes existing
protocol contracts without changing them.

The complete `examples/starlette-apples/app.pl` source in section 19.1 must be
kept in lockstep with the installed example. Its existing Test Client suite
must retain every prior behavior and add negotiated coverage for the
`/apples/auth-required` outcome demonstration. The Cookbook SSE recipe must
also prove that a declined 401 carries a structured `WWW-Authenticate` field.

## 21. Stop conditions

Implementation stops for design review if it appears to require:

- changes to PAGI events or PAGI::Server;
- a second WebSocket/SSE denial state machine;
- copying or intercepting send Futures outside the existing adapters;
- a universal app-to-Response coercion protocol;
- response-body replay or buffering;
- auth methods on Request, Response, WebSocket, or SSE;
- an ambient/global Pages policy;
- a challenge registry, dynamic package loading, or arity inspection;
- exceptions as expected challenge/forbid flow;
- preserving the current auth middleware through special cases;
- protocol-specific options on `response_for`; or
- several class-specific hacks merely to make Pages materialization work.

If the public `response_for` seam cannot be implemented by exposing Pages'
existing descriptor-to-Response operation cleanly, the seam is wrong and must
be reconsidered rather than forced through cloning, hidden caches, or
duplicated rendering paths.

## 22. Alternatives considered

### 22.1 Put helpers on Response

Rejected. Challenge and forbid combine status semantics, scheme construction,
and presentation policy. `PAGI::Response` should remain the literal wire-value
family, not become an authentication policy catalog.

### 22.2 Put helpers on Request or protocol objects

Rejected. `$request->challenge`, `$ws->challenge`, and `$sse->forbid` make a
response policy appear intrinsic to those objects and duplicate capability
across protocol classes. Explicit imports reveal ownership and remain usable
from raw PAGI code.

### 22.3 Put everything in authentication middleware

Rejected. Applications, endpoints, and future middleware need the same
outcomes. Coupling construction to enforcement recreates the current
Basic/Bearer problem and prevents reuse at route or protocol boundaries.

### 22.4 Return raw header strings

Rejected. A raw string loses scheme identity before status-sensitive Bearer
validation, encourages hand-built quoting, and cannot distinguish a generic
extension from a malformed Basic/Bearer value. The small value object keeps
the semantic information until response construction.

### 22.5 Add exceptions such as `AuthenticationRequired`

Rejected for Phase 1. Exceptions can be useful in languages and frameworks
whose complete middleware stack standardizes typed exception dispatch. In
Perl they would create action at a distance, depend on exception class
conventions, complicate already-started response behavior, and obscure which
boundary owns rendering. Returning an app value is explicit and matches the
new PAGI-Tools handler contract.

### 22.6 Automatically redirect HTML clients

Rejected. `Accept: text/html` does not prove that an interactive login flow is
appropriate, safe, or available. APIs, browser fetches, WebSockets, and SSE
can all carry browser-like headers. Redirect is a distinct explicit outcome.

### 22.7 Configure representation during `response_for`

Rejected. That creates two policy sites and precedence rules for a method whose
job is only request-local materialization. Construct the desired outcome once,
then materialize it against any source.

### 22.8 One combined Phase 1 and Phase 2 campaign

Rejected. Challenge serialization and outcome materialization are
standards-driven and independently useful. Identity/provider middleware has a
larger and more application-sensitive design space. Separate specs let Phase 1
land as a stable dependency and keep Phase 2 from becoming another oversized
compatibility campaign.

### 22.9 Make WebSocket and SSE materialize deferred outcomes implicitly

Rejected for Phase 1. Letting `deny` or `decline` call any object that happens
to provide `response_for` would introduce a new duck-typed deferred-response
protocol inside lifecycle-sensitive adapters. The explicit
`$failure->response_for($ws)` or `$failure->response_for($sse)` step is slightly
longer but makes materialization visible and leaves those adapters responsible
only for validating and emitting concrete Responses. This can be revisited
after real use demonstrates that the explicit boundary is recurring ceremony.

### 22.10 Make `PAGI::Auth` both the configured outcome policy and exporter

Rejected. Pages can combine those roles because its configured object and its
factories describe the same presentation responsibility. Auth already has a
second request-bound identity responsibility identified for Phase 2. Making
`PAGI::Auth->new(...)` mean response presentation now would either overload
that constructor later or force the ordinary identity facade into an
unrelated name. `PAGI::Auth::Outcomes` keeps configuration explicit while the
opt-in `PAGI::Auth` functions remain concise.

## 23. Acceptance summary

The design is complete when an application can express the common outcomes
without repeating protocol detail:

```perl
return challenge(
    challenges => [bearer(realm => 'api')],
);

return forbid(
    challenges => [bearer(
        error => 'insufficient_scope',
        scope => ['apples:write'],
    )],
);
```

and reuse either outcome safely at all current request boundaries:

```perl
return $failure;
return await $ws->deny($failure->response_for($ws));
return await $sse->decline($failure->response_for($sse));
```

The result must remain an ordinary Pages/Response composition. If Auth starts
owning credentials, identities, routing, protocol lifecycles, or response
emission in Phase 1, the implementation has crossed the boundary of this spec.
