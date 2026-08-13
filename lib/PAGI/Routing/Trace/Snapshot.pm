package PAGI::Routing::Trace::Snapshot;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(refaddr);

my %SNAPSHOT_STATE;

sub _copy_value {
    my ($value) = @_;
    return [map { _copy_value($_) } @$value] if ref($value) eq 'ARRAY';
    if (ref($value) eq 'HASH') {
        return { map { $_ => _copy_value($value->{$_}) } keys %$value };
    }
    return $value;
}

sub _new {
    my ($class, $facts) = @_;
    croak 'routing trace snapshot facts must be a hash reference'
        unless ref($facts) eq 'HASH';
    my $self = bless {}, $class;
    $SNAPSHOT_STATE{refaddr($self)} = {
        routing_declined  => $facts->{routing_declined} ? 1 : 0,
        path_matched      => $facts->{path_matched} ? 1 : 0,
        method_matched    => $facts->{method_matched} ? 1 : 0,
        allowed_methods   => [@{$facts->{allowed_methods} || []}],
        attempts          => _copy_value($facts->{attempts} || []),
        details_available => $facts->{details_available} ? 1 : 0,
        truncated         => $facts->{truncated} ? 1 : 0,
    };
    return $self;
}

sub _state {
    my ($self) = @_;
    my $state = $SNAPSHOT_STATE{refaddr($self)};
    croak 'routing trace snapshot is invalid' unless $state;
    return $state;
}

sub routing_declined {
    return _state($_[0])->{routing_declined};
}

sub path_matched {
    return _state($_[0])->{path_matched};
}

sub method_matched {
    return _state($_[0])->{method_matched};
}

sub allowed_methods {
    return [@{_state($_[0])->{allowed_methods}}];
}

sub attempts {
    return _copy_value(_state($_[0])->{attempts});
}

sub details_available {
    return _state($_[0])->{details_available};
}

sub truncated {
    return _state($_[0])->{truncated};
}

sub DESTROY {
    my ($self) = @_;
    delete $SNAPSHOT_STATE{refaddr($self)};
    return;
}

1;

__END__

=head1 NAME

PAGI::Routing::Trace::Snapshot - Immutable routing evidence view

=head1 DESCRIPTION

A snapshot is a read-only view of trusted routing work within one collector
checkpoint window. It reports whether routing declined, matching summary facts,
and a deterministic allowed-method union. Array-valued methods always return
fresh defensive copies and the object representation does not contain its
facts.

Detailed candidate attempts are collected only after the routing compiler
resolves a development environment. They are absent in other environments and
bounded to the first 256 records per request; L</truncated> reports overflow.

=head1 METHODS

=head2 routing_declined

Reports whether at least one qualifying routing-aware search declined.

=head2 path_matched

Reports whether a qualifying decline contained a complete path match.

=head2 method_matched

Reports whether a qualifying complete path match accepted the request method.

=head2 allowed_methods

Returns a fresh array reference in first-seen order.

=head2 attempts

Returns a fresh array reference containing defensive copies of available
development attempt records.

=head2 details_available

Reports whether development attempt collection was enabled.

=head2 truncated

Reports whether the per-request attempt bound was reached.

=cut
