package PAGI::App::Router;

use strict;
use warnings;
use parent 'PAGI::App::Router::Builder';

sub named_routes {
    my ($self) = @_;
    return $self->to_router->named_routes;
}

sub route_named {
    my ($self, $name) = @_;
    return $self->to_router->route_named($name);
}

sub path_for {
    my $self = shift;
    return $self->to_router->path_for(@_);
}

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::App::Router - Mutable declarations for the immutable PAGI router

=head1 SYNOPSIS

    use PAGI::App::Router;
    use PAGI::Compose qw(compose);
    use Future::AsyncAwait;
    use PAGI::Pages ();
    use PAGI::Routing qw(mount);

    my $people = PAGI::App::Router->new;
    $people->get('/{id}' => \&show)->name('show');

    my $not_found = PAGI::Pages->not_found(
        detail => 'No public route matched.',
    );

    my $r = PAGI::App::Router->new(
        desc         => 'Public routes',
        middleware   => [\&request_log],
        http_default => $not_found,
    );

    $r->get('/health' => \&health);
    $r->mount('/api', routes => sub {
        my ($api) = @_;
        $api->get('/people' => \&people)->name('people');
    })->name('api');
    $r->mount('/people', app => $people->to_router)->name('people');
    $r->mount('/static', app => $static_app);

    my $snapshot = $r->to_router;
    my $app = compose(
        routes => [mount('/' => app => $snapshot)],
    )->to_app;

=head1 DESCRIPTION

C<PAGI::App::Router> is a mutable declaration frontend for
L<PAGI::Routing::Router>. It stores declarations in their written order and
creates a fresh immutable Router snapshot through C<to_router>. Matching,
dispatch, HTTP outcomes, middleware compilation, metadata, and reverse routing
belong to the shared immutable routing implementation.

The constructor accepts C<desc>, C<middleware>, and optional
C<http_default>. It performs configuration validation only and invokes no
application or protocol channel.

=head1 DECLARATIONS

=head2 HTTP routes

    $r->get('/people' => \&index);
    $r->post('/people' => \&create);
    $r->put('/people/{id}' => \&replace);
    $r->patch('/people/{id}' => \&update);
    $r->delete('/people/{id}' => \&remove);
    $r->head('/people/{id}' => \&head_person);
    $r->options('/people' => \&options);
    $r->any('/health' => \&health);
    $r->route('/rpc' => \&rpc, methods => ['RPC']);

An HTTP endpoint may be a coderef or an instantiated application object. A
coderef receives exactly one L<PAGI::Request> and returns an immediate or
Future-backed application value, such as L<PAGI::Response::Text>,
L<PAGI::Response::JSON>, or L<PAGI::Pages::Application>. An object endpoint
is compiled through its C<to_app> method.
Explicit C<methods> wins. Otherwise an application object's
C<allowed_methods> is snapshotted once during immutable Route construction;
otherwise the Route defaults to GET plus automatic HEAD. Mutable declaration
retains the endpoint without consulting that capability. Each fresh
C<to_router> call constructs fresh Routes and therefore takes one fresh
snapshot; a retained immutable Router retains its method policy. Only scalar
C<< methods => '*' >> is unrestricted; C<any> declares that wildcard.
An explicit HEAD is an ordinary
declaration; place it before GET when it should win.

A returned object's C<to_app> runs once per handler invocation. Advanced
arbitrary results receive the unchanged scope and remaining body stream, with
no body or lifespan replay, and remain opaque to the outer reverse/schema
metadata. Synchronous handlers run inline; blocking work blocks the event loop.

=head2 WebSocket and SSE routes

    $r->websocket('/chat/{room}' => \&chat);
    $r->sse('/events/{stream}' => \&events);

Ordinary protocol handlers likewise receive exactly one
L<PAGI::WebSocket> or L<PAGI::SSE>. Their completion value is awaited but is
not interpreted as a wire event.

=head2 Native applications at routes

    use PAGI::Utils qw(as_app);

    $r->get('/native', as_app($native_http_app));
    $r->websocket('/native-ws', as_app($websocket_app));
    $r->sse('/native-events', as_app($sse_app));

An application object at a leaf owns the native
C<($scope, $receive, $send)> channels. Native coderefs must be explicitly
wrapped with C<as_app>; unwrapped coderefs remain direct protocol handlers.
Package-name strings are never loaded as applications. An object is compiled
once per enclosing C<to_app> call and its C<to_app> method must return a
coderef.

=head2 Mounts

    $r->mount('/legacy',
        app        => $legacy_app,
        middleware => [\&audit],
    )->desc('Legacy application');

    $r->mount('/api',
        routes => sub {
            my ($api) = @_;
            $api->get('/people' => \&people)->name('people');
        },
        middleware => [\&api_headers],
    )->name('api');

    $r->mount('/public', routes => [
        PAGI::Routing::Route->new(
            path => '/status', endpoint => \&status,
        ),
    ]);

C<mount> accepts exactly one named target: C<app> or C<routes>. C<app> uses
the native application contract. C<routes> accepts an arrayref of immutable
routing nodes or a synchronous callback. A callback receives a fresh App
Router, its return value is ignored, and it runs once while the mutable
declaration is made. Each C<to_router> snapshots that retained child through
the same root-local materializer.

