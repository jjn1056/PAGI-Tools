package PAGI::Utils::Scope;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed refaddr);
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

sub _compatible_cached_scope_object {
    my ($scope, $key, $expected_class) = @_;
    my $cached = $scope->{$key};
    my $reusable = (blessed($cached) // '') eq $expected_class
        && $cached->can('scope');
    if ($reusable) {
        my $cached_scope = eval { $cached->scope };
        $reusable = 0
            if $@
                || ref($cached_scope) ne 'HASH'
                || refaddr($cached_scope) != refaddr($scope);
    }
    delete $scope->{$key} unless $reusable;
    return $reusable ? $cached : undef;
}

# The full path the client requested, percent-encoded: raw_path is that at
# every mount level (mounts leave it; a server root path is prepended). A
# scope without raw_path rebuilds it from root_path and path, which cannot
# show how the client encoded them.
sub raw_path {
    my ($scope) = @_;
    return $scope->{raw_path} if defined $scope->{raw_path};
    return _encode_path(($scope->{root_path} // '') . ($scope->{path} // '/'));
}

# The path and query the client requested, as a URI-reference safe for a
# Location header or a log line: bytes outside printable ASCII are
# percent-encoded, and a leading "//" (another host to a browser) becomes "/".
sub request_uri {
    my ($scope) = @_;
    my $uri = raw_path($scope);
    my $query_string = $scope->{query_string} // '';
    $uri .= "?$query_string" if length $query_string;
    $uri = _escape_unsafe_bytes($uri);
    $uri =~ s{\A/{2,}}{/};
    return $uri;
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

sub _unescape {
    my ($value) = @_;
    $value =~ s/%([0-9A-Fa-f]{2})/chr hex $1/eg;
    return $value;
}

# Bytes a URI-reference cannot hold -- controls, space, DEL, and anything
# above 0x7F (raw UTF-8 a client sent unencoded) -- percent-encoded.
sub _escape_unsafe_bytes {
    my ($value) = @_;
    $value = Encode::encode('UTF-8', $value) if $value =~ /[^\x00-\xFF]/;
    $value =~ s{([\x00-\x20\x7F-\xFF])}{sprintf('%%%02X', ord $1)}ge;
    return $value;
}

1;
