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

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::Routing - Immutable declarative routing with Context handlers

=head1 SYNOPSIS

    use PAGI::Routing qw(:routes :middleware);
    use PAGI::Compose qw(compose);

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
                name => 'api',
            ),
        ],
        middleware => [
            $logging,
            middleware('RequestId', header => 'X-Request-ID'),
        ],
    );

    my $app = compose(app => $routing)->to_app;

=head1 DESCRIPTION

This module is the immutable functional frontend for PAGI's shared routing
engine. Constructor functions build an immutable, inspectable route tree.
Normal HTTP handlers receive one L<PAGI::Context> and return one
L<PAGI::Response>; WebSocket and SSE handlers receive their corresponding
Context subclasses and use imperative protocol helpers. Explicit C<raw> forms
keep all three PAGI channels available when an endpoint needs to own events.

The descriptions do no request I/O. C<to_app> is the explicit compilation
boundary and returns the native PAGI coderef a server runs. The mutable
L<PAGI::App::Router> and method-oriented L<PAGI::Endpoint::Router> materialize
this same Router model and use the same Resolver and Compiler.

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
    mount('/x', app => $code)    ($scope, $receive, $send)      inert
    middleware => [$entry]       ($inner_app), at to_app         PAGI app coderef
    middleware($target, %config) ($inner_app), at compile time    PAGI app coderef

=over 4

=item * C<< route('/x' =E<gt> $code) >> is a normal HTTP handler. It receives
C<($c)> and must return a Response, immediately or through a Future.

=item * C<< websocket('/x' =E<gt> $code) >> and
C<< sse('/x' =E<gt> $code) >> are normal imperative Context handlers. Their
completion is awaited and their resolved values are inert.

=item * C<< route('/x', raw =E<gt> $code) >>, and the corresponding
C<websocket> and C<sse> forms, are native PAGI applications. They receive
C<($scope, $receive, $send)> and own protocol events.

=item * C<< mount('/x', app =E<gt> $code) >> is a native PAGI application or
component accepted by L<PAGI::Utils/to_app>. It receives a rewritten child
scope after its prefix matches.


=item * A C<middleware> list accepts four forms per occurrence: a class name,
a bare synchronous factory coderef, a configured object with C<wrap>, or an
explicit C<middleware(...)> description. Construction normalizes them to
descriptions without loading classes, constructing objects, calling C<wrap>,
or performing protocol I/O.

=item * Compilation at C<to_app> resolves those descriptions. A factory or
object receives C<($inner_app)> directly or through C<wrap>; a class is loaded
and constructed, then wrapped. Each must return another native app coderef
immediately. C<middleware($class, %config)> is required only for configured
classes and is also useful for explicit reuse or inspection.

=back

Load handlers from packages normally and pass a fully qualified coderef:

    use MyApp::Routes::Home ();
    route('/' => \&MyApp::Routes::Home::home);

There is no string evaluation or bound-method loader. Routing objects also
have no C<&{}> overload; call C<to_app> explicitly.

Inline constraint providers are resolved in the package that directly calls
the constructor. A re-exported constructor therefore uses the consuming
package, while a wrapper sub or role method uses the package in which that
wrapper or method was defined.

=head1 CONSTRUCTORS

=head2 router

    router(
        routes     => \@nodes,
        middleware => \@middleware_entries,
        desc       => $text,
        http_default => $app,
    )

Routes describe endpoint leaves, Mount describes one prefixed application, and
Router describes an ordered collection of Route and Mount descriptions. An
optional C<http_default> declares an HTTP application; construction validates
it but does not compile it. Directly compiled Routers publish request-local trusted routing evidence for
HTTP selection. Unmatched and method-mismatched requests complete normally
without sending a response. Install ordinary C<Routing::NotFound> and
C<Routing::MethodNotAllowed> middleware at a Router, routing-aware Mount, or
enclosing application boundary to render that evidence. WebSocket, SSE, and
lifespan scopes do not install or alter HTTP routing evidence.

The evidence snapshot reports facts: whether routing declined, whether a path
or method matched, the first-seen allowed-method union, and bounded development
attempts. It never reports a status or outcome decision. The trace is passed
explicitly to fallback handlers. L<PAGI::Context> intentionally gains no
C<routing_trace>, C<not_found>, or C<method_not_allowed> method because Context
also serves native applications and third-party routers that do not publish
this first-party contract.

=head2 route, websocket, sse

    route('/path' => $handler, %options)
    route('/path', raw => $app, %options)

    websocket('/path' => $handler, %options)
    websocket('/path', raw => $app, %options)

    sse('/path' => $handler, %options)
    sse('/path', raw => $app, %options)

