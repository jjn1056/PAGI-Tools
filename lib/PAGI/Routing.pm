package PAGI::Routing;

use strict;
use warnings;
use Carp qw(croak);
use Exporter 'import';

our @EXPORT_OK = qw(router route websocket sse mount middleware request_response endpoint);
our %EXPORT_TAGS = (
    routes     => [qw(router route websocket sse mount)],
    middleware => [qw(middleware)],
    all        => [@EXPORT_OK],
);

sub router {
    require PAGI::Routing::Router;
    return PAGI::Routing::Router->new(@_);
}

sub route {
    my $declaration_package = caller;
    require PAGI::Routing::Route;
    return PAGI::Routing::Route->_new_from($declaration_package, 'route', @_);
}

sub websocket {
    my $declaration_package = caller;
    require PAGI::Routing::Route;
    return PAGI::Routing::Route->_new_from($declaration_package, 'websocket', @_);
}

sub sse {
    my $declaration_package = caller;
    require PAGI::Routing::Route;
    return PAGI::Routing::Route->_new_from($declaration_package, 'sse', @_);
}

sub mount {
    my $declaration_package = caller;
    require PAGI::Routing::Mount;
    return PAGI::Routing::Mount->_new_from($declaration_package, @_);
}

sub middleware {
    require PAGI::Routing::Middleware;
    return PAGI::Routing::Middleware->new(@_);
}

sub endpoint {
    require PAGI::Endpoint;
    return PAGI::Endpoint->new(@_)->endpoint;
}

sub request_response {
    croak 'request_response handler must be a coderef'
        unless @_ && ref($_[0]) eq 'CODE';
    my $handler = shift;
    croak 'request_response option list must be key/value pairs'
        if @_ % 2;
    require PAGI::Routing::RequestResponse;
    return PAGI::Routing::RequestResponse->new(
        handler => $handler,
        @_,
    );
}

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::Routing - Declarative routes for PAGI applications

=head1 SYNOPSIS

    use Future::AsyncAwait;
    use PAGI::Compose qw(compose);
    use PAGI::Response qw(response);
    use PAGI::Routing qw(:routes :middleware);
    use PAGI::Routing::URL qw(path_for);

    async sub list_notes {
        my ($request) = @_;
        return response('JSON', {
            notes => [],
            first => path_for($request, 'note', { id => 1 }),
        });
    }

    async sub show_note {
        my ($request) = @_;
        return response('JSON', { id => $request->path_param('id') });
    }

    async sub create_note {
        my ($request) = @_;
        my $note = await $request->json;
        return response('JSON', $note, status => 201);
    }

    async sub echo {
        my ($ws) = @_;
        await $ws->accept;
        await $ws->each_text(async sub {
            my ($text) = @_;
            await $ws->send_text("echo: $text");
        });
    }

    my $notes = router(
        routes => [
            route('/'          => \&list_notes,  name => 'list'),
            route('/'          => \&create_note, methods => ['POST']),
            route('/{id:\d+}'  => \&show_note,   name => 'note'),
        ],
        middleware => [middleware('RequestId')],
    );

    my $app = compose(routes => [
        mount('/notes', app => $notes, name => 'notes'),
        websocket('/echo' => \&echo),
    ]);

C<GET /notes/7> answers C<{"id":"7"}>, C<GET /notes/x> answers 404 and
C<PATCH /notes> answers 405 with C<Allow: GET, HEAD, POST>. Inside the
mount, C<path_for($request, 'note', ...)> names the sibling route and
gives C</notes/1>. Pass C<$app> to a PAGI server.

=head1 DESCRIPTION

Route matches a complete URL leaf. Mount composes an application under a
prefix. Router selects and owns routing outcomes. Middleware wraps
behavior. Compose owns the application root and lifespan.

C<route>, C<websocket> and C<sse> each describe one path and what handles
it; C<mount> hands every path under a prefix to another application;
C<router> holds an ordered list of both. The descriptions are immutable
and do no I/O. C<to_app> compiles them into the native PAGI application a
server runs, and L<PAGI::Compose> does that for you at the application
root. This is the one routing-construction API in PAGI-Tools.

This page has two parts. Everything before L</REFERENCE> is what an
application needs day to day. L</REFERENCE> has the complete rules for
constraint providers, compilation and the matched-route scope convention.
Rules about one class live with that class:

    PAGI::Routing::URL         path_for and url_for: references,
                               arguments, placement, root_path, proxies
    PAGI::Routing::Route       route options, methods, to_app
    PAGI::Routing::Mount       mount options, the child scope, to_app
    PAGI::Routing::Router      router accessors, path_for, to_app
    PAGI::Routing::Middleware  middleware descriptions and their reuse
    PAGI::Compose              the application root, lifespan, errors,
                               and the four ways to deploy a Router
    PAGI::Tools::Cookbook      recipes: custom 404s, mounts, catch-alls,
                               constraints, links inside a mount

