package PAGI::Utils::_SetCookie;

use strict;
use warnings;
use Carp qw(croak);

# The caller's caller is the one at fault, so the writers' own packages are skipped.
our @CARP_NOT = qw(PAGI::Response PAGI::Middleware::Cookie PAGI::Middleware::Cookie::Jar);

=head1 NAME

PAGI::Utils::_SetCookie - Private Set-Cookie writer

=head1 DESCRIPTION

Private to PAGI-Tools; not a public interface. L<PAGI::Response/cookie> and
the L<PAGI::Middleware::Cookie> jar write their Set-Cookie values with it.

=head2 set_cookie_string

    my $set_cookie = set_cookie_string($name, $value, %attrs);

Returns a Set-Cookie value. C<$value> must consist of RFC 6265 cookie-octets
(C<%x21 / %x23-2B / %x2D-3A / %x3C-5B / %x5D-7E>: no control character,
whitespace, C<">, C<,>, C<;> or C<\>) and is written as is; anything else
croaks, because a browser ends a value at the first C<;> and other readers
split on C<,> or strip quotes, so only these characters read back unchanged
through any client. A name outside C<A-Za-z0-9-._~> is percent-encoded.

The attributes are C<domain>, C<path>, C<expires> (an epoch number, a
relative time such as C<+1h>, C<now>, or a ready date string), C<max-age>,
C<samesite> (C<lax>, C<strict> or C<none>, any case; C<none> implies
C<secure>), C<secure>, C<httponly> and C<partitioned> (which implies
C<SameSite=None> and C<secure>). They are written in that order.

=cut

my @MON  = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
my @WDAY = qw(Sun Mon Tue Wed Thu Fri Sat);
my %TERM = (
    s => 1, m => 60, h => 3600, d => 86400,
    M => 86400 * 30, y => 86400 * 365,
);

sub set_cookie_string {
    my ($name, $value, %attrs) = @_;

    if ($value =~ /([^\x21\x23-\x2B\x2D-\x3A\x3C-\x5B\x5D-\x7E])/) {
        croak "cookie value contains '$1' which browsers cannot carry; "
            . "encode it first (Base64, say)";
    }
    if ($attrs{partitioned}) {
        $attrs{samesite} = 'none';
        $attrs{secure}   = 1;
    }
    $name =~ s/([^A-Za-z0-9\-._~])/sprintf '%%%02X', ord $1/ge;

    my @parts = ("$name=$value");
    push @parts, "domain=$attrs{domain}" if $attrs{domain};
    push @parts, "path=$attrs{path}"     if $attrs{path};
    push @parts, 'expires=' . _date($attrs{expires}) if defined $attrs{expires};
    push @parts, "max-age=$attrs{'max-age'}" if exists $attrs{'max-age'};
    if (defined $attrs{samesite} && $attrs{samesite} =~ /\A(?:lax|strict|none)\z/i) {
        my $samesite = ucfirst lc $attrs{samesite};
        push @parts, "SameSite=$samesite";
        $attrs{secure} = 1 if $samesite eq 'None';
    }
    push @parts, 'secure'      if $attrs{secure};
    push @parts, 'HttpOnly'    if $attrs{httponly};
    push @parts, 'Partitioned' if $attrs{partitioned};
    return join '; ', @parts;
}

sub _date {
    my ($expires) = @_;

    my $expires_at;
    if ($expires =~ /\A\d+\z/) {
        $expires_at = $expires;
    }
    elsif ($expires =~ /\A([-+]?(?:\d+|\d*\.\d*))([smhdMy]?)/) {
        no warnings;
        $expires_at = time + ($TERM{$2} || 1) * $1;
    }
    elsif ($expires eq 'now') {
        $expires_at = time;
    }
    else {
        return $expires;
    }
    my ($sec, $min, $hour, $mday, $mon, $year, $wday) = gmtime $expires_at;
    return sprintf '%s, %02d-%s-%04d %02d:%02d:%02d GMT',
        $WDAY[$wday], $mday, $MON[$mon], $year + 1900, $hour, $min, $sec;
}

1;
