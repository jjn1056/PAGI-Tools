package PAGI::Auth::Challenge;

use strict;
use warnings;
use Hash::Util qw(lock_hashref);

sub _new {
    my ($class, %fields) = @_;
    my $self = bless \%fields, $class;
    lock_hashref($self);
    return $self;
}

sub scheme       { return $_[0]{scheme} }
sub header_value { return $_[0]{header_value} }
sub _kind        { return $_[0]{kind} }
sub _error       { return $_[0]{error} }

1;

=head1 NAME

PAGI::Auth::Challenge - immutable authentication challenge metadata

=head1 DESCRIPTION

A challenge is protocol metadata for one C<WWW-Authenticate> field line. It is
not a L<PAGI::Response> and does not send events. Construct values with
L<PAGI::Auth/basic>, L<PAGI::Auth/bearer>, or
L<PAGI::Auth/custom_challenge>; there is no public constructor.

=head1 METHODS

=head2 scheme

Returns the authentication scheme exactly as supplied by its builder.

=head2 header_value

Returns the validated, serialized field value. When an outcome has several
challenges, each value remains a separate C<WWW-Authenticate> field line.

=head1 SEE ALSO

L<PAGI::Auth>, L<PAGI::Auth::Outcomes>

=cut
