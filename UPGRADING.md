# Upgrading router frontends

This guide is for applications moving from the previous `PAGI::App::Router`
or `PAGI::Endpoint::Router` APIs to the shipped unified router frontends. The
new frontends intentionally remove the old contracts shown in the Before
examples; there is no compatibility mode.

Each After example uses behavior shipped by the current release. Examples use
ordinary synchronous subs where asynchronous work is not relevant; handlers
may still return a `Future` when their protocol operation is asynchronous.

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
metadata, reverse-routing, and generated-response behavior.

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
container with a frame for each compiled Router boundary.

```perl
my $container = $c->scope->{'pagi.routing'};
die 'unsupported routing metadata' unless $container->{version} == 1;
my $current_frame = $container->{frames}[-1];
```

Prefer `$c->path_for(...)` when the goal is reverse routing rather than metadata
inspection.

Why: the frame stack can describe nested immutable routers, captures, logical
placement, and the selected leaf without mutating shared descriptions.

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
