# Authentication backends, context, and failure applications

Date: 2026-09-17

Status: **design snapshot for continued discussion; not approved for implementation**.

This document captures the shape developed in the current conversation. It is
intentionally detailed enough to resume in another session without treating
unfinished decisions as settled. The proposed Auth APIs below are not available
in the current implementation. Existing Routing, Compose, and Response APIs are
used to show how the proposal would fit the toolkit.

## 1. Purpose and authority

Make authentication something an application can configure at a middleware
boundary and inspect through a standalone helper. The first concrete use case is
one HTTP endpoint protected by an opaque Bearer token checked against storage.
The design must remain useful for Basic authentication, different token
verifiers, application-owned user objects, and custom authentication schemes.

The user explicitly authorized reconsidering, changing, or discarding existing
Auth work to obtain the right overall shape. Previous implementation effort is
not a design constraint. In particular, the cookie-boundary note's instruction
not to reopen Phase 1 does not override this later direction.

This snapshot records three levels of certainty:

- **Direction:** preferences stated or accepted in the conversation.
- **Proposed contract:** a concrete design put forward to realize that direction;
  still subject to review.
- **Open decision:** an unresolved choice that an implementation agent must not
  silently settle by copying a sketch.

Writing this document authorizes documentation only. It does not authorize
implementing these interfaces, replacing middleware, or changing sibling repos.

## 2. Work map and current baseline

No external ticket number has been supplied. The campaign is Auth backend and
context design, historically called Auth Phase 2.

| Repository | Branch and baseline | Owned work in this snapshot | Deployment boundary | Push target |
| --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | `feature/universal-connection-tools`, baseline `107622245af0fc4975fa29c15ae3ea0f5ad9b48a` | This new design document only | Local documentation; no runtime change or release | None |

PAGI and PAGI-Server are not implementation repositories for this task. Any
future cross-repository work needs an updated work map before implementation.
Nothing in this design requires depending on PAGI-Server internals.

At this baseline:

- Auth Phase 1 provides challenge values, `challenge` and `forbid` outcomes, and
  configurable rendering through Pages.
- `response_for` materializes existing outcomes for explicit protocol refusal.
- Existing Basic/Bearer middleware has older, differing auth-state shapes and
  behavior. It does not implement this proposal.
- Existing Bearer middleware includes a limited private JWT verifier. Keeping
  that implementation is not an objective of this design.
- Session and Stash already expose standalone helpers accepting a scope or an
  object with `scope()`.
- Routing distinguishes a Request-handler coderef from a `to_app` object and
  has explicit middleware descriptors.

The completion baseline is recorded in
[the continuation handoff](../plans/2026-09-17-tools-auth-continuation-complete-handoff.md).
That document's test results describe the existing code, not this proposal.

## 3. Goals and boundaries

### 3.1 Direction

1. Authentication runs in middleware, with reusable backends.
2. Application code uses `auth($scope)` or `auth($request)` to access results.
3. Request does not gain `user`, `auth`, or `auth_credentials` methods.
4. Backends can be simple callbacks or configured objects implementing a named
   method. The suggested method is `authenticate`.
5. A `backend(...)` descriptor should make configuration consistent with the
   declarative style of `middleware(...)`.
6. A user object is always available after authentication middleware runs,
   including an explicit unauthenticated user.
7. Identity and the permissions granted by particular credentials are separate.
8. Authentication state and failure information are available to ordinary PAGI
   applications through the scope, not hidden on a Request or shared middleware
   instance.
9. Failure handling has a default but accepts application customization using
   the existing handler/application distinction.
10. Flexibility should come from small explicit contracts used by built-ins and
    extensions alike, as with Routing.

### 3.2 HTTP authentication scope

The intended boundary is HTTP's authentication framework in RFC 9110, together
with relevant scheme specifications such as Basic (RFC 7617) and Bearer
(RFC 6750). RFC 9110 alone does not define credential parsing or every outcome
for those schemes.

