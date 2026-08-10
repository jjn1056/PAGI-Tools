package PAGI::Compose;

use strict;
use warnings;
use Carp qw(croak);
use Exporter 'import';
use Scalar::Util qw(blessed);
use PAGI::Routing::Middleware ();
use PAGI::Routing::Router ();

our @EXPORT_OK = qw(compose);
our %EXPORT_TAGS = (ALL => [@EXPORT_OK]);

sub compose {
    return __PACKAGE__->new(@_);
}

sub new {
    my ($class, @args) = @_;
    croak 'compose option list must be key/value pairs' if @args % 2;
    my %opts = @args;

    my %allowed = map { $_ => 1 } qw(routes app middleware lifespan);
    for my $key (keys %opts) {
        croak "unknown compose option '$key'" unless $allowed{$key};
    }

    my $has_routes = exists $opts{routes};
    my $has_app = exists $opts{app};
    croak 'compose requires exactly one of routes or app'
        unless $has_routes != $has_app;

    my $routes;
    if ($has_routes) {
        my $validated = PAGI::Routing::Router->new(routes => $opts{routes});
        $routes = $validated->routes;
    }
    else {
        _validate_app_shape($opts{app});
    }

    my $middleware = PAGI::Routing::Middleware->_normalize_descriptors(
        exists $opts{middleware} ? $opts{middleware} : [],
        'compose middleware',
    );
    my $lifespan = exists $opts{lifespan}
        ? _validate_lifespan($opts{lifespan})
        : undef;

    return bless {
        routes     => $routes,
        app        => $has_app ? $opts{app} : undef,
        middleware => $middleware,
        lifespan   => $lifespan,
    }, $class;
}

sub _validate_app_shape {
    my ($app) = @_;
    croak 'compose app must be defined' unless defined $app;
    return if ref($app) eq 'CODE' || blessed($app);
    return if !ref($app) && $app =~ /\A[A-Za-z_]\w*(?:::[A-Za-z_]\w*)*\z/;
    croak 'compose app must be a coderef, object, or class name';
}

sub _validate_lifespan {
    my ($lifespan) = @_;
    croak 'compose lifespan must be a hashref'
        unless ref($lifespan) eq 'HASH';
    my %allowed = map { $_ => 1 } qw(startup shutdown);
    for my $key (keys %$lifespan) {
        croak "unknown lifespan option '$key'" unless $allowed{$key};
    }
    croak 'compose lifespan requires startup or shutdown'
        unless exists $lifespan->{startup} || exists $lifespan->{shutdown};
    for my $key (qw(startup shutdown)) {
        croak "compose lifespan $key must be a coderef"
            if exists $lifespan->{$key} && ref($lifespan->{$key}) ne 'CODE';
    }
    return { %$lifespan };
}

sub routes {
    my ($self) = @_;
    return defined $self->{routes} ? [@{$self->{routes}}] : undef;
}

sub app { return $_[0]->{app} }

sub middleware { return [@{$_[0]->{middleware}}] }

sub lifespan {
    my ($self) = @_;
    return defined $self->{lifespan} ? {%{$self->{lifespan}}} : undef;
}

sub to_app {
    my ($self) = @_;
    require PAGI::Compose::Compiler;
    return PAGI::Compose::Compiler->compile($self);
}

1;

__END__

=head1 NAME

PAGI::Compose - Immutable application-root composition

=head1 SYNOPSIS

    use PAGI::Compose qw(compose);
    use PAGI::Routing qw(router route middleware);

    my $logging = sub {
        my ($app) = @_;
        return $app;
    };

    my $app = compose(
        routes => [route('/' => \&home)],
        middleware => [$logging, middleware('RequestId', header => 'X-Request-ID')],
        lifespan => {
            startup => sub { my ($state, $scope) = @_; $state->{ready} = 1 },
            shutdown => sub { my ($state, $scope) = @_; delete $state->{ready} },
        },
    )->to_app;

=head1 DESCRIPTION

PAGI::Compose is an optional application-root composer. It combines exactly
one request target, application-wide pure PAGI middleware, and optional
startup/shutdown callbacks. The constructor returns an immutable, inspectable
description; C<to_app> is the explicit compilation boundary that returns the
native PAGI coderef a server runs.

The deliberately narrow name matters. C<PAGI::App> would look like the base
class for the C<PAGI::App::*> namespace, while C<PAGI::Application> would claim
a central role this optional composer does not have. Direct router C<to_app>,
manual middleware, L<PAGI::Lifespan>, and native PAGI applications remain
supported alternatives.

