package PAGI::Endpoint::Router;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed);

sub new {
    my ($class, @args) = @_;
    croak "$class->new accepts no arguments" if @args;
    return bless {}, $class;
}

sub routes { return }

sub to_router {
    my ($invocant) = @_;
    my $endpoint = _instance_for($invocant);
    require PAGI::App::Router::Materializer;
    my $materializer = PAGI::App::Router::Materializer->new;
    return $materializer->materialize($endpoint, '<root>');
}

sub to_app {
    my ($invocant) = @_;
    my $endpoint = _instance_for($invocant);
    return $endpoint->to_router->to_app;
}

sub _materialize_with {
    my ($self, $materializer) = @_;
    require PAGI::App::Router;
    require PAGI::Endpoint::Router::Builder;
    my $app_router = PAGI::App::Router->new;
    my $facade = PAGI::Endpoint::Router::Builder->new($self, $app_router);
    $self->routes($facade);
    return $app_router->_materialize_with($materializer);
}

sub middleware_as {
    my ($self, $name) = @_;
    my $method = $self->_required_local_method($name, 'middleware');
    return sub { return $method->($self, @_) };
}

sub app_as {
    my ($self, $name) = @_;
    my $method = $self->_required_local_method($name, 'application');
    return sub { return $method->($self, @_) };
}

sub new_request {
    my ($self, @arguments) = @_;
    require PAGI::Request;
    return PAGI::Request->new(@arguments);
}

sub app_path {
    my ($invocant, @components) = @_;
    my $class = blessed($invocant) || $invocant;

    (my $module_file = $class) =~ s{::}{/}g;
    $module_file .= '.pm';

    my (undef, $caller_source) = caller;
    my $source = $INC{$module_file};
    $source = $caller_source unless defined $source && length $source;

    require PAGI::Utils;
    return PAGI::Utils::_app_path_from_origin(
        $class, $source, @components,
    );
}

sub _required_local_method {
    my ($self, $name, $kind) = @_;
    croak "$kind method name must be an unqualified name"
        unless defined $name && !ref($name)
            && $name =~ /\A[A-Za-z_]\w*\z/;
    my $method = $self->can($name);
    my $class = blessed($self) || $self;
    croak qq{$class has no $kind method "$name"} unless $method;
    return $method;
}

sub _instance_for {
    my ($invocant) = @_;
    return $invocant if blessed($invocant);
    return $invocant->new;
}

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::Endpoint::Router - Method-oriented frontend for shared PAGI routing

=head1 SYNOPSIS

    package MyApp::Endpoint;
    use parent 'PAGI::Endpoint::Router';
    use Future::AsyncAwait;
    use PAGI::Compose qw(compose);
    use PAGI::Response::JSON ();
    use PAGI::Response::Text ();
    use PAGI::Routing qw(middleware mount);
    use PAGI::Utils qw(as_app);

    sub new {
        my ($class, %args) = @_;
        die 'repository is required' unless $args{repository};
        return bless { repository => $args{repository} }, $class;
    }

    sub routes {
        my ($self, $r) = @_;
        $r->http_default($self->app_as('not_found_app'));
        $r->get('/people/{id}' => [
            'RequestId',
            $self->middleware_as('authenticate'),
            $self->{configured_middleware},
            middleware('Session', cookie_name => 'sid'),
        ] => 'show')->name('show');
        $r->get('/download', as_app($self->app_as('download')));
        $r->websocket('/chat/{room}' => 'chat')->name('chat');
        $r->sse('/events' => 'events')->name('events');
        $r->mount('/admin', routes => sub {
            my ($admin) = @_;
            $admin->get('/users' => 'users')->name('users');
        })->name('admin');
        $r->mount('/legacy', app => $self->app_as('legacy_app'));
    }

    sub show {
        my ($self, $request) = @_;
        return PAGI::Response::JSON->new(
            $self->{repository}->find($request->path_param('id')),
        );
    }

    sub authenticate {
        my ($self, $inner_app) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            return await $inner_app->($scope, $receive, $send);
        };
    }

    my $endpoint = MyApp::Endpoint->new(repository => $repository);
    my $static = $endpoint->app_path('static');
    my $app = compose(
        routes => [mount('/' => app => $endpoint)],
    )->to_app;

This is ordinary application deployment: C<$endpoint> already implements
C<to_app>.

=head1 DESCRIPTION

C<PAGI::Endpoint::Router> is the method-oriented mutable frontend over
L<PAGI::App::Router> and the shared immutable routing compiler. It binds route
handler names to one ordinary Perl object. It does not match requests, build
protocol objects for compiled routes, adapt Responses, load handler packages, inject
state, or maintain a separate middleware chain.

=head1 MIGRATING

This release intentionally replaces the previous Endpoint handler,
middleware, state, handler-object, nesting, and naming contracts without a
compatibility layer. See the
L<standalone router frontend upgrade guide|https://github.com/jjn1056/PAGI-Tools/blob/main/UPGRADING.md>
in the source distribution for concrete before-and-after examples with
exercised shipped replacements.

