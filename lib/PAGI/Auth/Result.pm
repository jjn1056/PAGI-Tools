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

=head1 DESCRIPTION

Created by C<auth_result> or C<unauth_result> in L<PAGI::Auth>. An installed
C<pagi.auth> entry holds this complete value. Its readers do not return a token,
HTTP status, challenge, or response. The result retains the supplied user and
its Credentials object.

=head1 METHODS

=head2 user

Returns the retained user object. The user implements C<is_authenticated>,
C<identity>, and C<display_name>. The authentication flag is independent of
granted scopes.

=head2 credentials

Returns the L<PAGI::Auth::Credentials> value containing live granted scopes.

=head2 failure

Returns the optional L<PAGI::Auth::Failure> value, or C<undef> for an accepted
identity or a guest without rejected credentials.

C<_new> is private; use the result helpers in L<PAGI::Auth>.

=cut
