package PAGI::Utils::Random;

use strict;
use warnings;
use Exporter 'import';
use Carp qw(croak);

our @EXPORT_OK = qw(secure_random_bytes);

sub secure_random_bytes {
    my ($length) = @_;
    croak 'secure_random_bytes length must be a non-negative integer'
        unless defined $length && !ref $length && $length =~ /\A[0-9]+\z/;

    # Try /dev/urandom first (Unix)
    if (open my $fh, '<:raw', '/dev/urandom') {
        my $bytes;
        read($fh, $bytes, $length);
        close $fh;
        return $bytes if defined $bytes && length($bytes) == $length;
    }

    # Fallback: use Crypt::URandom if available
    if (eval { require Crypt::URandom; 1 }) {
        return Crypt::URandom::urandom($length);
    }

    die "No secure random source available (need /dev/urandom or Crypt::URandom)\n";
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

Tries C</dev/urandom> first, then falls back to L<Crypt::URandom>.
Dies if no secure source is available.

=head1 PLATFORM NOTES

On Unix, Linux, and macOS, C</dev/urandom> is used directly and no
additional modules are needed. On systems without C</dev/urandom>
(notably Windows), install L<Crypt::URandom> to provide a secure
random source.

=cut
