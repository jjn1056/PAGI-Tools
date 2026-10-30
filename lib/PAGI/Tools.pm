package PAGI::Tools;

use strict;
use warnings;
use Exporter 'import';
use PAGI::Compose ();
use PAGI::ContentNegotiation ();
use PAGI::ErrorContext ();
use PAGI::Response ();
use PAGI::Routing ();
use PAGI::Routing::OpenAPI ();
use PAGI::Routing::URL ();
use PAGI::Session ();
use PAGI::Stash ();
use PAGI::State ();
use PAGI::Utils::Middleware ();

our $VERSION = '0.003000';

# Every name is the source module's own sub, aliased rather than wrapped:
# route, websocket, sse and mount resolve &Name constraint providers in the
# package that called them, and an alias keeps that the importing package.
my @SOURCES = (
    'PAGI::Compose'           => [qw(compose)],
    'PAGI::Response'          => [qw(response)],
    'PAGI::Routing'           => [qw(router route websocket sse mount middleware request_response endpoint)],
    'PAGI::Routing::URL'      => [qw(url path_for url_for)],
    'PAGI::Routing::OpenAPI'  => [qw(openapi)],
    'PAGI::ErrorContext'      => [qw(error_context)],
    'PAGI::State'             => [qw(app_state)],
    'PAGI::Stash'             => [qw(stash)],
    'PAGI::Session'           => [qw(session)],
    'PAGI::ContentNegotiation' => [qw(content_negotiation negotiated_type respond_to)],
    'PAGI::Utils::Middleware' => [qw(clone_scope wrap_send wrap_receive wrap_response_headers
                                     record_receive)],
);

our @EXPORT_OK;
for (my $i = 0; $i < @SOURCES; $i += 2) {
    my ($module, $names) = @SOURCES[$i, $i + 1];
    for my $name (@$names) {
        no strict 'refs';
        *{"PAGI::Tools::$name"} = \&{"${module}::$name"};
        push @EXPORT_OK, $name;
    }
}
our %EXPORT_TAGS = (
    routes => [qw(router route websocket sse mount)],
    urls   => [qw(url path_for url_for)],
    all    => [@EXPORT_OK],
);

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

Pass C<$app> to a PAGI server, or call C<< $app->to_app >> when an explicit
native coderef is required.

=head1 DESCRIPTION

PAGI-Tools collects application-side tools that are useful without requiring
a larger framework:

=over 4

=item * L<PAGI::Request>, L<PAGI::Response>, L<PAGI::WebSocket>, and L<PAGI::SSE>

=item * L<PAGI::HTTPConnection> for reading a request's headers, query and cookies
from the scope alone, in middleware or across HTTP, WebSocket and SSE

=item * L<PAGI::Routing> and L<PAGI::Routing::URL>

=item * L<PAGI::Routing::OpenAPI> for an OpenAPI document from an application's routes
(early beta: its interface may still change)

=item * L<PAGI::Compose> and L<PAGI::Lifespan>

=item * L<PAGI::Middleware> and the C<PAGI::Middleware::*> suite

=item * L<PAGI::App::File>, proxies, health checks, and other ready-made applications

=item * L<PAGI::Pages> for conventional negotiated HTTP applications

=item * L<PAGI::Auth> for authentication results, installed context, and challenge formatting

=item * L<PAGI::Middleware::Authentication> for request-based application authentication backends

=item * L<PAGI::Middleware::Requires> to declare the scopes a route, mount or application requires

=item * L<PAGI::State>, L<PAGI::Stash>, L<PAGI::Session>, L<PAGI::CSRF>, and L<PAGI::Transport>

=item * L<PAGI::FutureOwner> for work an application starts and does not wait for

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
answers 405 with an C<Allow> header. HEAD, disconnects and backpressure are
handled for you.

To keep the whole application in a module under F<lib/>, with no F<app.pl>,
subclass L<PAGI::App::Compose> (or L<PAGI::App> for a classic application) and
end the module with C<< __PACKAGE__->run_if_script >>
in place of C<1;>: C<pagi-server -Ilib --app lib/MyApp.pm> serves it, and
C<perl -Ilib lib/MyApp.pm GET /> runs one request from the shell.

=head1 IMPORTS

C<PAGI::Tools> exports the toolkit's everyday functions by name. Nothing is
exported by default, and an unknown name dies at compile time:

    use PAGI::Tools qw(compose response route path_for);
    use PAGI::Tools qw(compose :routes);

Each name is the function of the module listed here, re-exported as the same
sub rather than wrapped, so it behaves exactly as when imported from that
module. In particular C<route>, C<websocket>, C<sse> and C<mount> resolve a
C<{name:&Provider}> constraint provider in the package that called them: the
package that imported them from C<PAGI::Tools>.

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

=over 4

=item * C<:routes> exports C<router>, C<route>, C<websocket>, C<sse> and
C<mount>, as L<PAGI::Routing>'s C<:routes> does.

