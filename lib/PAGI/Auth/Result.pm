package PAGI::Auth::Result;

use strict;
use warnings;

sub _new {
    my ($class, %values) = @_;
    return bless \%values, $class;
}

sub user        { return $_[0]{user} }
sub credentials { return $_[0]{credentials} }
sub failure     { return $_[0]{failure} }

1;

=head1 NAME

PAGI::Auth::Result - completed authentication result

=head1 METHODS

=head2 user

Returns the supplied user object.

=head2 credentials

Returns the supplied L<PAGI::Auth::Credentials> value.

=head2 failure

Returns the optional L<PAGI::Auth::Failure> value.

C<_new> is private; use the result helpers in L<PAGI::Auth>.

=cut
