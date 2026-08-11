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
    use Future::AsyncAwait;

    my $router = PAGI::App::Router->new;

    $router->get('/' => async sub {
        my ($c) = @_;
        return $c->json({ hello => 'world' });
    })->name('home');

    $router->get('/users/{id}' => async sub {
        my ($c) = @_;
        return $c->json({ id => $c->path_param('id') });
    })->name('user');

    my $routing = $router->to_router; # retain one immutable snapshot
    my $app = $routing->to_app;       # still a native PAGI app

Routing has three public frontends over that same immutable snapshot and
compiler:

    PAGI::Routing          immutable functional declarations   $c handlers
    PAGI::App::Router      mutable imperative builder          verb methods + $c
    PAGI::Endpoint::Router class/role-oriented frontend        local method names

Use the functional frontend when the declarations are already immutable:

    use PAGI::Routing qw(:routes);

    async sub home {
        my ($c) = @_;
        return $c->json({ hello => 'world' });
    }

    my $routing = router(routes => [
        route('/' => \&home, name => 'home'),
    ]);

    my $app = $routing->to_app;

Functional routing distinguishes inline C<< routes => [...] >>, inspectable
C<< router => $child >> mounts with a required local C<name>, and positional opaque
application mounts. Named routes compose into slash addresses such as
C</person/show>; request Contexts can generate relative links from the active
placement, with compact or named path/query/fragment arguments. These helpers
return strings or croak, perform no protocol I/O, and do not replace normal
authorization checks.

The three frontends share Pattern parsing, Resolver names, Compiler dispatch,
route metadata, constraints, GET/HEAD behavior, generated outcomes, written
declaration order, and reverse routing. Ordinary HTTP handlers receive C<$c>
and return a Response. Native channel ownership is always explicit with
C<raw>. See the
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
router-specific configuration or inspection is needed.

Declarative mount prefixes accept both the exact prefix and its slash form
without redirecting, a deliberate difference from Starlette's default mount
behavior. Its request-aware URLs consume normalized scope data; the shipped
ReverseProxy and TrustedHosts middleware still process HTTP only, so
WebSocket/SSE deployments must normalize and validate those scopes outside
routing.

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

=item * C<PAGI::App::*> - ready-made apps (static files, the mutable router
frontend, proxies,
WebSocket chat/echo, PSGI bridging)

=item * L<PAGI::Endpoint::HTTP>, L<PAGI::Endpoint::Router>,
L<PAGI::Endpoint::SSE>, L<PAGI::Endpoint::WebSocket> - high-level endpoint
framework

=item * L<PAGI::Request>, L<PAGI::Response>, L<PAGI::Context> - request
processing and ergonomics

=item * L<PAGI::Routing>, L<PAGI::App::Router>, and
L<PAGI::Endpoint::Router> - immutable functional, mutable imperative, and
method-oriented frontends over one immutable routing engine

=item * L<PAGI::Compose> - optional immutable application-root composition of
one request target, application middleware, and explicit lifecycle callbacks

=item * L<PAGI::Test::Client> and friends - in-process test utilities for
PAGI applications

=item * L<PAGI::Utils> - composition and lifespan helpers, including explicit
component-to-application coercion

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
L<PAGI::Routing>, L<PAGI::App::Router>, L<PAGI::Endpoint::Router>, L<PAGI::Spec>,
L<router frontend upgrade guide|https://github.com/jjn1056/PAGI-Tools/blob/main/UPGRADING.md>,
L<PAGI::Server::Runner> - runs PAGI applications from the command line
(ships with the PAGI-Server distribution)

=head1 AUTHOR

John Napiorkowski <jjnapiork@cpan.org>

=head1 LICENSE

This library is free software; you may redistribute it and/or modify it
under the same terms as the Artistic License 2.0.

=cut
