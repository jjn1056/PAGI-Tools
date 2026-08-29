# NAME

PAGI::Tools - Application toolkit for the PAGI specification

Route matches a complete URL leaf. Mount composes an application under a
prefix. Router selects and owns routing outcomes. Middleware wraps behavior.
Compose owns the application root and lifespan.

# SYNOPSIS

Raw PAGI is deliberately minimal — an application is just an `async` sub that
speaks the protocol directly:

    use Future::AsyncAwait;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'application/json']],
        });
        await $send->({ type => 'http.response.body', body => '{"hello":"world"}' });
    };

PAGI-Tools adds the ergonomics — requests, response values, routing, a
middleware suite — so the same application reads like this:

    use PAGI::App::Router;
    use PAGI::Compose qw(compose);
    use PAGI::Response qw(json_response);
    use Future::AsyncAwait;

    my $router = PAGI::App::Router->new;

    $router->get('/' => async sub {
        my ($request) = @_;
        return json_response({ hello => 'world' });
    })->name('home');

    $router->get('/users/{id}' => async sub {
        my ($request) = @_;
        return json_response({ id => $request->path_param('id') });
    })->name('user');

    my $routing = $router->to_router; # retain one immutable snapshot
    my $app = compose(app => $routing)->to_app; # complete deployed app

