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
    use PAGI::Routing qw(route);

    async sub home {
        my ($request) = @_;
        return json_response({ hello => 'world' });
    }

    async sub user {
        my ($request) = @_;
        return json_response({ id => $request->path_param('id') });
    }

    my $app = compose(
        routes => [
            route('/' => \&home),
            route('/people/{id}' => \&user),
        ],
    );

Pass `$app` to a PAGI server, or call `$app->to_app` when an explicit
native coderef is required.

# DESCRIPTION

PAGI-Tools collects application-side tools that are useful without requiring
a larger framework:

- [PAGI::Request](https://metacpan.org/pod/PAGI%3A%3ARequest), [PAGI::Response](https://metacpan.org/pod/PAGI%3A%3AResponse), [PAGI::WebSocket](https://metacpan.org/pod/PAGI%3A%3AWebSocket), and [PAGI::SSE](https://metacpan.org/pod/PAGI%3A%3ASSE)
- [PAGI::Routing](https://metacpan.org/pod/PAGI%3A%3ARouting) and [PAGI::Routing::URL](https://metacpan.org/pod/PAGI%3A%3ARouting%3A%3AURL)
- [PAGI::Compose](https://metacpan.org/pod/PAGI%3A%3ACompose) and [PAGI::Lifespan](https://metacpan.org/pod/PAGI%3A%3ALifespan)
- [PAGI::Middleware](https://metacpan.org/pod/PAGI%3A%3AMiddleware) and the `PAGI::Middleware::*` suite
- [PAGI::App::File](https://metacpan.org/pod/PAGI%3A%3AApp%3A%3AFile), proxies, health checks, and other ready-made applications
- [PAGI::Pages](https://metacpan.org/pod/PAGI%3A%3APages) for conventional negotiated HTTP applications
- [PAGI::Auth](https://metacpan.org/pod/PAGI%3A%3AAuth) for authentication results, installed context, and challenge formatting
- [PAGI::Middleware::Authentication](https://metacpan.org/pod/PAGI%3A%3AMiddleware%3A%3AAuthentication) for request-based application authentication backends
- [PAGI::State](https://metacpan.org/pod/PAGI%3A%3AState), [PAGI::Stash](https://metacpan.org/pod/PAGI%3A%3AStash), [PAGI::Session](https://metacpan.org/pod/PAGI%3A%3ASession), [PAGI::CSRF](https://metacpan.org/pod/PAGI%3A%3ACSRF), and [PAGI::Transport](https://metacpan.org/pod/PAGI%3A%3ATransport)
- [PAGI::Test::Client](https://metacpan.org/pod/PAGI%3A%3ATest%3A%3AClient) and related in-process testing tools

The toolkit stays below application conventions and dependency assembly.
Higher-level frameworks can add those policies without maintaining another
core Router grammar.

New to PAGI? Start with [PAGI::Tools::Tutorial](https://metacpan.org/pod/PAGI%3A%3ATools%3A%3ATutorial); [PAGI::Tools::Cookbook](https://metacpan.org/pod/PAGI%3A%3ATools%3A%3ACookbook)
has recipes for common tasks.

# A QUICK TOUR

Handlers receive one object for the protocol they serve and return a value.
An HTTP handler gets a [PAGI::Request](https://metacpan.org/pod/PAGI%3A%3ARequest) and returns a Response; a WebSocket
handler gets a [PAGI::WebSocket](https://metacpan.org/pod/PAGI%3A%3AWebSocket); an SSE handler gets a [PAGI::SSE](https://metacpan.org/pod/PAGI%3A%3ASSE):

    use Future::AsyncAwait;
    use PAGI::Compose qw(compose);
    use PAGI::Response qw(json_response ndjson_response);
    use PAGI::Routing qw(route websocket);

    async sub user {
        my ($request) = @_;
        return json_response({ id => $request->path_param('id') });
    }

    # Stream records as they are produced. Each write waits for the
    # client to keep up, and the loop stops if the client goes away.
    async sub export {
        my ($request) = @_;
        return ndjson_response(async sub {
            my ($writer) = @_;
            for my $n (1 .. 3) {
                last if $writer->is_disconnected;
                await $writer->write_item({ n => $n });
            }
        });
    }

    async sub echo {
        my ($ws) = @_;
        await $ws->accept;
        await $ws->each_text(async sub {
            my ($text) = @_;
            await $ws->send_text("echo: $text");
        });
    }

    my $app = compose(
        routes => [
            route('/people/{id}' => \&user),
            route('/export'      => \&export),
            websocket('/echo'    => \&echo),
        ],
    );

An unmatched path answers 404, and a matched path with the wrong method
answers 405 with an `Allow` header. HEAD, disconnects and backpressure are
handled for you.

# HOW THE PIECES FIT

[PAGI::Routing](https://metacpan.org/pod/PAGI%3A%3ARouting) is the one way to build routes. Five pieces, each with one
job:

    Route     one path, the methods it answers, and what handles it
    Mount     hands every path under a prefix to another application
    Router    an ordered list of Routes and Mounts
    Compose   the top of the application
    Endpoint  optional classes for the behavior of a single Route

A [Router](https://metacpan.org/pod/PAGI%3A%3ARouting%3A%3ARouter) tries its children in order. When nothing
matches it answers 404; when a path matches but not its method it answers 405
with the `Allow` header, and it answers HEAD and OPTIONS for you.
[Compose](https://metacpan.org/pod/PAGI%3A%3ACompose) builds the top Router from your routes and wraps it
with application middleware, lifespan startup and shutdown, an error page for
exceptions, HEAD handling, and a guard that finishes a response the
application left incomplete.

[PAGI::Endpoint::HTTP](https://metacpan.org/pod/PAGI%3A%3AEndpoint%3A%3AHTTP), [PAGI::Endpoint::WebSocket](https://metacpan.org/pod/PAGI%3A%3AEndpoint%3A%3AWebSocket) and
[PAGI::Endpoint::SSE](https://metacpan.org/pod/PAGI%3A%3AEndpoint%3A%3ASSE) are for when one route's behavior is big enough to
want a class; they do not build routes. A class that owns a group of routes
returns a Router instead, and the parent mounts it:

    package MyApp::People;
    use PAGI::Routing qw(route router);

    sub routing {
        my ($self) = @_;
        return router(routes => [
            route('/' => sub { $self->index(@_) }, name => 'index'),
            route('/{id}' => sub { $self->show(@_) }, name => 'show'),
        ]);
    }

    # in the parent: mount('/people', app => $people->routing)

Route names stay visible to [PAGI::Routing::URL](https://metacpan.org/pod/PAGI%3A%3ARouting%3A%3AURL)'s `path_for` and
`url_for`.

# HANDLERS AND APPLICATIONS

A PAGI **application** is either an `async` sub taking
`($scope, $receive, $send)`, or an object with a `to_app` method that
returns one. Perl has no callable objects, so what a plain sub means depends
on the slot it is given to:

    Slot                                A sub is...          An object is...
    Route endpoint (http/websocket/sse) a handler taking     an application
    Compose/Router http_default         one Request,         (via to_app)
                                        WebSocket or SSE
    Mount app                           an application       an application
                                        ($scope, $receive,   (via to_app)
                                        $send)

So Mount always takes an application, and a Route takes a handler or an
application object. Two small adapters cross between the slots:

- `as_app_object($app)` ([PAGI::Utils](https://metacpan.org/pod/PAGI%3A%3AUtils)) marks an existing
three-argument application so it can sit in a Route or `http_default`.
- `request_response($handler)` ([PAGI::Routing](https://metacpan.org/pod/PAGI%3A%3ARouting)) wraps a one-Request
handler so it can be given to Mount. Its `request_factory` option builds a
[PAGI::Request](https://metacpan.org/pod/PAGI%3A%3ARequest) subclass of your own for that handler.

Methods: for an HTTP application object that implements `allowed_methods`,
Route asks once, when it is built, and a `methods` option may only narrow
that list. `methods => '*'` hands all method handling, 405 included, to
the application. WebSocket and SSE routes ignore `allowed_methods`.

An Endpoint object is created once and serves every request or connection on
its route, concurrently. Keep only configuration and long-lived services on
it; per-request state belongs on the Request, WebSocket or SSE object.

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

# REQUIREMENTS

PAGI-Tools targets [PAGI::Spec::Www](https://metacpan.org/pod/PAGI%3A%3ASpec%3A%3AWww) **0.6**. It depends on the specification,
not on any one server: it needs a server that implements Www 0.6, which puts a
`pagi.connection` object in every `http`, `websocket` and `sse` scope and
advertises `$scope->{pagi}{spec_version}` as `0.6`. [PAGI::Server](https://metacpan.org/pod/PAGI%3A%3AServer), the
reference implementation, does so from 0.002014.

Tools checks the connection's capabilities where it uses them, not the version
number. [PAGI::WebSocket](https://metacpan.org/pod/PAGI%3A%3AWebSocket) and [PAGI::SSE](https://metacpan.org/pod/PAGI%3A%3ASSE) die at construction when the scope
lacks a complete connection object, naming the server's advertised
`spec_version`. A streamed HTTP response ([PAGI::Response::Stream](https://metacpan.org/pod/PAGI%3A%3AResponse%3A%3AStream)) names any
connection method it needs and lacks before sending. Code that only observes
a request, such as access logging, works without a connection object.

# SEE ALSO

[PAGI::Tutorial](https://metacpan.org/pod/PAGI%3A%3ATutorial), [PAGI::Tools::Tutorial](https://metacpan.org/pod/PAGI%3A%3ATools%3A%3ATutorial), [PAGI::Tools::Cookbook](https://metacpan.org/pod/PAGI%3A%3ATools%3A%3ACookbook),
[PAGI::Compose](https://metacpan.org/pod/PAGI%3A%3ACompose), [PAGI::Routing](https://metacpan.org/pod/PAGI%3A%3ARouting), [PAGI::Pages](https://metacpan.org/pod/PAGI%3A%3APages), [PAGI::Auth](https://metacpan.org/pod/PAGI%3A%3AAuth), [PAGI::Response](https://metacpan.org/pod/PAGI%3A%3AResponse),
[PAGI::App::File](https://metacpan.org/pod/PAGI%3A%3AApp%3A%3AFile), [PAGI::Utils](https://metacpan.org/pod/PAGI%3A%3AUtils), [PAGI::Spec](https://metacpan.org/pod/PAGI%3A%3ASpec),
[router frontend upgrade guide](https://github.com/jjn1056/PAGI-Tools/blob/main/UPGRADING.md),
[PAGI::Server::Runner](https://metacpan.org/pod/PAGI%3A%3AServer%3A%3ARunner)

# AUTHOR

John Napiorkowski <jjnapiork@cpan.org>

# LICENSE

This library is free software; you may redistribute it and/or modify it under
the same terms as the Artistic License 2.0.
