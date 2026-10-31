package PAGI::Middleware::Requires;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Carp qw(croak);
use Future::AsyncAwait;
use PAGI::Auth qw(auth);
use PAGI::Response::Redirect ();
use PAGI::Response::Text ();
use PAGI::Routing::URL ();
use PAGI::Utils ();
use PAGI::Utils::Scope ();

sub _init {
    my ($self, $config) = @_;
    my $scopes = exists $config->{scopes} ? $config->{scopes} : [];
    $scopes = [$scopes] if defined $scopes && !ref $scopes;
    croak 'Requires scopes must be a scope string or an arrayref of them'
        unless ref($scopes) eq 'ARRAY' && !grep { !defined || ref } @$scopes;
    croak 'Requires takes refuse or redirect, not both: a redirect replaces the refusal'
        if exists $config->{refuse} && exists $config->{redirect};
    if (exists $config->{redirect}) {
        my $redirect = $config->{redirect};
        croak 'Requires redirect must be a location string or an arrayref of path_for arguments'
            unless ref($redirect)
                ? ref($redirect) eq 'ARRAY' && @$redirect && defined($redirect->[0]) && !ref($redirect->[0])
                : defined($redirect) && length($redirect);
    }
    $self->{scopes}   = [@$scopes];
    $self->{redirect} = $config->{redirect};
    $self->{refuse}   = PAGI::Utils::_refuse_option('Requires', $config)
        // PAGI::Response::Text->new('Forbidden', status => 403)->to_app;
    PAGI::Utils::_reject_unknown_options('Requires', $config, qw(redirect refuse scopes));
}

sub wrap {
    my ($self, $app) = @_;
    my @required = @{ $self->{scopes} };
    return async sub {
        my ($scope, $receive, $send) = @_;
        my $type = $scope->{type} // '';
        my $context = ($type eq 'http' || $type eq 'websocket' || $type eq 'sse')
            ? auth($scope) : undef;
        if (!$context || ($context->user->is_authenticated
                && $context->credentials->has_all(@required))) {
            await $app->($scope, $receive, $send);
            return;
        }
        # The refusal answers on the original scope: before the application
        # runs nothing has started, so a WebSocket is denied before accept
        # and SSE declined before the stream starts.
        my $refusal = defined $self->{redirect}
            ? PAGI::Response::Redirect->new(_redirect_target($self->{redirect}, $scope), status => 303)->to_app
            : $self->{refuse};
        await $refusal->($scope, $receive, $send);
        return;
    };
}

