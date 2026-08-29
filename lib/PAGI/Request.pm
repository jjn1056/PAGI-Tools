package PAGI::Request;
use strict;
use warnings;
use Hash::MultiValue;
use PAGI::Headers ();
use PAGI::Authority ();
use Encode qw(decode FB_CROAK FB_DEFAULT LEAVE_SRC);
use Cookie::Baker qw(crush_cookie);
use MIME::Base64 qw(decode_base64);
use Future::AsyncAwait;
use JSON::MaybeXS qw(decode_json);
use Carp qw(croak carp);
use Scalar::Util qw(blessed);
use PAGI::Request::MultiPartHandler;
use PAGI::Request::Upload;
use PAGI::Request::Negotiate;
use PAGI::Request::BodyStream;

sub new {
    croak 'PAGI::Request->new requires exactly scope and receive arguments'
        if @_ > 3;
    my ($class, $scope, $receive) = @_;
    croak 'PAGI::Request requires an unblessed scope hashref'
        unless ref($scope) eq 'HASH' && !blessed($scope);
    my $type = $scope->{type};
    croak 'PAGI::Request scope type is required'
        unless defined($type) && !ref($type) && length($type);
    croak "PAGI::Request requires HTTP scope; received '$type'"
        unless $type eq 'http';
    croak 'PAGI::Request requires a receive coderef'
        unless ref($receive) eq 'CODE';
    return bless { scope => $scope, receive => $receive }, $class;
}

