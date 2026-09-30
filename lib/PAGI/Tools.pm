package PAGI::Tools;

use strict;
use warnings;

our $VERSION = '0.002003';

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::Tools - Application toolkit for the PAGI specification

=head1 SYNOPSIS

PAGI itself is deliberately small: a native application is an async coderef
that receives C<($scope, $receive, $send)>. PAGI-Tools supplies Request and
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

Pass C<$app> to a PAGI server, or call C<< $app->to_app >> when an explicit
native coderef is required.

=head1 DESCRIPTION

PAGI-Tools collects application-side tools that are useful without requiring
a larger framework:

=over 4

=item * L<PAGI::Request>, L<PAGI::Response>, L<PAGI::WebSocket>, and L<PAGI::SSE>

=item * L<PAGI::Routing> and L<PAGI::Routing::URL>

=item * L<PAGI::Compose> and L<PAGI::Lifespan>

=item * L<PAGI::Middleware> and the C<PAGI::Middleware::*> suite

=item * L<PAGI::App::File>, proxies, health checks, and other ready-made applications

=item * L<PAGI::Pages> for conventional negotiated HTTP applications

=item * L<PAGI::Auth> for authentication results, installed context, and challenge formatting

=item * L<PAGI::Middleware::Authentication> for request-based application authentication backends

=item * L<PAGI::State>, L<PAGI::Stash>, L<PAGI::Session>, L<PAGI::CSRF>, and L<PAGI::Transport>

=item * L<PAGI::Test::Client> and related in-process testing tools

=back

The toolkit stays below application conventions and dependency assembly.
Higher-level frameworks can add those policies without maintaining another
core Router grammar.

New to PAGI? Start with L<PAGI::Tools::Tutorial>; L<PAGI::Tools::Cookbook>
has recipes for common tasks.

=head1 A QUICK TOUR

Handlers receive one object for the protocol they serve and return a value.
An HTTP handler gets a L<PAGI::Request> and returns a Response; a WebSocket
handler gets a L<PAGI::WebSocket>; an SSE handler gets a L<PAGI::SSE>:

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
answers 405 with an C<Allow> header. HEAD, disconnects and backpressure are
handled for you.

=head1 HOW THE PIECES FIT

L<PAGI::Routing> is the one way to build routes. Five pieces, each with one
job:

    Route     one path, the methods it answers, and what handles it
    Mount     hands every path under a prefix to another application
    Router    an ordered list of Routes and Mounts
    Compose   the top of the application
    Endpoint  optional classes for the behavior of a single Route

A L<Router|PAGI::Routing::Router> tries its children in order. When nothing
matches it answers 404; when a path matches but not its method it answers 405
with the C<Allow> header, and it answers HEAD and OPTIONS for you.
L<Compose|PAGI::Compose> builds the top Router from your routes and wraps it
with application middleware, lifespan startup and shutdown, an error page for
exceptions, HEAD handling, and a guard that finishes a response the
application left incomplete.

L<PAGI::Endpoint::HTTP>, L<PAGI::Endpoint::WebSocket> and
L<PAGI::Endpoint::SSE> are for when one route's behavior is big enough to
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

Route names stay visible to L<PAGI::Routing::URL>'s C<path_for> and
C<url_for>.

=head1 HANDLERS AND APPLICATIONS

A PAGI B<application> is either an C<async> sub taking
C<($scope, $receive, $send)>, or an object with a C<to_app> method that
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

=over 4

=item * C<as_app_object($app)> (L<PAGI::Utils>) marks an existing
three-argument application so it can sit in a Route or C<http_default>.

=item * C<request_response($handler)> (L<PAGI::Routing>) wraps a one-Request
handler so it can be given to Mount. Its C<request_factory> option builds a
L<PAGI::Request> subclass of your own for that handler.

=back

Methods: for an HTTP application object that implements C<allowed_methods>,
Route asks once, when it is built, and a C<methods> option may only narrow
that list. C<< methods => '*' >> hands all method handling, 405 included, to
the application. WebSocket and SSE routes ignore C<allowed_methods>.

An Endpoint object is created once and serves every request or connection on
its route, concurrently. Keep only configuration and long-lived services on
it; per-request state belongs on the Request, WebSocket or SSE object.

=head1 ROOTED STATIC FILES

Use L<PAGI::App::File> rather than constructing a filesystem path from a URL
capture:

    use PAGI::App::File;
    use PAGI::Routing qw(mount);

    mount('/static', app => PAGI::App::File->from_app_path('static'));

The similarly named L<PAGI::Utils/app_path> returns a path string. Import and
call it directly from the module that owns the asset directory:

    package MyApp::Root;
    use PAGI::Utils qw(app_path);

    sub public_root { return app_path('public') }

Do not hide that caller-sensitive lookup behind an inherited base-class
wrapper. Construct the serving application separately with the returned path.

=head1 REQUIREMENTS

PAGI-Tools targets L<PAGI::Spec::Www> B<0.6>. It depends on the specification,
not on any one server: it needs a server that implements Www 0.6, which puts a
C<pagi.connection> object in every C<http>, C<websocket> and C<sse> scope and
advertises C<< $scope->{pagi}{spec_version} >> as C<0.6>. L<PAGI::Server>, the
reference implementation, does so from 0.002014.

Tools checks the connection's capabilities where it uses them, not the version
number. L<PAGI::WebSocket> and L<PAGI::SSE> die at construction when the scope
lacks a complete connection object, naming the server's advertised
C<spec_version>. A streamed HTTP response (L<PAGI::Response::Stream>) names any
connection method it needs and lacks before sending. Code that only observes
a request, such as access logging, works without a connection object.

=head1 SEE ALSO

L<PAGI::Tutorial>, L<PAGI::Tools::Tutorial>, L<PAGI::Tools::Cookbook>,
L<PAGI::Compose>, L<PAGI::Routing>, L<PAGI::Pages>, L<PAGI::Auth>, L<PAGI::Response>,
L<PAGI::App::File>, L<PAGI::Utils>, L<PAGI::Spec>,
L<router frontend upgrade guide|https://github.com/jjn1056/PAGI-Tools/blob/main/UPGRADING.md>,
L<PAGI::Server::Runner>

=head1 AUTHOR

John Napiorkowski <jjnapiork@cpan.org>

=head1 LICENSE

This library is free software; you may redistribute it and/or modify it under
the same terms as the Artistic License 2.0.

=cut