=head1 CONSTRUCTION AND LIFECYCLE

=head2 new

The base constructor accepts no options and returns an empty blessed hash.
Configured subclasses override C<new> with their own ordinary validation and
accessors. Configuration is simply object data; Endpoint supplies no hidden
state hash.

=head2 to_router

    my $snapshot = MyApp::Endpoint->to_router;
    my $same_object_snapshot = $endpoint->to_router;

A class call constructs exactly one instance with C<new>. An object call
retains that exact object. Each call materializes a fresh immutable
L<PAGI::Routing::Router> snapshot, so later changes to ordinary object fields
do not alter an existing snapshot's declaration graph.

Convert a nested Endpoint explicitly when the parent must discover its
descendant names:

    $parent->mount('/people', app => $people_endpoint->to_router)
        ->name('people');
    $parent->path_for('/people/show', { id => 42 });

Each C<to_router> call makes an immutable child snapshot. Mounting an Endpoint
object directly with C<< app => $endpoint >> is also valid application
composition, but that boundary is opaque: dispatch enters the Endpoint's
C<to_app>, while the outer reverse resolver does not guess its route names.

=head2 to_app

Materializes one fresh snapshot and compiles it through the shared compiler.
Retain the returned native PAGI routing component for its intended lifetime. A
class call constructs one Endpoint instance; an object call keeps its receiver.
Direct C<to_app> is legal bare Router compilation. HTTP NONE invokes the
Router's declared C<http_default>, or its stock negotiated 404 when none was
declared; HTTP PARTIAL likewise retains the Router's negotiated 405. It never
completes HTTP exhaustion silently.
Call C<to_router> when a parent must inspect or discover descendant names, or
when the immutable snapshot itself must be retained or inspected. For ordinary
application deployment, mount the frontend directly:

    my $app = compose(
        routes => [mount('/' => app => $endpoint)],
    )->to_app;

Calling C<to_router> immediately before an opaque root Mount adds only syntax
unless the outer root inspects that snapshot. Mounting C<$endpoint> is ordinary
application composition, but it is an opaque application boundary: Compose
does not call C<to_router> automatically or expose the Endpoint's names.
Compose adds application middleware, root lifespan callbacks, ErrorHandler,
response-completion guarding, and the outer HEAD boundary. It does not add
lifespan to the Router, and it is not required merely to produce Router-owned
404 or 405 responses.

=head1 ROUTE DECLARATIONS

C<routes($builder)> receives an Endpoint-aware facade over one public App
Router. It provides C<get>, C<post>, C<put>, C<patch>, C<delete>, C<head>,
C<options>, C<any>, C<route>, C<websocket>, C<sse>, C<mount>,
C<http_default>, and the last-declaration modifiers C<name>, C<desc>, and
C<constraints>. It intentionally has no C<group>. Declarations remain in exact
first-seen order. A Mount C<routes> callback receives a fresh Endpoint facade
bound to the same object and a fresh child App Router.

The same snapshot and reverse-routing rules as L<PAGI::App::Router> apply.
Names are local logical segments; nested names form canonical slash addresses.
L<PAGI::Routing::URL/path_for> can resolve from the selected Request relative
to the active placement, while an absolute name starts with C</>.

=head1 HANDLERS

    $r->get('/method' => 'show');
    $r->get('/closure' => sub {
        my ($request) = @_;
        return PAGI::Response::Text->new('closure');
    });

A plain unqualified string in handler position is validated with C<can> while
the snapshot is built. The exact resulting method CODE is retained and later
called as C<($endpoint, $protocol)>. HTTP methods receive a
L<PAGI::Request>, WebSocket methods receive a L<PAGI::WebSocket>, and SSE
methods receive a L<PAGI::SSE>. Local, inherited, and role-installed or
aliased methods therefore work. Missing methods and qualified strings are
errors; handler strings never load packages.

A handler coderef passes to the shared App Router unmodified. It receives only
the ordinary protocol-specific object and is never rebound to the Endpoint.
HTTP handlers return an immediate application value or a Future resolving to
one.
WebSocket and SSE handlers use their protocol-object operations and may complete
immediately or through a Future. All response validation and protocol events
belong to the shared compiler.

For HTTP application objects, explicit Route methods win; otherwise
C<allowed_methods> is snapshotted once when the immutable Route is built;
otherwise GET plus automatic HEAD is used. The mutable Endpoint declaration
does not query that capability. Each fresh C<to_router> call constructs fresh
Routes and therefore takes one fresh snapshot; a retained immutable Router
retains its method policy. Only scalar C<< methods => '*' >> is unrestricted.
WebSocket and SSE leaves never consult that HTTP capability.

=head1 APPLICATION LEAVES

