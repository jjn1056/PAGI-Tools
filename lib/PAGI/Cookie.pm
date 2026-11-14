package PAGI::Cookie;

use v5.24;
use warnings;
use Carp ();
# The getters are this class's own (read-only), so they're declared before
# Class::Tiny is loaded, which then makes no accessors of its own.
use subs qw(name value path domain expires max_age samesite secure httponly partitioned);
use Class::Tiny qw(name value path domain expires max_age samesite secure httponly partitioned);

# A cookie is immutable: built once, from what you give it, and checked
# then (_check): a cookie that exists is one a browser can carry. Nothing
# about it changes after.
sub BUILD {
    my ($self) = @_;
    $self->_check;
}

# The getters. Given a value, each croaks: nothing about a cookie changes.

sub name {
    my $self = shift;
    _immutable('name') if @_;
    return $self->{name};
}

# Yours, else empty.
sub value {
    my $self = shift;
    _immutable('value') if @_;
    return exists $self->{value} ? $self->{value} : '';
}

# Yours, undef included (no Path at all), else '/'.
sub path {
    my $self = shift;
    _immutable('path') if @_;
    return exists $self->{path} ? $self->{path} : '/';
}

sub domain {
    my $self = shift;
    _immutable('domain') if @_;
    return $self->{domain};
}

sub expires {
    my $self = shift;
    _immutable('expires') if @_;
    return $self->{expires};
}

sub max_age {
    my $self = shift;
    _immutable('max_age') if @_;
    return $self->{max_age};
}

sub samesite {
    my $self = shift;
    _immutable('samesite') if @_;
    return $self->{samesite};
}

sub secure {
    my $self = shift;
    _immutable('secure') if @_;
    return $self->{secure};
}

sub httponly {
    my $self = shift;
    _immutable('httponly') if @_;
    return $self->{httponly};
}

sub partitioned {
    my $self = shift;
    _immutable('partitioned') if @_;
    return $self->{partitioned};
}

sub _immutable {
    my ($name) = @_;
    Carp::croak("cookie is immutable: \$cookie->$name can't be set; build a new cookie");
}

# The header, ready for a response's headers or a start event's.
sub header {
    my ($self) = @_;
    return ['set-cookie', $self->as_string];
}

sub as_string {
    my ($self) = @_;
    my @parts = ($self->name . '=' . $self->value);
    push @parts, 'Path=' . $self->path                     if defined $self->path;
    push @parts, 'Domain=' . $self->domain                 if defined $self->domain;
    push @parts, 'Expires=' . _date($self->expires)        if defined $self->expires;
    push @parts, 'Max-Age=' . $self->max_age               if defined $self->max_age;
    push @parts, 'SameSite=' . ucfirst lc $self->samesite  if defined $self->samesite;
    push @parts, 'Secure'      if $self->secure;
    push @parts, 'HttpOnly'    if $self->httponly;
    push @parts, 'Partitioned' if $self->partitioned;
    return join '; ', @parts;
}

# The same cookie, emptied and expired: same name, path and domain, so the
# browser removes the one it has.
sub expired {
    my ($self) = @_;
    return ref($self)->new(
        (map { $_ => $self->$_ } qw(name path domain samesite secure httponly partitioned)),
        value => '', max_age => 0, expires => 0,
    );
}

