# Authentication backends, context, and failure applications

Date: 2026-09-17

Updated: 2026-09-20 — constrained `auth_result` / `unauth_result` constructors,
user duck typing, function/class/instance helper forms, guest continuation, and
explicit application-owned HTTP status and authentication headers. Group protection uses existing middleware
composition, with a required Auth cookbook entry; no new Auth dispatch hook.
Backends receive only the existing PAGI::Request and own credential extraction,
parsing, verification, and missing-credential results. Generic authentication
middleware installs their results and delegates; it has no scheme parser or
encoding policy. OAuth flows remain separate. Authorization remains application code.
The public `pagi.auth` scope entry holds a completed Auth result; custom
middleware installs it using the existing `clone_scope` helper.

Status: **Auth v1 implemented locally in PAGI-Tools; final validation is recorded
in the [completion handoff](../plans/2026-09-20-authentication-v1-completion-handoff.md).**

This document preserves the design discussion and its dated amendments. Earlier
"proposed", "source-only", and "not implemented" statements describe their
original review point, not the current library state. The settled Auth v1
contract is implemented in [PAGI::Auth](../../../lib/PAGI/Auth.pm) and the public examples linked
in the completion handoff. Existing Routing, Compose, and Response APIs supply
the composition and refusal boundaries described here.

The earlier, broader design is preserved in the
[authorization-policy research snapshot](2026-09-19-auth-authorization-policy-research-snapshot.md).
This active document supersedes its guard, policy, and enforcement requirements.
The scope reduction is accepted for now; API details explicitly marked open
remain open. This is still a design document, not implementation approval.

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

The 2026-09-19 amendment is documentation-only in the same Tools repository and
branch, at baseline `f731ea9ae7580063e836540a1386ce7f84ce1ce7`. Its owned change is
this spec and its Notes companion, with the previous versions preserved as
research snapshots. There is no implementation, deployment, or push target.

The 2026-09-20 amendment uses the same branch and baseline. Its owned change is
this spec; the pre-amendment text is preserved in the
[previous design snapshot](2026-09-20-auth-pre-result-constructors-snapshot.md).
The request-only backend amendment also updates both JWT sandbox variants and
the Notes companion’s backend examples. The earlier parsing design is preserved
in the [presented-credentials research snapshot](2026-09-20-auth-presented-credentials-research-snapshot.md).
Other historical Notes APIs remain marked for reconciliation; this spec is
authoritative where they differ. No runtime changes, deployment, or push are authorized.

At the original snapshot baseline:

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
4. The backend option accepts exactly a coderef or an object implementing
   `authenticate`; both use the same input and result contract.
5. Pass either form directly. No backend generator, descriptor, class-name
   resolution, or implicit construction is part of the API.
6. A user object is always available after authentication middleware runs,
   including an explicit unauthenticated user.
7. Identity and the permissions granted by particular credentials are separate.
8. Authentication state and failure information are available to ordinary PAGI
   applications through the scope, not hidden on a Request or shared middleware
   instance.
9. Applications choose when to refuse access and explicitly construct status,
   body, and authentication headers. Protect groups through existing middleware
   composition, not a new Auth callback or enforcement API.
10. Flexibility should come from small explicit contracts used by built-ins and
    extensions alike, as with Routing.
11. Authorization stays in the application: inspect the user and granted scopes,
    then return or invoke an ordinary application response.
12. Scope helpers answer membership questions only. Applications compose those
    booleans with Perl operators; a higher-level framework may build enforcement.
13. Treat the unauthenticated user as a useful object. Public application behavior
    need not branch on authentication merely to read identity or display data.

### 3.2 HTTP authentication scope

The intended boundary is HTTP's authentication framework in RFC 9110, together
with relevant scheme specifications such as Basic (RFC 7617) and Bearer
(RFC 6750). RFC 9110 alone does not define credential parsing or every outcome
for those schemes.

Version one supplies scheme-neutral authentication middleware. The backend
receives the Request and owns credential extraction, scheme selection, parsing,
text encoding, verification, account/storage lookup, and any external verifier.
Basic and Bearer are motivating examples, not mandatory built-in parser stages.
Optional parsing helpers or ready-made backends can be considered separately
when they demonstrate value. A higher-level framework can provide parsed
credential adapters without changing this request-only contract.

OAuth 2 flows remain a separate concern: authorization redirects, token
acquisition, client registration, refresh, and discovery are not Auth features.
A backend may validate an OAuth-issued access token without making this toolkit
an OAuth client or authorization server. MCP's HTTP Bearer input can use the same
backend boundary; no MCP discovery or OAuth workflow implementation is implied.

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

- Token issuance, OAuth client/authorization-server flows, redirects, discovery,
  client registration, refresh-token endpoints, or a user-management system.
- Built-in scheme parsers, including Basic and Bearer, or a required parsed-
  credentials representation. Scheme examples test extensibility, not v1 scope.
- A built-in password database, password hashing implementation, or required ORM.
- A required JWT library, token format, or identity provider.
- A general policy language or complete role-management system.
- `Auth::Require` middleware, `required => 1|0`, and authentication/scope
  enforcement combinators (including the explored allow/deny form).
- Auth-specific `on_failure` / `after_auth` dispatch hooks for group protection.
- Public failure-policy callbacks, callable defaults, cause taxonomies, guard
  requirement propagation, or a guard rejection-preparation API.
- Automatic administrator overrides, role inheritance, or conversion of internal
  grants into advertised OAuth scopes.
- Automatic support for every registered HTTP authentication scheme or proxy
  authentication. The motivating flow is origin-server authentication.
- Fetch Metadata accessors or other action items from the cookie-boundary note.
- An implementation plan or a compatibility promise for proposed names.

### 3.4 Header primitives and optional conveniences

Accepted: header-facing helper names should closely resemble the HTTP fields
they encapsulate. `authorization(...)` and `www_authenticate(...)` illustrate
the naming direction. `www_authenticate` has the accepted formatter shape below;
the formatter lives in `PAGI::Auth`. An Authorization parsing helper is deferred;
no parser is required to implement the backend contract.
Backend results and the context facade have distinct roles
and are not renamed after headers merely to follow that convention.

It must be straightforward to bypass these conveniences and use ordinary public
header primitives. Applications can read all Authorization field values, parse
their own scheme, and construct WWW-Authenticate fields through `PAGI::Headers`
and normal Response/application APIs. Manually supplied headers do not need an
Auth-specific challenge object, a recognized Auth failure code, or an opt-out
flag. Auth must not intercept or rewrite a custom application's chosen response.
Normal PAGI HTTP/wire requirements still apply.

Applications may combine levels: custom parsing with public context
establishment, standard authentication with a custom failure app, or an ordinary
response containing entirely application-built authentication headers. The
context API and ordinary failure applications must preserve these paths without
forcing callers to replace the whole authenticator just to customize a response. Helpers
should reduce work for common cases without becoming a mandatory intermediate
representation for HTTP headers.

Examples must demonstrate the raw-header path alongside the convenience path,
including repeated fields. Backend rejection results are defined separately in
section 7.2.

Accepted: `www_authenticate` synchronously returns one plain header-value string
containing one challenge. It takes a required scheme followed by an optional flat
list of named challenge parameters:

```perl
www_authenticate($scheme, @parameter_pairs);  # returns a string, never a Future

use PAGI::Auth qw(www_authenticate);
www_authenticate('Bearer', realm => 'api');
PAGI::Auth->www_authenticate('Bearer', realm => 'api');
my $factory = PAGI::Auth->new;
$factory->www_authenticate('Bearer', realm => 'api');
PAGI::Auth->new->www_authenticate('Bearer', realm => 'api');
```

Class/instance forms preserve normal subclass dispatch (§7.4); exported functions
use the base implementation. A shared factory retains no request-local state.

```perl
www_authenticate('Bearer');
# Bearer

www_authenticate('Basic', realm => 'api', charset => 'UTF-8');
# Basic realm="api", charset="UTF-8"
```

Application code selects the response explicitly:

```perl
my $challenge = www_authenticate('Bearer',
    error             => 'insufficient_scope',
    scope             => 'notes:write',
    resource_metadata => $metadata_url,
);

my $response = json_response({ error => 'insufficient_scope' },
    status  => 403,
    headers => [ 'WWW-Authenticate' => $challenge ],
);
```

Parameter order and supplied name casing are preserved. Values are emitted as
quoted strings, escaping embedded double quotes and backslashes. There is no
parameter-name whitelist: any syntactically valid name can be supplied, including
extension parameters. The caller supplies scalar values; the formatter does not
join scope arrays or interpret their contents. An empty string value is valid;
omit a parameter by leaving its pair out, not by passing undef.

Argument errors are:

- A missing or syntactically invalid scheme name.
- An incomplete name/value pair or an invalid parameter name.
- An undefined value or reference.
- Value bytes that cannot appear in an HTTP quoted string, including CR, LF,
  and NUL.
- Repeated parameter names, compared case-insensitively. RFC 9110 §11.2 requires
  each parameter name to occur only once within a challenge; this is distinct
  from supplying multiple challenges through repeated response header fields.

This is syntax validation, not validation of scheme-specific requirements or
error-code meanings. The formatter chooses no status, body, realm, error code,
permissions, or OAuth behavior. It reads no request, Auth context, backend
configuration, or failure value. Scheme parameter semantics remain with the
caller or scheme implementation.

Each call formats one challenge. Multiple challenges use normal response headers:

```perl
headers => [
    'WWW-Authenticate' => www_authenticate('Basic', realm => 'api'),
    'WWW-Authenticate' => www_authenticate('Bearer', realm => 'api'),
],
```