Endpoint accepts application objects at leaf positions after the optional
positional middleware array. Wrap a native closure from C<app_as> explicitly:

    $r->get('/native-http' => [
        $self->middleware_as('audit'),
    ], as_app($self->app_as('native_http')));

The application owns the native C<($scope, $receive, $send)> channels and
route middleware still wraps it. An ordinary method-name target binds
C<($endpoint, $protocol)>. An ordinary handler coderef passes through
unchanged and receives one protocol object.

A dynamic application returned by an HTTP handler is normalized per request.
It receives the unchanged scope and remaining body stream, receives no
lifespan replay, and remains opaque to the outer Router's reverse/schema
metadata. Synchronous method handlers run inline and may block the event loop.

=head1 MIDDLEWARE

This Endpoint frontend intentionally accepts concise middleware arrays using
the four convenient forms:

=over 4

=item * a middleware class string;

=item * a factory coderef;

=item * a configured object with C<wrap>;

=item * a C<PAGI::Routing::Middleware> description, commonly built with
C<middleware($class, %configuration)>.

=back

The frontend immediately materializes each entry as an explicit
L<PAGI::Routing::Middleware> description for the immutable Router snapshot.
Descriptions resolve at app compilation. Factories and C<wrap> methods may
return native CODE or an object with C<to_app>; the resulting native app runs
at request time and returns the protocol completion. The first item listed is
outermost. This contract is identical for HTTP, WebSocket, and SSE; there is
no response-valued C<($protocol, $next)> Endpoint middleware.

=head2 middleware_as

    my $factory = $endpoint->middleware_as('authenticate');

    $r->get('/private' => [
        $self->middleware_as('authenticate'),
    ] => 'show');

Validates an unqualified local, inherited, or role-installed method and
returns a normal middleware factory closure. At compilation the method
receives C<($endpoint, $inner_app)> and must return the wrapped native app
immediately. Constructing the helper performs no protocol I/O.

=head2 app_as

    my $app = $endpoint->app_as('native_app');
    $r->get('/download', as_app($endpoint->app_as('native_app')));
    $r->mount('/legacy', app => $endpoint->app_as('native_app'));
    $r->http_default($endpoint->app_as('not_found_app'));

Validates the method and returns a native application closure. When invoked,
the method receives C<($endpoint, $scope, $receive, $send)>. The helper is
useful as the source for an explicitly wrapped application leaf, an opaque
mount, or another native composition boundary, including C<http_default>, and
does no work merely by being constructed. An application leaf remains
method-aware and keeps its matched path; an opaque mount owns and rewrites a
matched prefix.

=head1 REQUEST AND STATE

=head2 new_request

    my $request = $endpoint->new_request($scope, $receive);

This explicit convenience method calls C<PAGI::Request-E<gt>new>. It accepts
only an HTTP scope and the receive channel used for request-body consumption.
All arguments are forwarded to that constructor, so a C<$send> callback or any
other extra argument is rejected by the one Request validator.
It is not the routing compiler's Request factory. Overriding it affects only
explicit calls to the helper, never compiled route dispatch. WebSocket and SSE
objects are supplied directly by compiled handlers rather than through this
HTTP-only convenience.

=head2 app_path

    my $home   = $endpoint->app_path();
    my $static = $endpoint->app_path('static');

Returns an absolute, platform-canonical application path using the same
component validation and output contract as L<PAGI::Utils/app_path>. Object
and class calls use their concrete Endpoint class. A loaded class obtains its
source from the corresponding C<%INC> module entry, while an inline class
falls back to the source of the explicit helper call.

C<PAGI_HOME>, when defined and nonempty, has first precedence. The override
affects only explicit C<app_path> calls; it does not affect route compilation
or dispatch.

Endpoint object fields and request lifespan state are separate mechanisms.
Use validated constructor fields for object configuration.
C<$request-E<gt>state> returns the strict L<PAGI::State> facade for a C<state>
hash supplied in the server-owned request scope, including state prepared
through L<PAGI::Compose> lifespan callbacks. It returns C<undef> when the key
is absent. Endpoint neither creates nor injects that key and has no C<state>
method or protocol-object factory override.

=head1 SNAPSHOTS AND ORDER

Each C<to_router> returns a fresh immutable snapshot, and each C<to_app>
compiles one retained snapshot. Matching, middleware folds, Router-owned HTTP
outcomes, first-seen method evidence, route metadata, reverse resolution, and
request-local routing state are exactly those documented by
L<PAGI::App::Router>. Endpoint adds only method binding over that machinery and
forwards the Router's one-shot native C<http_default> declaration without
adding separate fallback callback accessors.

=head1 SEE ALSO

L<PAGI::Routing>, L<PAGI::Routing::Router>, L<PAGI::Routing::Mount>,
L<PAGI::Compose>, L<PAGI::App::Router>, and the
L<routing composition upgrade guide|https://github.com/jjn1056/PAGI-Tools/blob/main/UPGRADING.md#routing-composition-redesign>.

=cut
