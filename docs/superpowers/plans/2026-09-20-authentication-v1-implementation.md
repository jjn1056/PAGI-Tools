# Authentication v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide request-based authentication backends, explicit user/grant/failure results, and small inspection/header helpers, demonstrated by runnable applications using ordinary PAGI responses and middleware.

**Architecture:** `PAGI::Middleware::Authentication` calls a supplied coderef or object's `authenticate($request)` method, awaits its result, installs that complete result in a shallow child scope, and awaits the downstream application. `PAGI::Auth` constructs and exposes results and formats individual WWW-Authenticate challenges; applications own parsing, authorization, and response selection. Existing Request, Compose, Routing, Headers, Response, Pages, and protocol refusal APIs provide the rest.

**Tech Stack:** Perl, Future, Future::AsyncAwait, Test2::V0, existing PAGI Tools composition and test client. Crypt::JWT is an optional example dependency, never an Auth runtime dependency.

**Spec:** [Authentication backends, context, and failure applications](../specs/2026-09-17-authentication-backends-and-context-design.md), including the 2026-09-20 review corrections. Read the spec with this plan. The [Notes companion](../specs/2026-09-19-auth-notes-example.md) supplies coverage ideas, but its historical API code is not authoritative.

**Status:** Plan for review. Writing this plan does not authorize runtime implementation, publishing, or merging. The approved design choices are ready for implementation planning; the spec's historical “not approved for implementation” status must not be mistaken for approval to execute.

## Global Constraints

These are the spec's governing requirements, quoted verbatim:

- “Request does not gain `user`, `auth`, or `auth_credentials` methods.”
- “The backend option accepts exactly a coderef or an object implementing `authenticate`; both use the same input and result contract.”
- “A backend must return a result value; bare users and `undef` are not alternate return forms.”
- “Exceptions and failed Futures represent operational/programming failure and propagate normally, rather than becoming credential rejection.”
- “No scope is inserted implicitly.”
- “Supplied user objects and scopes arrayrefs are retained with normal Perl reference semantics.”
- “The nearest installed complete context is authoritative.”
- “OAuth 2 flows remain a separate concern: authorization redirects, token acquisition, client registration, refresh, and discovery are not Auth features.”
- “No server internals or additional Auth-owned lifecycle mechanism are needed.”
- “Do not expand the failure contract by introducing expected-failure exceptions, response-valued backend results, or middleware dispatch hooks.”
- “If the proposed shape needs several special cases, return to design discussion.”

Repository constraints: keep the declared runtime Perl floor at **5.018**, Future at **0.50**, and Future::AsyncAwait at **0.66**; library code follows existing strict/warnings and argument-unpacking style. Examples may use **v5.40**, like the existing JWT and Apples examples. Add no required runtime dependency. Do not introduce `PAGI::Response::Auth`, backend generators, scheme registries, automatic challenges, `on_failure`, permission guards, body replay, or compatibility aliases.

---

## Work map and execution boundary

| Repository | Ticket | Branch | Recorded base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | Authentication v1; no external ticket supplied | `feature/universal-connection-tools` | `f731ea9ae7580063e836540a1386ce7f84ce1ce7` | Plan now; on execution approval, Auth modules, affected callers/tests/docs, and Auth example family listed below | Local library and example work; no server deployment or release | None |

PAGI and PAGI-Server are reference repositories, not owned implementation repositories. Do not edit, merge, or push either. Reconfirm the map if scope changes. Use the current branch when execution is authorized unless the user changes that instruction; do not automatically create or switch branches.

The current checkout contains prior uncommitted work. Preserve it, especially `docs/superpowers/plans/2026-09-08-universal-connection-tracking.md`, `examples/README.md`, the canonical Auth spec, the JWT directory, and unrelated dotfiles. Stage only owned changes; never `git add .`. The Notes companion and several design files may be ignored: inspect `git check-ignore -v <path>` before deliberately adding a named project document. Do not force-add a whole directory.

At execution start, record the actual HEAD and dirty file list in the execution log. If HEAD moved, inspect the intervening changes and update this map; do not reset the checkout to this recorded base. Capture baseline failures before modifying runtime code.

### Validation environment

The shell currently defaults to system Perl 5.34. Use the installed Perlbrew environment explicitly for the dependency preflight and baseline suite:

```sh
perlbrew exec --with perl-5.40.0@default perl -MFuture -MFuture::AsyncAwait -MTest2::V0 -MPAGI::Test::Client -Ilib -e 1
perlbrew exec --with perl-5.40.0@default prove -lr t
```

Record missing dependencies or baseline failures as such; do not install arbitrary packages or relabel an environment failure as a feature regression. Crypt::JWT has its own preflight in Task 5. Do not run browsers against proposed APIs, add substitute Auth code, or count skipped example tests as validation of those examples.

## File structure and interface decisions

The classes below have separate responsibilities. Result, Credentials, and Failure have public readers but are created through Auth helpers, not additional public constructors. Internal `_new` methods are implementation details. Keep validation local to these classes and `PAGI::Auth`; do not introduce another utility framework.

| File | Responsibility / change |
| --- | --- |
| `lib/PAGI/Auth.pm` | Replace research factories with optional exports `auth`, `auth_result`, `unauth_result`, `www_authenticate`; zero-option shared factory `new`; function/class/instance invocation; reference and cookbook POD |
| `lib/PAGI/Auth/Result.pm` | Completed result with `user`, `credentials`, `failure`; no request, token, or response retained |
| `lib/PAGI/Auth/Credentials.pm` | Live supplied scopes array; `scopes`, `has`, `has_any`, `has_all` |
| `lib/PAGI/Auth/Failure.pm` | Public-safe `message`, optional application-defined `code`; no status/headers or exception conversion |
| `lib/PAGI/Auth/SimpleUser.pm` | Built-in authenticated identity/display-name convenience object |
| `lib/PAGI/Auth/UnauthenticatedUser.pm` | Built-in guest with false flag and empty identity/display strings |
| `lib/PAGI/Middleware/Authentication.pm` | Existing middleware `new(backend => ...)` / `wrap($app)` contract; request invocation and scope installation |
| `lib/PAGI/Auth/Challenge.pm`, `lib/PAGI/Auth/Outcomes.pm` | Remove after callers move to ordinary responses/Pages |
| `lib/PAGI/Middleware/Auth/Basic.pm`, `lib/PAGI/Middleware/Auth/Bearer.pm` | Remove with old scope shapes and private JWT implementation after their callers/tests move |
| `t/auth/` | New unit, middleware, composition, protocol, and documented-example tests; preserve useful old behavioral tests |
| `examples/auth-jwt-sandbox/` | Make the two approved variants runnable against real Auth; preserve their readability and shared page |
| `examples/auth-notes/` | Small opaque-token Notes application, application-owned fixture services, README and coverage index |
| `examples/auth-extensions/` | Small standalone examples for extension/composition/protocol capabilities that would obscure Notes |
| `lib/PAGI/Tools.pm`, `lib/PAGI/Tools/Cookbook.pod`, `lib/PAGI/Tools/Tutorial.pod`, `README.md`, `examples/README.md` | Current API and discoverability; remove old challenge/legacy middleware descriptions |

