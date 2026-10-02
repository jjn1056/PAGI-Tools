# Upgrading PAGI-Tools

This release breaks most of the 0.002002 API on purpose: routing, the
Context handler objects, the Response builder and the stock applications
are replaced. There are no compatibility aliases; every removed form fails
when used. Upgrade PAGI::Server to **0.002014** or later at the same time.

Start with the table, then the worked port. Each row links to the details
in [UPGRADING-REFERENCE.md](UPGRADING-REFERENCE.md).

## What replaces what

| 0.002002 | Now |
|---|---|
| `PAGI::App::Router` (`get`, `group`, `as`, `uri_for`, `not_found`) | `PAGI::Routing`: `router`, `route`, `mount`, `path_for`, `http_default` ([details](UPGRADING-REFERENCE.md#migrate-app-router-declarations)) |
| `PAGI::Endpoint::Router` (`routes($self, $r)`, string targets, `$self->state`) | a class whose `routing` returns a Router; lifespan state ([details](UPGRADING-REFERENCE.md#migrate-endpoint-router-classes)) |
| Handlers receive a Context (`$ctx`) | handlers receive the `PAGI::Request`, `PAGI::WebSocket` or `PAGI::SSE` ([details](UPGRADING-REFERENCE.md#breaking-replace-the-pagi-context-family-with-the-protocol-owner)) |
| `$ctx->json`/`text`/`html`/`redirect`, `$request->response`, the mutable Response builder | return `response('JSON', ...)`, `response('Text', ...)`, ... ([details](UPGRADING-REFERENCE.md#breaking-choose-a-concrete-response-class)) |
| `$ctx->stash`, `session`, `state`, `csrf_verify`, `on_drain` | `stash($request)`, `session($request)`, `app_state($request)`, `csrf($request)`, `transport($request)` ([details](UPGRADING-REFERENCE.md#import-optional-capabilities-from-their-owners)) |
| App::Router handlers as native `($scope, $receive, $send)` apps | Route CODE gets one Request; wrap natives with `as_app_object` ([details](UPGRADING-REFERENCE.md#migrate-app-router-declarations)) |
| `PAGI::App::NotFound`, `PAGI::App::Redirect` | `PAGI::Pages` `not_found`, `redirect` ([details](UPGRADING-REFERENCE.md#pages-replaces-the-stock-response-applications)) |
| ErrorHandler `content_type`; errors swallowed after start | a `handler` that returns a Response; 5xx re-raised to the server ([details](UPGRADING-REFERENCE.md#breaking-errorhandler-re-raises-server-errors)) |
| Session `secret`, `cookie_name`, `cookie_options`; `State::Bearer` | `state => session_state('Cookie', ...)`; no secret ([details](UPGRADING-REFERENCE.md#breaking-the-session-cookie-is-configured-on-statecookie-not-on-the-middleware)) |
| `Auth::Basic`, `Auth::Bearer` | `Authentication` with a backend, plus `requires` ([details](UPGRADING-REFERENCE.md#breaking-authbasic-and-authbearer-are-replaced-by-authentication)) |
| `FormBody`, `JSONBody` middleware | `$request->form_params`, `$request->json` ([details](UPGRADING-REFERENCE.md#breaking-pagimiddlewareformbody-and-pagimiddlewarejsonbody-are-removed)) |
| `PAGI::App::Loader` | `pagi-server --app`, or `do $file` ([details](UPGRADING-REFERENCE.md#breaking-pagiapploader-is-removed)) |
| WebSocket/SSE `->state` hashref | a `PAGI::State` object ([details](UPGRADING-REFERENCE.md#breaking-direct-websocket-and-sse-state-matches-request)) |
| WebSocket `on_close` `($code, $reason)`; SSE `on_close` `($sse, $reason)` | a third argument, `$detail`; a strict signature must accept it ([details](UPGRADING-REFERENCE.md#breaking-on_close-callbacks-receive-a-third-argument)) |
| `$ws->deny(status => ..., body => ...)` | `$ws->deny($response)`; new `$sse->decline($response)` ([details](UPGRADING-REFERENCE.md#refuse-websocketsse-with-request-handlers-or-applications)) |
| Builder `enable '^My::Middleware'` | `enable '+My::Middleware'` ([details](UPGRADING-REFERENCE.md#breaking-use-explicit-middleware-descriptions-at-core-boundaries)) |
| Directory `show_hidden` | `allow_hidden` ([details](UPGRADING-REFERENCE.md#rooted-file-serving-security-contract)) |
| `WebSocket::RateLimit`, `SSE::Pubsub`, `WebSocket::Broadcast`/`Chat` | removed; Cookbook recipes ([details](UPGRADING-REFERENCE.md#other-breaking-changes)) |

Behaviour that changes without a code change: stock error pages negotiate
HTML, problem JSON or text ([details](UPGRADING-REFERENCE.md#audit-changed-first-party-defaults));
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
        middleware('ErrorHandler', handler => sub ($request, $error) {
            return response('Problem', { title => 'Internal Server Error', status => 500 });
        }),
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
  `middleware(...)` description on a `mount`, or `PAGI::Auth`'s `requires`.
- `$self->state` became lifespan state: set in Compose's `startup`, read
  with `app_state($request)`.
- `$ctx->session` became `session($request)`; Session no longer takes
  `secret`.
- ErrorHandler's `content_type` became a `handler` returning a Response.
- `:id` became `{id}`, and `post` became `methods => ['POST']`.
