package PAGI::Response;

use strict;
use warnings;

use Future::AsyncAwait;
use Carp qw(croak);
use Encode qw(encode FB_CROAK);
use JSON::MaybeXS ();


=encoding UTF-8

=head1 NAME

PAGI::Response - Fluent response builder for PAGI applications

=head1 SYNOPSIS

    use PAGI::Response;
    use Future::AsyncAwait;

    # Body methods set the body and return $self for further chaining.
    # Sending is done via respond($send) or the endpoint return contract.

    # Class-method factory
    my $res = PAGI::Response->json({ message => 'Hello' });
    await $res->respond($send);

    # Instance method — chain freely
    my $res = PAGI::Response->new
        ->status(200)
        ->header('X-Custom' => 'value')
        ->json({ message => 'Hello' });
    await $res->respond($send);

    # Various body types
    PAGI::Response->text("Hello World");
    PAGI::Response->html("<h1>Hello</h1>");
    PAGI::Response->json({ data => 'value' });
    PAGI::Response->redirect('/login');

    # Streaming large responses
    PAGI::Response->stream(async sub {
        my ($writer) = @_;
        await $writer->write("chunk1");
        await $writer->write("chunk2");
        await $writer->close();
    });

    # File downloads
    PAGI::Response->new->send_file('/path/to/file.pdf', filename => 'doc.pdf');

=head1 DESCRIPTION

PAGI::Response provides a fluent interface for building HTTP responses in
PAGI applications. It is a detached value object: it holds status, headers,
and body but has no connection. Sending is done via L</respond> or L</to_app>.

B<Chainable methods> (C<status>, C<header>, C<content_type>, C<cookie>)
return C<$self> for fluent chaining.

B<Body methods> (C<text>, C<html>, C<json>, C<redirect>, etc.) set the
response body and also return C<$self>. They can be called as class-method
factories (C<< PAGI::Response->json($data) >>) or as instance methods
(C<< $res->json($data) >>).

=head1 CONSTRUCTOR

=head2 new

    my $res = PAGI::Response->new;
    my $res = PAGI::Response->new($scope);

Creates a detached response value. The response holds no connection and no
C<$send> callback — it is a pure value object that accumulates status,
headers, and body via the chainer methods.

=over 4

=item C<$scope> - Optional. A PAGI scope hashref. When provided it is stored
inert (for accessors like C<scope()> and helpers like L<PAGI::Stash>).
It is B<not> used as a connection — no C<$send> is stored here.

=back

To actually send the response, call L</respond> with the C<$send> callback,
or mount it as a PAGI app via L</to_app>.

Because the constructor stores no connection, the same response value can be
served to multiple connections (re-entrantly) by calling C<respond> more than
once.

=head1 CHAINABLE METHODS

These methods return C<$self> for fluent chaining.

=head2 status

    $res->status(404);
    my $code = $res->status;

Set or get the HTTP status code (100-599). Returns C<$self> when setting
for fluent chaining. When getting, returns 200 if no status has been set.

    my $res = PAGI::Response->new($scope, $send);
    $res->status;           # 200 (default, nothing set yet)
    $res->has_status;       # false
    $res->status(201);      # set explicitly
    $res->has_status;       # true

=head2 status_try

    $res->status_try(404);

Set the HTTP status code only if one hasn't been set yet. Useful in
middleware or error handlers to provide fallback status codes without
overriding choices made by the application:

    $res->status_try(202);  # sets to 202 (nothing was set)
    $res->status_try(500);  # no-op, 202 already set

=head2 header

    $res->header('X-Custom' => 'value');
    my $value = $res->header('X-Custom');

Add a response header. Can be called multiple times to add multiple headers.
If called with only a name, returns the last value for that header or C<undef>.

=head2 headers

    my $headers = $res->headers;

Returns the full header arrayref C<[ name, value ]> in order.

=head2 header_all

    my @values = $res->header_all('Set-Cookie');

Returns all values for the given header name (case-insensitive).

=head2 header_try

    $res->header_try('X-Custom' => 'value');

Add a response header only if that header name has not already been set.

=head2 content_type

    $res->content_type('text/html; charset=utf-8');
    my $type = $res->content_type;

Set the Content-Type header, replacing any existing one.

=head2 content_type_try

    $res->content_type_try('text/html; charset=utf-8');

Set the Content-Type header only if it has not already been set.

=head2 cookie

    $res->cookie('session' => 'abc123',
        max_age  => 3600,
        path     => '/',
        domain   => 'example.com',
        secure   => 1,
        httponly => 1,
        samesite => 'Strict',
    );

Set a response cookie. Options: max_age, expires, path, domain, secure,
httponly, samesite.

=head2 delete_cookie

    $res->delete_cookie('session');

Delete a cookie by setting it with Max-Age=0.

=head2 scope

    my $scope = $res->scope;