=head1 RESPONSIBILITY BOUNDARIES

  Endpoint::HTTP/WebSocket/SSE  optional behavior for one exact route
  Route                         exact path and HTTP method policy
  Mount                         prefix ownership and app composition
  Router                        ordered children and NONE/PARTIAL outcomes
  Compose                       root lifespan, middleware, and safety

An ordinary package can expose C<routing()> when it owns a reusable
subtree; that method returns an immutable Router which a parent Mount
accepts directly. Endpoint classes are for HTTP verb dispatch or a
WebSocket/SSE lifecycle at one route. They are not Router frontends.

=head1 IMPORTS

Nothing is exported by default.

=over 4

=item * C<:routes> exports C<router>, C<route>, C<websocket>, C<sse>, and C<mount>.

=item * C<:middleware> exports only C<middleware>.

=item * C<request_response> is an explicit opt-in export. It is not included
in C<:routes> because it adapts a handler into an app object rather than
constructing a route-tree node.

=item * C<endpoint> is an explicit opt-in export in C<:all>, like
C<request_response>.

=item * C<:all> exports all public functions.

=back

L<PAGI::Middleware::Builder> exports an unrelated C<mount> by default. In a
file that needs both, import Builder's functions by name, as in
C<use PAGI::Middleware::Builder qw(builder enable enable_if)>, or load it
without functions: C<use PAGI::Middleware::Builder ();>.

=head1 HANDLERS

What a coderef means depends only on where it is placed. Routing never
inspects a sub's signature. Three rules cover every place:

=over 4

=item 1.

An HTTP handler receives one L<PAGI::Request> and returns an application
value, at once or through a Future: usually a L<PAGI::Response> or
L<PAGI::Pages> value, which routing sends exactly once. The handler never
sees C<$receive> or C<$send>, so it does not send events itself.

=item 2.

A WebSocket or SSE handler receives one L<PAGI::WebSocket> or L<PAGI::SSE>
and drives the connection through it. Routing awaits it and ignores what
it returns.

=item 3.

An app object (any object with a C<to_app> method), a coderef given to
C<mount>'s C<app>, and a coderef wrapped with
L<PAGI::Utils/as_app_object> are native PAGI applications. They receive
C<($scope, $receive, $send)> and send every event themselves.

=back

    Position                       A coderef is            An object is
    route endpoint, http_default   one Request handler     an app object
    websocket / sse endpoint       one WebSocket / SSE     an app object
                                   handler
    mount app                      a native application    an app object

Package-name strings are never applications. Load a handler's package
normally and pass a fully qualified coderef:

    use MyApp::Routes::Home ();
    route('/' => \&MyApp::Routes::Home::home);

Routing evaluates no strings and binds no methods, and routing objects
have no C<&{}> overload: call C<to_app> explicitly.

Two adapters cross positions. C<as_app_object> puts a native application
in a route or C<http_default>, for the rare endpoint that must send its
own events. L</request_response> puts a one-Request handler in C<mount>'s
C<app>. A handler that returns some other application hands the request
to it; L</Compilation and request lifecycle> says what that application
receives.

=head1 CONSTRUCTORS

The distribution deliberately provides no C<get>, C<post>, C<delete>, or
C<any> constructors. Common handler names would collide with C<get>/C<post>,
and C<delete> is a Perl builtin. One C<route> form handles standard, extension,
and application-defined methods uniformly.

=head2 router

    router(
        routes       => \@nodes,
        middleware   => \@middleware_entries,
        desc         => $text,
        http_default => $app,
    )

C<routes> is the ordered list of Route and Mount descriptions; C<middleware>
holds L</middleware> descriptions; C<desc> is a human note. C<http_default>
is a Pages value, a one-Request handler, or an app object (L</HANDLERS>);
construction validates it but does not compile it.

When no child matches, the Router calls C<http_default>, or answers a
plain-text C<404 Not Found> without one. When a path matches but its method
does not, it answers the built-in plain-text C<405 Method Not Allowed> with
one authoritative C<Allow> union. Inside an L<PAGI::Middleware::ErrorHandler>
that has C<catch> entries, the Router raises the 404 (when there is no
C<http_default>) and the 405 instead, as HTTP errors -- the 405 carrying
C<Allow> -- as Starlette's router raises C<HTTPException> inside an
application: to answer them differently, register a C<catch> entry for the
status or for C<PAGI::Exception::HTTP> (or put a middleware around the Router
that rewrites the responses). With no entry for them, they are answered with
these same plain responses, byte for byte.

=head2 route, websocket, sse

    route('/path' => $handler, %options)
    route('/path' => as_app_object($native), %options)
    route('/path' => $application_object, %options)
    route('/path' => endpoint('Class', %args), %options)

    websocket('/path' => $handler, %options)
    websocket('/path' => as_app_object($native), %options)

    sse('/path' => $handler, %options)
    sse('/path' => as_app_object($native), %options)

