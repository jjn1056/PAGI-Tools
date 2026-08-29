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

    my $people = PAGI::App::Router->new;
    $people->get('/{id}' => \&show)->name('show');

    my $not_found = async sub {
        my ($scope, $receive, $send) = @_;
        my $response = PAGI::Pages->not_found(
            $scope,
            detail => 'No public route matched.',
        );
        await $response->respond($scope, $receive, $send);
    };

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

    my $app = compose(app => $r)->to_app;

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

An ordinary HTTP target must be a coderef. It receives exactly one
L<PAGI::Request> and returns an immediate or Future-backed concrete
L<PAGI::Response> value such as L<PAGI::Response::Text> or
L<PAGI::Response::JSON>.
GET includes automatic HEAD qualification. An explicit HEAD is an ordinary
declaration; place it before GET when it should win.

=head2 WebSocket and SSE routes

    $r->websocket('/chat/{room}' => \&chat);
    $r->sse('/events/{stream}' => \&events);

Ordinary protocol handlers likewise receive exactly one
L<PAGI::WebSocket> or L<PAGI::SSE>. Their completion value is awaited but is
not interpreted as a wire event.

=head2 Raw routes

    $r->get('/raw', raw => $native_http_app);
    $r->websocket('/raw-ws', raw => $websocket_component);
    $r->sse('/raw-events', raw => $sse_component);

A raw target receives the native C<($scope, $receive, $send)> channels. It must
be a coderef or an instantiated object with C<to_app>. Package-name strings
are never loaded as applications. An object is compiled once per enclosing
C<to_app> call and its C<to_app> method must return a coderef.

Raw changes only the selected exact leaf's invocation contract. It does not
make ordinary handlers application objects, and it does not consume a path
prefix.

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
        PAGI::Routing::Route->new(route => '/status', \&status),
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

=head1 MIDDLEWARE

Router, Route, and Mount middleware lists accept the shared
L<PAGI::Routing::Middleware> descriptor forms: class-name strings, coderef
factories, configured objects with C<wrap>, and existing descriptions.
Entries normalize at declaration time and build once per C<to_app>
compilation. The first listed entry is outermost at runtime.

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

A direct Router owns normal routing outcomes: HTTP NONE is its custom or stock
default, PARTIAL is its negotiated 405 with authoritative C<Allow>, and
protocol misses use stock protocol behavior. Direct compilation deliberately
does not install lifespan handling, error handling, or a response guard.
L<PAGI::Compose> supplies those root lifecycle and safety boundaries for a
deployed application.

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
