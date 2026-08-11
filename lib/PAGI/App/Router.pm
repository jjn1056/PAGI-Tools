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

PAGI::App::Router - Mutable frontend for the shared immutable PAGI router

=head1 SYNOPSIS

    use PAGI::App::Router;

    my $r = PAGI::App::Router->new;
    $r->head('/report' => \&head_report);
    $r->get('/report' => [\&audit] => \&get_report)->name('report');
    $r->get('/raw', raw => $native_app);
    $r->mount('/people', router => $people)->name('people');
    my $routing = $r->to_router;
    my $app = $routing->to_app;

=head1 DESCRIPTION

C<PAGI::App::Router> is the public mutable builder for the immutable
L<PAGI::Routing::Router> model. It inherits the complete declaration contract
from L<PAGI::App::Router::Builder>, materializes public routing descriptions,
and delegates matching and dispatch entirely to the shared
L<PAGI::Routing::Compiler>. It contains no matcher and keeps no request state.

The constructor accepts C<desc>, C<middleware>, C<not_found>, and
C<method_not_allowed>. The two generated-outcome handlers are ordinary HTTP
Context handlers. Their cached Response is seeded with status 404 or 405; the
405 response also begins with the selected C<Allow> value.

=head1 MIGRATING

This release intentionally replaces the previous App Router declaration,
handler, ordering, middleware, naming, and inspection contracts without a
compatibility layer. See the
L<standalone router frontend upgrade guide|https://github.com/jjn1056/PAGI-Tools/blob/main/UPGRADING.md>
in the source distribution for concrete before-and-after examples with
exercised shipped replacements.

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

An ordinary HTTP target is called with one L<PAGI::Context::HTTP> and must
return an immediate L<PAGI::Response> or a Future that resolves to one. The
shared compiler adapts and emits that Response. The generic C<route> form puts
the path first and requires C<methods>; C<any> uses all methods.

C<get> includes the shared automatic HEAD qualification. An explicit C<head>
is an ordinary declaration, not an option attached to C<get>. Declare it
before C<get> when it should win:

    $r->head('/report' => \&head_report);
    $r->get('/report' => \&get_report);

For HEAD the first route is FULL. For GET it is PARTIAL and scanning continues
to the GET route. There is no C<auto_head> option.

=head2 WebSocket and SSE routes

    $r->websocket('/chat/{room}' => \&chat);
    $r->sse('/events/{stream}' => \&events);

Normal protocol targets receive exactly one L<PAGI::Context::WebSocket> or
L<PAGI::Context::SSE>. They perform protocol work through that Context. An
immediate or Future-backed completion is awaited, and its resolved value is
not interpreted as a wire event.

=head2 Raw routes and opaque mounts

    $r->get('/raw', raw => $native_http_app);
    $r->websocket('/raw-ws', raw => $native_ws_app);
    $r->sse('/raw-events', raw => $native_sse_app);
    $r->mount('/legacy' => $native_multiprotocol_app);

An explicit C<raw> route gives its target the native
C<($scope, $receive, $send)> channels after an exact route match. A raw HTTP
route participates in its declared methods and 405 calculation, records leaf
metadata, and does not rewrite C<path> or C<root_path>.

An opaque C<mount>, by contrast, owns a matched prefix for every protocol. It
rewrites the child C<path> and C<root_path>, is not method-limited by its
parent, and hides its internal routes and names. Raw routes and mounts are not
interchangeable merely because both eventually invoke a native PAGI app.

=head2 Groups and routing-aware mounts

    $r->group('/api' => sub {
        my ($api) = @_;
        $api->get('/people' => \&people)->name('people');
    })->name('api');

    $r->mount('/people', router => $people)->name('people');

A group callback receives a fresh child C<PAGI::App::Router>. The group stays
at one position in its parent's declaration list and materializes as an inline
structural subtree. It is not flattened and is not a separately configured
Router boundary.

C<< router => >> creates a routing-aware mount. Its target may be an immutable
L<PAGI::Routing::Router>, another C<PAGI::App::Router>, or a constructed
L<PAGI::Endpoint::Router> instance. Mutable targets are recursively
materialized in the same root snapshot. Package loading, string targets, and
mutable routers used as opaque or raw applications are not supported.

=head2 Modifiers and patterns

    $r->get('/people/{id}' => \&show)
        ->name('show')
        ->desc('Show one person')
        ->constraints(id => qr/\A\d+\z/);

C<name>, C<desc>, and C<constraints> modify the most recent compatible
declaration. A name is one local logical segment. Nested addresses use slash
components such as C</people/show>; dotted effective names and the old C<as>
and C<namespace> vocabulary do not exist.

Paths use the shared L<PAGI::Routing::Pattern> grammar: C<{id}> for one
segment, C<{id:\d+}> for an inline constraint, C<{id:&Int}> for a declaration-
package provider, and C<*path> for a wildcard segment. Chained constraints are
also enforced during both dispatch and reverse routing.

=head1 MIDDLEWARE

Every Router, route, WebSocket, SSE, group, and mount middleware list accepts
the same four entry forms:

=over 4

=item * a nonempty middleware class-name string;

=item * a coderef factory called synchronously with C<($inner_app)>;

=item * a blessed configured object with C<< ->wrap($inner_app) >>; or

=item * an existing L<PAGI::Routing::Middleware> description.

=back

For example:

    $r->get('/admin' => [
        'RequestId',
        \&with_logging,
        $configured_auth,
        middleware('Session', cookie_name => 'sid'),
    ] => \&admin);

Entries are normalized at declaration time. Factories and C<wrap> methods run
once per C<to_app> compilation, in onion order with the first listed entry
outermost. These are native app-to-app middleware, not response-valued
C<($context, $next)> callbacks.

=head1 ORDER AND MATCH OWNERSHIP

All direct routes, groups, WebSocket routes, SSE routes, and mounts remain in
the exact order declared. Nothing is sorted by kind, path specificity, name,
hash order, or mount-prefix length. The first FULL match wins.

An HTTP path match for the wrong method is PARTIAL rather than final. Scanning
continues for a later FULL route; if none exists, all PARTIAL declarations
contribute methods to the deterministic first-seen C<Allow> union. Otherwise
the owning Router generates 404. A matched mount prefix owns dispatch at its
written position, including the mounted Router's generated outcomes.

=head1 SNAPSHOTS AND COMPILATION

=head2 to_router

    my $routing = $r->to_router;

Returns a fresh immutable L<PAGI::Routing::Router> on every call. Materializing
again repeats validation and creates independent immutable node identities.
Later builder mutations cannot alter an existing snapshot.

Retain the returned Router when inspection identity matters or several
reverse-routing calls belong to one configuration view.

=head2 to_app

    my $app = $r->to_app;

Materializes exactly one fresh Router snapshot and compiles that retained
snapshot through the shared compiler. Each call returns another middleware
graph. Build and retain the app for its intended lifetime rather than calling
C<to_app> per request.

=head1 INSPECTION AND REVERSE ROUTING

=head2 named_routes

=head2 route_named

=head2 path_for

These convenience methods delegate through a fresh C<to_router> snapshot on
every call. They therefore repeat materialization and validation; immutable
route object identity is not stable across calls. Use one retained Router for
stable C<route_named> or C<named_routes> identities.

C<path_for> uses canonical slash addresses, validates the complete effective
path and all constraints, percent-encodes parameter, query, and fragment
values, and performs no protocol I/O. Inside a matched handler, Context
C<path_for> can resolve relative to the active logical namespace and inherit
matched captures. There is no C<uri_for> alias.

=cut
