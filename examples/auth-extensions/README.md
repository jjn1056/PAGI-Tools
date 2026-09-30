# Authentication extension examples

These independent examples extend the small [Notes API](../auth-notes/README.md).
Run them with Perl 5.40 and `-Ilib`. Files 01 and 06 print labeled results;
files 02–05 return ordinary application objects. The fixed credentials in 02
are a learning fixture. Production credential verification belongs in an
application service.

From the repository root:

```sh
perlbrew exec --with perl-5.40.0@default perl -Ilib examples/auth-extensions/01-users-and-results.pl
perlbrew exec --with perl-5.40.0@default perl -Ilib examples/auth-extensions/06-header-primitives.pl
PERL5LIB=lib perlbrew exec --with perl-5.40.0@default pagi-server --app examples/auth-extensions/02-basic-backend.pl --port 5000
perlbrew exec --with perl-5.40.0@default prove -lv t/auth/11-extension-examples.t
```

Use `03-context-and-placement.pl`, `04-response-applications.pl`, or
`05-protocol-admission.pl` in the server command to explore the other apps.

## Coverage index

The test cases below run the actual files in `t/auth/11-extension-examples.t`.

| File | Test case | Demonstrated behavior |
| --- | --- | --- |
| [01-users-and-results.pl](01-users-and-results.pl) | users and results script | Built-in users and duck-typed Guest; Auth subclass through `SUPER`; all four helpers as functions, classes, instances and direct `new->...`; result readers and optional failure code/message; immediate and Future results; guest grants; live scopes and an explicit copy; `has`, `has_any`, `has_all`, including admin OR manager plus edit |
| [02-basic-backend.pl](02-basic-backend.pl) | Basic backend app | Object `authenticate($request)` backend with supplied verifier, dependencies at construction, Request Basic extraction with strict parsing errors, missing/rejected responses, and accepted SimpleUser grants |
| [03-context-and-placement.pl](03-context-and-placement.pl) | context and placement app | Custom `clone_scope` authenticator and completed result; Router, Route, Mount and Compose placement; middleware factory, object and class; nested replacement preserving outer context; manual identity and grant ownership check |
| [04-response-applications.pl](04-response-applications.pl) | response applications app | Sync/async Request notices, concrete Response, negotiated Pages, `to_app` object, native CODE via `as_app_object`, and group wrapper awaiting `invoke_app`/downstream |
| [05-protocol-admission.pl](05-protocol-admission.pl) | protocol admission app | HTTP, WebSocket and SSE sharing installed context; refusal reading `auth($request)->failure` before accept/start; successful protocol lifecycle and cleanup |
| [06-header-primitives.pl](06-header-primitives.pl) | header primitives script | Independent Bearer utility, formatter and raw Headers/Response paths, repeated challenges, opaque raw challenge, Digest quoting, MCP-style `resource_metadata`, and explicit `insufficient_scope` response |

## Basic learning fixture

File 02 accepts `ada:test`, with `Authorization: Basic YWRhOnRlc3Q=`. Its backend
calls `Request->basic_auth(raise_on_error => 1)`, which rejects duplicate and
malformed fields while treating a missing field or another scheme as a guest.
The example separately accepts only ASCII username/password bytes from
`0x20` through `0x7e`. The example has an application-supplied
verification callback solely to make the dependency visible; it is not a
password verifier for reuse.

The handler chooses the Basic response for both missing and rejected credentials:

```http
GET /staff HTTP/1.1
Host: localhost:5000

HTTP/1.1 401 Unauthorized
WWW-Authenticate: Basic realm="staff"
Content-Type: application/json

{"error":"Basic credentials are required."}
```

```http
GET /staff HTTP/1.1
Host: localhost:5000
Authorization: Basic YWRhOnRlc3Q=

HTTP/1.1 200 OK
Content-Type: application/json

{"identity":"ada","can_read":1}
```

With `Basic YWRhOm5v` the first response is still 401 with the same Basic
challenge, and its JSON error is `Credentials were not accepted.`. These are
application decisions; the backend returns a result and does not emit HTTP.

## Context, responses, and protocol admission

File 03 installs a completed result in a cloned scope at the Compose boundary.
The nested Mount installs a new result. Its Route checks the trusted resource
owner ID against `user->identity` and checks `notes:edit` separately. The
outer wrapper can still observe its own context after the nested app finishes.

File 04 places refusal choices in the application. Its `/sync` and `/async`
routes return a Response from Request handlers. `/response` returns a concrete
Response; `/pages` lets Pages negotiate a problem representation; `/object`
returns an object with `to_app`; `/native` adapts a native three-argument CODE
with `as_app_object`. A group wrapper explicitly awaits `invoke_app` for either
its chosen refusal or the downstream app. Every 401 explicitly includes
`WWW-Authenticate: Bearer realm="demo"`; authentication middleware does not
add it. This follows [RFC 9110's 401 contract](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.5.2).
For example:

```http
GET /pages HTTP/1.1
Host: localhost:5000
Accept: application/json

HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer realm="demo"
Content-Type: application/problem+json

{"status":401,"detail":"Sign in to view this page.","title":"Unauthorized","type":"about:blank"}
```

JSON member order may vary. The problem fields come from Pages.
File 05 shares the installed context across HTTP, WebSocket, and SSE. Its public
refusal application receives a Request on the original scope and reads
`auth($request)->failure`. WebSocket denial occurs before `accept`, and SSE
decline before `start`. Accepted connections use the ordinary accept/start,
close, and cleanup paths:

```http
GET /events HTTP/1.1
Host: localhost:5000

HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer realm="demo"
Content-Type: application/json

{"error":"An access token is required."}
```

## Challenge values

The formatter returns one challenge string. File 06 shows repeated
`WWW-Authenticate` fields through `PAGI::Headers`, and direct Response header
mutation. A raw opaque challenge such as `Negotiate YWJj` stays raw. Digest's
`qop` list is a single quoted parameter value. The formatter quotes every
parameter and does not validate scheme-specific serialization. Digest
`algorithm` and `stale` require unquoted values; file 06 sets the complete raw
header value `Digest realm="notes", nonce="example-nonce", qop="auth", algorithm=SHA-256, stale=true`
through `PAGI::Headers` instead of passing those fields to the formatter.

The `resource_metadata` example only constructs a header value. It does not
serve discovery, acquire tokens, or implement OAuth or MCP methods:

```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer realm="notes", resource_metadata="https://notes.example/.well-known/oauth-protected-resource/mcp"
Content-Type: application/json

{"error":"An access token is required."}
```

An application can explicitly choose an insufficient-scope response:

```http
HTTP/1.1 403 Forbidden
WWW-Authenticate: Bearer realm="notes", error="insufficient_scope", scope="notes:read"
Content-Type: application/json

{"error":"Read access required."}
```
