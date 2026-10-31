package PAGI::Utils::URI;

use strict;
use warnings;
use Carp qw(croak);
use Encode ();
use Hash::MultiValue;
use Scalar::Util qw(blessed);
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

my $SCHEME = qr/\A[A-Za-z][A-Za-z0-9+.\-]*\z/;

sub parse {
    my ($class, $string) = @_;
    my ($scheme, $authority, $path, $query, $fragment) = _split_reference($string);
    croak 'not an absolute URI'
        unless defined $scheme && $scheme =~ $SCHEME && defined $authority;
    croak 'userinfo is not supported' if $authority =~ /\@/;

    return $class->_new(
        scheme       => $scheme,
        _split_authority($authority),
        raw_path     => _one_leading_slash(PAGI::Utils::Scope::_escape_path_bytes($path)),
        query_string => PAGI::Utils::Scope::_escape_unsafe_bytes($query // ''),
        fragment     => PAGI::Utils::Scope::_escape_unsafe_bytes($fragment // ''),
    );
}

# A URI reference split as RFC 3986 appendix B splits one: scheme,
# authority, path, query and fragment, each undef when absent (the path is
# always defined). The reference is characters, UTF-8 encoded first.
sub _split_reference {
    my ($reference) = @_;
    return () unless defined $reference;
    return Encode::encode('UTF-8', $reference)
        =~ m{\A(?:([^:/?#]+):)?(?://([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?\z}s;
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
    my ($host, $port) = _host_and_port($authority);
    return (host => PAGI::Utils::Scope::_unescape($host), port => $port);
}

# An authority's host and port as written, the port undef when there is none.
sub _host_and_port {
    my ($authority) = @_;
    return $authority =~ /\A(.*?)(?::([0-9]+))?\z/s;
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

# Edits. Each returns a new value and leaves this one as it was.

sub with_query {
    my ($self, @edits) = @_;
    croak 'with_query takes name => value pairs' if @edits % 2;
    my @pairs = $self->_raw_query_pairs;
    while (@edits) {
        my ($name, $value) = splice @edits, 0, 2;
        @pairs = (
            _without_names(\@pairs, _utf8($name)),
            _query_bytes($name => $value),
        );
    }
    return $self->_clone(_query_fields(@pairs));
}

sub without_query {
    my ($self, @names) = @_;
    my @pairs = _without_names([$self->_raw_query_pairs],
        map { _utf8($_) } @names);
    return $self->_clone(_query_fields(@pairs));
}

my %REPLACEABLE = map { $_ => 1 }
    qw(scheme authority host port path raw_path query_params query_string fragment);

sub replace {
    my ($self, @parts) = @_;
    croak 'replace takes name => value pairs' if @parts % 2;
    my %parts = @parts;
    my @unknown = grep { !$REPLACEABLE{$_} } sort keys %parts;
    croak "replace cannot change: @unknown" if @unknown;
    croak 'replace takes authority, or host and port, not both'
        if exists $parts{authority} && (exists $parts{host} || exists $parts{port});
    croak 'replace takes path or raw_path, not both'
        if exists $parts{path} && exists $parts{raw_path};
    croak 'replace takes query_params or query_string, not both'
        if exists $parts{query_params} && exists $parts{query_string};

    my %changes;
    if (exists $parts{scheme}) {
        croak 'not a scheme: ' . ($parts{scheme} // 'undef')
            unless defined $parts{scheme} && $parts{scheme} =~ $SCHEME;
        $changes{scheme} = $parts{scheme};
    }
    if (exists $parts{authority}) {
        croak 'authority must be defined' unless defined $parts{authority};
        @changes{qw(host port)} = _host_and_port($parts{authority});
    }
    if (exists $parts{host}) {
        croak 'host must be defined' unless defined $parts{host};
        $changes{host} = $parts{host};
    }
    if (exists $parts{port}) {
        croak 'port must be digits or undef'
            if defined $parts{port} && $parts{port} !~ /\A[0-9]+\z/;
        $changes{port} = $parts{port};
    }
    if (exists $parts{path} || exists $parts{raw_path}) {
        my $raw_path = exists $parts{path}
            ? PAGI::Utils::Scope::_encode_path($parts{path} // '')
            : PAGI::Utils::Scope::_escape_path_bytes($parts{raw_path} // '');
        croak 'a path must be empty or start with /' if $raw_path =~ m{\A[^/]};
        $changes{raw_path} = _one_leading_slash($raw_path);
    }
    if (exists $parts{query_params}) {
        my @params = _query_param_list($parts{query_params});
        my @pairs;
        push @pairs, _query_bytes(splice @params, 0, 2) while @params;
        %changes = (%changes, _query_fields(@pairs));
    }
    $changes{query_string} = PAGI::Utils::Scope::_escape_unsafe_bytes($parts{query_string} // '')
        if exists $parts{query_string};
    $changes{fragment} = PAGI::Utils::Scope::_escape_unsafe_bytes(_utf8($parts{fragment} // ''))
        if exists $parts{fragment};
    return $self->_clone(%changes);
}

sub resolve {
    my ($self, $reference) = @_;
    croak 'resolve requires a reference' unless defined $reference;
    my ($scheme, $authority, $path, $query, $fragment) = _split_reference($reference);

    # A reference with an authority names its own host: it is parsed as a
    # URI, with this one's scheme when it has none.
    if (defined $scheme || defined $authority) {
        croak 'a reference with a scheme must have an authority' unless defined $authority;
        my $target = ref($self)->parse(defined $scheme ? $reference : "$self->{scheme}:$reference");
        return $target->_clone(raw_path => _one_leading_slash(_remove_dot_segments($target->{raw_path})));
    }

    my %changes = (fragment => PAGI::Utils::Scope::_escape_unsafe_bytes($fragment // ''));
    $path = PAGI::Utils::Scope::_escape_path_bytes($path);
    if (length $path) {
        my $merged = $path =~ m{\A/}      ? $path
            : length $self->{raw_path}    ? ($self->{raw_path} =~ s{[^/]*\z}{}r) . $path
            :                               "/$path";
        $changes{raw_path} = _one_leading_slash(_remove_dot_segments($merged));
        $changes{query_string} = PAGI::Utils::Scope::_escape_unsafe_bytes($query // '');
    }
    elsif (defined $query) {
        $changes{query_string} = PAGI::Utils::Scope::_escape_unsafe_bytes($query);
    }
    return $self->_clone(%changes);
}

# A path parse or an edit sets starts with at most one "/", as request_uri's
# does: a path read on its own must never name another host
# ("//evil.example/").
sub _one_leading_slash {
    my ($raw_path) = @_;
    $raw_path =~ s{\A/{2,}}{/};
    return $raw_path;
}

# RFC 3986 5.2.4: the "." and ".." segments of a path removed, each ".."
# taking the segment before it with it.
sub _remove_dot_segments {
    my ($input) = @_;
    my $output = '';
    while (length $input) {
        if ($input =~ s{\A\.\.?/}{}) {
            # A: a leading "../" or "./" goes
        }
        elsif ($input =~ s{\A/\.(?:/|\z)}{/}) {
            # B: "/./" or a final "/." is "/"
        }
        elsif ($input =~ s{\A/\.\.(?:/|\z)}{/}) {
            # C: "/../" or a final "/.." is "/", and the last output segment goes
            $output =~ s{/?[^/]*\z}{};
        }
        elsif ($input =~ /\A\.\.?\z/) {
            # D: a lone "." or ".."
            $input = '';
        }
        else {
            # E: the first segment moves to the output
            $input =~ s{\A(/?[^/]*)}{};
            $output .= $1;
        }
    }
    return $output;
}

# The query's pairs as bytes, parsed once and kept. A copy, so an edit
# cannot change them.
sub _raw_query_pairs {
    my ($self) = @_;
    $self->{_query_raw} //= [PAGI::Utils::Scope::_query_pairs($self->{query_string}, raw => 1)];
    return @{ $self->{_query_raw} };
}

# The query fields for pairs of bytes: each name and value form-encoded
# ("+" for a space; a bare name is written "name="), joined with "&". The
# pairs are kept with it, so the next edit does not parse them again.
sub _query_fields {
    my (@pairs) = @_;
    my @fields;
    for (my $i = 0; $i < @pairs; $i += 2) {
        push @fields, join '=', map { PAGI::Utils::Scope::_escape_form_bytes($_) } @pairs[$i, $i + 1];
    }
    return (query_string => join('&', @fields), _query_raw => \@pairs);
}

# The pairs of bytes whose name is none of @names (bytes).
sub _without_names {
    my ($pairs, @names) = @_;
    my %drop = map { $_ => 1 } @names;
    my @kept;
    for (my $i = 0; $i < @$pairs; $i += 2) {
        push @kept, @$pairs[$i, $i + 1] unless $drop{ $pairs->[$i] };
    }
    return @kept;
}

# One name and its value, text, as pairs of UTF-8 bytes: an arrayref gives
# the name once per value, undef gives no pair.
sub _query_bytes {
    my ($name, $value) = @_;
    my @values = ref $value eq 'ARRAY' ? @$value : defined $value ? ($value) : ();
    return map { (_utf8($name), _utf8($_)) } @values;
}

# Text as UTF-8 bytes. Encoded from a copy: with FB_CROAK, Encode empties
# the string it encodes, and a name is encoded once per value.
sub _utf8 {
    my ($text) = @_;
    return Encode::encode('UTF-8', $text, Encode::FB_CROAK);
}

# replace's query_params as a name => value list, in order: an arrayref of
# pairs, a hashref (its names sorted) or a Hash::MultiValue.
sub _query_param_list {
    my ($params) = @_;
    my @list = blessed($params) && $params->isa('Hash::MultiValue') ? $params->flatten
        : ref $params eq 'ARRAY' ? @$params
        : ref $params eq 'HASH'  ? map { ($_ => $params->{$_}) } sort keys %$params
        : croak 'query_params must be an arrayref, a hashref or a Hash::MultiValue';
    croak 'query_params must be name => value pairs' if @list % 2;
    return @list;
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

    # Edits return a new value
    my $next      = $request->uri->with_query(page => $page + 1);
    my $https     = $request->uri->replace(scheme => 'https');
    my $canonical = $request->uri->without_query(qw(utm_source utm_medium));
    my $callback  = $request->uri->resolve(path_for($request, 'oauth_return'));

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

A path starting with C<//> is read with one C</>, as L</from_scope> reads
the same request: C<http://h//evil.example/x> has the path
C</evil.example/x>, so the path alone cannot name another host.

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

=head1 EDITS

Each edit returns a new PAGI::Utils::URI and leaves the one it was called on,
and so C<< $request->uri >>, as it was.

A query edit (L</with_query>, L</without_query>, C<replace(query_params
=E<gt> ...)>) reads the query as L</raw_query_params> reads it and writes
every pair again, form-encoded: a space is C<+>, a literal C<+> is C<%2B>,
the pairs are joined with C<&>, and a bare name becomes C<name=>. So
C<q=red%20shoes;flag> is written C<q=red+shoes&flag=>. Names and values
given to an edit are text, UTF-8 encoded; the client's bytes are kept as
they were, UTF-8 or not.

A path an edit sets never starts with C<//>: a leading C<//> becomes C</>,
as in L<PAGI::HTTPConnection/request_uri>, so the path alone cannot name
another host. C<replace(path =E<gt> '//evil.example/x')> gives the path
C</evil.example/x>.

=head2 with_query

    # Pagination: ?x=1&x=2 becomes ?x=1&x=2&page=2
    my $next = $request->uri->with_query(page => 2);

    my $uri = $request->uri->with_query(sort => 'name', tag => [qw(a b)], x => undef);

Takes name => value pairs. For each name, in call order, every pair with
that name is removed and the new value appended at the end: an arrayref gives
the name once per value, and C<undef> removes the name. Pairs with other
names keep the client's order. A name given twice in one call keeps only the
later value. Dies C<with_query takes name =E<gt> value pairs> on an odd list.

=head2 without_query

    # A canonical link: the tracking keys removed
    my $canonical = $request->uri->without_query(qw(utm_source utm_medium));

Every pair with one of the names is removed; the rest keep their order. With
no pairs left, the URL has no C<?>.

=head2 replace

    # Redirect to https: only the scheme changes
    my $https = $request->uri->replace(scheme => 'https');

    my $uri = $request->uri->replace(host => 'www.example.com', port => undef);

A copy with the named parts changed and every other part kept, the query and
fragment included when the path changes. The parts are:

=over 4

=item scheme

C<[A-Za-z][A-Za-z0-9+.-]*>, or it dies C<not a scheme: ...>.

=item authority

C<host> or C<host:port>, unescaped, as L</authority> reads it: a trailing
C<:digits> is the port. It is not percent-decoded, so
C<< replace(authority => $uri->authority) >> changes nothing. Escaped in the
string form as a C<Host> is (see L</The host is not validated>).

=item host, port

The host, unescaped and unvalidated, and the port: digits, or C<undef> for
none. Each keeps the other. They cannot be given with C<authority>.

=item path

Text, UTF-8 encoded and percent-encoded (C</caf\x{e9}/a b> is written
C</caf%C3%A9/a%20b>). It must be empty or start with C</>.

=item raw_path

Escaped bytes, kept as given (C</a%2Fb> stays C</a%2Fb>); anything a path
cannot hold, such as a space or C<?>, is percent-encoded. It must be empty
or start with C</>, and cannot be given with C<path>.

=item query_params

The whole query as text: an arrayref of name => value pairs, a hashref (its
names sorted) or a L<Hash::MultiValue>. Values are as L</with_query> takes
them. Written as a query edit is.

=item query_string

The whole query as escaped bytes, kept as given; anything a query cannot
hold is percent-encoded. C<''> removes it. It cannot be given with
C<query_params>.

=item fragment

Characters, encoded as L</parse> encodes them. C<''> removes it.

=back

Any other part dies C<replace cannot change: ...>.

=head2 resolve

    # A callback URL from a path: https://example.com/app/oauth/return
    my $callback = $request->uri->resolve(path_for($request, 'oauth_return'));

    my $sibling = $uri->resolve('../7');

The reference resolved against this URL, as RFC 3986 section 5.2 resolves
it: an absolute path (C</app/oauth/return>) keeps this URL's scheme and
authority and takes the reference's query and fragment; a relative path is
merged with this URL's path, and C<.> and C<..> segments are removed; a
reference with only a query or fragment keeps this URL's path. A reference
starting C<//> keeps only the scheme, and one with a scheme and an authority
keeps nothing.

This is the way to build an absolute URL from a path:
L<PAGI::Routing::URL/path_for> gives the path, with the root path, and
C<resolve> adds the scheme and authority the request came in on.

The reference is characters, as L</parse> takes them: escaped ASCII (what
C<path_for> returns) is kept, and anything else is UTF-8 encoded and
percent-encoded. A reference with a scheme but no authority (C<g:h>, or
C<http:g>, which RFC 3986 resolves to C<http:g> for a strict parser) dies
C<a reference with a scheme must have an authority>: a PAGI::Utils::URI
always has one. Userinfo dies as in L</parse>.

=head1 SEE ALSO

L<PAGI::HTTPConnection>, L<PAGI::Routing::URL>, L<PAGI::Middleware::TrustedHosts>

=cut
