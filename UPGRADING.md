# Upgrading PAGI-Tools

This guide is the standalone handoff for existing applications moving to the
current PAGI::Tools release. It covers both the shipped routing-fallback and
application-error boundary and the earlier unification of the
`PAGI::App::Router` and `PAGI::Endpoint::Router` frontends. Contracts shown in
Before examples have been removed. There is no compatibility mode and there
are no compatibility aliases.

Each After example uses behavior shipped by the current release. Examples use
ordinary synchronous subs where asynchronous work is not relevant; handlers
may still return a `Future` when their protocol operation is asynchronous.

## Routing fallbacks and application error handling

### Replace Router callbacks with ordinary middleware

Routers now discover routes; they do not own an application's 404 or 405
representation. An exhausted HTTP search records request-local routing facts
and completes normally without starting a response.

**Before (removed):** Router construction accepted response callbacks.

```perl
my $routing = router(
    routes                 => \@routes,
    not_found              => \&not_found,
    method_not_allowed     => \&method_not_allowed,
);
```

**After (shipped):** install the same policy as application middleware.

```perl
use PAGI::Compose qw(compose);
use PAGI::Routing qw(router middleware);

my $routing = router(routes => \@routes);

my $app = compose(
    app => $routing,
    middleware => [
        middleware('Routing::NotFound',
            handler => \&not_found),
        middleware('Routing::MethodNotAllowed',
            handler => \&method_not_allowed),
    ],
)->to_app;
```

Those removed names are rejected as unknown Router options. They are not
ignored, warned about, or retained as aliases. The removal applies equally to
the immutable, App, and Endpoint Router frontends.

Use Router middleware when the policy belongs to one reusable subsystem
instead of the whole application:

```perl
my $api = router(
    routes => \@api_routes,
    middleware => [
        middleware('Routing::NotFound',
            handler => \&api_not_found),
        middleware('Routing::MethodNotAllowed',
            handler => \&api_method_not_allowed),
    ],
);
```

Both handlers receive `($context, $snapshot)` and may return an immediate or
Future-backed Response. The Context status is seeded to 404 or 405. The
MethodNotAllowed handler reads `allowed_methods` from the snapshot; `Allow` is
not seeded into mutable Context state. If that handler returns status 405, the
middleware replaces every conflicting `Allow` field with exactly one
authoritative, first-seen method union. GET contributes HEAD. Returning a
different status, such as a deliberate 404, suppresses that computed field.

### Treat a Router as a nonterminal component

**Before (removed deployment assumption):** a compiled Router's generated
fallback made it look like a complete server application.

```perl
my $app = $routing->to_app;
```

**After (shipped):** direct compilation remains the lower-level component
boundary, while Compose supplies a complete public HTTP application.

```perl
# Low-level routing component: a miss sends no response events.
my $routing_app = $routing->to_app;

# Complete deployed application: mandatory 404, 405, and 500 failsafes.
my $app = compose(app => $routing)->to_app;
```

Deploying the naked component can produce an empty reply, hang, or
server-specific protocol failure when no enclosing fallback responds. Use it
only when an explicit outer composition supplies the missing application
policy.

For every HTTP target, Compose installs this exact outer-to-inner graph:

```text
HEAD wire boundary
  fresh routing Trace
    Compose ErrorHandler failsafe
      response-completion guard
        Compose Routing::NotFound failsafe
          Compose Routing::MethodNotAllowed failsafe
            author Compose middleware, in listed order
              target Router or application
```

These automatic layers are mandatory and deliberately plain. Compose has no
`not_found`, `method_not_allowed`, `server_error`, disable, or replacement-
detection options. Author middleware never suppresses them; an inner author
response simply makes every outer failsafe inert. Install official policy
inside request IDs, access logging, and security-header middleware so those
wrappers observe and decorate application 404/405/500 responses:

```perl
middleware => [
    'RequestId',
    'AccessLog',
    'SecurityHeaders',
    middleware('ErrorHandler',
        handler  => \&site_server_error,
        on_error => \&report_error),
    middleware('Routing::NotFound',
        handler => \&site_not_found),
    middleware('Routing::MethodNotAllowed',
        handler => \&site_method_not_allowed),
]
```

The automatic emergency bodies sit outside the author stack and therefore do
not travel inward through it. Their production text is safe and generic.

### Choose routing-aware or opaque Mount ownership explicitly