Interactive cookie login, login forms, login redirects, `next` handling,
remember-me, and browser-specific login policy belong to a different system.
No cookie authentication middleware or automatic redirect policy is proposed
here. The eventual framework name need not become part of the public contract.

This is a toolkit boundary, not a claim that cookie authentication violates
HTTP. RFC 9110 section 11.4 explicitly acknowledges other authentication
mechanisms, including cookies, outside its challenge-response framework.

General session storage remains relevant: an opaque Bearer token can identify a
server-side record. Auth should not require Session, and finding an arbitrary
session record must not automatically establish an authenticated user.

Whether a separate cookie system later reuses the same user/result types is
open. This snapshot does not introduce a cookie-to-Auth adapter.

### 3.3 Not part of this snapshot

- Token issuance, OAuth authorization-server flows, refresh-token endpoints, or
  a user-management system.
- A built-in password database, password hashing implementation, or required ORM.
- A required JWT library, token format, or identity provider.
- A general policy language or complete role-management system.
- Automatic support for every registered HTTP authentication scheme or proxy
  authentication. The motivating flow is origin-server authentication.
- Fetch Metadata accessors or other action items from the cookie-boundary note.
- An implementation plan or a compatibility promise for proposed names.

## 4. Reference behavior from Starlette

The discussion used Starlette as a reference, not as a specification PAGI must
copy verbatim. The docs and source were checked on 2026-09-17.

| Concept | Observed Starlette behavior |
| --- | --- |
| Backend | `authenticate(conn)` asynchronously returns credentials and a user, or no result |
| Missing result | Middleware supplies empty `AuthCredentials` and an `UnauthenticatedUser` |
| User API | `is_authenticated`, `display_name`, and `identity` |
| Unauthenticated user | False authentication flag; empty display name and identity |
| Simple user | True authentication flag; username supplies display name and identity |
| Credentials | Stores the explicitly supplied scope strings; defaults to an empty list |
| `authenticated` scope | Added explicitly by the example backend, not automatically by middleware |
| Multiple required scopes | All listed scopes must be present |
| Custom failure response | `on_error` receives connection/request context and an authentication exception |

PAGI deliberately uses standalone helpers and ordinary application values for
failure handling. Its HTTP authentication defaults must preserve appropriate
401/403 distinctions rather than copy every Starlette response default.