Returns the raw PAGI scope hashref. Useful for constructing helper
objects like L<PAGI::Stash> and L<PAGI::Session>:

    my $stash = PAGI::Stash->new($res);

=head2 Per-Request Shared State

See L<PAGI::Stash> for per-request shared state. Construct from a
Response object or from the shared scope:

    use PAGI::Stash;
    my $stash = PAGI::Stash->new($res);

=head2 is_sent

    if ($res->is_sent) {
        warn "Response already sent, cannot send error";
        return;
    }

Returns true if the response has already been finalized (sent to the client).
Useful in error handlers or middleware that need to check whether they can
still send a response.

=head2 has_status

    if ($res->has_status) { ... }

Returns true if a status code has been explicitly set via C<status> or
C<status_try>.

=head2 has_header

    if ($res->has_header('content-type')) { ... }

Returns true if the given header name has been set via C<header> or
C<header_try>. Header names are case-insensitive.

=head2 has_content_type

    if ($res->has_content_type) { ... }

Returns true if Content-Type has been explicitly set via C<content_type>,
C<content_type_try>, or C<header>/C<header_try> with a Content-Type name.

=head2 cors

    # Allow all origins (simplest case)
    $res->cors->json({ data => 'value' });

    # Allow specific origin
    $res->cors(origin => 'https://example.com')->json($data);

    # Full configuration
    $res->cors(
        origin      => 'https://example.com',
        methods     => [qw(GET POST PUT DELETE)],
        headers     => [qw(Content-Type Authorization)],
        expose      => [qw(X-Request-Id X-RateLimit-Remaining)],
        credentials => 1,
        max_age     => 86400,
        preflight   => 0,
    )->json($data);

Add CORS (Cross-Origin Resource Sharing) headers to the response.
Returns C<$self> for chaining.

B<Options:>

=over 4

=item * C<origin> - Allowed origin. Default: C<'*'> (all origins).
Can be a specific origin like C<'https://example.com'> or C<'*'> for any.

=item * C<methods> - Arrayref of allowed HTTP methods for preflight.
Default: C<[qw(GET POST PUT DELETE PATCH OPTIONS)]>.

=item * C<headers> - Arrayref of allowed request headers for preflight.
Default: C<[qw(Content-Type Authorization X-Requested-With)]>.

=item * C<expose> - Arrayref of response headers to expose to the client.
By default, only simple headers (Cache-Control, Content-Language, etc.)
are accessible. Use this to expose custom headers.

=item * C<credentials> - Boolean. If true, sets
C<Access-Control-Allow-Credentials: true>, allowing cookies and
Authorization headers. Default: C<0>.

=item * C<max_age> - How long (in seconds) browsers should cache preflight
results. Default: C<86400> (24 hours).

=item * C<preflight> - Boolean. If true, includes preflight response headers
(Allow-Methods, Allow-Headers, Max-Age). Set this when handling OPTIONS
requests. Default: C<0>.

=item * C<request_origin> - The Origin header value from the request.
Required when C<credentials> is true and C<origin> is C<'*'>, because
the CORS spec forbids using C<'*'> with credentials. Pass the actual
request origin to echo it back.

=back

B<Important CORS Notes:>

=over 4

=item * When C<credentials> is true, you cannot use C<< origin => '*' >>.
Either specify an exact origin, or pass C<request_origin> with the
client's actual Origin header.

=item * The C<Vary: Origin> header is always set to ensure proper caching
when origin-specific responses are used.

=item * For preflight (OPTIONS) requests, set C<< preflight => 1 >> and
typically respond with C<< $res->status(204)->empty() >>.

=back

=head1 SEND PRIMITIVE AND APP MOUNTING

=head2 respond

    await $res->respond($send);

The single send primitive for a detached response value. Reads the
accumulated status, headers, and body from C<$self> and emits the
appropriate PAGI protocol events via C<$send>.

C<$send> must be a coderef (the PAGI send callback). C<respond> does
B<not> mutate the response object, so the same response value can be
passed to C<respond> multiple times for different connections.

For streaming responses (set up via the C<_stream> slot), C<respond>
sends the start event, runs the stream callback with a
L<PAGI::Response::Writer>, and ensures the writer is closed.

Returns a L<Future>.

=head2 to_app

    my $app = $res->to_app;

Returns a PAGI application coderef C<sub ($scope, $receive, $send)> that
calls L</respond> with the given C<$send> when invoked. Use this to mount
a response value directly as a PAGI app:

    my $not_found = PAGI::Response->new
        ->status(404)
        ->_set_body('Not Found', 'text/plain');

    # Mount as a fallback app
    my $app = $not_found->to_app;

=head1 BODY METHODS

These methods set the response body and return C<$self>. Sending happens via
L</respond> / L</to_app> or the endpoint return contract.