=item * C<:urls> exports C<url>, C<path_for> and C<url_for>.

=item * C<:all> exports every name above. Prefer naming what you use: a
reader then sees where each function comes from.

=back

Loading C<PAGI::Tools> loads those modules. Importing from each module
directly still works, and each module documents its own exports. Not exported
here: L<PAGI::Pages>' factories (generic names such as C<not_found>),
L<PAGI::State>'s lifetimes (C<singleton>, C<per_request>, C<factory>),
L<PAGI::Utils> (plumbing), L<PAGI::Middleware::Builder> (its own DSL, whose
default export C<mount> collides with this C<mount>; import Builder
selectively, as L<PAGI::Routing/IMPORTS> shows), and the C<PAGI::Exception::*>
classes, which are classes, not functions. C<use Future::AsyncAwait;> stays
your own line: C<PAGI::Tools> enables no pragmas.

Route constraints read best in their explicit form, which shows where a type
comes from:

    use Types::Standard qw(Int);

    route('/notes/{id}' => \&show, constraints => { id => Int });

The compact form names a capitalised provider function in the calling
package, here the same C<Int>:

    route('/notes/{id:&Int}' => \&show);

See L<PAGI::Routing/"Inline constraint providers">.

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
with the C<Allow> header, and it answers HEAD for you; an Endpoint::HTTP class
also answers OPTIONS.
L<Compose|PAGI::Compose> builds the top Router from your routes and wraps it
with application middleware, lifespan startup and shutdown, an error page for
exceptions, HEAD handling, and a guard that finishes a response the
application left incomplete.

L<PAGI::Endpoint::HTTP>, L<PAGI::Endpoint::WebSocket> and
L<PAGI::Endpoint::SSE> are for when one route's behavior is big enough to
want a class; they do not build routes. Name the class at its route with
C<endpoint>, which loads and builds it:
C<< route('/notes' => endpoint('MyApp::Notes', page_size => 50)) >>. A class
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

=over 4

=item * C<as_app_object($app)> (L<PAGI::Utils>) marks an existing
three-argument application so it can sit in a Route or C<http_default>.

=item * C<request_response($handler)> (L<PAGI::Routing>) wraps a one-Request
handler so it can be given to Mount. Its C<request_factory> option builds a
L<PAGI::Request> subclass of your own for that handler. For one Request class
across the application, use L<PAGI::Middleware::RequestClass>.

=back

Methods: for an HTTP application object that implements C<allowed_methods>,
Route asks once, when it is built, and a C<methods> option may only narrow
that list. C<< methods => '*' >> hands all method handling, 405 included, to
the application. WebSocket and SSE routes ignore C<allowed_methods>.

C<endpoint('Class', %args)> builds an Endpoint with
C<< Class->new(%args) >> for each request (each connection, for WebSocket
and SSE), so C<$self> belongs to that request and may keep its state. A
class that shares one object across every request, or wants another
lifetime such as one object per session, says so with C<BUILD_APP>; see
L<PAGI::Endpoint>.

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

PAGI-Tools targets L<PAGI::Spec::Www> B<0.7>. It depends on the specification,
not on any one server: it needs a server that implements Www 0.7, which puts a
C<pagi.connection> object in every C<http>, C<websocket> and C<sse> scope,
keeps a scope's sends in the order they were called (Tools' helpers send
without waiting for an earlier send to resolve), and advertises
C<< $scope->{pagi}{spec_version} >> as C<0.7>. L<PAGI::Server>, the reference
implementation, does so from 0.003000.

Tools checks the connection's capabilities where it uses them, not the version
number. L<PAGI::WebSocket> and L<PAGI::SSE> die at construction when the scope
lacks a complete connection object, naming the server's advertised
C<spec_version>. A streamed HTTP response (L<PAGI::Response::Stream>) names any
connection method it needs and lacks before sending. Code that only observes
a request, such as access logging, works without a connection object.

=head1 SEE ALSO

L<PAGI::Tutorial>, L<PAGI::Tools::Tutorial>, L<PAGI::Tools::Cookbook>,
L<PAGI::Tools::Extending> (building frameworks and add-ons on PAGI-Tools),
L<PAGI::Compose>, L<PAGI::Routing>, L<PAGI::Pages>, L<PAGI::Auth>, L<PAGI::Response>,
L<PAGI::App::File>, L<PAGI::Utils>, L<PAGI::Spec>,
L<router frontend upgrade guide|https://github.com/jjn1056/PAGI-Tools/blob/main/UPGRADING-REFERENCE.md>,
L<PAGI::Server::Runner>

=head1 AUTHOR

John Napiorkowski <jjnapiork@cpan.org>

=head1 LICENSE

This library is free software; you may redistribute it and/or modify it under
the same terms as the Artistic License 2.0.

=cut
