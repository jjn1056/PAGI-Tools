package PAGI::Response::Redirect;

use v5.24;
use warnings;
use parent 'PAGI::Response';
use Carp ();
use Encode ();
use overload ();

my %REDIRECT = map { $_ => 1 } qw(301 302 303 307 308);

sub prepare {
    my ($self, $args) = @_;
    my $url = $args->{url};
    Carp::croak('url must be a string, or an object that stringifies')
        if ref $url && !overload::Method($url, '""');
    Carp::croak('url is required: where to send the client')
        unless defined $url && length "$url";
    Carp::croak('a redirect has no body: give url, not content') if exists $args->{content};
    for my $header (@{ $args->{headers} // [] }) {
        (my $name = $header->[0]) =~ tr/A-Z/a-z/;
        Carp::croak('Redirect sets location itself, from url') if $name eq 'location';
    }
    $self->SUPER::prepare($args);
    push @{ $self->{headers} }, ['location', _location("$url")];
    return;
}

# The status: yours, else 302, the redirect most frameworks default to.
# Browsers follow it with a GET, so it's safe after a form is posted; 307
# would post the form again (Starlette's default, and its well-known trap).
sub prepare_status {
    my ($self, $args) = @_;
    my $status = $args->{status} // 302;
    Carp::croak("status $status isn't a redirect: use 301, 302, 303, 307 or 308")
        unless $REDIRECT{$status};
    return $status;
}

# No body: the Location says it all.
sub prepare_body { return '' }

# The URL as a Location: its characters as UTF-8 bytes, then every byte
# that isn't allowed in a URL as it stands percent-encoded. What a valid URL
# has, its %XX escapes included, is left as it is (Starlette's quote does
# the same). A CR or LF is encoded too, so it can't end the header.
sub _location {
    my ($url) = @_;
    my $bytes = Encode::encode('UTF-8', $url);
    $bytes =~ s/([^A-Za-z0-9\-._~:\/%#?=@\[\]!\$&'()*+,;])/sprintf '%%%02X', ord $1/ge;
    return $bytes;
}

1;

=encoding UTF-8

=head1 NAME

PAGI::Response::Redirect - a response that sends the client somewhere else

=head1 SYNOPSIS

    use v5.40;
    use utf8;
    use Future::AsyncAwait;
    use PAGI::Response::Redirect;

    my $app = async sub ($scope, $receive, $send) {
        die "unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';
        # After a form is posted: See Other, a GET of the new place.
        my $response = PAGI::Response::Redirect->new(url => '/search?q=Grüße', status => 303);
        await $response->call($scope, $receive, $send);
    };

    $app;

=head1 DESCRIPTION

A redirect is only a 3xx status and a Location header, and you can send one
with L<PAGI::Response> and no help:

    PAGI::Response->new(status => 303, headers => [[location => $url]]);

We provide this class because that's surprisingly easy to get wrong. A URL
with a space, or any character outside ASCII, has to be percent-encoded, as
UTF-8, before it can go in a header, or the client gets a Location it can't
follow. Even with L<URI> it's a trap: given characters, URI escapes C<ü> as
C<%FC> (Latin-1) or C<%C3%BC> (UTF-8) depending on how Perl happens to hold
the string. This class encodes the URL as UTF-8 first, then percent-encodes
what a URL can't carry at all, every time. A URL that's already valid, its
C<%XX> escapes included, is sent as it is, and a CR or LF is encoded, so it
can never start a header of its own.

=head2 Values you put in the URL are yours to encode

Redirect can't tell a C<&> or C<#> you meant from one that came in a value,
so it leaves every character a URL may contain as it is. A value you put in
a query or a path, from the request say, you encode first, and Redirect then
leaves your C<%XX> escapes alone. Without that, a search for C<a&admin=1>
becomes C<?q=a&admin=1>, a second parameter, and C<x#y> is cut at the C<#>:

    use Encode ();

    # A value for a query or a path segment: UTF-8, then everything but
    # the unreserved characters percent-encoded (RFC 3986).
    sub escape_value ($value) {
        my $bytes = Encode::encode('UTF-8', $value);
        $bytes =~ s/([^A-Za-z0-9\-._~])/sprintf '%%%02X', ord $1/ge;
        return $bytes;
    }

    PAGI::Response::Redirect->new(url => '/results?q=' . escape_value($q), status => 303);

The same goes for a path you take from C<< $scope->{path} >>, which the
server has decoded: use C<< $scope->{raw_path} >>, still encoded, instead.

The response has no body; a client follows the Location. If you'd rather
build the Location yourself, the plain response above is all a redirect is.

=head1 CONSTRUCTOR ARGUMENTS

=over 4

=item url

Required. Where to send the client: a path (C</next>) or an absolute URL,
as characters. Characters outside ASCII are encoded as UTF-8; bytes you
encoded already would be encoded a second time. Escapes you made for a
value (L</Values you put in the URL are yours to encode>) stay as they are.
An object that overloads stringification is its string. A L<URI> object's
string is already escaped and is sent as it is, so build it from UTF-8
bytes, not characters, or the URI trap above applies.

=item status

302 unless you give one, and one of the redirects:

    301 Moved Permanently     permanent; the method may change to GET
    302 Found                 temporary; the method may change to GET
    303 See Other             temporary; always a GET of the new place
    307 Temporary Redirect    temporary; same method and body
    308 Permanent Redirect    permanent; same method and body

After a form is posted, 302 or 303 sends the browser to GET a result page;
307 and 308 would post the form again to the new address, so give them only
when that's what you want. Any other status dies.

=item headers

As L<PAGI::Response>'s, except Location, which the class sets from C<url>:
giving one dies. Cookies set with C<set_cookie> are sent, so a redirect
after a login can carry the session.

=back

=head1 METHODS

=head2 prepare

Checks C<url> and the headers, does L<PAGI::Response>'s steps, then adds the
Location.

=head2 prepare_status

The status you gave, else 302, refusing one that isn't a redirect.

=head2 prepare_body

The empty string: a redirect has no body.

=head1 SEE ALSO

L<PAGI::Response>

=cut