Once any Mount prefix wins, that occurrence owns the request; the parent never
resumes later route scanning. The difference is whether the boundary can carry
trusted routing evidence outward.

**Before (now incomplete):** compiling a Router before mounting it selected an
opaque application that happened to provide its own generated fallback.

```perl
mount('/legacy' => $legacy_router->to_app)
```

**After (shipped, routing-aware):** retain the Router object. A child decline
can reach child Router middleware, this Mount occurrence, enclosing Routers,
and Compose in that order.

```perl
mount(
    '/legacy',
    router => $legacy_router,
    name   => 'legacy',
)
```

Occurrence-specific policy belongs directly on the Mount:

```perl
mount(
    '/legacy',
    router     => $legacy_router,
    name       => 'legacy',
    middleware => [
        middleware('Routing::NotFound',
            handler => \&legacy_not_found),
    ],
)
```

**After (shipped, intentionally opaque):** give the child its own complete
application boundary before passing the native app.

```perl
mount('/legacy' => compose(app => $legacy_router)->to_app)
```

An opaque Mount shields its parent's routing Trace. A naked compiled Router
behind it can decline only into its private child trace, so an outer Compose
cannot reinterpret that silence as 404; its response guard produces 500.
Wrapping the child makes the child's fallback response cross the opaque
boundary normally. Raw route targets use the same evidence shielding, although
they remain exact method-aware leaves rather than prefix mounts.

### Complete Router children placed in URLMap

`PAGI::App::URLMap` mounts and its `default` target are always opaque.

**Before (now incomplete):**

```perl
my $map = PAGI::App::URLMap->new;
$map->mount('/api' => $api_router->to_app);
```

**After (shipped):**

```perl
my $map = PAGI::App::URLMap->new;
$map->mount('/api' => compose(app => $api_router)->to_app);
```

The same rule applies to `default`. Compose around URLMap sees a selected
naked Router as incomplete opaque output and renders 500. Compose around the
child Router renders the child's 404 or 405 before URLMap returns. URLMap does
not inspect the target class or merge a child's private Trace into its parent.

### Distinguish Cascade status catching from trusted decline

**Before:** Router entries advanced only because their generated 404/405
responses appeared in `catch`.

```perl
my $routing = PAGI::App::Cascade->new(
    apps  => [$static_app, $api_router->to_app, $site_router->to_app],
    catch => [404, 405],
);
```

**After (shipped):** the spellings stay valid, but the two advance rules are
separate. A non-final Router may advance by trusted unanswered decline; an
explicit non-final response advances only when its status appears in `catch`.

```perl
my $routing = PAGI::App::Cascade->new(
    apps => [$static_app, $api_router->to_app, $site_router->to_app],
);

my $app = compose(app => $routing)->to_app;
```

A final Router decline remains unanswered for the enclosing routing fallback.
An arbitrary silent child is an incomplete-application error, not an implicit
miss. Non-caught responses now stream their start and body chunks as they
arrive instead of waiting for whole-child completion. A later exception is
therefore observably after response start and must propagate. Caught responses
are suppressed, awaited through their terminal body, and only then advance.

### Update ErrorHandler lifecycle expectations

**Before (removed behavior):** an exception after
`http.response.start` was warned about and swallowed, so callers could observe
normal completion even though the response was incomplete.

```perl
# Earlier tests could expect this failed stream to complete normally.
await $wrapped->($scope, $receive, $send);
```

**After (shipped):** ErrorHandler awaits reporting, emits no replacement
response, and rethrows the original exception for the server to abort the
stream.

```perl
my $future = Future->wrap($wrapped->($scope, $receive, $send));
die 'reporting was not awaited' if $future->is_ready;
$reporting_finished->done;
my $error = dies { $future->get };
is(refaddr($error), refaddr($original_error));
is($response_starts, 1);
```

```perl
my $errors = middleware(
    'ErrorHandler',
    handler => sub {
        my ($context, $error) = @_;
        return $context->json({ error => 'request failed' });
    },
    on_error => sub {
        my ($error) = @_;
        return $reporter->record($error); # immediate value or Future
    },
);
```

Before response start, a database throw or failed Future is reported and then
rendered by the custom or built-in handler. After response start, the renderer
is never called: `on_error` must settle first, its own failure is contained,
and the original database exception is rethrown unchanged. Tests that formerly
expected normal completion must now expect that failure and exactly one
response-start event.

