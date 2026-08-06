package PAGI::Routing;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(router route websocket sse mount middleware);
our %EXPORT_TAGS = (
    routes     => [qw(router route websocket sse mount)],
    middleware => [qw(middleware)],
    ALL        => [@EXPORT_OK],
);

sub router {
    require PAGI::Routing::Router;
    return PAGI::Routing::Router->new(@_);
}

sub route {
    require PAGI::Routing::Route;
    return PAGI::Routing::Route->new('route', @_);
}

sub websocket {
    require PAGI::Routing::Route;
    return PAGI::Routing::Route->new('websocket', @_);
}

sub sse {
    require PAGI::Routing::Route;
    return PAGI::Routing::Route->new('sse', @_);
}

sub mount {
    require PAGI::Routing::Mount;
    return PAGI::Routing::Mount->new(@_);
}

sub middleware {
    require PAGI::Routing::Middleware;
    return PAGI::Routing::Middleware->new(@_);
}

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::Routing - Immutable declarative routing with Context handlers

=head1 SYNOPSIS

    use PAGI::Routing qw(:routes :middleware);

    use Future::AsyncAwait;
    use MyApp::Routes::Home ();

    my $logging = sub {
        my ($app) = @_;
        return $app;
    };

    my $routing = router(
        routes => [
            route('/' => \&MyApp::Routes::Home::home,
                name => 'home',
                desc => 'HTML landing page',
            ),
            mount('/api',
                routes => [
                    route('/users/{id}' => async sub {
                        my ($c) = @_;
                        return $c->json({ id => $c->path_param('id') });
                    },
                        name        => 'user',
                        constraints => { id => qr/\d+/ },
                    ),
                ],
                namespace => 'api',
            ),
        ],
        middleware => [
            $logging,
            middleware('RequestId', header => 'X-Request-ID'),
        ],
    );

    my $app = $routing->to_app;

=head1 DESCRIPTION

This module is a Starlette-inspired, Perlish alternative to
L<PAGI::App::Router>. Constructor functions build an immutable, inspectable
route tree. Normal HTTP handlers receive one L<PAGI::Context> and return one
L<PAGI::Response>; WebSocket and SSE handlers receive their corresponding
Context subclasses and use imperative protocol helpers. Explicit C<raw> forms
keep all three PAGI channels available when an endpoint needs to own events.

The descriptions do no request I/O. C<to_app> is the explicit compilation
boundary and returns the native PAGI coderef a server runs. This API is
additive: the mutable L<PAGI::App::Router> and class-based
L<PAGI::Endpoint::Router> remain supported.

=head1 IMPORTS

Nothing is exported by default.

=over 4

=item * C<:routes> exports C<router>, C<route>, C<websocket>, C<sse>, and C<mount>.

=item * C<:middleware> exports only C<middleware>.

=item * Uppercase C<:ALL> exports all six constructors. Lowercase C<:all> is invalid.

=back

L<PAGI::Middleware::Builder> exports its own unrelated C<mount> by default.
Do not import both under one name. A declarative application normally needs no
Builder; an outer composition file can import Builder selectively:

    use PAGI::Middleware::Builder qw(builder enable enable_if);
    use PAGI::Routing qw(:routes :middleware);

or load Builder without functions:

    use PAGI::Middleware::Builder ();

=head1 CONSTRUCTORS AND CODE POSITION

Coderef meaning comes only from its argument position. The router does not
inspect signatures or evaluate package-method strings.

    Form                         Called with                    Required result
    ---------------------------  -----------------------------  -------------------------
    route('/x' => $code)         ($c)                           PAGI::Response
    websocket('/x' => $code)     ($c)                           inert; completion awaited
    sse('/x' => $code)           ($c)                           inert; completion awaited
    route('/x', raw => $code)    ($scope, $receive, $send)      inert
    mount('/x' => $code)         ($scope, $receive, $send)      inert
    middleware => [$code]        ($inner_app), at to_app         PAGI app coderef
    middleware($code)            ($inner_app), at compile time  middleware description

=over 4

=item * C<< route('/x' =E<gt> $code) >> is a normal HTTP handler. It receives
C<($c)> and must return a Response, immediately or through a Future.

