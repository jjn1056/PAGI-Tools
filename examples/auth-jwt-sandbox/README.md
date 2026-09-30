# JWT learning sandbox

This runnable example is the PAGI version of the Starlette JWT learning
application from the design discussion. It uses the version 1 Auth API and the
generic `Authentication` middleware. The Request Bearer helper parses the
Authorization header; JWT decoding, verification, and response policy remain
ordinary application code.

This revision follows the spec's **constrained result constructors**, **explicit
HTTP responses**, and **ordinary middleware composition**. `auth_result` requires
an authenticated user; `unauth_result` supplies a fresh unauthenticated user and
empty scopes by default. Both produce the same result type. Backends receive only
the Request, use its helper to parse Authorization, and own JWT decoding and
verification, including the policy for missing credentials.

Malformed Bearer syntax and duplicate Authorization headers are reported with
this application's `malformed_authorization` failure code. Protected response
code handles that case explicitly as 400 `invalid_request`; token verification
failures remain 401 `invalid_token`. The Request Bearer helper parses the field;
the application decides how failures become responses. The dedicated integration
test exercises these responses through both real applications.

In `app.pl`, application-owned `require_login` middleware protects two routes.
It either sends an ordinary response or explicitly calls the downstream app.
There is no Auth-specific `on_failure` or `after_auth` callback and no new guard
API. Existing Compose, Routing, and invocation APIs provide the composition.

`app2.pl` is the smaller, direct comparison with the Python application: it has
only `/`, `/login`, and `/protected`, with the authentication check inside the
protected handler. It uses the same backend and explicit Bearer response, without
the application-owned wrapper or an extra catalog endpoint. Both files are
standalone applications and share the same browser page.

Optional `failure => { message => ..., code => ... }` records the backend's
finding. Application code checks its own malformed-header code first, then uses
failure presence for token rejection. It chooses 400/401 and constructs the
Bearer header explicitly, without interpreting JWT-specific verifier codes.
There is no generated challenge object or response metadata on the context.
Backend guest results continue to application code, which decides whether to
refuse access.

## Work map

| Item | Value |
| --- | --- |
| Repository | `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` |
| Task | JWT sandbox example for Auth v1 design review; no external ticket |
| Branch | `feature/universal-connection-tools` |
| Base commit | `f731ea9ae7580063e836540a1386ce7f84ce1ce7` |
| Owned changes | This example and example/spec links; no library implementation |
| Deployment boundary | Local review artifact; no deployment or release |
| Push target | None |

## Read the application

- [app2.pl](app2.pl) is the closest Python comparison: JWT backend, dummy login,
  inline authentication check, and the original three routes. Generic authentication middleware
  establishes context across the app; only `/protected` requires authentication.
- [app.pl](app.pl) contains the JWT backend, dummy login, application-owned
  `require_login` wrapper, and four routes. The two protected routes share one
  mounted middleware stack.
- [public/index.html](public/index.html) contains the browser walkthrough. It
  requests a token, sends it to the protected route, and tries a bad or absent
  token. Responses display both status and the authentication challenge.

The group-protection variant `app.pl` keeps the Python example's page, login, and protected response,
then adds a second protected route to demonstrate group protection:

| Endpoint | Behavior |
| --- | --- |
| `GET /` | Serve the learning page without requiring authentication |
| `POST /login` | Issue a one-hour HS256 token for the dummy `alice_dev` account |
| `GET /protected` | After the shared wrapper permits access, show identity and granted scopes |
| `GET /protected/catalog` | Use the same protection, then return a small sample catalog |

The `role` claim is retained from the Python example. It does not automatically
grant permissions: the backend deliberately supplies only `authenticated`.
The shared wrapper checks `user->is_authenticated`, not a scope of that name. The
[Notes example](../auth-notes/README.md)
separately explores single/any/all scope checks and compound authorization;
its executable extension companions cover the remaining Auth interfaces.

## Backend callback or object

The `backend` option accepts exactly a coderef or an object implementing
`authenticate($request)`. Both sandbox variants pass their JWT callback
directly:

```perl
sub jwt_backend ($request) {
    my $token;
    my $parsed = eval {
        $token = $request->bearer_token(raise_on_error => 1);
        1;
    };
    return unauth_result(failure => {
        code => 'malformed_authorization',
        message => 'Expected one Authorization header containing a Bearer token.',
    }) unless $parsed;
    return unauth_result() unless defined $token;
    # Verify $token outside the parsing eval, then return an Auth result.
}

middleware('Authentication', backend => \&jwt_backend);
```

For an application-owned class loaded with `use MyApp::JWTBackend`, pass its
instance directly instead:

```perl
my $jwt_backend = MyApp::JWTBackend->new(key => $secret);

middleware('Authentication',
    backend => $jwt_backend,
);
```

