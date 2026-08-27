package PAGI::Routing::URL;

use strict;
use warnings;
use Carp qw(croak);
use Exporter 'import';
use Scalar::Util qw(blessed);
use PAGI::Routing::Resolver ();
use PAGI::Utils::Scope ();

our @EXPORT = ();
our @EXPORT_OK = qw(url path_for url_for);
our %EXPORT_TAGS = (ALL => [@EXPORT_OK]);

=encoding UTF-8

=head1 NAME

PAGI::Routing::URL - Scope-bound reverse routing facade

=head1 SYNOPSIS

    use PAGI::Routing::URL qw(url path_for url_for);

    my $urls = url($request);
    my $path = $urls->path_for('show', { id => 42 });
    my $absolute = $urls->url_for(
        'show',
        query    => { view => 'full' },
        fragment => 'details',
    );

    my $same_path = path_for($scope, 'show', { id => 42 });
    my $same_url  = url_for($scope, 'show', { id => 42 });

=head1 DESCRIPTION

C<PAGI::Routing::URL> provides handler-bound reverse routing from the current
version-1 C<pagi.routing> frame. It accepts an unblessed scope hashref or an
object with a C<scope> method. The facade stores that exact scope and reads its
current routing frame when each operation runs, so construction does not
freeze an ancestor frame before final route selection.

The facade is cheap and has no identity guarantee. It stores no helper object,
cache record, Resolver record, or other key in the scope. Rendering remains in
L<PAGI::Routing::Resolver>; this class only validates the routing frame and
supplies its request-local namespace, captures, root boundary, and scope.

=head1 EXPORTS

Nothing is exported by default. C<url>, C<path_for>, and C<url_for> are opt-in
named exports and are all available through the uppercase C<:ALL> tag.

=head2 url

    my $urls = url($scope);
    my $urls = url($request);

Constructs and returns a C<PAGI::Routing::URL> facade. It always accepts
exactly one source and never changes return type based on arity.

=cut

sub url { return __PACKAGE__->new(@_) }

=head1 CONSTRUCTOR

=head2 new

    my $urls = PAGI::Routing::URL->new($scope);
    my $urls = PAGI::Routing::URL->new($request);

Stores the exact scope obtained from one unblessed scope hashref or object with
a C<scope> method. Routing metadata is validated when C<path_for> or C<url_for>
runs so the operation observes the latest selected frame.

=cut

sub new {
    my ($class, @arguments) = @_;
    my $scope = PAGI::Utils::Scope::scope_from_source($class, @arguments);
    return bless { scope => $scope }, $class;
}

=head1 METHODS AND DELEGATED FUNCTIONS

=head2 path_for

    my $path = $urls->path_for('show', { id => 42 });
    my $path = path_for($request, 'show', { id => 42 });

Resolves a route relative to the current frame unless its reference begins
with C</>. Relative calls inherit only captures required by the exact target;
explicit parameters override inherited values. The compiled routing boundary's
C<root_path> is encoded and applied exactly once.

=cut

sub path_for {
    my ($source, @arguments) = @_;
    my $self = blessed($source) && $source->isa(__PACKAGE__)
        ? $source
        : __PACKAGE__->new($source);
    return $self->_path_for(@arguments);
}

sub _path_for {
    my $self = shift;
    return $self->_reverse_for('path_for', @_);
}

=head2 url_for

    my $absolute = $urls->url_for('show', { id => 42 });
    my $absolute = url_for($request, 'show', { id => 42 });

Uses the same reference and reverse-argument rules as C<path_for>, then
returns an absolute URL. HTTP and SSE targets map the scope scheme to C<http>
or C<https>; WebSocket targets map it to C<ws> or C<wss>. Authority selection
and validation are performed by L<PAGI::Authority> inside the Resolver.

Both operations accept compact C<(\%params, \%query, $fragment)> and named
C<(params =E<gt> ..., query =E<gt> ..., fragment =E<gt> ...)> forms. Query
pairs are sorted and component encoded. Dots navigate only when a complete
logical component is exactly C<.> or C<..>; lookup otherwise remains exact.

=cut

sub url_for {
    my ($source, @arguments) = @_;
    my $self = blessed($source) && $source->isa(__PACKAGE__)
        ? $source
        : __PACKAGE__->new($source);
    return $self->_url_for(@arguments);
}

sub _url_for {
    my $self = shift;
    return $self->_reverse_for('url_for', @_);
}

sub _reverse_for {
    my ($self, $operation, $reference, @reverse_arguments) = @_;
    my $frame = $self->_routing_frame($operation);
    my $scope = $self->{scope};
    my $root_path = exists $frame->{root_path}
        ? $frame->{root_path}
        : $scope->{root_path};
    return $frame->{resolver}->reverse_for_scope(
        $operation,
        $scope,
        $reference,
        $root_path,
        $frame->{logical_namespace},
        $frame->{captures},
        @reverse_arguments,
    );
}

sub _routing_frame {
    my ($self, $operation) = @_;
    my $container = $self->{scope}{'pagi.routing'};
    my $valid = ref($container) eq 'HASH'
        && defined $container->{version}
        && !ref($container->{version})
        && $container->{version} eq '1'
        && ref($container->{frames}) eq 'ARRAY'
        && @{$container->{frames}};

    if ($valid) {
        for my $frame (@{$container->{frames}}) {
            $valid = 0, last unless ref($frame) eq 'HASH'
                && blessed($frame->{resolver})
                && $frame->{resolver}->can('path_for')
                && $frame->{resolver}->can('reverse_for_scope')
                && PAGI::Routing::Resolver::_is_canonical_namespace(
                    $frame->{logical_namespace},
                )
                && ref($frame->{captures}) eq 'HASH'
                && ref($frame->{mounts}) eq 'ARRAY'
                && (!defined $frame->{match} || ref($frame->{match}) eq 'HASH')
                && (!exists $frame->{root_path}
                    || (defined $frame->{root_path} && !ref($frame->{root_path})));
        }
    }

    croak "$operation requires a PAGI::Routing resolver in scope"
        unless $valid;
    return $container->{frames}[-1];
}

1;

=head1 COMPATIBILITY

L<PAGI::Context/path_for> and L<PAGI::Context/url_for> remain compatibility
methods and lazily delegate here. New handler code can use this facade directly
without depending on Context.

=head1 SEE ALSO

L<PAGI::Routing>, L<PAGI::Routing::Router>, L<PAGI::Routing::Resolver>,
L<PAGI::Authority>

=cut