# Basic properties from scope
sub method       { shift->{scope}{method} }
sub path         { shift->{scope}{path} }
sub raw_path     { my $s = shift; $s->{scope}{raw_path} // $s->{scope}{path} }
sub query_string { shift->{scope}{query_string} // '' }
sub scheme       { shift->{scope}{scheme} // 'http' }
sub http_version { shift->{scope}{http_version} // '1.1' }
sub client       { shift->{scope}{client} }
sub server       { shift->{scope}{server} }
sub raw          { shift->{scope} }

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

sub host {
    my ($self) = @_;
    return PAGI::Authority->host_from_scope($self->{scope});
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

# Private cache: the source of truth for header lookups (built once per request).
sub _header_snapshot {
    my $self = shift;
    return $self->{scope}{'pagi.request.headers'}
        //= PAGI::Headers->new($self->{scope}{headers} // []);
}

# Public: a PAGI::Headers snapshot of the inbound headers. Returns an independent
# CLONE so mutating it cannot poison later header()/content_type()/cookie lookups.
sub headers { return $_[0]->_header_snapshot->clone }

# Single header lookup (case-insensitive, last value)
sub header     { return $_[0]->_header_snapshot->get($_[1]) }

# All values for a header
sub header_all { return $_[0]->_header_snapshot->get_all($_[1]) }

# Query params as Hash::MultiValue (cached in scope)
# Options: strict => 1 (croak on invalid UTF-8), raw => 1 (skip UTF-8 decoding)
sub query_params {
    my ($self, %opts) = @_;
    my $strict = delete $opts{strict} // 0;
    my $raw    = delete $opts{raw}    // 0;
    croak("Unknown options to query_params: " . join(', ', keys %opts)) if %opts;

    my $cache_key = $raw ? 'pagi.request.query.raw' : ($strict ? 'pagi.request.query.strict' : 'pagi.request.query');
    return $self->{scope}{$cache_key} if $self->{scope}{$cache_key};

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

    $self->{scope}{$cache_key} = Hash::MultiValue->new(@pairs);
    return $self->{scope}{$cache_key};
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

# DEPRECATED: Alias with warning
sub query {
    my $self = shift;
    carp "query() is deprecated; use query_param() instead";
    return $self->query_param(@_);
}

# Raw single query param
sub raw_query_param {
    my ($self, $name) = @_;
    return $self->query_param($name, raw => 1);
}

# DEPRECATED: Alias with warning
sub raw_query {
    my $self = shift;
    carp "raw_query() is deprecated; use raw_query_param() instead";
    return $self->raw_query_param(@_);
}

# All cookies as hashref (cached in scope)
sub cookies {
    my $self = shift;
    return $self->{scope}{'pagi.request.cookies'} if exists $self->{scope}{'pagi.request.cookies'};

    my $cookie_header = $self->header('cookie') // '';
    $self->{scope}{'pagi.request.cookies'} = crush_cookie($cookie_header);
    return $self->{scope}{'pagi.request.cookies'};
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

sub connection {
    my $self = shift;
    return $self->{scope}{'pagi.connection'};
}

sub is_disconnected {
    my $self = shift;
    my $connection = $self->connection;
    return undef unless $connection;
    return $connection->is_connected ? 0 : 1;
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

# Accept header check using Negotiate module
# Combines multiple Accept headers per RFC 7230 Section 3.2.2
sub accepts {
    my ($self, $mime_type) = @_;
    my @accept_values = $self->header_all('accept');
    my $accept = join(', ', @accept_values);
    return PAGI::Request::Negotiate->accepts_type($accept, $mime_type);
}

# Find best matching content type from supported list
# Combines multiple Accept headers per RFC 7230 Section 3.2.2
sub preferred_type {
    my ($self, @types) = @_;
    my @accept_values = $self->header_all('accept');
    my $accept = join(', ', @accept_values);
    return PAGI::Request::Negotiate->best_match(\@types, $accept);
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

sub scope { shift->{scope} }

# Application state (injected by PAGI::Lifespan, read-only)
sub has_state {
    my $self = shift;
    return 0 unless exists $self->{scope}{state};
    croak 'PAGI::Request state must be a hashref'
        unless ref($self->{scope}{state}) eq 'HASH';
    return 1;
}

sub state {
    my $self = shift;
    require PAGI::State;
    return PAGI::State->new($self);
}

# Body streaming - mutually exclusive with buffered body methods
sub body_stream {
    my ($self, %opts) = @_;

    croak "Body already consumed; streaming not available" if $self->{scope}{'pagi.request.body.read'};
    croak "Body streaming already started" if $self->{scope}{'pagi.request.body.stream.created'};

    $self->{scope}{'pagi.request.body.stream.created'} = 1;

    my $max_bytes = $opts{max_bytes};
    my $limit_name = defined $max_bytes ? 'max_bytes' : undef;
    if (!defined $max_bytes) {
        my $cl = $self->content_length;
        if (defined $cl) {
            $max_bytes = $cl;
            $limit_name = 'content-length';
        }
    }

    return PAGI::Request::BodyStream->new(
        receive    => $self->{receive},
        max_bytes  => $max_bytes,
        limit_name => $limit_name,
        decode     => $opts{decode},
        strict     => $opts{strict},
    );
}

# Streaming multipart - mutually exclusive with buffered body methods
sub multipart_stream {
    my ($self, %opts) = @_;
    croak "Body already consumed; multipart_stream() not available"
        if $self->{scope}{'pagi.request.body.read'}
        || $self->{scope}{'pagi.request.body.stream.created'};
    croak "multipart_stream() requires a multipart/form-data request" unless $self->is_multipart;

    my $ct = $self->header('content-type') // '';
    my ($boundary) = $ct =~ /boundary=([^;\s]+)/;
    $boundary =~ s/^["']|["']$//g if defined $boundary;  # Strip quotes
    croak "No boundary found in Content-Type" unless defined $boundary && length $boundary;

    $self->{scope}{'pagi.request.body.stream.created'} = 1;  # latch: lock out buffered readers

    require PAGI::Request::MultipartStream;
    return PAGI::Request::MultipartStream->new(
        receive  => $self->{receive},
        boundary => $boundary,
        map { defined $opts{$_} ? ($_ => $opts{$_}) : () }
            qw(max_files max_fields max_field_size max_file_size max_request_body),
    );
}

# Read raw body bytes (async, cached in scope)
async sub body {
    my $self = shift;

    croak "Body streaming already started; buffered helpers unavailable"
        if $self->{scope}{'pagi.request.body.stream.created'};

    # Return cached body if already read
    return $self->{scope}{'pagi.request.body'} if $self->{scope}{'pagi.request.body.read'};

    # A prior call already hit a mid-body disconnect: fail identically instead
    # of re-awaiting a receive that will never resolve normally again.
    if ($self->{scope}{'pagi.request.body.truncated'}) {
        my $connection = $self->connection;
        my $reason = $connection ? $connection->disconnect_reason : undef;
        $reason //= 'disconnect';
        croak "Request body incomplete: client disconnected mid-body ($reason)";
    }

    my $receive = $self->{receive};
    die "No receive callback provided" unless $receive;

    my $body = '';
    while (1) {
        my $message = await $receive->();
        last unless $message && $message->{type};
        if ($message->{type} eq 'http.disconnect') {
            last unless length $body;  # no bytes ever arrived -- an empty body, not a truncation
            $self->{scope}{'pagi.request.body.truncated'} = 1;
            my $connection = $self->connection;
            my $reason = $connection ? $connection->disconnect_reason : undef;
            $reason //= 'disconnect';
            croak "Request body incomplete: client disconnected mid-body ($reason)";
        }

        $body .= $message->{body} // '';
        last unless $message->{more};
    }

    $self->{scope}{'pagi.request.body'} = $body;
    $self->{scope}{'pagi.request.body.read'} = 1;
    return $body;
}

# Read body as decoded UTF-8 text (async)
# Options: strict => 1 (croak on invalid UTF-8)
async sub text {
    my ($self, %opts) = @_;
    my $strict = delete $opts{strict} // 0;
    croak("Unknown options to text: " . join(', ', keys %opts)) if %opts;

    my $body = await $self->body;
    return _decode_utf8($body, $strict);
}

# Parse body as JSON (async, dies on error)
async sub json {
    my $self = shift;
    my $body = await $self->body;
    return decode_json($body);
}

# Parse URL-encoded form body (async, returns Hash::MultiValue, cached in scope)
# Options: strict => 1 (croak on invalid UTF-8), raw => 1 (skip UTF-8 decoding)
async sub form_params {
    my ($self, %opts) = @_;
    my $strict = delete $opts{strict} // 0;
    my $raw    = delete $opts{raw}    // 0;

    # Extract multipart options before checking for unknown opts
    my %multipart_opts;
    for my $key (qw(max_field_size max_file_size spool_threshold max_files max_fields temp_dir)) {
        $multipart_opts{$key} = delete $opts{$key} if exists $opts{$key};
    }
    croak("Unknown options to form_params: " . join(', ', keys %opts)) if %opts;

    my $cache_key = $raw ? 'pagi.request.form.raw' : ($strict ? 'pagi.request.form.strict' : 'pagi.request.form');

    # Return cached if available
    return $self->{scope}{$cache_key} if $self->{scope}{$cache_key};

    # For multipart, delegate to uploads handling
    if ($self->is_multipart) {
        # Multipart always parses to default cache, then copy
        my $form = await $self->_parse_multipart_form(%multipart_opts);
        $self->{scope}{$cache_key} = $form;
        return $form;
    }

    # URL-encoded form
    my $body = await $self->body;
    my @pairs;

    for my $part (split /[&;]/, $body) {
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

    $self->{scope}{$cache_key} = Hash::MultiValue->new(@pairs);
    return $self->{scope}{$cache_key};
}

# DEPRECATED: Alias with warning
async sub form {
    my $self = shift;
    carp "form() is deprecated; use form_params() instead";
    return await $self->form_params(@_);
}

# Singular accessor for form params
async sub form_param {
    my ($self, $name, %opts) = @_;
    my $form = await $self->form_params(%opts);
    return $form->get($name);
}

# Raw form params (no UTF-8 decoding)
async sub raw_form_params {
    my ($self, %opts) = @_;
    return await $self->form_params(%opts, raw => 1);
}

# DEPRECATED: Alias with warning
async sub raw_form {
    my $self = shift;
    carp "raw_form() is deprecated; use raw_form_params() instead";
    return await $self->raw_form_params(@_);
}

# Raw singular accessor
async sub raw_form_param {
    my ($self, $name) = @_;
    return await $self->form_param($name, raw => 1);
}

# Parse multipart form (internal, cached in scope)
async sub _parse_multipart_form {
    my ($self, %opts) = @_;

    croak "Body streaming already started; buffered helpers unavailable"
        if $self->{scope}{'pagi.request.body.stream.created'};

    # Already parsed?
    return $self->{scope}{'pagi.request.form'}
        if $self->{scope}{'pagi.request.form'} && $self->{scope}{'pagi.request.uploads'};

    # Extract boundary from content-type
    my $ct = $self->header('content-type') // '';
    my ($boundary) = $ct =~ /boundary=([^;\s]+)/;
    $boundary =~ s/^["']|["']$//g if $boundary;  # Strip quotes

    die "No boundary found in Content-Type" unless $boundary;

    my $handler = PAGI::Request::MultiPartHandler->new(
        boundary        => $boundary,
        receive         => $self->{receive},
        max_field_size  => $opts{max_field_size},
        max_file_size   => $opts{max_file_size},
        spool_threshold => $opts{spool_threshold},
        max_files       => $opts{max_files},
        max_fields      => $opts{max_fields},
        temp_dir        => $opts{temp_dir},
    );

    my ($form, $uploads) = await $handler->parse;

    $self->{scope}{'pagi.request.form'} = $form;
    $self->{scope}{'pagi.request.uploads'} = $uploads;
    $self->{scope}{'pagi.request.body.read'} = 1;  # Body has been consumed

    return $form;
}

# Get all uploads as Hash::MultiValue (cached in scope)
async sub uploads {
    my ($self, %opts) = @_;

    return $self->{scope}{'pagi.request.uploads'} if $self->{scope}{'pagi.request.uploads'};

    if ($self->is_multipart) {
        await $self->_parse_multipart_form(%opts);
        return $self->{scope}{'pagi.request.uploads'};
    }

    # Not multipart - return empty
    $self->{scope}{'pagi.request.uploads'} = Hash::MultiValue->new();
    return $self->{scope}{'pagi.request.uploads'};
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
    use Future::AsyncAwait;

    async sub app {
        my ($scope, $receive, $send) = @_;
        my $req = PAGI::Request->new($scope, $receive);

        # Basic properties
        my $method = $req->method;        # GET, POST, etc.
        my $path   = $req->path;          # /users/42
        my $host   = $req->host;          # example.com

        # Query parameters (Hash::MultiValue)
        my $page = $req->query_param('page');
        my @tags = $req->query_params->get_all('tags');

        # Headers
        my $ct = $req->content_type;
        my $auth = $req->header('authorization');

        # Cookies
        my $session = $req->cookie('session');

        # Body parsing (async)
        my $json = await $req->json;           # Parse JSON body
        my $form = await $req->form_params;    # Parse form data (Hash::MultiValue)
        my $name = await $req->form_param('name');  # Single form value

        # File uploads
        my $avatar = await $req->upload('avatar');
        if ($avatar && !$avatar->is_empty) {
            $avatar->move_to('/uploads/avatar.jpg');  # blocking I/O
        }

        # Streaming large bodies
        my $stream = $req->body_stream(max_bytes => 100 * 1024 * 1024);
        await $stream->stream_to_file('/uploads/large.bin');

        # Auth helpers
        my $token = $req->bearer_token;
        my ($user, $pass) = $req->basic_auth;

        # Per-request shared state
        use PAGI::Stash;
        my $stash = PAGI::Stash->new($req);
        $stash->set(user => $current_user);
    }

=head1 DESCRIPTION

PAGI::Request provides a friendly interface to PAGI request data. It wraps
the raw C<$scope> hashref and C<$receive> callback with convenient methods
for accessing headers, query parameters, cookies, request body, and file
uploads.

This is an optional convenience layer. Raw PAGI applications continue to
work with C<$scope> and C<$receive> directly.

=head1 CONSTRUCTOR

=head2 new

    my $req = PAGI::Request->new($scope, $receive);

Creates an HTTP request object. C<$scope> must be an unblessed hashref with
C<< $scope->{type} eq 'http' >>, and C<$receive> must be a coderef. The
receive callback is retained for deferred body consumption; construction never
reads from it. These are the constructor's exact two arguments after the
invocant; a C<$send> callback or any other extra argument is rejected.

=head1 PROPERTIES

=head2 method

HTTP method (GET, POST, PUT, etc.)

=head2 path

Request path, UTF-8 decoded.

=head2 raw_path

Request path as raw bytes (percent-encoded).

=head2 query_string

Raw query string (without leading ?).

=head2 scheme

C<http> or C<https>.

=head2 host

Returns the complete validated Host field, including an explicit port. Returns
C<undef> only when Host is absent, and croaks when Host is malformed or occurs
more than once. Use L</header> with C<'host'> as the raw, last-value escape
hatch when that behavior is required.

=head2 http_version

HTTP version (1.0 or 1.1).

=head2 client

Arrayref of C<[host, port]> or undef.

=head2 server

Arrayref of C<[host, port]> for the local server endpoint, or undef when the
server did not provide it. This is informational only; use L</host> for the
validated inbound Host authority.

=head2 content_type

Content-Type header value (without parameters).

=head2 content_length

Content-Length header value.

=head2 raw

Deferred alias for L</scope>; returns the raw scope hashref without interpreting
it.

=head1 HEADER METHODS

=head2 header

    my $value = $req->header('Content-Type');

Get a single header value (case-insensitive). Returns the last value if
the header appears multiple times.

=head2 header_all

    my @values = $req->header_all('Accept');

Get all values for a header.

=head2 headers

    my $headers = $req->headers;  # PAGI::Headers

Returns a L<PAGI::Headers> clone of the inbound headers snapshot. The returned
object is independent: mutating it (C<clear>, C<set>, etc.) does not affect
subsequent calls to C<header>, C<header_all>, C<content_type>, or C<cookie>
-- those always read the private snapshot, not the clone.

=head1 QUERY PARAMETERS

=head2 query_params

    my $params = $req->query_params;  # Hash::MultiValue
    my $params = $req->query_params(strict => 1);  # Die on invalid UTF-8
    my $params = $req->query_params(raw => 1);     # Skip UTF-8 decoding

Get query parameters as L<Hash::MultiValue>.

B<Options:>

=over 4

=item * C<strict> - If true, die on invalid UTF-8 sequences. Default: false
(invalid bytes replaced with U+FFFD).

=item * C<raw> - If true, skip UTF-8 decoding entirely and return raw bytes.
Default: false.

=back

=head2 query_param

    my $value = $req->query_param('page');
    my $value = $req->query_param('page', strict => 1);
    my $value = $req->query_param('page', raw => 1);

Shortcut for C<< $req->query_params(%opts)->get($name) >>. Accepts the same
C<strict> and C<raw> options as C<query_params>.

=head2 raw_query_param

    my $value = $req->raw_query_param('page');

Shortcut for C<< $req->query_param($name, raw => 1) >>. Returns the raw bytes
without UTF-8 decoding.

=head1 PATH PARAMETERS

Path parameters are captured from the URL path by a router (e.g., L<PAGI::App::Router>)
and stored in C<< $scope->{path_params} >>. This is a router-agnostic interface -
any router can populate this field.

=head2 path_params

    my $params = $req->path_params;  # hashref

Get all path parameters as a hashref. Returns an empty hashref if no router
has set path parameters.

    # Route: /users/:id/posts/:post_id
    # URL: /users/42/posts/100
    my $params = $req->path_params;
    # { id => '42', post_id => '100' }

B<Note:> This method can be overridden in subclasses for custom parameter
handling (e.g., lazy conversion from positional to named parameters).
The C<path_param> method delegates to this method.

B<Options:>

=over 4

=item * C<strict> - If true, die when no router has populated
C<< $scope->{path_params} >> instead of returning an empty hashref. Default:
false. Mirrors the C<strict> option on L</path_param>.

=back

=head2 path_param

    my $id = $req->path_param('id');
    my $id = $req->path_param('id', strict => 0);  # Don't die if missing

Get a single path parameter by name.

    # Route: /users/:id
    # URL: /users/42
    my $id = $req->path_param('id');  # '42'

B<Strict by default:> Unlike C<query_param()>, this method dies if the requested
parameter does not exist. This catches typos early since path parameters are
defined by the route - if the route matched, the expected parameters must
exist.

    # Route defines :userId but you typed :user_id
    my $id = $req->path_param('user_id');
    # Dies: "path_param 'user_id' not found. Available: userId, postId"

B<Options:>

=over 4

=item * C<strict> - If false, return C<undef> for missing parameters instead
of dying. Default: true.

=back

=head2 Strict Mode

By default, C<path_params> returns an empty hashref if no router has set
C<< $scope->{path_params} >>. This is the safest behavior for middleware and
handlers that may run with or without a router.

To catch configuration errors early, pass C<< strict => 1 >>:

    # Dies if no router populated the scope:
    my $params = $req->path_params(strict => 1);
    # "path_params not set in scope (no router configured?)"

C<path_param> (singular) is strict by default for the requested key, so asking
for a parameter when no router ran also dies, naming the missing key:

    my $id = $req->path_param('id');
    # "path_param 'id' not found. ... No path params set (no router?)"

This matches Starlette's behavior of returning an empty dict by default, while
letting you opt into a loud failure per call.

=head1 COOKIES

=head2 cookies

    my $cookies = $req->cookies;  # hashref

Get all cookies.

=head2 cookie

    my $session = $req->cookie('session');

Get a single cookie value.

=head1 BODY METHODS (ASYNC)

=head2 body_stream

    my $stream = $req->body_stream;
    my $stream = $req->body_stream(
        max_bytes => 10 * 1024 * 1024,  # 10MB limit
        decode    => 'UTF-8',            # Decode to UTF-8
        strict    => 1,                  # Strict UTF-8 decoding
    );

Returns a L<PAGI::Request::BodyStream> for streaming body consumption. This is
useful for processing large request bodies incrementally without loading them
entirely into memory.

B<Options:>

=over 4

=item * C<max_bytes> - Maximum body size. Defaults to Content-Length header if present.

=item * C<decode> - Encoding to decode chunks to (typically 'UTF-8').

=item * C<strict> - If true, throw on invalid UTF-8. Default: false (use replacement chars).

=back

B<Important:> Body streaming is mutually exclusive with buffered body methods
(C<body>, C<text>, C<json>, C<form_params>). Once you start streaming, you cannot use
those methods, and vice versa.

Example:

    # Stream large upload to file
    my $stream = $req->body_stream(max_bytes => 100 * 1024 * 1024);
    await $stream->stream_to_file('/uploads/data.bin');

See L<PAGI::Request::BodyStream> for full documentation.

=head2 multipart_stream

    my $stream = $req->multipart_stream;
    my $stream = $req->multipart_stream(
        max_files        => 1000,
        max_fields       => 1000,
        max_field_size   => 1024 * 1024,
        max_file_size    => 100 * 1024 * 1024,
        max_request_body => 1024 * 1024 * 1024,
    );

Returns a L<PAGI::Request::MultipartStream> for pull-based streaming of a
C<multipart/form-data> request body. You pull one part at a time and choose
where each one goes:

    while (defined(my $part = await $stream->next)) {
        if ($part->is_file) {
            await $part->stream_to_file($path);
        }
        else {
            my $value = await $part->value;  # raw bytes; you decode
        }
    }

Each part is a L<PAGI::Request::Part> exposing its metadata (C<name>,
C<filename>, C<content_type>, C<headers>, C<is_file>) and methods to consume
its body: C<next_chunk> (pull raw bytes), C<value> (buffer the whole part as
raw bytes), C<stream_to($cb)> (drain to a possibly-async sink), and
C<stream_to_file($path)> (write to a new file, path-safe).

Unlike the buffered multipart path (C<form_params>/C<uploads>), this does
B<not> spool each upload to a temp file: the application owns the sink, so a
part can stream straight to an object store or a transform, and that sink can
be fully asynchronous (C<stream_to> awaits a Future-returning sink for
backpressure) -- whereas the buffered spool is blocking.

B<Options:>

=over 4

=item * C<max_files> - Maximum number of file parts. Default: 1000.

=item * C<max_fields> - Maximum number of field parts. Default: 1000.

=item * C<max_field_size> - Maximum bytes per field part. Default: 1 MiB.

=item * C<max_file_size> - Maximum bytes per file part. Default: 100 MiB.

=item * C<max_request_body> - Maximum total body bytes (per-stream
defence-in-depth; the server's C<max_body_size> is the primary cap).
Default: 1 GiB.

=back

B<Important:> Streaming the multipart body is mutually exclusive with the
buffered body methods. C<multipart_stream> croaks if the body was already read
or a stream was already created, and conversely C<body>/C<text>/C<json>/
C<form_params>/C<uploads> croak once a stream exists -- a body can only be
consumed once.

See L<PAGI::Request::MultipartStream> for full documentation.

=head2 body

    my $bytes = await $req->body;

Read raw body bytes. Cached after first read.

B<Important:> Cannot be used after C<body_stream()> has been called.

B<Truncation:> if the client disconnects after sending some but not all of
the body, C<body> croaks with
C<< "Request body incomplete: client disconnected mid-body ($reason)" >>
instead of silently returning whatever bytes had arrived -- a partial body is
never cached or handed back as if it were complete. A second call croaks
identically without re-awaiting the connection. An immediate disconnect
before any bytes ever arrive is treated as an empty body, not a truncation.
C<text>, C<json>, and C<form_params> all read the body through this method,
so they fail the same way.

=head2 text

    my $text = await $req->text;

Read body as UTF-8 decoded text.

=head2 json

    my $data = await $req->json;

Parse body as JSON. Dies on parse error.

=head2 form_params

    my $form = await $req->form_params;  # Hash::MultiValue
    my $form = await $req->form_params(strict => 1);  # Die on invalid UTF-8
    my $form = await $req->form_params(raw => 1);     # Skip UTF-8 decoding

Parse URL-encoded or multipart form data, returning a L<Hash::MultiValue>.

B<Options:>

=over 4

=item * C<strict> - If true, die on invalid UTF-8 sequences. Default: false.

=item * C<raw> - If true, skip UTF-8 decoding entirely. Default: false.

=item * C<max_field_size>, C<max_file_size>, C<spool_threshold>, C<max_files>,
C<max_fields>, C<temp_dir> - Per-request limits for multipart parsing, passed
through to L<PAGI::Request::MultiPartHandler>. Each defaults to the matching
package variable in that module (e.g.
C<$PAGI::Request::MultiPartHandler::MAX_FILE_SIZE>); C<local>-ize those to
change a default process-wide.

=back

=head2 form_param

    my $value = await $req->form_param('name');
    my $value = await $req->form_param('name', strict => 1);

Shortcut for C<< (await $req->form_params(%opts))->get($name) >>. Accepts the
same C<strict> and C<raw> options as C<form_params>.

=head2 raw_form_params

    my $form = await $req->raw_form_params;

Shortcut for C<< $req->form_params(raw => 1) >>. Returns form data without
UTF-8 decoding.

=head2 raw_form_param

    my $value = await $req->raw_form_param('name');

Shortcut for C<< $req->form_param($name, raw => 1) >>. Returns a single form
value without UTF-8 decoding.

=head1 UPLOAD METHODS (ASYNC)

=head2 uploads

    my $uploads = await $req->uploads;  # Hash::MultiValue

Get all uploads as L<Hash::MultiValue> of L<PAGI::Request::Upload> objects.

=head2 upload

    my $file = await $req->upload('avatar');

Get a single upload by field name.

=head2 upload_all

    my @files = await $req->upload_all('photos');

Get all uploads for a field name.

=head1 PREDICATES

=head2 is_get, is_post, is_put, is_patch, is_delete, is_head, is_options

    if ($req->is_post) { ... }

Check HTTP method.

=head2 is_json

True if Content-Type is C<application/json>.

=head2 is_form

True if Content-Type is form-urlencoded or multipart.

=head2 is_multipart

True if Content-Type is C<multipart/form-data>.

=head2 accepts

    if ($req->accepts('text/html')) { ... }
    if ($req->accepts('json')) { ... }

Check Accept header (supports wildcards and shortcuts). Returns true if the
client accepts the given MIME type.

=head2 preferred_type

    my $type = $req->preferred_type('json', 'html', 'xml');

Returns the best matching content type from the provided list based on the
client's Accept header and quality values. Returns undef if none are acceptable.
Supports shortcuts (json, html, xml, etc).

=head1 CONNECTION STATE METHODS

These methods provide non-destructive connection lookup without reading from
the receive queue.

=head2 connection

    my $conn = $req->connection;

Returns the L<PAGI::Server::ConnectionState> object for this request, or
C<undef> if not provided by the server.

=head2 is_disconnected

    if ($req->is_disconnected) {
        # Client has disconnected
    }

Returns C<1> when the provided connection reports disconnected, C<0> when it
reports connected, and C<undef> when no C<pagi.connection> is available.

For advanced lifecycle, disconnect-reason, callback, or Future operations,
obtain the server-provided object with L</connection> and use its explicit
interface directly. Outbound transport is separate from connection lifecycle.
Use the L<PAGI::Transport> factory for its optional flow-control facade:

    use PAGI::Transport qw(transport);
    my $flow = transport($req);

Raw PAGI applications may likewise call C<transport($scope)>. Reach through
C<< $req->scope->{'pagi.transport'} >> only as an explicit jailbreak when an
integration truly requires the server's raw transport handle.

=head1 AUTH HELPERS

=head2 bearer_token

    my $token = $req->bearer_token;

Extract Bearer token from Authorization header.

=head2 basic_auth

    my ($user, $pass) = $req->basic_auth;

Decode Basic auth credentials.

=head2 scope

    my $scope = $req->scope;

Returns the raw PAGI scope hashref. Useful for constructing helper
objects like L<PAGI::Stash> and L<PAGI::Session>:

    my $stash = PAGI::Stash->new($req);

=head2 Constructing responses

Request owns HTTP input and remains the scope source for request-local helpers;
it does not manufacture or cache a Response. Construct the desired concrete
L<PAGI::Response> value directly and return it from a normal handler:

    use PAGI::Response qw(json_response);

    sub create_item {
        my ($request) = @_;
        return json_response({ created => \1 }, status => 201);
    }

Only a raw native application owns response emission. It passes the complete
native triplet to C<respond>:

    await $response->respond($scope, $receive, $send);

=head2 Per-Request Shared State

See L<PAGI::Stash> for per-request shared state between middleware
and handlers. Construct from a Request object or scope:

    use PAGI::Stash;
    my $stash = PAGI::Stash->new($req);
    $stash->set(user => $current_user);

=cut

=head2 state

    my $state = $req->state;
    my $db = $state->get('db');
    my $config = $state->get('config');

Returns a L<PAGI::State> facade over the application state injected by
L<PAGI::Lifespan>. This contains worker-level shared state like database
connections and configuration. Returns C<undef> if no state was injected and
croaks if a present state value is not a hashref.

Repeated calls are not guaranteed to return the same facade object.

=head2 has_state

Returns true when a state hashref is present and false when state is absent.
Croaks when a present state value is malformed.

B<Key differences from L<PAGI::Stash>:>

=over 4

=item * C<state> is read-only, set during lifespan startup

=item * C<state> is shared across all requests in a worker

=item * L<PAGI::Stash> is per-request, writable by middleware/handlers

=back

=head1 SEE ALSO

L<PAGI::Stash>, L<PAGI::Request::Upload>, L<PAGI::Request::BodyStream>, L<Hash::MultiValue>

=cut
