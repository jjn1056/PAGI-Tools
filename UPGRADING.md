# Upgrading PAGI-Tools

This release breaks most of the 0.002002 API on purpose: routing, the
Context handler objects, the Response builder and the stock applications
are replaced. There are no compatibility aliases; every removed form fails
when used. Upgrade PAGI::Server to **0.003000** or later at the same time,
and run on **Perl 5.24** or later.

Start with the table, then the worked ports. Each row links to the details
in [UPGRADING-REFERENCE.md](UPGRADING-REFERENCE.md).

## What replaces what

| 0.002002 | Now |
|---|---|
| Perl 5.18 or later | Perl 5.24 or later, as PAGI and PAGI::Server (see "Perl version support" in [PAGI](https://metacpan.org/pod/PAGI)) |
| `PAGI::App::Router` (`get`, `group`, `as`, `uri_for`, `not_found`) | `PAGI::Routing`: `router`, `route`, `mount`, `path_for`, `http_default` ([details](UPGRADING-REFERENCE.md#migrate-app-router-declarations)) |
| `PAGI::Endpoint::Router` (`routes($self, $r)`, string targets, `$self->state`) | a class whose `routing` returns a Router; lifespan state ([details](UPGRADING-REFERENCE.md#migrate-endpoint-router-classes)) |
| Handlers receive a Context (`$ctx`) | handlers receive the `PAGI::Request`, `PAGI::WebSocket` or `PAGI::SSE` ([details](UPGRADING-REFERENCE.md#breaking-replace-the-pagi-context-family-with-the-protocol-owner)) |
| `$ctx->json`/`text`/`html`/`redirect`, `$request->response`, the mutable Response builder | return `response('JSON', ...)`, `response('Text', ...)`, ... ([details](UPGRADING-REFERENCE.md#breaking-choose-a-concrete-response-class)) |
| `$ctx->stash`, `session`, `state`, `csrf_verify`, `on_drain` | `stash($request)`, `session($request)`, `app_state($request)`, `csrf($request)`, `transport($request)` ([details](UPGRADING-REFERENCE.md#import-optional-capabilities-from-their-owners)) |
| `stash($request)` created the stash on first use | it dies without one: stack `middleware('Stash')` above every layer that uses the stash (PAGI::Middleware::Stash) |
| App::Router handlers as native `($scope, $receive, $send)` apps | Route CODE gets one Request; wrap natives with `as_app_object` ([details](UPGRADING-REFERENCE.md#migrate-app-router-declarations)) |
| `PAGI::App::NotFound`, `PAGI::App::Redirect` | `PAGI::Pages` `not_found`, `redirect` ([details](UPGRADING-REFERENCE.md#pages-replaces-the-stock-response-applications)) |
| `Test::SSE`/`Test::WebSocket`: an app that died in an unfinished refusal had the detail "refusal started but never completed" | the error's first line, as for any failure, and as PAGI-Server records it ([details](UPGRADING-REFERENCE.md#running-against-pagi-server-0002007)) |
| `Test::WebSocket`: a dying app's disconnect detail was the whole exception | its first line without " at FILE line N", as `Test::SSE` and PAGI-Server record it ([details](UPGRADING-REFERENCE.md#running-against-pagi-server-0002007)) |
| `Test::SSE`/`Test::WebSocket` `is_closed` true only after the test's `close` (or, for WebSocket, the app's `websocket.close`) | also true when the app returns, dies or refuses; sent events stay readable ([details](UPGRADING-REFERENCE.md#running-against-pagi-server-0002007)) |
| `Test::Client`: an HTTP handler waiting on its own event loop (an IO::Async timer) completed without setup | bind Future::IO to that loop in the test: `use Future::IO::Impl::IOAsync`; then WebSocket, SSE and lifespan waits run it too (PAGI::Test::Client, "Testing an application that commits to an event loop") |
| `Test::Client`: `form`/`query` values sent each character as one byte, so a test passed pre-encoded UTF-8 (`"h\xc3\xa9"`) to get the right bytes | pass characters (`"h\x{e9}"`); they are sent UTF-8 percent-encoded, as the path and `json` are (PAGI::Test::Client, "query", "form") |
| `Test::Client`: a receive after the whole request body answered `http.disconnect` at once, so a second read of a consumed body read `''` | it waits until the response is complete, as a server does; a second read dies after 5 seconds naming it -- pass the one Request on (PAGI::Test::Client, "HTTP METHODS") |
| ErrorHandler `content_type`; errors swallowed after start | `catch` entries for the errors the app expects, a `handler` reading `error_context($request)` for the rest; an unhandled error re-raised to the server; in Compose, RequestId, AccessLog and response-header middleware that must cover the 500 wrap the compiled app ([details](UPGRADING-REFERENCE.md#breaking-errorhandler-re-raises-server-errors)) |
| an unknown middleware option | now dies; check spelling and renamed options (`invalid` → `refuse`) |
| Session `secret`, `cookie_name`, `cookie_options`; `State::Bearer` | `state => session_state('Cookie', ...)`; no secret ([details](UPGRADING-REFERENCE.md#breaking-the-session-cookie-is-configured-on-statecookie-not-on-the-middleware)) |
| CSRF `enforce => 'header'` / `enforce => 'app'` | the default / remove it: `form_field => 'csrf_token'`, and the middleware checks each form's field; `enforce` now dies ([details](UPGRADING-REFERENCE.md#breaking-csrf-enforce-is-replaced-by-refuse)) |
| CSRF `secret`; its `HttpOnly` cookie | remove `secret` (tokens are random; passing it dies); `httponly => 1` keeps the flag; `session => 1` binds the token to the session ([details](UPGRADING-REFERENCE.md#breaking-csrf-secret-removed-cookie-readable-origin-checked)) |
| cross-origin unsafe requests through CSRF | refused; list legitimate callers in `trusted_origins` ([details](UPGRADING-REFERENCE.md#breaking-csrf-secret-removed-cookie-readable-origin-checked)) |
| RateLimit `backend` | removed (it was never used); passing it dies ([details](UPGRADING-REFERENCE.md#breaking-ratelimit-backend-is-removed-limiters-no-longer-share-buckets)) |
| `PAGI::App::Throttle` | `middleware('RateLimit', ...)`; `key_generator => sub { 'global' }` for one bucket ([details](UPGRADING-REFERENCE.md#breaking-pagiappthrottle-is-removed)) |
| `PAGI::App::Proxy` | removed: it blocked the event loop; proxy in front with nginx, HAProxy or Caddy ([details](UPGRADING-REFERENCE.md#breaking-pagiappproxy-is-removed)) |
| `PAGI::App::WrapCGI` | rewritten: no longer blocks the loop; POST bodies, `timeout` and the CGI environment now work; `refuse` ([details](UPGRADING-REFERENCE.md#changed-pagiappwrapcgi-is-rewritten)) |
| `PAGI::Request` caches what it parses in the scope (`pagi.request.*`), shared by every Request over that scope | each Request keeps its parse on itself and writes nothing to the scope; pass the one Request on rather than building a second to re-read the body |
| scope keys `csrf_token`, `original_client`, `original_method`, `original_path`, `request_id` | the same names under `pagi.` ([details](UPGRADING-REFERENCE.md#breaking-middleware-scope-keys-move-under-pagi)) |
| Maintenance `body`, `content_type` | `response => response('HTML', $page, status => 503)`; the default is now plain text; both options now die ([details](UPGRADING-REFERENCE.md#breaking-maintenance-body-and-content_type-are-replaced-by-response)) |
| ContentNegotiation `strict`, `default_type` | refusing is the default; `refuse => 0` lets the application decide; both options now die ([details](UPGRADING-REFERENCE.md#breaking-contentnegotiation-refuses-by-default-strict-and-default_type-are-removed)) |
| `PAGI::Request::Negotiate` | `PAGI::ContentNegotiation`: the same class methods |
| scope keys `pagi.preferred_content_type`, `pagi.accepted_types` | `negotiated_type($request)` (PAGI::ContentNegotiation); the record `pagi.content_negotiation` holds `type`, `supported`, `refusing` and `accepted` |
| an unknown shortcut in ContentNegotiation `supported_types` became `application/<name>` | it dies when the middleware is built; use a media type or a known shortcut |
| `Auth::Basic`, `Auth::Bearer` | `Authentication` with a backend, plus `Requires` ([details](UPGRADING-REFERENCE.md#breaking-authbasic-and-authbearer-are-replaced-by-authentication)) |
| `FormBody`, `JSONBody` middleware | `$request->form_params`, `$request->json` ([details](UPGRADING-REFERENCE.md#breaking-pagimiddlewareformbody-and-pagimiddlewarejsonbody-are-removed)) |
| `PAGI::App::Loader` | `pagi-server --app`, or `do $file` ([details](UPGRADING-REFERENCE.md#breaking-pagiapploader-is-removed)) |
| WebSocket/SSE `->state` hashref | a `PAGI::State` object ([details](UPGRADING-REFERENCE.md#breaking-direct-websocket-and-sse-state-matches-request)) |
| WebSocket `on_close` `($code, $reason)`; SSE `on_close` `($sse, $reason)` | a third argument, `$detail`; a strict signature must accept it ([details](UPGRADING-REFERENCE.md#breaking-on_close-callbacks-receive-a-third-argument)) |
| a failing `on_close` callback was warned | every callback runs; the first failure fails `finished`, so a route's call fails and the server logs it (a helper you build yourself reports it only if you `await $ws->finished`) |
| `PAGI::WebSocket->new` / `PAGI::SSE->new` in your own handler | end the handler with `await $ws->finished`, so `on_close` cleanup is part of its call (routes and Endpoint classes do it for you) |
| `$f->on_fail(...)->retain` for work the client does not wait for | `PAGI::FutureOwner`: `$owner->adopt($f)`, then `await $owner->settled` in `lifespan.shutdown` |
| `$ws->deny(status => ..., body => ...)` | `$ws->deny($response)`; new `$sse->decline($response)` ([details](UPGRADING-REFERENCE.md#refuse-websocketsse-with-request-handlers-or-applications)) |
| Builder `enable '^My::Middleware'` | `enable '+My::Middleware'` ([details](UPGRADING-REFERENCE.md#breaking-use-explicit-middleware-descriptions-at-core-boundaries)) |
| Directory `show_hidden` | `allow_hidden` ([details](UPGRADING-REFERENCE.md#rooted-file-serving-security-contract)) |
| `WebSocket::RateLimit`, `SSE::Pubsub`, `WebSocket::Broadcast`/`Chat` | removed; Cookbook recipes ([details](UPGRADING-REFERENCE.md#other-breaking-changes)) |
| WebSocket `query`, `raw_query`; Request `query`, `raw_query`, `form`, `raw_form` | `query_param`, `raw_query_param`, `form_params`, `raw_form_params`: one set of names on Request, WebSocket and SSE |
| WebSocket `send_text_if_connected`, `send_bytes_if_connected`, `send_json_if_connected` | `try_send_text`, `try_send_bytes`, `try_send_json`: they send nothing unless connected (before `accept` too) and return false |
| `body_stream(strict => 1)` died with "Failed to decode chunk" (a 500) on invalid bytes | a `PAGI::Exception::RequestBody` 400; an encoding it cannot decode in chunks (unknown, ISO-2022-*, UTF-7) is a `PAGI::Exception::RequestBody` 415 when the stream is made |
| a client disconnect mid-character flushed U+FFFD from `body_stream(decode)`, or threw under strict | the text ends at the last whole character; check `$stream->truncated` |
| `body_stream` over `max_bytes` died with "Request body max_bytes exceeded" (a 500) | a `PAGI::Exception::RequestBody` 413 `too_large` (400 `invalid_body` past the Content-Length); the limit's name is in `->cause`, not the message |
| `$request->text` decoded every body as UTF-8 | it decodes with the Content-Type charset, UTF-8 when none is declared; an unknown charset is a 415 |
| `each_json` died (a 1011 server error) on a message that is not JSON | it closes 1007 and returns; pass `on_invalid_json`, or override `handle_invalid_json`, to answer otherwise |
| `MyEndpoint->to_app` (an Endpoint class name) | `endpoint('MyEndpoint')->to_app`, or `MyEndpoint->new->to_app`; on a class name it now dies |
| `$request->header`, `PAGI::Headers->get`, `PAGI::Response->header` returned the last value of a repeated field | every value joined `", "` in order, as Mojo::Headers, PSGI and Plack::Request do; read `Set-Cookie` with `header_all` / `get_all`; `get_single` still rejects duplicates |
| `$request->cookie` / `cookies` percent-decoded each value (`a=x%2Fy` read `x/y`) | the value as the client sent it (`x%2Fy`), quotes removed (and, inside them, `\"` and `\\` undone, as Mojolicious does); encode and decode your own values (as Starlette and Mojolicious read cookies) |
| `$request->cookie` gave the first value of a cookie name sent twice | the last value, as query and form parameters do |
| `PAGI::WebSocket->new` / `PAGI::SSE->new` over a scope that already had one returned that object (cached in the scope as `pagi.websocket` / `pagi.sse`) | a new object on every call, and nothing stored in the scope: build one per connection and pass it on |
| `$ws->path_param` / `$sse->path_param` returned `undef` for a name the route did not capture | it dies naming the names it did capture, as `$request->path_param` does; pass `strict => 0` for `undef` |
| `$sse->path` answered `'/'`, and `$ws->path` / `$request->path` `undef`, on a scope without a path; `raw_path` / `request_uri` answered `'/'` on a scope with neither `raw_path` nor `path` | each dies "this scope has no path": a PAGI scope always has one |
| A second `PAGI::WebSocket` / `PAGI::SSE` over a connection another helper answered: `accept` / `start` / `close` / `keepalive` returned quietly, WebSocket sends croaked "Cannot send on closed WebSocket", `receive` returned `undef`, SSE sends returned as if sent | every operation croaks "this connection was answered by another helper; use that one" and sends and reads nothing (`try_send*` still return 0): use the helper that answered, or wrap `$send` / `$receive` in a middleware |
| After `$ws->deny` / `$sse->decline` started its response, `accept`, `start`, sends and `receive` returned quietly or croaked "Cannot send on closed WebSocket" | they croak "this helper is refusing the connection"; `close`, `close_or_deny`, `keepalive` and `try_send*` stay quiet |
| A send, `close` or `keepalive` from another branch of the handler while the helper's own `accept` / `start` was still pending died "Cannot send on closed WebSocket" or did nothing | it reaches the server after the accept or start, in call order |
| After an `accept` / `start` the server rejected (its `await` raises), WebSocket sends croaked "Cannot send on closed WebSocket", SSE sends returned without sending, `try_send*` returned 0, and `keepalive` and `close` sent nothing | the helper stays the connection's answerer, as Starlette's WebSocket does: its sends, `try_send*`, `keepalive`, `close` and `close_or_deny` go to the server, which answers them; to recover, build a new helper while the connection is live and unanswered, or use the one that answered |
| CORS and CSRF checked the first `Origin` (and CSRF the first `Sec-Fetch-Site`, `Host` and token header) | every field joined `", "`: a header sent twice fails its check |
| ReverseProxy used the first `X-Real-IP` / `X-Forwarded-Proto` / `X-Forwarded-Port`; Session::State::Header, RequestId (`trust_incoming`) and MethodOverride the first session, request-id or override header | a header sent twice is absent: the socket's client, scheme and port stand, there is no session id, a new request id is made, and MethodOverride checks `_method` |
| MethodOverride's `_method` gave the first of a repeated parameter and split only on `&` | the last, splitting on `&` or `;`, as `query_param` does |
| GZip compressed only when the first `Accept-Encoding` field named gzip; App::Directory listed JSON only when the first `Accept` field named `application/json` | any field counts (every field joined) |
| AccessLog logged the last `Referer` / `User-Agent` of a repeated field | every field joined `", "` |
| CSRF's token cookie, Session::State::Cookie's session cookie and the Cookie middleware's `pagi.cookies` read only the first `Cookie` field; CSRF and the Cookie middleware took the first of a repeated name, and the Cookie middleware percent-decoded | every `Cookie` field, quotes removed, the last of a repeated name, never percent-decoded (as `$request->cookie`) |
| `Response->cookie` and the Cookie middleware's `cookie_jar->set` percent-encoded the value (`x/y` sent `x%2Fy`; `;` or a space was encoded); a cookie already set that way reads back encoded (`x%2Fy`) until it is set again | the value is written as is and must be RFC 6265 cookie-octets (printable ASCII except space, `"`, `,`, `;`, `\`); anything else croaks, "encode it first (Base64, say)"; read back, a value is what was written; clear the old cookies or set them again; a cookie name must be an RFC 6265 token (it was percent-encoded, which reading never undid); a `samesite` that is given must be Lax, Strict or None (any case) or it croaks (an unknown value was silently omitted) |
| `Session::State::Cookie->extract` / `Session::State::Header->extract` read any hash with `headers` | they take an http, websocket or sse scope (one with its `type`) |
| `$request->content_length` and `$sse->last_event_id` read the first field of a repeated header | `undef` for a repeated field (a value used as a value reads `headers->get_single`) |
| Session gave a read-only session to any scope type with `headers` | only `websocket` and `sse` scopes get one; any other type passes to the app untouched, with no `pagi.session` |
| Reading the body of an Authentication backend's or an ErrorHandler handler's Request died with a message of its own | it dies "this Request was built from the scope alone; it has no body", as every Request without a receive does |

Behaviour that changes without a code change: stock refusals and error
responses are plain text, each replaceable by one option ([details](UPGRADING-REFERENCE.md#audit-changed-first-party-defaults));
bad request bodies are 400/413 ([details](UPGRADING-REFERENCE.md#bad-request-bodies-answer-400-or-413-not-500));
`raw_path` is the full requested path ([details](UPGRADING-REFERENCE.md#raw_path-request_uri-raw_path_info-and-serving-under-a-prefix));
file serving is stricter ([details](UPGRADING-REFERENCE.md#rooted-file-serving-security-contract));
and the test kit is as strict as a real server
([details](UPGRADING-REFERENCE.md#running-against-pagi-server-0002007)).

## A worked port

A small notes service, as written for 0.002002 and as ported. Both run, and
answer the same requests the same way (the After is pinned by
`t/upgrading-worked-port.t`).

**Before: 0.002002.**

```perl
package MyApp;
use parent 'PAGI::Endpoint::Router';
use Future::AsyncAwait;

sub routes {
    my ($self, $r) = @_;
    $self->state->{notes} = {};
    $r->get('/' => 'home');
    $r->post('/login' => 'login');
    $r->get('/notes/:id' => 'show_note');
    $r->post('/notes' => ['require_login'] => 'create_note');
}

async sub require_login {
    my ($self, $ctx, $next) = @_;
    return $ctx->json({ error => 'login required' }, status => 401)
        unless defined $ctx->session->get('user', undef);
    return await $next->();
}

async sub home {
    my ($self, $ctx) = @_;
    return $ctx->text('My notes');
}

async sub login {
    my ($self, $ctx) = @_;
    $ctx->session->set(user => 'ada');
    return $ctx->json({ ok => 1 });
}

async sub show_note {
    my ($self, $ctx) = @_;
    my $note = $self->state->{notes}{ $ctx->request->path_param('id') }
        or return $ctx->json({ error => 'no such note' }, status => 404);
    return $ctx->json($note);
}

async sub create_note {
    my ($self, $ctx) = @_;
    my $data  = await $ctx->request->json;
    my $notes = $self->state->{notes};
    my $id    = keys(%$notes) + 1;
    $notes->{$id} = { id => $id, text => $data->{text} };
    return $ctx->json($notes->{$id}, status => 201);
}

package main;
use PAGI::Middleware::Builder;

builder {
    enable 'Session', secret => 'change-me';
    enable 'ErrorHandler', content_type => 'application/json';
    MyApp->to_app;
};
```

**After.**

```perl
use v5.40;
use Future::AsyncAwait;
use PAGI::Compose qw(compose);
use PAGI::ErrorContext qw(error_context);
use PAGI::Response qw(response);
use PAGI::Routing qw(middleware route);
use PAGI::Session qw(session);
use PAGI::State qw(app_state);

async sub home ($request) {
    return response('Text', 'My notes');
}

async sub login ($request) {
    session($request)->set(user => 'ada');
    return response('JSON', { ok => 1 });
}

async sub show_note ($request) {
    my $note = app_state($request)->get('notes')->{ $request->path_param('id') }
        or return response('JSON', { error => 'no such note' }, status => 404);
    return response('JSON', $note);
}

async sub create_note ($request) {
    return response('JSON', { error => 'login required' }, status => 401)
        unless defined session($request)->get('user', undef);
    my $data  = await $request->json;
    my $notes = app_state($request)->get('notes');
    my $id    = keys(%$notes) + 1;
    $notes->{$id} = { id => $id, text => $data->{text} };
    return response('JSON', $notes->{$id}, status => 201);
}

# Every error in JSON: a catch entry is given the error, a handler reads it.
sub json_error ($request, $error = error_context($request)) {
    return response('JSON', { error => $error->message });
}

compose(
    lifespan => { startup => sub ($state, $scope) { $state->{notes} = {} } },
    routes => [
        route('/' => \&home),
        route('/login' => \&login, methods => ['POST']),
        route('/notes/{id}' => \&show_note),
        route('/notes' => \&create_note, methods => ['POST']),
    ],
    middleware => [
        middleware('Session'),
        middleware('ErrorHandler',
            catch   => { 'PAGI::Exception::RequestBody' => \&json_error },
            handler => \&json_error,
        ),
    ],
);
```

What changed, line by line:

- The `PAGI::Endpoint::Router` class became plain subs and one `compose`
  call; string targets became `\&handler` references.
- Each handler receives the `PAGI::Request` and returns a Response
  (`response('JSON', ...)`, `response('Text', ...)`) instead of calling `$ctx->json`.
- The `require_login` middleware method became a check inside the one
  handler that needs it; a check shared by many routes could be a
  `middleware(...)` description on a `mount`, such as `Requires`.
- `$self->state` became lifespan state: set in Compose's `startup`, read
  with `app_state($request)`.
- `$ctx->session` became `session($request)`; Session no longer takes
  `secret`.
- ErrorHandler's `content_type` became `catch` entries for the errors the
  application expects (here a body that is not JSON) and a `handler` for
  the rest; both answer in JSON. An entry is given the error; the handler
  reads it with `error_context($request)`. In 0.002002 a body that was not
  JSON was a 500; it is now a 400.
- `:id` became `{id}`, and `post` became `methods => ['POST']`.

## A worked port: middleware that reads a header

Middleware that read request headers kept a private loop over
`$scope->{headers}`. It now builds a `PAGI::HTTPConnection` from the scope:
it reads headers, query, cookies and path parameters without touching the
body, writes nothing to the scope, and is what `PAGI::Request`,
`PAGI::WebSocket` and `PAGI::SSE` extend. This is `PAGI::Middleware::CORS`'s
own port.

**Before: a private `_get_header`.**

```perl
sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        # Only handle HTTP requests
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Get Origin header
        my $origin = $self->_get_header($scope, 'origin');
        ...
    };
}

sub _get_header {
    my ($self, $scope, $name) = @_;

    $name = lc($name);
    for my $h (@{$scope->{headers} // []}) {
        return $h->[1] if lc($h->[0]) eq $name;
    }
    return;
}
```

**After.**

```perl
use PAGI::HTTPConnection ();

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        # Only handle HTTP requests
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Origin, every field joined: a repeated Origin matches no allowed
        # origin.
        my $origin = PAGI::HTTPConnection->new($scope)->header('origin');
        ...
    };
}
```

What changed:

- The loop is gone; `header` is case-insensitive and gives `undef` when the
  field is absent.
- A repeated field reads as every value joined `", "`. The loop took the
  first, so a second `Origin` was ignored; now the joined value matches no
  allowed origin and the check fails, as it should. For a value used as a
  value (an address, an id), read `->headers->get_single($name)`, which
  gives `undef` for a repeated field, so your fallback applies.
- Check `$scope->{type}` first, as here: `PAGI::HTTPConnection->new` takes
  an `http`, `websocket` or `sse` scope and dies on `lifespan`, which
  application-wide middleware also sees.
- Middleware that reads the body still builds a `PAGI::Request` and hands
  the application a receive that delivers it (see "Reading the request body"
  in `PAGI::Middleware`).
