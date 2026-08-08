package PAGI::Routing::Router;

use strict;
use warnings;
use Carp qw(croak);
use PAGI::Routing::Route ();
use PAGI::Routing::Mount ();
use PAGI::Routing::Middleware ();
use PAGI::Routing::Resolver ();

sub new {
    my ($class, @args) = @_;
    croak 'router option list must be key/value pairs' if @args % 2;
    my %opts = @args;

    my %allowed = map { $_ => 1 } qw(routes middleware desc not_found method_not_allowed);
    for my $key (keys %opts) {
        croak "unknown router option '$key'" unless $allowed{$key};
    }

    my $routes = exists $opts{routes} ? $opts{routes} : [];
    PAGI::Routing::Mount::_validate_routes($routes);
    my $middleware = PAGI::Routing::Middleware->_normalize_descriptors(
        exists $opts{middleware} ? $opts{middleware} : [],
        'middleware',
    );
    PAGI::Routing::Route::_validate_text('desc', $opts{desc}, 0) if exists $opts{desc};
    for my $name (qw(not_found method_not_allowed)) {
        croak "$name must be a coderef"
            if exists $opts{$name} && ref($opts{$name}) ne 'CODE';
    }

    my @routes = @$routes;
    my $self = bless {
        kind       => 'router',
        routes     => \@routes,
        middleware => $middleware,
        desc       => $opts{desc},
        not_found  => $opts{not_found},
        method_not_allowed => $opts{method_not_allowed},
    }, $class;

    $self->{_resolver} = PAGI::Routing::Resolver->new(router => $self);
    return $self;
}

sub kind       { $_[0]->{kind} }
sub name       { undef }
sub desc       { $_[0]->{desc} }
sub routes     { [ @{$_[0]->{routes}} ] }
sub middleware { [ @{$_[0]->{middleware}} ] }
sub path       { undef }
sub target     { undef }
sub is_raw     { undef }
sub methods    { undef }
sub constraints { undef }
sub namespace  { undef }
sub not_found { $_[0]->{not_found} }
sub method_not_allowed { $_[0]->{method_not_allowed} }
sub _resolver     { $_[0]->{_resolver} }
sub named_routes { $_[0]->{_resolver}->named_routes }
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

The root routing description. Construction validates its direct node list,
fallback handlers, middleware descriptors, descriptions, canonical slash
addresses, and every inspectable inline or Router-mount ancestry. A Router
description remains placement-free: mounting it never writes a parent path or
namespace onto the child. This is compile-time configuration only; the object
stores no request scope, match, or response state.

=head1 ACCESSORS

C<routes> returns a shallow arrayref copy of direct children in declaration
order. C<named_routes> returns a shallow hashref copy mapping canonical
absolute addresses such as C</person/blog/show> to their original immutable
leaves; C<route_named($address)> returns one such leaf or undef for an unknown
address. C<path_for> renders the application-relative path for an address
without request state or protocol I/O. A child Router's own paths remain local
to that Router, while each outer Router resolver composes the path for its
particular mount placement.

Explicit C<< router => $router >> mounts are inspected recursively. Positional
application mounts remain opaque even when their target is a Router. Duplicate
addresses and repeated path parameters on one effective ancestry fail during
construction; opaque mount prefixes are validated before traversal stops.
Cycles are rejected by Router identity within the active ancestry, while the
same Router may be reused in completed sibling branches.

C<middleware> returns a fresh arrayref of normalized
C<PAGI::Routing::Middleware> descriptions; explicit descriptions retain their
identity. C<desc>, C<not_found>, and C<method_not_allowed> return declaration
values. Leaf/mount-only accessors such as C<name>, C<path>, C<target>,
C<methods>, and C<constraints> return undef.

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

The compact form accepts params, query, and fragment in that order. Its first
trailing hashref selects compact form, and C<{}> placeholders are required for
query-only or fragment-only calls. A first trailing defined plain scalar
selects the order-independent named form with C<params>, C<query>, and
C<fragment>. Other selectors fail, and the forms cannot be mixed. Params and
query must be hashrefs. A fragment is a plain scalar or C<undef>; C<undef>
omits it and an empty string emits a terminal C<#>.

An initial C</> makes a reference absolute; otherwise it starts at this
Router's root. C<.> and C<..> components normalize exactly, dots within a
component remain literal, and references are never URI-decoded. Empty
components, repeated or trailing separators, above-root traversal,
namespace-only results, and unknown exact targets fail. There is no ancestor
search, fuzzy fallback, dotted hierarchy, or overlapping-prefix folding.

Query pairs are sorted and each UTF-8 key/value is percent-encoded as a URI
component. A fragment is encoded once as one component and follows the query.
C<path_for> only returns a string and performs no protocol I/O.

=head2 to_app

Synchronously compiles and returns a fresh PAGI application graph through
L<PAGI::Routing::Compiler> on every call. Middleware factories and components
are resolved during this call. It emits no events and starts no requests; the
returned coderef performs request matching and protocol I/O only when invoked.
Retain that coderef rather than compiling per request.

=cut
