package PAGI::Tools;

use strict;
use warnings;

our $VERSION = '0.002002';

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::Tools - Application toolkit for the PAGI specification

Route matches a complete URL leaf. Mount composes an application under a
prefix. Router selects and owns routing outcomes. Middleware wraps behavior.
Compose owns the application root and lifespan.

=head1 SYNOPSIS

Raw PAGI is deliberately minimal — an application is just an C<async> sub that
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
    use PAGI::Response;
    use Future::AsyncAwait;

    my $router = PAGI::App::Router->new;

    $router->get('/' => async sub {
        my ($request) = @_;
        return PAGI::Response->json({ hello => 'world' });
    })->name('home');

    $router->get('/users/{id}' => async sub {
        my ($request) = @_;
        return PAGI::Response->json({ id => $request->path_param('id') });
    })->name('user');

    my $routing = $router->to_router; # retain one immutable snapshot
    my $app = compose(app => $routing)->to_app; # complete deployed app

For a small conventional landing page or HTTP error, L<PAGI::Pages> builds an
ordinary negotiated Response or a terminal endpoint:

    use PAGI::Pages;

    my $response = PAGI::Pages->not_found($request);
    my $endpoint = PAGI::Pages->welcome;

For a conventional static tree, use the rooted file component rather than
constructing paths or reading files in a handler:

    use PAGI::App::File;

    my $static = PAGI::App::File->app_path('public')->to_app;

Its request-path construction is lexical and performs no I/O; the PAGI server
opens the resulting C<file> event. Configured symlinks extend administrator
authority, so keep the root dedicated and non-attacker-writable and enforce
appropriate filesystem ownership and permissions. These are deployment best
practices, not physical confinement enforced by the component. Custom access
control remains a separate application decision. See
L<PAGI::Tools::Cookbook> for the authenticated XSendfile recipe and the
L<rooted file-serving upgrade guide|https://github.com/jjn1056/PAGI-Tools/blob/main/UPGRADING.md#rooted-file-serving-security-contract>
for the intentionally changed statuses, hidden-file policy, and mapping rules.

Routing has three public frontends over that same immutable snapshot and
compiler:

    PAGI::Routing          immutable functional declarations   Request handlers
    PAGI::App::Router      mutable imperative builder          verb methods + Request
    PAGI::Endpoint::Router class/role-oriented frontend        local method names

Use the functional frontend when the declarations are already immutable:

    use PAGI::Routing qw(:routes);
    use PAGI::Compose qw(compose);
    use PAGI::Response;

    async sub home {
        my ($request) = @_;
        return PAGI::Response->json({ hello => 'world' });
    }

    my $routing = router(routes => [
        route('/' => \&home, name => 'home'),
    ]);

    my $app = compose(app => $routing)->to_app;

Every Mount names its target: C<< routes => [...] >> constructs a complete
child Router, while C<< app => $child >> composes a native application or
instantiated component. An immutable Router in C<app> remains inspectable;
other applications are opaque. Named routes compose into slash addresses such as
C</person/show>; L<PAGI::Routing::URL> can generate request-relative links from
the active placement, with compact or named path/query/fragment arguments. Its helpers
return strings or croak, perform no protocol I/O, and do not replace normal
authorization checks.

The three frontends share Pattern parsing, Resolver names, Compiler dispatch,
route metadata, constraints, GET/HEAD behavior, Router-owned 404/405 outcomes,
first-seen method unions, written declaration order, and reverse
routing. Ordinary HTTP handlers receive L<PAGI::Request> and return a Response;
WebSocket and SSE handlers receive their direct protocol objects. Native
channel ownership is always explicit with C<raw>. A bare Router sends its own
negotiated 404 and compliant 405 and installs its own HeadBoundary, but it
deliberately has no root ErrorHandler, response-completion guard, or lifespan
driver. Compose adds an outer idempotent application-root HEAD boundary and
supplies those deployed application policies.
See the
L<router frontend upgrade guide|https://github.com/jjn1056/PAGI-Tools/blob/main/UPGRADING.md>
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

L<PAGI::Compose> is an optional application-root composer, not a base class or
a replacement router. Build an explicit router and pass it through C<app> when
router-specific configuration or inspection is needed. Configure a Router
C<http_default> for custom missing-route presentation and ordinary ErrorHandler
middleware for official application errors. Compose keeps its stock error and
response-lifecycle boundary outside author middleware as the final safety net.

Declarative mount prefixes accept both the exact prefix and its slash form
without redirecting, a deliberate difference from Starlette's default mount
behavior. Its request-aware URLs consume normalized scope data; the shipped
ReverseProxy and TrustedHosts middleware still process HTTP only, so
WebSocket/SSE deployments must normalize and validate those scopes outside
routing.

