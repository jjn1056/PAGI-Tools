package PAGI::Utils::Scope;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use Encode ();

sub is_scope_source {
    my ($value) = @_;
    return 1 if ref($value) eq 'HASH' && !blessed($value);
    return blessed($value) && $value->can('scope') ? 1 : 0;
}

sub scope_from_source {
    my ($owner, @arguments) = @_;
    croak "$owner requires exactly one scope hashref or object with scope()"
        unless @arguments == 1;
    my $source = $arguments[0];
    my $scope = ref($source) eq 'HASH' && !blessed($source)
        ? $source
        : blessed($source) && $source->can('scope')
            ? $source->scope
            : undef;
    croak "$owner requires an unblessed scope hashref or object with scope()"
        unless ref($scope) eq 'HASH' && !blessed($scope);
    return $scope;
}

# The scope's scheme; without one, ws for a WebSocket scope and http for an
# HTTP or SSE scope.
sub scheme {
    my ($scope) = @_;
    return $scope->{scheme} // ($scope->{type} eq 'websocket' ? 'ws' : 'http');
}

# The scope's type, which must be http, websocket or sse: what a
# connection, and its URL, can be read from. $owner names the caller in the
# message.
sub _require_connection_type {
    my ($owner, $scope) = @_;
    my $type = $scope->{type};
    croak "$owner scope type is required"
        unless defined($type) && !ref($type) && length($type);
    croak "$owner requires HTTP, WebSocket, or SSE scope; received '$type'"
        unless $type eq 'http' || $type eq 'websocket' || $type eq 'sse';
    return $type;
}

# raw_path is rebuilt from path when the scope has no raw_path; with
# neither there is nothing to answer from.
sub _require_path_source {
    my ($scope) = @_;
    croak 'this scope has no path'
        unless defined $scope->{raw_path} || defined $scope->{path};
    return;
}

# The full path the client requested, percent-encoded: raw_path is that at
# every mount level (mounts leave it; a server root path is prepended). A
# scope without raw_path rebuilds it from root_path and path, which cannot
# show how the client encoded them.
sub raw_path {
    my ($scope) = @_;
    return $scope->{raw_path} if defined $scope->{raw_path};
    return _encode_path(_full_path($scope));
}

