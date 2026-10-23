# NAME

PAGI::Tools - Application toolkit for the PAGI specification

# SYNOPSIS

PAGI itself is deliberately small: a native application is an async coderef
that receives `($scope, $receive, $send)`. PAGI-Tools supplies Request and
Response classes, declarative routing, middleware, lifecycle composition, and
in-process testing without hiding that protocol boundary.

For an ordinary HTTP application:

    use Future::AsyncAwait;
    use PAGI::Tools qw(compose response route);

    async sub home {
        my ($request) = @_;
        return response('JSON', { hello => 'world' });
    }

    async sub user {
        my ($request) = @_;
        return response('JSON', { id => $request->path_param('id') });
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
- [PAGI::Routing::OpenAPI](https://metacpan.org/pod/PAGI%3A%3ARouting%3A%3AOpenAPI) for an OpenAPI document from an application's routes
- [PAGI::Compose](https://metacpan.org/pod/PAGI%3A%3ACompose) and [PAGI::Lifespan](https://metacpan.org/pod/PAGI%3A%3ALifespan)
- [PAGI::Middleware](https://metacpan.org/pod/PAGI%3A%3AMiddleware) and the `PAGI::Middleware::*` suite
- [PAGI::App::File](https://metacpan.org/pod/PAGI%3A%3AApp%3A%3AFile), proxies, health checks, and other ready-made applications
- [PAGI::Pages](https://metacpan.org/pod/PAGI%3A%3APages) for conventional negotiated HTTP applications
- [PAGI::Auth](https://metacpan.org/pod/PAGI%3A%3AAuth) for authentication results, installed context, and challenge formatting
- [PAGI::Middleware::Authentication](https://metacpan.org/pod/PAGI%3A%3AMiddleware%3A%3AAuthentication) for request-based application authentication backends
- [PAGI::Middleware::Requires](https://metacpan.org/pod/PAGI%3A%3AMiddleware%3A%3ARequires) to declare the scopes a route, mount or application requires
- [PAGI::State](https://metacpan.org/pod/PAGI%3A%3AState), [PAGI::Stash](https://metacpan.org/pod/PAGI%3A%3AStash), [PAGI::Session](https://metacpan.org/pod/PAGI%3A%3ASession), [PAGI::CSRF](https://metacpan.org/pod/PAGI%3A%3ACSRF), and [PAGI::Transport](https://metacpan.org/pod/PAGI%3A%3ATransport)
- [PAGI::FutureOwner](https://metacpan.org/pod/PAGI%3A%3AFutureOwner) for work an application starts and does not wait for
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
    use PAGI::Tools qw(compose response route websocket);

    async sub user {
        my ($request) = @_;
        return response('JSON', { id => $request->path_param('id') });
    }

    # Stream records as they are produced. Each write waits for the
    # client to keep up, and the loop stops if the client goes away.
    async sub export {
        my ($request) = @_;
        return response('NDJSON', async sub {
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

To keep the whole application in a module under `lib/`, with no `app.pl`,
subclass [PAGI::App::Compose](https://metacpan.org/pod/PAGI%3A%3AApp%3A%3ACompose) (or [PAGI::App](https://metacpan.org/pod/PAGI%3A%3AApp) for a classic application) and
end the module with `__PACKAGE__->run_if_script`
in place of `1;`: `pagi-server -Ilib --app lib/MyApp.pm` serves it, and
`perl -Ilib lib/MyApp.pm GET /` runs one request from the shell.

# IMPORTS

`PAGI::Tools` exports the toolkit's everyday functions by name. Nothing is
exported by default, and an unknown name dies at compile time:

    use PAGI::Tools qw(compose response route path_for);
    use PAGI::Tools qw(compose :routes);

Each name is the function of the module listed here, re-exported as the same
sub rather than wrapped, so it behaves exactly as when imported from that
module. In particular `route`, `websocket`, `sse` and `mount` resolve a
`{name:&Provider}` constraint provider in the package that called them: the
package that imported them from `PAGI::Tools`.

    Name                                          From
    compose                                       PAGI::Compose
    response                                      PAGI::Response
    router route websocket sse mount
      middleware request_response endpoint        PAGI::Routing
    url path_for url_for                          PAGI::Routing::URL
    openapi                                       PAGI::Routing::OpenAPI
    error_context                                 PAGI::ErrorContext
    app_state                                     PAGI::State
    stash                                         PAGI::Stash
    session                                       PAGI::Session
    content_negotiation negotiated_type
      respond_to                                  PAGI::ContentNegotiation
    clone_scope wrap_send wrap_receive
      wrap_response_headers record_receive        PAGI::Utils::Middleware

- `:routes` exports `router`, `route`, `websocket`, `sse` and
`mount`, as [PAGI::Routing](https://metacpan.org/pod/PAGI%3A%3ARouting)'s `:routes` does.
- `:urls` exports `url`, `path_for` and `url_for`.
- `:all` exports every name above. Prefer naming what you use: a
reader then sees where each function comes from.

Loading `PAGI::Tools` loads those modules. Importing from each module
directly still works, and each module documents its own exports. Not exported
here: [PAGI::Pages](https://metacpan.org/pod/PAGI%3A%3APages)' factories (generic names such as `not_found`),
[PAGI::State](https://metacpan.org/pod/PAGI%3A%3AState)'s lifetimes (`singleton`, `per_request`, `factory`),
[PAGI::Utils](https://metacpan.org/pod/PAGI%3A%3AUtils) (plumbing), [PAGI::Middleware::Builder](https://metacpan.org/pod/PAGI%3A%3AMiddleware%3A%3ABuilder) (its own DSL, whose
default export `mount` collides with this `mount`; import Builder
selectively, as ["IMPORTS" in PAGI::Routing](https://metacpan.org/pod/PAGI%3A%3ARouting#IMPORTS) shows), and the `PAGI::Exception::*`
classes, which are classes, not functions. `use Future::AsyncAwait;` stays
your own line: `PAGI::Tools` enables no pragmas.

Route constraints read best in their explicit form, which shows where a type
comes from:

    use Types::Standard qw(Int);

    route('/notes/{id}' => \&show, constraints => { id => Int });

The compact form names a capitalised provider function in the calling
package, here the same `Int`:

    route('/notes/{id:&Int}' => \&show);

See ["Inline constraint providers" in PAGI::Routing](https://metacpan.org/pod/PAGI%3A%3ARouting#Inline-constraint-providers).

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
with the `Allow` header, and it answers HEAD for you; an Endpoint::HTTP class
also answers OPTIONS.
[Compose](https://metacpan.org/pod/PAGI%3A%3ACompose) builds the top Router from your routes and wraps it
with application middleware, lifespan startup and shutdown, an error page for
exceptions, HEAD handling, and a guard that finishes a response the
application left incomplete.

[PAGI::Endpoint::HTTP](https://metacpan.org/pod/PAGI%3A%3AEndpoint%3A%3AHTTP), [PAGI::Endpoint::WebSocket](https://metacpan.org/pod/PAGI%3A%3AEndpoint%3A%3AWebSocket) and
[PAGI::Endpoint::SSE](https://metacpan.org/pod/PAGI%3A%3AEndpoint%3A%3ASSE) are for when one route's behavior is big enough to
want a class; they do not build routes. Name the class at its route with
`endpoint`, which loads and builds it:
`route('/notes' => endpoint('MyApp::Notes', page_size => 50))`. A class
that owns a group of routes returns a Router instead, and the parent mounts
it:

    package MyApp::People;
    use PAGI::Tools qw(route router);

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
    refuse (CSRF, TrustedHosts,         a handler taking     an application
    HTTPSRedirect, ReverseProxy,        one Request          (via to_app)
    RateLimit, ContentNegotiation,
    WrapCGI, File, Requires),
    Maintenance response,
    ErrorHandler handler
    URLMap mounts and default,          an application       an application
    Cascade, Builder's app

A slot that answers a request takes a handler; a slot that hosts an
application takes an application. Objects mean the same everywhere. Two small adapters cross between the slots:

- `as_app_object($app)` ([PAGI::Utils](https://metacpan.org/pod/PAGI%3A%3AUtils)) marks an existing
three-argument application so it can sit in a Route or `http_default`.
- `request_response($handler)` ([PAGI::Routing](https://metacpan.org/pod/PAGI%3A%3ARouting)) wraps a one-Request
handler so it can be given to Mount. Its `request_factory` option builds a
[PAGI::Request](https://metacpan.org/pod/PAGI%3A%3ARequest) subclass of your own for that handler. For one Request class
across the application, use [PAGI::Middleware::RequestClass](https://metacpan.org/pod/PAGI%3A%3AMiddleware%3A%3ARequestClass).

Methods: for an HTTP application object that implements `allowed_methods`,
Route asks once, when it is built, and a `methods` option may only narrow
that list. `methods => '*'` hands all method handling, 405 included, to
the application. WebSocket and SSE routes ignore `allowed_methods`.

`endpoint('Class', %args)` builds an Endpoint with
`Class->new(%args)` for each request (each connection, for WebSocket
and SSE), so `$self` belongs to that request and may keep its state. A
class that shares one object across every request, or wants another
lifetime such as one object per session, says so with `BUILD_APP`; see
[PAGI::Endpoint](https://metacpan.org/pod/PAGI%3A%3AEndpoint).

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
reference implementation, does so from 0.003000.

Tools checks the connection's capabilities where it uses them, not the version
number. [PAGI::WebSocket](https://metacpan.org/pod/PAGI%3A%3AWebSocket) and [PAGI::SSE](https://metacpan.org/pod/PAGI%3A%3ASSE) die at construction when the scope
lacks a complete connection object, naming the server's advertised
`spec_version`. A streamed HTTP response ([PAGI::Response::Stream](https://metacpan.org/pod/PAGI%3A%3AResponse%3A%3AStream)) names any
connection method it needs and lacks before sending. Code that only observes
a request, such as access logging, works without a connection object.

# SEE ALSO

[PAGI::Tutorial](https://metacpan.org/pod/PAGI%3A%3ATutorial), [PAGI::Tools::Tutorial](https://metacpan.org/pod/PAGI%3A%3ATools%3A%3ATutorial), [PAGI::Tools::Cookbook](https://metacpan.org/pod/PAGI%3A%3ATools%3A%3ACookbook),
[PAGI::Tools::Extending](https://metacpan.org/pod/PAGI%3A%3ATools%3A%3AExtending) (building frameworks and add-ons on PAGI-Tools),
[PAGI::Compose](https://metacpan.org/pod/PAGI%3A%3ACompose), [PAGI::Routing](https://metacpan.org/pod/PAGI%3A%3ARouting), [PAGI::Pages](https://metacpan.org/pod/PAGI%3A%3APages), [PAGI::Auth](https://metacpan.org/pod/PAGI%3A%3AAuth), [PAGI::Response](https://metacpan.org/pod/PAGI%3A%3AResponse),
[PAGI::App::File](https://metacpan.org/pod/PAGI%3A%3AApp%3A%3AFile), [PAGI::Utils](https://metacpan.org/pod/PAGI%3A%3AUtils), [PAGI::Spec](https://metacpan.org/pod/PAGI%3A%3ASpec),
[router frontend upgrade guide](https://github.com/jjn1056/PAGI-Tools/blob/main/UPGRADING-REFERENCE.md),
[PAGI::Server::Runner](https://metacpan.org/pod/PAGI%3A%3AServer%3A%3ARunner)

# AUTHOR

John Napiorkowski <jjnapiork@cpan.org>

# LICENSE

This library is free software; you may redistribute it and/or modify it under
the same terms as the Artistic License 2.0.