# A string is the location as written. An arrayref holds path_for's
# arguments -- compact (NAME, \%params, \%query, $fragment) or named
# (NAME, params => ..., query => ..., fragment => ...) -- and gains a `next`
# query value, the original path and query, unless it sets its own.
sub _redirect_target {
    my ($redirect, $scope) = @_;
    return $redirect unless ref $redirect;

    # Compose's application middleware runs before any Router has matched,
    # so there is nothing to resolve a name against.
    my $routing = $scope->{'pagi.routing'};
    croak q{Requires redirect names a route, which needs a Router's routing frame: }
        . 'put Requires on a route, mount or Router, or give a location string'
        unless ref($routing) eq 'HASH' && ref($routing->{frames}) eq 'ARRAY' && @{ $routing->{frames} };

    my $original = PAGI::Utils::Scope::request_uri($scope);

    my ($name, @arguments) = @$redirect;
    if (!@arguments || !defined($arguments[0]) || ref($arguments[0]) eq 'HASH') {
        my ($params, $query, @fragment) = @arguments;
        @arguments = ($params // {}, { next => $original, %{ $query // {} } }, @fragment);
    }
    else {
        my %named = @arguments;
        $named{query} = { next => $original, %{ $named{query} // {} } };
        @arguments = %named;
    }
    return PAGI::Routing::URL::path_for($scope, $name, @arguments);
}

1;

__END__

=head1 NAME

PAGI::Middleware::Requires - declare the scopes a route, mount or application requires

=head1 SYNOPSIS

    use PAGI::Response qw(response);
    use PAGI::Routing qw(middleware mount route);

    # Every listed scope.
    route('/notes' => \&add_note, methods => ['POST'],
        middleware => [middleware('Requires', scopes => ['notes:write'])]),

    # A group, hidden from those without access.
    mount('/admin', middleware => [middleware('Requires', scopes => ['admin'],
        refuse => response('Text', 'Not Found', status => 404))], routes => [...]),

    # Any authenticated user; anyone else goes to the route named login.
    route('/home' => \&home, middleware => [middleware('Requires', redirect => ['login'])]),

C<middleware('Requires', ...)> goes in a Compose, Router, Mount or Route
C<middleware> list. Without them, construct it and wrap an application:

    my $wrapped = PAGI::Middleware::Requires->new(scopes => ['admin'])->wrap($app);

=head1 DESCRIPTION

What it wraps runs only for an authenticated user holding every scope the
middleware names; anyone else is refused. It is Starlette's C<@requires>, as
middleware: on a route it guards that route, on a mount every route under
it. It reads the connection's authentication context with
L<PAGI::Auth/auth>, so L<PAGI::Middleware::Authentication> must run in front
of it; a request with no authentication result installed dies.

Because it is middleware, what a route requires is visible from outside:
L<PAGI::Routing::RouteEntry/middleware> lists its description, with
C<factory> C<Requires> and the options below as its C<config>, so a tool
reading C<route_table> (an OpenAPI generator, a route listing) sees it.

=head2 Options

=over 4

=item * C<scopes>

A scope string, or an arrayref of them; the user's granted scopes
(C<< auth($request)->credentials >>) must include every one. The default,
C<[]>, requires only an authenticated user.

=item * C<refuse>

The refusal instead of the default plain-text 403 C<Forbidden>: any
application -- a Request handler (a coderef called with one
L<PAGI::Request>, returning a Response or an application) or an object with
C<to_app>, which includes every L<PAGI::Response> and L<PAGI::Pages> value. A
404 hides the route from those without access:

    refuse => response('Text', 'Not Found', status => 404)

A native C<($scope, $receive, $send)> application is passed as
C<as_app_object($app)>.

=item * C<redirect>

Instead of refusing, redirect with a L<PAGI::Response::Redirect> 303; give
this or C<refuse>, not both. A string is the location exactly as written: a
path, or a URL outside the application, with no C<next> added.

An arrayref holds the arguments to C<path_for> (see L<PAGI::Routing::URL>):
the route name, then its parameters, query and fragment, in either of the
forms C<path_for> takes. It is resolved against the refused request, so the
target's parameters are filled from the current route's matching ones (on
C</orgs/{org}/settings>, C<< redirect => ['org_login'] >> goes to
C</orgs/acme/login>), and the path and query the client requested
(L<PAGI::HTTPConnection/request_uri>, mount and root path included) are added to the
query as C<next>, so the login page can send the user back. A C<next> you
give yourself is kept instead.

Names resolve as C<path_for> resolves them from a handler where the
middleware runs: on a route, as from that route's handler; on a mount, as
from a handler inside the mount. A named mount adds its name to its routes'
addresses, so a login page outside it (inside, it would be protected too) is
C<../login>, or the absolute C</login>. An unnamed mount adds nothing, so its
routes and the enclosing Router's share names and C<login> finds the
enclosing Router's route.

An arrayref needs the routing frame a Router installs, so it works on a
route, a mount or a Router. Compose's application C<middleware> runs before
routing, so there an arrayref C<redirect> dies on each refused request,
saying so (the client gets a 500); use a string location or C<refuse> at that
level. A mounted application's own application middleware likewise runs
before that application's routing, with the enclosing application's frame,
so put C<Requires> with a route name on a route, mount or Router inside it.

Only redirect to C<next> when it is a local path (it starts with C</> but
not C<//>), or the login page becomes an open redirect. See
F<examples/auth-cookie-login>.

=back

Invalid options die when the middleware is constructed, which for a
C<middleware('Requires', ...)> description is when the application is
compiled (C<to_app>, at server startup): C<scopes> that is not a string or
an arrayref of strings, a C<refuse> that is not an application, a
C<redirect> that is neither a non-empty string nor an arrayref starting with
a route name, C<refuse> and C<redirect> together, an unknown option.

=head2 Behaviour

For HTTP, WebSocket and SSE, an allowed user's request reaches the wrapped
application unchanged. Otherwise the refusal (the redirect, C<refuse>, or
the 403) answers on the original scope and the application never runs: a
WebSocket is denied before it is accepted, and an SSE request is declined
before the stream starts. Every other scope type, such as C<lifespan>,
passes through without reading the authentication context.

Like Starlette's, the refusal is one answer: it does not tell an
unauthenticated user from a missing scope, and sends no C<WWW-Authenticate>
challenge. An API that wants RFC 6750 challenges writes its own check; see
"Protecting a group of endpoints" in L<PAGI::Auth>.

=head1 SEE ALSO

L<PAGI::Auth>, L<PAGI::Middleware::Authentication>, L<PAGI::Routing::RouteEntry>

=cut
