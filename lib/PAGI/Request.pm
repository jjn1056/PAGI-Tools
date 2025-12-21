package PAGI::Request;
use strict;
use warnings;
use Hash::MultiValue;
use URI::Escape qw(uri_unescape);
use Encode qw(decode_utf8);
use Cookie::Baker qw(crush_cookie);
use MIME::Base64 qw(decode_base64);
use Future::AsyncAwait;
use JSON::PP qw(decode_json);
use PAGI::Request::MultiPartHandler;
use PAGI::Request::Upload;

# Class-level configuration defaults
our %CONFIG = (
    max_body_size   => 10 * 1024 * 1024,   # 10MB
    max_upload_size => 10 * 1024 * 1024,   # 10MB per file
    max_files       => 20,
    max_fields      => 1000,
    spool_threshold => 64 * 1024,           # 64KB
    temp_dir        => $ENV{TMPDIR} // '/tmp',
);

sub configure {
    my ($class, %opts) = @_;
    for my $key (keys %opts) {
        $CONFIG{$key} = $opts{$key} if exists $CONFIG{$key};
    }
}

sub config {
    my $class = shift;
    return \%CONFIG;
}

sub new {
    my ($class, $scope, $receive) = @_;
    return bless {
        scope   => $scope,
        receive => $receive,
        _body_read => 0,
    }, $class;
}