Opaque challenge-token formatting is deferred in v1; there is no overloaded token
argument or reserved parameter masquerading as one. Ordinary header construction
remains available, with the caller responsible for the supplied value:

```perl
headers => [ 'WWW-Authenticate' => 'Negotiate ' . $encoded_token ],
```

Raw headers also cover named-parameter schemes with special quoting rules.
For example, Digest requires `algorithm` and `stale` to be unquoted (RFC 7616
§3.3). The formatter quotes every value, so it cannot construct that form:

```perl
# A fixed illustrative Digest challenge; no Digest backend is provided here.
headers => [
    'WWW-Authenticate' =>
        'Digest realm="api", nonce="example-nonce", qop="auth", algorithm=SHA-256, stale=true',
],
```

This is another use of the existing raw-header path, not a new formatter mode.
A valid parameter name does not guarantee that the helper's serialization meets
every scheme's sender requirements. Callers constructing dynamic raw values own
correct quoting and value validation.

Hand-written valid header strings are interchangeable with the formatter output.
New schemes and valid extension parameters require no PAGI registry or allowlist.

## 4. Reference behavior from Starlette

The discussion used Starlette as a reference, not as a specification PAGI must
copy verbatim. The docs and source were checked on 2026-09-17 and rechecked on 2026-09-19.

| Concept | Observed Starlette behavior |
| --- | --- |
| Backend | `authenticate(conn)` asynchronously returns credentials and a user, or no result |
| Missing result | Middleware supplies empty `AuthCredentials` and an `UnauthenticatedUser` |
| User API | `is_authenticated`, `display_name`, and `identity` |
| Unauthenticated user | False authentication flag; empty display name and identity |
| Simple user | True authentication flag; username supplies display name and identity |
| Credentials | Stores the explicitly supplied scope strings; defaults to an empty list |
| `authenticated` scope | Added explicitly by the example backend, not automatically by middleware |
| Starlette permission decorator | Supports scope enforcement; this does not imply a PAGI Tools v1 guard |
| Custom failure response | `on_error` receives connection/request context and an authentication exception |

PAGI deliberately uses standalone helpers and ordinary application values for
failure handling. Starlette's `JSONResponse(status_code=401)` does not add a
WWW-Authenticate challenge, and its authentication middleware's default error
handler returns 400 plain text. The user's Python learning example omitted the
401 challenge and used that default for invalid JWTs. Preserve its simple
application structure while using correct HTTP authentication responses; those
omissions do not justify a general failure-policy system in PAGI Tools.