Ordinary ErrorHandler construction keeps static `development => 0`; it does
not consult `PAGI_ENV`. Compose's private outer failsafe resolves development
mode per handled request and falls back to safe production text if environment
resolution itself fails. Every built-in ErrorHandler representation now adds
`Cache-Control: no-store`. Text and HTML bodies are UTF-8 octets encoded once;
JSON encoder octets are preserved; and `Content-Length` counts the emitted
bytes. A custom renderer owns its own content type and cache policy.

### Keep catch-all routing distinct from NotFound policy

**Before (too broad for error policy):** a final route was sometimes used only
to manufacture the application's missing-page response.

```perl
route('/*path' => \&missing_page, methods => ['GET'])
```

**After (shipped application policy):** let an ordinary fallback run after the
search declines.

```perl
compose(
    app => $routing,
    middleware => [
        middleware('Routing::NotFound',
            handler => \&missing_page),
    ],
)
```

Retain an ordinary catch-all when it really is a selected resource, such as an
SPA shell:

```perl
route('/*path' => \&spa_shell, methods => ['GET'])
```

It participates in declaration order, captures, method matching, and route
middleware. A GET-only catch-all gives an unknown POST a method partial; a
`methods => '*'` catch-all can deliberately supersede earlier partials.

`Routing::NotFound` instead runs only after its enclosed trusted search
declines. Use it for application or subsystem error policy. It does not make a
parent catch-all resume after a selected Mount already owns the path.

The routing Trace passed to fallback handlers contains facts, never a chosen
HTTP status: `routing_declined`, `path_matched`, `method_matched`,
`allowed_methods`, and bounded development attempts. PAGI::Context
intentionally has no `routing_trace`, `not_found`, or `method_not_allowed`
convenience method because Context also serves native applications and
third-party routers that do not implement this first-party evidence contract.
Middleware authors can use the low-level scope key and the Trace checkpoint/
snapshot API when they deliberately participate in it.

## Choose a frontend: three descriptions, one engine

**Before (removed):** the App frontend owned the matcher while the Endpoint
frontend added a separate handler, middleware, Context, and state adaptation
layer around it.

```perl
my $app_router = PAGI::App::Router->new;
my $app = $app_router->to_app;

my $endpoint_app = MyApp::Endpoint->to_app;
```

**After (shipped):** choose an immutable functional description, a mutable
closure builder, or a method-oriented Endpoint, then compile the same immutable
`PAGI::Routing::Router` model.

```perl
use PAGI::Routing qw(router route);

my $immutable = router(routes => [
    route('/health' => sub { return $_[0]->text('ok') }),
]);

my $builder = PAGI::App::Router->new;
$builder->get('/health' => sub { return $_[0]->text('ok') });
my $builder_snapshot = $builder->to_router;

my $endpoint = MyApp::Endpoint->new(repository => $repository);
my $endpoint_snapshot = $endpoint->to_router;
```

Use `PAGI::Routing` for already-immutable composition, `PAGI::App::Router` for
incremental closure declarations, and `PAGI::Endpoint::Router` for handlers
bound to one configured object.

Why: one compiler now gives all three frontends the same matching, middleware,
metadata, reverse-routing, and nonterminal HTTP-decline behavior.

## App handlers now receive `$c`

**Before (removed):** an ordinary App route target was a native PAGI
application and owned all three channels.

```perl
$r->get('/people' => sub {
    my ($scope, $receive, $send) = @_;
    return send_people_response($scope, $receive, $send);
});
```

**After (shipped):** an ordinary HTTP handler receives one
`PAGI::Context::HTTP` and returns a `PAGI::Response` or a `Future` resolving to
one.

```perl
$r->get('/people' => sub {
    my ($c) = @_;
    return $c->json($repository->all_people);
});
```

Why: the shared compiler can validate and emit HTTP responses consistently
when ordinary handlers use the Context contract.

## Ask for native channels with `raw`

**Before (removed):** passing a native PAGI application as an ordinary route
target selected native channel ownership implicitly.

```perl
$r->get('/download' => $native_download_app);
```

**After (shipped):** mark native route ownership explicitly for HTTP,
WebSocket, or SSE.

```perl
$r->get('/download', raw => $native_download_app);
$r->websocket('/socket', raw => $native_socket_app);
$r->sse('/events', raw => $native_event_app);
```