Each method works as both a B<class-method factory> and an B<instance method>:

    # Class-method factory — creates a new detached response and returns it
    return $ctx->response->json($data);          # instance method on existing $res
    return PAGI::Response->json($data);          # factory shorthand

    # Chain body with other setters before sending
    PAGI::Response->json($data)->status(201)->respond($send)->get;

=head2 text

    $res->text("Hello World");
    PAGI::Response->text("Hello World");

Set body to the UTF-8–encoded string with Content-Type: text/plain; charset=utf-8.
Returns C<$self>.

=head2 html

    $res->html("<h1>Hello</h1>");
    PAGI::Response->html("<h1>Hello</h1>");

Set body to the UTF-8–encoded string with Content-Type: text/html; charset=utf-8.
Returns C<$self>.

=head2 json

    $res->json({ message => 'Hello' });
    PAGI::Response->json({ message => 'Hello' });

Set body to the JSON-encoded data with Content-Type: application/json; charset=utf-8.
Returns C<$self>.

=head2 redirect

    $res->redirect('/login');
    $res->redirect('/new-url', 301);
    PAGI::Response->redirect('/login');

Set an empty body and a Location header. Default status is 302. Returns C<$self>.

B<Why no body?> While RFC 7231 suggests including a short HTML body with a
hyperlink for clients that don't auto-follow redirects, all modern browsers
and HTTP clients ignore redirect bodies. If you need a body for legacy
compatibility, set it explicitly after calling C<redirect>.

=head2 empty

    $res->empty;
    PAGI::Response->new->empty;

Set an empty body with status 204 No Content (or keep a previously set status).
Returns C<$self>.

=head2 send

    $res->send($text);
    $res->send($text, charset => 'iso-8859-1');

Set body to the encoded text (UTF-8 by default, or the specified charset).
Adds charset to Content-Type if not present. Returns C<$self>.

=head2 send_raw

    $res->send_raw($bytes);

Set body to raw bytes without any encoding. Use for binary data or pre-encoded
content. Returns C<$self>.

=head2 stream

    $res->stream(async sub {
        my ($writer) = @_;
        await $writer->write("chunk1");
        await $writer->write("chunk2");
        await $writer->close();
    });
    PAGI::Response->stream($callback);

Store a streaming callback. When the response is sent via L</respond>, the callback
receives a L<PAGI::Response::Writer> and streams chunks. Returns C<$self>.

=head2 writer

    my $writer = await $res->writer;
    my $writer = await $res->writer(on_close => sub { cleanup() });
    my $writer = await $res->writer(on_close => async sub { await cleanup() });

Returns a L<PAGI::Response::Writer> directly, sending headers immediately.
Unlike C<stream()>, the writer is not scoped to a callback — you own it
and must call C<close()> when done.

This is useful when the writer needs to be passed to event handlers,
pub/sub callbacks, timers, or other contexts outside a single function:

    async sub live_feed {
        my ($self, $ctx) = @_;
        my $writer = await $ctx->response
            ->content_type('text/plain')
            ->writer(on_close => sub { $bus->unsubscribe($id) });

        my $id = $bus->subscribe(async sub ($line) {
            await $writer->write("$line\n");
        });

        await $ctx->receive;    # wait for disconnect
        await $writer->close;
    }

The optional C<on_close> callback is registered before headers are sent,
eliminating any race window with fast client disconnects. Sync and async
callbacks are both supported — see L</on_close> under L</WRITER OBJECT>.

=head2 send_file

    $res->send_file('/path/to/file.pdf');
    $res->send_file('/path/to/file.pdf',
        filename => 'download.pdf',
        inline   => 1,
    );
    PAGI::Response->send_file('/path/to/file.pdf');

    # Partial file (for range requests)
    $res->send_file('/path/to/video.mp4',
        offset => 1024,       # Start from byte 1024
        length => 65536,      # Send 64KB
    );

Set the response to serve a file. Stats the file and sets Content-Type,
Content-Length, and Content-Disposition at call time. The PAGI protocol's
C<file> key is used for efficient server-side streaming (file not read into
memory) when L</respond> is called. Returns C<$self>.

For production, use L<PAGI::Middleware::XSendfile> to delegate file serving
to your reverse proxy.

B<Options:>

=over 4

=item * C<filename> - Set Content-Disposition attachment filename

=item * C<inline> - Use Content-Disposition: inline instead of attachment

=item * C<offset> - Start position in bytes (default: 0). For range requests.

=item * C<length> - Number of bytes to send. Defaults to file size minus offset.

=back

B<Range Request Example:>

    # Manual range request handling
    async sub handle_video {
        my ($req, $send) = @_;
        my $path = '/videos/movie.mp4';
        my $size = -s $path;

        my $range = $req->header('Range');
        if ($range && $range =~ /bytes=(\d+)-(\d*)/) {
            my $start = $1;
            my $end = $2 || ($size - 1);
            my $length = $end - $start + 1;

            return PAGI::Response->new
                ->status(206)
                ->header('Content-Range' => "bytes $start-$end/$size")
                ->header('Accept-Ranges' => 'bytes')
                ->send_file($path, offset => $start, length => $length);
        }

        return PAGI::Response->new
            ->header('Accept-Ranges' => 'bytes')
            ->send_file($path);
    }