=item * C<< websocket('/x' =E<gt> $code) >> and
C<< sse('/x' =E<gt> $code) >> are normal imperative Context handlers. Their
completion is awaited and their resolved values are inert.

=item * C<< route('/x', raw =E<gt> $code) >>, and the corresponding
C<websocket> and C<sse> forms, are native PAGI applications. They receive
C<($scope, $receive, $send)> and own protocol events.

=item * C<< mount('/x' =E<gt> $code) >> is a native PAGI application or
component accepted by L<PAGI::Utils/to_app>. It receives a rewritten child
scope after its prefix matches.

=item * C<< middleware =E<gt> [$code] >> accepts a bare synchronous
compile-time factory. The enclosing middleware list calls it with
C<($inner_app)> at C<to_app> and it must return another native app coderef
immediately.

=item * C<middleware($code)> is a synchronous compile-time factory. It
receives the inner native app and must return another native app coderef
immediately.

=back

Load handlers from packages normally and pass a fully qualified coderef:

    use MyApp::Routes::Home ();
    route('/' => \&MyApp::Routes::Home::home);

There is no string evaluation or bound-method loader. Routing objects also
have no C<&{}> overload; call C<to_app> explicitly.

=head1 CONSTRUCTORS

=head2 router

    router(
        routes                 => \@nodes,
        middleware             => \@descriptors,
        not_found              => $handler,
        method_not_allowed     => $handler,
        desc                   => $text,
    )

The fallback values are ordinary HTTP Context handlers. The default handlers
return plain-text 404 and 405 responses.

=head2 route, websocket, sse

    route('/path' => $handler, %options)
    route('/path', raw => $app, %options)

    websocket('/path' => $handler, %options)
    websocket('/path', raw => $app, %options)

    sse('/path' => $handler, %options)
    sse('/path', raw => $app, %options)

All leaves accept C<name>, C<desc>, and C<middleware>. HTTP routes also accept
C<methods> and C<constraints>. C<methods> is one token, an arrayref, or the
explicit string C<*>; it defaults to GET. WebSocket and SSE routes reject it.

=head2 mount

    mount('/prefix' => $app, %options)
    mount('/prefix', routes => \@nodes, %options)

The first form is an opaque application mount. The second is an inline
declarative subtree and may add a dot C<namespace>. Both accept C<desc>,
C<constraints>, and C<middleware>. In the inline form C<routes> is the form
selector and therefore immediately follows the path.

=head2 middleware

    middleware($factory)
    middleware($configured_object)
    middleware($class, %config)

Creates an explicit middleware description for use in a routing object's
C<middleware> array. A target may be a synchronous factory coderef, an object
with C<wrap>, or a class name plus constructor configuration. Simple class
names resolve under C<PAGI::Middleware::>; C<^MyApp::Middleware> selects a
fully qualified caller-owned class.

Configuration is accepted only for class targets. Coderef factories capture
options in their closure, and objects are already configured.

A middleware list accepts two entry shapes: a bare factory coderef or an
explicit C<middleware(...)> description. Constructors normalize bare factories
when they build their immutable descriptions. The C<middleware> accessors on
routers, routes, and mounts expose descriptions only, never bare factories;
an explicit description keeps its identity.

The distribution deliberately provides no C<get>, C<post>, C<delete>, or
C<any> constructors. Common handler names would collide with C<get>/C<post>,
and C<delete> is a Perl builtin. One C<route> form handles standard, extension,
and application-defined methods uniformly.

=head1 COMPILATION AND REQUEST LIFECYCLE

C<< $routing->to_app >> validates and resolves native components, middleware
classes/factories, effective names, and match structures synchronously. Each
call builds a fresh wrapper graph; it does not mutate or cache on the source
description. Call it once for each intended application instance, retain the
coderef, and reuse that app for requests.

Middleware factories run once per compiled graph, not per request. Two
C<to_app> calls therefore get ordinary independent middleware instances.
Explicitly reused objects and closures still share the state their caller
chose to share. One compiled app safely keeps request paths, Allow sets,
Context objects, and metadata in request-local scope or lexicals during
concurrent requests.

At request time a normal HTTP handler builds and returns a Response. Routing
awaits an immediate or Future-backed result, validates it, and emits it exactly
once through the Context. A normal handler must not call C<respond> itself.
Use C<raw> when an endpoint must call C<$receive> or C<$send> and own event
emission.