All leaves accept C<name>, C<desc>, C<meta> (see L</meta>), C<middleware>,
C<constraints>, and C<declaration_package>.
C<methods> is HTTP-only: one token, an arrayref, or the explicit string C<*>.
For an app object, an explicit finite method set still consults
C<allowed_methods> once during immutable Route construction and must be a
restriction of its normalized snapshot. Without explicit
methods, the snapshot is used directly; an endpoint without the capability
defaults to GET plus automatic HEAD. Only scalar C<< methods => '*' >> bypasses
the capability and makes the Route unrestricted. GET supplies HEAD, duplicates
are removed, and method tokens are canonicalized. WebSocket and SSE routes
reject C<methods>, never consult C<allowed_methods>, and use the same inline
and explicit path constraints as HTTP routes.

C<declaration_package> names the package an unqualified inline provider
(C<{id:&Int}>) is looked up in; it defaults to the constructor's direct
caller. A framework that wraps the constructor passes C<< scalar caller >>
(see L</Inline constraint providers>).

=head2 mount

    mount('/prefix', app => $app, %options)
    mount('/prefix', routes => \@nodes, %options)

All accept C<desc>, C<meta> (see L</meta>), C<constraints>, C<middleware>, and
C<declaration_package> (as for L</route, websocket, sse>). C<app> accepts a native
application coderef or app object. C<routes> creates a
real L<PAGI::Routing::Router> application and stores it as the Mount's C<app>.
Names are nonempty scalar logical segments: they may not contain C</> or
equal C<.> or C<..>. A dot in C<v1.1> is literal, not hierarchy.

A mount is a barrier to any application and transparent to a Router. A Router
(C<routes>, or C<app> given the Router itself) is a set of routes: they join
the enclosing application under the mount's prefix and name, in
C<route_table>, C<named_routes> and C<path_for>. Anything else -- a coderef, an
app object, a L<PAGI::Compose> or L<PAGI::App::Compose> -- is a separate
application:

=over 4

=item * C<route_table> shows it as one entry of kind C<mount>, and the
enclosing application's names cannot reach into it. Its handlers resolve only
its own names, rendered under the mount.

=item * What it does at application level stays inside it: its error
handling and application middleware apply to its own requests, and its
lifespan never runs (see L<PAGI::Compose/LIFESPAN OWNERSHIP AND STATE>).

=item * Its application middleware runs before its own routing, so it sees the
enclosing application's routing frame. Middleware that resolves route names,
such as a L<PAGI::Middleware::Requires> redirect, belongs on a route, mount or
Router inside it.

=item * Construction-time checks stop at the mount: a path parameter named both
in the mount's path and in the application's routes fails when a request
arrives, not when the application is built.

=back

Pass the Router itself to keep it transparent: C<< $router->to_app >>, or a
Router wrapped in middleware by hand, is an application. Give the mount
C<middleware> instead. Build the parts of one application as Routers and put
one Compose at the root.

C<mount> is for an application that owns a subtree. One that answers a single
path is a route: C<< route('/health' => $app) >> gives it exactly that path,
unchanged (its C<path> is still C</health>), and C<route_table> describes it as
one route.

=head2 meta

    mount('/notes', meta => { openapi => { tags => ['notes'] } }, routes => [
        route('/' => \&add_note, methods => ['POST'],
            meta => { openapi => { requestBody => { ... } } }),
    ]),

A hashref of descriptive data for tools that inspect routes, accepted by
every leaf and by C<mount>, in the manner of Magritte's meta-descriptions:
one declaration that several interpreters read. Its top-level keys are, by
convention, the consumer's namespace -- C<openapi> for an OpenAPI generator,
a framework's own name for its annotations -- and a value is anything: a
hash, an array, a description object its consumer interprets.

PAGI::Routing stores it (a shallow copy), hands it out through the node's
C<meta> accessor and C<route_table> (L<PAGI::Routing::RouteEntry>), and does nothing else with it: no key
is reserved or read, and it is not in the request-time match record. What
enforces something belongs in middleware; C<meta> describes. C<desc> is
unchanged: the route's one free-text note.

A mount whose application is a Router, given by C<routes> or as
C<< app => $router >>, is a I<Router mount>: its names join the parent's and
reverse routing reaches into it. Any other mount is an I<application mount>,
opaque to the parent.

Named and unnamed mounts use the same one-application representation:

    mount('/api', app => $child_router, name => 'api')
    mount('/public', routes => [ route('/status' => $handler) ])

An application Route is different:

    route('/files/*path' => as_app_object($app))
    mount('/files', app => $app)