Why: `raw` makes it visible that the target receives
`($scope, $receive, $send)` and emits its own protocol events.

Endpoint uses the same grammar, including after positional middleware. Use
`app_as` only when the native target is a local Endpoint method:

```perl
$r->get('/download' => [$self->middleware_as('audit')],
    raw => $self->app_as('download'));
```

The raw coderef is otherwise preserved rather than rebound. Ordinary Endpoint
method names still receive `($self, $c)`, and ordinary handler coderefs still
receive `($c)`.

## Generic `route` is path-first

**Before (removed):** the generic form put the HTTP method before the path.

```perl
$r->route('POST', '/jobs' => $job_app);
```

**After (shipped):** put the path first and supply the method set as an option.

```perl
$r->route('/jobs' => sub {
    my ($c) = @_;
    return $c->json($jobs->create($c->request));
}, methods => ['POST']);
```

Why: the path-first form aligns generic HTTP declarations with `get`, `post`,
`websocket`, `sse`, and the immutable routing constructors.

## Names are slash-addressed

**Before (removed):** names and nested prefixes were joined with dots.

```perl
$r->get('/people/{id}' => $show_app)->name('people.show');
my $path = $r->uri_for('people.show', { id => 42 });
```

**After (shipped):** each declaration contributes one local name segment and
nested references use canonical slash addresses.

```perl
$r->group('/people' => sub {
    my ($people) = @_;
    $people->get('/{id}' => sub { return $_[0]->text('person') })
        ->name('show');
})->name('people');

my $path = $r->path_for('/people/show', { id => 42 });
```

Why: slash addresses provide one unambiguous logical path for routes, groups,
and inspectable mounts.

## `name` replaces `as` and mount `namespace`

**Before (removed):** an inspectable child was mounted positionally and its
names were imported afterward with `as`.

```perl
$r->mount('/api' => $child_router)->as('api');
my $path = $r->uri_for('api.people.show', { id => 42 });
```

**Removed metadata vocabulary:** public mount `namespace` values and accessors
are not part of the new description model.

**After (shipped):** declare a known router boundary with `router =>` and give
that mount its local name with the universal modifier.

```perl
$r->mount('/api', router => $child_router)->name('api');
my $path = $r->path_for('/api/people/show', { id => 42 });
```

Why: one `name` operation now assigns local logical segments to routes, groups,
and known mounts without a second import mechanism.

## Groups receive a fresh child builder

**Before (removed):** a group callback received its parent builder, and its
declarations were flattened into the parent's protocol collections.

```perl
$r->group('/api' => sub {
    my ($same_router) = @_;
    $same_router->get('/people' => $people_app);
});
```

**After (shipped):** the callback receives a fresh child builder retained as
one structural subtree at the group's declaration position.

```perl
$r->group('/api' => sub {
    my ($api) = @_;
    $api->get('/people' => sub { return $_[0]->json($people->all) })
        ->name('people');
})->name('api');
```

Why: a distinct child preserves group boundaries, local names, middleware,
constraints, and declaration order during materialization.

## Load and construct packages explicitly

**Before (removed):** group and mount string targets could load packages and
construct routing behavior as a side effect.

```perl
$r->group('/users' => 'MyApp::Routes::Users');
$r->mount('/admin' => 'MyApp::Admin');
```

**After (shipped):** load dependencies normally, construct configured objects,
and pass the exact object at a routing-aware boundary.

```perl
use MyApp::Endpoint::Users;
use MyApp::Endpoint::Admin;

my $users = MyApp::Endpoint::Users->new(repository => $repository);
my $admin = MyApp::Endpoint::Admin->new(policy => $policy);

$r->mount('/users', router => $users)->name('users');
$r->mount('/admin', router => $admin)->name('admin');
```

Why: explicit loading and construction make configuration, object identity,
dependency failures, and recursive router graphs visible to the application.

## Declaration order now governs routes and mounts

**Before (removed):** the old App Router kept separate HTTP, WebSocket, SSE,
and mount collections, checked protocol routes before mounts, and sorted mounts
longest-prefix-first.

```perl
$r->mount('/api'    => $broad_app);
$r->mount('/api/v2' => $v2_app);  # tried first because its prefix is longer
```

**After (shipped):** all declarations retain their written positions, so the
first full match owns dispatch.

