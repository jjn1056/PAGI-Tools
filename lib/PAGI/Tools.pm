package PAGI::Tools;

use strict;
use warnings;

our $VERSION = '0.002002';

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

Pass C<$app> to a PAGI server, or call C<< $app->to_app >> when an explicit
native coderef is required.

=head1 THE APPLICATION TOPOLOGY

PAGI-Tools has one routing-construction API, L<PAGI::Routing>. Its layers have
separate jobs:

    Endpoint::HTTP/WebSocket/SSE  optional behavior for one exact route
    Route                         exact path and HTTP method policy
    Mount                         prefix ownership and app composition
    Router                        ordered children and NONE/PARTIAL outcomes
    Compose                       root lifespan, middleware, and safety

A C<Route> matches one complete leaf. A C<Mount> selects and owns a prefix,
rewrites the child path, and delegates to one application. A C<Router> scans
its children in declaration order and owns exhausted-match 404 and
method-mismatch 405 outcomes. C<Compose> constructs the deployed root Router
and surrounds it with application middleware, lifespan, error handling, HEAD
handling, and response-completion safety.

The route-level L<PAGI::Endpoint::HTTP>, L<PAGI::Endpoint::WebSocket>, and
L<PAGI::Endpoint::SSE> classes are optional behavior helpers for a single
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

The parent mounts C<< $people->routing >> directly. This keeps route names
inspectable for C<path_for> and C<url_for> without another frontend or a
mutable snapshot step.

=head1 ROUTE AND APPLICATION VALUES

Callable meaning is determined by its position:

    Route CODE endpoint        -> one Request/WebSocket/SSE argument
    Route to_app object        -> native PAGI application
    Mount/default CODE         -> native PAGI application
    handler result             -> native CODE or instantiated to_app object

A native three-channel coderef used at a Route must be marked with
L<PAGI::Utils/as_app>. Mount C<app> and Router C<http_default> already are
native application positions, so their CODE values take the three channels
directly.

For HTTP application objects that implement C<allowed_methods>, Route calls
that capability once at construction and snapshots the normalized methods.
A finite C<methods> option must be a restriction of that capability. The
Router then owns PARTIAL matching, automatic HEAD, OPTIONS participation, and
the authoritative C<Allow> union. Scalar C<< methods => '*' >> bypasses Route
method qualification and leaves method dispatch and 405 handling to the
endpoint. WebSocket and SSE routes never inspect this HTTP capability.

Configured Endpoint objects are retained exactly once per compiled
application. The same instance may serve concurrent requests or connections,
so keep only configuration and long-lived services on it. Request,
WebSocket, SSE, writer, and other connection-local state belongs to the
protocol object created for each invocation.

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

=item * L<PAGI::State>, L<PAGI::Stash>, L<PAGI::Session>, L<PAGI::CSRF>, and L<PAGI::Transport>

=item * L<PAGI::Test::Client> and related in-process testing tools

=back

The toolkit stays below application conventions and dependency assembly.
Higher-level frameworks can add those policies without maintaining another
core Router grammar.

=head1 SEE ALSO

L<PAGI::Tutorial>, L<PAGI::Tools::Tutorial>, L<PAGI::Tools::Cookbook>,
L<PAGI::Compose>, L<PAGI::Routing>, L<PAGI::Pages>, L<PAGI::Response>,
L<PAGI::App::File>, L<PAGI::Utils>, L<PAGI::Spec>,
L<router frontend upgrade guide|https://github.com/jjn1056/PAGI-Tools/blob/main/UPGRADING.md>,
L<PAGI::Server::Runner>

=head1 AUTHOR

John Napiorkowski <jjnapiork@cpan.org>

=head1 LICENSE

This library is free software; you may redistribute it and/or modify it under
the same terms as the Artistic License 2.0.

=cut
