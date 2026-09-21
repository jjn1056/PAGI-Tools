package PAGI::Auth::UnauthenticatedUser;

use strict;
use warnings;

use Carp qw(croak);

sub new {
    my ($class, @args) = @_;
    croak 'UnauthenticatedUser does not accept options' if @args;
    return bless {}, $class;
}

sub is_authenticated { return 0 }
sub identity         { return '' }
sub display_name     { return '' }

1;

=head1 NAME

PAGI::Auth::UnauthenticatedUser - built-in unauthenticated user

=head1 CONSTRUCTION

=head2 new

Creates a fresh unauthenticated user. It accepts no options; any argument is an
error. Applications needing a different guest identity or display label may
supply their own three-method guest to C<unauth_result>, or override that helper
in a L<PAGI::Auth> factory subclass.

=head1 METHODS

=head2 is_authenticated

Returns false.

=head2 identity

Returns the empty string.

=head2 display_name

Returns the empty string without choosing an application display label.

=cut