```perl
$r->mount('/api'    => $broad_app);
$r->mount('/api/v2' => $v2_app);  # unreachable below /api while broad is first

# Reverse these declarations when /api/v2 must win.
```

Why: one declaration order makes route-versus-mount ownership and overlapping
prefix behavior inspectable without kind-specific precedence rules.

## Middleware has four universal forms

**Before (removed):** App routing lists accepted a factory coderef or an object
with `wrap`, while other routing surfaces had different accepted forms.

```perl
$r->get('/admin' => [
    $logging_factory,
    $configured_auth_object,
] => $admin_app);
```

**After (shipped):** every router, group, mount, and protocol route accepts a
class name, factory coderef, configured wrapping object, or explicit
description.

```perl
use PAGI::Routing qw(middleware);

$r->get('/admin' => [
    'RequestId',
    $logging_factory,
    $configured_auth_object,
    middleware('Session', cookie_name => 'sid'),
] => sub { return $_[0]->text('admin') });
```

Why: one native app-to-app middleware contract can wrap HTTP, WebSocket, SSE,
mount, group, and whole-router boundaries consistently.

## Endpoint middleware is native PAGI middleware

**Before (removed):** an Endpoint route middleware name selected a
response-valued method receiving `($self, $c, $next)`.

```perl
$r->get('/admin' => ['authenticate'] => 'admin');

sub authenticate {
    my ($self, $c, $next) = @_;
    my $response = $next->()->get;
    return $response;
}
```

**After (shipped):** Endpoint lists use the same synchronous app factory or
wrapping-object forms as every other routing surface.

```perl
$r->get('/admin' => [$auth_factory] => 'admin');

sub build_auth_factory {
    my ($policy) = @_;
    return sub {
        my ($inner_app) = @_;
        return sub {
            my ($scope, $receive, $send) = @_;
            return $policy->allows($scope)
                ? $inner_app->($scope, $receive, $send)
                : deny($send);
        };
    };
}
```

Why: native middleware controls downstream calls and channel wrapping without a
second response-valued execution model.

## Use `middleware_as` for a local middleware method

**Before (removed):** a bare string in an Endpoint middleware list was treated
as a local value-flow middleware method name.

```perl
$r->get('/account' => ['authenticate'] => 'account');
```

**After (shipped):** adapt a local method explicitly into a native middleware
factory.

```perl
sub routes {
    my ($self, $r) = @_;
    $r->get('/account' => [
        $self->middleware_as('authenticate'),
    ] => 'account');
}

sub authenticate {
    my ($self, $inner_app) = @_;
    return sub {
        my ($scope, $receive, $send) = @_;
        $self->check_scope($scope);
        return $inner_app->($scope, $receive, $send);
    };
}
```

Why: the adapter keeps method binding explicit while preserving the universal
native middleware contract.

## Use lifespan state through `$c->state`

**Before (removed):** Endpoint created a private state hash and injected it
into requests.

```perl
$self->state->{database} = connect_database();
my $database = $self->state->{database};
```

**After (shipped):** let the server or `PAGI::Compose` own lifespan state and
read the supplied hash through the request Context.

```perl
use PAGI::Compose qw(compose);

my $app = compose(
    app => $endpoint->to_app,
    lifespan => {
        startup  => sub { $_[0]{database} = connect_database() },
        shutdown => sub { $_[0]{database}->disconnect },
    },
)->to_app;

sub list_people {
    my ($self, $c) = @_;
    return $c->json($c->state->{database}->people);
}
```

Why: server-owned lifespan state has an explicit startup and shutdown lifetime
and retains one identity across the requests that receive it.

## `context_class` is gone; `new_context` is local only

**Before (removed):** overriding `context_class` changed the class Endpoint
used to build Context objects for compiled handlers.

```perl
sub context_class { return 'MyApp::Context' }
```

**After (shipped):** compiled routes always receive the shared protocol-specific
Contexts, while `new_context` is only an explicit convenience helper.

```perl
my $manual_context = $endpoint->new_context($scope, $receive, $send);

$r->get('/normal' => sub {
    my ($c) = @_;  # PAGI::Context::HTTP from the shared compiler
    return $c->text('ok');
});
```

Why: removing the compiler override keeps Context construction identical across
all frontends while leaving manual Context construction available locally.

## Mount nested Endpoint objects with `router =>`