`auth($source)` can return the validated stored Result directly. There is no need for a second facade allocation or cache. Do not promise reference identity for that return in public docs/tests. Validate result provenance using the Result class/subclasses, not by accepting any object with three similarly named methods. User objects remain duck typed.

Supported constructor options are `auth_result(user => ..., scopes => ...)` and `unauth_result(user => ..., scopes => ..., failure => ...)`; failure belongs to guest/rejection construction. Reject unsupported options instead of retaining response-era fields. `new` takes no configuration options. Nothing is exported by default; expose the four named exports without adding another export-tag API.

Use normal named-pair validation: reject odd argument lists, duplicate/unknown option names, explicit undefined users, non-array scopes, and undefined/reference scope entries. Failure input is a hashref with required defined scalar `message` and optional defined scalar `code`; omission gives an undefined code reader. Empty strings are scalar values, not automatic absence. Do not impose an HTTP token grammar on grants or application failure codes. For custom users, check method availability and the flag, not identity truthiness or a PAGI base class. If an implementer finds a conflict with the canonical spec, report that exact conflict before inventing another accepted form.

## Task 1: User, credentials, failure, and result values

**Files:**
- Create the five `lib/PAGI/Auth/{Result,Credentials,Failure,SimpleUser,UnauthenticatedUser}.pm` files above.
- Create `t/auth/05-values.t`.
- Modify `t/00-load.t` to add the new modules; keep old loads until Task 2.

**Interfaces:**
- Consumes: existing Perl scalar/object conventions only.
- Produces: user classes with `new`, `is_authenticated`, `identity`, `display_name`; internal `Credentials->_new($scopes)`, `Failure->_new($hash)`, `Result->_new(user => ..., credentials => ..., failure => ...)`; the readers listed in the file map. No result constructors become public here.

- [ ] **Write the value tests**, including this initial executable case:

```perl
use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw(refaddr);
use PAGI::Auth::SimpleUser;
use PAGI::Auth::UnauthenticatedUser;
use PAGI::Auth::Credentials;

my $guest = PAGI::Auth::UnauthenticatedUser->new;
ok !$guest->is_authenticated;
is [$guest->identity, $guest->display_name], ['', ''];
my $user = PAGI::Auth::SimpleUser->new(identity => '0');
ok $user->is_authenticated;
is $user->display_name, '0';
my $scopes = ['notes:read'];
my $grants = PAGI::Auth::Credentials->_new($scopes);
is refaddr($grants->scopes), refaddr($scopes);
ok !$grants->has('notes:write');
push @$scopes, 'notes:write';
ok $grants->has_all('notes:read', 'notes:write');
ok !$grants->has('Notes:Read');
ok !$grants->has_any();
ok $grants->has_all();
like dies { $grants->has_all(['notes:read']) }, qr/scope/i;
done_testing;
```

Add cases for removing/changing a grant after creation, explicit copied arrays, `has` arity, undefined/reference requirements, supplied display names, missing/undefined/reference SimpleUser identity, optional Failure code, and Result readers preserving the supplied user. Verify default Guest methods do not imply a particular display label. Tests of private construction here support the value unit; public construction coverage follows in Task 2.

- [ ] **Run red:** `perlbrew exec --with perl-5.40.0@default prove -lv t/auth/05-values.t`. Expected: new modules cannot yet load.
- [ ] **Implement plain value classes.** Credentials should scan the live list, not keep a membership cache:

```perl
sub has {
    my ($self, @required) = @_;
    Carp::croak('has requires exactly one scope') unless @required == 1;
    Carp::croak('scope must be a defined scalar')
        unless defined($required[0]) && !ref($required[0]);
    return scalar(grep { $_ eq $required[0] } @{$self->{scopes}}) ? 1 : 0;
}
sub has_any {
    my ($self, @required) = @_;
    my @matches = map { $self->has($_) } @required;
    return scalar(grep { $_ } @matches) ? 1 : 0;
}
sub has_all {
    my ($self, @required) = @_;
    my @matches = map { $self->has($_) } @required;
    return scalar(grep { !$_ } @matches) ? 0 : 1;
}
```

Validate every requirement even if an earlier one matches. The internal constructor validates the supplied grant list once; ordinary reference mutation remains the caller's responsibility. Readers simply return their stored values. Add concise POD identifying public user constructors and reader methods; mark `_new` private.

- [ ] **Run green:** `perlbrew exec --with perl-5.40.0@default prove -lv t/auth/05-values.t t/00-load.t`.
- [ ] **Review and commit owned files:** `feat: add authentication result value types`. Gate: no parsing, policy, responses, snapshotting, or new dependencies in these classes.

## Task 2: Replace the Auth facade and challenge research API

**Files:**
- Replace `lib/PAGI/Auth.pm`; remove `lib/PAGI/Auth/Challenge.pm` and `lib/PAGI/Auth/Outcomes.pm`.
- Create `t/auth/06-constructors-context.t`, `t/auth/07-www-authenticate.t`.
- Replace/remove superseded `t/auth/01-challenge-values.t`, `02-bearer.t`, `03-outcomes.t` as their still-relevant assertions move to the new tests or Pages tests.
- Modify `t/auth/04-protocol-integration.t`, `t/00-load.t`.
- Modify old outcome examples in `lib/PAGI/Response.pm`, `lib/PAGI/Tools.pm`, `lib/PAGI/Tools/{Cookbook,Tutorial}.pod`, `README.md`, `examples/starlette-apples/{app.pl,README.md}`, `examples/auth-cookie-login/README.md`; update `t/00-pod/cookbook-examples.t` if extracted examples change.

