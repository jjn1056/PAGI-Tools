# Auth example: a small Notes API

Date: 2026-09-19

Status: **runnable introductory Notes example and focused extension companions delivered**.

This is the companion application for the
[Auth design](2026-09-17-authentication-backends-and-context-design.md).
The runnable introduction lives in [auth-notes](../../../examples/auth-notes/README.md).
It is separate from `examples/starlette-apples`, which remains focused on routing.
Authentication establishes context; handlers own authorization and responses.
The broader guard/policy example is preserved as
[historical research](2026-09-19-auth-notes-policy-research-snapshot.md).
The numbered variations below retain the developed coverage requirements;
the focused [extension companions](../../../examples/auth-extensions/README.md)
provide executable examples for the settled extension contracts. The existing
[JWT variants](../../../examples/auth-jwt-sandbox/README.md) already demonstrate
inline and group-level responses against the implemented Auth API.

Coverage requirement: this example family must demonstrate every public Auth
capability delivered by the project, including defaults, alternate configuration
forms, and extension contracts. The main application is the introduction;
numbered variations below are required companion examples, not optional future
polish. A capability is not covered merely because prose mentions its name.
The delivered extension examples exercise the settled interfaces listed in the
coverage index below. The later variation labels and imperative acceptance
language preserve the original design checklist; the linked runnable files and
tests above are the current coverage index.

| Delivered file | Executed by | Focus |
| --- | --- | --- |
| [01-users-and-results.pl](../../../examples/auth-extensions/01-users-and-results.pl) | [users and results script](../../../t/auth/11-extension-examples.t) | User/result forms, subclass default, grants and scope helpers |
| [02-basic-backend.pl](../../../examples/auth-extensions/02-basic-backend.pl) | [Basic backend app](../../../t/auth/11-extension-examples.t) | Object backend, fixed Basic fixture, explicit refusal |
| [03-context-and-placement.pl](../../../examples/auth-extensions/03-context-and-placement.pl) | [context and placement app](../../../t/auth/11-extension-examples.t) | Cloned context, nesting, placement and ownership |
| [04-response-applications.pl](../../../examples/auth-extensions/04-response-applications.pl) | [response applications app](../../../t/auth/11-extension-examples.t) | Request, Response, Pages, object and native response forms |
| [05-protocol-admission.pl](../../../examples/auth-extensions/05-protocol-admission.pl) | [protocol admission app](../../../t/auth/11-extension-examples.t) | HTTP, WebSocket and SSE refusal/admission |
| [06-header-primitives.pl](../../../examples/auth-extensions/06-header-primitives.pl) | [header primitives script](../../../t/auth/11-extension-examples.t) | Formatter, raw/repeated fields and MCP-style header values |

The introductory Notes routes are exercised by
[their integration test](../../../t/integration-auth-notes.t); the
[JWT companion test](../../../t/integration-auth-jwt-sandbox.t) executes both
JWT variants.

Clarity takes precedence over keeping everything in one application or file.
Split the material into multiple small, independently understandable examples
whenever that makes the public API easier to learn or evaluate. For instance,
custom authenticators or protocol admission may deserve their own applications
rather than extra modes in the introductory Notes app. The numbered variations
below describe required coverage, not a fixed packaging scheme. Avoid switches
and shared scaffolding that hide the actual API usage. Provide an index stating
what each example demonstrates; the coverage table applies to the set as a whole.

The purpose is to judge the public API by reading a small application. Keep its
business logic simple: a library of published notes, with optional caller
identity, token-protected publishing, and a restricted bulk export. All notes in
this initial example are public; ownership restrictions belong to a later
focused variation, not an implied privacy promise.

## Routes and identities

| Route | Requirement | Purpose |
| --- | --- | --- |
| `GET /notes` | None | Published notes plus optional caller identity |
| `GET /me` | User flag is true | Smallest identity-protected endpoint |
| `POST /notes` | User flag plus `notes:read` and `notes:write` | Publish a note; demonstrate a deliberate application all-of rule |
| `GET /notes/export` | `notes:read` | Explicit bulk-export permission |

The export restriction is an application policy on bulk access; it does not make
the public notes confidential.

The demo token store contains these records. The keys are fixed demonstration
credentials, not a token-generation or production-storage recommendation:

