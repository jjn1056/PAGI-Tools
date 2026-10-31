package PAGI::Utils::URI;

use strict;
use warnings;
use Carp qw(croak);
use Encode ();
use Hash::MultiValue;
use PAGI::Authority ();
use PAGI::Headers ();
use PAGI::Utils::Scope ();

use overload '""' => 'to_string', fallback => 1;

# A croak from a helper the constructors call names the caller's line.
our @CARP_NOT = qw(PAGI::Utils::Scope PAGI::Headers);

# A value holds scheme, host, port (undef unless explicit), raw_path,
# query_string and fragment, all set when it is built and never changed.
# path, the parsed query and the string form are derived from them on first
# use and kept, which is safe because the value never changes.

sub from_scope {
    my ($class, $scope) = @_;
    croak 'PAGI::Utils::URI->from_scope requires a scope hashref'
        unless ref($scope) eq 'HASH';
    PAGI::Utils::Scope::_require_connection_type($class, $scope);
    PAGI::Utils::Scope::_require_path_source($scope);

    my $scheme = PAGI::Utils::Scope::scheme($scope);
    my $host = PAGI::Headers->new($scope->{headers})->get('host');
    my $authority = defined $host && length $host
        ? $host
        : eval { PAGI::Authority::_format_server($scope->{server}, lc $scheme) }
            // croak 'no Host header, and the scope server cannot provide an authority';
    my ($raw_path, $query_string) = split /\?/, PAGI::Utils::Scope::request_uri($scope), 2;

    return $class->_new(
        scheme       => $scheme,
        _split_authority($authority),
        raw_path     => $raw_path,
        query_string => $query_string // '',
        fragment     => '',
        (defined $scope->{path} ? (path => ($scope->{root_path} // '') . $scope->{path}) : ()),
    );
}

sub parse {
    my ($class, $string) = @_;
    $string = Encode::encode('UTF-8', $string) if defined $string;
    my ($scheme, $authority, $path, $query, $fragment) = defined $string
        ? $string =~ m{\A(?:([^:/?#]+):)?(?://([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?\z}s
        : ();
    croak 'not an absolute URI'
        unless defined $scheme && $scheme =~ /\A[A-Za-z][A-Za-z0-9+.\-]*\z/
            && defined $authority;
    croak 'userinfo is not supported' if $authority =~ /\@/;

    return $class->_new(
        scheme       => $scheme,
        _split_authority($authority),
        raw_path     => PAGI::Utils::Scope::_escape_path_bytes($path),
        query_string => PAGI::Utils::Scope::_escape_unsafe_bytes($query // ''),
        fragment     => PAGI::Utils::Scope::_escape_unsafe_bytes($fragment // ''),
    );
}

sub _new {
    my ($class, %fields) = @_;
    return bless \%fields, $class;
}

# A copy with some parts changed. The decoded path is kept only while
# raw_path is.
sub _clone {
    my ($self, %changes) = @_;
    my %fields = map { $_ => $self->{$_} } qw(scheme host port raw_path query_string fragment);
    $fields{path} = $self->{path} if defined $self->{path} && !exists $changes{raw_path};
    return ref($self)->_new(%fields, %changes);
}

# An authority as host and port, as Mojo::URL reads a Host: a trailing
# ":digits" is the port, and the rest is percent-decoded.
sub _split_authority {
    my ($authority) = @_;
    my ($host, $port) = $authority =~ /\A(.*?)(?::([0-9]+))?\z/s;
    return (host => PAGI::Utils::Scope::_unescape($host), port => $port);
}

# The authority as it may appear in a URI: every byte outside Mojo::URL's
# allow-list is percent-encoded, so a Host cannot add a path, query,
# fragment or userinfo.
sub _escape_authority {
    my ($authority) = @_;
    $authority = Encode::encode('UTF-8', $authority) if $authority =~ /[^\x00-\xFF]/;
    $authority =~ s{([^A-Za-z0-9\-._~!\$&'()*+,;=:\[\]])}{sprintf('%%%02X', ord $1)}ge;
    return $authority;
}

# Readers take no arguments: a value never changes, and no reader has
# options.
sub _read_only {
    my ($self, @value) = @_;
    return unless @value;
    my $name = (caller 1)[3];
    $name =~ s/.*:://;
    croak "$name takes no arguments: a PAGI::Utils::URI never changes, and its readers take no options";
}

sub scheme       { _read_only(@_); $_[0]{scheme} }
sub host         { _read_only(@_); $_[0]{host} }
sub port         { _read_only(@_); $_[0]{port} }
sub raw_path     { _read_only(@_); $_[0]{raw_path} }
sub query_string { _read_only(@_); $_[0]{query_string} }
sub fragment     { _read_only(@_); $_[0]{fragment} }

sub authority {
    my $self = shift;
    _read_only($self, @_);
    return defined $self->{port} ? "$self->{host}:$self->{port}" : $self->{host};
}

sub path {
    my $self = shift;
    _read_only($self, @_);
    return $self->{path} //= PAGI::Utils::Scope::_decode_path($self->{raw_path});
}

# Each call returns a new Hash::MultiValue over the pairs parsed once, so a
# change made to it cannot reach the value.
sub query_params {
    my $self = shift;
    _read_only($self, @_);
    $self->{_query} //= [PAGI::Utils::Scope::_query_pairs($self->{query_string})];
    return Hash::MultiValue->new(@{ $self->{_query} });
}

sub raw_query_params {
    my $self = shift;
    _read_only($self, @_);
    $self->{_query_raw} //= [PAGI::Utils::Scope::_query_pairs($self->{query_string}, raw => 1)];
    return Hash::MultiValue->new(@{ $self->{_query_raw} });
}

sub to_string {
    my $self = shift;
    return $self->{_string} //= join '',
        $self->{scheme}, '://', _escape_authority($self->authority), $self->{raw_path},
        (length $self->{query_string} ? ('?', $self->{query_string}) : ()),
        (length $self->{fragment} ? ('#', $self->{fragment}) : ());
}

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::Utils::URI - The request's URL as an immutable value

=head1 SYNOPSIS

    # From a connection: $request, $websocket or $sse
    my $uri = $request->uri;    # https://example.com/app/items/42?page=2

    $uri->scheme;               # https
    $uri->authority;            # example.com
    $uri->host;                 # example.com
    $uri->port;                 # undef: none in the URL
    $uri->path;                 # /app/items/42 (decoded text)
    $uri->raw_path;             # /app/items/42 (escaped bytes)
    $uri->query_string;         # page=2
    $uri->query_params->get('page');   # 2
    "$uri";                     # https://example.com/app/items/42?page=2

    my $base = $request->base_uri;     # https://example.com/app/

    # From a scope, or from a string
    my $uri = PAGI::Utils::URI->from_scope($scope);
    my $uri = PAGI::Utils::URI->parse('https://example.com/a%2Fb?x=1');

=head1 DESCRIPTION

A PAGI::Utils::URI is a URL as a value: it is built once and never changes,
so it can be kept, passed around and compared. L<PAGI::HTTPConnection/uri>
gives the request's URL as one, so every L<PAGI::Request>, L<PAGI::WebSocket>
and L<PAGI::SSE> has it, and L<PAGI::HTTPConnection/base_uri> the
application's root URL.

Text and bytes are kept apart. Text given to it is UTF-8 encoded and
percent-encoded; text read from it (L</path>, L</query_params>) is decoded;
bytes go through the C<raw_> forms (L</raw_path>, L</raw_query_params>).

The string form is safe to put in a C<Location> header, a page or a log
line: an unedited request URL is C<scheme://authority> followed by
L<PAGI::HTTPConnection/request_uri>, exactly.

=head2 The host is not validated

The authority of a request URL is the client's C<Host> header, read as
Mojolicious reads it: nothing checks that it is a host name. A trailing
C<:digits> is the port, the rest is percent-decoded (C<Host: a%41> has the
host C<aA>), and a C<Host> sent more than once reads as every value joined
with C<", ">, as L<PAGI::HTTPConnection/header> does. Without a
C<Host> (HTTP/1.0), or with an empty one, the authority is the server's
address from the scope, without the port when it is the scheme's default
(80 for C<http> and C<ws>, 443 for C<https> and C<wss>).

In the string form the authority is percent-encoded: every byte outside
C<A-Za-z0-9-._~!$&'()*+,;=:[]> (Mojo::URL's list) becomes C<%XX>, so a
hostile C<Host> cannot change the path or query. C<Host: evil.com/x?> on
C<GET /items?page=1> gives C<http://evil.com%2Fx%3F/items?page=1>, and
C<Host: evil.com%2Fx>, whose host reads C<evil.com/x>, is written
C<evil.com%2Fx> again.

To accept only the hosts an application serves, put
C<middleware('TrustedHosts', hosts =E<gt> [...])> (L<PAGI::Middleware::TrustedHosts>)
first: it answers 400 to any other C<Host> before the request reaches code
that reads this one.

=head2 Equality

C<eq> and C<ne> compare the string forms byte for byte (through the C<"">
overload), with no normalisation: C<http://Example.COM/> and
C<http://example.com/> differ, as the C<Host> spelling differs.

=head1 CONSTRUCTORS

=head2 from_scope

    my $uri = PAGI::Utils::URI->from_scope($scope);

The URL of the request in an C<http>, C<websocket> or C<sse> scope: its
scheme (without one, C<ws> for a WebSocket scope and C<http> otherwise), its
authority as described in L</The host is not validated>, and its path and
query as L<PAGI::HTTPConnection/request_uri> gives them. The fragment is
C<''>: a client does not send one. The value copies what it reads, so a
later change to the scope does not reach it, and it writes nothing to the
scope.

Dies as L<PAGI::HTTPConnection/new> does when the scope's C<type> is
missing or is not C<http>, C<websocket> or C<sse>; C<this scope has no
path> when the scope has neither C<raw_path> nor C<path>; and C<no Host
header, and the scope server cannot provide an authority> when it has no
C<Host> and no usable C<server>.

=head2 parse

    my $uri = PAGI::Utils::URI->parse('https://example.com:8443/a%2Fb?x=1#top');

A URL from its string form, split as RFC 3986 appendix B splits a URI. It
must have a scheme and an authority (C<scheme://...>), or it dies C<not an
absolute URI>; an authority with userinfo (C<user:pw@host>) dies
C<userinfo is not supported>.

The string is characters. Every non-ASCII character is UTF-8 encoded and
then percent-encoded, in the authority, path, query and fragment alike:
C<caf\x{e9}> is written C<caf%C3%A9>. An existing C<%XX> is kept as it is,
so C<caf%C3%A9> stays C<caf%C3%A9>. Pass a URL as a string of characters,
not as UTF-8 bytes, which would be encoded a second time. Anything else a
URI cannot hold in the path, query or fragment is percent-encoded too, as
the string form would show it.

The authority is read as L</from_scope> reads a C<Host>: a trailing
C<:digits> is the port, and the rest is percent-decoded. The string form of
a value from L</from_scope> or L</parse> parses back to a value with the
same string form, though not always the same host and port: C<Host:
a%3A80> has the host C<a:80> and no port, and its string form
C<http://a:80/> parses to the host C<a> and the port C<80>.

=head1 READERS

Each reader takes no arguments and has no options; given any, it dies
C<... takes no arguments>.

=head2 scheme

    my $scheme = $uri->scheme;   # http, https, ws or wss

The scheme, as the scope or the string gave it.

=head2 authority

    my $authority = $uri->authority;   # example.com:8080

The host, then C<:> and the port when the URL has one; unescaped. For a
request, the C<Host> header percent-decoded (see L</The host is not
validated>).

=head2 host

    my $host = $uri->host;   # example.com, [::1]

The authority without its port. An IPv6 address keeps its brackets.
Unvalidated and unescaped.

=head2 port

    my $port = $uri->port;   # 8080, or undef

The port written in the URL, or C<undef> when there is none. It is not
filled with the scheme's default: C<Host: example.com> has no port, and
C<Host: example.com:80> has C<80>.

=head2 path

    my $path = $uri->path;   # /app/café

The path as decoded text, with the root path: for a request,
C<root_path> followed by C<path> from the scope. Otherwise L</raw_path>
percent-decoded and then UTF-8 decoded, left as bytes when it is not UTF-8,
as a server decodes a request path. An encoded C</> reads as C</>; use
L</raw_path> to tell them apart.

=head2 raw_path

    my $raw_path = $uri->raw_path;   # /app/caf%C3%A9

The path as escaped bytes, with the root path, exactly as the string form
shows it.

=head2 query_string

    my $query = $uri->query_string;   # page=2&sort=name

The query without its C<?>, as the string form shows it; C<''> when there is
none.

=head2 query_params

    my $params = $uri->query_params;   # Hash::MultiValue
    my $page   = $params->get('page');

The query's parameters as a L<Hash::MultiValue> of decoded text, parsed as
L<PAGI::HTTPConnection/query_params> parses them (C<&> or C<;> between
pairs, C<+> as a space, invalid UTF-8 replaced). A repeated name keeps every
value; C<get> gives the last. Each call returns a new object, so changing it
does not change the URL.

=head2 raw_query_params

    my $params = $uri->raw_query_params;

As L</query_params>, with the names and values left as bytes.

=head2 fragment

    my $fragment = $uri->fragment;

The fragment without its C<#>; C<''> when there is none, and always for a
request URL.

=head2 to_string

    my $string = $uri->to_string;
    my $string = "$uri";

The URL as a string: C<scheme://>, the escaped authority, L</raw_path>, then
C<?> and L</query_string> and C<#> and L</fragment> when they are not empty.
Stringifying the value gives the same.

=head1 SEE ALSO

L<PAGI::HTTPConnection>, L<PAGI::Middleware::TrustedHosts>

=cut