Synchronous handlers run in the server's current execution context. Routing
never moves them into a worker or thread pool.

=head1 MATCHING

Nodes are scanned strictly in declaration order; there is no specificity sort.
For HTTP, a path-and-method match dispatches immediately. A path match with a
wrong method contributes its normalized methods to a request-local Allow set
and scanning continues, so a later full match still wins. If no full match
exists, a nonempty set selects the 405 handler; otherwise the 404 handler runs.
Allow retains first-seen order.

A matching mount owns the request immediately, including a child 404 or 405.
An earlier broad mount can therefore preempt a later narrow mount or route.
A failed mount constraint is no match and scanning continues.

Paths are exact: C</users> and C</users/> differ. There is no slash redirect or
normalization and no automatic OPTIONS response.

=head2 GET and HEAD

Omitted C<methods> means GET. Every GET route also accepts HEAD, inserted
immediately after GET in its normalized method list. To avoid an expensive GET,
declare a separate HEAD route first:

    route('/report' => \&head_report, methods => ['HEAD']),
    route('/report' => \&get_report,  methods => ['GET']),

This is ordinary declaration order. Reversing the pair makes GET's automatic
HEAD match win. If the explicit HEAD constraint rejects a request, scanning
continues to GET's automatic HEAD support.

The compiled router owns the HEAD wire boundary. Handlers and router
middleware still see C<method =E<gt> 'HEAD'> and the full response stream;
response starts and calculated headers are preserved, while body, sendfile,
streaming, and trailer events are suppressed and one empty terminal body is
sent.

Separately compiled declarative routers coordinate through a private
request-local scope marker. Only the outermost participating router suppresses
the wire stream, so enclosing parent-router, application-mount, and raw-route
middleware still sees the child router's full representation. Incoming scopes
are not mutated.

That guarantee includes middleware in the router's C<middleware> list. A
body-derived transformer wrapped I<outside> the compiled app sees the already
suppressed wire body and can produce a false C<Content-Length>, ETag, or
encoding. Put GZip, ContentLength, ETag, and similar response-transforming
middleware in the router list when using router-owned HEAD behavior.

=head2 Path parameters, wildcards, and constraints

Canonical parameters use C<{name}>. The familiar C<:name> and inline
C<{name:pattern}> forms are accepted, but explicit Perl constraints are
clearer:

    route('/users/{id}' => \&show,
        constraints => { id => qr/\d+/ },
    );

A constraint may be an anchored Perl regex, a synchronous unary predicate, or
a Type::Tiny-compatible object with C<check> and optional C<get_message>.
Regexes and inline patterns match the complete decoded value with C<\A> and
C<\z>. Predicates receive only that scalar. Constraints validate but never
coerce; false means no match, exceptions propagate, and a Future is rejected.