```perl
my $records = {
    'alice-reader' => {
        user_id      => 'alice',
        display_name => 'Alice',
        scopes       => ['authenticated', 'notes:read'],
    },
    'alice-editor' => {
        user_id      => 'alice',
        display_name => 'Alice',
        scopes       => ['authenticated', 'notes:read', 'notes:write'],
    },
    'export-service' => {
        user_id      => 'export-bot',
        display_name => 'Note exporter',
        scopes       => ['notes:read'],
    },
};
```

Both Alice tokens identify the same user with different grants. The service is
authenticated but lacks the literal `authenticated` grant: it can export and
access `/me`, which checks the user flag rather than a named scope. This exercises
the accepted distinction between `is_authenticated` and scope membership.

## Introductory application

The injected token store and note library are application-owned services.
`find_active` returns an accepted record or `undef`; infrastructure errors
propagate. `all_published` returns public notes; `publish($author, $data)` stores a
note under the supplied author after the handler validates its text. These illustrative service methods return
Futures and are not PAGI APIs.

The response values below are ordinary application-built responses, not
Auth outcome objects or a new failure policy. Their challenge scopes are explicit
wire values chosen for this application's rules.

```perl
use v5.40;
use Future::AsyncAwait;
use NotesDemo::TokenStore;
use NotesDemo::Library;
use PAGI::Auth qw(auth auth_result unauth_result www_authenticate);
use PAGI::Auth::SimpleUser;
use PAGI::Middleware::Authentication;
use PAGI::Compose qw(compose);
use PAGI::Response qw(json_response);
use PAGI::Routing qw(route middleware);

sub build_authentication ($token_store) {
    return PAGI::Middleware::Authentication->new(
        backend => async sub ($request) {
            my @authorization = $request->header_all('Authorization');
            return unauth_result() unless @authorization;

            my $token;
            if (@authorization == 1) {
                my ($scheme) = $authorization[0] =~ /\A(\S+)/;
                return unauth_result() if defined($scheme) && lc($scheme) ne 'bearer';
                ($token) = $authorization[0] =~ /\ABearer +([A-Za-z0-9._~+\/-]+=*)\z/i;
            }
            # Application convention, shared with the JWT examples.
            return unauth_result(failure => {
                code => 'malformed_authorization',
                message => 'Expected one Authorization header containing a Bearer token.',
            }) unless defined $token;

            # A failed store Future propagates; it is not a rejected credential.
            my $record = await $token_store->find_active($token);
            return unauth_result(failure => {
                message => 'The token was rejected.',
            }) unless $record;

            return auth_result(
                user => PAGI::Auth::SimpleUser->new(
                    identity => $record->{user_id},
                    display_name => $record->{display_name},
                ),
                scopes => $record->{scopes},
            );
        },
    );
}

# An ordinary response builder: handlers below explicitly choose when to use it.
sub authentication_notice ($context) {
    my $failure = $context->failure;
    my $malformed = $failure && ($failure->code // '') eq 'malformed_authorization';
    my @params = (realm => 'notes');
    push @params, error => ($malformed ? 'invalid_request' : 'invalid_token') if $failure;
    return json_response(
        { error => $malformed ? 'Malformed Authorization header.' : 'Please authenticate.' },
        status => $malformed ? 400 : 401,
        headers => ['WWW-Authenticate' => www_authenticate('Bearer', @params)],
    );
}

sub build_app ($token_store, $notes) {
    return compose(
        middleware => [middleware(build_authentication($token_store))],
        routes => [
            route('/notes' => async sub ($request) {
                my $items = await $notes->all_published;
                return json_response({
                    viewer => auth($request)->user->display_name || 'Guest',
                    notes => $items,
                });
            }, methods => ['GET']),

            route('/me' => sub ($request) {
                my $context = auth($request);
                return authentication_notice($context) unless $context->user->is_authenticated;
                return json_response({
                    user_id => $context->user->identity,
                    display_name => $context->user->display_name,
                    scopes => $context->credentials->scopes,
                });
            }, methods => ['GET']),

            route('/notes' => async sub ($request) {
                my $context = auth($request);
                return authentication_notice($context) unless $context->user->is_authenticated;
                unless ($context->credentials->has_all('notes:read', 'notes:write')) {
                    return json_response(
                        { error => 'Publishing requires read and write access.' },
                        status => 403,
                        headers => ['WWW-Authenticate' => www_authenticate('Bearer',
                            realm => 'notes', error => 'insufficient_scope',
                            scope => 'notes:read notes:write',
                        )],
                    );
                }
                my $data = await $request->json;
                unless (ref($data) eq 'HASH' && defined($data->{text})
                    && !ref($data->{text}) && $data->{text} =~ /\S/) {
                    return json_response({error => 'A nonempty text string is required.'}, status => 400);
                }
                my $note = await $notes->publish($context->user->identity, $data);
                return json_response($note, status => 201);
            }, methods => ['POST']),

            route('/notes/export' => async sub ($request) {
                my $context = auth($request);
                unless ($context->credentials->has('notes:read')) {
                    return authentication_notice($context) unless $context->user->is_authenticated;
                    return json_response(
                        { error => 'Export requires read access.' },
                        status => 403,
                        headers => ['WWW-Authenticate' => www_authenticate('Bearer',
                            realm => 'notes', error => 'insufficient_scope', scope => 'notes:read',
                        )],
                    );
                }
                return json_response({notes => await $notes->all_published});
            }, methods => ['GET']),
        ],
    );
}

build_app(NotesDemo::TokenStore->new, NotesDemo::Library->new);
```