B<Note:> For production file serving with full features (ETag caching,
automatic range request handling, conditional GETs, directory indexes),
use L<PAGI::App::File> instead:

    use PAGI::App::File;
    my $files = PAGI::App::File->new(root => '/var/www/static');
    my $app = $files->to_app;

=head1 EXAMPLES

=head2 Complete Raw PAGI Application

    use Future::AsyncAwait;
    use PAGI::Request;
    use PAGI::Response;

    my $app = async sub ($scope, $receive, $send) {
        return await handle_lifespan($scope, $receive, $send)
            if $scope->{type} eq 'lifespan';

        my $req = PAGI::Request->new($scope, $receive);
        my $res = PAGI::Response->new($scope, $send);

        if ($req->method eq 'GET' && $req->path eq '/') {
            return await $res->html('<h1>Welcome</h1>');
        }

        if ($req->method eq 'POST' && $req->path eq '/api/users') {
            my $data = await $req->json;
            # ... create user ...
            return await $res->status(201)
                             ->header('Location' => '/api/users/123')
                             ->json({ id => 123, name => $data->{name} });
        }

        return await $res->status(404)->json({ error => 'Not Found' });
    };

=head2 Form Validation with Error Response

    async sub handle_contact ($req, $send) {
        my $res = PAGI::Response->new($scope, $send);
        my $form = await $req->form_params;

        my @errors;
        my $email = $form->get('email') // '';
        my $message = $form->get('message') // '';

        push @errors, 'Email required' unless $email;
        push @errors, 'Invalid email' unless $email =~ /@/;
        push @errors, 'Message required' unless $message;

        if (@errors) {
            return await $res->status(422)
                             ->json({ error => 'Validation failed', errors => \@errors });
        }

        # Process valid form...
        return await $res->json({ success => 1 });
    }

=head2 Authentication with Cookies

    async sub handle_login ($req, $send) {
        my $res = PAGI::Response->new($scope, $send);
        my $data = await $req->json;

        my $user = authenticate($data->{email}, $data->{password});

        unless ($user) {
            return await $res->status(401)->json({ error => 'Invalid credentials' });
        }

        my $session_id = create_session($user);

        return await $res->cookie('session' => $session_id,
                path     => '/',
                httponly => 1,
                secure   => 1,
                samesite => 'Strict',
                max_age  => 86400,  # 24 hours
            )
            ->json({ user => { id => $user->{id}, name => $user->{name} } });
    }

    async sub handle_logout ($req, $send) {
        my $res = PAGI::Response->new($scope, $send);

        return await $res->delete_cookie('session', path => '/')
                         ->json({ logged_out => 1 });
    }

=head2 File Download

    async sub handle_download ($req, $send) {
        my $res = PAGI::Response->new($scope, $send);
        my $file_id = $req->path_param('id');

        my $file = get_file($file_id); # Be sure to clean $file
        unless ($file && -f $file->{path}) {
            return await $res->status(404)->json({ error => 'File not found' });
        }

        return await $res->send_file($file->{path},
            filename => $file->{original_name},
        );
    }

=head2 Streaming Large Data

    async sub handle_export ($req, $send) {
        my $res = PAGI::Response->new($scope, $send);

        await $res->content_type('text/csv')
                  ->header('Content-Disposition' => 'attachment; filename="export.csv"')
                  ->stream(async sub ($writer) {
                      # Write CSV header
                      await $writer->write("id,name,email\n");

                      # Stream rows from database
                      my $cursor = get_all_users_cursor();
                      while (my $user = $cursor->next) {
                          await $writer->write("$user->{id},$user->{name},$user->{email}\n");
                      }
                  });
    }

=head2 Server-Sent Events Style Streaming

    async sub handle_events ($req, $send) {
        my $res = PAGI::Response->new($scope, $send);

        await $res->content_type('text/event-stream')
                  ->header('Cache-Control' => 'no-cache')
                  ->stream(async sub ($writer) {
                      for my $i (1..10) {
                          await $writer->write("data: Event $i\n\n");
                          await some_delay(1);  # Wait 1 second
                      }
                  });
    }

=head2 Conditional Responses

    async sub handle_resource ($req, $send) {
        my $res = PAGI::Response->new($scope, $send);
        my $etag = '"abc123"';

        # Check If-None-Match for caching
        my $if_none_match = $req->header('If-None-Match') // '';
        if ($if_none_match eq $etag) {
            return await $res->status(304)->empty();
        }

        return await $res->header('ETag' => $etag)
                         ->header('Cache-Control' => 'max-age=3600')
                         ->json({ data => 'expensive computation result' });
    }