All leaves accept C<name>, C<desc>, C<middleware>, and C<constraints>.
C<methods> is HTTP-only: one token, an arrayref, or the explicit string C<*>;
it defaults to GET. WebSocket and SSE routes reject C<methods> but use the same
inline and explicit path constraints as HTTP routes.

=head2 mount

    mount('/prefix', app => $app, %options)
    mount('/prefix', routes => \@nodes, %options)

The two mutually exclusive forms are:

    Form                    Base application             Name
    ----------------------  ---------------------------  ------------------------
    '/x', app => $app       retained exactly             optional local segment
    '/x', routes => [...]   new child Router application  optional local segment

All accept C<desc>, C<constraints>, and C<middleware>. C<app> accepts a native
application coderef or instantiated object with C<to_app>. C<routes> creates a
real L<PAGI::Routing::Router> application and stores it as the Mount's C<app>.
Names are nonempty scalar logical segments: they may not contain C</> or
equal C<.> or C<..>. A dot in C<v1.1> is literal, not hierarchy.

Named and unnamed mounts use the same one-application representation:

    mount('/api', app => $child_router, name => 'api')
    mount('/public', routes => [ route('/status' => $handler) ])

Positional targets and C<router> are not accepted.

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

A middleware list accepts four entry shapes: a class name, a bare factory
coderef, a configured object with C<wrap>, or an explicit
C<middleware(...)> description. Constructors normalize all four at description
construction, without performing protocol I/O. The C<middleware> accessors on
routers, routes, and mounts expose descriptions only; explicit descriptions
keep their identity while each bare occurrence receives a fresh description.
C<middleware($class, %config)> is required only for configured classes and is
otherwise useful for explicit reuse or inspection.

The distribution deliberately provides no C<get>, C<post>, C<delete>, or
C<any> constructors. Common handler names would collide with C<get>/C<post>,
and C<delete> is a Perl builtin. One C<route> form handles standard, extension,
and application-defined methods uniformly.

=head1 COMPILATION AND REQUEST LIFECYCLE

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
Context objects, routing Trace objects, and metadata in request-local scope or
lexicals during concurrent requests.

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
wrong method contributes its normalized methods to a request-local method union
and scanning continues, so a later full match still wins. If no full match
exists, routing records a PARTIAL decline with the nonempty method union;
otherwise it records a NONE decline. Both complete without calling C<$send>.
The method union retains first-seen order and GET contributes HEAD.

A matching Mount owns the request immediately, including an unanswered child
decline. An earlier broad Mount can therefore preempt a later narrow Mount or
route. A failed Mount constraint is no match and scanning continues.

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

=head3 Inline constraint providers

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

=head3 Validation semantics and Type::Tiny

Regexes and inline patterns match the complete decoded value with C<\A> and
C<\z>. Predicates receive only that scalar. Constraints validate but never
coerce; false means no match, exceptions propagate, and a Future predicate is
rejected. Matching, C<path_for>, and C<url_for> enforce the same normalized
predicates for HTTP, WebSocket, and SSE names.

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

Inline provider references are specific to this declarative
L<PAGI::Routing> API. L<PAGI::App::Router> retains its existing
C<{name:pattern}> grammar, where the C<&Int> text is regex syntax matching a
literal ampersand spelling. Translate constraints explicitly when moving a
declaration between the two routers.

A wildcard is one terminal whole segment:

    route('/files/*path' => \&files)