=head1 IMPORTS

Nothing is exported by default. Import C<compose> explicitly or through the
uppercase C<:ALL> tag:

    use PAGI::Compose qw(compose);
    use PAGI::Compose qw(:ALL);

There is no lowercase C<:all> alias.

=head1 CONSTRUCTOR

C<compose(%options)> and C<< PAGI::Compose->new(%options) >> are equivalent.
The accepted top-level keys are C<routes>, C<app>, C<middleware>, and
C<lifespan>. An odd option list, an unknown key, or providing neither or both
of C<routes> and C<app> is an error.

Bare coderefs have deliberately different meanings according to position:

  Position                         Called with                       Meaning
  ------------------------------   -------------------------------   --------------------------
  route('/x' => $code)             ($context)                        Context handler
  compose(app => $code)            ($scope, $receive, $send)         native PAGI app
  middleware => [$entry]           ($inner_app), at compile time     normalized middleware description
  middleware($target, %config)     ($inner_app), at compile time     middleware description

=head2 routes

    compose(routes => \@routing_nodes)

C<routes> must be an arrayref accepted by L<PAGI::Routing>. An empty arrayref
is valid and explicit. The list is shallow-copied and structurally validated
at construction. Each C<to_app> builds a fresh root declarative router, whose
matching, generated 404/405 responses, route metadata, and reverse-routing
behavior remain router-owned.

Compose does not accept router options such as C<not_found>,
C<method_not_allowed>, or C<desc>. Build and retain a router when those are
needed. The compact direct form is
C<< compose(app => router(%router_options)) >>; retaining the router also keeps
its inspection API available:

    my $routing = router(
        routes             => \@nodes,
        not_found          => \&not_found,
        method_not_allowed => \&method_not_allowed,
    );
    my $app = compose(app => $routing)->to_app;

=head2 app

    compose(app => $component)

C<app> accepts the component forms supported by L<PAGI::Utils/to_app>: a
native coderef, an object with C<to_app>, or a loadable class with C<to_app>.
It must be defined and have a plausible component shape. Final component
coercion and class loading occur once during each C<to_app>, never per request.

This target receives every non-lifespan scope after application middleware.
It never receives the lifespan scope owned by Compose.

=head2 middleware

    my $logging = sub {
        my ($app) = @_;
        return $app;
    };

    middleware => [
        'RequestId',
        $logging,
        $configured_object,
        middleware('RequestId', header => 'X-Request-ID'),
    ]

C<middleware> is optional and defaults to an empty arrayref. Each entry is
a class name such as C<'RequestId'>, a bare factory coderef such as
C<$logging>, a configured object with C<wrap>, or a
L<PAGI::Routing::Middleware> description returned by C<middleware(...)>.
The list is shallow-copied and all four forms are normalized to descriptions
at construction; this phase does not load classes, construct objects, call
C<wrap>, or perform protocol I/O. C<middleware($class, %config)> is required
only for configured classes and remains useful for explicit reuse or
inspection. This is application middleware, not router middleware. It
surrounds generated routing outcomes and sees HTTP, WebSocket, SSE, lifespan,
and application-defined extension scopes. Protocol-specific middleware must
pass unrelated scope types through.

For router-only middleware, use C<< compose(app => router(...)) >>.

=head2 lifespan

    lifespan => {
        startup  => \&startup,
        shutdown => \&shutdown,
    }

C<lifespan> is optional. When present it must be a hashref containing at least
one of the exact keys C<startup> and C<shutdown>, and each supplied value must
be a coderef. A non-hash value, empty hashref, unknown key, or non-coderef
callback is an error. The hash is shallow-copied.

=head1 ACCESSORS

C<routes> returns a shallow arrayref copy in routes mode and C<undef> in app
mode. C<app> returns the original component by identity in app mode and
C<undef> in routes mode. C<middleware> returns a shallow arrayref copy whose
entries are homogeneous L<PAGI::Routing::Middleware> descriptions: bare
factories were normalized and explicit descriptions retain their identity.
C<lifespan> returns a shallow hashref copy or C<undef>.

The source object stores configuration only. It never stores compiled
middleware, lifecycle phase, request scope, server state, or response events.

=head1 COMPILATION AND MIDDLEWARE ORDER