**Interfaces:**
- Consumes: Task 1 types; `PAGI::Utils::Scope::scope_from_source($label, $source)`.
- Produces: all four Auth helpers, shared zero-option factory, complete result construction, and public `pagi.auth` observation. `www_authenticate($scheme, @pairs)` returns one string synchronously.

- [ ] **Write public construction/context tests** before replacing the module:

```perl
use PAGI::Auth qw(auth auth_result unauth_result);
use PAGI::Auth::SimpleUser;
use Scalar::Util qw(refaddr);

my $user = PAGI::Auth::SimpleUser->new(identity => 'alice');
my $scopes = ['notes:read'];
my $result = auth_result(user => $user, scopes => $scopes);
is refaddr($result->user), refaddr($user);
is refaddr($result->credentials->scopes), refaddr($scopes);
is $result->failure, undef;
my $scope = { type => 'http', 'pagi.auth' => $result };
is auth($scope)->user->identity, 'alice';
ok !auth($scope)->credentials->has('authenticated');
my $rejected = unauth_result(failure => { message => 'Not accepted' });
ok !$rejected->user->is_authenticated;
is $rejected->failure->code, undef;
is $rejected->failure->message, 'Not accepted';
like dies { auth({ type => 'http' }) }, qr/pagi\.auth/;
like dies { auth_result(user => $rejected->user) }, qr/authenticated/i;
```

Add cases for raw scope / object with `scope`, bad scope source and arity, invalid entry (undef, hash, bare user, Future, factory), both result constructors returning the same class, Guest grants, fresh omitted defaults, supplied reference identity, and no required relation between user flag and `authenticated` grant. Test direct result inspection before installation.

For every helper run exported, base class, instance, chained `new`, and subclass calls. A small subclass overriding `unauth_result` to supply an application Guest must work through `SUPER`, while imported functions still make the built-in Guest. Two shared factories must never acquire a current result. Do not assert that `auth($scope)` allocates or avoids allocating a facade.

- [ ] **Write formatter tests** for exact output and errors:

```perl
use PAGI::Auth qw(www_authenticate);
is www_authenticate('Bearer'), 'Bearer';
is www_authenticate('Basic', realm => 'api', charset => 'UTF-8'),
    'Basic realm="api", charset="UTF-8"';
is www_authenticate('Bearer', resource_metadata => 'https://api.example/meta'),
    'Bearer resource_metadata="https://api.example/meta"';
is www_authenticate('Demo', Label => '', realm => 'a"b'),
    'Demo Label="", realm="a\\"b"';
like dies { www_authenticate('Bearer', realm => 'a', Realm => 'b') }, qr/duplicate/i;
like dies { www_authenticate('Bearer', realm => "bad\r\nheader") }, qr/value|quoted/i;
```

Include backslash escaping, preserved pair order/casing, invalid/absent scheme, invalid parameter names, odd pairs, refs/undef, NUL/DEL/other forbidden controls, permitted HTAB and byte obs-text, rejection of characters above byte range, and unknown but valid extension names. These follow HTTP quoted-string syntax; do not keep the old ASCII-printable-only validator. Reject array scope values instead of joining them. No challenge object, token overload, or scheme status rule remains.

- [ ] **Run red:** `perlbrew exec --with perl-5.40.0@default prove -lv t/auth/06-constructors-context.t t/auth/07-www-authenticate.t`. Expected: unavailable exports, not an unrelated import error.
- [ ] **Implement the facade and formatter.** Adapt the small `_factory_invocation` pattern in `PAGI::Pages`, retaining class/instance invocants and normal subclass dispatch. A no-argument `new` returns a shared factory with no invocation data. Resolve sources with the existing Scope helper. Validate the entry as a completed Result before returning its readers. Constructors enforce the user duck type and true/false flag, create the value objects, and preserve supplied references.

Formatter serialization, after validating arguments, is deliberately small:

```perl
# Token grammar for scheme and parameter names:
my $token = qr/\A[!#\$%&'*+\-.\^_`|~0-9A-Za-z]+\z/;
# Allowed unescaped input bytes; quote and backslash are escaped below:
my $quoted_input = qr/\A[\x09\x20-\x7e\x80-\xff]*\z/;
# For each validated ordered pair ($name, $value):
$value =~ s/([\\"])/\\$1/g;
push @serialized, $name . '="' . $value . '"';
# Return the scheme alone when there are no pairs.
```

Keep error messages about arguments/types, not their credential-bearing contents. No parser, error-to-status mapping, or request lookup belongs here.

- [ ] **Migrate outcome callers in the same task**, then remove old modules and tests. Replace each challenge/forbid application with explicit Pages/Response construction. For the Apples notice and corresponding tutorial snippets, preserve negotiated rendering:

```perl
return PAGI::Pages->status(401,
    detail => 'A valid access token is required.',
    headers => ['WWW-Authenticate' => 'Bearer realm="apples"'],
    cache_control => 'no-store',
);
```

Do not add authentication to Apples: it remains a routing example. Cookie login keeps its independent behavior; only obsolete Phase 1 prose changes. Retain Pages `response_for` as an existing public feature, but new refusal examples pass the Pages application directly to `deny`/`decline`. Rewrite `t/auth/04-protocol-integration.t` fixtures to use ordinary Pages with repeated raw/formatter-built headers; preserve its disconnect, stream cleanup, pending-send, cancellation, and negotiation coverage. Drop only assertions specific to deleted Challenge/Outcomes APIs. Do not change protocol helper code to ease this migration.

- [ ] **Run green:**

```sh
perlbrew exec --with perl-5.40.0@default prove -lr t/auth t/pages
perlbrew exec --with perl-5.40.0@default prove -lv t/00-load.t t/00-pod/cookbook-examples.t t/integration-starlette-apples.t t/integration-auth-cookie-login.t
```

- [ ] **Review and commit owned files:** `feat: replace auth outcomes with explicit authentication results`. Gate: every removed API's active caller is migrated; historical research documents remain historical. No compatibility facade or relocated outcome framework.

## Task 3: Authentication middleware and retirement of legacy authenticators

**Files:**
- Create `lib/PAGI/Middleware/Authentication.pm`, `t/auth/08-middleware.t`.
- Remove `lib/PAGI/Middleware/Auth/{Basic,Bearer}.pm`.
- Modify `t/00-load.t`, `t/middleware/10-session-auth.t`, `t/middleware/12-protocol-specific.t`, `t/middleware-builder-resolution.t`, `t/routing/04-middleware-descriptors.t`.
- Update legacy references in `lib/PAGI/Middleware/{Builder,Session}.pm`, `lib/PAGI/Routing.pm`, `lib/PAGI/Routing/Middleware.pm`, `lib/PAGI/Tools.pm`, `lib/PAGI/Tools/Cookbook.pod`, `README.md`.

**Interfaces:**
- Consumes: Task 2 result helpers and reader; `PAGI::Request->new($scope, $receive)`; `clone_scope($scope, \%changes)`; Future wrapping.
- Produces: `PAGI::Middleware::Authentication->new(backend => $coderef_or_object)->wrap($native_app)`. Routing/Builder resolves `'Authentication'` through existing machinery.

- [ ] **Write the middleware tests**, starting with the scope and continuation contract:

```perl
use Future;
use Test2::V0;
use Scalar::Util qw(refaddr);
use PAGI::Middleware::Authentication;
use PAGI::Auth qw(auth unauth_result);

my ($calls, $seen) = (0, undef);
my $outer = { type => 'http', headers => [], path => '/' };
my $receive = sub { die 'unexpected body read' };
my $send = sub { die 'unexpected response' };
my $mw = PAGI::Middleware::Authentication->new(backend => sub {
    my ($request) = @_;
    ++$calls;
    is scalar(@_), 1;
    is refaddr($request->scope), refaddr($outer);
    return unauth_result();
});
my $app = $mw->wrap(sub {
    my ($scope, $recv, $snd) = @_;
    $seen = auth($scope);
    isnt refaddr($scope), refaddr($outer);
    is refaddr($recv), refaddr($receive);
    is refaddr($snd), refaddr($send);
    return Future->done;
});
is $calls, 0, 'construction does not authenticate';
$app->($outer, $receive, $send)->get;
is $calls, 1;
ok !$seen->user->is_authenticated;
ok !exists $outer->{'pagi.auth'};
```

Add a real object fixture whose `authenticate` counts arguments (self plus one Request). Exercise immediate success/guest/rejection, pending Future success/rejection, failed Futures and synchronous exceptions, invalid returns (undef, user, hash, Response, multi-value completion), absent and unsupported Authorization, and object/closure reuse. No raw credential is put in the result or diagnostic by middleware. Validate missing backend, strings, constructor hashes, and objects without `authenticate` during construction. Unknown Auth callback/parser options must not silently work.

- [ ] **Run red:** `perlbrew exec --with perl-5.40.0@default prove -lv t/auth/08-middleware.t`.
- [ ] **Implement using the existing base middleware**, validating the sole `backend` option in `_init`. The execution body should stay close to this:

```perl
return async sub {
    my ($scope, $receive, $send) = @_;
    my $type = $scope->{type} // '';
    unless ($type eq 'http' || $type eq 'websocket' || $type eq 'sse') {
        await $app->($scope, $receive, $send);
        return;
    }
    my $request = PAGI::Request->new($scope, $receive);
    my $returned = ref($backend) eq 'CODE'
        ? $backend->($request)
        : $backend->authenticate($request);
    my @results = await Future->wrap($returned);
    Carp::croak('Authentication backend must return one Auth result')
        unless @results == 1;
    my $inner = clone_scope($scope, { 'pagi.auth' => $results[0] });
    auth($inner);  # Validate the same public entry contract used by custom middleware.
    await $app->($inner, $receive, $send);
    return;
};
```

Import the named dependencies explicitly. Do not catch operational failures, invent detached workers, retain Futures, or return `without_cancel`. The pending backend and downstream work belong to the ordinary awaited invocation. Middleware may retain its backend configuration, not the current Request/result. Generic middleware does not need `pagi.connection` to authenticate.

- [ ] **Retire legacy modules and update their tests/callers atomically.** Preserve Session tests in `10-session-auth.t`; migrate general protocol-admission/error cases to new Auth tests and remove obsolete JWT implementation tests. In `12-protocol-specific.t`, replace the two legacy Auth entries with Authentication cases: HTTP/WS/SSE supported, lifespan passed through. Preserve all unrelated middleware cases. Use existing `SSE::Retry` for nested namespace resolution tests rather than weakening that regression to a flat class name. Keep existing Request Basic/Bearer accessors and `t/request/05-auth.t`; those are not the retired middleware.

Update cookbook Basic/JWT examples to request-only backends or links to the complete example family, with explicit response decisions. Session documentation should describe opaque-record lookup without making Session an automatic authentication provider. Do not leave old `'pagi.auth' => { type, token, claims }` documentation active.

- [ ] **Run green:**

```sh
perlbrew exec --with perl-5.40.0@default prove -lv t/auth/08-middleware.t t/middleware/10-session-auth.t t/middleware/12-protocol-specific.t t/middleware-builder-resolution.t t/routing/04-middleware-descriptors.t t/request/05-auth.t t/00-load.t t/00-pod/cookbook-examples.t
```

- [ ] **Review and commit owned files:** `feat: add request-based authentication middleware`. Gate: guest/rejected results continue; operational failures propagate; unknown scopes pass unchanged before Request creation; no server or general Headers edits.

## Task 4: Composition, protocol admission, and async lifetime integration

**Files:**
- Create `t/auth/09-composition.t`, `t/auth/10-protocol-admission.t`.
- Extend `t/auth/08-middleware.t` for controlled cancellation/interleaving and `t/auth/04-protocol-integration.t` only where Auth composition needs extra coverage.
- Fix new Auth modules if these tests reveal defects. Existing Compose/Request/WebSocket/SSE/Test client runtime changes require a demonstrated independent defect and discussion first.

**Interfaces:**
- Consumes: Task 3 middleware plus ordinary `route`, `mount`, `middleware`, `compose`, `invoke_app`, `as_app_object`, `deny`, and `decline`.
- Produces: evidence that the same auth context works for Request handlers, native apps, app objects, nesting, HTTP/WS/SSE, and lifespan, without new runtime APIs.

- [ ] **Write composition tests around actual composed applications.** Start from the spec's §11.2 cookbook factory, including the HTTP-only bypass before `auth`. Use two protected routes, an unprotected route, and Compose startup/shutdown callbacks. Test factory/object/class middleware descriptor forms through existing composition. Assert backend/protection calls occur on HTTP but not startup/shutdown; do not assert a particular internal scope allocation by Compose.

For nesting, install an outer rejection, then an inner authenticated result, and capture both contexts through ordinary middleware. Assert inner replacement covers user, credentials, and failure together, while the outer observer still sees its Guest/failure. Demonstrate custom installation with this complete native middleware body:

```perl
my $custom = sub {
    my ($next) = @_;
    return async sub {
        my ($scope, $receive, $send) = @_;
        return await $next->($scope, $receive, $send)
            unless ($scope->{type} // '') eq 'http';
        my $result = unauth_result(scopes => ['notes:read']);
        my $inner = clone_scope($scope, { 'pagi.auth' => $result });
        await $next->($inner, $receive, $send);
        return;
    };
};
```

Exercise scope-bearing Request/WS/SSE sources. Assert state/stash/session references present at the middleware position remain observable; do not require later route parameters to exist there.

- [ ] **Write protocol tests using real Tools adapters and Test client.** Mount Authentication around HTTP, WS, and SSE routes. A missing/rejected identity produces explicit 401 via the handler's normal response/`deny`/`decline`; accepted identity reaches normal WS accept/SSE start. Include false user with grants and true user with no grants so policy is visibly application code. For example:

```perl
websocket('/socket' => async sub {
    my ($ws) = @_;
    unless (auth($ws)->user->is_authenticated) {
        await $ws->deny(sub {
            my ($request) = @_;
            return json_response({ error => 'Sign in' },
                status => 401,
                headers => ['WWW-Authenticate' => www_authenticate('Bearer')],
            );
        });
        return;
    }
    await $ws->accept;
    await $ws->close;
});
```

SSE uses `decline($application)` before `start`. Verify original protocol type, failure availability, response status/body and repeated headers, no acceptance/start event on refusal, and selected app response unchanged. Cover sync/async Request handlers, `to_app` object, and native three-argument app explicitly wrapped with `as_app_object`; use `invoke_app` inside native middleware. Preserve existing refusal tests for missing capabilities and post-start rejection instead of duplicating their entire state machine.

- [ ] **Write async boundary tests using pending Futures, not sleeps.** Cancel while backend is pending and assert no downstream invocation or late response. Cancel while downstream is pending and verify ordinary cancellation propagation; failed backend Future must remain an operational failure, not unauthenticated context. Run two pending invocations on one middleware instance, resolve them in reverse order, and verify no user/grants/failure leakage. On WS/SSE, retain existing public terminal callback/cleanup assertions through the new stack; do not pin server timeout durations or reach into server objects. In test-only connection doubles, existing driver methods are permissible setup, never runtime dependencies.

- [ ] **Run red, then fix only demonstrated Auth defects**, with the new tests before changes:

```sh
perlbrew exec --with perl-5.40.0@default prove -lv t/auth/08-middleware.t t/auth/09-composition.t t/auth/10-protocol-admission.t
```

Existing behaviors may already pass; do not manufacture a failure for unchanged Compose/protocol code.

- [ ] **Run the focused integration gate:**

```sh
perlbrew exec --with perl-5.40.0@default prove -lr t/auth t/compose t/routing t/websocket t/sse
perlbrew exec --with perl-5.40.0@default prove -lv t/integration/sse-decline-end-to-end.t t/test/client-sse-decline.t
```

- [ ] **Review and commit:** `test: verify auth composition and protocol admission`. Gate: no extra cleanup owner, fabricated HTTP scope, private `_emit`, or Server implementation knowledge.

## Task 5: Make both JWT sandbox variants executable

**Files:**
- Modify `examples/auth-jwt-sandbox/{app.pl,app2.pl,README.md}`; preserve `public/index.html` unless an observed API mismatch requires a small correction.
- Create `examples/auth-jwt-sandbox/cpanfile`, `t/integration-auth-jwt-sandbox.t`.
- Update the existing JWT entry in `examples/README.md` without replacing unrelated edits.

**Interfaces:**
- Consumes: real Auth runtime from Tasks 1–3 and existing approved JWT source.
- Produces: two runnable, separate applications: group-protected `app.pl`, inline three-route `app2.pl`. JWT decoding remains application code with no Auth dependency on Crypt::JWT.

- [ ] **Declare and verify optional example dependencies.** The example cpanfile lists Perl 5.40, PAGI::Tools and Crypt::JWT. Root `cpanfile` must not gain a required JWT dependency. Run:

```sh
perlbrew exec --with perl-5.40.0@default perl -MCrypt::JWT -e 1
```

If absent, record the dependency and use the normal dependency-install permission flow if needed. The dedicated test can skip clearly in a minimal distribution environment, but local completion of this task requires running it with Crypt::JWT installed. Check the current Crypt::JWT documentation before changing verifier exception handling or option usage; retain the explicit algorithm and expiration checks.

- [ ] **Write tests that load each real app in an isolated package/process**, following `t/integration-pages-example.t`. Both files define the same named handlers, so do not `do` both into `main` and accidentally test overwritten subs. Include:

```perl
my $missing = $client->get('/protected');
is $missing->status, 401;
is $missing->header('WWW-Authenticate'), 'Bearer realm="jwt-sandbox"';
my $bad = $client->get('/protected', headers => {
    Authorization => 'Bearer absolute-gibberish-token',
});
is $bad->status, 401;
like $bad->header('WWW-Authenticate'), qr/error="invalid_token"/;
my $malformed = $client->get('/protected', headers => {
    Authorization => 'Bearer first second',
});
is $malformed->status, 400;
like $malformed->header('WWW-Authenticate'), qr/error="invalid_request"/;
```

Use the Test client's existing nested-pair input for duplicate fields:

```perl
my $duplicate = $client->get('/protected', headers => [
    ['Authorization', 'Bearer first'],
    ['Authorization', 'Bearer second'],
]);
is $duplicate->status, 400;
like $duplicate->header('WWW-Authenticate'), qr/error="invalid_request"/;
```

Also test login-issued token success, expired token, invalid signature, missing `sub`, unsupported scheme guest, public page/login serving despite rejected credentials, group catalog protection, and no implicit grants from `role`. Assert status, body, and challenge, not just status. Capture public failure text to verify it contains neither token nor raw decoder exception.

- [ ] **Run before changing the examples:** `perlbrew exec --with perl-5.40.0@default prove -lv t/integration-auth-jwt-sandbox.t`. Any failures should identify an actual runtime/example mismatch; do not add a fake Auth package.
- [ ] **Make minimal application corrections**, preserving the explicit backend and response code already reviewed. Keep `app_path('public', 'index.html')`, the learning key/dummy-login labeling, and explicit 400/401 decisions. Do not introduce shared builder layers merely to deduplicate the two comparison examples. Mark examples runnable only after tests pass; keep the claim local, not “released on CPAN.”
- [ ] **Run green:** the same dedicated test, with both apps exercised and no missing-dependency skip.
- [ ] **Review and commit:** `feat: run JWT examples against authentication v1`. Gate: HTTP execution proves the example; no browser automation is needed for this Auth change.

## Task 6: Build the introductory opaque-token Notes example

**Files:**
- Create `examples/auth-notes/app.pl`, `examples/auth-notes/lib/NotesDemo/TokenStore.pm`, `examples/auth-notes/lib/NotesDemo/Library.pm`, `examples/auth-notes/README.md`.
- Create `t/integration-auth-notes.t`.
- Reconcile `docs/superpowers/specs/2026-09-19-auth-notes-example.md` incrementally and update `examples/README.md`.

**Interfaces:**
- Consumes: `auth`, `auth_result`, `unauth_result`, `www_authenticate`, user duck type, Credentials membership readers, ordinary handlers.
- Produces: one readable app and two application-owned in-memory fixture services. `TokenStore->find_active($token)` returns a Future containing a trusted record or undef; `Library->all_published` and `Library->publish($author, $data)` return Futures. These are example services, not new PAGI APIs.

- [ ] **Correct the Notes companion before copying code from it.** Replace `authenticated`/`rejected`, `on_failure`, failure status/header accessors, parsed-credential arguments, and the claim that the backend is not called for absent credentials. Record these corrected HTTP expectations: public `/notes` serves a Guest even after token rejection; `/me` explicitly challenges; malformed-header failures use the example's 400 code; operational store failures propagate. Preserve the developed examples/coverage explanations where still applicable and point to focused companions for material moved out. Do not change historical snapshot files.
- [ ] **Write the app acceptance test with deterministic record fixtures** from the companion. Test these outcomes:

| Request | Credential | Expected observation |
| --- | --- | --- |
| GET `/notes` | absent / unknown token | 200 with guest display; backend called; failure does not automatically refuse |
| GET `/me` | absent | 401 Bearer realm, no error parameter |
| GET `/me` | `alice-reader` | 200 Alice |
| POST `/notes` | `alice-reader` | 403 insufficient_scope; no publication |
| POST `/notes` | `alice-editor` | 201; author Alice |
| GET `/notes/export` | `export-service` | 200, despite no literal `authenticated` grant |
| GET `/me` | `export-service` | 200, based on user flag |
| POST `/notes` | read/write grants without named `authenticated` | 201 |
| POST `/notes` | write-only grants | 403, both read and write required |
| GET `/notes/export` | `Notes:Read` or empty grants | 403 |
| GET `/me` | duplicate Authorization / malformed Bearer field | 400 invalid_request |
| Any protected request | applicable token and failed store Future | operational failure; never 401 invalid_token |

Use a direct wrapped application to observe propagated failure; Compose may correctly render an operational exception as 500 at its outer error boundary. Assert the publishing service was not called on denied requests.

```perl
my $reader = $client->post('/notes',
    headers => { Authorization => 'Bearer alice-reader' },
    json => { text => 'A public note' },
);
is $reader->status, 403;
like $reader->header('WWW-Authenticate'), qr/error="insufficient_scope"/;
my $editor = $client->post('/notes',
    headers => { Authorization => 'Bearer alice-editor' },
    json => { text => 'A public note' },
);
is $editor->status, 201;
```

- [ ] **Run red:** `perlbrew exec --with perl-5.40.0@default prove -lv t/integration-auth-notes.t`.
- [ ] **Implement the small app.** The backend receives Request, reads all Authorization fields, uses the same limited malformed-header classification as the approved opaque/JWT sketches, awaits `find_active`, and returns constrained results. Endpoints inspect user/scopes and return explicit ordinary responses:

```perl
my $context = auth($request);
my $grants = $context->credentials;
unless ($grants->has_all('notes:read', 'notes:write')) {
    return json_response({ error => 'Publishing requires read and write access.' },
        status => 403,
        headers => ['WWW-Authenticate' => www_authenticate('Bearer',
            realm => 'notes', error => 'insufficient_scope',
            scope => 'notes:read notes:write',
        )],
    );
}
```

Place the separate user-flag check before this scope rule where required by the route matrix. Show the same identity with different token grants. Keep all notes public; bulk-export restrictions do not imply note confidentiality. No database, token issuer, OAuth flow, or login UI. README gives commands and HTTP examples with statuses/challenges for each main outcome.
- [ ] **Run green:** the Notes test and `perlbrew exec --with perl-5.40.0@default prove -lr t/auth`.
- [ ] **Review and commit:** `docs: add runnable opaque-token authentication example`. Gate: the introductory file is understandable without navigating a policy framework; remaining extension coverage is explicitly assigned to Task 7.

## Task 7: Focused examples for extension contracts

**Files:**
- Create `examples/auth-extensions/README.md` and these standalone scripts:
  - `01-users-and-results.pl`
  - `02-basic-backend.pl`
  - `03-context-and-placement.pl`
  - `04-response-applications.pl`
  - `05-protocol-admission.pl`
  - `06-header-primitives.pl`
- Create `t/auth/11-extension-examples.t`.
- Update `examples/auth-notes/README.md`, `examples/README.md`, and the Notes companion coverage index.

**Interfaces:**
- Consumes: implemented public APIs and existing Routing/Compose/Response/Pages/Scope utilities.
- Produces: executable demonstrations covering the remaining supported forms without bloating Notes. Files 01 and 06 may be direct scripts; files 02–05 return ordinary app objects. Tests execute the real example files, not copies of their logic.

- [ ] **Write an explicit coverage index before coding.** Each row below must name its file and test case. No requirement is satisfied only by saying “supported.”

| File | Required demonstrated behavior |
| --- | --- |
| 01 | Both built-in users and custom duck-typed Guest; custom Auth subclass through `SUPER`; all four helpers as function/class/instance and direct `new->...`; direct result readers; optional code/message; immediate and Future results; Guest grants; live list vs explicit copy; all scope helper forms including admin OR manager-and-edit |
| 02 | A real backend object with `authenticate($request)`, application construction/dependencies, Basic extraction/verification using existing Request support where suitable, explicit missing/rejected responses; no built-in Basic middleware resurrection |
| 03 | Custom authenticator using `clone_scope` and a completed result; Router/Route/Mount/Compose placement and normal middleware factory/object/class forms; nested complete replacement with preserved outer context; manual ownership check based on identity and grants |
| 04 | Sync/async Request notices, concrete Response, negotiated Pages, `to_app` object, and native CODE via `as_app_object`; one group wrapper explicitly awaits `invoke_app`/downstream; response is selected in application code |
| 05 | HTTP/WS/SSE share context; deny/decline before accept/start; public refusal application reads `auth($request)->failure`; ordinary successful lifecycle and cleanup |
| 06 | Formatter string and raw Headers/Response paths; multiple WWW-Authenticate fields; raw opaque challenge and Digest special quoting; MCP-style resource_metadata and explicit insufficient_scope response, without implementing discovery/OAuth/MCP methods |

Use fixed illustrative Basic credentials only as a labeled learning fixture. `PAGI::Request->basic_auth` currently decodes permissively and selects a single header; the example must check all fields before using it, and label its ASCII-only input boundary. Do not advertise that convenience method as strict RFC validation or change Request in this task. The example backend's extraction step is:

```perl
my @values = $request->header_all('Authorization');
return unauth_result() unless @values;
return unauth_result(failure => {
    code => 'malformed_authorization', message => 'Supply one Authorization field.',
}) unless @values == 1;
return unauth_result() unless $values[0] =~ /\ABasic(?: |\z)/i;
my ($username, $password) = $request->basic_auth;
return unauth_result(failure => { message => 'Credentials were not accepted.' })
    unless defined($username) && defined($password)
        && $username !~ /[^\x20-\x7e]/ && $password !~ /[^\x20-\x7e]/;
```

The object's supplied verification callback decides whether that pair matches its fixed fixture, and accepted results use SimpleUser with explicit grants. Missing or rejected credentials receive a Basic challenge chosen by the handler; Bearer error parameters do not apply. Document that production credential verification belongs to an application service. Do not publish a new password verifier or parser helper.

- [ ] **Write execution assertions before filling each example.** For application files load with the correct example library path and isolated package; use Test client to assert unauthenticated, authenticated, and denied outcomes. For script examples, exit success and check labeled outputs. Add one representative subclass example test:

```perl
{
    package DemoGuest;
    sub new { bless {}, shift }
    sub is_authenticated { 0 }
    sub identity { '' }
    sub display_name { 'Visitor' }
}
{
    package DemoAuth;
    use parent 'PAGI::Auth';
    sub unauth_result {
        my ($self, %args) = @_;
        $args{user} = DemoGuest->new unless exists $args{user};
        return $self->SUPER::unauth_result(%args);
    }
}
my $factory = DemoAuth->new;
is $factory->unauth_result->user->display_name, 'Visitor';
is PAGI::Auth::unauth_result()->user->display_name, '';
```

- [ ] **Run red:** `perlbrew exec --with perl-5.40.0@default prove -lv t/auth/11-extension-examples.t`.
- [ ] **Implement the examples with visible public operations.** The raw/MCP response should be as direct as:

```perl
my $response = json_response({ error => 'An access token is required.' },
    status => 401,
);
$response->headers->set('WWW-Authenticate',
    'Bearer realm="notes", resource_metadata="https://notes.example/.well-known/oauth-protected-resource/mcp"',
);
```

This is header construction only. Supply hand-written HTTP transcripts for the response forms. Keep literal status choices and explicit challenge construction; do not reintroduce `$context->challenge`, failure headers, or a catch-all backend error conversion. New scripts must be small and independent; application helper objects stay under the example namespace, never under `PAGI`.
- [ ] **Run green:** `perlbrew exec --with perl-5.40.0@default prove -lv t/auth/11-extension-examples.t t/integration-auth-notes.t t/integration-auth-jwt-sandbox.t`.
- [ ] **Review and commit:** `docs: demonstrate authentication extension contracts`. Gate: compare the coverage table against actual executable code; defer no delivered public form and revive no removed design feature.

## Task 8: Public reference, consistency audit, and completion gate

**Files:**
- Finish POD in `lib/PAGI/Auth.pm`, new Auth value modules, and `lib/PAGI/Middleware/Authentication.pm`.
- Finish affected public docs from Tasks 2–3, `README.md`, `examples/README.md`, the three Auth example READMEs, and Notes companion.
- Extend `t/00-pod/cookbook-examples.t` for the Auth cookbook's executable group-protection recipe, or add its extraction tests in `t/auth/12-cookbook.t` if that keeps the existing test focused.
- Create `docs/superpowers/plans/2026-09-20-authentication-v1-completion-handoff.md` at completion, with actual results only.

**Interfaces:**
- Consumes: final implemented API and all example tests.
- Produces: precise discoverable API docs, executed cookbook, removed stale active references, and evidence-based handoff. No new API is introduced here.

- [ ] **Write the public method reference** with exact arguments, accepted forms, return type, omission/default behavior, errors, and reference semantics for every helper and reader. Include a synopsis matching the inline JWT approach, then the optional group-protection cookbook. Show source resolution via scope/Request/WS/SSE; explain that credentials means granted scopes, not the original token. State that `pagi.auth` contains a completed Result, not public hash fields, and that absence is a configuration error. Explain no automatic `authenticated` grant and the custom Guest/factory path.
- [ ] **Make “Protecting a group of endpoints” executable from Auth POD.** Include two routes, Authentication-before-protection ordering, explicit HTTP/lifespan bypass, awaited downstream execution, and direct response invocation. Check the real extracted example with startup and shutdown, guest/accepted/rejected requests, and the same endpoints without the protection wrapper. Reuse the established POD extraction approach rather than matching source text for apparent correctness.

```perl
PAGI::Test::Client->run($documented_app, sub {
    my ($client) = @_;
    is $client->get('/one')->status, 401;
    is $client->get('/two')->status, 401;
    is $client->get('/public')->status, 200;
});
```

The complete extracted fixture supplies accepted test credentials and records lifecycle callbacks; assert both protected routes succeed with those credentials and shutdown finishes. Keep current exact Pages references and public `to_app` forms; do not regress to private `_emit`.

- [ ] **Audit old APIs in active code/docs** using this bounded search:

```sh
rg -n 'Auth::Challenge|Auth::Outcomes|Auth::Basic|Auth::Bearer|custom_challenge|failure_policy|after_auth|on_failure' lib t examples README.md
```

Inspect each hit: unrelated callbacks in other systems are not an Auth bug. Remove or rewrite obsolete Auth references, including comments and test descriptions; historical research under `docs/superpowers` is explicitly excluded. Check separately for hash-shaped `pagi.auth`, generated challenge/status/header readers, stale “backend not called” statements, and proposed/unimplemented banners in now-tested examples. Preserve dated historical records. Update the Notes companion's active status/coverage claims only to what the tests prove.

- [ ] **Validate POD and examples, then the full suite once:**

```sh
perlbrew exec --with perl-5.40.0@default prove -lr t/auth
perlbrew exec --with perl-5.40.0@default prove -lv t/00-pod/cookbook-examples.t t/integration-auth-jwt-sandbox.t t/integration-auth-notes.t t/integration-starlette-apples.t t/integration-auth-cookie-login.t
perlbrew exec --with perl-5.40.0@default prove -lr t
git diff --check
```

If a separate `t/auth/12-cookbook.t` exists it is included by `t/auth`. Run `podchecker` on each changed `.pm`/`.pod` using the same Perlbrew environment. Keep README consistent with its source in `lib/PAGI/Tools.pm`; do not run a distribution build that overwrites unrelated working files just to regenerate a paragraph. The runtime floor is unchanged: inspect new library syntax and, if the declared-floor environment is available, execute the new unit tests there. Do not claim a Perl 5.018 test run from a 5.40 run.

- [ ] **Review final scope and evidence.** Check the coverage mapping below, exact public interface forms, no secret values added to diagnostic messages, and lack of new server coupling. Report actual failures and skipped checks. A reviewer assesses mergeability and lists blockers; they are not instructed to reach a predetermined verdict. Do not repeat a passed full suite without a new change or unresolved failure that warrants it.
- [ ] **Write the handoff and commit owned documentation:** `docs: complete authentication v1 reference and validation`. Include branch/base/final commits, removed APIs, current spec authority, test commands and results, skipped dependency/floor checks, optional JWT requirements, and whether any server probe was actually run. This plan requires Tools end-to-end tests; it does not authorize or claim a new Server wire-level joint gate. No release, merge, deployment, or push.

## Spec coverage map

| Spec section / acceptance criteria | Tasks |
| --- | --- |
| §3.4 formatter, raw headers, MCP/extension fields; criteria 10, 11, 16, 28 | 2, 7, 8 |
| §§5–7 backend forms, invocation, results; criteria 1–3, 7–8, 19, 24–26 | 1, 2, 3, 5, 6 |
| §7.4 factory/dispatch; criteria 18, 20 | 2, 7 |
| §§8–9 context, users, live grants, scope helpers; criteria 4–6, 12–14, 19, 27, 30 | 1, 2, 4, 6, 7 |
| §10 explicit outcomes and malformed requests; criteria 7–8, 11, 22–23, 26 | 2, 5, 6, 7 |
| §11 normal middleware/app forms, protocols, lifecycle; criteria 9, 15, 21, 29 | 3, 4, 5, 7, 8 |
| §§12–15 example reconciliation and removal of research APIs | 2, 3, 5, 6, 7, 8 |
| Every public API has an example and observable result; criterion 17 | 5, 6, 7, 8 |

## Stop-and-discuss conditions

- Supporting this shape appears to require a second auth failure channel, callback registry, response interception, or per-scheme middleware configuration.
- A proposed fix needs general duplicate-Authorization enforcement in Headers/Request, automatic cookie/session authentication, or new JWT/OAuth runtime machinery.
- Composition would require fabricating HTTP scopes, calling `_emit`, adding Future `retain`/`without_cancel`, or taking terminal cleanup ownership away from existing helpers/server contracts.
- A new test demonstrates a defect in shared Request/Compose/protocol/Test client infrastructure that cannot be addressed by the specified Auth implementation or an existing public operation. Present the failing case and smallest proposed fix before broadening scope.
- An implementation task cannot remain understandable without several adapters or special cases. Show the concrete use case and added code rather than pressing on with another workaround.

Ordinary private factoring, validation consistent with this plan, and example fixture choices do not require another design round. Report an actual conflict, not hypothetical future flexibility.

## Execution order and review gates

Run Tasks 1 → 2 → 3 → 4 sequentially because they establish and replace shared interfaces. Tasks 5–7 can be delegated after Task 4, but assign a single owner for `examples/README.md` and the Notes companion; workers submit edits to those shared files to that owner. Task 8 follows all examples. Never have two agents mutate `PAGI::Auth.pm` or the same documentation concurrently.

For each task: targeted failing test → smallest implementation → targeted green → spec/scope review → code-quality review → scoped commit. Do not postpone superseded test updates to the final task. Keep the approved design and this work map in every worker brief; include exact consumed/produced interfaces, owned files, and the relevant gate commands. The final handoff distinguishes implemented, locally tested, and released behavior.