sub _check {
    my ($self) = @_;
    my ($name, $value) = ($self->name, $self->value);
    Carp::croak('a cookie needs a name') unless defined $name && length $name;
    Carp::croak("cookie name contains '$1': a name is an RFC 6265 token")
        if $name =~ /([^!#\$%&'*+\-.^_`|~0-9A-Za-z])/;
    Carp::croak('cookie value must be a string, not ' . (defined $value ? 'a ' . ref($value) . ' reference' : 'undef'))
        if !defined $value || ref $value;
    Carp::croak("cookie value contains '$1', which browsers can't carry: encode it first (Base64 or URI::Escape)")
        if $value =~ /([^\x21\x23-\x2B\x2D-\x3A\x3C-\x5B\x5D-\x7E])/;
    for my $attr (qw(path domain)) {
        _plain_text($attr, $self->$attr) if defined $self->$attr;
    }
    _plain_text('expires', $self->expires) if defined $self->expires && $self->expires !~ /\A\d+\z/;
    Carp::croak('max_age must be a whole number of seconds')
        if defined $self->max_age && $self->max_age !~ /\A-?\d+\z/;
    Carp::croak('samesite must be lax, strict or none')
        if defined $self->samesite && $self->samesite !~ /\A(?:lax|strict|none)\z/i;
    _check_together($self);
    my $bytes = length $self->as_string;
    Carp::croak("cookie $name is $bytes bytes: browsers ignore one over 4096") if $bytes > 4096;
}

# What browsers require of attributes together (RFC 6265bis cookie
# prefixes; SameSite=None and Partitioned need Secure). Each croaks with
# the fix rather than adding it: you see what's sent.
sub _check_together {
    my ($self) = @_;
    my $name = $self->name;
    Carp::croak("a $1 cookie needs secure => 1") if $name =~ /\A(__Secure-|__Host-)/ && !$self->secure;
    Carp::croak("a __Host- cookie needs path => '/' and no domain")
        if $name =~ /\A__Host-/ && (($self->path // '') ne '/' || defined $self->domain);
    Carp::croak('samesite => none needs secure => 1: browsers drop it otherwise')
        if defined $self->samesite && lc $self->samesite eq 'none' && !$self->secure;
    Carp::croak('partitioned needs secure => 1') if $self->partitioned && !$self->secure;
}

# No ; and no control character: either would end or break the header.
sub _plain_text {
    my ($attr, $text) = @_;
    Carp::croak("cookie $attr can't contain ';' or a control character") if $text =~ /[;\x00-\x1F\x7F]/;
}

my @DAY   = qw(Sun Mon Tue Wed Thu Fri Sat);
my @MONTH = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);

# An epoch number as an HTTP date (RFC 9110 5.6.7); a string is yours, as given.
sub _date {
    my ($expires) = @_;
    return $expires unless $expires =~ /\A\d+\z/;
    my ($sec, $min, $hour, $mday, $mon, $year, $wday) = gmtime $expires;
    return sprintf '%s, %02d %s %04d %02d:%02d:%02d GMT',
        $DAY[$wday], $mday, $MONTH[$mon], $year + 1900, $hour, $min, $sec;
}

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::Cookie - One correct Set-Cookie header

=head1 SYNOPSIS

    use v5.40;
    use PAGI::Response;
    use PAGI::Cookie;

    sub session_cookie (%args) {
        PAGI::Cookie->new(name => 'session', httponly => 1, secure => 1, %args);
    }

    # Logging in: set it.
    PAGI::Response->new(status => 303,
        headers => [['location', '/'], session_cookie(value => $id, max_age => 86400)->header]);

    # Logging out: the same cookie, expired.
    PAGI::Response->new(status => 303,
        headers => [['location', '/login'], session_cookie()->expired->header]);

=head1 INHERITANCE

    PAGI::Cookie
      Class::Tiny::Object

C<new> comes from L<Class::Tiny>; the getters are this class's own.

=head1 DESCRIPTION

A cookie is a header: C<Set-Cookie>, with a name, a value and attributes.
This builds one, checked when you build it, so a cookie that exists is one
a browser will accept and read back unchanged; anything else croaks with
what to fix. Put its C<header> in a response's C<headers>, or push it onto
an C<http.response.start> event's headers in a middleware.

We follow RFC 6265 and don't encode for you. A value must be
cookie-octets: no space, C<">, C<,>, C<;>, C<\>, control character or
non-ASCII byte. Browsers end a value at C<;>, other readers split on C<,>
or strip quotes, so only these read back unchanged through every client.
Encode anything else yourself, with L<MIME::Base64> (URL-safe, unpadded) or
L<URI::Escape>, and decode it when you read it.

The only default is C<< path => '/' >>. Without a Path, a browser keeps
the cookie for the directory of the page that set it (RFC 6265 5.1.4), so
a session set by C</account/login> would be sent only under C</account/>.
SameSite, HttpOnly and Secure are choices for your application to make;
nothing is added you didn't ask for. Where attributes contradict what
browsers require, it croaks with the fix rather than adding it, so the
cookie you built is the one sent.

=head1 CONSTRUCTOR ARGUMENTS

    my $cookie = PAGI::Cookie->new(name => $name, value => $value, %attributes);

=over 4

=item name

Required: an RFC 6265 token (letters, digits and C<!#$%&'*+-.^_`|~>).

=item value

Cookie-octets, as above. Defaults to the empty string.

=item path

Defaults to C</>. C<undef> sends no Path. No C<;> or control character.

=item domain

No C<;> or control character.

=item expires

An epoch number, sent as an HTTP date (C<time + 3600> for an hour from
now), or a date string sent as given (no C<;> or control character).

=item max_age

Seconds, a whole number.

=item samesite

C<lax>, C<strict> or C<none>, any case; sent capitalized. None by default.

=item secure, httponly, partitioned

True to send the flag.

=back

What browsers require together croaks when it's missing: a C<__Secure->
or C<__Host-> name needs C<secure>, and C<__Host-> also C<< path => '/' >>
and no C<domain>; C<< samesite => 'none' >> and C<partitioned> need
C<secure>. A cookie whose header is over 4096 bytes croaks: browsers
ignore it.

=head1 METHODS

=head2 name, value, path, domain, expires, max_age, samesite, secure, httponly, partitioned

What it was built with. They only read: given a value, each croaks.

=head2 header

    my $pair = $cookie->header;   # ['set-cookie', '...']

The header, as the PAGI spec writes one, ready for C<headers>.

=head2 as_string

The header's value: C<name=value>, then Path, Domain, Expires, Max-Age,
SameSite, Secure, HttpOnly and Partitioned, as given.

=head2 expired

    my $gone = $cookie->expired;

The same cookie, emptied, with C<< max_age => 0 >> and an expiry in 1970.
A browser removes a cookie only when the name, path and domain match, so
expiring the cookie you set deletes it, and you can't get them wrong.

=head1 SEE ALSO

L<PAGI::Response>, RFC 6265 (cookies), RFC 9110 5.6.7 (HTTP dates)

=cut
