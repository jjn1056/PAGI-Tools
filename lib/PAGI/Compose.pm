package PAGI::Compose;

use strict;
use warnings;
use Carp qw(croak);
use Exporter 'import';
use PAGI::Routing::Middleware ();
use PAGI::Routing::Router ();

our @EXPORT_OK = qw(compose);
our %EXPORT_TAGS = (all => [@EXPORT_OK]);

sub compose {
    return __PACKAGE__->new(@_);
}

sub new {
    my ($class, @args) = @_;
    croak 'compose option list must be key/value pairs' if @args % 2;
    my %opts = @args;

    my %allowed = map { $_ => 1 }
        qw(routes http_default desc middleware lifespan);

    croak q{compose no longer accepts 'router'; mount an existing Router through mount('/' => app => $router)}
        if exists $opts{router};

    croak q{compose no longer accepts 'app'; deploy the application directly or compose it through Mount}
        if exists $opts{app};

    for my $key (keys %opts) {
        croak "unknown compose option '$key'" unless $allowed{$key};
    }

    croak 'compose requires routes' unless exists $opts{routes};
    croak 'compose routes must be an arrayref'
        unless ref($opts{routes}) eq 'ARRAY';

    my $router = PAGI::Routing::Router->new(
        routes => $opts{routes},
        (exists $opts{http_default}
            ? (http_default => $opts{http_default}) : ()),
        (exists $opts{desc} ? (desc => $opts{desc}) : ()),
    );

    my $middleware = PAGI::Routing::Middleware->_require_descriptors(
        exists $opts{middleware} ? $opts{middleware} : [],
        'compose middleware',
    );
    my $lifespan = exists $opts{lifespan}
        ? _validate_lifespan($opts{lifespan})
        : undef;

    return bless {
        router     => $router,
        middleware => $middleware,
        lifespan   => $lifespan,
    }, $class;
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

sub router       { $_[0]->{router} }
sub routes       { $_[0]->{router}->routes }
sub http_default { $_[0]->{router}->http_default }
sub desc         { $_[0]->{router}->desc }
sub named_routes { $_[0]->{router}->named_routes }
# The root Router's route_table, with the application middleware outermost.
sub route_table {
    my ($self) = @_;
    return map { $_->_with_outer_middleware(@{$self->{middleware}}) }
        $self->{router}->route_table;
}
sub route_named  { $_[0]->{router}->route_named($_[1]) }
sub path_for     { my $self = shift; return $self->{router}->path_for(@_) }

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
    use PAGI::Pages qw(not_found);
    use PAGI::Routing qw(middleware mount route);

    my $app = compose(
        routes => [
            route('/' => \&home),
            mount('/api', routes => \@api_routes),
        ],
        http_default => not_found(...),
        middleware   => [middleware('RequestId')],
        lifespan     => { startup => \&startup, shutdown => \&shutdown },
        desc         => 'Application root',
    );

For modular construction, preserve an existing configured Router behind an
explicit unnamed root Mount:

    use PAGI::Routing qw(middleware mount route router);

    my $routing = router(
        routes       => [route('/' => \&home, name => 'home')],
        http_default => $not_found,
        middleware   => [middleware($router_metrics)],
        desc         => 'Public routes',
    );

    my $app = compose(
        routes     => [mount('/' => app => $routing)],
        middleware => [middleware('RequestId')],
        lifespan   => { startup => \&startup },
    );

Pass C<< $app->to_app >> to a server when an explicit native coderef is
required.

=head1 DESCRIPTION

PAGI::Compose is an optional application-root facade around exactly one
immutable L<PAGI::Routing::Router> that it constructs from C<routes>. Compose
owns this distinct root Router, application-wide pure PAGI middleware,
optional startup/shutdown callbacks, and mandatory HTTP safety. An existing
configured Router is preserved only as the C<app> of an explicit Mount. The
constructor returns an immutable, inspectable description; C<to_app> is the
explicit compilation boundary that returns the native PAGI coderef a server
runs.

The deliberately narrow name matters. C<PAGI::App> is the optional base
class for applications, and C<PAGI::Application> would claim a central role
this optional composer does not have; a Compose application in a module
subclasses L<PAGI::App::Compose>. Direct router C<to_app>,
manual middleware, L<PAGI::Lifespan>, and hand-built protocol applications
remain supported alternatives.

=head1 IMPORTS

Nothing is exported by default. Import C<compose> explicitly or through the
C<:all> tag:

    use PAGI::Compose qw(compose);
    use PAGI::Compose qw(:all);

L<PAGI::Tools> also exports C<compose>.

=head1 CONSTRUCTOR

C<compose(%options)> and C<< PAGI::Compose->new(%options) >> are equivalent.
The accepted top-level keys are C<routes>, C<http_default>, C<desc>,
C<middleware>, and C<lifespan>. C<routes> is required. An odd option list, an
unknown key, or a missing C<routes> value is an error.

C<app> and C<router> are no longer Compose options. Put an existing immutable
Router behind an explicit root Mount instead:

    compose(routes => [mount('/' => app => $router)])

Mount an immutable Router directly when a reusable subtree must preserve its
middleware, C<http_default>, description, identity, or descendant names:

    my $people = MyApp::People->new(repo => $repo)->routing;
    compose(routes => [
        mount('/people', app => $people, name => 'people'),
    ]);

The ordinary component's C<routing> method returns a
L<PAGI::Routing::Router>; no mutable snapshot or automatic structural
conversion is involved.

An arbitrary native application has no direct Compose form in this release;
deploy it directly or use a separately designed application boundary.

Callable meaning is positional; L<PAGI::Routing/HANDLERS> has the one table.

Middleware descriptions are a separate construction-time contract: Compose
constructs configured class targets, invokes factory targets with the inner
application, or calls C<wrap> on configured object targets while building the
middleware stack.

=head2 routes

    compose(routes => \@routing_nodes)

C<routes> must be an arrayref accepted by L<PAGI::Routing>. An empty arrayref
is valid and explicit. The list is shallow-copied and structurally validated
at Compose construction. Compose immediately constructs and owns one distinct
L<PAGI::Routing::Router>; later C<to_app> calls compile that same root
description rather than reconstructing it. The root Router owns matching,
route metadata, reverse routing, exhausted-match 404, method-mismatch 405 with
C<Allow>, and protocol-specific miss behavior. Compose neither installs
routing metadata nor interprets routing outcomes.

C<http_default> and C<desc> are optional. They are passed unchanged into the
root Router and are available through the delegated Compose accessors. This
form handles a common root declaration without constructing a disposable
Router first:

    compose(
        routes       => \@nodes,
        http_default => $not_found,
        desc         => 'Public routes',
    )

Put a source-free Pages application directly in C<http_default> for the usual
custom 404, or a bare one-Request handler when the result depends on the
request; an advanced native default is marked with C<as_app_object>.
L<PAGI::Tools::Cookbook/"HTTP Defaults: Pages, Request Handlers, and Native Applications">
shows each.

Compose C<middleware> is the outer application-wide boundary. When a reusable
Router already owns middleware, C<http_default>, C<desc>, identity, or a
Resolver, preserve that Router explicitly:

    compose(routes => [mount('/' => app => $routing)])

The Mount retains the configured Router; Compose still constructs and owns a
distinct outer root Router. An ordinary component can expose a C<routing>
method that returns an immutable Router; mount that Router directly to retain
its boundary, or pass its C<routes> list deliberately when flattening is the
intended policy.

=head2 composition choices

The four forms have different ownership:

    # New root Router from declarations
    compose(routes => \@nodes);

    # Preserve an existing Router application
    compose(routes => [mount('/' => app => $router)]);

    # Deliberately flatten direct child nodes
    compose(routes => $router->routes);

    # Deploy without Compose root services
    $router->to_app;

Flattening copies only the Router's direct Route and Mount nodes into the new
Compose root. It discards the source Router's middleware, C<http_default>,
C<desc>, identity, and Resolver. The leaves may be shared objects, but the
source Router is no longer the selected child boundary.

The preserving root Mount consumes no path, and an unnamed Mount adds no
namespace to slash route names. Once selected, the child Router owns its 404,
405, and protocol misses. The outer root does not resume scanning, so later
root siblings cannot win after that Mount.

Compose is the application root. The parts of one application are Routers
(C<< mount('/notes', app => MyApp::Notes->routing) >>), which routing sees
into. A Compose mounted below another is a separate application, with its own
names and no lifespan (see L<PAGI::Routing/mount>).

=head2 middleware

    my $logging = sub {
        my ($app) = @_;
        return $app;
    };

    middleware => [
        middleware('RequestId'),
        middleware($logging),
        middleware($configured_object),
        middleware('RequestId', header => 'X-Request-ID'),
    ]

C<middleware> is optional and defaults to an empty arrayref. Core Compose lists
contain only L<PAGI::Routing::Middleware> descriptions returned by
C<middleware(...)>. The list is shallow-copied; this phase does not load
classes, construct objects, call C<wrap>, or perform protocol I/O.
C<middleware($class, %config)> and C<middleware($factory, %config)> capture
configuration for deferred construction or synchronous factory execution;
C<middleware($object)> accepts an already configured object with C<wrap>.
This is application middleware, not router middleware. It
sees HTTP, WebSocket, SSE, lifespan, and application-defined extension scopes.
Responses travel outward through this complete stack. A stock
L<PAGI::Middleware::ErrorHandler> listed here is taken out of the list,
wherever it is, and split as Starlette builds an application: its exception
boundary (C<catch>, and HTTP errors' built-in answers) is around the root
Router, inside every application middleware; its server-error boundary
(C<handler>, C<on_error>, the 500) is outside them all. So an application
middleware's error is answered by C<handler>, never by C<catch>, and nothing
an application middleware adds -- a scope key, a response header -- reaches
that 500. ErrorHandler's C<catch> is for what the application raises; a
middleware with errors of its own answers them with its own table, such as
L<PAGI::Middleware::Authentication>'s C<catch>. Middleware that must cover server-error responses, such as
RequestId, AccessLog, SecurityHeaders or CORS, wrap the compiled application
instead (C<< PAGI::Middleware::RequestId->new->wrap($compose->to_app) >>; see
L<PAGI::Tools::Cookbook/Compose Safety and Application Error Policy>). One
stock ErrorHandler per Compose: a second dies at C<to_app>. A subclass of
ErrorHandler is not split and wraps what follows it where it is listed.
Compose's emergency ErrorHandler is outside the complete author stack and
does not send its safety response inward through author middleware.
Protocol-specific middleware must pass unrelated scope types through.

For router-only middleware, construct a Router with its own C<middleware> list
and preserve it through an explicit root Mount.

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

C<router> returns only the distinct root Router constructed and owned by
Compose. C<routes> returns that root Router's direct children, so a preserved
child Router appears as its root Mount rather than as flattened leaves.
C<route_table> returns the root Router's entries with Compose's application
middleware outermost in each entry's C<middleware> (see
L<PAGI::Routing::RouteEntry>).
C<http_default>, C<desc>, C<named_routes>, C<route_named>, and C<path_for>
delegate to the root Router and therefore use its Resolver and stable
declaration graph. Resolver traversal can discover named leaves beneath an
inspectable Router-valued Mount; this does not make the child the Compose root.
C<routes> and C<named_routes> retain the Router's shallow-copy contracts;
C<route_named> returns the original named leaf or Mount, or C<undef>;
C<path_for> has the forms documented by
L<PAGI::Routing::Router/path_for>.

C<middleware> returns a shallow arrayref copy whose entries are the original
homogeneous L<PAGI::Routing::Middleware> descriptions, retaining their
identity. C<lifespan> returns a shallow hashref copy or C<undef>. There is no
C<app> accessor.

The source object stores configuration only. It never stores compiled
middleware, lifecycle phase, request scope, server state, or response events.

=head1 COMPILATION AND MIDDLEWARE ORDER

C<to_app> is the second phase: it synchronously calls C<to_app> once on the
constructed root Router, then builds fresh
author middleware wrappers, and fresh root safety wrappers after
constructor-time description validation, then returns one native PAGI
coderef. It performs no request or lifecycle I/O. Router component loading, middleware
construction, and wrapping failures therefore occur at C<to_app>. Calling
C<to_app> again builds an independent executable graph around the same root
Router identity and recompiles its app objects, although lexical state
deliberately captured by user coderefs remains ordinary shared Perl state.

For HTTP, the exact outer-to-inner order is:

  outer idempotent application-root HEAD wire boundary
    emergency ErrorHandler, server errors only
      the configured ErrorHandler's server-error boundary, if any
        response-completion guard
          first application middleware
            second application middleware
              an ErrorHandler's exception boundary
                Compose dispatcher
                  Compose root Router

The exception boundary is the configured ErrorHandler's; without one, the
emergency ErrorHandler's own (it has no C<catch> entries), unless a subclass
of ErrorHandler is among the application middleware.

The application-root HEAD boundary is outermost and idempotent with a directly
compiled Router's own HeadBoundary; the outermost participating boundary owns
wire suppression. Compose does not clone an ordinary HTTP scope or inspect
routing metadata. All response lifecycle observation is lexical to that
request. The completion guard observes events without copying or rewriting
them and accepts a terminal C<http.response.body> with absent or false C<more>,
including sendfile bodies.

WebSocket, SSE, lifespan, and application-defined extension scopes retain the
author stack and dispatcher path; they do not enter the HTTP ErrorHandler or
guard. The first author middleware listed remains outermost within that stack:

  first application middleware
    second application middleware
      Compose dispatcher
        lifespan driver or Compose root Router

Middleware scope changes are visible to callbacks and the root Router;
receive/send wrappers cover lifecycle events as well as request protocols. A
middleware that does not call inward owns that scope. Immediate and
Future-backed Router completion is accepted, and return values
are ignored because native PAGI events are the result channel. Normal HTTP
completion must include response start followed by a terminal body event.

=head1 LIFESPAN OWNERSHIP AND STATE

Compose owns C<lifespan> scopes and never delegates them to its root Router.
Only the deployed root owns lifecycle. A Compose application mounted
below a Router still dispatches request scopes, but Mount does not forward the
server's root lifespan exchange and its callbacks do not run. Lift required
initialization into the root composition; this is a documented ownership
convention, not automatic route-tree discovery. Router, Mount, and Route
middleware do not see lifespan; outer Compose middleware does. Do not put two
independent lifespan consumers around one deployed root.

Callbacks receive C<($state, $scope)>. C<$state> is the exact unblessed
hashref supplied by the server and C<$scope> is the middleware-adjusted raw
lifespan scope. Middleware may mutate that state but must preserve unknown
scope keys and may not fabricate or replace the state reference. Compose does
not create fallback state or copy state into request scopes; the server owns
that propagation.

Startup writes the raw hash; handlers read it through a read-only
L<PAGI::State> facade (C<< $request->state->get('db') >>). Each request scope
gets a shallow copy of the state, so a top-level key assigned after startup --
in a request, or by a timer that kept startup's C<$state> -- changes only one
copy and silently desyncs the rest. Store each shared object once in startup
and change it through its reference; see
L<PAGI::State/"WRITTEN AT STARTUP, READ THROUGH A FACADE">.

With callbacks configured, missing, malformed, replaced, or unprovable server
state prevents both callbacks from running and sends:

    {
        type    => 'lifespan.startup.failed',
        message => 'PAGI::Compose lifespan requires server state support',
    }

Without callbacks, ordinary startup and shutdown complete without requiring a
C<state> key.

A callback's return value is ignored unless it is a Future, which is awaited:
a callback may be a plain sub or an async sub. A synchronous exception or failed
Future from startup produces C<lifespan.startup.failed>; shutdown failure
produces C<lifespan.shutdown.failed>, using the exception text as C<message>.
A failed startup does not invoke shutdown. A startup callback that allocates
several resources before failing owns cleanup of that partial startup.
Receive/send channel failures propagate rather than provoking a second
protocol response. Exceptions thrown outside the lifecycle callbacks by
application middleware remain ordinary middleware failures. The HTTP safety
graph is not entered for lifespan.

=head1 HEAD REQUESTS

For HTTP HEAD, Compose's outer idempotent application-root boundary sits
outside the HTTP safety graph and all application middleware. A directly
compiled Router already installs its own HeadBoundary; the shared marker makes
the outermost participating boundary the wire owner. Middleware, Router outcome
renderers, and error renderers therefore complete the full representation
before wire suppression. Body-derived C<Content-Length>, compression metadata,
ETags, and similar headers survive for target, Router outcome, error, and
sendfile responses.

The boundary never rewrites HEAD to GET. Custom HEAD routes still receive
method C<HEAD>, so they can avoid an expensive GET handler. At the wire it
suppresses byte bodies, every chunk of a streaming body, file/sendfile body
events, and trailers, then emits one empty terminal body event. Response
start and other non-body events pass through unchanged, except that a start
event declaring C<< trailers => 1 >> is forwarded as a copy with that key
removed, since the suppressed wire never sends the trailers event it
promised.

L<PAGI::Middleware::Head> is an older explicit middleware that delegates its
own wire suppression to this same boundary, so stacking it under Compose is
harmless but redundant. It still unconditionally rewrites HEAD to GET before
the inner app runs, though, so it can bypass a custom HEAD route; do not
enable it accidentally.

=head1 ERRORS

Constructor validation and C<to_app> compilation errors are synchronous.
Every compiled Compose root has one unconditional HTTP safety boundary. There
is no public option to suppress, detect, configure, or disable it. Compose
looks at its author middleware only to find a stock ErrorHandler to split.

Routing outcomes belong to the root Router. When the innermost ErrorHandler
around it has C<catch> entries, the Router raises its 404 and 405 (with C<Allow>) as HTTP
errors to the exception boundary, as Starlette's router does; with no entry
for them they get the Router's own plain answers, unchanged. Compose does not
inspect routing metadata or turn a silent selected Route or Mount application
into a routing miss.
Normal completion without a valid response lifecycle throws
L<PAGI::Exception::IncompleteResponse>. Before response start, that exception,
request-target failures, failed Futures, author-middleware failures, and author
handler failures are converted to one plain-text, no-store 500. A selected
silent native application is therefore guarded as 500. An author handler
that itself fails is answered by ErrorHandler's final hardcoded UTF-8 text
500. Compose does not report the failure itself: once that 500
is complete it re-raises the original exception, and the server reports it
(L<PAGI::Spec::Www>, "Exceptions after the terminal event"). Explicit
application responses, including matched 404, 405, and 500, pass unchanged and
are neither raised nor reinterpreted.

The root ErrorHandler resolves C<PAGI_ENV> only while rendering an error.
Development responses may include the error diagnostic; production responses
remain generic. If environment resolution itself fails, the response uses safe
production output and ErrorHandler warns
C<PAGI ErrorHandler could not resolve development mode: ...>, a configuration
diagnostic. A normally complete native response does not consult the
environment or warn.

After response start, a thrown error or missing terminal body cannot be
replaced safely. Compose sends no second response start and rethrows the
original value so the server can abort the incomplete stream.
The completion guard never replaces an inner exception.

Install an ErrorHandler for the application's official error policy, and
wrap Compose in the middleware that must cover its responses:

    use PAGI::Middleware::AccessLog;
    use PAGI::Middleware::RequestId;
    use PAGI::Middleware::SecurityHeaders;
    use PAGI::Response qw(response);

    my $composed = compose(
        routes     => \@routes,
        middleware => [
            middleware('ErrorHandler',
                catch    => { 'PAGI::Exception::HTTP' => sub {
                    my ($request, $error) = @_;
                    return response('JSON', { error => $error->message },
                        headers => $error->exception->headers);
                } },
                handler  => \&server_error,
                on_error => \&report_error),
        ],
    );
    my $app = PAGI::Middleware::RequestId->new->wrap(
        PAGI::Middleware::AccessLog->new->wrap(
            PAGI::Middleware::SecurityHeaders->new->wrap($composed->to_app)));

The C<catch> entry answers the errors the application expects, routing 404
and 405 included; C<handler> answers the rest. The handler runs inside the
root last resort: if custom policy fails or leaves HTTP unanswered, the root
boundary still protects the deployed application. Both the author and root
error layers remain installed; an inner response makes the outer layer inert
rather than triggering a duplicate start. C<http_default> still answers a
routing 404 before any entry sees it. Lifespan callback failures retain
the separate lifespan failure-event behavior documented above, and non-HTTP
target failures retain their existing propagation behavior.

An ordinary author ErrorHandler has static C<development =E<gt> 0> behavior
unless configured otherwise and awaits immediate or Future-backed C<on_error>
reporting. Only Compose's private root instance resolves development mode
dynamically per handled request. Before response start a database throw or
failed Future may be rendered; after start the same failure is reported and
re-thrown without a second response.

There is no C<pages> option on Compose and no ambient renderer selection.
Install ordinary inner middleware as above when error presentation uses a
Pages subclass. The mandatory stock outer failsafes remain installed and
recover if an inner renderer fails.

=head1 RELATIONSHIP TO OTHER PAGI APIS

C<< compose(routes => [...]) >> is a compact deployed root: a newly constructed
Router plus application middleware, lifecycle, and HTTP safety. A directly compiled Router already owns
HTTP 404 and 405 outcomes and its own HeadBoundary, but it does not install
Compose's ErrorHandler, response guard, or lifespan driver. Preserving it with
C<< compose(routes => [mount('/' => app => $routing)]) >> adds an outer
Router, an idempotent application-root HEAD boundary, and those root policies.
For Router middleware, C<http_default>, C<desc>, identity, or Resolver state,
retain the Router behind that Mount instead of passing C<< $routing->routes >>.
Compose inspection delegates to its own root Router.

L<PAGI::Routing> is the routing-construction API. Compose accepts only
C<routes>; an immutable Router crosses that grammar as an explicit Mount
application. Compose does not wrap an arbitrary native app or general
C<to_app> component directly in this release.
Normal compiled handlers receive their direct Request, WebSocket, or SSE
object. Native applications and every middleware wrapper retain the exact
C<($scope, $receive, $send)> triplet; Compose does not adapt that boundary.
Compose remains the optional deployed root that can own application middleware
and server-provided lifespan state; it is not a fourth router. L<PAGI::Lifespan> and
L<PAGI::Utils/handle_lifespan> remain the low-level choices for hand-built
native applications or their existing hook-registration behavior.

=head1 STARLETTE COMPARISON

The influence is architectural, not source or API identity. Current Starlette
does not subclass C<Router>. Its app object owns C<self.router>,
delegates routing inspection, and wraps that Router with application
middleware. See the
L<official Starlette application source|https://github.com/Kludex/starlette/blob/main/starlette/applications.py>.

Starlette stores lifespan handling on Router, so a standalone Starlette Router
is lifecycle-capable. Mounted Starlette Routers do not receive lifespan:
Starlette Mount matches HTTP and WebSocket scopes only, leaving one root Router
to enter the lifespan context. See the
L<official routing source|https://github.com/Kludex/starlette/blob/main/starlette/routing.py>
and
L<routing tests|https://github.com/Kludex/starlette/blob/main/tests/test_routing.py>.

PAGI preserves that load-bearing non-cascading lifecycle but keeps its owner on
Compose. The PAGI root Router receives HTTP, WebSocket, and SSE, never the
root lifespan exchange, and Compose middleware rather than Router middleware
can observe lifespan. A bare PAGI Router deployment declines lifespan; a
server's strict mode rejects that decline. Mount the Router explicitly beneath
Compose when the root requires startup or shutdown. Compose does not add a
C<lifespan> option to Router.

Starlette's Mount is transparent to any mounted application that has
C<routes>, a mounted Starlette application included: reverse routing and
schema generation descend into it, and names inside it resolve against the
outermost router. A PAGI mount is transparent only to a Router; a mounted
Compose is a separate application whose names stay its own (see
L<PAGI::Routing/mount>). For documentation this is FastAPI's choice: its OpenAPI
generator skips mounts, and each mounted application serves its own.

Starlette's multiprotocol Router C<default> was also considered but not copied:
PAGI Router C<http_default> changes only HTTP NONE and preserves stock
WebSocket and first-class SSE misses.

=head1 SEE ALSO

L<PAGI::Routing>, L<PAGI::Routing::Router>, L<PAGI::Routing::Mount>,
L<PAGI::Routing::Middleware>, L<PAGI::Pages>, L<PAGI::Lifespan>, L<PAGI::Utils>,
L<PAGI::Tools::Tutorial>, L<PAGI::Tools::Cookbook>,
L<routing composition upgrade guide|https://github.com/jjn1056/PAGI-Tools/blob/main/UPGRADING-REFERENCE.md#routing-composition-redesign>

=cut