For a small conventional landing page or HTTP error, [PAGI::Pages](https://metacpan.org/pod/PAGI%3A%3APages) builds an
ordinary negotiated concrete Response:

    use PAGI::Pages qw(welcome_page);

    my $response = PAGI::Pages->not_found($request);
    my $handler  = \&welcome_page;

For a conventional static tree, use the rooted file component rather than
constructing paths or reading files in a handler:

    use PAGI::App::File;

    my $static = PAGI::App::File->from_app_path('public')->to_app;

Its request-path construction is lexical and performs no I/O; the PAGI server
opens the resulting `file` event. Configured symlinks extend administrator
authority, so keep the root dedicated and non-attacker-writable and enforce
appropriate filesystem ownership and permissions. These are deployment best
practices, not physical confinement enforced by the component. Custom access
control remains a separate application decision. See
[PAGI::Tools::Cookbook](https://metacpan.org/pod/PAGI%3A%3ATools%3A%3ACookbook) for the authenticated XSendfile recipe and the
[rooted file-serving upgrade guide](https://github.com/jjn1056/PAGI-Tools/blob/main/UPGRADING.md#rooted-file-serving-security-contract)
for the intentionally changed statuses, hidden-file policy, and mapping rules.

Routing has three public frontends over that same immutable snapshot and
compiler:

    PAGI::Routing          immutable functional declarations   Request handlers
    PAGI::App::Router      mutable imperative builder          verb methods + Request
    PAGI::Endpoint::Router class/role-oriented frontend        local method names

Use the functional frontend when the declarations are already immutable:

    use PAGI::Routing qw(:routes);
    use PAGI::Compose qw(compose);
    use PAGI::Response qw(json_response);

    async sub home {
        my ($request) = @_;
        return json_response({ hello => 'world' });
    }

    my $routing = router(routes => [
        route('/' => \&home, name => 'home'),
    ]);

    my $app = compose(app => $routing)->to_app;

Every Mount names its target: `routes => [...]` constructs a complete child
Router, while `app => $child` composes a native application or instantiated
component. An immutable Router in `app` remains inspectable; other applications
are opaque. Named routes compose into slash addresses such as
`/person/show`; `PAGI::Routing::URL` can generate request-relative links from
the active placement, with compact or named path/query/fragment arguments. Its helpers
return strings or croak, perform no protocol I/O, and do not replace normal
authorization checks.

Response classes make representation and delivery cost explicit. Base, Text,
HTML, JSON, Problem, Redirect, and Empty are finite buffered values; File sends
one already selected path; Stream produces chunks with awaited send-Future
backpressure. Route and Mount retain separate ownership:

    Route('/x')       exact complete path leaf
    Route('/*path')   explicit real catchall leaf
    Mount('/x')       selected owner of /x and its complete subtree

The three frontends share Pattern parsing, Resolver names, Compiler dispatch,
route metadata, constraints, GET/HEAD behavior, Router-owned 404/405 outcomes,
first-seen method unions, written declaration order, and reverse
routing. Ordinary HTTP handlers receive `PAGI::Request` and return a Response;
WebSocket and SSE handlers receive their direct protocol objects. Native
channel ownership is always explicit with `raw`. A bare Router sends its own
negotiated 404 and compliant 405 and installs its own HeadBoundary, but it
deliberately has no root ErrorHandler, response-completion guard, or lifespan
driver. Compose adds an outer idempotent application-root HEAD boundary and
supplies those deployed application policies.
See the
[router frontend upgrade guide](https://github.com/jjn1056/PAGI-Tools/blob/main/UPGRADING.md)
for the intentionally breaking migration from the previous App and Endpoint
contracts.

For a small deployed root, the optional composer can put routes,
application-wide middleware, and lifecycle callbacks in one immutable
description:

    use PAGI::Compose qw(compose);
    use PAGI::Routing qw(route middleware);

    my $app = compose(
        routes => [route('/' => \&home)],
        middleware => [middleware('RequestId')],
        lifespan => {
            startup => sub {
                my ($state, $scope) = @_;
                $state->{ready} = 1;
            },
            shutdown => sub {
                my ($state, $scope) = @_;
                delete $state->{ready};
            },
        },
    )->to_app;

[PAGI::Compose](https://metacpan.org/pod/PAGI%3A%3ACompose) is an optional application-root composer, not a base class or
a replacement router. Build an explicit router and pass it through `app` when
router-specific configuration or inspection is needed. Configure a Router
`http_default` for custom missing-route presentation and ordinary ErrorHandler
middleware for official application errors. Compose keeps its stock error and
response-lifecycle boundary outside author middleware as the final safety net.

Declarative mount prefixes accept both the exact prefix and its slash form
without redirecting, a deliberate difference from Starlette's default mount
behavior. Its request-aware URLs consume normalized scope data; the shipped
ReverseProxy and TrustedHosts middleware still process HTTP only, so
WebSocket/SSE deployments must normalize and validate those scopes outside
routing.

PAGI follows Starlette's Route/Mount/Router/application topology, not every
method on Starlette Request. `PAGI::Request` owns HTTP input; imports identify
the Router or middleware that supplies optional behavior. This keeps URL,
Session, Stash, CSRF, State, and Transport ownership visible and lets another
framework use its own Router without teaching Request that framework's API.

The Starlette influence is conceptual, not API identity. PAGI distinguishes
direct protocol handlers from native three-channel application positions, validates
constraints without coercion, uses slash logical names and relative lookup,
treats SSE as a first-class scope, and exposes an HTTP-only `http_default`.
Starlette's single multiprotocol Router `default` was considered and not copied,
so PAGI retains its stock WebSocket and SSE miss behavior. PAGI middleware is
pure app-to-app wrapping; Compose, rather than Router, owns root lifespan.
OpenAPI and schema generation remain deferred until a concrete consumer is
designed.

Run it with any PAGI server (such as `pagi-server` from the `PAGI-Server`
distribution), or mount it inside a larger PAGI application.

# DESCRIPTION

[PAGI](https://metacpan.org/pod/PAGI) — the Perl Asynchronous Gateway Interface — is deliberately small: an
application is just an `async` sub that speaks a simple event protocol over
`$scope`, `$receive`, and `$send`. That minimalism is a virtue, but building
applications directly against the raw protocol can get verbose.

PAGI-Tools is the application-side toolkit that smooths this over. It collects
the ergonomics an author reaches for again and again, so you can build real
PAGI applications without hand-emitting protocol events:

- [PAGI::Middleware](https://metacpan.org/pod/PAGI%3A%3AMiddleware) and the `PAGI::Middleware::*` suite
- `PAGI::App::*` - ready-made apps (rooted static files, the mutable router
frontend, proxies,
WebSocket chat/echo, PSGI bridging)
- [PAGI::Endpoint::HTTP](https://metacpan.org/pod/PAGI%3A%3AEndpoint%3A%3AHTTP), [PAGI::Endpoint::Router](https://metacpan.org/pod/PAGI%3A%3AEndpoint%3A%3ARouter),
[PAGI::Endpoint::SSE](https://metacpan.org/pod/PAGI%3A%3AEndpoint%3A%3ASSE), [PAGI::Endpoint::WebSocket](https://metacpan.org/pod/PAGI%3A%3AEndpoint%3A%3AWebSocket) - high-level endpoint
framework
- [PAGI::Request](https://metacpan.org/pod/PAGI%3A%3ARequest) and [PAGI::Response](https://metacpan.org/pod/PAGI%3A%3AResponse) - HTTP input and detached output values; WebSocket and SSE
handlers receive their direct protocol objects
- `PAGI::State`, `PAGI::Stash`, `PAGI::Session`, `PAGI::CSRF`,
`PAGI::Transport`, and `PAGI::Routing::URL` - explicitly imported optional
scope capabilities
- [PAGI::Pages](https://metacpan.org/pod/PAGI%3A%3APages) - negotiated conventional welcome, redirect, and HTTP
error Responses returned by ordinary Request handlers
- [PAGI::Routing](https://metacpan.org/pod/PAGI%3A%3ARouting), [PAGI::App::Router](https://metacpan.org/pod/PAGI%3A%3AApp%3A%3ARouter), and
[PAGI::Endpoint::Router](https://metacpan.org/pod/PAGI%3A%3AEndpoint%3A%3ARouter) - immutable functional, mutable imperative, and
method-oriented frontends over one immutable routing engine
- [PAGI::Compose](https://metacpan.org/pod/PAGI%3A%3ACompose) - optional immutable application-root composition of
one request target, application middleware, explicit lifecycle callbacks, and
mandatory HTTP routing/error failsafes
- [PAGI::Test::Client](https://metacpan.org/pod/PAGI%3A%3ATest%3A%3AClient) and friends - in-process test utilities for
PAGI applications
- [PAGI::Utils](https://metacpan.org/pod/PAGI%3A%3AUtils) - composition, lifespan, and lexical path helpers,
including explicit component-to-application coercion

It is the author's hope that these tools serve two audiences: people
_exploring_ PAGI, who get going with far less friction than the raw protocol
asks for; and framework authors, who get a _ready-made base_ to build
higher-order frameworks on top of, rather than starting from `$scope`,
`$receive`, and `$send` every time.

The reference server lives in the `PAGI-Server` distribution; the
protocol specification lives in the `PAGI` distribution.

# SEE ALSO

[PAGI::Tutorial](https://metacpan.org/pod/PAGI%3A%3ATutorial) (the protocol tutorial, in the `PAGI` distribution),
[PAGI::Tools::Tutorial](https://metacpan.org/pod/PAGI%3A%3ATools%3A%3ATutorial) (this distribution's helpers guide),
[PAGI::Tools::Cookbook](https://metacpan.org/pod/PAGI%3A%3ATools%3A%3ACookbook) (this distribution's recipes), [PAGI::Compose](https://metacpan.org/pod/PAGI%3A%3ACompose),
[PAGI::Routing](https://metacpan.org/pod/PAGI%3A%3ARouting), [PAGI::Pages](https://metacpan.org/pod/PAGI%3A%3APages), [PAGI::Response](https://metacpan.org/pod/PAGI%3A%3AResponse), [PAGI::App::Router](https://metacpan.org/pod/PAGI%3A%3AApp%3A%3ARouter),
[PAGI::Endpoint::Router](https://metacpan.org/pod/PAGI%3A%3AEndpoint%3A%3ARouter), [PAGI::App::File](https://metacpan.org/pod/PAGI%3A%3AApp%3A%3AFile), [PAGI::Utils](https://metacpan.org/pod/PAGI%3A%3AUtils), [PAGI::Spec](https://metacpan.org/pod/PAGI%3A%3ASpec),
[router frontend upgrade guide](https://github.com/jjn1056/PAGI-Tools/blob/main/UPGRADING.md),
[PAGI::Server::Runner](https://metacpan.org/pod/PAGI%3A%3AServer%3A%3ARunner) - runs PAGI applications from the command line
(ships with the PAGI-Server distribution)

# AUTHOR

John Napiorkowski <jjnapiork@cpan.org>

# LICENSE

This library is free software; you may redistribute it and/or modify it
under the same terms as the Artistic License 2.0.