Sources: [authentication documentation](https://starlette.dev/authentication/),
[user and credentials implementation](https://github.com/Kludex/starlette/blob/main/starlette/authentication.py),
[authentication middleware](https://github.com/Kludex/starlette/blob/main/starlette/middleware/authentication.py).

## 5. Responsibilities and data flow

The proposed responsibilities are:

| Responsibility | Role |
| --- | --- |
| Scheme handling | Extract and validate credential syntax; supply scheme-specific challenge metadata |
| Backend | Verify credentials using application services and establish a user plus granted scopes |
| Authentication context | Store the user, resulting credentials, and any expected failure for this invocation |
| Enforcement | Decide whether that context satisfies an endpoint's access requirements |
| Failure application | Render and emit the selected rejection using ordinary PAGI application machinery |
| Auth helper | Read established context without re-running authentication or performing hidden I/O |

These are not requirements for six classes or six middleware layers.

For a presented Bearer token, the proposed flow is:

1. The scheme middleware checks the Authorization field and parses the token.
2. The backend receives parsed credentials and the current PAGI scope.
3. Middleware awaits the result if needed.
4. Middleware installs a context in a derived downstream scope.
5. Valid credentials continue with an authenticated user and granted scopes.
6. Absent credentials continue with an unauthenticated user and empty scopes.
7. Invalid credentials select the authentication failure application.
8. A separate endpoint requirement can reject an otherwise anonymous or
   insufficiently privileged context.

Step 8 has no settled public API. Earlier sketches used `required => 1`; the
user questioned that option. It is no longer part of the proposed core shape.

## 6. Backend descriptors

### 6.1 Proposed public forms

```perl
use PAGI::Auth qw(backend);

backend(\&authenticate_token)

backend($configured_backend)

backend('+MyApp::TokenBackend',
    store => $token_store,
)
```

A descriptor records configuration; it does not authenticate during declaration.

The proposed object method is:

```perl
$backend->authenticate($presented_credentials, $scope)
```

No base class inheritance is required. A supplied instance must satisfy the
documented method contract. Construction errors should be detected when the
application is assembled, before serving requests.

### 6.2 Proposed construction semantics

- Class form: constructor arguments belong to `new`; construct when the owning
  middleware is compiled/assembled, not once per request.
- Instance form: retain the supplied instance; do not reconstruct or clone it.
- Callback form: retain the per-request authenticator callback.
- Reusing a class descriptor in independent placements constructs independent
  backend instances. Supplying the same instance or closure deliberately shares
  its configured dependencies.
- Credentials, users, and failures remain invocation-local even when the backend
  instance is shared.

The leading `+` exact-package convention is proposed to match Routing's
middleware descriptors. Short-name resolution and its namespace are open.

### 6.3 Callback distinction

The proposed callback is the runtime authenticator:

```perl
my $backend = backend(async sub ($presented, $scope) {
    # Authenticate this invocation.
});
```

This differs from a `middleware(...)` callback, which is an application-wrapping
factory. Backend callbacks capture dependencies; the class form takes
constructor options. Do not guess factory-versus-authenticator semantics from
arity or return values. Whether separate explicit factory support is useful is
open and should require an actual use case.

## 7. Backend invocation and results

### 7.1 Proposed inputs

Callbacks and objects receive the same two arguments:

```perl
$callback->($presented_credentials, $scope)
$instance->authenticate($presented_credentials, $scope)
```

For Bearer, the illustrative parsed representation is:

```perl
{ scheme => 'bearer', token => $token }
```

This value is parsed, not trusted. The exact representation and mutability are
open. Other schemes require documented scheme-specific fields; a universal
token-shaped credential type is not assumed.

The scope provides request metadata and state installed by earlier middleware.
It is the current scope at this middleware placement, including only routing or
tenant information actually available there. Backends must not assume later
middleware has run.

Passing scope avoids forcing a PAGI::Request onto WebSocket or SSE. It also lets
backends use standalone helpers. This metadata contract does not itself provide
body reads or event-stream ownership. Schemes requiring those capabilities need
an explicit extension design; do not add hidden body consumption.

### 7.2 Proposed result contract

| Result | Interpretation |
| --- | --- |
| `authenticated(...)` result | Valid credentials; contains a user and granted scopes |
| `undef` | This backend checked the presented credentials and rejected them |
| Exception or failed Future | Operational/programming failure; propagate normally |

Both immediate and Future-backed results are supported in the proposed contract.
Unexpected result shapes are programming errors, not anonymous authentication.

Unlike Starlette's scheme-owning backend, this callback runs after the scheme
middleware finds and parses applicable credentials. The middleware handles
absence before invocation. Consequently, `undef` means rejected credentials in
this proposal, not missing credentials. This distinction must survive any later
redesign of scheme/backend composition.

A structured rejection result may be needed when a backend has useful safe
failure information. Its constructor, fields, and relationship to `undef` remain
open; exceptions should not become the default expected-rejection mechanism.

### 7.3 Proposed success construction

```perl
return authenticated(
    user => PAGI::Auth::SimpleUser->new(
        identity     => $record->{user_id},
        display_name => $record->{display_name},
    ),
    scopes => ['authenticated', @{ $record->{scopes} }],
);
```

These names and constructor arguments are provisional. The intended result
keeps user identity separate from the scopes granted by this credential.
Application-owned user objects should be accepted through the agreed user
interface, without mandatory inheritance.

The storage record must already have been validated for this API, including any
expiration and revocation requirements. A backend grants scopes from trusted
verification results; it must not copy permissions requested by an unverified
client and treat them as granted.

## 8. Shared authentication context

### 8.1 Proposed scope entry

```perl
$scope->{'pagi.auth'} = {
    user        => $user,
    credentials => $credentials,
    failure     => $failure,
};
```

This is the proposed backing shape, not a description of today's middleware.
The helper does not maintain a second auth result on a Request object.

```perl
my $auth = auth($scope);
my $auth = auth($request);  # resolves through ->scope

my $user        = $auth->user;
my $credentials = $auth->credentials;
my $failure     = $auth->failure;
```

The helper follows Session/Stash source resolution: one raw scope hash or an
object exposing `scope()`. Requiring auth middleware, rather than silently
inventing an anonymous context when the entry is absent, is the proposed default.

### 8.2 State meanings

| Situation | User | Credentials | Failure |
| --- | --- | --- | --- |
| No applicable credentials | Unauthenticated user | Empty scopes | `undef` |
| Credentials accepted | Authenticated user | Backend-granted scopes | `undef` |
| Credentials rejected | Unauthenticated user | Empty scopes | Failure object |
| Malformed auth request | Unauthenticated user | Empty scopes | Failure object |
| Anonymous access rejected by a guard | Unauthenticated user | Empty scopes | Challenge-triggering failure |
| Authenticated access rejected by a guard | Preserve authenticated user | Preserve granted scopes | Authorization failure |
| Middleware absent | Configuration error | Configuration error | Configuration error |

A guard must not erase the authenticated user merely because that user lacks a
permission. Missing credentials alone are not a failure until a policy requires
authentication. Operational exceptions are not stored as credential rejection.

### 8.3 Ownership and lifetime

The proposed middleware contract installs state before invoking downstream code
or the failure application. It uses a derived scope for its result rather than
overwriting shared incoming auth state.

The context, credentials, and failure belong to this invocation. A reusable
middleware, backend, or failure app must not retain the current user/failure on
its own instance fields. Unrelated requests must not observe one another's
results.

Auth access is observational: no re-verification, lazy database access, or raw
token decoding occurs in `auth(...)` or its ordinary accessors.

Whether objects are immutable, how arrays are copied, and how nested
authentication middleware composes or replaces state remain open. The intended
direction is controlled installation of verified results, not a freely writable
Stash equivalent. This is not a claim that application-owned user objects must
be deeply frozen.

## 9. Users and resulting credentials

### 9.1 User interface

The latest proposal follows Starlette's small interface:

```perl
$user->is_authenticated;
$user->identity;
$user->display_name;
```

Provide an unauthenticated implementation and a simple authenticated
implementation. Proposed names are `PAGI::Auth::UnauthenticatedUser` and
`PAGI::Auth::SimpleUser`.

The default user for absent/rejected credentials is a real unauthenticated
object, not `undef`. A service account may implement the same interface; the
contract must not assume a human or require a database model.

Starlette uses empty strings for anonymous identity and display name. Whether
PAGI copies that choice or uses `undef` for absent identity is open. So are
identity type restrictions and whether display name is required or supplied by
a convenience implementation. Do not infer authentication from the truthiness
of an identity value; use `is_authenticated`.

### 9.2 Resulting credentials

```perl
my $credentials = auth($source)->credentials;
my $scopes = $credentials->scopes;  # proposed: arrayref
```

Resulting credentials describe the permissions granted by this authentication.
They are separate from the presented credentials passed into the backend.
Naming must make this distinction clear in documentation and signatures.

For example, two tokens may identify user 42 but grant different scopes:

```text
Token A: authenticated, orders:read
Token B: authenticated, orders:read, orders:write
```

Permissions must not be inferred solely from a reusable user object's global
roles when the current token grants fewer permissions.

### 9.3 The `authenticated` scope

Starlette requires backends to add this ordinary string explicitly. The latest
recommendation for PAGI is likewise explicit scopes in the success result.
Automatic insertion by `authenticated(...)` was discussed but not selected.

There is an unresolved consistency question: a user can report authenticated
while credentials omit that string. Conversely, custom code could incorrectly
grant it to an unauthenticated user. Decide whether PAGI reserves/enforces this
scope, adds it automatically, or follows literal Starlette membership semantics
before implementing an authentication guard. Do not accidentally let a string
grant contradict user authentication state.

### 9.4 Scope checks and access enforcement

The intended all-of behavior is that requiring `authenticated` and `admin`
requires both. An `admin` scope has no intrinsic user-management meaning.
Possible any-of/all-of/missing-scope convenience methods have been discussed but
their names, placement, empty-list semantics, validation, and case handling are
not settled.

Route protection should be separate from identity acquisition. A guard,
middleware descriptor, or explicit handler-level check may supply it. There is
no approved `requires(...)` or `Auth::Require` API yet. The old
`required => 1|0` sketch is set aside, not an accepted configuration option.

## 10. Structured failures

The failure object is stored in `pagi.auth`, alongside user and credentials,
before the failure application is called. Proposed accessors are:

```perl
$failure->code;
$failure->message;
$failure->status;
$failure->headers;
```

- `code`: a stable classification useful to application code.
- `message`: a deliberately public-safe explanation.
- `status`: the selected/suggested HTTP rejection status.
- `headers`: response-ready authentication header pairs, compatible with normal
  Response construction and preserving repeated fields.

The scheme/enforcement layer determines HTTP semantics. A backend need not know
how to serialize a challenge. An extension's ability to supply structured safe
rejection detail needs a final contract.

### 10.1 Internal classification is not always a wire error token

An absent-credentials failure may have an application classification such as
`missing_credentials`, but that must not be mechanically copied into a Bearer
challenge. RFC 6750 omits its error parameter when no applicable authentication
information was supplied.

Likewise, `invalid_request`, `invalid_token`, and `insufficient_scope` have
scheme-specific meanings. The design must distinguish general failure kinds
from protocol parameters where necessary. Exact code vocabulary is open.

### 10.2 Failure selection

| Condition | Proposed default |
| --- | --- |
| No credentials, authentication not required | Continue anonymously |
| No credentials, protected endpoint | 401 with a challenge and no Bearer error parameter |
| Unknown, expired, or revoked Bearer token | 401 with `invalid_token` |
| Malformed authentication request, e.g. duplicate Authorization | 400 with `invalid_request` |
| Authenticated token lacks required scope | 403 with `insufficient_scope` where applicable |
| Backend storage/service failure | Normal operational error handling; no invalid-token conversion |

Malformed credential syntax versus malformed authentication request needs a
precise scheme-level matrix. The table is not permission to classify every
parsing failure identically.

## 11. Failure handlers are ordinary applications

### 11.1 Proposed HTTP dispatch contract

| `on_failure` configuration | Meaning |
| --- | --- |
| Omitted | Use the default authentication failure application |
| Coderef | Call with one PAGI::Request; invoke its returned application value |
| Instantiated object | Require `to_app`; run as a normal PAGI application |

A handler may return its value immediately or through a Future, as with HTTP
Routing. The object path has no Auth-specific `render` method. Response objects,
Pages applications, and custom application objects are usable under the normal
application contract. Native triplet coderefs need the existing explicit
application-object adapter at declaration time, rather than arity guessing.

Backend objects use `authenticate`; failure application objects use `to_app`.
These are different responsibilities, not interchangeable object contracts.

### 11.2 Request handler example

```perl
on_failure => sub ($request) {
    my $failure = auth($request)->failure;

    return json_response(
        {
            error   => $failure->code,
            message => $failure->message,
        },
        status  => $failure->status,
        headers => $failure->headers,
    );
},
```

This replaces the earlier two-argument failure callback sketches. The desired
form is one Request, matching HTTP route handlers. The helper exposes the
failure to both the high-level and native application forms.

### 11.3 Native application object example

```perl
package MyApp::AuthFailure;

use Future::AsyncAwait;
use PAGI::Auth qw(auth);
use PAGI::Response qw(json_response);
use PAGI::Utils qw(invoke_app);

sub new { bless {}, shift }

sub to_app {
    my ($self) = @_;

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $failure = auth($scope)->failure;

        my $response = json_response(
            {
                error   => $failure->code,
                message => $failure->message,
            },
            status  => $failure->status,
            headers => $failure->headers,
        );

        await invoke_app($response, $scope, $receive, $send);
    };
}
```

`to_app` receives no per-request error argument. The compiled app receives the
derived scope containing the current failure. Shared application objects never
store that failure on themselves.

### 11.4 Response control

The application owns a custom response. It can choose JSON shape, text, HTML,
Pages rendering, and additional headers. Following the supplied status and
authentication headers makes the standards-correct path straightforward.

The current proposal does not silently rewrite a custom application's emitted
response. Custom responses remain responsible for HTTP requirements, including
the required challenge on 401. Whether any opt-in validation is useful is open;
do not impose a new response-inspection mechanism merely to preserve old code.

The default can reuse current Pages/Auth outcomes where appropriate. Current
`challenge`/`forbid` do not cover every outcome, notably malformed-request 400.
That case must be designed explicitly, not forced through a 401 constructor.

### 11.5 Protocol boundary still open

The one-Request callback contract above is for HTTP. PAGI::Request currently
requires an HTTP scope. Do not fabricate an HTTP scope or pass a WebSocket/SSE
scope to it to make this callback appear portable.

The goal remains shared authentication information and appropriate rejection
before WebSocket acceptance or SSE start. The exact failure callback adaptation
and the treatment of arbitrary `to_app` objects on those protocols remain open.
Existing outcome materialization/refusal support is useful evidence, but does
not by itself make every HTTP application portable to every protocol.

Any future adaptation must follow PAGI's public scope/event/lifecycle contract,
retain correct response completion and cleanup, and avoid server internals.

## 12. Consolidated opaque-token sketch

This is the latest shape, intentionally without a speculative protection flag.
It establishes authentication for `/me`; the outstanding route-protection API
is necessary before this becomes the originally requested protected endpoint.
Anonymous handling is explicit so the sketch does not imply protection it lacks.

```perl
use v5.40;
use Future::AsyncAwait;

use PAGI::Auth qw(auth backend authenticated);
use PAGI::Compose qw(compose);
use PAGI::Routing qw(route middleware);
use PAGI::Response qw(json_response);
use PAGI::Auth::SimpleUser;

sub build_app ($token_store) {
    my $authentication = middleware('Auth::Bearer',
        realm => 'api',

        backend => backend(async sub ($presented, $scope) {
            my $record = await $token_store->find_active(
                $presented->{token},
            );

            return undef unless $record;

            return authenticated(
                user => PAGI::Auth::SimpleUser->new(
                    identity     => $record->{user_id},
                    display_name => $record->{display_name},
                ),
                scopes => ['authenticated', @{ $record->{scopes} }],
            );
        }),

        on_failure => sub ($request) {
            my $failure = auth($request)->failure;

            return json_response(
                { error => $failure->code, message => $failure->message },
                status  => $failure->status,
                headers => $failure->headers,
            );
        },
    );

    return compose(
        routes => [
            route('/me' => sub ($request) {
                my $user = auth($request)->user;

                return json_response({ anonymous => \1 })
                    unless $user->is_authenticated;

                return json_response({ user_id => $user->identity });
            },
                methods    => ['GET'],
                middleware => [$authentication],
            ),
        ],
    );
}
```

`find_active` is application-defined, not a proposed PAGI storage method. Here
it returns a validated record with `user_id`, `display_name`, and `scopes`, or
`undef`; infrastructure failures propagate. Another backend can use a database,
an external service, or suitable session storage through the same contract.

The callback can be replaced by:

```perl
backend => backend('+MyApp::TokenBackend', store => $token_store)
```

The failure handler can independently be replaced by:

```perl
on_failure => MyApp::AuthFailure->new
```

Neither replacement changes how the downstream handler accesses its user.

## 13. Intended protected-endpoint HTTP traffic

These exchanges describe the original protected `/me` use case once an explicit
authentication requirement is attached. They are not claims that the optional
authentication sketch above already enforces that requirement. Assume HTTPS;
message-framing and unrelated headers are omitted.

### 13.1 Success

```http
GET /me HTTP/1.1
Host: api.example.com
Authorization: Bearer valid-opaque-token
Accept: application/json
```

Backend accepts token, middleware installs the user and granted scopes, the
requirement succeeds, and the endpoint runs:

```http
HTTP/1.1 200 OK
Content-Type: application/json

{"user_id":"42"}
```

### 13.2 Missing credentials at a protected endpoint

```http
GET /me HTTP/1.1
Host: api.example.com
Accept: application/problem+json
```

The backend is not called. Middleware establishes an unauthenticated user. The
requirement selects a challenge, and the endpoint is not called:

```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer realm="api"
Content-Type: application/problem+json

{"type":"about:blank","title":"Unauthorized","status":401}
```

The client obtains a token separately and may retry. This response does not
issue a token or imply a login redirect.

### 13.3 Invalid token

```http
GET /me HTTP/1.1
Host: api.example.com
Authorization: Bearer expired-opaque-token
Accept: application/problem+json
```

The backend rejects the token. Middleware establishes an unauthenticated user
with a failure and invokes the failure app instead of the endpoint:

```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer realm="api", error="invalid_token"
Content-Type: application/problem+json

{"type":"about:blank","title":"Unauthorized","status":401}
```

These are illustrative default bodies. A configured application may render a
different representation while preserving appropriate HTTP semantics.

### 13.4 Other outcomes

- Malformed authentication requests are rejected before backend invocation where
  detected by scheme parsing; proposed default 400 with `invalid_request`.
- A valid token lacking an endpoint's required scope produces the appropriate
  403 failure while retaining the user and granted scopes.
- A token-store outage propagates through normal application error handling.
  The resulting 5xx policy is not an Auth invalid-token response.

## 14. Relationship to prior documents and implementation

The [Phase 1 specification](2026-09-04-authentication-outcomes-design.md) and
[cookie-boundary ruling](../../../.pagi-auth-cookie-boundary-ruling.md) are
historical inputs. The current conversation changes the following assumptions:

- Phase 1 APIs are available for reconsideration, not frozen by this work.
- The target is more than response factories: it includes backends, user and
  credentials context, failure applications, and a future enforcement seam.
- Cookie login remains outside scope; Session is not automatically an Auth
  dependency or a cookie identity provider.
- `required => 1|0` is unresolved and set aside.
- Failure callbacks follow the one-Request route convention, not earlier
  `($failure, $scope)` or `($request, $failure)` sketches.
- `auth(...)->user->identity` replaces the earlier sketch's direct
  `auth(...)->identity` as the primary illustrated identity access.
- Backends return an explicit user plus scopes in the latest sketch, rather
  than only a scalar identity.

Do not carry historical comparative claims into public docs without checking
them. For example, Starlette does implement `next` behavior for redirecting
guards. The cookie-boundary decision does not depend on claims that other
frameworks cannot express comparable responses.

## 15. Open decisions before an implementation plan

| Decision | Current leaning / constraint |
| --- | --- |
| Exact module/export names | Examples are provisional; avoid confusing presented and resulting credentials |
| Backend short-name resolution | Follow middleware conventions, with an explicit exact-package escape |
| Descriptor-only backend configuration | Latest examples wrap every form with `backend(...)`; decide whether bare values are rejected |
| Scheme/backend extensibility | Preserve custom schemes without forcing all credentials into a Bearer shape |
| Backend input representation | Parsed credentials plus scope proposed; typed value vs hash not settled |
| Structured rejection return | Needed only if it improves expected-failure expression; API not selected |
| User methods and identity types | Small interface proposed; anonymous identity value and required display name undecided |
| `authenticated` scope invariant | Explicit scopes currently recommended; consistency with user flag must be resolved |
| Scope helper operations | Any/all/missing semantics and names need definition |
| Route protection | Separate from authentication; no accepted replacement for `required` yet |
| Challenge selection at a guard | An absent-credentials guard must know the configured acceptable schemes without guessing from user state |
| Guard failure handler ownership | How guards reuse/default/override authentication failure apps remains open |
| Nested auth / multiple schemes | No automatic merging, precedence, fallback, or identity replacement policy selected |
| Failure codes and messages | Internal classification versus wire parameters; backend safe detail mapping |
| State mutability and copies | Prevent cross-request leakage and accidental privilege mutation; exact object rules open |
| Raw credential retention | Avoid putting secrets in ordinary user/credentials context; lifetime/redaction rules need definition |
| Failure application lifecycle | Reuse normal app compilation/invocation rules; exact compilation timing for configured objects to specify |
| WebSocket/SSE adaptation | No fake HTTP Request; explicit public-protocol behavior required |
| Existing API migration | Replacement, removal, or adapters to decide after the target design is approved |

Do not resolve these by adding compatibility branches or special cases until a
minimal implementation happens to pass tests. If the shape needs several
exceptions, return to design discussion.

## 16. Future validation criteria

These are acceptance topics for a later plan, not tests run for this document.

1. Callback and object backends produce equivalent observable results, including
   immediate and Future-backed success, rejection, and operational failure.
2. Class descriptors construct at the documented boundary; configuration is
   reusable without per-request construction or accidental state sharing.
3. Missing credentials produce an unauthenticated user and empty credentials;
   missing middleware produces the chosen clear configuration error.
4. Same user/different tokens can have different granted scopes without leakage.
5. User and credential-scope consistency follows an explicitly chosen rule.
6. Failure handlers and `to_app` objects observe the same current failure through
   their Request or scope, including concurrent requests on one compiled app.
7. Expected rejection never swallows a storage exception as an invalid token.
8. Missing, invalid, malformed, and insufficient-scope cases produce the agreed
   challenge/status matrix and do not invoke a protected endpoint.
9. Public/optional endpoints can observe an anonymous user without a rejection.
10. Scope enforcement tests distinguish all-of and any-of if both are exposed.
11. Custom failure responses preserve application control; default responses
    preserve required authentication fields and safe rendering.
12. Duplicate headers, unsupported schemes, nested middleware, and any accepted
    alternate credential transports have explicit tested rules.
13. Examples and docs show both callback and object backends, application failure
    handlers, and the actual protected-endpoint API once selected.
14. Protocol tests prove the eventual WebSocket/SSE adaptation against public
    PAGI outcomes without depending on one server's internal implementation.

## 17. Sources and review status

Normative references:

- [RFC 9110 section 11: HTTP Authentication](https://www.rfc-editor.org/rfc/rfc9110.html#section-11)
- [RFC 9110 section 11.4: other authentication mechanisms](https://www.rfc-editor.org/rfc/rfc9110.html#section-11.4)
- [RFC 6750: Bearer token usage](https://www.rfc-editor.org/rfc/rfc6750.html)
- [RFC 7617: Basic authentication](https://www.rfc-editor.org/rfc/rfc7617.html)

Local design references:

- [Phase 1 outcome design](2026-09-04-authentication-outcomes-design.md)
- [Completed continuation handoff](../plans/2026-09-17-tools-auth-continuation-complete-handoff.md)
- [Cookie-boundary note](../../../.pagi-auth-cookie-boundary-ruling.md)
- `lib/PAGI/Session.pm` and `lib/PAGI/Stash.pm`: standalone helper conventions.
- `lib/PAGI/Routing.pm` and `lib/PAGI/Routing/Middleware.pm`: handler/application
  distinction and declarative construction.
- `lib/PAGI/Auth/Outcomes.pm`: current response customization and limitations.

This snapshot received an inline consistency review when written. It has not
received user approval as a final design, an implementation feasibility review,
or runtime verification. Continue editing it incrementally as decisions change;
preserve the distinction between accepted direction and proposed mechanics.
