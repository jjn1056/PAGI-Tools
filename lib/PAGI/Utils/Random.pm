package PAGI::Utils::Random;

use strict;
use warnings;
use PAGI::Utils::_Exporter ();

my (%EXPORTS, %TAGS, @DEFAULTS);
BEGIN {
    %EXPORTS = (secure_random_bytes => \&secure_random_bytes);
    %TAGS    = (all => [sort keys %EXPORTS]);
}
sub import   { PAGI::Utils::_Exporter::export(__PACKAGE__, \%EXPORTS, \%TAGS, \@DEFAULTS, scalar caller, @_) }
sub _exports { \%EXPORTS }

use Carp qw(croak);
use Crypt::URandom ();

sub secure_random_bytes {
    my ($length) = @_;
    croak 'secure_random_bytes length must be a non-negative integer'
        unless defined $length && !ref $length && $length =~ /\A[0-9]+\z/;

    return Crypt::URandom::urandom($length);
}

1;

__END__

=head1 NAME

PAGI::Utils::Random - Cryptographically secure random bytes

=head1 SYNOPSIS

    use PAGI::Utils::Random qw(secure_random_bytes);

    my $bytes = secure_random_bytes(32);

=head1 FUNCTIONS

=head2 secure_random_bytes($length)

Returns C<$length> cryptographically secure random bytes. Croaks unless
C<$length> is a non-negative integer; C<0> returns an empty string.

The bytes come from L<Crypt::URandom>, which uses the operating system's
random source: a system call such as L<getrandom(2)> where one is
available, otherwise C</dev/urandom>, and the system API on Windows.

=cut