=head2 CORS API Endpoint

    # Simple CORS - allow all origins
    async sub handle_api ($scope, $receive, $send) {
        my $res = PAGI::Response->new($scope, $send);

        return await $res->cors->json({ status => 'ok' });
    }

    # CORS with credentials (e.g., cookies, auth headers)
    async sub handle_api_with_auth ($scope, $receive, $send) {
        my $req = PAGI::Request->new($scope, $receive);
        my $res = PAGI::Response->new($scope, $send);

        # Get the Origin header from request
        my $origin = $req->header('Origin');

        return await $res->cors(
            origin         => 'https://myapp.com',  # Or use request_origin
            credentials    => 1,
            expose         => [qw(X-Request-Id)],
        )->json({ user => 'authenticated' });
    }

=head2 CORS Preflight Handler

    # Handle OPTIONS preflight requests
    async sub app ($scope, $receive, $send) {
        my $req = PAGI::Request->new($scope, $receive);
        my $res = PAGI::Response->new($scope, $send);

        # Handle preflight
        if ($req->method eq 'OPTIONS') {
            return await $res->cors(
                origin      => 'https://myapp.com',
                methods     => [qw(GET POST PUT DELETE)],
                headers     => [qw(Content-Type Authorization X-Custom-Header)],
                credentials => 1,
                max_age     => 86400,
                preflight   => 1,  # Include preflight headers
            )->status(204)->empty();
        }

        # Handle actual request
        return await $res->cors(
            origin      => 'https://myapp.com',
            credentials => 1,
        )->json({ data => 'response' });
    }

=head2 Dynamic CORS Origin

    # Allow multiple origins dynamically
    my %ALLOWED_ORIGINS = map { $_ => 1 } qw(
        https://app1.example.com
        https://app2.example.com
        https://localhost:3000
    );

    async sub handle_api ($scope, $receive, $send) {
        my $req = PAGI::Request->new($scope, $receive);
        my $res = PAGI::Response->new($scope, $send);

        my $request_origin = $req->header('Origin') // '';

        # Check if origin is allowed
        if ($ALLOWED_ORIGINS{$request_origin}) {
            return await $res->cors(
                origin      => $request_origin,  # Echo back the allowed origin
                credentials => 1,
            )->json({ data => 'allowed' });
        }

        # Origin not allowed - respond without CORS headers
        return await $res->status(403)->json({ error => 'Origin not allowed' });
    }

=head1 WRITER OBJECT

The C<stream()> method passes a writer object to its callback, and
C<writer()> returns one directly. The writer has the following methods:

=head3 write

    await $writer->write($chunk);

Write a chunk of data to the response stream. Returns a L<Future>.

Writing after close returns a failed L<Future> rather than throwing.
This allows cleanup code that races with close to handle the error
gracefully via C<await>.

=head3 close

    await $writer->close;

Close the stream. Returns a L<Future>. Calling close multiple times is
safe — subsequent calls are no-ops.

=head3 bytes_written

    my $n = $writer->bytes_written;

Returns the total number of bytes written so far.

=head3 on_close

    # Sync callback
    $writer->on_close(sub { cleanup() });

    # Async callback — return value is awaited automatically
    $writer->on_close(async sub {
        await notify_stream_ended();
    });

    # Chaining
    $writer->on_close(sub { ... })
           ->on_close(sub { ... });

Registers a callback to fire when the writer closes (either explicitly
or via C<stream()> auto-close). Callbacks can be regular subs or async
subs — async results are automatically awaited. Multiple callbacks run
in registration order. Exceptions are caught and warned but do not
prevent other callbacks from running. Returns C<$self> for chaining.

B<Circular reference note:> If your callback captures the writer
object in a closure, use C<Scalar::Util::weaken> to avoid a memory leak:

    use Scalar::Util qw(weaken);
    my $weak_writer = $writer;
    weaken($weak_writer);
    $writer->on_close(sub { $weak_writer->... if $weak_writer });

The callback array is cleared after firing, so any cycle via a closure
is broken when the writer closes, but C<weaken> prevents the object
from being kept alive until that point.

=head3 is_closed

    if ($writer->is_closed) { ... }

Returns true if the writer has been closed.

The writer automatically closes when the C<stream()> callback completes,
but calling C<close()> explicitly is recommended for clarity.

=head1 ERROR HANDLING

Body methods (C<text>, C<json>, etc.) encode synchronously and croak on
invalid input (e.g., unencodable characters with C<FB_CROAK>). Errors surface
at call time, not at send time. Errors during L</respond> (e.g., a broken
connection) will cause the returned Future to fail.

    use Syntax::Keyword::Try;

    try {
        my $res = $ctx->response->json($data);
        await $res->respond($send);
    }
    catch ($e) {
        warn "Response error: $e";
    }

=head1 SEE ALSO

