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
class for the C<PAGI::App::*> package family, while C<PAGI::Application> would claim
a central role this optional composer does not have. Direct router C<to_app>,
manual middleware, L<PAGI::Lifespan>, and hand-built protocol applications
remain supported alternatives.

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
matching, route metadata, and reverse-routing behavior remain router-owned.
Normal HTTP exhaustion is an unanswered routing-component outcome with trusted
trace evidence. Compose's automatic outer fallback interprets that evidence as
404 or 405. Protocol-specific misses retain the Router's existing outcomes.

Compose does not accept Router construction options through C<routes>. Build
and retain a Router when router middleware, C<desc>, reverse routing, or
inspection is needed. The compact direct form is
C<< compose(app => router(%router_options)) >>; retaining the Router also keeps
its inspection API available while Compose still owns the deployed boundary:

    my $routing = router(
        routes => \@nodes,
    );
    my $app = compose(
        app => $routing,
        middleware => [
            middleware('Routing::NotFound',
                handler => \&site_not_found),
        ],
    )->to_app;

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
sees HTTP, WebSocket, SSE, lifespan, and application-defined extension scopes.
An author fallback or error renderer is inside earlier listed author
middleware, so those earlier wrappers see the official response. Compose's
automatic emergency fallback is outside the complete author stack and does not
send its default response inward through author middleware. Protocol-specific
middleware must pass unrelated scope types through.

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

C<to_app> is the second phase: it synchronously compiles the target, fresh
author middleware wrappers, and fresh automatic safety wrappers after
constructor-time normalization, then returns one native PAGI coderef. It
performs no request or lifecycle I/O. Target loading, middleware construction,
and wrapping failures therefore occur at C<to_app>. Calling C<to_app> again
builds an independent graph and recompiles component objects, although lexical
state deliberately captured by user coderefs remains ordinary shared Perl
state.

For HTTP, the exact outer-to-inner order is:

  final HEAD wire boundary
    fresh shallow routing-trace scope
      automatic ErrorHandler
        response-completion guard
          automatic Routing::NotFound
            automatic Routing::MethodNotAllowed
              first application middleware
                second application middleware
                  Compose dispatcher
                    request target

The final HEAD boundary is outermost. Each HTTP request then receives a new
first-party routing Trace, replacing even a compatible incoming collector
without mutating the caller's scope. All lifecycle observation is lexical to
that request. The completion guard observes events without copying or
rewriting them and accepts a terminal C<http.response.body> with absent or
false C<more>, including sendfile bodies.

WebSocket, SSE, lifespan, and application-defined extension scopes retain the
author stack and dispatcher path; they do not enter the automatic HTTP
ErrorHandler, guard, or routing fallbacks. The first author middleware listed
remains outermost within that stack:

  first application middleware
    second application middleware
      Compose dispatcher
        lifespan driver or non-HTTP request target

Middleware scope changes are visible to callbacks and the request target;
receive/send wrappers cover lifecycle events as well as request protocols. A
middleware that does not call inward owns that scope. Immediate and
Future-backed target completion are both accepted, and target return values
are ignored because native PAGI events are the result channel. Normal HTTP
completion must include response start followed by a terminal body event.

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
application middleware remain ordinary middleware failures. The automatic HTTP
safety graph is not entered for lifespan.

=head1 HEAD REQUESTS

For HTTP HEAD, the final Compose wire boundary sits outside the automatic
safety graph and all application middleware. Middleware and built-in fallback
or error renderers therefore complete the full representation before wire
suppression. Body-derived C<Content-Length>, compression metadata, ETags, and
similar headers survive for target, fallback, error, and sendfile responses.

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
Every compiled Compose root has one unconditional HTTP safety boundary. There
is no public option to suppress, detect, configure, or disable it, and Compose
does not inspect author middleware to decide whether to install it.

After normal unanswered completion, trusted routing evidence produces a
plain-text no-store 404 or 405; 405 carries the deterministic union C<Allow>.
Normal completion without a valid response lifecycle throws
L<PAGI::Exception::IncompleteResponse>. Before response start, that exception,
request-target failures, failed Futures, author-middleware failures, and author
renderer failures are reported and converted to one plain-text no-store 500.
The internal reporter warns C<PAGI application error: $error>. Explicit
application responses, including matched 404, 405, and 500, pass unchanged and
are neither reported nor reinterpreted.

The automatic ErrorHandler resolves C<PAGI_ENV> only while rendering an error.
Development responses may include the error diagnostic; production responses
remain generic. If environment resolution itself fails, that failure is also
reported and the response uses safe production output. A normally complete
native response does not consult the environment or warn.

After response start, a thrown error or missing terminal body cannot be
replaced safely. Compose reports it, sends no second response start, and
rethrows the original value so the server can abort the incomplete stream.
The completion guard never replaces an inner exception.

Install ordinary author middleware for the application's official policy:

    middleware => [
        'RequestId',
        'AccessLog',
        'SecurityHeaders',
        middleware('ErrorHandler',
            handler  => \&site_error,
            on_error => \&report_error),
        middleware('Routing::NotFound',
            handler => \&site_not_found),
        middleware('Routing::MethodNotAllowed',
            handler => \&site_method_not_allowed),
    ]

These renderers run inside the automatic last resort. Earlier listed author
middleware can attach request identity, log, add security headers, or otherwise
observe their responses. If custom policy fails or leaves HTTP unanswered, the
automatic boundary still protects the deployed root. Both the author and
automatic layers remain installed; an inner response makes the outer layer
inert rather than triggering a duplicate start. Lifespan callback failures
retain the separate lifespan failure-event behavior documented above, and
non-HTTP target failures retain their existing propagation behavior.

An ordinary author ErrorHandler has static C<development =E<gt> 0> behavior
unless configured otherwise and awaits immediate or Future-backed C<on_error>
reporting. Only Compose's private automatic instance resolves development mode
dynamically per handled request. Before response start a database throw or
failed Future may be rendered; after start the same failure is reported and
re-thrown without a second response.

=head1 RELATIONSHIP TO OTHER PAGI APIS

C<< compose(routes => [...]) >> is a compact deployed root: a functional
Router plus application middleware, lifecycle, and automatic HTTP safety. It
does not replace any Router frontend. A directly compiled Router remains a
routing component whose exhausted HTTP search is unanswered; wrapping it with
C<< compose(app => $routing) >> adds the application boundary. For router
middleware, reverse routing, or inspection, retain that Router and pass it to
Compose. Compose deliberately does not delegate C<path_for>, C<route_named>,
or other target-specific methods.

L<PAGI::Routing>, L<PAGI::App::Router>, and L<PAGI::Endpoint::Router> are
functional, mutable, and method-oriented frontends over one immutable routing
engine. Any compiled frontend, native app, or component object/class can be the
single Compose target. Compose remains the optional deployed root that can own
application middleware and server-provided lifespan state; it is not a fourth
router. L<PAGI::Lifespan> and
L<PAGI::Utils/handle_lifespan> remain the low-level choices for hand-built
native applications or their existing hook-registration behavior.

=head1 SEE ALSO

L<PAGI::Routing>, L<PAGI::Routing::Middleware>, L<PAGI::Lifespan>,
L<PAGI::Utils>, L<PAGI::Tools::Tutorial>, L<PAGI::Tools::Cookbook>

=cut