C<to_app> is the second phase: it synchronously compiles the target and fresh
middleware instances after constructor-time normalization, then returns one
native PAGI coderef. It performs no request or lifecycle I/O. Target loading,
middleware construction, and wrapping failures therefore occur at C<to_app>.
Calling C<to_app> again builds an independent middleware graph and recompiles
component objects, although lexical state deliberately captured by user
coderefs remains ordinary shared Perl state.

The first listed middleware is outermost:

  final HEAD wire boundary
    first application middleware
      second application middleware
        Compose dispatcher
          lifespan driver or request target

Middleware scope changes are visible to callbacks and the request target;
receive/send wrappers cover lifecycle events as well as request protocols. A
middleware that does not call inward owns that scope. Immediate and
Future-backed target completion are both accepted, and target return values
are ignored because native PAGI events are the result channel.

=head1 LIFESPAN OWNERSHIP AND STATE

Compose owns C<lifespan> scopes and never delegates them to its target. Only
the deployed root owns lifecycle. A composition used as another composition's
C<app>, or mounted below a router, still dispatches requests but its callbacks
do not run. Lift required initialization into the root composition; this is a
documented ownership convention, not automatic route-tree discovery. Do not
put two independent lifespan consumers around one deployed root.

Callbacks receive C<($state, $scope)>. C<$state> is the exact unblessed
hashref supplied by the server and C<$scope> is the middleware-adjusted raw
lifespan scope. Middleware may mutate that state but must preserve unknown
scope keys and may not fabricate or replace the state reference. Compose does
not create fallback state or copy state into request scopes; the server owns
that propagation.

With callbacks configured, missing, malformed, replaced, or unprovable server
state prevents both callbacks from running and sends:

    {
        type    => 'lifespan.startup.failed',
        message => 'PAGI::Compose lifespan requires server state support',
    }

Without callbacks, ordinary startup and shutdown complete without requiring a
C<state> key.

Callback return values are ignored. Plain immediate completion and
Future-backed completion are normalized. A synchronous exception or failed
Future from startup produces C<lifespan.startup.failed>; shutdown failure
produces C<lifespan.shutdown.failed>, using the exception text as C<message>.
A failed startup does not invoke shutdown. A startup callback that allocates
several resources before failing owns cleanup of that partial startup.
Receive/send channel failures propagate rather than provoking a second
protocol response. Exceptions thrown outside the lifecycle callbacks by
application middleware remain ordinary middleware failures.

=head1 HEAD REQUESTS

For HTTP HEAD, the final Compose wire boundary sits outside all application
middleware. Middleware therefore sees the complete GET-equivalent
representation and may calculate C<Content-Length>, compression metadata,
ETags, and similar headers before suppression.

The boundary never rewrites HEAD to GET. Custom HEAD routes still receive
method C<HEAD>, so they can avoid an expensive GET handler. At the wire it
suppresses byte bodies, every chunk of a streaming body, file/sendfile body
events, and trailers, then emits one empty terminal body event. Response start
and other non-body events pass through.

L<PAGI::Middleware::Head> is an older explicit middleware that rewrites HEAD
to GET. It is unnecessary under Compose and can bypass a custom HEAD route; do
not enable it accidentally.

=head1 ERRORS

Constructor validation and C<to_app> compilation errors are synchronous.
Request-target and application-middleware failures propagate normally;
Compose does not synthesize HTTP 500 responses. Use application-wide error
middleware when that policy is required. Only missing required lifespan state
and configured callback failures are translated into lifespan failure events.

=head1 RELATIONSHIP TO OTHER PAGI APIS

C<< compose(routes => [...]) >> is a compact root declarative router plus
application middleware and lifecycle; it does not replace L<PAGI::Routing>.
For router fallbacks, router middleware, reverse routing, or inspection, retain
the router and pass it with C<< compose(app => $routing) >>. Compose deliberately
does not delegate C<path_for>, C<route_named>, or other target-specific methods.

L<PAGI::App::Router>, L<PAGI::Endpoint::Router>, native apps, and component
objects/classes can all be targets. L<PAGI::Lifespan> and
L<PAGI::Utils/handle_lifespan> remain the low-level choices for hand-built
native applications or their existing hook-registration behavior.

=head1 SEE ALSO

L<PAGI::Routing>, L<PAGI::Routing::Middleware>, L<PAGI::Lifespan>,
L<PAGI::Utils>, L<PAGI::Tools::Tutorial>, L<PAGI::Tools::Cookbook>

=cut