The Route is one HTTP leaf: it participates in methods, automatic HEAD,
partial matching, and named reverse routing, and keeps the routed path. The
mount is a protocol-capable prefix owner with an implicit remainder, no method
filter, and a rewritten child scope.

C<mount('/api')> accepts both C</api> and C</api/> at the mount boundary and
does not redirect. This deliberately differs from Starlette's default trailing
slash behavior.
A page served at both C</admin> and C</admin/> resolves a relative link
differently (C<href="users"> is C</users> from the first and
C</admin/users> from the second); generate links with C<path_for>.

=head2 middleware

    middleware($factory)
    middleware($configured_object)
    middleware($class, %config)

Creates a L<PAGI::Routing::Middleware> description for use in a Router,
Route, Mount, or Compose C<middleware> array. Despite its name, this helper
does not wrap or invoke an application immediately. It records what should be
built later when C<to_app> compiles the application.

Core lists contain these descriptions only:

    Form                              Meaning
    --------------------------------  ---------------------------------
    middleware($class, %config)       deferred class construction
    middleware($factory, %config)     synchronous app-to-app factory
    middleware($object)               configured object with wrap

Class names may be short, nested short, already PAGI-qualified, or exact:

    middleware('RequestId')
    middleware('Authentication', backend => $backend)
    middleware('PAGI::Middleware::RequestId')
    middleware('+MyApp::Middleware::Audit')

Short and nested short names resolve under C<PAGI::Middleware::>; a leading
C<+> selects an exact fully qualified class. A class already defined --
declared in the application file, or loaded before -- is used as it is;
otherwise its file is loaded, and a name with no file, or a file that fails
to load, dies C<middleware('...'): cannot load ...> when the application is
built. Configuration is captured for
deferred class construction or passed to the synchronous factory; a configured
object accepts no additional description configuration. The C<middleware>
accessors on routers, routes, and mounts expose descriptions only.

A description is not a wrapper: reuse one by putting the same value in
several lists, never by passing it to C<middleware> again
(L<PAGI::Routing::Middleware/REUSING A DESCRIPTION>).

=head2 request_response

    request_response($handler, %options)

Adapts a one-Request handler into an app object, so it can sit in
C<mount>'s C<app>, where a coderef is a native application. Its optional
C<< request_factory => $coderef >> gives that one handler a Request subclass;
for the whole application, use L<PAGI::Middleware::RequestClass>. Ordinary
C<http_default> use does not need the adapter: a bare CODE there already
receives one Request. It never infers coderef arity.
L<PAGI::Routing::RequestResponse> has the details.

=head2 endpoint

    endpoint($class, %args)

    route('/notes' => endpoint('MyApp::Notes', page_size => 50))
    websocket('/chat' => endpoint('MyApp::Chat', hub => $hub))
    mount('/health', app => endpoint('MyApp::Health'))

Loads the class by its exact package name and returns the app object for a
route or mount; it is C<< PAGI::Endpoint->new($class, %args)->endpoint >>.
The class decides how it is built: with C<new> for each request or
connection, or through its C<BUILD_APP>. There is no default namespace and no leading C<+>, unlike
C<middleware>. See L<PAGI::Endpoint>.

=head1 MATCHING

Nodes are scanned strictly in declaration order; there is no specificity sort.
For HTTP, a path-and-method match dispatches immediately. A path match with a
wrong method contributes its normalized methods to a request-local method union
and scanning continues, so a later full match still wins. If no full match
exists, PARTIAL emits the Router's 405 with the nonempty method union;
otherwise NONE invokes the Router's HTTP default or stock 404. The method
union retains first-seen order and GET contributes HEAD.

A matching Mount owns the request immediately, including the 404 or 405 of a
Router mount. Those responses flow outward through child, occurrence, and
enclosing Router middleware, while the parent neither resumes sibling scanning
nor unions method evidence. An earlier broad Mount can therefore preempt a
later narrow Mount or route. A failed Mount constraint is no match and scanning
continues.

Paths are exact: C</users> and C</users/> differ. There is no slash redirect or
normalization and no automatic OPTIONS response.

Omitted C<methods> means GET, and every GET route also accepts HEAD. To
answer HEAD without running an expensive GET, declare a HEAD route before the
GET route (L<PAGI::Tools::Cookbook/Custom HEAD without Running an Expensive GET>).

=head2 Path parameters, wildcards, and constraints

Canonical parameters use C<{name}>. The familiar C<:name> and inline
C<{name:pattern}> forms are also accepted. Choose the constraint spelling that
keeps a declaration legible:

    # A short, path-local regex.
    route('/users/{id:\d+}' => \&show);

    # A reusable semantic constraint beside the parameter.
    use Types::Standard qw(Int);
    route('/users/{id:&Int}' => \&show);

    # A reusable object selected while constructing the route.
    route('/users/{id}' => \&show,
        constraints => { id => Int },
    );

    # A dynamic or declaration-local predicate.
    route('/users/{id}' => \&show,
        constraints => { id => sub { my ($value) = @_; ... } },
    );