`MyApp::JWTBackend` is illustrative, not a bundled verifier. Its `authenticate`
method receives the same PAGI::Request as the callback, in
addition to its normal invocant. Both forms return the same Auth result, directly
or through a Future, and propagate operational errors normally. No PAGI base
class is required.

There is no `backend()` generator, backend descriptor, class-name lookup, or
implicit construction. The application owns its closures, instances, and sharing.
The existing `middleware(...)` descriptor retains its normal behavior.

The sole argument is the existing PAGI::Request, with raw scope available via
`->scope`. The backend calls `bearer_token(raise_on_error => 1)` to read exactly
one well-formed Bearer value before JWT verification. Missing headers and
unsupported schemes return a guest without failure; malformed Bearer
syntax or duplicates return the local `malformed_authorization` failure code.
Generic middleware does not inspect Authorization, choose a scheme, or read the
body. OAuth acquisition, registration, discovery, and refresh remain separate.

Completed results also expose `user`, `credentials`, and `failure` directly.
A backend unit test or wrapper can inspect its result without installing a scope:

```perl
my $result = jwt_backend($request);  # This sandbox backend is synchronous.
my $user = $result->user;
my $failure = $result->failure;
```

Generic Authentication processes HTTP, WebSocket, and SSE scopes. It passes
startup/shutdown (`lifespan`) and other scope types through before creating a
Request or calling the backend. The `require_login` wrapper in `app.pl` is
explicitly HTTP-only and passes other types through before reading Auth context;
that also permits using it at Compose root as shown in the spec's cookbook.

## Authentication and failure paths

The wrapper and mount discussion below describes `app.pl`. In `app2.pl`, the
same missing/rejected-token results reach `protected_route`, whose inline check
returns the same refusal response. Its page and login handlers allow guests.
Unlike the mounted variant, its backend runs for all three routes, including
requests without Authorization. Guest and rejected-token results still reach the
page and login handlers; generic middleware does not automatically refuse them.

The callback handles credential extraction and JWT verification, returning a
user and grants in the same result shape for either outcome:

```perl
auth_result(user => $member, scopes => ['authenticated'])
unauth_result(failure => $public_failure)
unauth_result(user => $guest, scopes => ['catalog:read'])
```

A missing header is handled inside the backend with `return unauth_result()`,
establishing an unauthenticated user with empty scopes and no failure. An invalid JWT produces an explicit
`UnauthenticatedUser`, empty scopes, and optional public failure information.
A custom guest must implement `is_authenticated`, `identity`, and `display_name`,
and report false for `is_authenticated`. `unauth_result(user => $guest, ...)`
retains that object; no PAGI inheritance is required. A guest can have explicit
grants, but still fails this wrapper's authentication check.

In both cases authentication middleware continues to `require_login`. That application-owned
middleware checks the user flag, then either invokes a refusal application or
awaits `$next->($scope, $receive, $send)`. Neither protected endpoint repeats the
check. The relevant composition in `app.pl` is:

```perl
mount('/protected',
    middleware => [
        middleware('Authentication',
            backend => \&jwt_backend,
        ),
        middleware(\&require_login),
    ],
    routes => [
        route('/' => \&protected_route, methods => ['GET']),
        route('/catalog' => \&catalog, methods => ['GET']),
    ],
),
```

The first middleware is outermost: Authentication establishes context before the wrapper
reads it. The mount maps `/protected` to its inner `/` route. The public `/` and
`/login` routes are outside the mount and do not run either middleware.

The wrapper chooses its status, realm, message, and header parameters locally:

```perl
my $failure = $context->failure;
my $malformed = $failure
    && ($failure->code // '') eq 'malformed_authorization';
my @params = (realm => 'jwt-sandbox');
push @params, error => ($malformed ? 'invalid_request' : 'invalid_token')
    if $failure;

my $response = json_response(
    { error => $malformed ? 'Malformed Authorization header.'
                         : 'Please sign in to access the vault.' },
    status  => $malformed ? 400 : 401,
    headers => [
        'WWW-Authenticate' => www_authenticate('Bearer', @params),
    ],
);
```

`www_authenticate` only formats the supplied scheme and parameters into a plain
header string. It does not inspect context or select status/error parameters.
`app2.pl` uses these same lines inside its protected handler. The wrapper in
`app.pl` sends the resulting response using public `invoke_app`.

Missing credentials and a deliberate Guest without failure get a bare Bearer
challenge with 401. The application handles `malformed_authorization` first as
400 `invalid_request`; other failures from this backend mean token rejection and
produce 401 `invalid_token`. This is a small convention shared by this backend
and its response code, not a PAGI error-code registry. An opaque-token backend
can follow that same local convention. Generic middleware has no realm or
response configuration; application code supplies those choices explicitly.

Omitting `middleware(\&require_login)` would let guest results reach the mounted
handlers; those handlers could then implement public Guest behavior or their own
checks. Being unauthenticated alone does not imply credential rejection.