It may capture an empty remainder and may contain internal slashes. C</files/*path>
matches C</files/> but not C</files>; C</*path> is a real root catch-all.
Captured values are decoded, unsanitized input. Values such as C<..>, repeated
separators, and backslashes must never be concatenated with a document root.
File code must canonicalize, enforce containment at a component boundary, and
choose an explicit symlink policy; route matching is not filesystem security.
Prefer L<PAGI::App::File> or L<PAGI::Middleware::Static> to using a wildcard
capture as a filesystem path.

=head1 HTTP DECLINES, FALLBACK MIDDLEWARE, AND CATCH-ALLS

A selected route's 404 or 405 is application output and passes through
untouched. A selected raw route or opaque Mount that sends nothing is also a
selected application completion, not a routing decline. A selected normal
HTTP handler must still return a Response; an invalid return remains an
application error.

When MethodNotAllowed renders a trusted method partial as 405, it emits exactly
one authoritative C<Allow> field from the snapshot's deterministic first-seen
union; GET contributes HEAD. The renderer reads C<allowed_methods> from the
snapshot rather than mutable Context headers. An explicit handler/native 405
remains application output and is never repaired by an outer fallback.

Router middleware surrounds that Router's own decline. Middleware on an inline
or Router Mount surrounds the already-selected child boundary, and the parent
never resumes scanning. Put C<Routing::NotFound> or
C<Routing::MethodNotAllowed> middleware at the boundary that owns response
policy. Route placement is inert for exhaustion because route middleware runs
only after that route fully matches.

Direct C<< $routing->to_app >> is therefore a lower-level component spelling.
Use C<< compose(app => $routing)->to_app >> for a complete deployed HTTP
application. An application Mount or raw route shields the parent
routing-evidence channel; if its selected native target sends nothing, Compose
treats that as incomplete output and renders 500 rather than inventing a 404.

L<PAGI::Pages> supplies terminal negotiated endpoints without a Router-specific
adapter:

    use PAGI::Pages;

    route('/old' => PAGI::Pages->permanent_redirect('/new'));
    mount('/gone', app => PAGI::Pages->gone);

The first is still one exact, method-aware route. The second owns the complete
C</gone> subtree for every HTTP method and ignores the remaining child path.
Choose C<route> or C<mount> for that routing boundary, not merely because both
accept the same Pages coderef.

C<not_found> is not a catch-all route. A final C<< route('/*path' =E<gt> ...) >>
is a normal route with captures, middleware, and method matching. A GET-only
catch-all makes unknown non-GET paths 405. A C<methods =E<gt> '*'> catch-all can
beat partial matches and erase a 405. Keep catch-alls last and choose methods
deliberately.

=head1 MOUNTS

Every Mount is a selected application boundary within its containing Router.
C<routes> is shorthand for a child Router application; C<app> retains a
declared base application. Once its prefix matches, the child owns FULL,
PARTIAL, and NONE: unanswered child completion bubbles outward through child,
occurrence, and enclosing Router middleware, while the parent neither resumes
sibling scanning nor unions method evidence. A child or occurrence fallback
response makes later outer fallback middleware inert. A raw route is different
again:

    route('/files/*path', raw => $app)
    mount('/files', app => $app)

The raw route is one HTTP leaf: it participates in methods, automatic HEAD,
partial matching, and named reverse routing, and keeps the routed path. The
mount is a protocol-capable prefix owner with an implicit remainder, no method
filter, and a rewritten child scope.

After a non-root mount prefix matches, the child scope receives the remainder
in C<path>, the actual decoded prefix appended to C<root_path>, and merged
captures in C<path_params>; C<raw_path> remains the original wire path. An
exact prefix produces child path C</>. A root Mount consumes no prefix and
leaves C<path>, C<root_path>, and C<raw_path> unchanged.

The decoded C<root_path> and consumed prefix are joined with exactly one slash
at their boundary; existing internal slashes are not normalized.

C<mount('/api')> accepts both C</api> and C</api/> at the mount boundary and
does not redirect. This deliberately differs from Starlette's default trailing
slash behavior.

=head1 MIDDLEWARE

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
A child-owned NONE/PARTIAL decline unwinds through the selected child Router
and Mount middleware without resuming the parent scan. When fallback
middleware renders it, the response crosses the remaining enclosing
middleware but no route middleware. The one outermost
L<PAGI::Routing::HeadBoundary> removes the final HEAD body, including sendfile
events, only after every Router/mount/route middleware has observed the
unsuppressed GET representation. WebSocket and SSE retain their existing
protocol ownership; Mounts do not adapt their events.
See L<PAGI::Middleware::Helpers> for small channel wrappers that keep this
contract explicit.

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

The composed resolver visits direct routes and Router base applications. Named
leaves must have unique absolute addresses. It croaks during Router
construction when two leaves claim one address (naming both effective URL
patterns), when a path parameter repeats along one effective ancestry, or when
a pathological Router subclass creates a cycle (naming its URL and logical
mount ancestry). Sibling branches may reuse a parameter name or child Router.

References use exact filesystem-like normalization:

    /person/blog/show   absolute from this resolver root
    show                relative to the current containing namespace
    blog/show           child of that namespace
    ./show              same namespace
    ../show             parent namespace
    blog/../show        normalized left to right

Empty or repeated segments, trailing slashes, traversal above root, unknown
exact addresses, and results ending at a namespace rather than a named leaf
croak. Resolution never searches ancestors, retries an absolute spelling, or
folds overlapping prefixes. References are not URI-decoded. A dot within one
segment, such as C<v1.1>, stays literal.

For a named leaf, the current containing namespace is its absolute address
without the final local name. An unnamed leaf, including a catch-all, uses the
namespace contributed by its enclosing known Mounts. An unanswered decline
uses the owning Router placement and captures only prefixes actually consumed;
it does not borrow an arbitrary partial leaf.

All reverse helpers accept compact and named argument forms:

    $routing->path_for('/person/show', { person_id => 42 });
    $c->path_for('show', { person_id => 42 }, { tab => 'profile' });
    $c->url_for('show', {}, {}, 'details');
    $c->url_for('show',
        query    => { tab => 'profile' },
        fragment => 'details',
    );

Compact order is C<(\%params, \%query, $fragment)>; empty hashrefs are
placeholders when a component is skipped. In the named form C<params>,
C<query>, and C<fragment> are optional and order-independent. A first trailing
hashref selects compact form; a first trailing defined plain scalar selects
named form. The forms cannot be mixed. Params and query must be hashrefs, and
a fragment is a plain scalar or undef. Query keys are sorted and all query and
fragment components are UTF-8 percent-encoded. Output order is path, query,
then fragment.

Router C<path_for> starts at that Router's local root, inherits no request
captures, and cannot know an external placement. Context C<path_for> uses the
active request placement and adds the compiled-router entry C<root_path>
exactly once. A relative Context reference inherits only captured keys needed
by the target; explicit params override them. Absolute Context references
inherit nothing. Query and fragment values never inherit.

The same immutable child Router may be mounted at several paths and
names. It stores no parent placement. Context follows the active
request-local placement; calling the child Router's own C<path_for> still
returns its local path. Each placement and each C<to_app> call receives a
fresh compiled middleware graph.

Inheritance constructs a URL; it does not authorize the target. A captured
tenant, account, or user identifier says nothing about whether the current
principal may access it. Handlers must authorize normally.

C<url_for> selects HTTP(S) or WS(S) from the route kind and uses
L<PAGI::Authority> for a validated Host or server fallback. Duplicate or
malformed Host fields never fall back. Routing does not parse Forwarded or
X-Forwarded headers. Reverse helpers return strings or croak. They perform no
receive/send calls, emit no protocol events, do not redirect, and do not mutate
a response.

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
    my $node   = $routing->route_named('/person/show');

C<routes> contains only direct children in declaration order. C<named_routes>
maps canonical absolute addresses to original leaves, and C<route_named>
resolves from the Router root. Router base applications are traversed.
Collection accessors return shallow copies. C<desc> is a human note with no
matching or schema behavior.

=head1 MATCHED-ROUTE SCOPE CONVENTION

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
may omit it, in which case Context reverse routing falls back to the current
scope C<root_path>. C<logical_namespace> is the active containing namespace;
C<captures> is a fresh, unaliased working snapshot used only for relative
Context reverse routing. Nested Mounts append this public record to
C<mounts>:

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

C<match> is the selected mount's terminal record. Unanswered NONE/PARTIAL
declines leave
C<match> undefined while retaining the namespace and consumed-prefix capture
snapshot of their owning placement. Routing fallback middleware may render
that trusted decline without changing the match metadata.

Router base applications share their containing resolver frame. A separately
compiled Router reached through an application mount appends a compatible child
frame, and Context selects the innermost compatible frame. Malformed or newer
C<pagi.routing> data is an incompatible boundary:
the child router creates a fresh v1 container, ignores foreign ancestry, and
does not croak. The incoming scope and foreign value are not mutated. Additive
compatible fields, such as frame C<root_path>, retain version 1.

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
put two independent lifespan consumers around one root. Missing and unknown
scope types croak before router middleware or channel I/O.

Construction and compilation errors are reported early where possible.
Request-time dispatch, constraint, raw-application, and middleware exceptions
propagate to an enclosing L<PAGI::Middleware::ErrorHandler>. The router does
not synthesize 500 responses; put that middleware at the application policy
boundary. A compile-time factory/configuration error instead fails C<to_app>
before an application exists to wrap.

=head1 ROUTER FRONTENDS

  PAGI::Routing          immutable functional declarations   $c handlers
  PAGI::App::Router      mutable imperative builder          verb methods + $c
  PAGI::Endpoint::Router class/role-oriented frontend        local method names

These are three declaration surfaces over one immutable Router, not separate
matchers. They share Pattern parsing, Resolver slash addresses, Compiler
matching and dispatch, route metadata, constraints, GET/HEAD qualification and
wire suppression, nonterminal HTTP exhaustion, first-seen method evidence,
reverse routing, pure native middleware, and exact written declaration order.

C<PAGI::Routing> is already immutable. C<PAGI::App::Router> incrementally
builds declarations whose ordinary handlers receive C<$c> and whose native
targets require explicit C<raw>. C<PAGI::Endpoint::Router> binds unqualified
local method names to one constructed object; its method handlers receive
C<($self, $c)>. App and Endpoint C<to_router> calls create fresh immutable
snapshots, while C<to_app> compiles one retained snapshot. All middleware uses
the same four compile-time factory/C<wrap> forms and a request-time native app
phase; there is no response-valued Endpoint middleware chain.

=head1 SEE ALSO

L<PAGI::Tools::Cookbook>, L<PAGI::Context>, L<PAGI::Authority>,
L<PAGI::Compose>, L<PAGI::Pages>, L<PAGI::Response>,
L<PAGI::Middleware::Helpers>, L<PAGI::App::Router>, L<PAGI::Endpoint::Router>

=cut