Inline patterns support ordinary regex comments C<(?#...)>, but their route
tokenizer is intentionally not a complete Perl regex parser. Put complex
patterns, especially extended-mode comments, in the explicit
C<constraints =E<gt> { name =E<gt> qr/.../ }> form.

A wildcard is one terminal whole segment:

    route('/files/*path' => \&files)

It may capture an empty remainder and may contain internal slashes. C</files/*path>
matches C</files/> but not C</files>; C</*path> is a real root catch-all.
Captured values are decoded, unsanitized input. Values such as C<..>, repeated
separators, and backslashes must never be concatenated with a document root.
File code must canonicalize, enforce containment at a component boundary, and
choose an explicit symlink policy; route matching is not filesystem security.

=head1 GENERATED OUTCOMES AND CATCH-ALLS

Before C<not_found>, the cached Context response has status 404. Before
C<method_not_allowed>, it has status 405 and the computed C<Allow>. Returning
C<< $c->text >>, C<< $c->html >>, or C<< $c->json >> uses that same response
and preserves the seed. If a custom 405 returns a detached response that still
has status 405 but no Allow, routing adds the computed field. It never replaces
an existing Allow or adds one after the handler changes status.

A selected route's 404 or 405 is application output and passes through
untouched. Router middleware sees generated responses; route middleware does
not run when no route fully matched. A matched inline mount's middleware sees
its subtree's generated outcome.

C<not_found> is not a catch-all route. A final C<< route('/*path' =E<gt> ...) >>
is a normal route with captures, middleware, and method matching. A GET-only
catch-all makes unknown non-GET paths 405. A C<methods =E<gt> '*'> catch-all can
beat partial matches and erase a 405. Keep catch-alls last and choose methods
deliberately.

=head1 MOUNTS

An inline mount is part of one known tree and inherits fallback handlers. An
application mount is opaque and owns every selected HTTP, WebSocket, and SSE
outcome. After a non-root prefix matches, the child scope receives the
remainder in C<path>, the actual decoded prefix appended to C<root_path>, and
merged captures in C<path_params>; C<raw_path> remains the original wire path.
An exact prefix produces child path C</>. A root mount consumes nothing and
leaves C<path>, C<root_path>, and C<raw_path> unchanged.

The decoded C<root_path> and consumed prefix are joined with exactly one slash
at their boundary; existing internal slashes are not normalized.

C<mount('/api')> accepts both C</api> and C</api/> at the mount boundary and
does not redirect. This deliberately differs from Starlette's default trailing
slash behavior.

A raw route and application mount both accept native apps, but select them
differently. C<< route('/files/*path', raw =E<gt> $app) >> is an HTTP leaf: it
participates in methods, automatic HEAD, partial matching, and named reverse
routing, and keeps the routed path. C<< mount('/files' =E<gt> $app) >> is a
protocol-capable prefix owner with an implicit remainder, no method filter,
rewritten child scope, and no inspectable child names.

=head1 MIDDLEWARE

All middleware here is pure PAGI app-to-app event middleware. At compile time,
a factory maps one native app to another. At request time the wrapper receives
only C<($scope, $receive, $send)>. There is no four-argument C<$next> form.

The first entry listed is outermost. Placement is:

    router middleware
      -> mount middleware
        -> separately compiled child-router middleware
          -> route middleware
            -> handler adapter

Route middleware runs only after a full route match. Scope rewriting and
matched-route metadata are installed before the matching mount/route wrapper.
See L<PAGI::Middleware::Helpers> for small channel wrappers that keep this
contract explicit.

=head1 REVERSE ROUTING AND INSPECTION

Names are optional. An inline mount's optional C<namespace> prefixes lookup
names with dots but is independent of its URL prefix. An unnamed mount leaves
child names unprefixed. Effective names must be unique; collisions identify
both paths and ask for a namespace.

    $routing->path_for('api.user', { id => 42 }, { tab => 'profile' });
    $c->path_for('api.user', { id => 42 });
    $c->url_for('api.user',  { id => 42 });

Router C<path_for> is request-independent. Context C<path_for> adds the
compiled-router entry C<root_path>; C<url_for> also selects HTTP(S) or WS(S)
from the route kind and uses L<PAGI::Authority> for a validated Host or server
fallback. Duplicate or malformed Host fields never fall back. Routing does not
parse Forwarded or X-Forwarded headers.

Scope C<root_path> is decoded Unicode. Context reverse routing percent-encodes
it component-wise while preserving slashes, then joins it to the resolver's
already escaped path without double-encoding route or query values.

For HTTP behind a trusted proxy, use this outer-to-inner order:

    ReverseProxy -> TrustedHosts -> PAGI::Routing

The shipped ReverseProxy and TrustedHosts middleware are currently HTTP-only
and pass WebSocket/SSE scopes through. Those protocols must arrive with
already normalized and validated scheme/authority data. Cross-protocol support
is planned separately; routing does not supply it.

The immutable tree is the public inspection surface:

    my $direct = $routing->routes;
    my $named  = $routing->named_routes;
    my $node   = $routing->route_named('api.user');

C<routes> contains only direct children in declaration order. Recursively call
C<routes> on inline mounts. Application mounts are opaque. Collection
accessors return shallow copies. C<desc> is a human note with no matching or
schema behavior.

=head1 MATCHED-ROUTE SCOPE CONVENTION

The compiled router reserves C<pagi.routing> and leaves the older
C<pagi.router> key untouched. The value is a read-only, versioned convention:

    {
        version => 1,
        frames  => [{
            resolver  => $resolver,
            root_path => '/proxy', # optional additive v1 field
            mounts    => [],
            match     => undef,
        }],
    }

Each compiled router installs a fresh request-local frame before router
middleware. C<root_path> records that router's entry boundary so inline mount
prefixes are not added twice during reverse generation. Older/manual v1 frames
may omit it, in which case Context reverse routing falls back to the current
scope C<root_path>. Inline mounts append records to C<mounts>. The exact public
record for one matched inline mount is:

    {
        path      => '/tenants/{tenant_id}', # declared mount path
        namespace => 'tenant',               # declared value or undef
        desc      => 'Tenant routes',         # declared value or undef
    }

All three keys are present. Nested inline mounts append these records in
outer-to-inner match order. The exact C<match> record for a selected leaf is:

    {
        kind  => 'route', # or websocket / sse
        route => '/tenants/{tenant_id}/users/{user_id}',
        name  => 'tenant.user.show',
        desc  => 'Display one tenant user',
    }

C<route> is the complete effective mounted route. C<name> is the complete
effective namespaced name, or undef for an unnamed leaf. C<desc> is that
leaf's declared description, or undef.

A selected opaque application mount uses the same four C<match> keys:

    {
        kind  => 'mount',
        route => '/admin/{tenant_id}', # complete effective mount path
        name  => undef,
        desc  => 'Tenant admin app',   # declared value or undef
    }

The opaque mount does not append an entry for itself to C<mounts>; its terminal
C<match> is the only record it adds. Generated 404/405 outcomes leave C<match>
undefined.

Compatible nested v1 routers copy the frame list and append a child frame.
Opaque, malformed, or newer C<pagi.routing> data is an incompatible boundary:
the child router creates a fresh v1 container, ignores foreign ancestry, and
does not croak. The incoming scope and foreign value are not mutated. This
lets independent extensions coexist without pretending their schemas are
compatible. Additive compatible fields, such as frame C<root_path>, retain
version 1.

The current frame is shared only through the router's request-local shallow
scope clones, allowing router/mount middleware to inspect the final match after
awaiting downstream. Treat the convention as read-only. Middleware outside
the compiled app receives its original top-level scope and cannot see
downstream top-level additions.

=head1 PROTOCOL OUTCOMES AND FAILURES

Unmatched SSE routes emit an SSE HTTP-decline 404. Unmatched WebSockets use the
HTTP-denial extension when advertised and otherwise close before acceptance.
Routing itself ignores lifespan scopes. At the deployed application root, use
L<PAGI::Compose> to combine the routing object, application middleware, and
startup/shutdown callbacks. L<PAGI::Lifespan> remains the lower-level wrapper
for native applications and its existing hook-registration behavior. Do not
put two independent lifespan consumers around one root. Unknown scope types
croak.

Construction and compilation errors are reported early where possible.
Request-time dispatch, constraint, raw-application, and middleware exceptions
propagate to an enclosing L<PAGI::Middleware::ErrorHandler>. The router does
not synthesize 500 responses; put that middleware at the application policy
boundary. A compile-time factory/configuration error instead fails C<to_app>
before an application exists to wrap.

=head1 ROUTER API COMPARISON

=over 4

=item * L<PAGI::Routing> uses the new immutable, declaration-ordered matcher.
HTTP handlers receive C<$c> and return Response values. Route middleware is
pure app-to-app event middleware. Its generated Allow order is first-seen.

=item * L<PAGI::App::Router> uses the existing mutable route-first,
mount-fallback matcher. Handlers are native PAGI applications and route
middleware is pure app-to-app event middleware. Its generated Allow order is
alphabetical.

=item * L<PAGI::Endpoint::Router> delegates matching to
PAGI::App::Router. Class methods receive C<($self, $c)> and HTTP methods return
Response values. It also ships specialized value-flow route middleware in
which C<< $next->() >> resolves to a Response.

=back

Allow represents a set; neither first-seen nor alphabetical rendering denotes
method priority.

=head1 SEE ALSO

L<PAGI::Tools::Cookbook>, L<PAGI::Context>, L<PAGI::Authority>,
L<PAGI::Compose>, L<PAGI::Middleware::Helpers>, L<PAGI::App::Router>,
L<PAGI::Endpoint::Router>

=cut