Sources: [authentication documentation](https://starlette.dev/authentication/),
[user and credentials implementation](https://github.com/Kludex/starlette/blob/main/starlette/authentication.py),
[authentication middleware](https://github.com/Kludex/starlette/blob/main/starlette/middleware/authentication.py).

## 5. Responsibilities and data flow

| Responsibility | Role |
| --- | --- |
| Authentication middleware | Construct the Request, invoke/await the backend, install its result, and delegate |
| Backend | Read and interpret credentials, verify them, and return an authenticated or unauthenticated result |
| Authentication context | Expose the user, resulting credentials, and optional failure for this invocation |
| Scope inspection | Answer boolean membership questions without enforcing access |
| Application | Decide authorization and construct its own refusal when needed |
| Authentication failure application | Render an explicitly selected refusal using ordinary PAGI application machinery |

Authentication applies only to `http`, `websocket`, and `sse` scopes. Other
scope types, including `lifespan`, are passed to the downstream app unchanged
and awaited, before constructing Request, invoking the backend, or installing
Auth context. Compose routes startup/shutdown through root middleware before
its lifespan dispatcher, so this pass-through is part of the middleware contract.

For a supported request through authentication middleware:

1. Generic authentication middleware constructs a PAGI::Request from the current
   scope and real receive channel, then invokes the configured backend. It does
   this even when Authorization is absent; it does not inspect credentials itself.
2. The backend interprets the request and returns `auth_result(...)` or
   `unauth_result(...)`, immediately or through a Future. It owns the choice of
   Guest and any guest grants, including for missing credentials.
3. Middleware awaits the result if needed, installs the completed result under
   `pagi.auth` in a child scope, and invokes downstream. No response metadata is
   generated. Operational exceptions and failed Futures propagate normally.
4. Downstream application code inspects the user or scopes when needed and owns
   its response. Optional application-defined failure codes preserve distinctions
   without a hidden middleware parser. Header validation is a separate concern (§10.2).

There is no separate built-in enforcement phase. Missing and rejected credentials
continue to the application in the default flow. Applications may place ordinary
middleware after authentication to protect a group (§11). There is no Auth
`on_failure` or `after_auth` hook. A later application denial does not
automatically populate `auth(...)->failure`.

### 5.1 Small functions and ordinary application code

Challenge formatting transforms explicit inputs into a value without reading
storage, changing scope, or emitting responses. Backends may use their own small
parsing functions; no public parser is required by this design. Backend callbacks
close over dependencies or use configured objects and may perform I/O. Scope helpers
return booleans and perform no I/O or response selection. Perl `&&`, `||`, and
parentheses are sufficient to combine application rules.

This direction does not require immutable collections, a pipeline DSL, a class
hierarchy, or allow/deny application combinators. Repeated parsing code can
motivate an optional helper later; it does not justify making a parsed-credential
argument mandatory for every backend.

Evaluate the shape through an opaque-token API, Basic verification, an
application-supplied JWT backend using generic authentication middleware, and
manually composed MCP challenges. These are examples of the core, not authorization to implement a
JWT verifier, OAuth server, or MCP framework in PAGI Tools.

## 6. Backends: a coderef or an authenticate object

### 6.1 Exactly two accepted forms

Accepted: the middleware's `backend` option takes a coderef or an already
constructed object implementing `authenticate`. Both are passed directly.
`PAGI::Middleware::Authentication` (descriptor spelling `Authentication`) is the
working name for the new generic middleware; it is not a shipped class:

```perl
middleware('Authentication',
    backend => sub ($request) {
        # Return auth_result(...) or unauth_result(...).
    },
);

# The application loads and constructs its class normally.
use MyApp::TokenBackend;

middleware('Authentication',
    backend => MyApp::TokenBackend->new(store => $token_store),
);
```

No required base class, generator, registry, or backend descriptor is involved.
Class-name strings, constructor descriptions, backend-producing factories, and
objects providing only `to_app` are not alternate backend forms. There is no
public `backend()` helper in the proposed API, including class/instance variants.

### 6.2 Identical invocation and result semantics

```perl
$callback->($request);
$object->authenticate($request);
```

A callback gets exactly one Request; no adapter or middleware invocant is
inserted. The object gets its normal invocant plus that same Request. Either
returns a result immediately or a Future resolving to that result. Exceptions and failed Futures propagate under §7's existing contract.
Validate the accepted shape before serving requests. Do not guess the role of a
callback from its arity or return value: it authenticates an invocation, not
constructs another backend.

Middleware can normalize invocation internally if useful, but that creates no
public adapter API, implementation-class requirement, or separate result path.

### 6.3 Construction, sharing, and scope

The application constructs its objects and closures through ordinary Perl code.
Middleware retains the supplied value; it does not load backend classes, call
`new`, clone instances, or defer backend construction. Applications decide
whether to share a closure or instance across placements. No current user's
credentials, result, or failure is stored on a shared backend or middleware.

Closures capture dependencies; objects keep configured dependencies and helper
methods. This supports both small verifiers and more complex implementations
without adding accepted configuration forms.

The earlier backend descriptor and optional callback-to-object generator are
superseded. Existing Routing `middleware(...)` descriptors are unchanged: their
callbacks wrap applications during assembly. Backend callbacks instead verify
credentials at request time.

## 7. Backend invocation and results

### 7.1 Accepted backend argument

```perl
$callback->($request);
$instance->authenticate($request);

# In an object implementation:
sub authenticate ($self, $request) {
    ...
}
```

The sole argument is the existing `PAGI::Request`, constructed with the current
scope and real receive callback. It provides header, path, client, query, and
scope accessors and works with standalone Session/Stash helpers. Raw scope is
available through `$request->scope`. Retain the actual HTTP, WebSocket, or SSE
scope type; introduce no Auth-only request class or fabricated receive callback.

The middleware does not inspect Authorization, extract a token, select a scheme,
decode Basic credentials, choose an encoding, or decide whether credentials are
missing. The backend runs on every applicable request and owns those decisions.
Missing credentials can simply return `unauth_result()`, or an application-owned
Guest and grants. A higher-level framework may offer convenience backends or
adapters using this same contract.

Request construction does not consume input. Normal body operations have their
existing effects and protocol restrictions. Middleware does not read the body;
a backend requiring body verification owns that behavior explicitly. This
contract does not promise body replay, stream independence, or automatic
signature canonicalization.

The request exposes state available at this middleware placement, not future
route captures or tenant state. It is not the server-supplied `pagi.connection`
transport object. No send callback or response-emission capability is added to
the backend API. Results remain authentication results, not PAGI applications.

#### 7.1.1 Scheme decisions belong to the backend

A Basic backend chooses its Base64 parsing and character decoding according to
its application and RFC 7617. A Bearer backend extracts and verifies its token;
it can support opaque storage tokens, JWTs, or MCP HTTP access tokens without a
middleware distinction. Neither needs a core `$presented` schema. Expected
issuer/audience and verifier dependencies remain trusted backend configuration.

The earlier survey remains useful as an extensibility check:

| Mechanism | Backend-owned interpretation |
| --- | --- |
| Basic | Username/password extraction and text encoding |
| Bearer, including MCP HTTP | Token extraction and verification |
| Digest | Parameters, method/target comparison, and any body integrity work |
| DPoP | Access token, proof JWT, and binding to the actual request |
| HTTP Message Signatures | Signature inputs, ordered covered components, and body data |
| Hypothetical delegation/device proof | Credential chain or proof and request binding |

A backend may use a dedicated library and whatever internal structures it needs.
No universal parser or credential wrapper is introduced. Multi-round exchanges
may require custom middleware owning challenge state or successful-response
fields; such middleware can publish the same result via §8.4. OAuth flows remain
outside this project. This table does not promise implementations of these schemes.

### 7.2 One result type, two constrained constructors

Accepted: both constructors return the same result type. The distinction is in
construction intent and validation, not a second middleware execution path.
Completed results directly expose `user`, `credentials`, and `failure`, with the
same observations available through installed-context readers. A backend wrapper
or unit test does not need to construct a scope merely to inspect its result:

```perl
# $existing_backend is an application-owned asynchronous backend in this example.
my $result = await $existing_backend->authenticate($request);
$audit->accepted($result->user->identity)
    if $result->user->is_authenticated;
return $result;
```

This documents readers on the existing result type, not a new wrapper or an
`auth($result)` overload. It does not require a separate context allocation or
change the reference-identity boundary described in §8.1.

| Constructor | User requirement | Omitted options |
| --- | --- | --- |
| `auth_result(user => $user, ...)` | Required duck-typed user reporting `is_authenticated` true | Fresh empty scopes array; no failure |
| `unauth_result(...)` | Duck-typed user reporting `is_authenticated` false | Fresh built-in UnauthenticatedUser, fresh empty scopes array, no failure |

```perl
return auth_result(user => $member, scopes => ['catalog:read']);
return unauth_result();
return unauth_result(scopes => ['catalog:read']);
return unauth_result(user => MyApp::Guest->new);
return unauth_result(
    failure => { message => 'The supplied credentials were not accepted.' },
);
```

Omission requests a default. An explicit `user => undef`, an object missing the
required user methods, or a user whose authentication flag contradicts the
constructor is a construction error. Neither constructor changes that flag or
inserts an `authenticated` scope. `auth_result` is not a general constructor for
both authenticated and unauthenticated users; that earlier suggestion is
superseded by the constrained pair.

Supplied user objects and scopes arrayrefs are retained with normal Perl
reference semantics. A guest may have explicitly granted scopes. Being
unauthenticated is not itself an authentication failure.

Both immediate and Future-backed results are supported. A backend must return a
result value; bare users and `undef` are not alternate return forms. The earlier
`authenticated(...)`, `rejected(...)`, and `undef` rejection conventions are
superseded. Exceptions and failed Futures represent operational/programming
failure and propagate normally, rather than becoming credential rejection.

### 7.3 Rejection information and continuation

Accepted: `failure => { message => ..., code => ... }` records an authentication
failure. The optional `code` is application-defined; PAGI preserves it without
interpreting it as a status or copying it into a header. There is no registry or
required error-code vocabulary. Its message is deliberately safe for public
display, not raw verifier exception text. Existing message-only failures remain
valid. Applications that need finer distinctions can use the code; applications
that do not need them may continue checking failure presence.

```perl
return unauth_result(
    failure => {
        code    => 'token_expired',
        message => 'The token has expired.',
    },
);
```

This retains result-based guest continuation. It does not introduce an expected-
failure exception path or a middleware error-response callback. Operational
exceptions and failed Futures still propagate normally.

An unauthenticated result without failure deliberately establishes a guest.
An unauthenticated result with failure establishes a guest and records rejection.
Both continue downstream in the default flow. The endpoint may serve that guest
or choose to refuse access. A group can make that decision in ordinary middleware
(§11); no Auth-specific callback or trigger contract is needed.

Application refusal code knows which HTTP scheme it serves and explicitly
constructs its response. For a Bearer backend whose failure results exclusively
mean rejected tokens, failure presence is enough to select `invalid_token`. If
the backend also reports malformed input, response code checks that application-
defined code first (§10.2). No JWT-specific or storage-specific taxonomy is
required. Missing credentials have no failure but can still be challenged. No generated challenge object or
response metadata is carried by the context. See §10 for the explicit examples.

### 7.4 Function, class, and instance invocation

Accepted: all public helpers support exported-function, class-method, and
instance-method forms with the same payload arguments and return contracts:

```perl
use PAGI::Auth qw(auth auth_result unauth_result www_authenticate);

my $factory = PAGI::Auth->new;

auth_result(user => $member);
PAGI::Auth->auth_result(user => $member);
$factory->auth_result(user => $member);
PAGI::Auth->new->auth_result(user => $member);

unauth_result();
PAGI::Auth->unauth_result();
$factory->unauth_result();

auth($request);
PAGI::Auth->auth($request);
$factory->auth($request);

www_authenticate('Bearer', realm => 'api');
PAGI::Auth->www_authenticate('Bearer', realm => 'api');
$factory->www_authenticate('Bearer', realm => 'api');
```

`PAGI::Auth->new->auth_result(...)` is also supported directly. An Auth factory
instance is distinct from the request-local context returned by `auth($source)`.
It may be shared across the application, but must not store the current user,
result or failure for an invocation on itself.

Class/instance calls preserve their invocant and normal method dispatch so
subclasses can provide application-wide conventions. Do not normalize calls by
hard-coding the base class and bypassing overrides. Exported functions use base
PAGI defaults; creating a custom instance does not globally redirect them or
silently configure middleware that was not given that behavior.

```perl
package MyApp::Auth {
    use v5.40;
    use parent 'PAGI::Auth';

    sub unauth_result ($self, %args) {
        $args{user} = MyApp::Guest->new
            unless exists $args{user};
        return $self->SUPER::unauth_result(%args);
    }
}

my $AUTH = MyApp::Auth->new;
# Application backends deliberately use this shared factory.
my $result = $AUTH->unauth_result(scopes => ['catalog:read']);
```

This supports application-wide overrides through ordinary Perl subclassing and
shared instances, not a process-global registry. No constructor-option vocabulary
for overriding helpers is introduced by this decision.

### 7.5 Authenticated construction

```perl
return auth_result(
    user => PAGI::Auth::SimpleUser->new(
        identity     => $record->{user_id},
        display_name => $record->{display_name},
    ),
    scopes => ['authenticated', @{ $record->{scopes} }],
);
```

The storage record must already have been validated for this API, including any
expiration and revocation requirements. A backend grants scopes from trusted
verification results; it must not copy permissions requested by an unverified
client and treat them as granted.

## 8. Shared authentication context

### 8.1 Public scope entry

Accepted: PAGI::Auth claims `pagi.auth` as its documented scope key. Its value is
the completed result object returned by `auth_result(...)` or
`unauth_result(...)`, including their class/instance forms. Both constructors
produce the same result type (§7). It is not a bare user, an ad hoc hash of
fields, a Future, or a shared Auth factory.

```perl
my $result = auth_result(user => $user, scopes => ['catalog:read']);
# This assignment shows the entry's value; §8.4 shows installation in a child scope.
$scope->{'pagi.auth'} = $result;
```

The key and its constructor-produced value are a public integration contract,
shared by built-in and custom authentication middleware. Result internals are
not a public hash layout: construct results with the public helpers and use
their public readers (§7.2), or read installed state through `auth(...)`. This replaces the earlier backing-hash
sketch. There is no `failure_policy`, generated challenge, status, or
response-headers member or accessor in the version 1 context.

```perl
my $context = auth($scope);
my $context = auth($request);  # resolves through ->scope

my $user        = $context->user;
my $credentials = $context->credentials;
my $failure     = $context->failure;
```

The helper follows Session/Stash source resolution: one raw scope hash or an
object exposing `scope()`. It resolves the result under `pagi.auth` and exposes
its user, credentials, and optional failure. Missing context or a value outside
the documented result contract is a configuration error; `auth()` does not
silently fabricate an anonymous user or run authentication. This contract does
not require the returned facade to be identical by reference to the stored
result.

### 8.2 State meanings

| Situation | User | Credentials | Failure |
| --- | --- | --- | --- |
| Backend finds no applicable credentials | Backend-chosen guest | Backend grants, empty by default | `undef`; continue |
| Credentials accepted | Backend-established user | Backend-granted scopes | `undef`; continue |
| Deliberate guest result | Backend-established guest | Explicit grants, empty by default | `undef`; continue |
| Credentials rejected | Backend-established guest | Explicit grants, empty by default | Failure information; continue by default |
| Malformed auth request | Backend or request validation detects it | Application owns the response (§10.2) | Optional application-defined code; no automatic parser response |
| Application denies an operation | Established user retained | Established scopes retained | No automatic Auth failure installation or callback |
| Middleware/context absent | Configuration error | Configuration error | Configuration error |

Application refusal does not make an authenticated user anonymous. Missing
credentials alone are not a middleware failure. Operational exceptions are not
stored as credential rejection.

### 8.3 Ownership and lifetime

Authentication establishes a fresh downstream scope with a complete result
under `pagi.auth` rather than overwriting the incoming entry. Its user, credentials,
and failure describe this invocation. Shared middleware, backend, and failure
application instances must not store the current invocation on themselves.

The nearest installed complete context is authoritative. Inner authentication
replaces the user, credentials, and failure together; there is no
automatic merging or fallback. The inner authenticator uses its own configuration.
Outer rejection does not stop execution in the default continuation flow; an
explicitly selected refusal application may stop before the inner authenticator.
An outer observer can still inspect its original context. Scope-bound helper
caches must remain tied to the correct scope identity.

Auth access is observational: no re-verification, lazy database access, or raw
token decoding occurs in `auth(...)` or its ordinary accessors.

Accepted: grant lists use ordinary Perl reference semantics. Success construction
retains the supplied scopes arrayref, and `credentials->scopes` exposes that same
list rather than a defensive copy. Deliberate mutation affects later membership
checks. Helpers must observe the current list rather than a stale membership
cache. Auth does not promise immutable grants or a snapshot of application data.

```perl
scopes => $record->{scopes},          # share the application's list
scopes => [ @{ $record->{scopes} } ],  # explicitly take a snapshot
```

Fresh scopes and result containers do not imply cloning referenced user objects or grant
lists. Header ownership follows existing toolkit conventions; it is not a reason
to introduce an Auth-only defensive-copy rule.

### 8.4 Public context establishment for custom authenticators

Custom authentication middleware constructs a result and installs it using
the existing `PAGI::Utils::Middleware::clone_scope` helper. No new installation
helper is introduced. Built-ins use the same public scope-entry contract. A
backend verifying ordinary Bearer tokens returns a result; its middleware
installs it after awaiting it if necessary.

```perl
use PAGI::Auth qw(auth_result unauth_result);
use PAGI::Utils::Middleware qw(clone_scope);

# Inside custom middleware, after verifying the credentials:
my $result = auth_result(
    user   => $verified_user,
    scopes => ['catalog:read'],
);
# A guest can instead be established with unauth_result(...).
my $child_scope = clone_scope($scope, {
    'pagi.auth' => $result,
});

await $next->($child_scope, $receive, $send);
```

Downstream code continues to use `auth($request)->user`,
`auth($request)->credentials`, and `auth($request)->failure` unchanged.
The public PAGI::Auth documentation must describe this key/value contract and
include this custom-middleware pattern alongside the built-in middleware examples.

Installation performs no I/O. `clone_scope` makes a shallow scope copy and
replaces the entire `pagi.auth` entry, leaving the incoming entry unchanged.
It does not clone the result or its referenced data. Nested authentication uses
this same whole-entry replacement; it does not merge grants or retain an outer
failure. No policy framework, registry, inheritance, or knowledge of middleware
private fields is required.

This boundary permits higher-level frameworks to build their own authorization
behavior. Version 1 does not define that behavior for them.

## 9. Users and resulting credentials

### 9.1 User duck type

Accepted: both result constructors require an object supporting these methods:

```perl
$user->is_authenticated;
$user->identity;
$user->display_name;
```

No PAGI inheritance, role consumption, or registration is required. Additional
application methods are allowed, and the original object remains available
through `auth($source)->user`. Constructors validate method availability and the
authentication flag as specified in §7.2. Identity truthiness never determines
authentication.

Provide an unauthenticated implementation and a simple authenticated
implementation. Proposed names are `PAGI::Auth::UnauthenticatedUser` and
`PAGI::Auth::SimpleUser`.

The default user for absent/rejected credentials is a real unauthenticated
object, not `undef`. A service account may implement the same interface; the
contract must not assume a human or require a database model.

Accepted: the built-in UnauthenticatedUser follows Starlette's defaults:
`is_authenticated` is false, and `identity` and `display_name` both return `''`.
It does not supply a particular label such as "Anonymous" or "Visitor".

SimpleUser requires a defined scalar `identity` (not a reference). An omitted
`display_name` defaults to that identity; an explicitly supplied display name
allows a separate user-facing label. It reports `is_authenticated` true.

```perl
my $user = PAGI::Auth::SimpleUser->new(
    identity     => '42',
    display_name => 'Alice',
);
my $named_user = PAGI::Auth::SimpleUser->new(identity => 'alice');
# $named_user->identity and ->display_name both return 'alice'.
```

These are convenience-class defaults, not additional constraints on custom
users beyond the agreed duck type. SimpleUser performs no credential verification;
the backend must verify credentials before returning an authenticated result.
Do not infer authentication from identity truthiness; use `is_authenticated`.

#### 9.1.1 Custom unauthenticated users

An application-owned Guest can satisfy the duck type directly. The empty
identity below matches the built-in default; its "Visitor" label and domain
method remain application choices:

```perl
package MyApp::Guest {
    use v5.40;

    sub new ($class, %args) { return bless \%args, $class }
    sub is_authenticated ($self) { return 0 }
    sub identity ($self) { return '' }
    sub display_name ($self) { return $self->{display_name} // 'Visitor' }
    sub preferred_catalog ($self) { return 'public' }
}
```

Backend-controlled guests use the same result contract:

```perl
return unauth_result(
    user   => MyApp::Guest->new(display_name => 'Visitor'),
    scopes => ['catalog:read'],
);
```

A custom factory subclass may supply that Guest by default (§7.4). The backend
also runs for missing credentials, so the same mechanism covers that path:

```perl
# Inside a backend using an application-owned factory:
return $AUTH->unauth_result(scopes => ['catalog:read'])
    unless $request->header('Authorization');
```

The ordinary `unauth_result()` default is a fresh built-in Guest and empty scopes.
There is no separate `unauthenticated_user` middleware setting or absence-only
factory. The backend explicitly uses any custom Auth factory; creating one does
not silently redirect exports or middleware behavior. A backend may return a
Future for this path just as for any other result.

### 9.2 Resulting credentials

```perl
my $credentials = auth($source)->credentials;
my $scopes = $credentials->scopes;  # proposed: arrayref
```

Resulting credentials describe the permissions granted by this authentication.
They are separate from credentials the backend extracts from the request.
Naming must make this distinction clear in documentation and signatures.

For example, two tokens may identify user 42 but grant different scopes:

```text
Token A: authenticated, orders:read
Token B: authenticated, orders:read, orders:write
```

Permissions must not be inferred solely from a reusable user object's global
roles when the current token grants fewer permissions.

### 9.3 The `authenticated` scope

Accepted: scopes are supplied explicitly, matching Starlette's membership
semantics. `auth_result(...)` and `unauth_result(...)` do not insert the `authenticated` string.
That string is a conventional scope, not an alias for `user->is_authenticated`.
The user's flag and scope membership are independent observations.

A successful backend may establish an authenticated user with only
`orders:read`. That user passes an `orders:read` scope check but fails a check
for the literal `authenticated` scope. Scope helpers must not repair the grant
list or substitute the user flag. Default `unauth_result()` has empty scopes;
a backend can explicitly grant scopes to its Guest.

This explicitness is intentional in PAGI Tools. A higher-level framework may
offer conventions or constructors that make its own common cases easier.

### 9.4 Boolean scope-inspection helpers

Accepted: `has`, `has_any`, and `has_all` inspect exact single-scope, any-of,
and all-of membership on the resulting credentials. These method names and
the argument rules below are settled; they introduce no enforcement API.

```perl
my $grants = auth($request)->credentials;

$grants->has('notes:read');
$grants->has_any('editor', 'publisher');
$grants->has_all('manager', 'notes:write');

my $can_edit =
       $grants->has('global_admin')
    || $grants->has_all('manager', 'edit');

my $can_publish =
       $grants->has('global_admin')
    || ($grants->has_any('manager', 'editor') && $grants->has('publish'));
```

These are boolean observations over the current granted list. Matching is exact
and case-sensitive. They perform no I/O, mutate no context, select no response,
and invoke no application. No pattern matching, implicit role inheritance, or
administrator override is implied. In these examples the backend deliberately
grants role-like names as ordinary scopes; applications need not model roles
that way. Positive membership checks against nonempty requirements fail on the
default Guest result's empty list.

The user flag is independent: a scope named `authenticated` is still an ordinary
string. A helper does not perform an additional authentication check. Manual
inspection of `credentials->scopes` remains equally supported.

Accepted argument rules:

- `has($scope)` requires exactly one argument.
- `has_any(@scopes)` returns false for an empty list.
- `has_all(@scopes)` returns true for an empty list: there are no requirements
  to satisfy. This is independent of the user's authentication flag.
- Undefined values and references are argument errors. There is no implicit
  arrayref expansion or pattern matching; callers pass a flat list of scope names.

```perl
$grants->has_any();  # false
$grants->has_all();  # true

my @required = ();  # This operation requires no scopes.
$grants->has_all(@required);  # true

$grants->has();                # argument error
$grants->has('read', 'write'); # argument error
$grants->has_any(undef);       # argument error
$grants->has_all(['edit']);    # argument error; use @required for a list
```

These are ordinary boolean and argument semantics, not configurable policy.

### 9.5 Application behavior and manual authorization

An unauthenticated user is a usable object, not an instruction to branch at the
start of every handler. Public code can read `display_name` or use additional
methods supplied by application-owned guest/member classes. Built-in interfaces
remain small; a greeting or domain operation is not a new required user method.

For restricted operations, applications can explicitly inspect the user flag or
scope helpers and return ordinary responses. A higher-level framework can build
its own guards from the same primitives. No `Auth::Require`, `require_scopes`,
`require_authentication`, allow/deny combinator, or `required` option is delivered
in version 1.

An application generating 401 supplies an applicable WWW-Authenticate challenge.
A Bearer insufficient-scope denial uses the appropriate 403 and challenge. An
ownership denial need not claim that another scope would solve the problem.
Those are HTTP/application responsibilities, not automatic effects of boolean
scope inspection. The application owns its response and can use raw headers or
the optional formatter. There is no Auth-specific refusal callback dispatch
for a handler's authorization decision.

## 10. Failure information and explicit HTTP responses

Accepted: the Auth context exposes user, credentials, and optional failure.
It does not supply a challenge object, a generated WWW-Authenticate value, or
response status/headers. The previous middleware-generated response description
is superseded. A few explicit application lines are preferable to indirect
response selection hidden behind the context.

```perl
my $failure = auth($request)->failure;  # Absent when there was no rejection.
$failure->message;                     # Public explanation when supplied.
$failure->code;                        # Optional application code; undef if omitted.
```

The failure input hash supplies the public `message` and optional `code`
accessors; its internal storage is not a public hash layout. Failure records
the backend finding, not generated HTTP response choices.
Missing credentials and a deliberate guest without failure are not rejection.

For a backend whose failures exclusively mean rejected tokens, a Bearer-protected
endpoint can refuse explicitly:

```perl
my $context = auth($request);
unless ($context->user->is_authenticated) {
    my @params = (realm => 'api');
    push @params, error => 'invalid_token' if $context->failure;

    return json_response(
        { error => 'Please authenticate.' },
        status  => 401,
        headers => [
            'WWW-Authenticate' => www_authenticate('Bearer', @params),
        ],
    );
}
```

This code intentionally knows it serves Bearer authentication. It does not know
whether verification uses JWTs or opaque-token storage. Here every failure
means token rejection; this shortcut must not be copied unchanged when the
backend also reports malformed requests. The complete examples below handle
their application-defined `malformed_authorization` code first. The
formatter takes only its supplied arguments and returns a plain string; it
neither reads context nor chooses status, body, realm, or error parameters.
Raw header construction remains equally supported (§3.4).

Response and Pages constructors accept ordinary flat `[name => value, ...]`
header arrays. Preserve order and repeated names. This is distinct from nested
PAGI scope/event pairs and introduces no Auth-specific header container. For example:

```perl
[
    'WWW-Authenticate' => www_authenticate('Bearer', realm => 'api'),
    'WWW-Authenticate' => www_authenticate('Basic', realm => 'api'),
]
```

This illustrates explicitly chosen repeated fields, not automatic multi-scheme
selection. Application code can extract repeated response construction into an
ordinary function when needed; no new response factory or policy API is required.

### 10.1 Agreed Bearer cases

| Condition | Default flow | Explicit refusal in the example |
| --- | --- | --- |
| No applicable credentials | Establish guest, empty scopes, no failure; continue | 401; Bearer realm, without an error parameter |
| Backend returns `unauth_result()` without failure | Establish its guest and grants; continue | 401; Bearer realm, without an error parameter |
| Backend reports rejected token through `unauth_result(failure => ...)` | Establish its guest, grants, and failure; continue | 401; Bearer realm and `error="invalid_token"` |
| Example backend reports code `malformed_authorization` | Establish its guest and failure; continue | 400; Bearer realm and `error="invalid_request"` |
| Backend returns `auth_result(...)` | Establish its user and grants; continue | No automatic refusal |
| Backend storage/service failure | Propagate normally | Do not convert to invalid token |

The application chooses the refusal and supplies these fields; middleware does
not prepare them for later retrieval. A guest flag alone does not mean invalid
credentials. Applications may choose their own body without exposing failure
messages. The realm supplied to `www_authenticate` is explicit application
configuration, not implicitly retrieved from middleware. Generic authentication
middleware has no realm or scheme-specific response configuration. This table
covers the examples' missing credentials, malformed input, and token verification
outcomes; their validation and response handling remain explicit (§10.2).

### 10.2 Standards-based parsing and authorization boundaries

Accepted: follow the applicable HTTP and scheme specifications. Distinguish
malformed authentication requests from invalid credentials; do not classify every
parsing or verification failure as the same outcome.

For Bearer, RFC 6750 §§3–3.1 distinguishes:

| Condition | Standard response guidance |
| --- | --- |
| No applicable credentials at a protected resource | Challenge with 401; omit Bearer error information |
| Expired, revoked, malformed, or otherwise invalid token | `invalid_token`; SHOULD use 401 |
| Malformed authentication request, repeated parameters, or multiple token transmission methods | `invalid_request`; SHOULD use 400 |
| Insufficient token privileges | `insufficient_scope`; SHOULD use 403 |

Examples and scheme implementations should use these recommended statuses and
preserve the required authentication headers. A syntactically valid Bearer field containing a
malformed JWT is token rejection, not necessarily a malformed HTTP authentication
request. The JWT verifier remains application-owned.

RFC 9110 §5.3 restricts duplicate field lines to definitions permitting their
combination; §11.6.2 defines Authorization as one credentials value. For duplicate
Bearer Authorization fields, the intended example response remains:

```http
HTTP/1.1 400 Bad Request
WWW-Authenticate: Bearer realm="api", error="invalid_request"
```

This duplicate-field treatment is our application of the RFCs, not a claim that
they literally require that exact response for every duplicate Authorization
field. Backends must not select an arbitrary first/last duplicate credential
and authenticate it; the Request exposes all field values via `header_all`.

The earlier automatic parser short circuit is superseded. Generic middleware
cannot identify malformed credentials without owning the scheme again. An
application-defined failure code can communicate a backend's finding to the
response-owning application without message matching or automatic HTTP behavior.
No mandatory code taxonomy, response-valued backend result, or callback hook is
introduced. Operational errors continue to propagate normally.

Duplicate singleton headers are a separate Headers/request-validation concern,
not the reason to build an Auth classification framework. Research found that
Starlette Headers preserves duplicates and ordinary lookup returns the first;
PAGI::Headers preserves duplicates and ordinary lookup returns the last. Neither
container currently rejects duplicate Authorization fields. Any future validation
work must specify both where checking runs and how rejection becomes a 400,
rather than merely making a container throw. No Headers implementation change
or automatic validation API is authorized by this Auth decision.

The JWT and opaque-token examples own a small local convention: duplicate
Authorization fields or malformed Bearer syntax return an unauthenticated result
with `code => 'malformed_authorization'`. The protected handler or application
wrapper checks this code first and explicitly selects 400 `invalid_request`.
Missing credentials and unsupported schemes return a guest without failure;
rejected tokens lead to 401 `invalid_token` at the protected endpoint.

This example code neither implements a general singleton-header validator nor
makes the application code a PAGI-standard failure taxonomy. It never selects a
token from duplicate fields. General Headers/request-validation work remains
separate; no hidden middleware parser supplies these responses. Guest results
still reach public endpoints, whose application code chooses their behavior.
These are source-only examples until the new Auth runtime is implemented and
verified. Basic encoding remains a backend decision.

Anonymous access denial, insufficient permissions, and ownership refusal remain
application decisions. Applications may advertise Bearer `scope` and MCP
`resource_metadata` explicitly through the formatter or raw headers. Internal
grant names are not automatically joined, mapped, or restricted to OAuth syntax.
The formatter does not infer required permissions or classify application
refusals; it serializes only supplied arguments.

### 10.3 Version 1 boundary

Applications explicitly own status, body, and authentication headers for their
refusals. Generic authentication middleware neither parses scheme syntax nor
creates error responses. The remaining example/header-validation work is explicit in
§10.2; the context does not gain generated response metadata to conceal it.
Raw header construction remains first-class; the optional formatter returns a
string, not a challenge object.

There is no public failure-calculation callback, callable default policy, cause
object, requirement propagation, continuation-dispatch API, or policy object
attached to the context. The earlier designs remain research, not hidden
implementation requirements.

## 11. Protecting groups with existing middleware

### 11.1 Accepted composition contract

Use the existing `middleware(...)` descriptor and application invocation APIs.
No Auth-specific `on_failure`, `after_auth`, continuation dispatcher, built-in
`RequireLogin`, or new application-return convention is needed. Earlier optional
Auth-hook proposals are superseded by this decision.

Authentication middleware establishes context. An application-owned wrapper
placed after it decides whether to invoke its downstream application or send a
refusal. Omitting the wrapper leaves the guest-continuation behavior unchanged;
endpoints can continue to make decisions inline.

| Existing middleware form | Contract |
| --- | --- |
| `middleware($factory, %config)` | Synchronous factory receives `($next, %config)` and returns an application |
| `middleware($object)` | Configured object implements `wrap($next)` and returns an application |
| `middleware('+MyApp::RequireLogin')` | Existing class resolution/construction, followed by `wrap($next)` |

The first descriptor is the outermost wrapper. Calls to `$next` explicitly
continue execution. A return value of `undef` is not a special continue signal;
there is no output inspection to guess whether an application responded. Await
normal downstream/refusal execution; add no detached Future ownership.

A middleware object uses `wrap`, while a response/application object uses
`to_app`. Backend objects still use `authenticate`. These are existing, distinct
responsibilities.

### 11.2 Required PAGI::Auth cookbook: Protecting a group of endpoints

When documenting the new Auth API, publish this as a cookbook entry in
`PAGI::Auth` POD under **Protecting a group of endpoints** (the practical question:
“how do I protect a bunch of stuff at once?”). It must be a concrete, copyable
example using the shipped composition APIs, not a new helper proposal. Until
Auth is implemented, this is a source-only design example.

```perl
use v5.40;
use Future::AsyncAwait;
use PAGI::Auth qw(auth www_authenticate);
use PAGI::Compose qw(compose);
use PAGI::Response qw(json_response);
use PAGI::Routing qw(route middleware);
use PAGI::Utils qw(invoke_app);

sub require_login ($next) {
    return async sub ($scope, $receive, $send) {
        # This application wrapper protects HTTP routes only.
        if ($scope->{type} ne 'http') {
            await $next->($scope, $receive, $send);
            return;
        }
        my $context = auth($scope);

        unless ($context->user->is_authenticated) {
            my $failure = $context->failure;
            my $malformed = $failure
                && ($failure->code // '') eq 'malformed_authorization';
            my @params = (realm => 'api');
            push @params, error => ($malformed ? 'invalid_request' : 'invalid_token')
                if $failure;
            my $response = json_response(
                { error => $malformed ? 'Malformed Authorization header.'
                                     : 'Please sign in to access this API.' },
                status  => $malformed ? 400 : 401,
                headers => [
                    'WWW-Authenticate' => www_authenticate('Bearer', @params),
                ],
            );
            await invoke_app($response, $scope, $receive, $send);
            return;
        }

        await $next->($scope, $receive, $send);
    };
}

# $token_backend is an application-supplied coderef or authenticate object.
my $protected = compose(
    middleware => [
        middleware('Authentication',
            backend => $token_backend,
        ),
        middleware(\&require_login),
    ],
    routes => [
        route('/me' => sub ($request) {
            return json_response({
                user_id => auth($request)->user->identity,
            });
        }, methods => ['GET']),
        route('/catalog' => sub ($request) {
            return json_response({ items => [] });
        }, methods => ['GET']),
    ],
);
```

This illustrates an HTTP group. The wrapper passes non-HTTP scopes through
before looking up Auth context, including Compose startup/shutdown. Authentication runs first; `require_login` then
covers both routes. Missing credentials and rejected tokens reach the wrapper as
guests, and it explicitly constructs the appropriate Bearer header. An authenticated user
reaches the selected route. The example backend's `malformed_authorization`
failure selects 400 `invalid_request` before the token-rejection case. Public routes belong
outside this protected group or can use authentication alone without the wrapper.

`require_login` is application code, not a PAGI export. The cookbook must explain
that the wrapper chooses its own body and can use ordinary Response, Pages, or
other application objects. Grant inspection can be added using ordinary Perl
boolean expressions; a guest with a grant remains unauthenticated and fails
this particular wrapper's user-flag check. There is no implicit grant requirement.

### 11.3 Middleware object variant

Also document the object and class descriptor forms. Given the preceding
`require_login` function in `main`, the equivalent wrapper object is:

```perl
package MyApp::RequireLogin {
    use v5.40;

    sub new ($class) { return bless {}, $class }
    sub wrap ($self, $next) { return main::require_login($next) }
}

middleware(MyApp::RequireLogin->new)
```

A reusable module can contain the same wrapper body in its own `wrap` method.
Once installed as `MyApp/RequireLogin.pm`, it can use existing class loading:

```perl
middleware('+MyApp::RequireLogin')
```

Neither variant requires a `to_app` method on the middleware object. Its returned
application uses the normal PAGI contract. The factory/wrap phase runs during
assembly; authentication checks happen per invocation, with no current user or
failure stored on the shared middleware object.

### 11.4 Response control

The application owns a custom response. It can choose JSON shape, text, HTML,
Pages rendering, and headers. It supplies status and authentication header
parameters explicitly, following the relevant HTTP and scheme requirements.

The current proposal does not silently rewrite a custom application's emitted
response. Custom responses remain responsible for HTTP requirements, including
the required challenge on 401. Whether any opt-in validation is useful is open;
do not impose a new response-inspection mechanism merely to preserve old code.

An ordinary Pages application can provide the refusal response chosen by
application code. It performs no credential parsing or authorization. This
example renders token-rejection/missing-credential challenge cases only; a caller
handles malformed requests separately. It is not a new Auth default-dispatch API:

```perl
sub sign_in_notice ($request) {
    my @params = (realm => 'api');
    push @params, error => 'invalid_token' if auth($request)->failure;
    return PAGI::Pages->status(
        401,
        headers => [
            'WWW-Authenticate' => www_authenticate('Bearer', @params),
        ],
        detail  => 'Please authenticate.',
    );
}
```

The earlier Auth response generators were research-phase work, not a compatibility
constraint. Do not preserve `challenge`/`forbid`, their outcome model, adapters,
or aliases merely because they exist. The application-owned notice above does
not depend on that model. Any separate response convenience API requires an independent useful
purpose; its preservation or relocation is not required by this design.
Custom failure applications retain the response control described above.

The raw-header path is equally supported. For example, an ordinary application
handler initiating authentication can construct its own 401 using existing
public Response and Headers APIs, without any Auth helper:

```perl
sub request_authentication ($request) {
    my $response = json_response(
        { message => 'An access token is required.' }, status => 401,
    );
    $response->headers->set('WWW-Authenticate',
        'Bearer realm="notes", resource_metadata="https://notes.example/.well-known/oauth-protected-resource/mcp"',
    );
    return $response;
}
```

This illustrates one explicit challenge response, not a universal handler that
converts every failure to 401. Custom applications can choose other appropriate
statuses and headers through the same primitives.

### 11.5 Protocol boundary

The original snapshot's HTTP-only Request limitation is superseded by the
completed refusal work: `PAGI::Request` and the existing RequestResponse adapter
now accept real HTTP, WebSocket, and SSE scopes. Request-handler failure
applications can therefore use that adapter without fabricating an HTTP scope.

Authentication rejection must occur before WebSocket acceptance or SSE start.
Reuse the existing ordinary application invocation and public refusal-admission
rules, retaining the original protocol type and receive/send channels. This does
not make an arbitrary custom application compatible with every protocol; the
selected application remains responsible for its output.

The generic middleware passes lifespan and other unsupported scope types
through unchanged before Request construction; it never calls the backend or
creates Auth context for startup/shutdown. Application wrappers placed at Compose
root must also pass unsupported scopes through before accessing Auth. The HTTP-
only cookbook demonstrates that rule. A wrapper protecting WebSocket or SSE must
explicitly use the appropriate admission/refusal behavior for those protocols.

The eventual implementation plan must specify and verify these paths through the
public PAGI contract, including normal cancellation and terminal cleanup. No
server internals or additional Auth-owned lifecycle mechanism are needed.

### 11.6 Application-controlled authorization responses

Application-owned middleware or a handler makes the authorization decision.
There is no separate Auth callback to activate. A handler returns
an ordinary Response/Pages/application object; a native app invokes it through the existing
public application API. WebSocket and SSE handlers use their existing public
`deny`/`decline` methods before acceptance or response start.

A custom authenticator may install its own authentication failure through the
small public establishment boundary and invoke its chosen application. This
requires no general guard rejection-preparation API. The earlier
`failure_policy->prepare_rejection` design is deferred research, not a version 1
contract.

## 12. Consolidated opaque-token sketch

The broader application example is the separate
[Notes API mockup](2026-09-19-auth-notes-example.md). It exercises optional
identity, distinct grants for the same user, inline scope checks, and ordinary
authentication failure applications. The existing apples example remains focused on routing. Use the
Notes example and its focused variations to evaluate API elegance as this design
develops; the smaller `/me` sketch below remains a useful introduction.
The example family must cover every public Auth capability delivered by this
project, including all supported backend/failure-app forms, defaults, context
access, boolean scope inspection, extension boundaries, and protocol admission. Its coverage table
is a completion gate: every finalized API needs concrete example code and an
observable outcome. Unsettled APIs remain explicitly pending until researched;
the example must not silently choose their contracts or expand project scope.
Use multiple independently understandable examples whenever that makes the API
clearer to learn or evaluate. Complete coverage is required across the example
set, not inside one application; the Notes mockup does not mandate a single file
or a single example directory. An index must identify each example's purpose.

The Notes companion predates the latest constructor/continuation amendment and
requires reconciliation before it can serve as a current API acceptance example.
The implementation plan must explicitly replace its removed `on_failure`, old
result constructors, and failure response-metadata accessors. Its historical
warning is not permission to implement those APIs; use the current spec and JWT
variants as authority while preserving its useful coverage scenarios.

The [JWT learning sandbox](../../../examples/auth-jwt-sandbox/README.md) contains
the Perl application and browser page corresponding to the Python example. It
is source for reviewing this proposed API, not a runnable Auth implementation;
it uses `auth_result` / `unauth_result` and explicit status/header construction. Its
application-owned middleware protects two mounted routes using the existing
composition API, while the learning page and login remain public. Its `app2.pl`
variant instead checks authentication inline, matching the three-route Python
example. Both use the same explicit Bearer response pattern.

This sketch places the authentication check inside `/me`, like the user's
Python example. It checks the user flag rather than a conventionally named
scope. These Auth APIs are still unimplemented; the example records the design,
not runnable current library behavior.

```perl
use v5.40;
use Future::AsyncAwait;

use PAGI::Auth qw(auth auth_result unauth_result www_authenticate);
use PAGI::Compose qw(compose);
use PAGI::Routing qw(route middleware);
use PAGI::Response qw(json_response);
use PAGI::Auth::SimpleUser;

sub build_app ($token_store) {
    my $authentication = middleware('Authentication',
        backend => async sub ($request) {
            my @authorization = $request->header_all('Authorization');
            return unauth_result() unless @authorization;

            my $token;
            if (@authorization == 1) {
                my ($scheme) = $authorization[0] =~ /\A(\S+)/;
                return unauth_result() if defined($scheme) && lc($scheme) ne 'bearer';
                ($token) = $authorization[0] =~ /\ABearer +([A-Za-z0-9._~+\/-]+=*)\z/i;
            }
            # Never select a token from duplicate Authorization fields.
            return unauth_result(
                failure => {
                    code    => 'malformed_authorization',  # This application's convention.
                    message => 'Expected one Authorization header containing a Bearer token.',
                },
            ) unless defined $token;

            my $record = await $token_store->find_active($token);

            return unauth_result(
                failure => { message => 'The access token was rejected.' },
            ) unless $record;

            return auth_result(
                user => PAGI::Auth::SimpleUser->new(
                    identity     => $record->{user_id},
                    display_name => $record->{display_name},
                ),
                scopes => $record->{scopes},
            );
        },
    );

    return compose(
        routes => [
            route('/me' => sub ($request) {
                my $context = auth($request);
                my $user = $context->user;
                unless ($user->is_authenticated) {
                    my $failure = $context->failure;
                    my $malformed = $failure
                        && ($failure->code // '') eq 'malformed_authorization';
                    my @params = (realm => 'api');
                    push @params, error => ($malformed ? 'invalid_request' : 'invalid_token')
                        if $failure;
                    return json_response(
                        { error => $malformed ? 'Malformed Authorization header.'
                                             : 'Please authenticate.' },
                        status  => $malformed ? 400 : 401,
                        headers => [
                            'WWW-Authenticate' => www_authenticate('Bearer', @params),
                        ],
                    );
                }

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

After loading the application's backend class normally, the callback can be
replaced by a directly constructed instance:

```perl
backend => MyApp::TokenBackend->new(store => $token_store)
```

To protect several routes together, add an application-owned wrapper using the
existing middleware descriptor, as shown in §11. Neither backend replacement nor
wrapper composition changes how downstream handlers access their user.

## 13. Intended protected-endpoint HTTP traffic

These exchanges describe the protected `/me` design in section 12. They are not
claims that the proposed Auth APIs are implemented. Assume HTTPS;
message-framing and unrelated headers are omitted.

### 13.1 Success

```http
GET /me HTTP/1.1
Host: api.example.com
Authorization: Bearer valid-opaque-token
Accept: application/json
```

Backend accepts the token and middleware installs its user and grants. The
endpoint checks the user flag and returns:

```http
HTTP/1.1 200 OK
Content-Type: application/json

{"user_id":"42"}
```

### 13.2 Missing credentials at a protected endpoint

```http
GET /me HTTP/1.1
Host: api.example.com
Accept: application/json
```

The backend runs, finds no credentials, and returns `unauth_result()`. Middleware
installs that guest result and invokes the endpoint. Its explicit check returns
this ordinary JSON response:

```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer realm="api"
Content-Type: application/json

{"error":"Please authenticate."}
```

The client obtains a token separately and may retry. This response does not
issue a token or imply a login redirect. No Auth-specific callback is involved.

### 13.3 Invalid token

```http
GET /me HTTP/1.1
Host: api.example.com
Authorization: Bearer expired-opaque-token
Accept: application/json
```

The backend returns `unauth_result` with failure information. Middleware
establishes that guest and invokes the endpoint. Its authentication check uses
an explicitly constructed Bearer header and returns its own message:

```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer realm="api", error="invalid_token"
Content-Type: application/json

{"error":"Please authenticate."}
```

These bodies match the endpoint in section 12. It does not expose backend
messages or depend on backend-specific error codes.

### 13.4 Other outcomes

- Optional failure codes can distinguish backend findings. Request-validation
  integration is separate; the intended Bearer malformed-request response remains
  400 `invalid_request` (§10.2).
  Generic middleware supplies no scheme-aware short circuit.
- A scope helper reports a missing grant as false. Application code decides
  whether to refuse access and constructs the appropriate response; identity and
  grants are not changed by inspection.
- A token-store outage propagates through normal application error handling.
  The resulting 5xx policy is not an Auth invalid-token response.

## 14. Relationship to prior documents and implementation

The [Phase 1 specification](2026-09-04-authentication-outcomes-design.md) and
[cookie-boundary ruling](../../../.pagi-auth-cookie-boundary-ruling.md) are
historical inputs. The current conversation changes the following assumptions:

- Phase 1 APIs are available for reconsideration, not frozen by this work.
- The target is more than response factories: it includes backends, user and
  credentials context, authentication failure applications, and scope inspection.
- Cookie login remains outside scope; Session is not automatically an Auth
  dependency or a cookie identity provider.
- `required => 1|0`, `Auth::Require`, branching combinators, and public failure
  policy/preparation APIs are deferred. Earlier acceptance of those directions
  is superseded by the version 1 scope reduction.
- Auth-specific failure callbacks are superseded by ordinary middleware
  composition. Request handlers retain their normal one-Request convention;
  native applications and middleware use their existing contracts.
- `auth(...)->user->identity` replaces the earlier sketch's direct
  `auth(...)->identity` as the primary illustrated identity access.
- Backends return an explicit user plus scopes in the latest sketch, rather
  than only a scalar identity.

Do not carry historical comparative claims into public docs without checking
them. For example, Starlette does implement `next` behavior for redirecting
guards. The cookie-boundary decision does not depend on claims that other
frameworks cannot express comparable responses.

## 15. Remaining decisions and implementation planning

The request-only backend removes Basic encoding, parsed credential shapes,
scheme selection, and the absence-only Guest factory from the core decision
list. Those are backend/application choices. Higher-level frameworks can provide
conventions without changing PAGI Tools.

The listed API decisions are settled: optional application-defined failure code
and message, built-in user defaults (§9.1), scope helper names and argument rules
(§9.4), and the `PAGI::Auth::www_authenticate` formatter (§3.4). Opaque challenge
values use ordinary header strings in v1; extension parameters need no allowlist.

Next is implementation planning and a consistency pass over the example family,
not another round of speculative API expansion. Duplicate-header validation
remains separate work. The examples now own their limited malformed-header
classification and responses (§10.2); this is not a general Headers validator. This records API decisions,
not approval to implement or publish the runtime.

The plan must also cover ordinary implementation work: public class names (the
working middleware name is `Authentication`), validation, avoiding accidental
credential logging/retention by the toolkit, HTTP/WS/SSE admission and lifecycle
checks, docs/example coverage, and removal of superseded research APIs. These
are not invitations to add configuration or reopen agreed contracts. Whole-entry
context replacement, live grant references, public-safe failure messages, and
ordinary application invocation are already settled. Automatic scheme fallback
and merging remain outside the core.

Do not expand the failure contract by introducing expected-failure exceptions,
response-valued backend results, or middleware dispatch hooks. If the proposed
shape needs several special cases, return to design discussion.

## 16. Future validation criteria

These are acceptance topics for a later plan, not tests run for this document.

1. Direct coderef and authenticate-object backends have equivalent observable
   results; immediate/Future success and rejection work, and operational failures
   propagate. Both receive only the same Request.
2. Application code controls backend construction and sharing. Middleware retains
   supplied closures/instances and performs no backend loading, reconstruction,
   or authentication during assembly. Shared objects retain no current invocation
   state.
3. Absent credentials still invoke the backend. Its `unauth_result()` supplies
   default guest/empty scopes, or it can choose a custom guest and grants through
   the same result constructor. Missing context remains a configuration error.
4. Same-user credentials can carry different grants. Supplied scope arrays retain
   their identity; later mutations are visible to membership helpers and explicit
   application copies isolate lists.
5. No scope is inserted implicitly. The user flag and scope membership remain
   independent, including an authenticated user with no grants.
6. `has`, `has_any`, and `has_all` exercise exact, case-sensitive
   single/any/all matching, including global-admin OR manager-AND-edit. They
   return booleans without I/O, response dispatch, or context mutation. Verify
   empty any=false and all=true, exactly one argument for `has`, and rejection
   of undefined/reference arguments. No implicit arrayref expansion or enforcement.
7. Missing credentials and backend guest results invoke the endpoint by default.
   An inline check or application-owned middleware explicitly constructs 401
   and its authentication headers. No Auth-specific dispatch hook is involved.
8. Backends own parsing and verification; generic middleware makes no scheme,
   encoding, or credential-absence decisions. Application examples satisfy the
   intended HTTP matrix through their explicit parsing and response code. Storage
   failures are not invalid-token responses.
9. Request handlers, ordinary `to_app` objects, and explicitly adapted native
   applications observe the same authentication failure and use normal execution.
10. Default Pages rendering and custom failure apps preserve their documented
    behavior. Flat headers preserve order and duplicates. Custom apps retain
    control over status, body, and headers without response rewriting.
11. Failure presence records rejection, while a guest alone does not. JWT and
    opaque-token backends allow the same explicit Bearer refusal code without
    verifier-specific code translation; application-owned malformed-input codes
    are handled before the token-rejection shortcut. The formatter reads no context and
    selects no response behavior; it returns only a header string.
12. Built-in and custom guest objects support public application behavior without
    an obligatory authentication branch. A bare guest is not a backend result.
13. Nested authenticators replace complete user/credentials/failure contexts,
    preserve outer containers, and use their own scheme configuration. No automatic
    fallback or cross-request state leakage occurs.
14. A custom authenticator installs a completed `auth_result` or `unauth_result`
    under `pagi.auth` using `clone_scope`, with unchanged context consumers and
    scope helpers. Built-ins use the same entry contract. Cover success, guest,
    rejection, invalid entry values, and nested whole-entry replacement without
    changing the outer scope entry or defensively copying supplied references.
15. HTTP/WS/SSE authentication refusal uses ordinary applications and public PAGI
    behavior, with no server-specific internals or new cancellation ownership.
    Application permission checks precede WS acceptance/SSE start where needed.
16. Example coverage includes explicit authentication and permission responses,
    manual ownership checks, header primitives, and MCP discovery/scope challenges.
    There is no automatic OAuth grant mapping or whole-operation aggregation.
17. Every delivered public API and supported form has example code and an
    observable result across the example family. Deferred research APIs are not
    implementation or example-completion requirements.
18. Function, class, and instance forms agree for every public helper. A subclass
    override is respected by class/instance calls, including direct chained
    `new->auth_result` usage; exported functions retain base defaults.
19. Both constructors validate all user duck-type methods and their respective
    authentication flag. Test missing/undefined users, mismatched flags, custom
    Guests, guest grants, omitted scopes, fresh default objects/arrays, and live
    supplied references. Both constructors produce the same result type.
20. Shared Auth factories carry no current invocation state. A custom factory
    does not silently affect exported calls or backends that do not use it.

21. The PAGI::Auth cookbook includes **Protecting a group of endpoints** with
    at least two routes, correct middleware ordering, factory/object/class forms,
    explicit awaited downstream delegation, and ordinary refusal invocation.
    Verify authenticated access, absent credentials, rejected tokens, deliberate
    guests, and the effect of omitting the wrapper. It introduces no public API.
22. Verify the example backend detects malformed authentication
    requests and the chosen application response path returns 400 `invalid_request`
    for duplicate Bearer fields. A malformed JWT in valid Bearer field syntax
    remains token rejection with explicit 401 `invalid_token`. No scheme parser
    or error-response dispatch is implicit in the generic middleware.

23. Both JWT sandbox variants and the Auth cookbook use literal 401 and explicit
    WWW-Authenticate construction for authentication refusal. No active example
    consumes generated response metadata from the auth context or failure value.
    Cover absent credentials, deliberate guest, and rejected token, preserving
    the distinction between failure presence and the user's authentication flag.

24. Coderefs receive exactly `($request)`; objects receive the normal
    invocant plus that Request through `authenticate`. Verify that backend
    strings, constructor descriptions, and objects without `authenticate` are
    rejected before serving requests. No public backend generator is required or
    documented.

25. Middleware supplies a real PAGI::Request with current scope and receive
    channel. Verify scope identity/type, existing helper access, and no implicit
    body reads for HTTP, WebSocket, and SSE. It supplies no parsed-credentials
    argument. Custom backends can interpret headers and other request data without
    adding a scheme registry, encoding setting, or middleware parser.

26. Failure codes are optional and preserved for application inspection through
    `failure->code`; omission returns undef. Code/message changes do not cause
    middleware response selection. Guest continuation and operational-error
    propagation are unchanged.
27. Built-in Guest returns a false flag and empty identity/display strings.
    SimpleUser requires a defined scalar identity and defaults an omitted display
    name to it; custom user duck types do not inherit these constructor constraints.

28. Header formatting supports exported-function, class, and instance forms,
    scheme-only output, ordered named parameters, quoting/escaping, empty values,
    and arbitrary valid extension names. Verify rejection of malformed argument
    pairs, invalid names/value bytes, references, undef values, and case-insensitive
    duplicate parameter names. It never infers HTTP behavior or reads context.
    Examples demonstrate repeated challenge headers and raw opaque-token values;
    no token overload is implemented in v1. Document raw headers for schemes
    requiring unquoted parameters, including Digest algorithm/stale.

29. Root Authentication passes lifespan and other unsupported scope types through
    unchanged, with no Request creation, backend call, or Auth entry. Verify
    startup and shutdown reach Compose's handler through the cookbook stack;
    its HTTP-only protection wrapper does not inspect Auth on those events.
30. Completed results from either constructor expose `user`, `credentials`, and
    `failure` before scope installation. Exercise a backend wrapper or direct
    backend test using those readers without an artificial scope.

## 17. Sources and review status

Normative references:

- [RFC 9110 section 5.3: field order and combination](https://www.rfc-editor.org/rfc/rfc9110.html#section-5.3)
- [RFC 9110 section 11: HTTP Authentication](https://www.rfc-editor.org/rfc/rfc9110.html#section-11)
- [RFC 9110 section 11.4: other authentication mechanisms](https://www.rfc-editor.org/rfc/rfc9110.html#section-11.4)
- [RFC 6750: Bearer token usage](https://www.rfc-editor.org/rfc/rfc6750.html)
- [RFC 7617: Basic authentication](https://www.rfc-editor.org/rfc/rfc7617.html)
- [RFC 7616: Digest authentication](https://www.rfc-editor.org/rfc/rfc7616.html)
- [RFC 9449: DPoP](https://www.rfc-editor.org/rfc/rfc9449.html)
- [RFC 9421: HTTP Message Signatures](https://www.rfc-editor.org/rfc/rfc9421.html)
- [RFC 4559: Negotiate exchange](https://www.rfc-editor.org/rfc/rfc4559.html)
- [MCP HTTP authorization](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/specification/2026-07-28/basic/authorization/index.mdx)

Local design references:

- [Phase 1 outcome design](2026-09-04-authentication-outcomes-design.md)
- [Completed continuation handoff](../plans/2026-09-17-tools-auth-continuation-complete-handoff.md)
- [Cookie-boundary note](../../../.pagi-auth-cookie-boundary-ruling.md)
- `lib/PAGI/Session.pm` and `lib/PAGI/Stash.pm`: standalone helper conventions.
- `lib/PAGI/Routing.pm` and `lib/PAGI/Routing/Middleware.pm`: handler/application
  distinction and declarative construction.
- `lib/PAGI/Auth.pm`: current completed-result, context, and challenge API;
  the former `lib/PAGI/Auth/Outcomes.pm` was removed by Auth v1.

The following records historical reviews, not current scope approval. The
2026-09-19 version 1 reduction supersedes their guard and public failure-policy
recommendations. Full pre-reduction prose and examples are preserved in the
[research snapshot](2026-09-19-auth-authorization-policy-research-snapshot.md) and
[earlier Notes mockup](2026-09-19-auth-notes-policy-research-snapshot.md).

This snapshot received an inline consistency review when written. On 2026-09-19,
a focused team review covered HTTP authentication semantics, PAGI middleware and
application integration, and adversarial API/simplicity concerns. All three
supported the middleware approach with refinements: public failure preparation,
complete context replacement, and scheme-owned wire formatting. The user accepted
recording those choices, along with the preceding explicit-scope and anonymous
user customization decisions.

The subsequent full-spec team review and ecosystem survey are recorded in
[the consolidated review](../../../.superpowers/brainstorm/2026-09-19-auth-spec-survey/consolidated-review.md).
During the recommendation walkthrough, the user approved public context
establishment for custom authenticators as an addition to scope, with its API
shape still requiring research. The user subsequently rejected mandatory
defensive copying of grants in favor of documented ordinary Perl reference
semantics (§8.3). The review's original copying recommendation is superseded by
that decision. The user also accepted one ordinary Pages-based default failure
application (§11.4), explicitly reaffirming that research-phase Auth response
generators need not be preserved. Remaining failure-classification and message
details are still open. The user also accepted header-based naming and a direct,
first-class path through ordinary header primitives (§3.4), without mandatory
Auth helper objects or response rewriting. Other recommendations remain proposals
unless separately accepted. Failure headers now have an accepted flat arrayref
shape matching Response and Pages constructors, preserving order and duplicates
(section 10).

This is still not an implementation approval or a finalized whole-design review.
No Auth implementation or runtime verification was performed by that design
review. Continue editing incrementally and preserve the distinction between
accepted behavior and provisional API mechanics.

The 2026-09-20 amendment records the subsequently accepted uniform result type,
constrained authenticated/unauthenticated constructors, three-method user duck
type, and function/class/instance invocation with subclass dispatch. Guest
results continue by default; optional failure records rejection and the scheme
initially supplied an observational challenge description. That description
was subsequently removed in favor of explicit application status/header code.
The subsequent group-protection ruling below supersedes the optional-hook question.
The earlier middleware short-circuit and general `auth_result` assumptions are
superseded. This amendment was reviewed for document consistency only, not by a
new expert team or runtime tests.

The later 2026-09-20 group-protection decision uses existing middleware factories
and `wrap($next)` objects, with explicit downstream delegation and ordinary
refusal applications. It removes the proposed Auth dispatch hooks. The Auth POD
must teach the pattern in a group-protection cookbook entry. Its original scheme-
parsing short circuit is superseded by the later request-only backend decision;
application middleware continues to own authorization.

The final response-simplicity decision removes middleware-generated challenge
objects and response metadata from the public context. User, credentials, and
optional failure are sufficient. Applications explicitly choose 401 and format
WWW-Authenticate, adding Bearer `invalid_token` for explicit rejection. The
formatter stays a pure string formatter. The then-retained parser short circuit
is superseded below; required HTTP headers remain application responsibilities.

The backend-simplicity discussion first considered ordinary objects with an
optional callback adapter. The final decision accepts coderefs and objects with
`authenticate` directly, removing the generator as well as the earlier descriptor.
No backend class-name resolution, constructor descriptions, or backend factories
are supported. The result contract is unchanged. Existing middleware descriptors
are unaffected.

The first backend-input decision supplied parsed credentials plus Request. That
approach is now superseded: it forced too many scheme and application choices
into middleware. The accepted contract is `($request)` for callbacks and
`($self, $request)` in object methods. Backends own extraction, interpretation,
verification, and missing-credential results. Generic middleware only invokes,
awaits, installs the completed `pagi.auth` result, and delegates. Optional parsing
helpers and higher-level framework adapters need no special support in this core.
The old shape is preserved in the presented-credentials research snapshot.

This also removes the absence-only Guest factory and the automatic malformed-
request parser response. The former is ordinary backend result construction;
the latter has no automatic replacement. The subsequent accepted refinement adds
an optional application-defined failure code, while duplicate-header validation
is tracked as separate request-validation work (§10.2).

The subsequent user-default decision follows Starlette for the built-in Guest:
false authentication flag and empty identity/display strings. SimpleUser requires
a defined scalar identity and defaults an omitted display name to that identity.
Custom users retain the agreed duck type; built-in defaults do not verify credentials.

The 2026-09-20 expert review's four recommendations were approved: explicit
lifespan pass-through, public completed-result readers, qualified failure-response
examples with local malformed-input codes, and a raw-header example for scheme-
specific quoting requirements. See the [consolidated review](../../../.superpowers/brainstorm/2026-09-20-auth-api-review/consolidated-review.md).
Only the spec and source examples are updated; no runtime implementation or
new general header-validation API is introduced.