**Before (removed):** compiling a nested Endpoint to an app first made it an
opaque mount whose routes and names were hidden from its parent.

```perl
$r->mount('/people' => MyApp::People->to_app);
```

**After (shipped):** construct the child and mount that object as a known
router.

```perl
my $people = MyApp::People->new(repository => $repository);
$r->mount('/people', router => $people)->name('people');

my $show = $endpoint->to_router
    ->path_for('/people/show', { id => 42 });
```

Why: a routing-aware object mount retains child metadata, reverse names, shared
materialization, identity reuse, and cycle diagnostics.

## Route middleware works for HTTP, WebSocket, and SSE

**Before (removed):** Endpoint rejected route-level middleware for WebSocket
and SSE declarations.

```perl
$r->websocket('/chat' => ['authenticate'] => 'chat'); # rejected
$r->sse('/events' => ['authenticate'] => 'events');   # rejected
```

**After (shipped):** use the same native middleware entry on every protocol
route.

```perl
my $auth = $self->middleware_as('authenticate');

$r->get('/account'       => [$auth] => 'account');
$r->websocket('/chat'    => [$auth] => 'chat');
$r->sse('/events'        => [$auth] => 'events');
```

Why: middleware now wraps the native application boundary, which exists for
all three protocols.

## Read `pagi.routing`, not `pagi.router`

**Before (removed):** matched App routes published a small route hash at the
old scope key.

```perl
my $route_path = $scope->{'pagi.router'}{route};
```

**After (shipped):** the shared compiler publishes a versioned routing
container whose frame stack records the current routing owner and any
compatible ancestor owners.

```perl
my $container = $c->scope->{'pagi.routing'};
die 'unsupported routing metadata' unless $container->{version} == 1;
my $current_frame = $container->{frames}[-1];
```

Prefer `$c->path_for(...)` when the goal is reverse routing rather than metadata
inspection.

Why: the frame stack and its mount ancestry can describe nested immutable
routers, captures, logical placement, and the selected leaf without mutating
shared descriptions.

## Retain a `to_router` snapshot for stable inspection

**Before (removed):** named-route inspection and generation read the mutable
App Router's internal tables directly.

```perl
my $routes = $r->named_routes;
my $path = $r->uri_for('people.show', { id => 42 });
```

**After (shipped):** materialize once and use that immutable object for a
coherent inspection view.

```perl
my $routing = $r->to_router;
my $route = $routing->route_named('/people/show');
my $path = $routing->path_for('/people/show', { id => 42 });
my $app = $routing->to_app;
```

Why: each frontend `to_router` call creates a fresh snapshot, so retaining one
keeps route identity, inspection, reverse routing, and compilation aligned.

## Generated paths validate and encode parameters

**Before (removed):** route generation substituted path values without applying
the route's full constraints or percent-encoding path parameters.

```perl
$r->get('/tags/{name}' => $tag_app)->name('tag.show');
my $path = $r->uri_for('tag.show', { name => 'Perl tools' });
```

**After (shipped):** `path_for` validates the complete effective path and
percent-encodes path, query, and fragment values.

```perl
$r->get('/tags/{name}' => sub { return $_[0]->text('tag') })
    ->name('show')
    ->constraints(name => qr/\A[[:print:]]+\z/);

my $path = $r->path_for('/show',
    { name => 'Perl tools' },
    { from => 'upgrade guide' },
    'examples');
# /tags/Perl%20tools?from=upgrade%20guide#examples
```

Why: generated paths now obey the same parameter contract as dispatch and are
safe to place in URI path, query, and fragment components.

## Raw routes and opaque mounts are different

**Before (removed):** ordinary route targets and mounts both accepted native
applications without making their different ownership rules explicit.

```perl
$r->get('/health' => $native_health_app);
$r->mount('/legacy' => $legacy_app);
```

**After (shipped):** use an exact, method-aware raw route for one leaf and an
opaque mount for a protocol-wide prefix boundary.

```perl
$r->get('/health', raw => $native_health_app);
$r->mount('/legacy' => $legacy_app);
```

A raw route keeps `path` and `root_path` unchanged, participates in HTTP 405
selection, and publishes leaf metadata; an opaque mount strips its prefix,
extends `root_path`, owns every protocol at that prefix, and hides its internals.

Why: choosing between a leaf and a prefix boundary determines matching,
methods, path rewriting, metadata visibility, and downstream ownership.
