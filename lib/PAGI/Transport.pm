package PAGI::Transport;

use strict;
use warnings;
use Carp qw(croak);
use Exporter 'import';
use Scalar::Util qw(blessed);
use PAGI::Utils::Scope ();

our @EXPORT = ();
our @EXPORT_OK = qw(transport);
our %EXPORT_TAGS = (ALL => [@EXPORT_OK]);

=head1 NAME

PAGI::Transport - Optional outbound flow-control facade

=head1 SYNOPSIS

    use PAGI::Transport qw(transport);

    my $flow = transport($request);
    if ($flow && !$flow->is_writable) {
        $flow->on_drain(sub { resume_producer() });
    }

=head1 DESCRIPTION

C<PAGI::Transport> wraps the optional C<pagi.transport> handle supplied in a
PAGI scope. A present handle must implement C<buffered_amount>. Watermarks and
callback registration are optional capabilities and degrade quietly when the
handle does not implement them.

The facade stores only the provided handle. It does not add a cache key to the
scope, and callers must not rely on identity between separate constructor
calls.

=head1 FUNCTIONS

=head2 transport

    my $flow = transport($scope);
    my $flow = transport($request);

Returns C<undef> when the source has no transport handle. Otherwise constructs
a facade from exactly one unblessed scope hashref or object with a C<scope>
method. This function is an opt-in named export and is also available through
the uppercase C<:ALL> tag. Nothing is exported by default.

=cut

sub transport { return __PACKAGE__->new(@_) }

=head1 CONSTRUCTOR

=head2 new

    my $flow = PAGI::Transport->new($source);

Returns C<undef> without C<pagi.transport>. A present provider must be an
object implementing C<buffered_amount>.

=cut

sub new {
    my ($class, @arguments) = @_;
    my $scope = PAGI::Utils::Scope::scope_from_source($class, @arguments);
    my $handle = $scope->{'pagi.transport'};
    return undef unless defined $handle;
    croak 'PAGI::Transport handle requires buffered_amount capability'
        unless blessed($handle) && $handle->can('buffered_amount');
    return bless { handle => $handle }, $class;
}

=head1 METHODS

=head2 buffered_amount

Returns the number of outbound bytes queued by the transport.

=cut

sub buffered_amount { return $_[0]{handle}->buffered_amount }

=head2 high_water_mark

Returns the high watermark, or C<undef> when the transport does not provide
that capability.

=head2 low_water_mark

Returns the low watermark, or C<undef> when the transport does not provide
that capability.

=cut

sub high_water_mark {
    my ($self) = @_;
    my $handle = $self->{handle};
    return undef unless $handle->can('high_water_mark');
    return $handle->high_water_mark;
}

sub low_water_mark {
    my ($self) = @_;
    my $handle = $self->{handle};
    return undef unless $handle->can('low_water_mark');
    return $handle->low_water_mark;
}

=head2 on_high_water

Registers a high-water callback when supported and returns the facade for
chaining. A missing callback capability is a no-op.

=head2 on_drain

Registers a drain callback when supported and returns the facade for chaining.
A missing callback capability is a no-op.

=cut

sub on_high_water {
    my ($self, $callback) = @_;
    my $handle = $self->{handle};
    $handle->on_high_water($callback) if $handle->can('on_high_water');
    return $self;
}

sub on_drain {
    my ($self, $callback) = @_;
    my $handle = $self->{handle};
    $handle->on_drain($callback) if $handle->can('on_drain');
    return $self;
}

=head2 is_writable

Returns true when no high watermark is available or when C<buffered_amount>
is below the high watermark. A buffer at or above the high watermark is not
writable.

=cut

sub is_writable {
    my ($self) = @_;
    my $high = $self->high_water_mark;
    return 1 unless defined $high;
    return $self->buffered_amount < $high ? 1 : 0;
}

1;

=head1 SEE ALSO

L<PAGI::Request>, L<PAGI::WebSocket>, L<PAGI::SSE>

=cut
