# NAME

PAGI::Tools - Application toolkit for the PAGI specification

# SYNOPSIS

PAGI itself is deliberately small: a native application is an async coderef
that receives `($scope, $receive, $send)`. PAGI-Tools supplies Request and
Response classes, declarative routing, middleware, lifecycle composition, and
in-process testing without hiding that protocol boundary.

For an ordinary HTTP application:

    use Future::AsyncAwait;
    use PAGI::Compose qw(compose);
    use PAGI::Response qw(json_response);
    use PAGI::Routing qw(mount route router);

    async sub home {
        my ($request) = @_;
        return json_response({ hello => 'world' });
    }

    async sub user {
        my ($request) = @_;
        return json_response({ id => $request->path_param('id') });
    }

    my $people = router(
        routes => [
            route('/{id}' => \&user, name => 'show'),
        ],
        desc => 'People routes',
    );

    my $app = compose(
        routes => [
            route('/' => \&home, name => 'home'),
            mount('/people', app => $people, name => 'people'),
        ],
    );

Pass `$app` to a PAGI server, or call `$app->to_app` when an explicit
native coderef is required.

# THE APPLICATION TOPOLOGY

PAGI-Tools has one routing-construction API, [PAGI::Routing](https://metacpan.org/pod/PAGI%3A%3ARouting). Its layers have
separate jobs:

    Endpoint::HTTP/WebSocket/SSE  optional behavior for one exact route
    Route                         exact path and HTTP method policy
    Mount                         prefix ownership and app composition
    Router                        ordered children and NONE/PARTIAL outcomes
    Compose                       root lifespan, middleware, and safety

A `Route` matches one complete leaf. A `Mount` selects and owns a prefix,
rewrites the child path, and delegates to one application. A `Router` scans
its children in declaration order and owns exhausted-match 404 and
method-mismatch 405 outcomes. `Compose` constructs the deployed root Router
and surrounds it with application middleware, lifespan, error handling, HEAD
handling, and response-completion safety.

The route-level [PAGI::Endpoint::HTTP](https://metacpan.org/pod/PAGI%3A%3AEndpoint%3A%3AHTTP), [PAGI::Endpoint::WebSocket](https://metacpan.org/pod/PAGI%3A%3AEndpoint%3A%3AWebSocket), and
[PAGI::Endpoint::SSE](https://metacpan.org/pod/PAGI%3A%3AEndpoint%3A%3ASSE) classes are optional behavior helpers for a single
leaf. They do not construct or own route trees. An ordinary class that owns a
reusable subtree can return an immutable Router:

    package MyApp::People;
    use PAGI::Routing qw(route router);

    sub routing {
        my ($self) = @_;
        return router(routes => [
            route('/' => sub { $self->index(@_) }, name => 'index'),
            route('/{id}' => sub { $self->show(@_) }, name => 'show'),
        ]);
    }

The parent mounts `$people->routing` directly. This keeps route names
inspectable for `path_for` and `url_for` without another frontend or a
mutable snapshot step.

# ROUTE AND APPLICATION VALUES

Callable meaning is determined by its position:

    HTTP Route endpoint / http_default CODE  -> one Request handler
    HTTP Route endpoint / http_default object -> app object via to_app
    WebSocket Route endpoint CODE             -> one WebSocket handler
    WebSocket Route endpoint object           -> app object via to_app
    SSE Route endpoint CODE                   -> one SSE handler
    SSE Route endpoint object                 -> app object via to_app
    Mount app CODE                       -> native PAGI application
    Mount app object                     -> app object via to_app

An **app object** is an instantiated object with a `to_app` method. Route
accepts either a one-argument Request/WebSocket/SSE handler or an app object.

A native three-channel coderef used at a Route or `http_default` must be
marked with ["as\_app\_object" in PAGI::Utils](https://metacpan.org/pod/PAGI%3A%3AUtils#as_app_object).
Mount `app` CODE is already a native application position. A bare
`http_default` CODE receives one Request; use `request_response($handler)`
only when adapting that handler into Mount `app`. The wrapper is a narrow
escape hatch for special protocol handling or an existing native PAGI coderef;
ordinary Route handlers use their direct Request, WebSocket, or SSE object.
`request_response($handler, request_factory => $factory)` also lets a project
build an ordinary Route around its own `PAGI::Request` subclass without adding
a new router node type.

For HTTP app objects that implement `allowed_methods`, Route calls
that capability once at construction and snapshots the normalized methods.
A finite `methods` option must be a restriction of that capability. The
Router then owns PARTIAL matching, automatic HEAD, OPTIONS participation, and
the authoritative `Allow` union. Scalar `methods => '*'` bypasses Route
method qualification and leaves method dispatch and 405 handling to the
endpoint. WebSocket and SSE routes never inspect this HTTP capability.

Configured Endpoint objects are retained exactly once per compiled
application. The same instance may serve concurrent requests or connections,
so keep only configuration and long-lived services on it. Request,
WebSocket, SSE, writer, and other connection-local state belongs to the
protocol object created for each invocation.

# ROOTED STATIC FILES

Use [PAGI::App::File](https://metacpan.org/pod/PAGI%3A%3AApp%3A%3AFile) rather than constructing a filesystem path from a URL
capture:

    use PAGI::App::File;
    use PAGI::Routing qw(mount);

    mount('/static', app => PAGI::App::File->from_app_path('static'));

The similarly named ["app\_path" in PAGI::Utils](https://metacpan.org/pod/PAGI%3A%3AUtils#app_path) returns a path string. Import and
call it directly from the module that owns the asset directory:

    package MyApp::Root;
    use PAGI::Utils qw(app_path);

    sub public_root { return app_path('public') }

Do not hide that caller-sensitive lookup behind an inherited base-class
wrapper. Construct the serving application separately with the returned path.

# DESCRIPTION

PAGI-Tools collects application-side tools that are useful without requiring
a larger framework:

- [PAGI::Request](https://metacpan.org/pod/PAGI%3A%3ARequest), [PAGI::Response](https://metacpan.org/pod/PAGI%3A%3AResponse), [PAGI::WebSocket](https://metacpan.org/pod/PAGI%3A%3AWebSocket), and [PAGI::SSE](https://metacpan.org/pod/PAGI%3A%3ASSE)
- [PAGI::Routing](https://metacpan.org/pod/PAGI%3A%3ARouting) and [PAGI::Routing::URL](https://metacpan.org/pod/PAGI%3A%3ARouting%3A%3AURL)
- [PAGI::Compose](https://metacpan.org/pod/PAGI%3A%3ACompose) and [PAGI::Lifespan](https://metacpan.org/pod/PAGI%3A%3ALifespan)
- [PAGI::Middleware](https://metacpan.org/pod/PAGI%3A%3AMiddleware) and the `PAGI::Middleware::*` suite
- [PAGI::App::File](https://metacpan.org/pod/PAGI%3A%3AApp%3A%3AFile), proxies, health checks, and other ready-made applications
- [PAGI::Pages](https://metacpan.org/pod/PAGI%3A%3APages) for conventional negotiated HTTP applications
- [PAGI::State](https://metacpan.org/pod/PAGI%3A%3AState), [PAGI::Stash](https://metacpan.org/pod/PAGI%3A%3AStash), [PAGI::Session](https://metacpan.org/pod/PAGI%3A%3ASession), [PAGI::CSRF](https://metacpan.org/pod/PAGI%3A%3ACSRF), and [PAGI::Transport](https://metacpan.org/pod/PAGI%3A%3ATransport)
- [PAGI::Test::Client](https://metacpan.org/pod/PAGI%3A%3ATest%3A%3AClient) and related in-process testing tools

The toolkit stays below application conventions and dependency assembly.
Higher-level frameworks can add those policies without maintaining another
core Router grammar.

# SEE ALSO

[PAGI::Tutorial](https://metacpan.org/pod/PAGI%3A%3ATutorial), [PAGI::Tools::Tutorial](https://metacpan.org/pod/PAGI%3A%3ATools%3A%3ATutorial), [PAGI::Tools::Cookbook](https://metacpan.org/pod/PAGI%3A%3ATools%3A%3ACookbook),
[PAGI::Compose](https://metacpan.org/pod/PAGI%3A%3ACompose), [PAGI::Routing](https://metacpan.org/pod/PAGI%3A%3ARouting), [PAGI::Pages](https://metacpan.org/pod/PAGI%3A%3APages), [PAGI::Response](https://metacpan.org/pod/PAGI%3A%3AResponse),
[PAGI::App::File](https://metacpan.org/pod/PAGI%3A%3AApp%3A%3AFile), [PAGI::Utils](https://metacpan.org/pod/PAGI%3A%3AUtils), [PAGI::Spec](https://metacpan.org/pod/PAGI%3A%3ASpec),
[router frontend upgrade guide](https://github.com/jjn1056/PAGI-Tools/blob/main/UPGRADING.md),
[PAGI::Server::Runner](https://metacpan.org/pod/PAGI%3A%3AServer%3A%3ARunner)

# AUTHOR

John Napiorkowski <jjnapiork@cpan.org>

# LICENSE

This library is free software; you may redistribute it and/or modify it under
the same terms as the Artistic License 2.0.
