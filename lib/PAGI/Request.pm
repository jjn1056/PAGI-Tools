package PAGI::Request;
use strict;
use warnings;
use parent 'PAGI::HTTPConnection';
use Hash::MultiValue;
use PAGI::Headers ();
use PAGI::Authority ();
use Encode qw(find_encoding FB_CROAK FB_DEFAULT LEAVE_SRC);
use Future::AsyncAwait;
use JSON::MaybeXS qw(decode_json);
use Carp qw(croak);
use PAGI::Request::MultiPartHandler;
use PAGI::Request::Upload;
use PAGI::ContentNegotiation;
use PAGI::Exception::HTTP ();
use PAGI::Exception::RequestBody;
use PAGI::Request::BodyStream;
use PAGI::Request::_BodyInput ();

# Without a receive (absent or undef) the Request reads the scope but has no
# body: every body entry point dies in _require_body_scope.
sub new {
    croak 'PAGI::Request->new requires exactly scope and receive arguments'
        if @_ > 3;
    my ($class, $scope, $receive) = @_;
    my $self = $class->SUPER::new($scope);
    croak 'PAGI::Request requires a receive coderef'
        if defined($receive) && ref($receive) ne 'CODE';
    $self->{receive} = $receive;
    return $self;
}

sub method       { shift->{scope}{method} }
sub raw          { shift->{scope} }

# As _decode_utf8, for request body content: invalid UTF-8 under strict is the
# client's error, a PAGI::Exception::RequestBody (400) rather than a croak.
sub _decode_body_utf8 {
    my ($str, $strict) = @_;
    my $text = eval { PAGI::HTTPConnection::_decode_utf8($str, $strict) };
    return $text unless $@;
    PAGI::Exception::RequestBody->throw(
        reason => 'invalid_encoding',
        message => 'The request body is not valid UTF-8.',
        cause => $@,
    );
}