L<PAGI>, L<PAGI::Request>, L<PAGI::Server>

=head1 AUTHOR

PAGI Contributors

=cut

sub new {
    my ($class, $scope) = @_;
    croak("scope must be a hashref") if defined $scope && ref($scope) ne 'HASH';
    return bless {
        scope       => $scope,           # optional, inert (accessors / Stash); NOT a connection
        _headers    => [],
        _header_set => {},
    }, $class;
}

sub status {
    my ($self, $code) = @_;
    return $self->{_status} // 200 if @_ == 1;  # lazy default
    croak("Status must be a number between 100-599")
        unless $code =~ /^\d+$/ && $code >= 100 && $code <= 599;
    $self->{_status} = $code;
    return $self;
}

sub status_try {
    my ($self, $code) = @_;
    return $self if exists $self->{_status};
    return $self->status($code);
}

sub header {
    my ($self, $name, $value) = @_;
    croak("Header name is required") unless defined $name;
    if (@_ == 2) {
        my $key = lc($name);
        for (my $i = $#{$self->{_headers}}; $i >= 0; $i--) {
            my $pair = $self->{_headers}[$i];
            return $pair->[1] if lc($pair->[0]) eq $key;
        }
        return undef;
    }
    push @{$self->{_headers}}, [$name, $value];
    my $key = lc($name // '');
    $self->{_header_set}{$key} = 1 if length $key;
    if ($key eq 'content-type') {
        $self->{_content_type} = $value;
    }
    return $self;
}

sub headers {
    my ($self) = @_;
    return $self->{_headers};
}

sub header_all {
    my ($self, $name) = @_;
    croak("Header name is required") unless defined $name;
    my $key = lc($name);
    my @values;
    for my $pair (@{$self->{_headers}}) {
        push @values, $pair->[1] if lc($pair->[0]) eq $key;
    }
    return @values;
}

sub header_try {
    my ($self, $name, $value) = @_;
    return $self if $self->has_header($name);
    return $self->header($name, $value);
}

sub content_type {
    my ($self, $type) = @_;
    return $self->{_content_type} if @_ == 1;
    # Remove existing content-type headers
    $self->{_headers} = [grep { lc($_->[0]) ne 'content-type' } @{$self->{_headers}}];
    push @{$self->{_headers}}, ['content-type', $type];
    $self->{_header_set}{'content-type'} = 1;
    $self->{_content_type} = $type;
    return $self;
}

sub content_type_try {
    my ($self, $type) = @_;
    return $self if exists $self->{_content_type};
    return $self->content_type($type);
}

sub has_status {
    my ($self) = @_;
    return exists $self->{_status} ? 1 : 0;
}

sub has_header {
    my ($self, $name) = @_;
    my $key = lc($name // '');
    return 0 unless length $key;
    return $self->{_header_set}{$key} ? 1 : 0;
}

sub has_content_type {
    my ($self) = @_;
    return exists $self->{_content_type} ? 1 : 0;
}

sub scope { shift->{scope} }

sub _set_body {
    my ($self, $bytes, $default_type) = @_;
    $self->{_body} = $bytes;
    $self->content_type_try($default_type) if defined $default_type;
    return $self;
}

sub _render_headers {
    my ($self, $extra_len) = @_;
    my @headers = map { [$_->[0], $_->[1]] } @{$self->{_headers}};
    push @headers, ['content-length', $extra_len] if defined $extra_len;
    return \@headers;
}

async sub respond {
    my ($self, $send) = @_;
    croak("send must be a coderef") unless ref($send) eq 'CODE';

    if ($self->{_stream}) {
        await $send->({
            type    => 'http.response.start',
            status  => $self->status,
            headers => $self->_render_headers(undef),
        });
        my $writer = PAGI::Response::Writer->new($send);
        await $self->{_stream}->($writer);
        await $writer->close() unless $writer->is_closed;
        return;
    }

    if ($self->{_file}) {
        my $fd = $self->{_file};
        # Headers (incl. content-length) were set at send_file() build time.
        await $send->({
            type    => 'http.response.start',
            status  => $self->status,
            headers => $self->_render_headers(undef),
        });
        my $body_event = {
            type => 'http.response.body',
            file => $fd->{path},
        };
        $body_event->{offset} = $fd->{offset} if exists $fd->{offset};
        $body_event->{length} = $fd->{length} if exists $fd->{length};
        await $send->($body_event);
        return;
    }

    my $body = $self->{_body} // '';
    await $send->({
        type    => 'http.response.start',
        status  => $self->status,
        headers => $self->_render_headers(length $body),
    });
    await $send->({ type => 'http.response.body', body => $body, more => 0 });
    return;
}

sub to_app {
    my ($self) = @_;
    return async sub {
        my ($scope, $receive, $send) = @_;
        await $self->respond($send);
    };
}


sub is_sent {
    my ($self) = @_;
    return $self->{scope}{'pagi.response.sent'} ? 1 : 0;
}

sub _mark_sent {
    my ($self) = @_;
    croak("Response already sent") if $self->{scope}{'pagi.response.sent'};
    $self->{scope}{'pagi.response.sent'} = 1;
}

# Returns the invocant if it is already an instance; otherwise creates a new
# detached instance from the class name. Allows finisher methods to be called
# as either class-method factories or instance methods.
sub _self_or_new {
    my ($proto) = @_;
    return ref($proto) ? $proto : $proto->new;
}

# Encode a text string to UTF-8 bytes, croaking on invalid characters.
# Replicates the encoding used by the old send() method.
sub _enc {
    my ($str, $charset) = @_;
    $charset //= 'utf-8';
    return encode($charset, $str // '', FB_CROAK);
}

sub send_raw {
    my ($proto, $body) = @_;
    my $self = $proto->_self_or_new;
    $self->_set_body($body // '', undef);
    return $self;
}

sub send {
    my ($proto, $body, %opts) = @_;
    my $self   = $proto->_self_or_new;
    my $charset = $opts{charset} // 'utf-8';
    my $encoded = _enc($body, $charset);
    # Match old send() behaviour: set content-type with charset if not present,
    # or append charset to an existing content-type that lacks it.
    if ($self->has_content_type) {
        my $ct = $self->content_type;
        unless ($ct =~ /charset=/i) {
            $self->content_type("$ct; charset=$charset");
        }
    } else {
        $self->content_type("text/plain; charset=$charset");
    }
    $self->{_body} = $encoded;
    return $self;
}

sub text {
    my ($proto, $body) = @_;
    my $self = $proto->_self_or_new;
    $self->_set_body(_enc($body), 'text/plain; charset=utf-8');
    return $self;
}

sub html {
    my ($proto, $body) = @_;
    my $self = $proto->_self_or_new;
    $self->_set_body(_enc($body), 'text/html; charset=utf-8');
    return $self;
}

sub json {
    my ($proto, $data) = @_;
    my $self = $proto->_self_or_new;
    my $body = JSON::MaybeXS->new(utf8 => 1, canonical => 1)->encode($data);
    $self->_set_body($body, 'application/json; charset=utf-8');
    return $self;
}

sub redirect {
    my ($proto, $url, $status) = @_;
    my $self = $proto->_self_or_new;
    $self->status($status // 302)->header('location', $url);
    $self->_set_body('', undef);
    return $self;
}

sub empty {
    my ($proto) = @_;
    my $self = $proto->_self_or_new;
    $self->status_try(204);
    $self->_set_body('', undef);
    return $self;
}

sub cookie {
    my ($self, $name, $value, %opts) = @_;
    my @parts = ("$name=$value");

    push @parts, "Max-Age=$opts{max_age}" if defined $opts{max_age};
    push @parts, "Expires=$opts{expires}" if defined $opts{expires};
    push @parts, "Path=$opts{path}" if defined $opts{path};
    push @parts, "Domain=$opts{domain}" if defined $opts{domain};
    push @parts, "Secure" if $opts{secure};
    push @parts, "HttpOnly" if $opts{httponly};
    push @parts, "SameSite=$opts{samesite}" if defined $opts{samesite};

    my $cookie_str = join('; ', @parts);
    push @{$self->{_headers}}, ['set-cookie', $cookie_str];

    return $self;
}

sub delete_cookie {
    my ($self, $name, %opts) = @_;
    return $self->cookie($name, '',
        max_age => 0,
        path    => $opts{path},
        domain  => $opts{domain},
    );
}

sub cors {
    my ($self, %opts) = @_;
    my $origin      = $opts{origin} // '*';
    my $credentials = $opts{credentials} // 0;
    my $methods     = $opts{methods} // [qw(GET POST PUT DELETE PATCH OPTIONS)];
    my $headers     = $opts{headers} // [qw(Content-Type Authorization X-Requested-With)];
    my $expose      = $opts{expose} // [];
    my $max_age     = $opts{max_age} // 86400;
    my $preflight   = $opts{preflight} // 0;

    # Determine the origin to send back
    my $allow_origin;
    if ($origin eq '*' && $credentials) {
        # With credentials, can't use wildcard - use request_origin if provided
        $allow_origin = $opts{request_origin} // '*';
    } else {
        $allow_origin = $origin;
    }

    # Core CORS headers (always set)
    $self->header('Access-Control-Allow-Origin', $allow_origin);
    $self->header('Vary', 'Origin');

    if ($credentials) {
        $self->header('Access-Control-Allow-Credentials', 'true');
    }

    if (@$expose) {
        $self->header('Access-Control-Expose-Headers', join(', ', @$expose));
    }

    # Preflight headers (for OPTIONS responses or when explicitly requested)
    if ($preflight) {
        $self->header('Access-Control-Allow-Methods', join(', ', @$methods));
        $self->header('Access-Control-Allow-Headers', join(', ', @$headers));
        $self->header('Access-Control-Max-Age', $max_age);
    }

    return $self;
}

sub stream {
    my ($proto, $callback) = @_;
    my $self = $proto->_self_or_new;
    $self->{_stream} = $callback;
    return $self;
}

async sub writer {
    my ($self, %opts) = @_;
    $self->_mark_sent;

    # Send headers
    await $self->{send}->({
        type    => 'http.response.start',
        status  => $self->status,
        headers => $self->{_headers},
    });

    return PAGI::Response::Writer->new($self->{send}, %opts);
}

# Simple MIME type mapping
my %MIME_TYPES = (
    '.html' => 'text/html',
    '.htm'  => 'text/html',
    '.txt'  => 'text/plain',
    '.css'  => 'text/css',
    '.js'   => 'application/javascript',
    '.json' => 'application/json',
    '.xml'  => 'application/xml',
    '.pdf'  => 'application/pdf',
    '.zip'  => 'application/zip',
    '.png'  => 'image/png',
    '.jpg'  => 'image/jpeg',
    '.jpeg' => 'image/jpeg',
    '.gif'  => 'image/gif',
    '.svg'  => 'image/svg+xml',
    '.ico'  => 'image/x-icon',
    '.woff' => 'font/woff',
    '.woff2'=> 'font/woff2',
);

sub _mime_type {
    my ($path) = @_;
    my ($ext) = $path =~ /(\.[^.]+)$/;
    return $MIME_TYPES{lc($ext // '')} // 'application/octet-stream';
}

sub send_file {
    my ($proto, $path, %opts) = @_;
    my $self = $proto->_self_or_new;

    croak("File not found: $path") unless -f $path;
    croak("Cannot read file: $path") unless -r $path;

    # Get file size
    my $file_size = -s $path;

    # Handle offset and length for range requests
    my $offset = $opts{offset} // 0;
    my $length = $opts{length};

    # Validate offset
    croak("offset must be non-negative") if $offset < 0;
    croak("offset exceeds file size") if $offset > $file_size;

    # Calculate actual length to send
    my $max_length = $file_size - $offset;
    if (defined $length) {
        croak("length must be non-negative") if $length < 0;
        $length = $max_length if $length > $max_length;
    } else {
        $length = $max_length;
    }

    # Set content-type if not already set
    $self->content_type_try(_mime_type($path));

    # Set content-length based on actual bytes to send
    $self->header('content-length', $length);

    # Set content-disposition
    my $disposition;
    if ($opts{inline}) {
        $disposition = 'inline';
    } elsif ($opts{filename}) {
        # Sanitize filename for header
        my $safe_filename = $opts{filename};
        $safe_filename =~ s/["\r\n]//g;
        $disposition = "attachment; filename=\"$safe_filename\"";
    }
    $self->header('content-disposition', $disposition) if $disposition;

    # Store the file send descriptor; respond() handles the actual emission.
    # offset/length are stored only when they narrow the full-file default.
    my $file_desc = { path => $path };
    $file_desc->{offset} = $offset if $offset > 0;
    $file_desc->{length} = $length if $length < $max_length;
    $self->{_file} = $file_desc;

    return $self;
}

# Writer class for streaming responses
package PAGI::Response::Writer {
    use strict;
    use warnings;
    use Future::AsyncAwait;
    use Carp qw(croak);
    use Scalar::Util qw(blessed);

    sub new {
        my ($class, $send, %opts) = @_;
        my $self = bless {
            send          => $send,
            bytes_written => 0,
            closed        => 0,
            _on_close     => [],
        }, $class;
        push @{$self->{_on_close}}, $opts{on_close} if $opts{on_close};
        return $self;
    }

    async sub write {
        my ($self, $chunk) = @_;
        die 'Writer already closed' if $self->{closed};
        $self->{bytes_written} += length($chunk // '');
        await $self->{send}->({
            type => 'http.response.body',
            body => $chunk,
            more => 1,
        });
    }

    async sub close {
        my ($self) = @_;
        return if $self->{closed};
        $self->{closed} = 1;
        await $self->{send}->({
            type => 'http.response.body',
            body => '',
            more => 0,
        });
        for my $cb (@{$self->{_on_close}}) {
            eval {
                my $r = $cb->();
                if (blessed($r) && $r->isa('Future')) {
                    await $r;
                }
            };
            if ($@) {
                warn "PAGI::Response::Writer on_close callback error: $@";
            }
        }

        # Clear callback array to break any closure-based cycles
        $self->{_on_close} = [];
    }

    sub on_close {
        my ($self, $cb) = @_;
        push @{$self->{_on_close}}, $cb;
        return $self;
    }

    sub is_closed { $_[0]->{closed} }

    sub bytes_written { $_[0]->{bytes_written} }
}

1;
