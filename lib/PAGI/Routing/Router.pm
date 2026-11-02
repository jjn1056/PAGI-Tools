package PAGI::Routing::Router;

use strict;
use warnings;
use namespace::autoclean;
use Carp qw(croak);
use PAGI::Routing::Route ();
use PAGI::Routing::Mount ();
use PAGI::Routing::Middleware ();
use PAGI::Routing::Resolver ();
use PAGI::Utils ();

sub new {
    my ($class, @args) = @_;
    croak 'router option list must be key/value pairs' if @args % 2;
    my %opts = @args;

    my %allowed = map { $_ => 1 } qw(routes middleware desc http_default);
    for my $key (keys %opts) {
        croak "unknown router option '$key'" unless $allowed{$key};
    }

    my $routes = exists $opts{routes} ? $opts{routes} : [];
    PAGI::Routing::Mount::_validate_routes($routes);
    my $middleware = PAGI::Routing::Middleware->_require_descriptors(
        exists $opts{middleware} ? $opts{middleware} : [],
        'middleware',
    );
    PAGI::Routing::Route::_validate_text('desc', $opts{desc}, 0) if exists $opts{desc};
    my $http_default = exists $opts{http_default}
        ? PAGI::Utils::_validate_app_value(
            $opts{http_default}, 'router http_default', 'request handler coderef',
        )
        : undef;
    my @routes = @$routes;
    my $self = bless {
        kind       => 'router',
        routes     => \@routes,
        middleware => $middleware,
        desc       => $opts{desc},
        http_default => $http_default,
    }, $class;

    $self->{_resolver} = PAGI::Routing::Resolver->new(router => $self);
    return $self;
}

sub kind       { $_[0]->{kind} }
sub name       { undef }
sub desc       { $_[0]->{desc} }
sub http_default { $_[0]->{http_default} }
sub routes     { [ @{$_[0]->{routes}} ] }
sub middleware { [ @{$_[0]->{middleware}} ] }
sub path       { undef }
sub methods    { undef }
sub constraints { undef }
sub _resolver     { $_[0]->{_resolver} }
sub named_routes { $_[0]->{_resolver}->named_routes }
sub route_table  { $_[0]->{_resolver}->route_table }
sub route_named  { $_[0]->{_resolver}->route_named($_[1]) }
sub path_for     { my $self = shift; return $self->{_resolver}->path_for(@_) }

sub to_app {
    my ($self) = @_;
    require PAGI::Routing::Compiler;
    return PAGI::Routing::Compiler->compile($self);
}

1;

__END__

=head1 NAME

PAGI::Routing::Router - Immutable declarative router description

=head1 SYNOPSIS

    my $router = PAGI::Routing::Router->new(routes => \@nodes);

=head1 DESCRIPTION

Routes describe endpoint leaves, Mount describes one prefixed application, and
Router describes an ordered collection of Route and Mount descriptions.
Construction accepts C<routes>, C<middleware>, C<desc>, and an optional
C<http_default>.

The Router validates direct nodes, middleware descriptors,
descriptions, canonical slash addresses, and child Router ancestry. A Router
description remains placement-free: mounting it never writes a parent path or
local name onto the child. This is compile-time configuration only; the object
stores no request scope, match, or response state.

=head1 ACCESSORS

C<routes> returns a shallow arrayref copy of direct children in declaration
order. C<named_routes> returns a shallow hashref copy mapping canonical
absolute addresses such as C</person/blog/show> to their original immutable
leaves and named Mounts; C<route_named($address)> returns one of them or undef
for an unknown address. C<path_for> renders the application-relative path for an address
without request state or protocol I/O. A child Router's own paths remain local
to that Router, while each outer Router resolver composes the path for its
particular mount placement.

C<route_table> returns a L<PAGI::Routing::RouteEntry> for every route in the
tree, named or not, depth-first in declaration order (see
L<PAGI::Routing::RouteEntry>); each Mount placement of a child Router gives
its own entries.

C<< mount('/prefix', routes => \@nodes) >> constructs a child Router
application; C<< mount('/prefix', app => $router) >> retains that Router as
its direct base application. Duplicate addresses and repeated path parameters
on one effective ancestry fail during construction. Cycles are rejected by
Router identity within the active ancestry, while the same Router may be
reused in completed sibling branches.

C<middleware> returns a fresh arrayref of normalized
C<PAGI::Routing::Middleware> descriptions; explicit descriptions retain their
identity. C<desc> returns the declaration value. C<http_default> returns the
exact declared value unchanged (a one-Request handler or app object), or undef
when it was omitted. It is validated at construction but not compiled there.
Inapplicable node metadata
accessors C<name>, C<path>, C<methods>, and C<constraints> return undef. Router
is a collection and has no leaf C<endpoint> accessor.

=head1 METHODS

=head2 path_for

    my $path = $router->path_for(
        '/account/show',
        { account_id => 7 },
        { tab => 'two words' },
        'details',
    );

    my $same = $router->path_for(
        '/account/show',
        params   => { account_id => 7 },
        query    => { tab => 'two words' },
        fragment => 'details',
    );

An initial C</> makes a reference absolute; otherwise it starts at this
Router's root. It inherits no request captures; inside a handler, import
L<PAGI::Routing::URL/path_for> and pass the Request so relative generation can
select the active placement of a reused child Router.
L<PAGI::Routing::URL/REFERENCES> and L<PAGI::Routing::URL/ARGUMENTS> have the
reference and argument rules. C<path_for> returns a string or croaks.

=head2 to_app

Synchronously compiles and returns a fresh PAGI application graph through
L<PAGI::Routing::Compiler> on every call. Middleware factories and components
are resolved during this call. It emits no events and starts no requests; the
returned coderef performs request matching and protocol I/O only when invoked.
Retain that coderef rather than compiling per request.

HTTP exhaustion is a complete Router outcome. NONE invokes C<http_default> when
configured and otherwise emits the stock concrete 404 response.
PARTIAL emits the Router's compliant 405 with an authoritative C<Allow> header.
Resolved Route methods include explicit declarations, one construction-time
C<allowed_methods> snapshot from an app object, or the GET plus
automatic HEAD default. Scalar C<< methods => '*' >> is unrestricted.
Selected child Router outcomes remain owned by that child. L<PAGI::Compose>
remains useful at an application root for middleware, lifespan, error handling,
and response lifecycle safety; it is not required to make Router 404 or 405
responses complete. WebSocket and SSE retain their protocol-specific miss
behavior.

Unlike L<PAGI::Compose>, a bare Router does not own root ErrorHandler,
response-completion guarding, or lifespan. It declines a lifespan scope; a
server's strict lifespan mode rejects that decline. An explicit root Mount
places this Router beneath Compose's root lifespan and safety services, but
does not add lifecycle behavior or a C<lifespan> option to Router itself. See
L<PAGI::Routing>, L<PAGI::Routing::Mount>, and the
L<routing composition upgrade guide|https://github.com/jjn1056/PAGI-Tools/blob/main/UPGRADING-REFERENCE.md#routing-composition-redesign>.

=cut
