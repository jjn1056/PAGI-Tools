# NAME

PAGI::Tools - Application toolkit for the PAGI specification

# SYNOPSIS

Raw PAGI is deliberately minimal — an application is just an `async` sub that
speaks the protocol directly:

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
    use PAGI::Request;
    use PAGI::Response;

    my $router = PAGI::App::Router->new;

    # A response value mounts straight onto a route:
    $router->get('/' => PAGI::Response->json({ hello => 'world' }));

    # A dynamic handler builds a request and sends a response value:
    $router->get('/users/:id' => async sub {
        my ($scope, $receive, $send) = @_;
        my $req = PAGI::Request->new($scope, $receive);
        await PAGI::Response->json({ id => $req->path_param('id') })->respond($send);
    });

    my $app = $router->to_app;   # still just a PAGI app: an async sub

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
- `PAGI::App::*` - ready-made apps (static files, routers, proxies,
WebSocket chat/echo, PSGI bridging)
- [PAGI::Endpoint::HTTP](https://metacpan.org/pod/PAGI%3A%3AEndpoint%3A%3AHTTP), [PAGI::Endpoint::Router](https://metacpan.org/pod/PAGI%3A%3AEndpoint%3A%3ARouter),
[PAGI::Endpoint::SSE](https://metacpan.org/pod/PAGI%3A%3AEndpoint%3A%3ASSE), [PAGI::Endpoint::WebSocket](https://metacpan.org/pod/PAGI%3A%3AEndpoint%3A%3AWebSocket) - high-level endpoint
framework
- [PAGI::Request](https://metacpan.org/pod/PAGI%3A%3ARequest), [PAGI::Response](https://metacpan.org/pod/PAGI%3A%3AResponse), [PAGI::Context](https://metacpan.org/pod/PAGI%3A%3AContext) - request
processing and ergonomics
- [PAGI::Test::Client](https://metacpan.org/pod/PAGI%3A%3ATest%3A%3AClient) and friends - in-process test utilities for
PAGI applications
- [PAGI::Utils](https://metacpan.org/pod/PAGI%3A%3AUtils) - composition and lifespan helpers; its
[to\_app](https://metacpan.org/pod/PAGI%3A%3AUtils#to_app) coercion is what lets every composition
point above accept component objects and class names directly

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
[PAGI::Cookbook](https://metacpan.org/pod/PAGI%3A%3ACookbook), [PAGI::Spec](https://metacpan.org/pod/PAGI%3A%3ASpec),
[PAGI::Server::Runner](https://metacpan.org/pod/PAGI%3A%3AServer%3A%3ARunner) - runs PAGI applications from the command line
(ships with the PAGI-Server distribution)

# AUTHOR

John Napiorkowski <jjnapiork@cpan.org>

# LICENSE

This library is free software; you may redistribute it and/or modify it
under the same terms as the Artistic License 2.0.