PAGI follows Starlette's Route/Mount/Router/application topology, not every
method on Starlette Request. L<PAGI::Request> owns HTTP input; imports identify
the Router or middleware that supplies optional behavior. This keeps URL,
Session, Stash, CSRF, State, and Transport ownership visible and lets another
framework use its own Router without teaching Request that framework's API.

The Starlette influence is conceptual, not API identity. PAGI distinguishes
direct protocol handlers from native three-channel application positions, validates
constraints without coercion, uses slash logical names and relative lookup,
treats SSE as a first-class scope, and exposes an HTTP-only C<http_default>.
Starlette's single multiprotocol Router C<default> was considered and not
copied, so PAGI retains its stock WebSocket and SSE miss behavior. PAGI
middleware is pure app-to-app wrapping; Compose, rather than Router, owns root
lifespan. OpenAPI and schema generation remain deferred until a concrete
consumer is designed.

Run it with any PAGI server (such as C<pagi-server> from the C<PAGI-Server>
distribution), or mount it inside a larger PAGI application.

=head1 DESCRIPTION

L<PAGI> — the Perl Asynchronous Gateway Interface — is deliberately small: an
application is just an C<async> sub that speaks a simple event protocol over
C<$scope>, C<$receive>, and C<$send>. That minimalism is a virtue, but building
applications directly against the raw protocol can get verbose.

PAGI-Tools is the application-side toolkit that smooths this over. It collects
the ergonomics an author reaches for again and again, so you can build real
PAGI applications without hand-emitting protocol events:

=over 4

=item * L<PAGI::Middleware> and the C<PAGI::Middleware::*> suite

=item * C<PAGI::App::*> - ready-made apps (rooted static files, the mutable router
frontend, proxies,
WebSocket chat/echo, PSGI bridging)

=item * L<PAGI::Endpoint::HTTP>, L<PAGI::Endpoint::Router>,
L<PAGI::Endpoint::SSE>, L<PAGI::Endpoint::WebSocket> - high-level endpoint
framework

=item * L<PAGI::Request> and L<PAGI::Response> - HTTP input and detached output
values; WebSocket and SSE handlers receive their direct protocol objects

=item * L<PAGI::State>, L<PAGI::Stash>, L<PAGI::Session>, L<PAGI::CSRF>,
L<PAGI::Transport>, and L<PAGI::Routing::URL> - explicitly imported optional
scope capabilities

=item * L<PAGI::Pages> - negotiated conventional welcome, redirect, and HTTP
error Responses and terminal endpoints

=item * L<PAGI::Routing>, L<PAGI::App::Router>, and
L<PAGI::Endpoint::Router> - immutable functional, mutable imperative, and
method-oriented frontends over one immutable routing engine

=item * L<PAGI::Compose> - optional immutable application-root composition of
one request target, application middleware, explicit lifecycle callbacks, and
mandatory HTTP routing/error failsafes

=item * L<PAGI::Test::Client> and friends - in-process test utilities for
PAGI applications

=item * L<PAGI::Utils> - composition, lifespan, and lexical path helpers,
including explicit component-to-application coercion

=back

It is the author's hope that these tools serve two audiences: people
I<exploring> PAGI, who get going with far less friction than the raw protocol
asks for; and framework authors, who get a I<ready-made base> to build
higher-order frameworks on top of, rather than starting from C<$scope>,
C<$receive>, and C<$send> every time.

The reference server lives in the C<PAGI-Server> distribution; the
protocol specification lives in the C<PAGI> distribution.

=head1 SEE ALSO

L<PAGI::Tutorial> (the protocol tutorial, in the C<PAGI> distribution),
L<PAGI::Tools::Tutorial> (this distribution's helpers guide),
L<PAGI::Tools::Cookbook> (this distribution's recipes), L<PAGI::Compose>,
L<PAGI::Routing>, L<PAGI::Pages>, L<PAGI::Response>, L<PAGI::App::Router>,
L<PAGI::Endpoint::Router>, L<PAGI::App::File>, L<PAGI::Utils>, L<PAGI::Spec>,
L<router frontend upgrade guide|https://github.com/jjn1056/PAGI-Tools/blob/main/UPGRADING.md>,
L<PAGI::Server::Runner> - runs PAGI applications from the command line
(ships with the PAGI-Server distribution)

=head1 AUTHOR

John Napiorkowski <jjnapiork@cpan.org>

=head1 LICENSE

This library is free software; you may redistribute it and/or modify it
under the same terms as the Artistic License 2.0.

=cut