The wrapper is an ordinary middleware factory, not a new Auth helper. The object
alternative is the existing `middleware($object)` form with `wrap($next)`, not
`to_app` on the middleware object. Its returned application uses normal PAGI
execution. No special `undef` return convention, output inspection, or separate
Future ownership is involved.

The `eval` is deliberately limited to the configured JWT decode/verification
call. Crypt::JWT reports failures with `croak`; this small fixed-key example
maps exceptions from that call to a generic rejection. That includes a possible
configuration failure inside the call, so this is not a general error adapter
for an operational key service. Errors elsewhere in the backend propagate.

Compared with the supplied Python example, the refusal responses include the
required WWW-Authenticate challenge, and rejected tokens use a Bearer 401.
The UI says a JWT payload is **decoded**, not decrypted: HS256 signs this token;
it does not encrypt its contents.

## Expected traffic

```http
POST /login HTTP/1.1
Host: localhost:5000

HTTP/1.1 200 OK
Content-Type: application/json
Cache-Control: no-store

{"token":"<signed JWT>"}
```

```http
GET /protected HTTP/1.1
Host: localhost:5000
Authorization: Bearer <signed JWT>

HTTP/1.1 200 OK
Content-Type: application/json

{"message":"Success! You accessed the vault.","user_authenticated":true,"username":"alice_dev","assigned_scopes":["authenticated"]}
```

Without Authorization, the wrapper refuses access before the handler runs:

```http
HTTP/1.1 401 Unauthorized
Content-Type: application/json
WWW-Authenticate: Bearer realm="jwt-sandbox"

{"error":"Please sign in to access the vault."}
```

A gibberish token, bad signature, or expired token reaches the wrapper as a guest
with failure information. The wrapper returns:

```http
HTTP/1.1 401 Unauthorized
Content-Type: application/json
WWW-Authenticate: Bearer realm="jwt-sandbox", error="invalid_token"

{"error":"Please sign in to access the vault."}
```

The second protected endpoint uses the same wrapper. For example, with a valid
token it would return:

```http
GET /protected/catalog HTTP/1.1
Host: localhost:5000
Authorization: Bearer <signed JWT>

HTTP/1.1 200 OK
Content-Type: application/json

{"items":["Notebook","Pencil"]}
```

Without valid credentials it receives the same refusal as `/protected`. The
browser walkthrough still exercises `/protected`; this second route makes the
shared protection visible in the source and available for direct calls.

Malformed authentication requests are distinct from a valid Bearer field carrying
an invalid JWT. The backend reports duplicate fields or malformed Bearer syntax
as `malformed_authorization`; the protected handler or group wrapper responds:

```http
HTTP/1.1 400 Bad Request
Content-Type: application/json
WWW-Authenticate: Bearer realm="jwt-sandbox", error="invalid_request"

{"error":"Malformed Authorization header."}
```

For example, `Authorization: Bearer first second` is malformed syntax; a single
`Authorization: Bearer absolute-gibberish-token` reaches JWT verification and
gets 401 `invalid_token`. The backend never selects a token from duplicate
Authorization fields. This is application-owned handling, not a new validation
rule in PAGI::Headers or generic Authentication middleware.

A verified JWT without a nonempty string `sub` instead becomes a guest with
failure information. The wrapper explicitly adds `invalid_token` to its Bearer
header and displays its own sign-in message, not the backend's detail.

## Dependencies and execution

This source uses Perl 5.40 signatures, PAGI Tools, and
[Crypt::JWT](https://metacpan.org/pod/Crypt::JWT). Its documented `accepted_alg`
option pins HS256; `verify_exp => 1` requires a valid expiration claim. JWT
verification and issuance are application code, not PAGI Auth functionality.
The example-local `cpanfile` declares these optional example dependencies; JWT
is not a required dependency of the PAGI Tools distribution.

Install the example dependencies and launch from the repository root:

```sh
cpanm --installdeps examples/auth-jwt-sandbox
```

```sh
pagi-server --app examples/auth-jwt-sandbox/app.pl --port 5000
```

For the inline variant, select `examples/auth-jwt-sandbox/app2.pl` instead.
Run one variant at a time on that port; both use the same browser URLs.

Then visit `http://127.0.0.1:5000/`.

This intentionally preserves the original's dummy login and public learning
key. It is a local teaching application, not a real login or token issuer. A
deployed application needs actual credential verification and private key
management. Tokens are kept only in page memory and cleared by a reload.

## Validation

From the repository root, run the dedicated integration test with the optional
JWT dependency installed:

```sh
prove -lv t/integration-auth-jwt-sandbox.t
```

It executes both real applications in isolated Perl packages and covers login,
protected success, missing and unsupported credentials, malformed and duplicate
Authorization fields, malformed JWTs, wrong signatures, expiration, missing
subjects, public routes, group catalog protection, and the absence of implicit
grants from the JWT `role` claim. Browser automation is not needed for this Auth
example.
