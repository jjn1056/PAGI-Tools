package PAGI::HTTPConnection;
use strict;
use warnings;
use Carp qw(croak);
use Encode qw(decode FB_CROAK FB_DEFAULT LEAVE_SRC);
use Hash::MultiValue;
use PAGI::Headers ();
use PAGI::Utils::Scope ();
use Scalar::Util qw(blessed);

sub new {
    my ($class, $scope, @extra) = @_;
    croak "$class->new requires exactly one scope argument" if @extra;
    croak "$class requires an unblessed scope hashref"
        unless ref($scope) eq 'HASH' && !blessed($scope);
    my $type = $scope->{type};
    croak "$class scope type is required"
        unless defined($type) && !ref($type) && length($type);
    croak "$class requires HTTP, WebSocket, or SSE scope; received '$type'"
        unless $type eq 'http' || $type eq 'websocket' || $type eq 'sse';
    return bless { scope => $scope }, $class;
}

sub scope        { shift->{scope} }
sub connection   { shift->{scope}{'pagi.connection'} }
sub client       { shift->{scope}{client} }
sub server       { shift->{scope}{server} }
sub http_version { shift->{scope}{http_version} // '1.1' }
sub query_string { shift->{scope}{query_string} // '' }

sub scheme {
    my $scope = shift->{scope};
    return $scope->{scheme} // ($scope->{type} eq 'websocket' ? 'ws' : 'http');
}

# A scope without a path is a bug (the PAGI spec requires one), so reading
# it fails where it is used rather than answering a made-up '/'.
sub path {
    my $scope = shift->{scope};
    croak 'this scope has no path' unless defined $scope->{path};
    return $scope->{path};
}

sub raw_path {
    my $scope = shift->{scope};
    _require_path_source($scope);
    return PAGI::Utils::Scope::raw_path($scope);
}

sub request_uri {
    my $scope = shift->{scope};
    _require_path_source($scope);
    return PAGI::Utils::Scope::request_uri($scope);
}

sub raw_path_info { PAGI::Utils::Scope::raw_path_info(shift->{scope}) }

# raw_path is rebuilt from path when the scope has no raw_path; with
# neither there is nothing to answer from.
sub _require_path_source {
    my ($scope) = @_;
    croak 'this scope has no path'
        unless defined $scope->{raw_path} || defined $scope->{path};
    return;
}

# Internal: URL decode a string (handles + as space)
sub _url_decode {
    my ($str) = @_;
    return '' unless defined $str;
    $str =~ s/\+/ /g;
    $str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    return $str;
}

# Internal: Decode UTF-8 with replacement or croak in strict mode
sub _decode_utf8 {
    my ($str, $strict) = @_;
    return '' unless defined $str;
    my $flag = $strict ? FB_CROAK : FB_DEFAULT;
    $flag |= LEAVE_SRC;
    return decode('UTF-8', $str, $flag);
}

# The scope's headers as a PAGI::Headers, parsed once per object.
sub headers {
    my $self = shift;
    return $self->{_headers} //= PAGI::Headers->new($self->{scope}{headers} // []);
}

# Single header lookup (case-insensitive, repeated fields joined ", ")
sub header     { return $_[0]->headers->get($_[1]) }

# All values for a header
sub header_all { return $_[0]->headers->get_all($_[1]) }

# Query params as Hash::MultiValue (cached on the object)
# Options: strict => 1 (croak on invalid UTF-8), raw => 1 (skip UTF-8 decoding)
sub query_params {
    my ($self, %opts) = @_;
    my $strict = delete $opts{strict} // 0;
    my $raw    = delete $opts{raw}    // 0;
    croak("Unknown options to query_params: " . join(', ', keys %opts)) if %opts;

    my $cache_key = $raw ? '_query_raw' : ($strict ? '_query_strict' : '_query');
    return $self->{$cache_key} if $self->{$cache_key};

    my $qs = $self->query_string;
    my @pairs;

    for my $part (split /[&;]/, $qs) {
        next unless length $part;
        my ($key, $val) = split /=/, $part, 2;
        $key //= '';
        $val //= '';

        # URL decode (handles + as space)
        my $key_decoded = _url_decode($key);
        my $val_decoded = _url_decode($val);

        # UTF-8 decode unless raw mode
        my $key_final = $raw ? $key_decoded : _decode_utf8($key_decoded, $strict);
        my $val_final = $raw ? $val_decoded : _decode_utf8($val_decoded, $strict);

        push @pairs, $key_final, $val_final;
    }

    $self->{$cache_key} = Hash::MultiValue->new(@pairs);
    return $self->{$cache_key};
}

# Raw query params (no UTF-8 decoding)
sub raw_query_params {
    my $self = shift;
    return $self->query_params(raw => 1);
}

# Shortcut for single query param
sub query_param {
    my ($self, $name, %opts) = @_;
    return $self->query_params(%opts)->get($name);
}

# Raw single query param
sub raw_query_param {
    my ($self, $name) = @_;
    return $self->query_param($name, raw => 1);
}

# Path parameters - captured from URL path by router
# Stored in scope->{path_params} for router-agnostic access
sub path_params {
    my ($self, %opts) = @_;
    my $strict = delete $opts{strict};
    croak("Unknown options to path_params: " . join(', ', keys %opts)) if %opts;

    my $params = $self->{scope}{path_params};
    if (!defined $params && $strict) {
        croak "path_params not set in scope (no router configured?). "
            . "Pass strict => 0 to allow this.";
    }
    return $params // {};
}

sub _default_path_param_strict_opt { return 1 }

sub path_param {
    my ($self, $name, %opts) = @_;
    my $strict = exists $opts{strict} ? delete $opts{strict} : $self->_default_path_param_strict_opt;
    croak("Unknown options to path_param: " . join(', ', keys %opts)) if %opts;

    my $params = $self->path_params;

    if ($strict && !exists $params->{$name}) {
        my @available = keys %$params;
        croak "path_param '$name' not found. "
            . (@available ? "Available: " . join(', ', sort @available) : "No path params set (no router?)");
    }

    return $params->{$name};
}

# Every Cookie field, split into cookies on ';' (RFC 6265's Cookie grammar;
# a ',' belongs to the value), each name and value trimmed, a value wrapped
# in double quotes unquoted, nothing percent-decoded; a repeated name: the
# last wins. A piece without '=' is not a cookie and is skipped.
sub cookies {
    my $self = shift;
    return $self->{_cookies} if $self->{_cookies};

    my %cookies;
    for my $field ($self->header_all('cookie')) {
        for my $piece (split /;/, $field) {
            my ($name, $value) = split /=/, $piece, 2;
            next unless defined $value;
            for ($name, $value) { s/\A\s+//; s/\s+\z// }
            $cookies{$name} = _unquote($value);
        }
    }
    return $self->{_cookies} = \%cookies;
}

# A value wrapped in double quotes loses them, and \\ and \" inside become
# \ and " (Mojo::Util's unquote); any other value is returned as is.
sub _unquote {
    my ($str) = @_;
    return $str unless $str =~ s/\A"(.*)"\z/$1/s;
    $str =~ s/\\\\/\\/g;
    $str =~ s/\\"/"/g;
    return $str;
}

# Single cookie value
sub cookie {
    my ($self, $name) = @_;
    return $self->cookies->{$name};
}

# Application state (injected by PAGI::Lifespan, read-only)
sub has_state {
    my $self = shift;
    return 0 unless exists $self->{scope}{state};
    croak ref($self) . ' state must be a hashref'
        unless ref($self->{scope}{state}) eq 'HASH';
    return 1;
}

sub state {
    my $self = shift;
    require PAGI::State;
    return PAGI::State->new($self) // PAGI::State->_without_state;
}

1;

__END__

=head1 NAME

PAGI::HTTPConnection - Read an HTTP, WebSocket or SSE request without touching its body or socket

=head1 SYNOPSIS

    use PAGI::HTTPConnection;

    my $conn = PAGI::HTTPConnection->new($scope);

    my $path    = $conn->path;                 # /users/42
    my $token   = $conn->header('Authorization');
    my $page    = $conn->query_param('page');
    my $session = $conn->cookie('session');
    my $id      = $conn->path_param('id');
    my $db      = $conn->state->get('db');

=head1 DESCRIPTION

PAGI::HTTPConnection is what can be known about a request without talking to
it: its scope, path, headers, query, path parameters, cookies, client and
application state. It is built from the scope alone -- no C<$receive>, no
C<$send> -- so it cannot read a body, accept a WebSocket or start an event
stream, and it never writes the scope. It reads C<http>, C<websocket> and
C<sse> scopes alike.

It is Starlette's C<HTTPConnection>, and like Starlette's it has two uses.
PAGI's also covers SSE, which Starlette does not have.

=head2 Reading a request safely in middleware

Middleware that only needs to look at a request -- a header, a cookie, the
query -- builds a PAGI::HTTPConnection over the scope. It reads what the
middleware needs and cannot consume the body the application will read, or
answer a socket the application owns. Starlette's own Authentication and
Session middleware read requests through C<HTTPConnection(scope)> this way.

    use Future::AsyncAwait;
    use PAGI::HTTPConnection;

    # valid_key is the application's own check.
    sub require_api_key {
        my ($app) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            return await $app->($scope, $receive, $send)
                unless $scope->{type} eq 'http';

            my $conn = PAGI::HTTPConnection->new($scope);
            my $key = $conn->header('X-API-Key') // $conn->query_param('api_key');
            return await $app->($scope, $receive, $send) if valid_key($key);

            await $send->({ type => 'http.response.start', status => 401,
                headers => [['content-type', 'text/plain']] });
            await $send->({ type => 'http.response.body', body => 'Unauthorized' });
        };
    }

=head2 Code that works across protocols

A helper written against PAGI::HTTPConnection -- an authentication check, a
tenant lookup -- works with a L<PAGI::Request>, a L<PAGI::WebSocket> or a
L<PAGI::SSE>, since each of them is a PAGI::HTTPConnection. FastAPI documents
its C<HTTPConnection> for exactly this: "dependencies that should be compatible
with both HTTP and WebSockets".

    # Works for an HTTP handler's $request, a WebSocket handler's $websocket
    # and an SSE handler's $sse alike.
    sub current_tenant {
        my ($conn) = @_;
        my $name = $conn->header('X-Tenant') // $conn->cookie('tenant')
            // return undef;
        return $conn->state->get('tenants')->{$name};
    }

=head1 CONSTRUCTOR

=head2 new

    my $conn = PAGI::HTTPConnection->new($scope);

Builds a connection over C<$scope>, an unblessed C<http>, C<websocket> or
C<sse> scope hashref. It croaks when:

=over 4

=item * C<$scope> is not a hash reference, or is a blessed one;

=item * the scope has no C<type>, or its type is empty or a reference;

=item * the type is anything else (C<lifespan>, say) -- middleware that
sees every scope checks C<< $scope->{type} >> before building one;

=item * a second argument is passed.

=back

It does not require C<pagi.connection> (L</connection> returns it when
present). Building reads nothing and writes nothing: every parse happens on
first use and is kept on the object.

=head1 SCOPE PROPERTIES

=head2 scope

    my $scope = $conn->scope;

The scope hashref the object was built over, as is.

=head2 connection

    my $pagi_connection = $conn->connection;

The server-supplied object under C<pagi.connection>, or C<undef> when the
scope has none. Its interface is defined by the PAGI specification.

=head2 client

Arrayref of C<[host, port]> for the remote end, or C<undef> when the server
did not provide it.

=head2 server

Arrayref of C<[host, port]> for the local server endpoint, or C<undef> when
the server did not provide it. This is informational only; it is not the
Host the client asked for.

=head2 scheme

The scope's C<scheme>; without one, C<ws> for a WebSocket scope and C<http>
for an HTTP or SSE scope.

=head2 http_version

The scope's HTTP version (C<1.0>, C<1.1>, C<2>), C<1.1> when absent.

=head2 path

    my $path = $conn->path;   # /users/42

The request path, UTF-8 decoded. Dies C<this scope has no path> when the scope
has none: the PAGI specification requires one, so a missing path is a bug in
whatever built the scope, reported where the path is read.

=head2 raw_path

The full path the client requested, percent-encoded as sent. Mounts leave it
unchanged, so inside a mount it still starts with the mount prefix (see
L<PAGI::Spec::Www/Paths, Mounts and Root Paths>). Without one in the scope it
is C<root_path> followed by C<path>, percent-encoded; with neither it dies
C<this scope has no path>. Never use it for authorization: different
encodings reach the same C<path>.

=head2 raw_path_info

    my $rest = $conn->raw_path_info;  # /a%2Fb inside mount('/files')

The part of C<raw_path> below C<root_path>, still encoded, for code that must
tell an encoded C</> from a separator. Returns C<undef> when it cannot be
found: an encoded C</> straddles the mount boundary, or C<path> was rewritten.

=head2 request_uri

    my $here = $conn->request_uri;   # /app/admin/users?x=1

The path and query the client requested: C<raw_path>, then C<?> and
C<query_string> when there is one, with any byte a URI cannot hold
percent-encoded and a leading C<//> reduced to C</>. It is the URL to
redirect back to, at any mount depth and behind a server root path. Dies
C<this scope has no path> when the scope has neither C<raw_path> nor C<path>.

=head2 query_string

The raw query string, without the leading C<?>; C<''> when absent.

=head1 HEADERS

=head2 headers

    my $headers = $conn->headers;  # PAGI::Headers

The scope's headers as a L<PAGI::Headers>, parsed on first use and kept on
the object; L</header> and L</header_all> read this same object. A change made
through it is seen by later reads through this object, and by no other
object and not by the scope. Call C<< $conn->headers->clone >> for an isolated
copy.

=head2 header

    my $value = $conn->header('Content-Type');

A header's value (the name is case-insensitive), or C<undef> when absent. A
header that appears more than once reads as every value joined with C<", ">
in order: two C<Accept> fields read C<"text/html, application/json">, and two
C<Origin> fields read a value no origin check accepts. Read each value with
L</header_all>, or a value that must appear once (an id, an address) with
C<< $conn->headers->get_single($name) >>, which gives C<undef> for a repeated
field.

=head2 header_all

    my @values = $conn->header_all('Accept');

Every value of a header, in order; an empty list when absent.

=head1 QUERY PARAMETERS

=head2 query_params

    my $params = $conn->query_params;               # Hash::MultiValue
    my $params = $conn->query_params(strict => 1);  # die on invalid UTF-8
    my $params = $conn->query_params(raw => 1);     # skip UTF-8 decoding

The query string's parameters as a L<Hash::MultiValue>: percent-decoded,
C<+> read as a space, then UTF-8 decoded. A repeated name keeps every value;
C<get> gives the last. Each form is parsed once and kept on the object.

B<Options:>

=over 4

=item * C<strict> - If true, die on invalid UTF-8 sequences. Default: false
(invalid bytes replaced with U+FFFD).

=item * C<raw> - If true, skip UTF-8 decoding entirely and return raw bytes.
Default: false.

=back

An unknown option croaks.

=head2 query_param

    my $value = $conn->query_param('page');
    my $value = $conn->query_param('page', strict => 1);
    my $value = $conn->query_param('page', raw => 1);

Shortcut for C<< $conn->query_params(%opts)->get($name) >>: the last value of
the name, or C<undef>. Accepts the same C<strict> and C<raw> options as
L</query_params>.

=head2 raw_query_params

    my $params = $conn->raw_query_params;

Shortcut for C<< $conn->query_params(raw => 1) >>.

=head2 raw_query_param

    my $value = $conn->raw_query_param('page');

Shortcut for C<< $conn->query_param($name, raw => 1) >>: the raw bytes,
without UTF-8 decoding.

=head1 PATH PARAMETERS

Path parameters are captured from the URL path by a router (for example,
L<PAGI::Routing>) and stored in C<< $scope->{path_params} >>; any router can
populate that field. They are read from the scope on every call, so a router
that updates the scope in place between matches is seen at once.

=head2 path_params

    my $params = $conn->path_params;              # hashref
    my $params = $conn->path_params(strict => 1); # die without a router

Every path parameter as a hashref; C<{}> when no router has set them. With
C<< strict => 1 >> it dies instead: C<path_params not set in scope (no router
configured?)>. L</path_param> reads through this method, so a subclass may
override it for its own router.

=head2 path_param

    my $id = $conn->path_param('id');
    my $id = $conn->path_param('id', strict => 0);  # undef if missing

One path parameter. Strict by default: a name the route did not capture
dies, naming the ones it did (C<path_param 'user_id' not found. Available:
postId, userId>), so a typo fails where it is made. C<< strict => 0 >> returns
C<undef> instead. An unknown option croaks.

=head2 _default_path_param_strict_opt

The default of L</path_param>'s C<strict> option: C<1>. A subclass overrides
it to return C<0> to make C<path_param> lenient by default. It is a hook for
subclasses, not a method to call.

=head1 COOKIES

=head2 cookies

    my $cookies = $conn->cookies;  # { session => 'abc123', ... }

Every cookie the client sent, as a hashref of name to value, parsed on first
use and kept on the object. Every C<Cookie> field is read and split into
cookies on C<;> only, as RFC 6265 writes the field (a C<,> is part of a
value); each name and value is trimmed. A value wrapped in double quotes is
unquoted as Mojolicious does: the surrounding quotes are removed and, inside,
C<\"> becomes C<"> and C<\\> becomes C<\>; any other value is taken as is.
Nothing is percent-decoded: C<a=x%2Fy> reads C<x%2Fy>, as the client sent it.
A name sent more than once gives the last value. A piece without C<=> is not
a cookie and is skipped.

=head2 cookie

    my $session = $conn->cookie('session');

One cookie's value, or C<undef> when the client did not send it.

=head1 APPLICATION STATE

=head2 state

    my $db = $conn->state->get('db');

A L<PAGI::State> facade over the application state injected by
L<PAGI::Lifespan>. Always returns a facade: without application state it is
empty, and its C<get> and C<data> die naming the likely cause. Croaks if a
present state value is not a hashref. Repeated calls are not guaranteed to
return the same facade object.

=head2 has_state

Returns true when a state hashref is present and false when state is absent.
Croaks when a present state value is not a hashref.

=head1 SUBCLASSING

The object is a blessed hash. PAGI-Tools uses the field C<scope> and fields
whose names start with C<_> (the parse caches C<_headers>, C<_query>,
C<_query_raw>, C<_query_strict> and C<_cookies>); a subclass adds fields under
any other name. One object reads one scope: a scope copy (a middleware's
rewrite, say) needs a new object, since an object answers from the scope it
was built over and the parses it kept.

=head1 SEE ALSO

L<PAGI::Request>, L<PAGI::WebSocket>, L<PAGI::SSE>, L<PAGI::Headers>,
L<PAGI::State>, L<Hash::MultiValue>

=cut