# The scope's root_path followed by its path (or "/"), joined without
# doubling the slash when root_path ends in one.
sub _full_path {
    my ($scope) = @_;
    my $root_path = $scope->{root_path} // '';
    $root_path =~ s{/+\z}{};
    return $root_path . ($scope->{path} // '/');
}

# The path and query the client requested, as a URI-reference safe for a
# Location header or a log line: every character RFC 3986 does not allow in
# a path or query is percent-encoded (so a backslash cannot turn "/\host"
# into "//host"), and a leading "//" (another host to a browser) becomes "/".
sub request_uri {
    my ($scope) = @_;
    my ($path, $query) = _request_path_and_query($scope);
    return _one_leading_slash($path . (length $query ? "?$query" : ''));
}

# The request's path and query, each escaped as request_uri escapes them
# and neither held to one leading slash. The query is '' when there is none.
sub _request_path_and_query {
    my ($scope) = @_;
    return (
        _escape_path_bytes(raw_path($scope)),
        _escape_unsafe_bytes($scope->{query_string} // ''),
    );
}

# A path handed out on its own starts with at most one "/": a leading "//"
# is another host to a browser.
sub _one_leading_slash {
    my ($path) = @_;
    $path =~ s{\A/{2,}}{/};
    return $path;
}

# The encoded part of raw_path below root_path, for code that must tell an
# encoded "/" from a separator. raw_path segments are decoded the way the
# server decodes the whole path until they spell root_path. undef when no
# segment boundary in raw_path matches root_path (an encoded "/" straddles
# the mount boundary), or when the rest does not decode to path (something
# rewrote path).
sub raw_path_info {
    my ($scope) = @_;
    my $raw_path = $scope->{raw_path};
    my $path = $scope->{path} // '/';
    return _encode_path($path) unless defined $raw_path;
    my $root_path = $scope->{root_path} // '';

    my $unescaped = _unescape($raw_path);
    my $utf8 = defined eval {
        Encode::decode('UTF-8', $unescaped, Encode::FB_CROAK | Encode::LEAVE_SRC)
    };
    my $decode = sub {
        my $bytes = _unescape($_[0]);
        return $utf8 ? Encode::decode('UTF-8', $bytes) : $bytes;
    };

    my ($consumed, $at) = ('', 0);
    while ($consumed ne $root_path) {
        return undef unless substr($raw_path, $at, 1) eq '/';
        my $end = index($raw_path, '/', $at + 1);
        $end = length $raw_path if $end < 0;
        $consumed .= '/' . $decode->(substr($raw_path, $at + 1, $end - $at - 1));
        $at = $end;
        return undef unless index($root_path, $consumed) == 0;
    }
    my $rest = substr($raw_path, $at);
    $rest = '/' unless length $rest;
    return $decode->($rest) eq $path ? $rest : undef;
}

# Percent-encode a decoded path as UTF-8, keeping unreserved characters and
# "/" literal. path_for and the helpers above share it, so the parts of a
# URL they generate agree byte for byte.
sub _encode_path {
    my ($value) = @_;
    my $bytes = Encode::encode('UTF-8', $value, Encode::FB_CROAK);
    $bytes =~ s{([^A-Za-z0-9\-._~/])}{sprintf('%%%02X', ord $1)}ge;
    return $bytes;
}

# Percent-encode one URL component -- a path parameter, a query key or
# value, a form field -- as UTF-8, keeping only unreserved characters
# literal. The routing Pattern, the Resolver and PAGI::Test::Client share
# it, so a value encodes the same wherever Tools puts it in a URL.
sub _encode_component {
    my ($value) = @_;
    my $bytes = Encode::encode('UTF-8', $value, Encode::FB_CROAK);
    $bytes =~ s/([^A-Za-z0-9\-._~])/sprintf('%%%02X', ord($1))/ge;
    return $bytes;
}

# Percent-encode bytes as an application/x-www-form-urlencoded component:
# every byte outside the unreserved characters is %XX, except a space,
# which is "+", as a browser writes a form. A literal "+" is still "%2B".
sub _escape_form_bytes {
    my ($bytes) = @_;
    $bytes =~ s/([^A-Za-z0-9\-._~ ])/sprintf('%%%02X', ord($1))/ge;
    $bytes =~ tr/ /+/;
    return $bytes;
}

# A query key or value, or a form field, given as characters.
sub _encode_form_component {
    my ($value) = @_;
    return _escape_form_bytes(Encode::encode('UTF-8', $value, Encode::FB_CROAK));
}

sub _unescape {
    my ($value) = @_;
    $value =~ s/%([0-9A-Fa-f]{2})/chr hex $1/eg;
    return $value;
}

# An escaped path as text, decoded as the server decodes the scope path:
# percent-decoded, then UTF-8 decoded, or left as bytes when not UTF-8.
sub _decode_path {
    my ($raw_path) = @_;
    my $bytes = _unescape($raw_path);
    my $text = eval { Encode::decode('UTF-8', $bytes, Encode::FB_CROAK | Encode::LEAVE_SRC) };
    return defined $text ? $text : $bytes;
}

# URL decode a query or form component: "+" is a space.
sub _url_decode {
    my ($str) = @_;
    return '' unless defined $str;
    $str =~ s/\+/ /g;
    return _unescape($str);
}

# Decode UTF-8 with replacement, or croak in strict mode.
sub _decode_utf8 {
    my ($str, $strict) = @_;
    return '' unless defined $str;
    my $flag = $strict ? Encode::FB_CROAK : Encode::FB_DEFAULT;
    $flag |= Encode::LEAVE_SRC;
    return Encode::decode('UTF-8', $str, $flag);
}

# A query string's key/value pairs as a flat list, in order: split on "&"
# or ";", each piece at its first "=" (a bare key has the value ''),
# percent-decoded with "+" as a space, then UTF-8 decoded unless raw
# (strict croaks on invalid UTF-8; otherwise it is replaced).
sub _query_pairs {
    my ($query_string, %opts) = @_;
    my @pairs;
    for my $part (split /[&;]/, $query_string // '') {
        next unless length $part;
        my ($key, $val) = split /=/, $part, 2;
        for my $component ($key, $val) {
            $component = _url_decode($component);
            $component = _decode_utf8($component, $opts{strict}) unless $opts{raw};
            push @pairs, $component;
        }
    }
    return @pairs;
}

# Percent-encode what RFC 3986 does not allow in a query (and so in a
# request target's path-and-query): anything but unreserved characters,
# sub-delims, ":", "@", "/", "?" and an existing "%" escape. Characters
# beyond a byte are encoded as UTF-8 first.
sub _escape_unsafe_bytes {
    my ($value) = @_;
    $value = Encode::encode('UTF-8', $value) if $value =~ /[^\x00-\xFF]/;
    $value =~ s{([^A-Za-z0-9\-._~!\$&'()*+,;=:\@/?%])}{sprintf('%%%02X', ord $1)}ge;
    return $value;
}

# The same for a path, where "?" would start the query.
sub _escape_path_bytes {
    my ($value) = @_;
    $value = _escape_unsafe_bytes($value);
    $value =~ s{\?}{%3F}g;
    return $value;
}

1;