Authentication wraps the application once. Every permission decision is ordinary
handler code; membership helpers return booleans and do not dispatch responses. The
public notes handler uses the user object without an authentication branch.
The backend grants exactly what the record supplies and shares its scope array;
a backend wanting a snapshot writes `scopes => [ @{ $record->{scopes} } ]`.

The main example deliberately shows both styles: publishing separately checks
identity and grants; export checks its actual permission first and selects a
response on failure. PAGI does not prescribe either application structure.

## Requests that the example must demonstrate

Use HTTPS outside local development and valid note input for publishing.
The runnable example uses the public Auth contract and its own failure-code convention.

| Request | Authorization | Expected result |
| --- | --- | --- |
| `GET /notes` | Absent | 200 with Guest display; backend called |
| `GET /notes` | `Bearer alice-reader` | 200, `viewer: "Alice"` |
| `GET /notes` | `Bearer unknown` | 200 with Guest display; rejection does not refuse public access |
| `GET /me` | Absent | 401 with Bearer challenge, no Bearer error parameter |
| `GET /me` | `Bearer alice-reader` | 200 with Alice's identity |
| `POST /notes` | `Bearer alice-reader` | 403 with Bearer `insufficient_scope`; publisher not called |
| `POST /notes` | `Bearer alice-editor` | 201; author is Alice |
| `GET /notes/export` | `Bearer export-service` | 200 |
| `GET /me` | `Bearer export-service` | 200; user flag is true despite lacking the named `authenticated` grant |
| `POST /notes` | Valid token granting only `notes:write` | 403; the application requires both read and write |
| `POST /notes` | Valid token granting read and write, without `authenticated` | 201; the named grant has no special meaning |
| `GET /notes/export` | Valid token granting only `Notes:Read` | 403; matching is case-sensitive |
| `GET /notes/export` | Valid authenticated user with no scopes | 403; authentication does not imply grants |
| `GET /me` | Duplicate Authorization fields or malformed Bearer syntax | 400 `invalid_request`, chosen by the protected handler |
| Any request with applicable credentials | Store fails | Operational error propagates; no invalid-token conversion |

Missing and rejected credentials both reach the handler with a guest context.
Public `/notes` remains public. Protected handlers choose 401 for absence or
rejection and 400 for the example-defined `malformed_authorization` code. Permission-helper
results do not automatically install a failure in the auth context.

The [runnable walkthrough](../../../examples/auth-notes/README.md) includes
literal HTTP requests and responses for anonymous success, authenticated success,
rejected token, and insufficient scope. Its matrix lets readers compare outcomes
without reading every handler.

## 1. Backend forms and result timing

These backend variations follow the current request-only coderef/object contract.
The delivered Basic object backend appears in
[02-basic-backend.pl](../../../examples/auth-extensions/02-basic-backend.pl);
the code below retains the broader backend-form rationale.
A synchronous callback can use the in-memory fixture directly:

```perl
use PAGI::Auth qw(auth_result unauth_result);

my $lookup = sub ($request) {
    my @authorization = $request->header_all('Authorization');
    return unauth_result() unless @authorization;
    my $token;
    if (@authorization == 1) {
        my ($scheme) = $authorization[0] =~ /\A(\S+)/;
        return unauth_result() if defined($scheme) && lc($scheme) ne 'bearer';
        ($token) = $authorization[0] =~ /\ABearer +([A-Za-z0-9._~+\/-]+=*)\z/i;
    }
    return unauth_result(failure => {
        code => 'malformed_authorization',
        message => 'Expected one Authorization header containing a Bearer token.',
    }) unless defined $token;
    my $record = $records->{ $token };
    return unauth_result(
        failure => { message => 'The token was rejected.' },
    ) unless $record;
    return auth_result(
        user => PAGI::Auth::SimpleUser->new(
            identity     => $record->{user_id},
            display_name => $record->{display_name},
        ),
        scopes => $record->{scopes},
    );
};

my $callback_backend = $lookup;  # A coderef can be supplied directly.
```

Object form uses the same inputs and results, without a required base class:

```perl
package NotesApp::TokenBackend;
use v5.40;
use Future::AsyncAwait;
use PAGI::Auth qw(auth_result unauth_result);
use PAGI::Auth::SimpleUser;

sub new ($class, %args) { bless { store => $args{store} }, $class }

async sub authenticate ($self, $request) {
    my @authorization = $request->header_all('Authorization');
    return unauth_result() unless @authorization;
    my $token;
    if (@authorization == 1) {
        my ($scheme) = $authorization[0] =~ /\A(\S+)/;
        return unauth_result() if defined($scheme) && lc($scheme) ne 'bearer';
        ($token) = $authorization[0] =~ /\ABearer +([A-Za-z0-9._~+\/-]+=*)\z/i;
    }
    return unauth_result(failure => {
        code => 'malformed_authorization',
        message => 'Expected one Authorization header containing a Bearer token.',
    }) unless defined $token;
    my $record = await $self->{store}->find_active($token);
    return unauth_result(
        failure => { message => 'The token was rejected.' },
    ) unless $record;
    return auth_result(
        user => PAGI::Auth::SimpleUser->new(
            identity     => $record->{user_id},
            display_name => $record->{display_name},
        ),
        scopes => $record->{scopes},
    );
}
```

The application loads its class and supplies an ordinary instance directly:

```perl
my $instance_backend = NotesApp::TokenBackend->new(store => $token_store);

middleware('Authentication', backend => $instance_backend);
# Or pass the callback directly:
middleware('Authentication', backend => $callback_backend);
```

Both a coderef and an object with `authenticate` are accepted directly. There
is no backend generator, class-name resolution, or deferred construction.
Application code decides when to construct and share closures or instances.
Middleware passes only PAGI::Request to either form, even without credentials;
the object additionally receives its normal invocant. No invocation-specific
user or failure is stored on a shared backend object.

Include demonstrations of immediate success/rejection, Future-backed
success/rejection, and an exception/failed Future from the store. Missing
credentials still call the backend; rejection is an explicit `unauth_result`
with failure information, not `undef`.
Also demonstrate Request accessors and `->scope` for metadata installed by
earlier application middleware; do not depend on routing data unavailable at placement.

An explicit expected rejection adds a public explanation without a policy API:

```perl
use PAGI::Auth qw(unauth_result);

return unauth_result(failure => {
    code    => 'account_disabled',
    message => 'This account is disabled.',
});
```

An ordinary application handler sees those values through `failure->code` and
`failure->message`. The standard Bearer rejection still uses its own wire error
parameter; the application code is not copied into the challenge.

## 2. Built-in and application-owned users

The main listing uses `SimpleUser`; an anonymous `GET /notes` supplies the built-in
`UnauthenticatedUser`. Both are real objects with `is_authenticated`, `identity`,
and `display_name`. The built-in guest has empty identity and display strings; the Notes handler
chooses the visible label `Guest`.

An application user implements that interface without inheriting a PAGI class:

```perl
package NotesApp::Member;
use v5.40;
sub new ($class, %args) { bless { %args }, $class }
sub is_authenticated ($self) { 1 }
sub identity ($self) { $self->{id} }
sub display_name ($self) { $self->{name} }
sub plan ($self) { $self->{plan} } # application-specific information
```

Use it in the backend's success result:

```perl
return auth_result(
    user => NotesApp::Member->new(
        id => 'alice', name => 'Alice', plan => 'team',
    ),
    scopes => ['authenticated', 'notes:read'],
);
```

Customize the anonymous user independently:

```perl
package NotesApp::Guest;
use v5.40;
sub new ($class, %args) { bless { %args }, $class }
sub is_authenticated ($self) { 0 }
sub identity ($self) { '' }
sub display_name ($self) { $self->{name} }
```

```perl
# In the backend's missing-credential branch:
return unauth_result(user => NotesApp::Guest->new(name => 'Visitor'));
```

Show this object both on an anonymous request and after rejected credentials.
Its grants default to empty; results continue to application code, which decides
whether to refuse access. Returning a bare guest from the backend is not a supported result.

Public application behavior can also use a method supplied by both custom
classes, such as `greeting`. A guest might return a browsing invitation and a
member a personalized welcome. That is application polymorphism, not an Auth
permission branch or an extra required method on PAGI user objects.

## 3. Context access and shared grant references

High-level handlers use `auth($request)` as in the main listing. Native middleware
and applications use `auth($scope)`; a wrapper exposing `scope()` also qualifies.
All observe the same installed context, without triggering another lookup.

```perl
my $context = auth($scope);
my $user = $context->user;
my $grants = $context->credentials->scopes;
my $failure = $context->failure;          # undef on ordinary success/absence

push @$grants, 'notes:annotate';          # deliberately affects later membership checks
my $snapshot = [ @$grants ];              # explicit independent list
```

Demonstrate these observations in application-owned middleware. No context means
a configuration error; `auth()` must not fabricate an anonymous user when the
authentication middleware was forgotten.

## 4. Ordinary response and application forms

Authentication has no failure renderer or `on_failure` option. Its result carries
only a user, credentials, and optional failure with `code`/`message` readers.
Handlers or ordinary middleware construct status and challenge headers explicitly.
The main application uses JSON responses;
[04-response-applications.pl](../../../examples/auth-extensions/04-response-applications.pl)
demonstrates synchronous/asynchronous handlers, Pages values, `to_app` objects,
and native applications adapted with `PAGI::Utils::as_app_object` where a Route
needs an application object. These remain ordinary PAGI application contracts.

Demonstrate explicit 400 malformed-header, 401 absent/rejected-token, and 403
insufficient-scope responses, repeated WWW-Authenticate fields, and JSON/HTML
Pages negotiation. Challenge parameters belong to the application's response;
application-defined failure codes are not automatically copied to wire errors.
Operational exceptions and failed Futures propagate and are never rendered as
401 invalid_token. Compose may render them as 500 at its outer error boundary.

## 5. Scope inspection, placement, and nested contexts

Show every membership operation, including the motivating compound rule:

```perl
my $grants = auth($request)->credentials;

my $can_read = $grants->has('notes:read');
my $can_review = $grants->has_any('editor', 'publisher');
my $can_manage = $grants->has_all('manager', 'edit');
my $can_edit = $grants->has('global_admin')
    || $grants->has_all('manager', 'edit');

my $can_publish = $grants->has('global_admin')
    || ($grants->has_any('manager', 'editor') && $grants->has('publish'));
```

Demonstrate admin success, manager-plus-edit success, manager-only failure, and
anonymous failure for that compound edit rule. These booleans do not select HTTP
statuses or execute applications. Role-like names are ordinary granted strings;
there is no built-in admin bypass, role model, or inferred permission hierarchy.
An application can inspect the array manually instead:

```perl
my %granted = map { $_ => 1 } @{ $grants->scopes };
my $can_edit = $granted{global_admin} || ($granted{manager} && $granted{edit});
```

Authentication middleware can use existing Router/Route/Mount/Compose placement
and ordering; this does not require a new Auth guard at those boundaries.
Record route/method-miss behavior for the placements actually demonstrated.