# The body as text in the charset the client declared, UTF-8 when it declared
# none. A charset Encode does not know is a 415; under strict, bytes invalid in
# the charset are a 400.
sub _decode_body_text {
    my ($self, $body, $strict) = @_;
    my $charset = $self->charset;
    return _decode_body_utf8($body, $strict) unless defined $charset;

    my $encoding = find_encoding($charset)
        or PAGI::Exception::RequestBody->throw(
            status_code => 415,
            reason => 'unsupported_charset',
            message => "The request body's charset is not supported.",
        );
    # Encode's 'utf8' is its lax variant; a client's UTF-8 is decoded strictly.
    return _decode_body_utf8($body, $strict) if $encoding->name =~ /\Autf-?8/i;

    my $text = eval {
        $encoding->decode($body // '', ($strict ? FB_CROAK : FB_DEFAULT) | LEAVE_SRC);
    };
    return $text unless $@;
    PAGI::Exception::RequestBody->throw(
        reason => 'invalid_encoding',
        message => "The request body is not valid $charset.",
        cause => $@,
    );
}

sub host {
    my ($self) = @_;
    return PAGI::Authority->host_from_scope($self->{scope});
}

# Content-Type shortcut
sub content_type {
    my ($self, @opts) = @_;
    return $self->_client_header('content_type', 'Content-Type', @opts) // '';
}

# The Content-Type charset parameter, as sent (undef when there is none)
sub charset {
    my $self = shift;
    my $parameters = $self->headers->content_type_parameters or return undef;
    return $parameters->{charset};
}

# Content-Length shortcut
sub content_length {
    my $self = shift;
    return $self->headers->get_single('content-length');
}

# Method predicates
sub is_get     { uc(shift->method // '') eq 'GET' }
sub is_post    { uc(shift->method // '') eq 'POST' }
sub is_put     { uc(shift->method // '') eq 'PUT' }
sub is_patch   { uc(shift->method // '') eq 'PATCH' }
sub is_delete  { uc(shift->method // '') eq 'DELETE' }
sub is_head    { uc(shift->method // '') eq 'HEAD' }
sub is_options { uc(shift->method // '') eq 'OPTIONS' }

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
    # application/json, or any +json structured-syntax type (RFC 6839), such
    # as application/vnd.api+json or application/problem+json.
    return $ct eq 'application/json' || $ct =~ m{\Aapplication/[^/\s]+\+json\z} ? 1 : 0;
}

sub is_form {
    my $self = shift;
    my $ct = $self->content_type;
    return $ct eq 'application/x-www-form-urlencoded'
        || $ct eq 'multipart/form-data';
}

sub is_multipart {
    my $self = shift;
    my $ct = $self->content_type;
    return $ct eq 'multipart/form-data';
}

# Accept header check using PAGI::ContentNegotiation
# Combines multiple Accept headers per RFC 7230 Section 3.2.2
sub accepts {
    my ($self, $mime_type) = @_;
    my @accept_values = $self->header_all('accept');
    my $accept = join(', ', @accept_values);
    return PAGI::ContentNegotiation->accepts_type($accept, $mime_type);
}

# Find best matching content type from supported list
# Combines multiple Accept headers per RFC 7230 Section 3.2.2
sub preferred_type {
    my ($self, @types) = @_;
    my @accept_values = $self->header_all('accept');
    my $accept = join(', ', @accept_values);
    return PAGI::ContentNegotiation->best_match(\@types, $accept);
}

# Extract Bearer token from Authorization header
sub bearer_token {
    my ($self, @opts) = @_;
    return $self->_client_header('authorization_bearer', 'Authorization', @opts);
}

# Extract Basic auth credentials
sub basic_auth {
    my ($self, @opts) = @_;
    return $self->_client_header('authorization_basic', 'Authorization', @opts);
}

# Reads one of the client's header fields through PAGI::Headers' $method.
# What raise_on_error refuses -- a duplicate or malformed field -- is the
# client's error, so it is an HTTP 400, as a body the client got wrong is.
# The options are checked first, so an option error stays a croak.
sub _client_header {
    my ($self, $method, $field, @opts) = @_;
    my $raise = PAGI::Headers::_read_options($method, @opts);
    return $self->headers->$method(@opts) unless $raise;
    my @value;
    return wantarray ? @value : $value[0]
        if eval { @value = $self->headers->$method(@opts); 1 };
    PAGI::Exception::HTTP->throw(400, "The $field header could not be parsed.");
}

sub _require_body_scope {
    my ($self) = @_;
    croak 'this Request was built from the scope alone; it has no body'
        unless defined $self->{receive};
    my $type = $self->{scope}{type};
    croak 'body input requires HTTP or SSE scope'
        unless $type eq 'http' || $type eq 'sse';
    return $type;
}

# Body streaming - mutually exclusive with buffered body methods
sub body_stream {
    my ($self, %opts) = @_;
    my $scope_type = $self->_require_body_scope;

    croak "Body already consumed; streaming not available" if $self->{_body_read};
    croak "Body streaming already started" if $self->{_body_stream_created};

    my $max_bytes = $opts{max_bytes};
    my $limit_name = defined $max_bytes ? 'max_bytes' : undef;
    if (!defined $max_bytes) {
        my $cl = $self->content_length;
        if (defined $cl) {
            $max_bytes = $cl;
            $limit_name = 'content-length';
        }
    }

    # Made before the body is marked as streaming: a stream that cannot be
    # made (a charset it cannot decode, a 415) leaves the body to text.
    my $stream = PAGI::Request::BodyStream->new(
        receive    => $self->{receive},
        max_bytes  => $max_bytes,
        limit_name => $limit_name,
        decode     => $opts{decode},
        strict     => $opts{strict},
        strip_bom  => $opts{strip_bom},
        max_line_length => $opts{max_line_length},
        _scope_type => $scope_type,
    );
    $self->{_body_stream_created} = 1;
    return $stream;
}

# Streaming multipart - mutually exclusive with buffered body methods
sub multipart_stream {
    my ($self, %opts) = @_;
    my $scope_type = $self->_require_body_scope;
    croak "Body already consumed; multipart_stream() not available"
        if $self->{_body_read}
        || $self->{_body_stream_created};
    croak "multipart_stream() requires a multipart/form-data request" unless $self->is_multipart;

    my $parameters = $self->headers->content_type_parameters;
    my $boundary = defined($parameters) ? $parameters->{boundary} : undef;
    PAGI::Exception::RequestBody->throw(
        reason => 'invalid_multipart', message => 'No boundary found in Content-Type',
    ) unless defined $boundary && length $boundary;

    $self->{_body_stream_created} = 1;  # latch: lock out buffered readers

    require PAGI::Request::MultipartStream;
    return PAGI::Request::MultipartStream->new(
        receive  => $self->{receive},
        boundary => $boundary,
        _scope_type => $scope_type,
        map { defined $opts{$_} ? ($_ => $opts{$_}) : () }
            qw(max_files max_fields max_field_size max_file_size max_request_body),
    );
}

# Read raw body bytes (async; kept on this object, never in the scope)
async sub body {
    my $self = shift;
    my $scope_type = $self->_require_body_scope;

    croak "Body streaming already started; buffered helpers unavailable"
        if $self->{_body_stream_created};

    # Return cached body if already read. A multipart parse streams the body
    # to its parts and keeps no copy of it.
    if ($self->{_body_read}) {
        croak 'The raw body of a multipart request is not kept; read it with form_params and uploads'
            unless exists $self->{_body};
        return $self->{_body};
    }

    # A prior call already hit a mid-body disconnect: fail identically instead
    # of re-awaiting a receive that will never resolve normally again.
    if ($self->{_body_truncated}) {
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
        my $kind = PAGI::Request::_BodyInput::event_kind($scope_type, $message);
        if ($kind eq 'disconnect') {
            last unless length $body;  # no bytes ever arrived -- an empty body, not a truncation
            $self->{_body_truncated} = 1;
            my $connection = $self->connection;
            my $reason = $connection ? $connection->disconnect_reason : undef;
            $reason //= 'disconnect';
            croak "Request body incomplete: client disconnected mid-body ($reason)";
        }

        $body .= $message->{body} // '';
        last unless $message->{more};
    }

    $self->{_body} = $body;
    $self->{_body_read} = 1;
    return $body;
}

# Read body as decoded UTF-8 text (async)
# Options: strict => 1 (bytes invalid in the charset are a 400)
async sub text {
    my ($self, %opts) = @_;
    my $strict = delete $opts{strict} // 0;
    croak("Unknown options to text: " . join(', ', keys %opts)) if %opts;

    my $body = await $self->body;
    return $self->_decode_body_text($body, $strict);
}

# Parse body as JSON (async; a body that is not JSON is a PAGI::Exception::RequestBody, 400)
async sub json {
    my $self = shift;
    my $body = await $self->body;
    my $data = eval { decode_json($body) };
    PAGI::Exception::RequestBody->throw(
        reason => 'invalid_json',
        message => 'The request body is not valid JSON.',
        cause => $@,
    ) if $@;
    return $data;
}

# Parse URL-encoded form body (async, returns Hash::MultiValue, kept on this Request)
# Options: strict => 1 (croak on invalid UTF-8), raw => 1 (skip UTF-8 decoding)
async sub form_params {
    my ($self, %opts) = @_;
    $self->_require_body_scope;
    my $strict = delete $opts{strict} // 0;
    my $raw    = delete $opts{raw}    // 0;

    # Extract multipart options before checking for unknown opts
    my %multipart_opts;
    for my $key (qw(max_field_size max_file_size spool_threshold max_files max_fields temp_dir)) {
        $multipart_opts{$key} = delete $opts{$key} if exists $opts{$key};
    }
    croak("Unknown options to form_params: " . join(', ', keys %opts)) if %opts;

    my $cache_key = $raw ? '_form_raw' : ($strict ? '_form_strict' : '_form');

    # Return cached if available
    return $self->{$cache_key} if $self->{$cache_key};

    # For multipart, delegate to uploads handling
    if ($self->is_multipart) {
        # Multipart always parses to default cache, then copy
        my $form = await $self->_parse_multipart_form(%multipart_opts);
        $self->{$cache_key} = $form;
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
        my $key_decoded = PAGI::HTTPConnection::_url_decode($key);
        my $val_decoded = PAGI::HTTPConnection::_url_decode($val);

        # UTF-8 decode unless raw mode
        my $key_final = $raw ? $key_decoded : _decode_body_utf8($key_decoded, $strict);
        my $val_final = $raw ? $val_decoded : _decode_body_utf8($val_decoded, $strict);

        push @pairs, $key_final, $val_final;
    }

    $self->{$cache_key} = Hash::MultiValue->new(@pairs);
    return $self->{$cache_key};
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

# Raw singular accessor
async sub raw_form_param {
    my ($self, $name) = @_;
    return await $self->form_param($name, raw => 1);
}

# Parse multipart form (internal, kept on this Request)
async sub _parse_multipart_form {
    my ($self, %opts) = @_;
    my $scope_type = $self->_require_body_scope;

    croak "Body streaming already started; buffered helpers unavailable"
        if $self->{_body_stream_created};

    # Already parsed?
    return $self->{_form}
        if $self->{_form} && $self->{_uploads};

    my $parameters = $self->headers->content_type_parameters;
    my $boundary = defined($parameters) ? $parameters->{boundary} : undef;
    PAGI::Exception::RequestBody->throw(
        reason => 'invalid_multipart', message => 'No boundary found in Content-Type',
    ) unless defined($boundary) && length($boundary);

    my $handler = PAGI::Request::MultiPartHandler->new(
        boundary        => $boundary,
        receive         => $self->{receive},
        _scope_type     => $scope_type,
        max_field_size  => $opts{max_field_size},
        max_file_size   => $opts{max_file_size},
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

# Get all uploads as Hash::MultiValue (kept on this Request)
async sub uploads {
    my ($self, %opts) = @_;
    $self->_require_body_scope;

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

        # Per-request shared state (with middleware('Stash') above)
        use PAGI::Stash;
        my $stash = PAGI::Stash->new($req);
        $stash->set(user => $current_user);
    }

=head1 DESCRIPTION

PAGI::Request provides a friendly interface to PAGI request data. It wraps
the raw C<$scope> hashref and C<$receive> callback with convenient methods
for accessing headers, query parameters, cookies, request body, and file
uploads.

A PAGI::Request is a L<PAGI::HTTPConnection>: what can be read from the scope
alone -- path, headers, query and path parameters, cookies, client,
application state -- comes from the methods it inherits (see
L</INHERITED FROM PAGI::HTTPConnection>). This class adds the method, the
Host and Content-Type readers, the body, forms and uploads.

HTTP, WebSocket, and SSE scopes are supported for metadata access. Request
body input is available for HTTP and SSE scopes using each protocol's native
request and disconnect events. WebSocket scopes reject body methods before
reading from C<$receive> or changing body-consumption state.

This is an optional convenience layer. Raw PAGI applications continue to
work with C<$scope> and C<$receive> directly.

=head1 CONSTRUCTOR

=head2 new

    my $req = PAGI::Request->new($scope, $receive);
    my $req = PAGI::Request->new($scope);   # no body

Creates a request object. C<$scope> must be an unblessed HTTP, WebSocket, or
SSE scope hashref. C<$receive>, when given and defined, must be a coderef; it
is retained for deferred HTTP or SSE body consumption, and construction never
reads from it. These are the constructor's exact two arguments after the
invocant; a C<$send> callback or any other extra argument is rejected.

Without a receive (absent or C<undef>) the Request reads everything the scope
holds but has no body: L</body>, L</text>, L</json>, L</body_stream>,
L</multipart_stream>, the form methods and the upload methods die C<this
Request was built from the scope alone; it has no body>, before they read
anything or mark the body consumed. Code that only reads a request uses
L<PAGI::HTTPConnection>; this form is for code that needs the application's
Request class without its body, as L<PAGI::Utils/request_for_scope> builds it.

=head1 PROPERTIES

=head2 method

Request method (GET, POST, PUT, etc.). A WebSocket scope may omit this value,
in which case C<method> returns C<undef>; it does not guess GET for an extended
CONNECT request.

=head2 host

Returns the complete validated Host field, including an explicit port. Returns
C<undef> only when Host is absent, and croaks when Host is malformed or occurs
more than once. To read the field without validation, use
L<PAGI::HTTPConnection/header> with C<'host'>: the raw value, or every value
joined C<", "> when Host is repeated.

=head2 content_type

The normalized media type from one valid Content-Type field, without
parameters. Returns C<''> when the field is absent, duplicated, or malformed.
With C<raise_on_error =E<gt> 1> a duplicate or malformed field throws a
L<PAGI::Exception::HTTP> 400, C<The Content-Type header could not be parsed.>:
the client sent it, so it is the client's error, which a Compose application
answers by itself (see L</AUTH HELPERS>).
Use C<< $request->header('Content-Type') >> for the raw joined lookup;
parsing does not alter the stored field.

=head2 charset

    my $charset = $request->charset;    # 'ISO-8859-1', or undef

The C<charset> parameter of the Content-Type field, exactly as the client
sent it (unquoted), or C<undef> when the field has none or is absent,
duplicated or malformed. Nothing is decoded because of it: pass it on when
you decide to read the body as text, for example
C<< body_stream(decode => $request->charset // 'UTF-8') >> (see
L</body_stream>).

=head2 content_length

Content-Length header value. A Content-Length sent twice reads as absent
(C<undef>).

=head2 raw

Deferred alias for L<PAGI::HTTPConnection/scope>; returns the raw scope hashref without interpreting
it.

=head1 INHERITED FROM PAGI::HTTPConnection

These methods read the scope and are documented in L<PAGI::HTTPConnection>:

=over 4

=item * Scope properties: C<scope>, C<connection>, C<client>, C<server>,
C<scheme>, C<http_version>, C<path>, C<raw_path>, C<raw_path_info>,
C<request_uri>, C<query_string>

=item * Headers: C<headers>, C<header>, C<header_all>

=item * Query parameters: C<query_params>, C<query_param>,
C<raw_query_params>, C<raw_query_param>

=item * Path parameters: C<path_params>, C<path_param>, and the subclass hook
C<_default_path_param_strict_opt>

=item * Cookies: C<cookies>, C<cookie>

=item * Application state: C<state>, C<has_state>

=back

=head1 BODY METHODS (ASYNC)

Body methods accept HTTP and SSE scopes and consume the matching native event
family. They croak on WebSocket scopes without calling C<$receive>, even when
a body, form, or upload cache is already present.

=head2 body_stream

    my $stream = $req->body_stream;
    my $stream = $req->body_stream(
        max_bytes => 10 * 1024 * 1024,  # 10MB limit
        decode    => 'UTF-8',            # Decode from UTF-8
        strict    => 1,                  # invalid bytes are a 400
        strip_bom => 1,                  # drop a leading byte-order mark
    );

Returns a L<PAGI::Request::BodyStream> for streaming body consumption. This is
useful for processing large request bodies incrementally without loading them
entirely into memory.

B<Options:>

=over 4

=item * C<max_bytes> - Maximum body size. Defaults to Content-Length header if present.

=item * C<decode> - The encoding to decode chunks from, such as C<'UTF-8'>.
Without it, chunks are the bytes the client sent. A character split across
chunks is held back until it is complete; an encoding the stream cannot
decode is a 415 when it is made.

=item * C<strict> - If true, bytes invalid in the C<decode> encoding throw a
L<PAGI::Exception::RequestBody> (400). Default: false (they become U+FFFD).

=item * C<strip_bom> - With C<decode>, drops a byte-order mark (U+FEFF) at
the very start of the text, as Excel's "CSV UTF-8" sends. Default: false (in
UTF-8 the mark is text).

=item * C<max_line_length> - The longest line
L<PAGI::Request::BodyStream/next_line> and C<each_line> accept (default
65536); a longer one is the client's 413.

=back

B<Bytes or text.> Without C<decode>, C<body_stream> gives you the bytes
exactly as sent: use that for files, archives, images, anything binary.
With C<decode>, it gives you text, decoded by the client's declared charset
and UTF-8 when it declares none:

    my $stream = $req->body_stream(decode => $req->charset // 'UTF-8');

B<strict>: off (the default) replaces bytes that are not valid in the
encoding with U+FFFD -- use it where a garbled character is acceptable,
such as a display or a transformation. On rejects them with a 400 -- use it
where you store or act on the text, and wherever a client might send
something that is not text at all: a binary file posted to a text route
fails at once instead of turning into garbage.

A charset the stream cannot decode is a 415 when the stream is made, as for
C<text>; catch the L<PAGI::Exception::RequestBody> at the call to choose
another path. A client that disconnects partway through a character ends
the text early and C<truncated> is true. A byte-order mark is consumed only
by plain C<UTF-16> and C<UTF-32>; with C<UTF-8> or an explicit byte order
(C<UTF-16LE>, ...) it arrives as U+FEFF, and C<s/\A\x{FEFF}//> on the first
chunk removes it (harmless when there is none).

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

The C<boundary> parameter is read from C<Content-Type> with normal quoted
parameter syntax. The underlying C<HTTP::MultiPartParser> accepts only
alphanumeric boundary characters and C<'()+_,-./:=?>; it rejects spaces even
when the C<Content-Type> value is correctly quoted.

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

Read raw body bytes. Cached after first read, and C<text>, C<json> and a
URL-encoded C<form_params> all read through it, so the exact bytes are still
here after they have parsed the body -- what a webhook signature check needs.
A multipart C<form_params> (or C<uploads>) streams its parts to disk instead
and keeps no raw copy; C<body> after it dies with C<The raw body of a
multipart request is not kept; read it with form_params and uploads>.

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
    my $text = await $req->text(strict => 1);   # invalid bytes are a 400

Read the body as text, decoded with the charset the client declared in
Content-Type (see L</charset>), or as UTF-8 when it declared none. A charset
L<Encode> does not know throws a L<PAGI::Exception::RequestBody> (415). With
C<< strict => 1 >>, bytes invalid in the charset throw one (400); without it
they become U+FFFD. See L</BAD REQUEST BODIES>.

=head2 json

    my $data = await $req->json;

Parse body as JSON. A body that is not JSON throws a
L<PAGI::Exception::RequestBody> (400); see L</BAD REQUEST BODIES>.

=head2 form_params

    my $form = await $req->form_params;  # Hash::MultiValue
    my $form = await $req->form_params(strict => 1);  # Invalid UTF-8 is a 400
    my $form = await $req->form_params(raw => 1);     # Skip UTF-8 decoding

Parse URL-encoded or multipart form data, returning a L<Hash::MultiValue>.
A field sent more than once keeps every value: C<get> returns the last,
C<get_all> all of them, in the order sent.
Multipart boundary parameters use the same quoted parameter parsing as
C<multipart_stream>, subject to the parser's boundary character restriction
described above. Part C<Content-Disposition> parameters handle quoted escapes,
including C<filename="a\"b.txt">. A quoted empty C<filename> is a file
upload. C<filename*> alone remains distinct from C<filename> and does not
make the part a file upload.

B<Options:>

=over 4

=item * C<strict> - If true, invalid UTF-8 sequences throw a
L<PAGI::Exception::RequestBody> (400). Default: false.

=item * C<raw> - If true, skip UTF-8 decoding entirely. Default: false.

=item * C<max_field_size>, C<max_file_size>, C<spool_threshold>, C<max_files>,
C<max_fields>, C<temp_dir> - Per-request limits for multipart parsing, passed
through to L<PAGI::Request::MultiPartHandler>. Each defaults to the matching
package variable in that module (e.g.
C<$PAGI::Request::MultiPartHandler::MAX_FILE_SIZE>); C<local>-ize those to
change a default process-wide. A body over C<max_field_size>,
C<max_file_size>, C<max_files> or C<max_fields> throws a
L<PAGI::Exception::RequestBody> with status 413; a malformed multipart body, 400.

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

=head1 BAD REQUEST BODIES

When the body itself is wrong -- not JSON, not valid in its charset under
C<strict>, text in a charset Perl does not know, a multipart body that cannot
be parsed or has no boundary, or a part over a configured limit -- the
buffered helpers (C<json>, C<text>, C<form_params>, C<uploads>) throw a
L<PAGI::Exception::RequestBody>. It carries C<status_code> (400, 413 for a limit,
or 415 for an unknown charset), C<reason>, a client-safe C<message>, and the
underlying C<cause>.

Most applications do nothing: every L<PAGI::Compose> application answers with
that status and the error's client message as plain text, and treats it as
handled rather than as a server error.

    my $data = await $request->json;    # bad JSON: the client gets a 400

A handler that wants its own response catches it:

    my $data;
    unless (eval { $data = await $request->json; 1 }) {
        my $error = $@;
        die $error unless ref $error && $error->isa('PAGI::Exception::RequestBody');
        return response('JSON', { error => 'Send a JSON object.' }, status => 400);
    }

An application that wants one style for every route gives ErrorHandler a
C<handler>; see L<PAGI::Tools::Cookbook/"Bad request bodies">.

=head1 PREDICATES

=head2 is_get, is_post, is_put, is_patch, is_delete, is_head, is_options

    if ($req->is_post) { ... }

Check HTTP method.

=head2 is_json

True if Content-Type is C<application/json> or any C<+json> type (the RFC 6839
structured-syntax suffix: C<application/vnd.api+json>,
C<application/problem+json>, ...).

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

A response chosen this way depends on the request's Accept header, so every
answer the handler gives from it -- the 406 and the no-Accept default
included -- should carry C<Vary: Accept>, and the handler writes it. To have
it written for you, along with the 406, put
L<PAGI::Middleware::ContentNegotiation> on the route and answer with
L<PAGI::ContentNegotiation/respond_to>.

=head1 CONNECTION STATE METHODS

C<is_disconnected> and the inherited L<PAGI::HTTPConnection/connection> look
up the connection without reading from the receive queue.

=head2 is_disconnected

    if ($req->is_disconnected) {
        # Client has disconnected
    }

Returns C<1> when the provided connection reports disconnected, C<0> when it
reports connected, and C<undef> when no C<pagi.connection> is available.

For advanced lifecycle, disconnect-reason, callback, or Future operations,
obtain the server-provided object with L<PAGI::HTTPConnection/connection> and use its explicit
interface directly. Outbound transport is separate from connection lifecycle.
Use the L<PAGI::Transport> factory for its optional flow-control facade:

    use PAGI::Transport qw(transport);
    my $flow = transport($req);

Raw PAGI applications may likewise call C<transport($scope)>. Reach through
C<< $req->scope->{'pagi.transport'} >> only as an explicit jailbreak when an
integration truly requires the server's raw transport handle.

=head1 AUTH HELPERS

=head2 bearer_token

    my $token = $req->bearer_token(raise_on_error => 1);

Returns an RFC 6750 Bearer token only when exactly one Authorization field is
present. Missing fields and another identifiable scheme return C<undef>.
Malformed Bearer credentials, including the former permissive whitespace and
partial-token forms, and duplicate fields, return C<undef> by default; with
C<raise_on_error =E<gt> 1> they throw a L<PAGI::Exception::HTTP> 400, C<The
Authorization header could not be parsed.> Unknown options are errors (a
croak, not a 400).

=head2 basic_auth

    my ($user, $pass) = $req->basic_auth(raise_on_error => 1);

Returns Basic C<(username, password)> bytes in list context only when exactly
one Authorization field contains a valid conventional padded Base64 credential.
It splits at the first colon and does not decode character encodings or verify
credentials. Missing, another scheme, duplicates, and malformed input return
C<(undef, undef)> by default; with C<raise_on_error =E<gt> 1> duplicates and
malformed Basic credentials throw a L<PAGI::Exception::HTTP> 400, C<The
Authorization header could not be parsed.> Unknown options are errors (a
croak, not a 400).

The 400 is the client's error, not the application's: a Compose application
answers it by itself, at a route or in an authentication backend (see
L<PAGI::Middleware::Authentication>), and does not log it. Its message never
carries the credential. The L<PAGI::Headers> readers these call raise plain
errors instead, since they parse any header list, not only a request's.

=head2 Constructing responses

Request owns HTTP input and remains the scope source for request-local helpers;
it does not manufacture or cache a Response. Construct the desired concrete
L<PAGI::Response> value directly and return it from a normal handler:

    use PAGI::Response qw(response);

    sub create_item {
        my ($request) = @_;
        return response('JSON', { created => \1 }, status => 201);
    }

Only a native application owns response emission. Invoke the application value
against the complete native triplet:

    use PAGI::Utils qw(invoke_app);
    await invoke_app($response, $scope, $receive, $send);

=head2 Per-Request Shared State

See L<PAGI::Stash> for per-request shared state between middleware
and handlers; L<PAGI::Middleware::Stash>, stacked above them, provides it.
Construct from a Request object or scope:

    use PAGI::Stash;
    my $stash = PAGI::Stash->new($req);
    $stash->set(user => $current_user);

B<How the stash differs from application state> (C<< $req->state >>, see
L<PAGI::HTTPConnection/state>):

=over 4

=item * C<state> is read-only, written (or declared) during lifespan startup

=item * C<state> values are shared across all requests in a worker, except a
C<per_request> value, built on its first C<get> in a request and shared by
every view of that request (L<PAGI::State/LIFETIMES>)

=item * L<PAGI::Stash> is per-request, written by middleware and handlers and
read below them

=back

=head1 SUBCLASSING

A framework may subclass PAGI::Request (Thunderhorse does, with Moo's
C<extends>). The contract:

=over 4

=item * B<State.> The object is a blessed hash. PAGI-Tools uses the fields
C<scope> and C<receive> (C<undef> in a Request built without one) and fields
whose names start with C<_>. A subclass adds fields under any other name.

=item * B<What is parsed is kept on the object.> A Request keeps the
headers, query, cookies, body, form and uploads it parses, and the latches
that record the body was read or streamed, on itself; it only reads the
scope and writes nothing to it. Two Request objects over one scope each
parse for themselves, and since the body arrives through C<$receive> once, a
second object cannot read a body the first one read: pass the one Request on,
as L<PAGI::Endpoint> passes its builder's Request to the handler.

=item * B<Overridable methods.> Public methods may be overridden; the ones
other methods call are:

    Method        Also read by
    ------------  ----------------------------------------------------------
    path_params   path_param (and its strict mode)
    query_params  query_param, raw_query_param, raw_query_params
    headers       header, header_all, content_type, charset, content_length,
                  basic_auth, bearer_token, multipart_stream
    header_all    cookies, accepts, preferred_type
    content_type  is_json, is_form, is_multipart
    cookies       cookie
    body          text, json, form_params
    form_params   form_param, raw_form_param, raw_form_params
    uploads       upload, upload_all

C<path_params> is the seam for a framework with its own router. Methods
whose names start with C<_> are not part of the contract.

=item * B<How the class is chosen.> PAGI-Tools builds the class named by
C<pagi.request.factory> in the scope, set by
L<PAGI::Middleware::RequestClass> for an application, or by
L<PAGI::Routing/request_response>'s C<request_factory> for one handler.

=item * B<Re-dispatch through one scope.> A framework whose router passes
one request through several matches writes each match's parameters into
the scope in place (C<< $scope->{path_params} = {...} >>, merged or replaced
as its routing means), relies on the stock C<path_params>, which reads the
scope live, and builds a new Request only when the scope is new. It does not
cache path parameters on the object or write the fields above, and it does
not make a shallow copy of the scope per match: a value written into one
copy is not in the others (L<PAGI::Building>, "The footgun: scalars do not
propagate").

When something hands a route a copy of the scope (a per-route middleware
that rewrites it, say), the copy is a new scope and needs a new Request,
since a Request reads headers and the query from the scope it was built
over. A framework that keeps one Request in its context compares
C<< $scope != $ctx->request->scope >> and rebuilds it when they differ. The
rebuilt Request cannot read a body the old one already read -- the body
arrived once, and the old Request holds it -- so read the body only where
the scope is final: in the handler.

This is how Starlette works: its C<Request.path_params> reads
C<scope["path_params"]>, and each route match updates the scope in place.

=item * B<Errors name the user's line.> A framework that calls Request on its
users' behalf marks its own packages for Carp, so a croak from here names
the user's line (L<PAGI::Response/ERRORS FROM A FRAMEWORK>).

=back

=head1 SEE ALSO

L<PAGI::Stash>, L<PAGI::Request::Upload>, L<PAGI::Request::BodyStream>, L<Hash::MultiValue>

=cut