Use an explicit C<constraints> hash for dynamically constructed,
subclass-dependent, or syntactically complex rules. Its value may be a Perl
regex, a synchronous unary predicate, or a Type::Tiny-compatible object with
C<check> and optional C<get_message>. Every leaf protocol and every mount form
uses the same path grammar and constraint behavior; only HTTP routes accept
C<methods>. An inline and explicit constraint may target the same parameter;
both must pass, inline first.

Constraints check a value; they never convert it. The handler gets the
decoded path segment as text, so C<{id:&Int}> matches both C</notes/9> and
C</notes/09>, and C<path_param('id')> is C<"9"> in one and C<"09"> in the
other: the two are not C<eq>, and a JSON response carries C<"09"> as a
string. Starlette's C<{id:int}> matches the same URLs but hands the handler
the number. Numify where a number is needed
(C<< 0 + $request->path_param('id') >>), or declare a pattern with one
spelling per number, such as C<{id:[1-9][0-9]*}> for positive integers
(C</notes/09>, C</notes/0> and C</notes/-3> do not match; use
C<{id:0|[1-9][0-9]*}> when zero is allowed).

A wildcard is one terminal whole segment:

    route('/files/*path' => \&files)

It may capture an empty remainder and may contain internal slashes.
C</files/*path> matches C</files/> but not C</files>; C</*path> is a real root
catch-all. Captured values are decoded, unsanitized input: never join one to a
document root. Prefer L<PAGI::App::File> or L<PAGI::Middleware::Static>;
L<PAGI::Tools::Cookbook/Constraint Forms and Wildcard Safety> shows a native
handler with its own file policy.

=head1 MIDDLEWARE AND HEAD

All middleware here is pure PAGI app-to-app event middleware. At compile time,
a factory maps one native app to another. At request time the wrapper receives
only C<($scope, $receive, $send)>. There is no four-argument C<$next> form.

The first entry listed is outermost. Placement is:

    router middleware
      -> mount middleware
        -> child Router middleware
          -> child Mount middleware
            -> route middleware
              -> handler adapter

Route middleware runs only after a full route match. Scope rewriting and
matched-route metadata are installed before the matching mount/route wrapper.
Mount middleware can therefore read dynamic mount captures.
A child-owned 404/405 response unwinds through the selected child Router and
Mount middleware without resuming the parent scan. The response crosses the
remaining enclosing middleware but no route middleware. WebSocket and SSE
retain their existing protocol ownership; Mounts do not adapt their events.
See L<PAGI::Utils::Middleware> for small channel wrappers that keep this
contract explicit.

The compiled router owns the HEAD wire boundary. Handlers and router
middleware still see C<method =E<gt> 'HEAD'> and the full response stream;
response starts and calculated headers are preserved, while body, sendfile,
streaming, and trailer events are suppressed and one empty terminal body is
sent. The one outermost L<PAGI::Routing::HeadBoundary> suppresses them, only
after every Router, mount and route middleware has observed the unsuppressed
GET representation.

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

=head1 REVERSE ROUTING AND INSPECTION

Every route and mount C<name> is one local logical segment. Slash
is the only hierarchy separator. For example:

    mount('/people/{person_id}',
        app       => $people,
        name      => 'person',
    )

and a child C<< route('/{item_id}' =E<gt> ..., name =E<gt> 'show') >> publish
C</person/show>. Logical addresses and URL paths are independent. An unnamed
mount contributes no address segment. A Mount has exactly one base application:
C<app> retains a declared application, while C<routes> constructs a child
Router application. A name is optional for either form.
A named Mount is itself an address: C<path_for('/static')> gives its prefix,
and C<< path_for('/static', { path => 'app.css' }) >> a path below it, with
prefix parameters and C<root_path> applied. C<path> is a reserved parameter
name there: a named Mount, and any Mount around one, may not declare a
C<path> parameter.

The composed resolver visits direct routes and Router base applications. Named
leaves and named Mounts must have unique absolute addresses. It croaks during
Router construction when two of them claim one address, naming both effective
URL patterns (a route and a Mount included: put the landing route inside the
Mount as C<route('/')>); when a path parameter repeats along one effective
ancestry; or when a pathological Router subclass creates a cycle, naming its
URL and logical mount ancestry. Sibling branches may reuse a parameter name or
child Router.

Inside a handler, import C<path_for> and C<url_for> from
L<PAGI::Routing::URL> and pass the Request, WebSocket, SSE, or scope:

    path_for($request, 'show', { item_id => 7 });
    url_for($request, '/person/show', { person_id => 42, item_id => 7 });

A reference beginning with C</> is absolute and inherits nothing; any other
is relative to the handler's namespace and inherits the captures its target
needs, such as C<person_id> above. Inheritance constructs a URL; it does not
authorize the target. A Router's own C<path_for> starts at that Router's root
and inherits no request captures (L<PAGI::Routing::Router/path_for>).
L<PAGI::Routing::URL> has the complete rules: reference normalization,
compact and named arguments, encoding, placement and C<root_path>, and
authority behind a proxy.

The immutable tree is the public inspection surface:

    my $direct = $routing->routes;
    my $named  = $routing->named_routes;
    my $node   = $routing->route_named('/person/show');

C<routes> contains only direct children in declaration order. C<named_routes>
maps canonical absolute addresses to original leaves and named Mounts, and
C<route_named>
resolves from the Router root. Router base applications are traversed.
Collection accessors return shallow copies. C<desc> is a human note with no
matching or schema behavior.

C<route_table> describes every route in the tree, named or not, as a
L<PAGI::Routing::RouteEntry>, depth-first in declaration order: its path
template and declared pattern, kind, methods, name and absolute address,
C<desc>, capture names and constraints as declared, the middleware around it
and its C<meta>. A route listing is a loop:

    for my $entry ($routing->route_table) {
        my $methods = $entry->methods;    # an arrayref, '*', or undef (WebSocket, SSE, mount)
        printf "%-10s %s\n", join(',', ref $methods ? @$methods : ($methods // $entry->kind)),
            $entry->template;
    }

It is what a tool that describes an application -- an OpenAPI document, a
listing, a test of its surface -- reads, without walking the tree itself.

Passing C<< $routing->routes >> to Compose flattens only its direct children
into a new root Router; L<PAGI::Compose/composition choices> says what that
drops and how to keep the Router instead.

=head1 OUTCOMES AND ERRORS

A selected route's 404 or 405 is application output and passes through
untouched; C<http_default> never replaces it. A selected application that
sends nothing, or a selected HTTP handler that returns no application value,
is an application error, not a routing miss.

Unmatched SSE and WebSocket routes emit ordinary HTTP 404 responses on their
original scopes before C<sse.start> or C<websocket.accept>. Missing and
unknown scope types croak before router middleware or channel I/O.

Request-time dispatch, constraint, application, and middleware exceptions
propagate to an enclosing L<PAGI::Middleware::ErrorHandler>. The router does
not synthesize 500 responses; put that middleware at the application policy
boundary. A compile-time factory/configuration error instead fails C<to_app>
before an application exists to wrap.

A catch-all is a real route, not a default: keep it last and choose its
methods deliberately (L<PAGI::Tools::Cookbook/Real Catch-All Routes>).

Direct C<< $routing->to_app >> is safe for Router outcomes but has no root
ErrorHandler, response-completion guard, or lifespan driver, and routing
itself ignores lifespan. Deploy through L<PAGI::Compose>, with the Router
behind C<< mount('/' => app => $routing) >>, when the application needs them
(L<PAGI::Compose/RELATIONSHIP TO OTHER PAGI APIS>).

=head1 REFERENCE

The complete rules behind the everyday API above. Most applications never
need them.

=head2 Compilation and request lifecycle

C<< $routing->to_app >> resolves native components, middleware
classes/factories, and executable match structures synchronously. Router
construction has already validated composed logical addresses, parameters,
and Router ancestry. Each
call builds a fresh wrapper graph; it does not mutate or cache on the source
description. Call it once for each intended application instance, retain the
coderef, and reuse that app for requests.

Middleware factories run once per compiled graph, not per request. Two
C<to_app> calls therefore get ordinary independent middleware instances.
Explicitly reused objects and closures still share the state their caller
chose to share. One compiled app safely keeps request paths, method unions,
Request/protocol objects, routing metadata, and outcome state in request-local
scope or lexicals during concurrent requests.

At request time a normal HTTP handler returns a native CODE or instantiated
C<to_app> object, immediately or through a Future. Routing validates and
invokes that application once against the original triplet. The handler
receives neither C<$receive> nor C<$send>; return a Response or Pages
application for the ordinary case. Use C<as_app_object> at declaration time when an
endpoint itself must call C<$receive> or C<$send> and own event emission.

Returning an arbitrary application is advanced delegation. It receives the
unchanged HTTP, WebSocket, or SSE scope and remaining body stream; body events
already consumed by the handler are not replayed. It receives no lifespan
replay, and its routes, names, constraints, and schema metadata are opaque to
the outer Router. A returned object's C<to_app> is called once per handler
invocation, so static or expensive applications belong directly in Route,
Mount, C<http_default>, or Compose.

Synchronous handlers run in the server's current execution context. Routing
never moves them into a worker or thread pool; blocking work blocks that event-
loop thread.

=head2 Inline constraint providers

An inline source beginning with an unescaped C<&> declares a provider, not a
regex. The complete source must be C<&> followed by an optional Perl package
prefix and a terminal function name beginning with ASCII C<A> through C<Z>:

    '/{id:&Int}'
    '/{id:&PersonId}'
    '/{id:&MyApp::Types::PersonId}'

Lowercase terminal names, whitespace, expressions, arguments, methods, and
partial regex/provider mixtures are invalid and croak during construction.
The entire unescaped-leading-C<&> space is reserved so spellings such as
C<&int>, C<&Int >, C<&[A-Z]+>, and C<&Foo::lower> never silently fall back to
regexes.

To match a literal leading ampersand, use the canonical regex spelling
C<[&]Int> or C<[&][A-Z]+>. A backslashed alternative works only when the Perl
string preserves it:

    route('/{value:[&]Int}' => \&show);  # recommended
    route('/{value:\&Int}'  => \&show);  # single-quoted string

In a double-quoted Perl string, C<< "\&Int" >> becomes C<&Int> and therefore
requests the provider.

An unqualified provider resolves to the exact symbol-table CODE slot in the
package that directly called C<route>, C<websocket>, C<sse>, or C<mount>.
An ordinary Exporter alias leaves the consuming package as the caller. A real
wrapper sub and a role-defined method make their own defining package the
declaration boundary; invoking such code through a subclass does not rebind
it. Use a fully qualified spelling when reusable declarations must name an
external provider exactly.

A framework that wraps C<route>, C<websocket>, C<sse> or C<mount> in its own
sugar is that wrapper package, so an application's C<{id:&Int}> would be
looked up in the framework. The wrapper names the application instead:

    sub get {
        my ($path, $handler, @options) = @_;
        return route($path => $handler, @options,
            declaration_package => scalar caller);
    }

C<declaration_package> names one package; lookup still never falls back to
another.

Qualified packages must already be loaded. Lookup never searches C<@ISA>,
dispatches methods, invokes C<AUTOLOAD>, loads a module, consults
C<Type::Registry>, evaluates the spelling, or falls back after a miss.

Construction invokes each provider occurrence once with no arguments or
invocant. It must return a regex, predicate coderef, or blessed C<check>
object; an exception, Future, or other value fails construction. If a provider
returns a coderef, that returned coderef is the per-value predicate: the
provider itself is not passed path values and never runs during matching,
C<path_for>, or C<url_for>. Providers should therefore be deterministic and
free of request-specific side effects.

All three returned shapes and all explicit constraints normalize once to a
private predicate coderef with an optional error explainer. Composed Mounts and
Router base applications preserve those exact predicates rather than reparsing paths,
calling providers again, or applying explicit constraints twice.

=head2 Validation semantics and Type::Tiny

Regexes and inline patterns match the complete decoded value with C<\A> and
C<\z>. Predicates receive only that scalar. Constraints validate but never
coerce; false means no match, exceptions propagate, and a Future predicate is
rejected. Database or resource checks belong in middleware or the handler.
Matching, C<path_for>, and C<url_for> enforce the same normalized predicates
for HTTP, WebSocket, and SSE names.

C<Types::Standard> works without a registry because an imported function such
as C<Int> returns a C<check>-compatible object when called with no arguments.
Its own semantics apply: C<Int> accepts a leading minus sign, and PAGI still
passes the original decoded string to the handler. Applications needing a
positive identifier can expose a local capitalized zero-argument provider:

    sub PersonId {
        my $int = Int;
        return sub {
            my ($value) = @_;
            return $int->check($value) && $value > 0;
        };
    }

    route('/people/{id:&PersonId}' => \&show);

Type::Tiny is not a PAGI::Tools runtime dependency.

Inline patterns support ordinary regex comments C<(?#...)>, but their route
tokenizer is intentionally not a complete Perl regex parser. Put complex
patterns, especially extended-mode comments, in the explicit
C<constraints =E<gt> { name =E<gt> qr/.../ }> form.

=head2 MATCHED-ROUTE SCOPE CONVENTION

The compiled router reserves C<pagi.routing> and leaves the older
C<pagi.router> key untouched. The value is a read-only, versioned convention:

    {
        version => 1,
        frames  => [{
            resolver          => $resolver,
            root_path         => '/proxy', # optional additive v1 field
            logical_namespace => '/',
            captures          => {},       # private reverse-routing snapshot
            mounts            => [],
            match             => undef,
        }],
    }

Each compiled router installs a fresh request-local frame before Router
middleware. C<root_path> records that router's entry boundary so known mount
prefixes are not added twice during reverse generation. Older/manual v1 frames
may omit it, in which case scope-bound reverse routing falls back to the current
scope C<root_path>. C<logical_namespace> is the active containing namespace;
C<captures> is a fresh, unaliased working snapshot used only for relative
scope-bound reverse routing. A matched Router mount (C<routes>, or C<app>
holding a Router) appends this record to C<mounts>; an application mount does
not, and records itself only as the terminal C<match>.

    {
        path      => '/tenants/{tenant_id}', # declared mount path
        name      => 'tenant',                # declared value or undef
        desc      => 'Tenant routes',         # declared value or undef
    }

All three keys are present. Nested Mounts append these records in
outer-to-inner match order. The exact C<match> record for a selected leaf is:

    {
        kind              => 'route', # or websocket / sse
        route             => '/tenants/{tenant_id}/users/{user_id}',
        name              => '/tenant/show',
        logical_namespace => '/tenant',
        desc              => 'Display one tenant user',
    }

C<route> is the complete effective mounted route. C<name> is the complete
absolute logical address, or undef for an unnamed leaf.
C<logical_namespace> is available even when C<name> is undef. The declaration
object's C<< Route->name >> remains only its local final segment, such as
C<show>; matched metadata C<name> is absolute. C<desc> is that leaf's declared
description, or undef.

A selected application mount uses the same match shape:

    {
        kind              => 'mount',
        route             => '/admin/{tenant_id}', # complete effective mount path
        name              => undef,
        logical_namespace => '/',
        desc              => 'Tenant admin app',   # declared value or undef
    }

C<match> is the selected mount's terminal record. Router NONE/PARTIAL outcomes
leave C<match> undefined while retaining the namespace and consumed-prefix
capture snapshot of their owning placement. The Router renders the resulting
404 or 405 without inventing a selected leaf.

Entering a Router mount appends a distinct child boundary frame.
It shares the root Resolver and root entry C<root_path> while copying the
selected placement's logical namespace, captures, and cumulative Mount chain.

An application mount retains its terminal Mount match in the parent
frame. If that native target is another separately compiled Router, the child
Router appends a frame to a compatible container with its own Resolver and its
own entry C<root_path>; L<PAGI::Routing::URL> selects that innermost compatible
frame.
Malformed or newer C<pagi.routing> data is an incompatible boundary:
the child router creates a fresh v1 container, ignores foreign ancestry, and
does not croak. The incoming scope and foreign value are not mutated. Additive
compatible fields, such as frame C<root_path>, retain version 1.

The current frame is shared only through the router's request-local shallow
scope clones, allowing router/mount middleware to inspect the final match after
awaiting downstream. Treat the convention as read-only. Middleware outside
the compiled app receives its original top-level scope and cannot see
downstream top-level additions.

=head2 DELIBERATE DIFFERENCES FROM STARLETTE

Starlette supplied the useful Route/Mount/Router vocabulary, but PAGI does not
claim API identity. Ordinary PAGI route and C<http_default> handlers receive
one direct Request; C<as_app_object($code)> marks a native Route or
C<http_default> CODE, while Mount C<app> CODE is a native three-channel
application position. Compose instead accepts route declarations through C<routes>, or
an existing immutable Router as the application of an explicit Mount inside
that C<routes> list. Package strings are not coerced in those positions.
Middleware strings remain supported because middleware descriptors define an
explicit loading, construction, configuration, and C<wrap> contract.

PAGI constraints validate a decoded scalar without coercing it. Logical names
use slash addresses with scope-bound L<PAGI::Routing::URL> lookup rather than
Starlette's colon mount namespace. SSE is a first-class routed scope.
Middleware is pure PAGI app-to-app wrapping at Router, Mount, Route, and
Compose boundaries.

Starlette's single multiprotocol Router C<default> was considered and
deliberately not copied. PAGI's C<http_default> handles only HTTP NONE,
leaving stock WebSocket and SSE miss behavior intact. OpenAPI generation,
C<schema> and C<include_in_schema> are left to a consumer: C<route_table> (L<PAGI::Routing::RouteEntry>)
and L</meta> are what one reads, and PAGI::Routing interprets neither.

=head1 SEE ALSO

=over 4

=item * L<PAGI::Routing::URL> - C<path_for> and C<url_for>: references, arguments, placement, proxies

=item * L<PAGI::Routing::Route>, L<PAGI::Routing::Mount>, L<PAGI::Routing::Router> - each description's options, accessors and C<to_app>

=item * L<PAGI::Routing::Middleware> - middleware descriptions and their reuse; L<PAGI::Routing::RequestResponse> - the one-Request adapter

=item * L<PAGI::Compose> - the application root: lifespan, errors, composition choices

=item * L<PAGI::Tools::Cookbook> (routing recipes), L<PAGI::Tools::Tutorial> (Part 2)

=item * L<PAGI::Request>, L<PAGI::WebSocket>, L<PAGI::SSE>, L<PAGI::Response>, L<PAGI::Pages>, L<PAGI::Authority>, L<PAGI::Utils::Middleware>

=item * L<routing composition upgrade guide|https://github.com/jjn1056/PAGI-Tools/blob/main/UPGRADING-REFERENCE.md#routing-composition-redesign>

=back

=cut
