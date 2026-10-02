# Upgrading PAGI-Tools: reference

The details behind [UPGRADING.md](UPGRADING.md), which has the summary table
and a worked port; start there. This reference is for applications written
against **PAGI-Tools 0.002002**, the previous CPAN release. Every "Before" below is code that release accepted.
There is no compatibility mode and there are no compatibility aliases: each
removed form fails rather than being translated.

`PAGI::Compose`, `PAGI::Routing`, `PAGI::Pages`, the concrete `PAGI::Response`
classes, `PAGI::Auth` and `PAGI::Middleware::Authentication` are new in this
release. Their POD documents them; this guide covers what changes for code
that already exists. Upgrade PAGI::Server to 0.002014 or later at the same
time (see [pagi.connection](#breaking-pagisse-and-pagiwebsocket-require-pagiconnection)).

## Checklist

**Removed** (each fails when used):

- `PAGI::App::Router` and `PAGI::Endpoint::Router` -- use `PAGI::Routing`
  ([Router frontend removal](#breaking-remove-the-mutable-router-frontends)).
- The `PAGI::Context` family -- handlers receive the protocol object
  ([Context](#breaking-replace-the-pagi-context-family-with-the-protocol-owner)).
- The mutable `PAGI::Response` builder and `$request->response`
  ([Response](#breaking-choose-a-concrete-response-class)).
- `PAGI::App::NotFound`, `PAGI::App::Redirect` -- use `PAGI::Pages`
  ([Pages](#pages-replaces-the-stock-response-applications)).
- `PAGI::App::Loader` ([Loader](#breaking-pagiapploader-is-removed)).
- `PAGI::Middleware::FormBody`, `JSONBody`
  ([body middleware](#breaking-pagimiddlewareformbody-and-pagimiddlewarejsonbody-are-removed)).
- `PAGI::Middleware::Auth::Basic`, `Auth::Bearer`
  ([Authentication](#breaking-authbasic-and-authbearer-are-replaced-by-authentication)).
- `PAGI::Middleware::Session::State::Bearer`, and Session's `secret`,
  `cookie_name` and `cookie_options` ([Sessions](#breaking-the-session-cookie-is-configured-on-statecookie-not-on-the-middleware)).
- `PAGI::Middleware::WebSocket::RateLimit`, `PAGI::App::SSE::Pubsub`,
  `PAGI::App::WebSocket::Broadcast`, `PAGI::App::WebSocket::Chat`
  ([other removals](#other-breaking-changes)).

**Changed behaviour:**

- ErrorHandler re-raises server errors, renders through Pages, and loses
  `content_type` ([ErrorHandler](#breaking-errorhandler-re-raises-server-errors)).
- Stock error and redirect responses negotiate HTML, problem JSON or text
  ([changed defaults](#audit-changed-first-party-defaults)).
- WebSocket and SSE `state` is a `PAGI::State` object, and the helpers need
  `pagi.connection` ([state](#breaking-direct-websocket-and-sse-state-matches-request)).
- Bad request bodies are 400/413; a body cut short by a disconnect croaks
  ([bodies](#bad-request-bodies-answer-400-or-413-not-500)).
- `raw_path` is the full requested path; AccessLog, HTTPSRedirect, WrapPSGI
  and App::Proxy change with it ([raw_path](#raw_path-request_uri-raw_path_info-and-serving-under-a-prefix)).
- File serving shares one strict request-path contract
  ([file serving](#rooted-file-serving-security-contract)).
- Middleware Builder's exact-package prefix is `+`, not `^`
  ([Builder](#breaking-use-explicit-middleware-descriptions-at-core-boundaries)).

**Tests:** the test kit now behaves like PAGI::Server, so tests that passed
against its old leniency may fail ([test kit](#running-against-pagi-server-0002007)).

## Breaking: remove the mutable Router frontends

PAGI-Tools now has one routing-construction API: `PAGI::Routing`.
`PAGI::App::Router` and `PAGI::Endpoint::Router` have been removed. There is
no compatibility layer and there are no forwarding classes or aliases. This
Router frontend removal is the largest change in the release.

The responsibility model is:

```text
Endpoint::HTTP/WebSocket/SSE  optional behavior for one exact route
Route                         exact path and HTTP method policy
Mount                         prefix ownership and app composition
Router                        ordered children and NONE/PARTIAL outcomes
Compose                       root lifespan, middleware, and safety
```

### Migrate App Router declarations

**Before: `PAGI::App::Router` (0.002002).**

```perl
use PAGI::App::Router;

my $api = PAGI::App::Router->new;
$api->get('/users/{id:\d+}' => $show_user)->name('show');

my $router = PAGI::App::Router->new(not_found => $not_found_app);
$router->get('/' => [$audit] => $home)->name('home');
$router->post('/users' => $create_user)->name('create');
$router->websocket('/chat/:room' => $chat)->name('chat');
$router->sse('/events' => $events)->name('events');
$router->group('/admin' => [$require_admin] => sub {
    my ($r) = @_;
    $r->get('/stats' => $stats);
});
$router->mount('/api' => $api)->as('api');

my $url = $router->uri_for('api.show', { id => 42 });
my $app = $router->to_app;
```

**After: one immutable `PAGI::Routing` tree.**

```perl
use PAGI::Routing qw(middleware mount route router sse websocket);

my $api = router(routes => [
    route('/users/{id}' => \&show_user,
        name        => 'show',
        constraints => { id => qr/\A\d+\z/ },
    ),
]);

my $routing = router(
    http_default => $not_found_app,
    routes => [
        route('/' => \&home,
            name       => 'home',
            middleware => [middleware($audit)],
        ),
        route('/users' => \&create_user, methods => ['POST'], name => 'create'),
        websocket('/chat/{room}' => \&chat, name => 'chat'),
        sse('/events' => \&events, name => 'events'),
        mount('/admin',
            routes     => [route('/stats' => \&stats)],
            middleware => [middleware($require_admin)],
        ),
        mount('/api', app => $api, name => 'api'),
    ],
);

my $path = $routing->path_for('/api/show', { id => 42 });
my $app  = $routing->to_app;
```

What moves where:

- **Handlers.** App::Router called every handler as a native PAGI
  application, `($scope, $receive, $send)`. A Route's CODE is now a handler
  that receives one `PAGI::Request` and returns a response; a `websocket`
  CODE receives a `PAGI::WebSocket`, an `sse` CODE a `PAGI::SSE`. To keep a
  native handler unchanged, wrap it: `route('/x' => as_app_object($native))`
  (`PAGI::Utils`). A Mount `app` CODE is still native.
- **Verb methods** (`get`, `post`, `any`, ...) become a Route `methods`
  option; omitted means GET plus automatic HEAD; `any` is `methods => '*'`.
- **Placeholders** `:id` and `{id:\d+}` become `{id}`, with `constraints`.
- **Route middleware** `[$mw] =>` becomes `middleware => [middleware($mw)]`.
  The same middleware objects (`wrap`) and coderef factories work.
- **`group`** flattened routes into the parent. A `mount` with `routes` is a
  real child Router instead: its prefix moves from `path` to `root_path`.
- **`not_found`** (every scope type) becomes `http_default` (HTTP only); the
  Router answers WebSocket and SSE misses itself.
- **`mount('/x' => 'My::Package')`** package strings are gone: load the
  package and pass an object or coderef as `app`.
- **`->as('api')` and `uri_for('api.show')`** become `name => 'api'` on the
  Mount and `path_for('/api/show')` (or `path_for`/`url_for` from
  `PAGI::Routing::URL` inside a handler).

Deploy the Router with `to_app`, or put it in `compose(routes => [...])` when
you want Compose's lifespan, error handling and response guard.

### Migrate Endpoint Router classes

**Before: `PAGI::Endpoint::Router` (0.002002), string method targets and
Context callbacks.**

```perl
package MyApp::API;
use parent 'PAGI::Endpoint::Router';
use Future::AsyncAwait;

sub routes {
    my ($self, $r) = @_;
    $self->state->{db} = MyApp::DB->connect;
    $r->get('/people' => 'list_people')->name('index');
    $r->get('/people/:id' => ['require_auth'] => 'show_person')->name('show');
    $r->websocket('/chat' => 'chat');
    $r->mount('/child' => MyApp::Child->to_app);
}

async sub require_auth {
    my ($self, $ctx, $next) = @_;
    $ctx->stash->set(user => verify_token($ctx->header('Authorization')));
    return await $next->();
}

async sub show_person {
    my ($self, $ctx) = @_;
    return $ctx->json({ id => $ctx->request->path_param('id') });
}
```

**After: an ordinary object returns an immutable Router from `routing`.**

```perl
package MyApp::API;
use strict;
use warnings;
use Future::AsyncAwait;
use PAGI::Request;
use PAGI::Response qw(json_response);
use PAGI::Routing qw(middleware mount route router websocket);
use PAGI::Stash qw(stash);
use PAGI::Utils qw(as_app_object);

sub new {
    my ($class, %args) = @_;
    return bless {%args}, $class;
}

sub routing {
    my ($self) = @_;
    return router(routes => [
        route('/people' => sub { $self->list_people(@_) }, name => 'index'),
        route('/people/{id}' => sub { $self->show_person(@_) },
            name       => 'show',
            middleware => [middleware(sub {
                my ($inner) = @_;
                return $self->require_auth($inner);
            })],
        ),
        websocket('/chat' => sub { $self->chat(@_) }),
        route('/legacy' => as_app_object($self->{legacy_app})),
        mount('/child', app => $self->{child}->routing),
    ]);
}

sub require_auth {
    my ($self, $inner) = @_;
    return async sub {
        my ($scope, $receive, $send) = @_;
        my $request = PAGI::Request->new($scope, $receive);
        stash($request)->set(user => verify_token($request->header('Authorization')));
        return await $inner->($scope, $receive, $send);
    };
}

async sub show_person {
    my ($self, $request) = @_;
    return json_response({ id => $request->path_param('id') });
}
```

What moves where:

- **String method targets** (`'show_person'`) become closures over `$self`.
- **Middleware methods** `($self, $ctx, $next)` become middleware factories:
  given the inner application, return a native one that calls it.
- **Handlers** receive the protocol object (`PAGI::Request`,
  `PAGI::WebSocket`, `PAGI::SSE`) instead of a Context, and return a
  response value (see [Context](#breaking-replace-the-pagi-context-family-with-the-protocol-owner)).
- **`$self->state`** worker state moves to lifespan state: initialize it in
  Compose's (or `PAGI::Lifespan`'s) `startup` and read it with
  `PAGI::State`'s `app_state($request)`.
- **`MyApp->to_app`** class deployment becomes
  `MyApp->new(...)->routing->to_app`, or a Mount of `->routing`.

For one resource with meaningful HTTP verb dispatch, use an exact leaf class
rather than rebuilding a Router frontend:

```perl
package MyApp::PeopleRepository;

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

sub find {
    my ($self, $id) = @_;
    return $self->{people}{$id};
}

package MyApp::Person;
use parent 'PAGI::Endpoint::HTTP';
use PAGI::Response qw(json_response);

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

sub get {
    my ($self, $request) = @_;
    return json_response(
        $self->{repo}->find($request->path_param('id')),
    );
}

package MyApp::Routes;
use PAGI::Routing qw(route);

my $repo = MyApp::PeopleRepository->new(
    people => { 42 => { id => 42, name => 'Ada' } },
);

my $person_route = route('/people/{id}' => MyApp::Person->new(repo => $repo),
    name => 'show',
);
```

Simple behavior stays a closure. Endpoint classes are best when HTTP verb
dispatch, WebSocket/SSE connection lifecycle, or a long-lived configured
dependency earns the class. They own one exact leaf, never a subtree.

### Configured WebSocket and SSE endpoint lifecycle

Configured protocol endpoint instances now work as leaf applications:

```perl
websocket('/chat' => MyApp::Chat->new(hub => $hub));
sse('/events' => MyApp::Events->new(bus => $bus));
```

Calling `to_app` on a class constructs one receiver immediately. Calling it
on an instance retains that same object. No receiver is reconstructed for each
connection. The configured WebSocket and SSE instance may serve concurrent
connections, so store configuration and long-lived services on it and keep
connection-local state on each `PAGI::WebSocket` or `PAGI::SSE` object.

### HTTP endpoint method capability

An object endpoint that implements `allowed_methods` publishes its method
capability to its containing Route. Route consults `allowed_methods` exactly
once during construction whether methods are omitted or explicitly finite,
and snapshots the normalized result. GET adds HEAD, and
`PAGI::Endpoint::HTTP` also advertises OPTIONS.

A finite method string or arrayref must be a restriction of that capability:

```perl
route('/messages' => $endpoint, methods => 'GET');
route('/messages' => $endpoint, methods => ['GET', 'POST']);
```

Construction fails if a finite declaration includes a method the endpoint does
not advertise. The Router owns method mismatch, the first-seen `Allow` union,
and OPTIONS dispatch at that Route boundary. A mounted or standalone endpoint
still owns its own 405 and OPTIONS behavior.

Only scalar `methods => '*'` bypasses the capability:

```perl
route('/delegated' => $endpoint, methods => '*');
```

This skips the capability lookup and lets the endpoint own every method and
405 outcome. WebSocket and SSE routes never inspect `allowed_methods`.

### What was removed without replacement

- App::Router's mutable verb methods, `any`, `group`, `as`, `uri_for`, the
  all-scope `not_found`, and package-name mount targets;
- Endpoint::Router's `routes($self, $r)` callback, string method targets,
  middleware methods, `context_class`, and its `state` hashref.

Use constructor options, route arrays, closures, immutable Router values,
`path_for`/`url_for`, and lifespan state instead. Higher-level frameworks can
add conventions without adding a second core routing model.

## Routing composition redesign

The pieces a 0.002002 application assembled by hand are now separate
values: a Route matches one complete path, a Mount composes an application
under a prefix (moving it from `path` to `root_path`), a Router selects among
its children and owns HTTP 404 (`http_default`) and 405, middleware wraps
behavior, and Compose owns the application root, its lifespan, ErrorHandler
and response guard. See `PAGI::Routing` and `PAGI::Compose`.

Two existing components change with it:

- **`PAGI::App::Cascade`** advances past a child only when that child's
  response status is in `catch` (for example `catch => [404, 405]`). A child
  that sends nothing is an incomplete-application error, not a miss.
  Responses not caught stream as they arrive.
- **`PAGI::App::URLMap`** is unchanged: its mounts are opaque applications.
  Use `mount('/api', app => $router)` when reverse URLs into the child
  matter.

## Breaking: replace the `PAGI` Context family with the protocol owner

The Context classes are removed without a compatibility layer. Handlers
receive the object that owns their protocol: `PAGI::Request` for HTTP,
`PAGI::WebSocket`, `PAGI::SSE`. Raw applications and middleware keep the
native `($scope, $receive, $send)` contract unchanged.

### Change class Endpoint callback signatures

**Before:** Endpoint callbacks received a Context wrapper.

```perl
# PAGI::Endpoint::HTTP
async sub get { my ($self, $ctx) = @_; ... }

# PAGI::Endpoint::WebSocket
async sub on_receive { my ($self, $ctx, $data) = @_; ... }
sub on_disconnect    { my ($self, $ctx, $code, $reason) = @_; ... }

# PAGI::Endpoint::SSE
async sub on_connect { my ($self, $ctx) = @_; ... }
sub on_disconnect    { my ($self, $ctx) = @_; ... }
```

**After:** use `PAGI::Request`, `PAGI::WebSocket`, and `PAGI::SSE` directly.

```perl
use PAGI::Response qw(json_response);

async sub get {
    my ($self, $request) = @_;
    return json_response({ path => $request->path });
}

async sub on_receive {
    my ($self, $websocket, $data) = @_;
    await $websocket->send_json($data);
}
sub on_disconnect { my ($self, $websocket, $code, $reason) = @_; ... }

async sub on_connect {
    my ($self, $sse) = @_;
    await $sse->send_event(data => 'ready');
}
sub on_disconnect { my ($self, $sse) = @_; ... }
```

Endpoint `on_disconnect` hooks remain synchronous. Do not return a Future
from them.

### Build Responses directly

**Before:** `PAGI::Context::HTTP` cached one mutable Response behind
`response`/`resp`, with the shortcuts `text`, `html`, `json` and `redirect`,
and a guarded `respond`.

```perl
return $ctx->text('Created', status => 201);
return $ctx->json($data, status => 201);
return $ctx->redirect('/items');

my $response = $ctx->response;
await $ctx->respond($response);
```

**After:** construct and return one complete Response; in a native
application, delegate with `invoke_app`.

```perl
use PAGI::Response qw(json_response redirect_response text_response);
use PAGI::Utils qw(invoke_app);

return text_response('Created', status => 201);
return json_response($data, status => 201);
return redirect_response('/items');

await invoke_app(json_response($data), $scope, $receive, $send);
```

### The two former `send` meanings

**Before:** Context `send` returned the raw send coderef, except on
`PAGI::Context::SSE`, where `send($data)` emitted a data-only event;
`raw_send` was the raw coderef everywhere.

```perl
my $raw_send = $ctx->send;           # HTTP and WebSocket Context
await $raw_send->($event);
await $ctx->send('Hello world');     # SSE Context
```

**After:** a native application already has `$send`. Handlers use their
protocol object's typed methods; `PAGI::SSE->send($data)` keeps the
data-only meaning.

```perl
await $websocket->send_text('Hello world');
await $sse->send('Hello world');
```

### Import optional capabilities from their owners

**Before:** one object carried stash, session, state, CSRF and flow control.

```perl
my $stash = $ctx->stash;
my $user  = $ctx->session->get('user');
my $db    = $ctx->state->{db};
return $ctx->text('Forbidden', status => 403)
    unless $ctx->csrf_verify($submitted);
$ctx->on_drain(\&resume);
```

**After:** pass the protocol object to the helper that owns the capability.

```perl
use PAGI::CSRF qw(csrf);
use PAGI::Response qw(text_response);
use PAGI::Session qw(session);
use PAGI::Stash qw(stash);
use PAGI::State qw(app_state);
use PAGI::Transport qw(transport);

my $user  = session($request)->get('user');
my $db    = app_state($request)->get('db');
stash($request)->set(result => $result);

return text_response('Forbidden', status => 403)
    unless csrf($request)->verify($submitted);

my $flow = transport($request);
$flow->on_drain(\&resume) if $flow;
```

`app_state` and `transport` return `undef` when their capability is absent.
A `PAGI::State` is an object, not a hashref: use `->data` where a plain
HashRef is required. URL generation (`path_for`, `url_for`) comes from
`PAGI::Routing::URL`.

### Update ErrorHandler callbacks

**Before:** a custom renderer received Context and returned a shortcut.

```perl
handler => sub {
    my ($context, $error) = @_;
    return $context->json({ error => 'request failed' });
}
```

**After:** it receives `($request, $error)` and returns a complete Response;
an explicit status wins over ErrorHandler's fallback.

```perl
use PAGI::Response qw(json_response);

handler => sub {
    my ($request, $error) = @_;
    return json_response({ error => 'request failed' }, status => 503);
}
```

## Breaking: choose a concrete Response class

`PAGI::Response` is now the base of a family of complete, reusable response
values; `ref($response)` names the representation.

| Class | Factory | Memory/delivery |
| --- | --- | --- |
| `PAGI::Response` | `response` | buffers caller-supplied encoded bytes |
| `PAGI::Response::Text` | `text_response` | buffers strict UTF-8 text |
| `PAGI::Response::HTML` | `html_response` | buffers strict UTF-8 HTML |
| `PAGI::Response::JSON` | `json_response` | buffers one serialized finite Perl value |
| `PAGI::Response::Problem` | `problem_response` | buffers validated RFC 9457 JSON |
| `PAGI::Response::Redirect` | `redirect_response` | buffers a small redirect document |
| `PAGI::Response::Empty` | `empty_response` | buffers zero body bytes |
| `PAGI::Response::File` | `file_response` | request-time preflight and a server-owned `file` event |
| `PAGI::Response::Stream` | `stream_response` | fresh producer and sequential Writer per invocation |

`PAGI::Response` exports nothing by default; import the factories you use or
`:all`.

### Complete spelling map

| Before | After |
| --- | --- |
| `$request->response` | construct the desired concrete Response directly |
| `PAGI::Response->new($scope)` as a mutable builder | construct a complete response; pass the Request to Session, Stash, State, CSRF, URL or Transport helpers |
| `PAGI::Response->text($s)` | `text_response($s)` |
| `PAGI::Response->html($s)` | `html_response($s)` |
| `PAGI::Response->json($v)` | `json_response($v)` |
| `PAGI::Response->send($s, charset => $name)` | encode explicitly and pass bytes plus Content-Type to `PAGI::Response->new(...)` |
| `PAGI::Response->send_raw($b)` | `PAGI::Response->new($b)` |
| `PAGI::Response->redirect($uri)` | `redirect_response($uri)` |
| `PAGI::Response->empty(...)` | `empty_response(...)` |
| `PAGI::Response->send_file($p)` with immediate `-f`/`-r` checks | `file_response($p)`; checks happen at request time, so check at startup yourself if you need to |
| `PAGI::Response->stream($cb)` | `stream_response($cb)` |
| `$response->writer($send)` | `stream_response(async sub ($writer) { ... })` |
| `$response->respond($send)` | `invoke_app($response, $scope, $receive, $send)` |
| `is_response($value)` (`PAGI::Utils`) | no replacement; any value with `to_app` is an application |
| `$response->scope` | use the Request/protocol object, or raw `$scope` |
| `$response->is_sent` | `$request->connection->response_started` |
| `$response->cors(...)` | `PAGI::Middleware::CORS`, or `header` for one literal field |
| canonically sorted keys from `PAGI::Response->json(...)` | JSON member order is unspecified; compare decoded values |
| `$ws->deny(status => ..., body => ...)` | `$ws->deny($handler_or_app)` (below) |

### Construct once and return the value

**Before:** a mutable accumulator, finished by a body-mode method.

```perl
my $response = $request->response;
return $response->status(201)->json($item);
```

**After:** choose the class at construction.

```perl
use PAGI::Response qw(json_response);

return json_response(
    $item,
    status  => 201,
    headers => ['Location' => $location],
);
```

Common options are `status`, `content_type` and a flat `headers` arrayref;
unknown or malformed options fail immediately. For a custom charset, make the
bytes explicit:

```perl
use Encode qw(encode);
use PAGI::Response ();

return PAGI::Response->new(
    encode('ISO-8859-1', $text),
    content_type => 'text/plain; charset=iso-8859-1',
);
```

### Native applications use the application protocol

**Before:** a Response held the request scope and was sent with `respond`.

```perl
my $response = PAGI::Response->new($scope)
    ->status(201)
    ->json($data);
await $response->respond($send);
```

**After:** a Response holds no request state; deliver it as an application.

```perl
use PAGI::Response qw(json_response);
use PAGI::Utils qw(invoke_app);

my $response = json_response($data, status => 201);
await invoke_app($response, $scope, $receive, $send);
```

Handlers do not send at all: they return the Response (or any application
value) and the Route delivers it.

### Move CORS policy out of Response

**Before:**

```perl
return text_response('ok')->cors(
    origin      => 'https://app.example',
    credentials => 1,
);
```

**After:** wrap the application with CORS middleware.

```perl
use PAGI::Middleware::Builder;

my $app = builder {
    enable 'CORS',
        origins     => ['https://app.example'],
        credentials => 1;
    $routing;
};
```

### Await Stream writes and treat disconnect as state

```perl
use Future::AsyncAwait;
use PAGI::Response qw(stream_response);

return stream_response(async sub ($writer) {
    await $writer->write("id,name\n");
    for my $row (@rows) {
        await $writer->write($row);  # one outstanding write
    }
});
```

Each write Future is the backpressure boundary: starting another write before
it settles fails. A client disconnect never fails a write; check the
connection's state instead.

### Refuse WebSocket/SSE with Request handlers or applications

```perl
use PAGI::Auth qw(www_authenticate);
use PAGI::Response qw(problem_response);

await $websocket->deny(
    problem_response({ title => 'Unauthorized', status => 401 },
        headers => ['WWW-Authenticate' => www_authenticate('Bearer', realm => 'api')]),
);

await $sse->decline(sub {
    my ($request) = @_;
    return problem_response({
        title => 'Not Found', status => 404, detail => $request->path,
    });
});
```

Both methods take exactly one Request handler or an object with `to_app`
(any Response, a Pages application, your own). A bare coderef receives one
Request and returns an application value. A WebSocket refusal needs a status
of at least 300; SSE accepts any. Call `deny` before accepting and `decline`
before starting the stream. `decline` is new in this release; `deny` took
`status`/`body` options in 0.002002.

## Breaking: direct WebSocket and SSE `state` matches Request

`PAGI::Request`, `PAGI::WebSocket` and `PAGI::SSE` share one application-state
contract: `state` returns a `PAGI::State` or `undef`.

**Before:** WebSocket and SSE returned a raw hashref (or an empty one).

```perl
my $db = $websocket->state->{db};
```

**After:**

```perl
my $state = $websocket->state
    or die 'lifespan state required';
my $db = $state->get('db');
```

A temporary `%{}` overload still allows `->state->{db}` (with a warning), but
`ref($protocol->state) eq 'HASH'` is false: use `->data` for an exact hashref.

## Breaking: `on_close` callbacks receive a third argument

`on_close` now also passes the connection's disconnect detail:

| | 0.002002 | Now |
|---|---|---|
| `PAGI::WebSocket` | `($code, $reason)` | `($code, $reason, $detail)` |
| `PAGI::SSE` | `($sse, $reason)` | `($sse, $reason, $detail)` |

A callback that unpacks `@_` is unaffected. One with a **strict signature**
dies with "Too many arguments", which the helper catches and logs, so its
cleanup silently does not run:

```perl
# Before
$sse->on_close(sub ($sse, $reason) { cleanup() });

# After
$sse->on_close(sub ($sse, $reason, $detail = undef) { cleanup() });
```

## Breaking: `PAGI::SSE` and `PAGI::WebSocket` require `pagi.connection`

PAGI::Spec::Www 0.6 requires a `pagi.connection` object in every `http`,
`websocket` and `sse` scope. PAGI::Server provides it on websocket and sse
scopes from **0.002014**. `PAGI::SSE` and `PAGI::WebSocket` now die without
it, so upgrade PAGI::Server together with this release:

```text
PAGI::WebSocket requires pagi.connection capabilities response_started, ...
(server reports spec_version unspecified; current connection contract required)
```

Tests that build scopes by hand add one:

```perl
use PAGI::Test::ConnectionState;
my $scope = {
    type              => 'websocket',
    headers           => [],
    'pagi.connection' => PAGI::Test::ConnectionState->new(websocket => 1),
};
```

Terminal state now comes from that connection:

- A client disconnect is recorded on the connection before the application
  sees it: `$conn->_mark_disconnected('client_closed')`, or for a WebSocket
  peer Close `$conn->_set_peer_close($code, $reason)` then
  `$conn->_mark_complete`. A `*.disconnect` event alone no longer closes the
  helper.
- A local `close()` starts closing; `on_close` runs when the connection ends.
  SSE `close()` also waits for that end.
- A dying `on_message` or `each`/`every` callback is re-raised after
  `on_error` runs.

`PAGI::Test::Client` builds its own connection and needs no change.

## Breaking: ErrorHandler re-raises server errors

ErrorHandler still renders the error page, but after a **server error**
(status 500 or above) it re-raises the original exception so the server
reports it:

```text
# Before: a bare warn from inside PAGI-Tools
PAGI application error: database unreachable

# After: PAGI::Server's own log, at level error
PAGI application error (after response complete): database unreachable
```

- An exception claiming a 4xx `status_code` is a handled outcome: rendered,
  not re-raised, not logged.
- `on_error` runs before rendering and now receives `($error, $scope)`.
- An exception **after** the response has started is no longer swallowed:
  ErrorHandler awaits `on_error`, sends nothing more, and rethrows, so the
  server aborts the stream. Code that calls a wrapped application directly
  sees its Future fail where it used to succeed.

With `PAGI::Test::Client`'s default `raise_app_exceptions => 0`, a test that
provokes a 500 sees a warning to capture:

```perl
my @warnings;
my $response = do {
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    PAGI::Test::Client->new(app => $app)->get('/boom');
};
is $response->status, 500;
like $warnings[0], qr/^exception after response completed: database unreachable/;
```

### Replace ErrorHandler content_type

`content_type` is removed; the built-in page negotiates HTML, problem JSON or
text. To fix one representation, use `handler`:

```perl
# Before
enable 'ErrorHandler', content_type => 'application/json';

# After
use PAGI::Response qw(problem_response);

enable 'ErrorHandler',
    handler => sub {
        my ($request, $error) = @_;
        return problem_response({ title => 'Internal Server Error', status => 500 });
    };
```

Use `html_response` or `text_response` the same way for the other two.
Without a handler, an exception's `status_code` is kept only for a
registered error status that needs no extra protocol facts; bare 401, 405,
407 and 426, and anything malformed, fall back to 500.

## Pages replaces the stock response applications

`PAGI::Pages` builds the conventional welcome, error and redirect responses.
Its functions take no request: each returns an HTTP application.

### Replace the removed NotFound application

```perl
# Before
PAGI::App::NotFound->new->to_app;

# After
use PAGI::Pages qw(not_found);
my $not_found_app = not_found(detail => 'No such page');
```

It negotiates HTML, RFC 9457 problem JSON or text and sends
`Cache-Control: no-store`. For a literal body use a Response:
`text_response('No such page', status => 404)`.

### Replace the removed Redirect application

```perl
# Before
PAGI::App::Redirect->new(to => '/new', status => 308, preserve_query => 1)->to_app;

# After
use PAGI::Pages qw(redirect);
my $redirect_app = redirect('/new', status => 308, preserve_query => 1);
```

App::Redirect preserved the query by default; Pages defaults
`preserve_query` to `0`. Only 301, 302, 303, 307 and 308 are accepted. For a
literal empty redirect use `redirect_response`.

### Audit changed first-party defaults

These components keep deciding *when* to answer with an error or redirect;
only the stock body moved to Pages, so its body, `Content-Type`,
`Content-Length`, `Vary` and cache fields may change. Tests that asserted a
built-in English body should assert the status and media type instead.

| Component | Stock default now from Pages | Preserved locally |
|---|---|---|
| `PAGI::App::File` | 403, 404, 405, 416 | 405 `Allow: GET, HEAD`; 416 file length |
| `PAGI::App::Directory` | listing 403 plus File's 403, 404, 405, 416 | listing rendering and I/O |
| `PAGI::App::URLMap` | no-default 404 | mount selection |
| `PAGI::App::Proxy` | backend-connect 502 | connection decision |
| `PAGI::App::WrapCGI` | process-start 500 | CGI execution and responses |
| `PAGI::App::Throttle` | default 429 | `retry_after`, rate-limit fields, `on_limit` |
| `PAGI::Middleware::Static` | 403, 404, 416 | pass-through; 416 file length |
| `PAGI::Middleware::CSRF` | enforced 403 | validation, `enforce => 'app'` |
| `PAGI::Middleware::ContentNegotiation` | strict-mode 406 | supported-type detail |
| `PAGI::Middleware::Maintenance` | built-in 503 | `retry_after`; explicit `body`/`content_type` stay literal |
| `PAGI::Middleware::RateLimit` | default 429 | `retry_after`, `X-RateLimit-*` |
| `PAGI::Middleware::ReverseProxy` | forwarded-authority 400 | trust decisions |
| `PAGI::Middleware::TrustedHosts` | bad Host 400 | host policy |
| `PAGI::Middleware::HTTPSRedirect` | invalid-authority 400 and redirect | authority/HSTS policy |
| `PAGI::Middleware::Rewrite` | redirect-mode response | rule selection, code, target |
| `PAGI::Endpoint::HTTP` | automatic 405 | computed `allowed_methods` |

Custom handlers, `on_limit`, application bodies and explicit Responses stay
literal. Two non-HTTP fallbacks that used to send `http.response.*` on
another protocol now croak instead: URLMap with no default, and Throttle
without `on_limit`, on a WebSocket or SSE scope.

ContentNegotiation now uses `PAGI::Request::Negotiate`: an exact `q=0`
exclusion beats a less specific wildcard. Unknown, missing or malformed scope
types are never treated as HTTP.

## Breaking: the Session cookie is configured on `State::Cookie`, not on the middleware

`PAGI::Middleware::Session` no longer takes `cookie_name` or
`cookie_options`; passing either dies with a message naming the new place.
Build a `PAGI::Middleware::Session::State::Cookie` and pass it as `state`.
With no `state` you get a `pagi_session` cookie with `HttpOnly`, `Path=/` and
`SameSite=Lax`.

- The middleware's `expire` is only the server-side idle timeout. It no
  longer sets the cookie's `Max-Age`.
- `State::Cookie` sets no `Max-Age` by default, so the cookie lasts until the
  browser session ends; give the State an `expire` to outlive it.
- `State::Cookie`'s `cookie_options` merge into its defaults: give only what
  you add or change, and a false value turns a default off.

```perl
# Before
enable 'Session',
    secret         => $secret,
    cookie_name    => 'myapp_session',
    cookie_options => { httponly => 1, path => '/', samesite => 'Lax', secure => 1 },
    expire         => 86400;

# After
use PAGI::Middleware::Session qw(session_state);

enable 'Session',
    state  => session_state('Cookie',
        cookie_name    => 'myapp_session',
        cookie_options => { secure => 1 },   # merged into the defaults
        expire         => 86400,             # only if the cookie should outlive the browser session
    ),
    expire => 86400;                         # the server-side idle timeout
```

`session_state(NAME, ...)` and `session_store(NAME, ...)` build State and
Store objects from a short name (`'Cookie'`) or, with a leading `+`, an exact
package of your own. `CLASS->new(...)` works the same.

## Breaking: `PAGI::Middleware::Session` takes no `secret`

It only salted an already random session ID. It is gone, and passing it dies.
Session IDs are 32 random bytes as 64 hex characters, as long as before.

```perl
# Before
enable 'Session', secret => $secret;

# After
enable 'Session';
```

`PAGI::Middleware::Session::Store::Cookie` still needs its own secret,
because it encrypts the cookie with it.

## Breaking: `PAGI::Middleware::Session::State::Bearer` is removed

To identify users from tokens, use `PAGI::Middleware::Authentication`. To keep
reading a session ID from that header, use `State::Header` with a pattern:

```perl
# Before
state => PAGI::Middleware::Session::State::Bearer->new,

# After
state => session_state('Header',
    header_name => 'Authorization',
    pattern     => qr/^Bearer\s+(.+)$/i,
),
```

## Breaking: Auth::Basic and Auth::Bearer are replaced by Authentication

`PAGI::Middleware::Auth::Basic` and `Auth::Bearer` are removed. They answered
401 themselves and left a plain hash in `$scope->{'pagi.auth'}`.
`PAGI::Middleware::Authentication` takes a backend that turns a Request into
a result, and never chooses a response: refusing is application policy.

```perl
# Before
enable 'Auth::Basic',
    realm         => 'Restricted Area',
    authenticator => sub {
        my ($username, $password) = @_;
        return $username eq 'admin' && $password eq 'secret';
    };
# ...and in the app: $scope->{'pagi.auth'}{username}

# After
use PAGI::Auth qw(auth auth_result unauth_result requires);
use PAGI::Auth::SimpleUser;

enable 'Authentication', backend => sub {
    my ($request) = @_;
    my ($username, $password) = $request->basic_auth;
    return unauth_result()
        unless defined $username && check_password($username, $password);
    return auth_result(user => PAGI::Auth::SimpleUser->new(identity => $username));
};

# ...and in a handler: auth($request)->user->identity
# ...or refuse declaratively: route('/admin' => requires([], \&admin))
```

For tokens, read `$request->bearer_token` in the backend and verify it
yourself (Auth::Bearer's JWT decoding is not built in). Answer
unauthenticated requests with `requires`, or in the handler with
`www_authenticate` for a `WWW-Authenticate` challenge. `PAGI::Auth`'s POD and
`examples/auth-notes` show both.

## Breaking: `PAGI::Middleware::FormBody` and `PAGI::Middleware::JSONBody` are removed

Body parsing belongs to `PAGI::Request`. The middleware buffered the body into
`$scope->{'pagi.parsed_body'}` with its own URL-encoded-only parser, where a
repeated key became a scalar or an arrayref.

```perl
# Before
enable 'FormBody';          # or 'JSONBody'
my $data = $scope->{'pagi.parsed_body'};

# After
use PAGI::Request;
my $request = PAGI::Request->new($scope, $receive);
my $form    = await $request->form_params;   # Hash::MultiValue; also multipart
my $data    = await $request->json;
```

## Bad request bodies answer 400 (or 413), not 500

`$request->json`, `text`/`form_params` with `strict`, and multipart parsing
used to die with plain strings, which became 500s. They now throw a
`PAGI::Request::BodyError` with a `status_code`: 400 for a body that cannot be
read, 413 for a multipart part over a limit. A Compose application answers
with that status automatically. The error still stringifies to the same
message; code that checked `ref $@` sees an object now. See `PAGI::Request`
(BAD REQUEST BODIES).

A body cut short by a client disconnect now croaks
`Request body incomplete: client disconnected mid-body ($reason)` instead of
returning what had arrived. A disconnect before any body arrives is still an
empty body.

## raw_path, request_uri, raw_path_info, and serving under a prefix

`raw_path` is the full path the client requested, percent-encoded, at every
mount level (`PAGI::Spec::Www`, "Paths, Mounts and Root Paths").

- **Breaking (hand-built scopes only):** without a `raw_path` in the scope,
  `->raw_path` on Request, WebSocket and SSE is now `root_path` and `path`
  percent-encoded, not the decoded path below the mount.
- **New:** `request_uri` (the path and query requested, encoded, safe for a
  Location header or a log line) and `raw_path_info` (the encoded path below
  the mount) on Request, WebSocket and SSE.
- **New:** `PAGI::Test::Client->new(..., root_path => '/app')` serves an app
  as a server with that root path does behind a stripping proxy; requests
  take the browser's URL.
- **AccessLog** logs `request_uri`: percent-encoded and with the mount prefix,
  where it logged the decoded path. Log parsers that expected decoded paths
  see encoded ones; a client can no longer forge a line with `%0D%0A`.
- **HTTPSRedirect** redirects to `https://` + host + `request_uri`. Before:

  ```
  GET /search%3Fsort%3Ddate%23results?q=1  ->  https://host/search?sort=date&q=1#results
  GET /wide%E2%98%BA                       ->  failed (Redirect location must be a URI-reference)
  GET /secure/a inside mount('/secure')    ->  https://host/a
  ```

  After:

  ```
  -> https://host/search%3Fsort%3Ddate%23results?q=1
  -> https://host/wide%E2%98%BA
  -> https://host/secure/a
  ```
- **WrapPSGI** sets `REQUEST_URI` and passes `SCRIPT_NAME`/`PATH_INFO` as
  bytes, as PSGI requires; `Plack::Request->uri` now works on non-Latin-1
  paths.
- **App::Proxy** forwards the encoded path below its mount; a client's
  `%0D%0A` can no longer inject a header into the backend request.

## Rooted file-serving security contract

File components share one lexical request-path contract.

### Replace manual request-path deletion

**Before (unsafe; do not copy):**

```perl
my $path = $scope->{path};
$path =~ s/\.\.//g;
my $file = "$root/$path";
open my $fh, '<:raw', $file or die $!;
```

**After:** let one `PAGI::App::File` own static files: validation, index and
MIME selection, conditional and Range requests, streaming and errors.

```perl
use PAGI::App::File;

my $app = PAGI::App::File->new(root => 'public')->to_app;
```

For a custom handler (authorization, headers), resolve the request path with
`path_from_root` (new in `PAGI::Utils`) before touching the filesystem:

```perl
use PAGI::Utils qw(path_from_root);

my $path = path_from_root('/var/www/files', $scope->{path});
# undef: refuse with 403. Otherwise check -f/-r and send a `file` event.
```

`path_from_root` does no I/O and does not resolve symlinks; a configured
symlink extends the root, so keep the root on a filesystem attackers cannot
modify.

### Rename the hidden-file policy

```perl
# Before
PAGI::App::Directory->new(root => $root, show_hidden => 1);

# After
PAGI::App::Directory->new(root => $root, allow_hidden => 1);
```

`allow_hidden` now governs serving as well as listings; by default hidden
components are forbidden and hidden index files skipped.

### Audit range, listing, status and mapping assumptions

- **Ranges.** File and Static accept exactly one `bytes=start-end` (open-ended
  and suffix forms included); empty, repeated, malformed, reversed and
  multi-range values get 416 with `Content-Range: bytes */N`.
- **Listings.** Directory links are absolute (`root_path` plus `path`), and
  names that cannot round-trip through a request path are omitted.

| Before | After |
|---|---|
| File NUL request -> 400 | unsafe-path 403 |
| outward symlink rejected | configured symlink served |
| Directory missing -> 403 | 404 |
| Directory POST listing -> 200 | 405, `Allow: GET, HEAD` |
| Static hidden files allowed | hidden files forbidden by default |
| textual/hash-order XSendfile mapping | longest component-aware mapping |
| unmatched XSendfile hash emits the raw proxy path | the original `file` event continues |

See `PAGI::App::File`, `PAGI::App::Directory`, `PAGI::Middleware::Static`
and `PAGI::Middleware::XSendfile`.

## Breaking: `PAGI::App::Loader` is removed

Pass the file to the server (`pagi-server --app ./app.pl`), or load it with
`do` and an explicit path:

```perl
# Before
my $app = PAGI::App::Loader->new(file => 'app.pl')->to_app;

# After
my $file = './app.pl';
my $app  = do $file;
die "Cannot load $file: $@" if $@;
die "Cannot read $file: $!\n" unless defined $app;
```

`reload` has no equivalent; restart the server to pick up changes.

## Breaking: use explicit middleware descriptions at core boundaries

`PAGI::Middleware::Builder` keeps its own concise API and its runtime behavior
is unchanged, except that its exact-package prefix is now `+` (Plack's
convention) instead of `^`:

```perl
# Before
enable '^MyApp::Middleware::Auth';

# After
enable '+MyApp::Middleware::Auth';
```

The new core values (Route, Mount, Router, Compose) take middleware only as
`middleware(...)` descriptions: `middleware('RequestId')`,
`middleware('+MyApp::Middleware::Auth')`, `middleware(\&factory)`,
`middleware($object)`. See `PAGI::Routing`.

## Other breaking changes

- **Removed middleware and apps**, with no replacement in this release:
  `PAGI::Middleware::WebSocket::RateLimit`, `PAGI::App::SSE::Pubsub`,
  `PAGI::App::WebSocket::Broadcast`, `PAGI::App::WebSocket::Chat`. They held
  and called another scope's `send`, which the spec rules out. The Cookbook's
  "In-Loop WebSocket Rate Limiting" and "Real-Time Fan-Out (Pub/Sub)" recipes
  show the replacements; cross-process fan-out is PAGI-Channels.
- **`PAGI::App::WebSocket::Echo`'s `on_disconnect`** receives
  `($scope, $code, $reason)` instead of `($scope, $code)`.
- **`PAGI::Middleware::Lint`** delegates to the shared send validator; in
  strict mode a violation rejects the event instead of warning.

## Running against PAGI-Server 0.002007

The test kit (`PAGI::Test::Client` and its companions) now behaves like a real
server where it used to be looser. Tests that passed against that leniency
may fail -- correctly.

- **Sends are validated.** An illegal event (a duplicate
  `http.response.start`, a body before start, undeclared trailers, a lifespan
  result for the wrong phase) fails the returned Future, as on a server. An
  app that returns without a legal terminal state is reported as a
  `server_error` disconnect with a warning; one that never starts a response
  gets the server's 500, not an empty 200.

  ```perl
  await $send->({ type => 'http.response.start', status => 200, headers => [] });
  await $send->({ type => 'http.response.start', status => 200, headers => [] }); # now fails
  ```
- **An exception after a complete response** returns the real response
  (`on_complete` fires) instead of replacing it with a 500.
- **`disconnect_future`** on `PAGI::Test::ConnectionState` resolves on an
  abnormal disconnect and stays pending after a clean completion; it used to
  be `undef`. Request it before the response completes:

  ```perl
  my $connection = $req->connection;
  if ($connection && $connection->is_connected) {
      await Future->wait_any($connection->disconnect_future, $work);
  }
  ```
- **WebSocket and SSE ends.** `Test::WebSocket` and `Test::SSE` keep the
  terminal `*.disconnect` event for later receives. A send after the app's own
  `websocket.close` fails; after the peer closed, it is dropped. Refusals are
  ordinary `http.response.*` (status 300+ for WebSocket); `websocket.close`
  before accept is rejected.
- **HTTP responses** are HTTP/1.1-shaped: app-supplied `Transfer-Encoding`
  and `Connection` headers are stripped with a warning, and every scope
  advertises `extensions`.
- **Lifespan state** is shallow-copied into each scope, as the spec requires:
  a counter kept in a top-level state key no longer leaks between requests.
  Share through a value stored at startup (a hash or object).
- **Paths.** Scopes carry `raw_path` and a decoded `path`, and
  `root_path => '/app'` serves an app under a prefix (see
  [raw_path](#raw_path-request_uri-raw_path_info-and-serving-under-a-prefix)).

## Appendix: notes for framework authors

The native application and middleware contract is unchanged:
`($scope, $receive, $send)`. What changes is at the handler and value
boundaries:

- HTTP handlers receive `PAGI::Request` and return an immediate or
  Future-backed application value, commonly a concrete `PAGI::Response`.
  PAGI-Tools does not infer a response type from an ordinary Perl return
  value; a framework that accepts those serializes them into a Response.
- Route endpoints and `http_default` CODE receive one Request; Mount `app`
  CODE is native. Use `as_app_object` for a native coderef where a handler is
  expected, and `request_response($handler)` to adapt a handler into Mount
  `app`. Coderef arity is never inspected, and package-name strings are not
  applications.
- Deliver any application value with `invoke_app($value, $scope, $receive,
  $send)`; it preserves the triplet and adds no policy. There is no
  `respond` method and no `is_response` predicate.
- Use `ref($response)`/`isa` for representation policy and `is_buffered` for
  memory strategy.
- The Context extension points are gone: `context_class`, `_type_map`,
  protocol assertions, and the generic `on`/`on_default`/`on_error`/`run`
  dispatcher. A custom protocol supplies its own object over the native
  triplet:

  ```perl
  my $app = async sub {
      my ($scope, $receive, $send) = @_;
      return await MyApp::Protocol->new($scope, $receive, $send)->run;
  };
  ```
- A framework may keep its own router and URL builder; PAGI-Tools' URL
  helpers read `pagi.routing` frames, which a higher layer need not
  manufacture.
- `PAGI::Test::Response` is a captured-wire decoder for tests, not a
  production Response.
