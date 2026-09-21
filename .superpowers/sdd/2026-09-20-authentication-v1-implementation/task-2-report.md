# Task 2 report: Auth facade and challenge research API retirement

## Status

Implemented the Authentication v1 facade, completed-result constructors, public
scope observation, and `WWW-Authenticate` formatter. Retired the research-phase
Challenge and Outcomes modules after migrating every active caller in Task 2's
scope to ordinary Pages/Response applications.

## Red/green evidence

The required red command was run before production changes:

```text
perlbrew exec --with perl-5.40.0@default prove -lv \
  t/auth/06-constructors-context.t t/auth/07-www-authenticate.t
Result: FAIL
Reason: auth, auth_result, unauth_result, and www_authenticate were not exported.
```

After implementation, the focused constructor/formatter run passed 92 tests.
The exact task green gates then passed:

```text
perlbrew exec --with perl-5.40.0@default prove -lr t/auth t/pages
Files=11, Tests=453, Result: PASS

perlbrew exec --with perl-5.40.0@default prove -lv \
  t/00-load.t t/00-pod/cookbook-examples.t \
  t/integration-starlette-apples.t t/integration-auth-cookie-login.t
Files=4, Tests=110, Result: PASS
```

## Owned files

- Replaced `lib/PAGI/Auth.pm`.
- Removed `lib/PAGI/Auth/Challenge.pm` and `lib/PAGI/Auth/Outcomes.pm`.
- Added `t/auth/06-constructors-context.t` and
  `t/auth/07-www-authenticate.t`.
- Removed superseded `t/auth/01-challenge-values.t`,
  `t/auth/02-bearer.t`, and `t/auth/03-outcomes.t`.
- Updated `t/auth/04-protocol-integration.t` and `t/00-load.t`.
- Migrated documentation/examples in `lib/PAGI/Response.pm`,
  `lib/PAGI/Tools.pm`, `lib/PAGI/Tools/Cookbook.pod`,
  `lib/PAGI/Tools/Tutorial.pod`, `README.md`,
  `examples/starlette-apples/app.pl`,
  `examples/starlette-apples/README.md`, and
  `examples/auth-cookie-login/README.md`.

## Migration inventory

- Protocol fixtures now use Pages 401 applications. Repeated authentication
  fields deliberately combine one raw Basic value with one formatter-built
  Bearer value. Direct `deny`/`decline` application use and intentional
  `response_for` coverage are both retained.
- The Apples routing example retains negotiated rendering, its exact safe
  detail, a raw Bearer field, and `no-store`; it still performs no authentication.
- Response and Cookbook WebSocket/SSE/native examples now pass ordinary Pages
  applications directly to protocol refusal or normal invocation helpers.
- Basic, Bearer, insufficient-scope, repeated-field, and custom presentation
  recipes now choose explicit Pages statuses and headers.
- Cookie-login prose now describes the current separation from the Auth facade.
- Load coverage now verifies the removed Challenge and Outcomes modules are no
  longer loadable.

## Self-review and concerns

The implementation adds only the four specified optional exports and a
zero-option stateless factory. Constructors retain supplied references, create
fresh omitted defaults, enforce the user duck type and authentication flag, and
do not synthesize grants. Context lookup accepts only a raw scope or scope
object and validates Result provenance. Formatter validation follows byte-level
HTTP quoted-string input, preserves pair order/casing, rejects duplicate names
case-insensitively, and escapes only quote/backslash.

No active caller of the removed APIs remains outside historical design/plan
documents. Legacy middleware descriptions remain because middleware removal is
Task 3. No protocol helper or unrelated dirty file was changed. No unresolved
contract conflicts or infrastructure concerns were found.

## Review follow-up: custom context installation

Added the public custom-middleware recipe requested by Task 2 review. The Auth
reference now shows unsupported scope passthrough, completed authenticated and
guest result construction, whole-entry installation under `pagi.auth` with
`clone_scope`, and downstream invocation. Its explanation states that the child
scope replaces the complete entry while preserving the original result, user,
and scopes references without merging outer context.

Exact covering checks:

```text
perlbrew exec --with perl-5.40.0@default podchecker lib/PAGI/Auth.pm
lib/PAGI/Auth.pm pod syntax OK.
Result: PASS (exit 0)

perlbrew exec --with perl-5.40.0@default perl -Ilib -c lib/PAGI/Auth.pm
lib/PAGI/Auth.pm syntax OK
Result: PASS (exit 0)
```