# Basic properties from scope
sub method       { shift->{scope}{method} }
sub path         { shift->{scope}{path} }
sub raw_path     { my $s = shift; $s->{scope}{raw_path} // $s->{scope}{path} }
sub query_string { shift->{scope}{query_string} // '' }
sub scheme       { shift->{scope}{scheme} // 'http' }
sub http_version { shift->{scope}{http_version} // '1.1' }
sub client       { shift->{scope}{client} }
sub raw          { shift->{scope} }

# Host from headers
sub host {
    my $self = shift;
    return $self->header('host');
}

# Content-Type shortcut
sub content_type {
    my $self = shift;
    my $ct = $self->header('content-type') // '';
    # Strip parameters like charset
    $ct =~ s/;.*//;
    return $ct;
}

# Content-Length shortcut
sub content_length {
    my $self = shift;
    return $self->header('content-length');
}

# Single header lookup (case-insensitive, returns last value)
sub header {
    my ($self, $name) = @_;
    $name = lc($name);
    my $value;
    for my $pair (@{$self->{scope}{headers} // []}) {
        if (lc($pair->[0]) eq $name) {
            $value = $pair->[1];
        }
    }
    return $value;
}

# All headers as Hash::MultiValue (cached, case-insensitive keys)
sub headers {
    my $self = shift;
    return $self->{_headers} if $self->{_headers};

    my @pairs;
    for my $pair (@{$self->{scope}{headers} // []}) {
        push @pairs, lc($pair->[0]), $pair->[1];
    }

    $self->{_headers} = Hash::MultiValue->new(@pairs);
    return $self->{_headers};
}

# All values for a header
sub header_all {
    my ($self, $name) = @_;
    return $self->headers->get_all(lc($name));
}

# Query params as Hash::MultiValue (cached)
sub query_params {
    my $self = shift;
    return $self->{_query_params} if $self->{_query_params};

    my $qs = $self->query_string;
    my @pairs;

    for my $part (split /&/, $qs) {
        next unless length $part;
        my ($key, $val) = split /=/, $part, 2;
        $key //= '';
        $val //= '';

        # Decode percent-encoding and UTF-8
        $key = decode_utf8(uri_unescape($key));
        $val = decode_utf8(uri_unescape($val));

        push @pairs, $key, $val;
    }

    $self->{_query_params} = Hash::MultiValue->new(@pairs);
    return $self->{_query_params};
}

# Shortcut for single query param
sub query {
    my ($self, $name) = @_;
    return $self->query_params->get($name);
}

# All cookies as hashref (cached)
sub cookies {
    my $self = shift;
    return $self->{_cookies} if exists $self->{_cookies};

    my $cookie_header = $self->header('cookie') // '';
    $self->{_cookies} = crush_cookie($cookie_header);
    return $self->{_cookies};
}

# Single cookie value
sub cookie {
    my ($self, $name) = @_;
    return $self->cookies->{$name};
}

# Method predicates
sub is_get     { uc(shift->method // '') eq 'GET' }
sub is_post    { uc(shift->method // '') eq 'POST' }
sub is_put     { uc(shift->method // '') eq 'PUT' }
sub is_patch   { uc(shift->method // '') eq 'PATCH' }
sub is_delete  { uc(shift->method // '') eq 'DELETE' }
sub is_head    { uc(shift->method // '') eq 'HEAD' }
sub is_options { uc(shift->method // '') eq 'OPTIONS' }

# Check if client has disconnected (async)
async sub is_disconnected {
    my $self = shift;

    return 0 unless $self->{receive};

    # Peek at receive - if we get disconnect, client is gone
    my $message = await $self->{receive}->();

    if ($message && $message->{type} eq 'http.disconnect') {
        return 1;
    }

    return 0;
}

# Content-type predicates
sub is_json {
    my $self = shift;
    my $ct = $self->content_type;
    return $ct eq 'application/json';
}

sub is_form {
    my $self = shift;
    my $ct = $self->content_type;
    return $ct eq 'application/x-www-form-urlencoded'
        || $ct =~ m{^multipart/form-data};
}

sub is_multipart {
    my $self = shift;
    my $ct = $self->content_type;
    return $ct =~ m{^multipart/form-data};
}

# Accept header check (case-insensitive per RFC 7231)
sub accepts {
    my ($self, $mime_type) = @_;
    my @accepts = $self->header_all('accept');
    $mime_type = lc($mime_type);

    for my $accept (@accepts) {
        $accept = lc($accept);
        # Handle wildcards
        if ($accept eq '*/*' || $mime_type eq '*/*') {
            return 1;
        }
        if ($accept =~ m{^([^/]+)/\*$}) {
            my $type = $1;
            return 1 if $mime_type =~ m{^\Q$type\E/};
        }
        if ($mime_type =~ m{^([^/]+)/\*$}) {
            my $type = $1;
            return 1 if $accept =~ m{^\Q$type\E/};
        }
        # Exact match
        return 1 if $accept eq $mime_type;
    }

    return 0;
}

# Extract Bearer token from Authorization header
sub bearer_token {
    my $self = shift;
    my $auth = $self->header('authorization') // '';
    if ($auth =~ /^Bearer\s+(.+)$/i) {
        return $1;
    }
    return undef;
}

# Extract Basic auth credentials
sub basic_auth {
    my $self = shift;
    my $auth = $self->header('authorization') // '';
    if ($auth =~ /^Basic\s+(.+)$/i) {
        my $decoded = decode_base64($1);
        my ($user, $pass) = split /:/, $decoded, 2;
        return ($user, $pass);
    }
    return (undef, undef);
}

# Path params (set by router)
sub params {
    my $self = shift;
    return $self->{_path_params} // $self->{scope}{path_params} // {};
}

sub param {
    my ($self, $name) = @_;
    return $self->params->{$name};
}

# Called by router to set matched params
sub set_params {
    my ($self, $params) = @_;
    $self->{_path_params} = $params;
}

# Per-request storage for middleware/handlers
sub stash {
    my $self = shift;
    $self->{_stash} //= {};
    return $self->{_stash};
}

# Read raw body bytes (async, cached)
async sub body {
    my $self = shift;

    # Return cached body if already read
    return $self->{_body} if $self->{_body_read};

    my $receive = $self->{receive};
    die "No receive callback provided" unless $receive;

    my $body = '';
    while (1) {
        my $message = await $receive->();
        last unless $message && $message->{type};
        last if $message->{type} eq 'http.disconnect';

        $body .= $message->{body} // '';
        last unless $message->{more};
    }

    $self->{_body} = $body;
    $self->{_body_read} = 1;
    return $body;
}

# Read body as decoded UTF-8 text (async)
async sub text {
    my $self = shift;
    my $body = await $self->body;
    return decode_utf8($body);
}

# Parse body as JSON (async, dies on error)
async sub json {
    my $self = shift;
    my $body = await $self->body;
    return decode_json($body);
}

# Parse URL-encoded form body (async, returns Hash::MultiValue)
async sub form {
    my ($self, %opts) = @_;

    # Return cached if available
    return $self->{_form} if $self->{_form};

    # For multipart, delegate to uploads handling
    if ($self->is_multipart) {
        return await $self->_parse_multipart_form(%opts);
    }

    # URL-encoded form
    my $body = await $self->body;
    my @pairs;

    for my $part (split /&/, $body) {
        next unless length $part;
        my ($key, $val) = split /=/, $part, 2;
        $key //= '';
        $val //= '';

        # Decode + as space, then percent-decoding
        $key =~ s/\+/ /g;
        $val =~ s/\+/ /g;
        $key = decode_utf8(uri_unescape($key));
        $val = decode_utf8(uri_unescape($val));

        push @pairs, $key, $val;
    }

    $self->{_form} = Hash::MultiValue->new(@pairs);
    return $self->{_form};
}

# Parse multipart form (internal)
async sub _parse_multipart_form {
    my ($self, %opts) = @_;

    # Already parsed?
    return $self->{_form} if $self->{_form} && $self->{_uploads};

    # Extract boundary from content-type
    my $ct = $self->header('content-type') // '';
    my ($boundary) = $ct =~ /boundary=([^;\s]+)/;
    $boundary =~ s/^["']|["']$//g if $boundary;  # Strip quotes

    die "No boundary found in Content-Type" unless $boundary;

    my $handler = PAGI::Request::MultiPartHandler->new(
        boundary        => $boundary,
        receive         => $self->{receive},
        max_part_size   => $opts{max_part_size},
        spool_threshold => $opts{spool_threshold},
        max_files       => $opts{max_files},
        max_fields      => $opts{max_fields},
        temp_dir        => $opts{temp_dir},
    );

    my ($form, $uploads) = await $handler->parse;

    $self->{_form} = $form;
    $self->{_uploads} = $uploads;
    $self->{_body_read} = 1;  # Body has been consumed

    return $form;
}

# Get all uploads as Hash::MultiValue
async sub uploads {
    my ($self, %opts) = @_;

    return $self->{_uploads} if $self->{_uploads};

    if ($self->is_multipart) {
        await $self->_parse_multipart_form(%opts);
        return $self->{_uploads};
    }

    # Not multipart - return empty
    $self->{_uploads} = Hash::MultiValue->new();
    return $self->{_uploads};
}

# Get single upload by field name
async sub upload {
    my ($self, $name, %opts) = @_;
    my $uploads = await $self->uploads(%opts);
    return $uploads->get($name);
}

# Get all uploads for a field name
async sub upload_all {
    my ($self, $name, %opts) = @_;
    my $uploads = await $self->uploads(%opts);
    return $uploads->get_all($name);
}

1;

__END__

=head1 NAME

PAGI::Request - Convenience wrapper for PAGI request scope

=head1 SYNOPSIS

    use PAGI::Request;

    async sub app {
        my ($scope, $receive, $send) = @_;
        my $req = PAGI::Request->new($scope, $receive);

        my $method = $req->method;
        my $path = $req->path;
        my $ct = $req->content_type;
    }

=cut