A separate nested-authentication example uses outer and inner realms with
distinguishable users and failure bodies. Inner authentication replaces the
entire user/credentials/failure context; its handlers choose their responses.
The outer observer keeps its original context. Outer rejection alone does not prevent entry
into the inner authenticator; an explicit application refusal can do so. No policy object or automatic scheme fallback is
involved.

## 6. Custom authorization and custom authentication

An ownership variation uses ordinary application checks after loading the note.
The application controls its response; it does not construct an Auth cause or
invoke a public rejection-preparation operation:

```perl
unless ($note->{author_id} eq auth($request)->user->identity) {
    return json_response(
        { error => 'Only the owner can edit this note.' },
        status => 403,
    );
}
```

Place this within an authenticated handler that has already checked any required
write permission. The ownership refusal does not claim that acquiring another
OAuth scope would make the caller the owner.

The custom-authenticator companion uses the small public establishment boundary
to supply a user, credentials, and optional authentication failure. It reuses
unchanged `auth()` and membership helpers, without a scheme-policy object. It installs a completed result in a cloned scope at `pagi.auth`; do not silently
restore the earlier `with_auth(..., failure_policy => ...)` research shape.

Include a focused Basic example with application-owned password verification
and an application-supplied JWT verifier using Authentication middleware. They must
show their actual verification boundary rather than pretend token decoding is
verification. A JWT learning sandbox may mint dummy tokens as application code;
this does not add token issuance or a verifier to the Auth toolkit.

## 7. WebSocket and SSE admission

Use small separate routes inside an authenticated application. Identity access
and scope inspection work through the same context helper. The handler chooses
its refusal before accepting or starting output. Here `$authenticate_notice`
and `$read_notice` are ordinary application responses (401 challenge and 403
insufficient-scope challenge) constructed like those in the main listing:

```perl
use PAGI::Routing qw(websocket sse);

websocket('/notes/socket' => async sub ($ws) {
    my $context = auth($ws);
    unless ($context->credentials->has('notes:read')) {
        await $ws->deny($context->user->is_authenticated
            ? $read_notice : $authenticate_notice);
        return;
    }
    await $ws->accept;
    await $ws->send_json({ user_id => $context->user->identity });
    await $ws->close;
})

sse('/notes/events' => async sub ($sse) {
    my $context = auth($sse);
    unless ($context->credentials->has('notes:read')) {
        await $sse->decline($context->user->is_authenticated
            ? $read_notice : $authenticate_notice);
        return;
    }
    await $sse->start;
    await $sse->send_json({ user_id => $context->user->identity });
    await $sse->close;
})
```

Also demonstrate rejected credentials reaching these handlers as guest results;
ordinary handler/application responses decide protocol refusal.
Preserve original PAGI scope types and channels. Use clients capable of supplying
Authorization; browser credential delivery and long-lived expiry/revocation
policy are separate concerns. No new Auth guard or lifecycle mechanism is needed.

## 8. Direct header primitives

The convenience helpers must remain optional. This companion shows the existing
public header APIs directly, with no Auth-specific parsing or challenge value:

```perl
# Preserve every field value for application-owned parsing decisions.
my @authorization = $request->headers->get_all('Authorization');

# An explicit challenge response, not a catch-all failure mapper.
my $response = json_response(
    { message => 'An access token is required.' }, status => 401,
);
$response->headers->set('WWW-Authenticate',
    'Bearer realm="notes", resource_metadata="https://notes.example/.well-known/oauth-protected-resource/mcp"',
);
return $response;
```

Also show `headers->add(...)` where the application deliberately supplies
multiple challenge fields. No mandatory Auth wrapper or recognized failure code
is needed to construct these responses. Dynamic header values are the
application's formatting responsibility; the final convenience helpers can
handle that formatting when desired.

Show the accepted string-returning `www_authenticate(...)` formatter beside
literal headers. An Authorization parsing helper is deferred; the
formatter lives in `PAGI::Auth`. Show mixing custom
parsing with public context establishment and mixing standard authentication
with an application-built response. The example must make the escape path easy
to find and use, not bury it in an internal implementation walkthrough.

### MCP notice using ordinary response construction

A small MCP-oriented companion shows inline authentication and permission checks
with ordinary responses. This is the anonymous branch of an application handler:

```perl
unless (auth($request)->user->is_authenticated) {
    return json_response(
        { message => 'Connect your account to access your notes.' },
        status => 401,
        headers => [
            'WWW-Authenticate' => www_authenticate('Bearer',
                resource_metadata => $metadata_url,
                scope             => 'notes:read',
            ),
        ],
    );
}
```

After that check, the same handler can inspect the actual permission:

```perl
unless (auth($request)->credentials->has('notes:read')) {
    return json_response(
        { message => 'Your token does not grant notes:read.' },
        status => 403,
        headers => [
            'WWW-Authenticate' => www_authenticate('Bearer',
                error             => 'insufficient_scope',
                resource_metadata => $metadata_url,
                scope             => 'notes:read',
            ),
        ],
    );
}

# Dispatch the permitted MCP operation using application code.
```

The metadata URL must serve the corresponding public protected-resource metadata.
The wire scopes are explicit application choices. For the permission refusal:

```http
HTTP/1.1 403 Forbidden
Content-Type: application/json
WWW-Authenticate: Bearer error="insufficient_scope", resource_metadata="https://notes.example/.well-known/oauth-protected-resource/mcp", scope="notes:read"

{"message":"Your token does not grant notes:read."}
```

Include the equivalent literal-header path in the completed companion. Rejected tokens also reach the inline application checks with failure information;
the application chooses its challenge explicitly.

This is not a complete MCP implementation or an OAuth authorization server.
Neither scope inspection nor challenge formatting discovers an operation's
requirements, maps internal grants, or fetches metadata automatically.

## Coverage and completion gate

| Public capability or observable contract | Required example location |
| --- | --- |
| Request-only Bearer backend, application realm and parsing | Main application |
| Direct coderef or authenticate object; construction versus invocation | Variation 1 |
| Immediate/Future success, rejection, operational failure; scope input | Variation 1 and request matrix |
| Success constructor; built-in authenticated/anonymous user | Main application and variation 2 |
| Custom user and guest results; all user methods | Variation 2 |
| `auth` with raw scope and scope-bearing objects; every context accessor | Main application and variation 3 |
| Explicit grants, independent user flag, live references, explicit copies | Fixtures, request matrix, variation 3 |
| Explicit responses; synchronous/asynchronous Request handlers | Variation 4 |
| Response/Pages values, `to_app` objects, adapted native CODE | Variation 4 |
| Authentication failure code/message; application status/headers and authorization responses | Main application, request matrix, variations 4 and 6 |
| Boolean single/any/all membership, compound admin-or-manager-and-edit, exact matching, live and empty grants | Main application, request matrix, variations 3 and 5 |
| Router/Route/Mount/Compose placement and ordering | Variation 5 |
| Nested context replacement; parent preservation; no fallback | Variation 5 |
| Manual ownership and authorization decisions; no implicit response dispatch | Variation 6 |
| Public context establishment for a custom authenticator | Variation 6; completed result in cloned scope |
| Basic verification and application-supplied JWT verification using Authentication | Variation 6; focused companion examples |
| HTTP/WS/SSE failure delivery through ordinary applications | Main application and variation 7 |
| Header formatter, direct primitives, and manually composed MCP challenges | Variation 8; parsing helper deferred, formatter in PAGI::Auth |

Every public constructor, option, method, and supported configuration
form must map to concrete example code and an observable result before this
example family is called complete. The assigned focused extension examples are
indexed above;
do not omit an awkward capability to make the API appear simpler. Conversely,
this coverage requirement does not expand implementation scope to every feature
mentioned as an open possibility in the design.

The accompanying walkthrough must also exercise missing middleware, invalid membership-helper
arguments under the public contract, invalid backend result shapes, and ordinary cancellation
or operational failure propagation. These are failure demonstrations, not extra
endpoints or configuration modes. Cookie login, a toolkit token-issuance API, and database setup remain outside the
project. A small JWT learning page is application/example code if included, not
an expansion of the Auth runtime. Deferred guards and failure policies are not
required example coverage.

The design review question is whether the complete application and these small
substitutions read naturally. If a routine variation requires private access or
several special cases, revisit the contract instead of hiding the difficulty in
demo-specific helpers.