There is no positional Mount target, C<< router => >> form, or C<group>.
C<name>, C<desc>, and C<constraints> remain chained modifiers rather than
Mount options.

An immutable L<PAGI::Routing::Router> supplied through C<app> remains
discoverable for nested reverse names. Other application objects are opaque to
parent inspection but dispatch normally. To expose names from another mutable
frontend, take the boundary explicitly:

    $r->mount('/people',
        app => $people_builder->to_router,
    )->name('people');

Passing C<$people_builder> itself is also a valid opaque application, but the
parent does not guess that object's declarations or call an arbitrary
C<routes> method.

=head2 Modifiers and patterns

    $r->get('/people/{id}' => \&show)
        ->name('show')
        ->desc('Show one person')
        ->constraints(id => qr/\A\d+\z/);

C<name>, C<desc>, and C<constraints> modify the most recent compatible Route
or Mount. Names are one local slash-address segment. Paths use the shared
L<PAGI::Routing::Pattern> grammar, including C<{id}>, inline constraints,
provider constraints, and terminal wildcards.

=head1 HTTP DEFAULT

    $r->http_default($not_found_app);

C<http_default> configures the Router's native HTTP NONE application. It may
be configured exactly once, either in the constructor or through this method;
a second configuration croaks. The application is retained unchanged and is
not compiled or invoked during declaration or C<to_router>.

At compilation it is built once for that Router occurrence. It receives only
HTTP requests for which the complete direct Router scan found neither FULL nor
PARTIAL. It never receives Router-generated 405 outcomes, WebSocket or SSE
misses, or selected handler exceptions. When omitted, the immutable Router
uses the stock negotiated Pages 404.

A source-free Pages object is already a native application and needs no
adapter. A custom one-Request default uses
L<PAGI::Utils/request_response>.

=head1 MIDDLEWARE

This mutable frontend intentionally accepts concise middleware arrays with
class-name strings, coderef factories, configured objects with C<wrap>, or
existing descriptions. It immediately materializes every entry as an explicit
L<PAGI::Routing::Middleware> description for the immutable Router snapshot;
the core Router, Route, and Mount lists themselves contain descriptions only.
Entries build once per C<to_app> compilation. The first listed entry is
outermost at runtime.

Router middleware surrounds every Router outcome. Mount middleware surrounds
the selected child application. Route middleware surrounds only its selected
leaf. A C<routes> callback creates a real child Router application boundary,
not a transparent inline group.

=head1 ORDER AND SNAPSHOTS

Routes and Mounts remain in exact declaration order. Nothing sorts by kind,
path specificity, name, or Mount prefix length. The first FULL declaration
wins. A matching Mount is FULL at its written position and transfers ownership
to its child application; the parent never resumes after that child returns a
404 or 405.

=head2 to_router

    my $routing = $r->to_router;

Returns a fresh immutable L<PAGI::Routing::Router> snapshot on every call.
Later parent or callback-child mutations cannot alter an existing snapshot.
Within one snapshot operation, repeated structural frontend identities reuse
one completed Router identity and malformed active cycles croak with their
placement chain.

=head2 to_app

    my $routing_app = $r->to_app;

Creates exactly one fresh Router snapshot and compiles that retained snapshot.
Each call builds a fresh middleware and application graph; requests reuse that
graph and never compile per request.

C<to_app> is bare Router compilation. A direct Router owns normal routing
outcomes: HTTP NONE is its custom or stock
default, PARTIAL is its negotiated 405 with authoritative C<Allow>, and
protocol misses use stock protocol behavior. Direct compilation deliberately
does not install lifespan handling, error handling, or a response guard.
Call C<to_router> when the immutable snapshot must be retained or inspected.

For root deployment, retain and mount the immutable boundary explicitly:

    my $snapshot = $r->to_router;
    my $app = compose(
        routes => [mount('/' => app => $snapshot)],
    )->to_app;

The explicit snapshot Mount is inspectable: its names remain available through
the outer Compose Router. Mounting C<$r> itself with C<< app => $r >> is also
valid, but it is an opaque application boundary: Compose does not call
C<to_router> automatically or expose the frontend's names. Compose supplies
application middleware, root lifespan, ErrorHandler, response-completion
guarding, and the outer HEAD boundary. It does not add lifespan to the Router.

=head1 INSPECTION AND REVERSE ROUTING

C<named_routes>, C<route_named>, and C<path_for> delegate through a fresh
C<to_router> snapshot on every call. Retain one immutable Router when stable
snapshot identity matters.

Names use canonical slash addresses. Nested names are discovered only through
mounted immutable Router applications. C<path_for> validates the complete
effective path and constraints, encodes parameter/query/fragment values, and
performs no protocol I/O. Inside a selected handler,
L<PAGI::Routing::URL/path_for> accepts the Request or protocol object and can
resolve relative to the active placement while inheriting captures.

=head1 SEE ALSO

L<PAGI::Routing>, L<PAGI::Routing::Router>, L<PAGI::Routing::Mount>,
L<PAGI::Compose>, L<PAGI::Endpoint::Router>, and the
L<routing composition upgrade guide|https://github.com/jjn1056/PAGI-Tools/blob/main/UPGRADING.md#routing-composition-redesign>.

=cut
