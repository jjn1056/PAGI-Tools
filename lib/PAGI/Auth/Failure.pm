package PAGI::Auth::Failure;

use strict;
use warnings;

use Carp qw(croak);

sub _new {
    my ($class, $fields) = @_;

    croak 'failure must be a hash reference' unless ref($fields) eq 'HASH';
    for my $name (keys %$fields) {
        croak "failure has unknown field '$name'"
            unless $name eq 'message' || $name eq 'code';
    }
    croak 'failure message must be a defined scalar'
        unless exists($fields->{message})
            && defined($fields->{message})
            && !ref($fields->{message});
    croak 'failure code must be a defined scalar'
        if exists($fields->{code})
            && (!defined($fields->{code}) || ref($fields->{code}));

    return bless {
        message => $fields->{message},
        code    => $fields->{code},
    }, $class;
}

sub message { return $_[0]{message} }
sub code    { return $_[0]{code} }

1;

=head1 NAME

PAGI::Auth::Failure - public authentication rejection information

=head1 DESCRIPTION

Created through C<unauth_result(failure =E<gt> {...})> in L<PAGI::Auth>.
This value records an application-owned, public-safe reason for rejection.
It has no HTTP status, challenge, or response fields. The hash supplied to the
result helper requires a defined scalar C<message>, permits a defined scalar
C<code>, and rejects unknown fields.

=head1 METHODS

=head2 message

Returns the public-safe scalar message, including an empty string if supplied.

=head2 code

Returns the optional application-defined scalar code, or C<undef> when omitted.
An empty string is a valid supplied code.

C<_new> is private; applications create failures through authentication result
helpers.

=cut
