# Opaque-token Notes API

A small Authentication v1 example: public notes, an identity endpoint, publishing,
and a permission-restricted bulk export. All notes are public. Export restrictions
control bulk access and do not imply confidentiality.

The backend receives a Request, extracts Bearer credentials with
`bearer_token(raise_on_error => 1)`, awaits the application-owned token store,
and returns `auth_result` or `unauth_result`.
Authentication installs that context and continues, even for rejected tokens.
Each protected handler explicitly checks the user or credentials and constructs
an ordinary response. The only shared response builder creates the authentication
notice; it does not enforce access or dispatch another application.

The checks are written by hand rather than with `PAGI::Auth`'s `requires`
because this API answers as RFC 6750 describes: 401 with a Bearer challenge
when the token is missing or rejected, 403 `insufficient_scope` naming the
scopes when it is not enough. `requires` refuses with one response and no
challenge, like Starlette's `@requires`; it suits pages and APIs that need no
challenge (see [auth-cookie-login](../auth-cookie-login/README.md)).

## Run

Use Perl 5.40 with PAGI::Tools and PAGI::Server available. From the repository root:

```sh
PERL5LIB=lib:examples/auth-notes/lib pagi-server --app examples/auth-notes/app.pl --port 5000
prove -lv t/integration-auth-notes.t
```

These services use memory and return Futures. Notes reset when the app restarts;
each server process has its own copy. The fixed tokens are public demonstration
records. There is no database, token issuer, OAuth flow, or login UI.

## Try the routes

```sh
curl -i http://localhost:5000/notes
curl -i http://localhost:5000/notes -H 'Authorization: Bearer unknown'
curl -i http://localhost:5000/me
curl -i http://localhost:5000/me -H 'Authorization: Bearer alice-reader'
curl -i http://localhost:5000/me -H 'Authorization: Bearer unknown'
curl -i http://localhost:5000/notes -H 'Authorization: Bearer alice-reader' -H 'Content-Type: application/json' -d '{"text":"A public note"}'
curl -i http://localhost:5000/notes -H 'Authorization: Bearer alice-editor' -H 'Content-Type: application/json' -d '{"text":"A public note"}'
curl -i http://localhost:5000/notes/export -H 'Authorization: Bearer export-service'
curl -i http://localhost:5000/notes/export -H 'Authorization: Bearer alice-reader'
curl -i http://localhost:5000/me -H 'Authorization: Bearer first second'
```

| Request | Token | Result / WWW-Authenticate |
| --- | --- | --- |
| GET `/notes` | absent, unknown, or malformed | 200, Guest viewer; no challenge |
| GET `/notes` | `alice-reader` | 200, Alice viewer |
| GET `/me` | absent | 401, `Bearer realm="notes"` |
| GET `/me` | unknown | 401, `Bearer realm="notes", error="invalid_token"` |
| GET `/me` | `alice-reader` | 200, Alice identity |
| GET `/me` | `export-service` | 200, Note exporter identity |
| POST `/notes` | `alice-reader` | 403, `Bearer realm="notes", error="insufficient_scope", scope="notes:read notes:write"` |
| POST `/notes` | `alice-editor` | 201, Alice is the author |
| GET `/notes/export` | `export-service` or `alice-reader` | 200 |
| GET `/me` | duplicate fields or malformed Bearer | 400, `Bearer realm="notes", error="invalid_request"` |

The three demo tokens: `alice-reader` and `alice-editor` are the same Alice
with different grants (`notes:read`, or `notes:read` and `notes:write`), and
`export-service` is a separate service identity with `notes:read`. Being
authenticated comes from the user the backend returns, not from a grant, so no
token needs an `authenticated` scope. The acceptance test adds edge cases to
the same store (a write-only grant, a differently cased `Notes:Read`, and an
empty grant list) and checks that exact grants are required.

## HTTP exchanges

These excerpts show the relevant response headers; JSON member order may vary.
The initial note list grows after successful publishing.

```http
GET /notes HTTP/1.1
Host: localhost:5000

HTTP/1.1 200 OK
Content-Type: application/json

{"viewer":"Guest","notes":[{"id":1,"author_id":"alice","text":"All notes in this demo are public."}]}
```

The same public response follows `Authorization: Bearer unknown`. The backend
still runs; its rejection supplies a guest result and the public handler serves
the notes. A protected route chooses a different response:

```http
GET /me HTTP/1.1
Host: localhost:5000
Authorization: Bearer unknown

HTTP/1.1 401 Unauthorized
Content-Type: application/json
WWW-Authenticate: Bearer realm="notes", error="invalid_token"

{"error":"Please authenticate."}
```

With no Authorization field, `/me` returns the same status and body, with only
`WWW-Authenticate: Bearer realm="notes"` and no error parameter.

```http
GET /me HTTP/1.1
Host: localhost:5000
Authorization: Bearer alice-reader

HTTP/1.1 200 OK
Content-Type: application/json

{"user_id":"alice","display_name":"Alice","scopes":["notes:read"]}
```

```http
POST /notes HTTP/1.1
Host: localhost:5000
Authorization: Bearer alice-reader
Content-Type: application/json
Content-Length: 24

{"text":"A public note"}

HTTP/1.1 403 Forbidden
Content-Type: application/json
WWW-Authenticate: Bearer realm="notes", error="insufficient_scope", scope="notes:read notes:write"

{"error":"Publishing requires read and write access."}
```

Changing that token to `alice-editor` returns 201 with a new note containing its
ID, `author_id: "alice"`, and the supplied text. The request cannot choose another
author. Publishing expects a JSON object with a nonempty `text` string; invalid
note input returns 400 before the publishing service runs. A body that is not
JSON at all is refused by `$request->json` itself, as a 400 problem document.

Duplicate Authorization fields and malformed Bearer syntax produce the local
failure code `malformed_authorization`. Protected handlers turn that into 400
`invalid_request`. Another scheme is treated as absent Bearer credentials. This
is the same small parsing convention used by the JWT examples, not a general
Authorization parser. A token-store exception or failed Future propagates;
Compose may render it as 500 at its outer error boundary. It never becomes a
401 `invalid_token` response.

## Example coverage

| File | Demonstrates |
| --- | --- |
| [app.pl](app.pl) | Request backend, explicit results, default guest, user flag, `auth`, scope membership, and ordinary 400/401/403 responses |
| [TokenStore.pm](lib/NotesDemo/TokenStore.pm) | Fixed trusted identity/grant records and a Future-returning lookup |
| [Library.pm](lib/NotesDemo/Library.pm) | Public in-memory notes and Future-returning publication under an authenticated author |
| [Acceptance test](../../t/integration-auth-notes.t) | Route matrix, absence still invoking the backend, no publishing on denial, and direct propagation of store failure |
| [JWT companions](../auth-jwt-sandbox/README.md) | Inline and grouped authentication checks with an application-owned JWT verifier |
| [Extension companions](../auth-extensions/README.md) | Executable coverage index for custom users, Basic backend, context placement, response forms, protocol admission, and challenge headers |

The extension companions keep custom users/factories, Basic verification,
context composition, Pages/native response forms, header values, and
WebSocket/SSE admission separate from this introduction.
