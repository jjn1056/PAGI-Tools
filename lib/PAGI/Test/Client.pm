package PAGI::Test::Client;

use strict;
use warnings;
use Future::AsyncAwait;
use Carp qw(croak);

use PAGI::SendValidation;
use PAGI::Test::ConnectionState;
use PAGI::Test::Response;
use PAGI::Utils ();

# Extension sets this mock genuinely implements, one per scope type. Each is
# the single source of truth threaded into BOTH that scope's advertised
# `extensions` key AND the PAGI::SendValidation instance guarding that
# scope's sends -- never two independently-hardcoded lists that can drift.
# http/sse: empty. http.fullflush's real contract is "block until bytes are
# flushed to the transport" -- this mock has no transport to flush (everything
# is captured synchronously in-process), so there is nothing genuine to honor;
# advertising it would be decorative, not implemented (see LIMITATIONS).
# websocket: the extension denial path (websocket.http.response.*) IS
# concretely implemented -- PAGI::Test::WebSocket models its own denial/
# denial_complete states -- so it is genuinely advertised.
my %HTTP_EXTENSIONS      = ();
my %SSE_EXTENSIONS       = ();
my %WEBSOCKET_EXTENSIONS = ('websocket.http.response' => {});


sub new {
    my ($class, %args) = @_;

    croak "app is required" unless $args{app};

    return bless {
        app                  => PAGI::Utils::to_app($args{app}),
        headers              => $args{headers} // {},
        cookies              => {},
        lifespan             => $args{lifespan} // 0,
        raise_app_exceptions => $args{raise_app_exceptions} // 0,
        started              => 0,
    }, $class;
}

sub get     { shift->_request('GET', @_) }
sub head    { shift->_request('HEAD', @_) }
sub delete  { shift->_request('DELETE', @_) }
sub post    { shift->_request('POST', @_) }
sub put     { shift->_request('PUT', @_) }
sub patch   { shift->_request('PATCH', @_) }
sub options { shift->_request('OPTIONS', @_) }

# Cookie management
sub cookies {
    my ($self) = @_;
    return $self->{cookies};
}

sub cookie {
    my ($self, $name) = @_;
    return $self->{cookies}{$name};
}

sub set_cookie {
    my ($self, $name, $value) = @_;
    $self->{cookies}{$name} = $value;
    return $self;
}

sub clear_cookies {
    my ($self) = @_;
    $self->{cookies} = {};
    return $self;
}

sub _request {
    my ($self, $method, $path, %opts) = @_;

    $path //= '/';

    # Handle json option
    if (exists $opts{json}) {
        require JSON::MaybeXS;
        $opts{body} = JSON::MaybeXS::encode_json($opts{json});
        _set_header(\$opts{headers}, 'Content-Type', 'application/json', 0);
        _set_header(\$opts{headers}, 'Content-Length', length($opts{body}), 1);
    }
    # Handle form option (supports multi-value)
    elsif (exists $opts{form}) {
        my $pairs = _normalize_pairs($opts{form});
        my @encoded;
        for my $pair (@$pairs) {
            my $key = _url_encode($pair->[0]);
            my $val = _url_encode($pair->[1] // '');
            push @encoded, "$key=$val";
        }
        $opts{body} = join('&', @encoded);
        _set_header(\$opts{headers}, 'Content-Type', 'application/x-www-form-urlencoded', 0);
        _set_header(\$opts{headers}, 'Content-Length', length($opts{body}), 1);
    }
    # Add Content-Length for raw body if not already set
    elsif (defined $opts{body}) {
        _set_header(\$opts{headers}, 'Content-Length', length($opts{body}), 0);
    }

    # Build scope
    my $scope = $self->_build_scope($method, $path, \%opts);

    # Build receive (returns request body)
    my $body = $opts{body} // '';
    my $receive_called = 0;
    my $receive = async sub {
        if (!$receive_called) {
            $receive_called = 1;
            return { type => 'http.request', body => $body, more => 0 };
        }
        return { type => 'http.disconnect' };
    };

    # Build send (captures response). Strict: illegal events (per
    # PAGI::SendValidation's http rules) fail the returned Future -- a
    # canonical test client must not accept what a real server would reject
    # -- and are never appended to @events. extensions is the SAME hashref
    # advertised on the scope above (see %HTTP_EXTENSIONS) -- one source of
    # truth, not two lists that can drift.
    my $sv = PAGI::SendValidation->new(scope_type => 'http', extensions => $scope->{extensions});
    my @events;
    my $send = async sub {
        my ($event) = @_;

        if (my $err = $sv->check($event)) {
            die $err->message . "\n";
        }

        my %captured = %$event;

        if (my $conn = $scope->{'pagi.connection'}) {
            $conn->_mark_response_started
                if ($captured{type} // '') eq 'http.response.start';
        }

        if (($captured{type} // '') eq 'http.response.start') {
            # PAGI spec — this mock is H1-flavored (see http_version above):
            # strip app-supplied transfer-encoding/connection (the mock owns
            # response framing), warning per occurrence, then supply Date if
            # the app didn't. Mirrors PAGI::Server::Connection's H1 rule,
            # deliberately narrower than the H2 six-name strip.
            my $headers = _strip_h1_connection_headers($captured{headers} // []);
            unless (grep { lc($_->[0]) eq 'date' } @$headers) {
                push @$headers, ['date', _format_http_date()];
            }
            # Upgrade companion: RFC 9110 obliges any Upgrade sender to pair
            # it with Connection: upgrade, and per the PAGI spec the server
            # supplies that token itself (the app's own Connection header
            # was stripped above). Mirrors PAGI::Server's H1 response path.
            if (grep { lc($_->[0]) eq 'upgrade' } @$headers) {
                push @$headers, ['connection', 'upgrade'];
            }
            $captured{headers} = $headers;
        }
        elsif (($captured{type} // '') eq 'http.response.body') {
            if ($method eq 'HEAD') {
                $captured{body} = '';
                delete @captured{qw(fh file offset length)};
            }
            elsif (exists $captured{fh} || exists $captured{file}) {
                $captured{body} = $self->_response_body_bytes(\%captured);
                delete @captured{qw(fh file offset length)};
            }
        }

        push @events, \%captured;

        if (my $conn = $scope->{'pagi.connection'}) {
            $conn->_mark_response_complete if $sv->complete;
        }
    };

    # Call app (with exception handling like real server)
    my $exception;
    eval {
        $self->{app}->($scope, $receive, $send)->get;
    };
    if ($@) {
        $exception = $@;
        if ($self->{raise_app_exceptions}) {
            die $exception;
        }

        if ($sv->complete) {
            # The wire contract was already satisfied (terminal body chunk,
            # any declared trailers) before the app threw -- mirror the
            # server: the response stands and this is a clean completion,
            # not a disconnect.
            if (my $conn = $scope->{'pagi.connection'}) {
                $conn->_mark_complete;
            }
            warn "exception after response completed: $exception";
            return $self->_build_response(\@events);
        }

        # Mimic server behavior: return 500 response
        if (my $conn = $scope->{'pagi.connection'}) {
            $conn->_mark_response_started;            # the 500 IS a response
            $conn->_mark_disconnected('server_error');# abnormal end — not on_complete
        }
        return PAGI::Test::Response->new(
            status    => 500,
            headers   => [['content-type', 'text/plain']],
            body      => 'Internal Server Error',
            exception => $exception,
        );
    }

    # Verify the app satisfied the wire contract before returning -- mirror
    # the server: an incomplete response (no terminal body chunk, or
    # declared trailers never sent) is an abnormal disconnect, not a clean
    # completion.
    if (my $err = $sv->finalize) {
        if (my $conn = $scope->{'pagi.connection'}) {
            $conn->_mark_disconnected('server_error');
        }
        warn "incomplete response: $err\n";

        unless ($sv->started) {
            # The app never sent http.response.start at all -- mirror the
            # server's "Application Produced No Response" backstop: the
            # synthesized 500, not an empty 200.
            return PAGI::Test::Response->new(
                status  => 500,
                headers => [['content-type', 'text/plain']],
                body    => 'Internal Server Error',
            );
        }

        return $self->_build_response(\@events);
    }

    if (my $conn = $scope->{'pagi.connection'}) {
        $conn->_mark_complete;
    }

    # Parse response from captured events
    return $self->_build_response(\@events);
}

sub _build_scope {
    my ($self, $method, $path, $opts) = @_;

    # Parse query string from path
    my $query_string = '';
    if ($path =~ s/\?(.*)$//) {
        $query_string = $1;
    }

    # Add query params if provided (appended to path query string)
    if ($opts->{query}) {
        my $pairs = _normalize_pairs($opts->{query});
        my @encoded;
        for my $pair (@$pairs) {
            my $key = _url_encode($pair->[0]);
            my $val = _url_encode($pair->[1] // '');
            push @encoded, "$key=$val";
        }
        my $new_params = join('&', @encoded);
        $query_string = $query_string ? "$query_string&$new_params" : $new_params;
    }

    # Build headers using helper
    my $headers = $self->_build_headers($opts->{headers});

    my $scope = {
        type         => 'http',
        # source of truth: released PAGI::Server scope advertisement
        pagi         => { version => '0.4', spec_version => '0.3' },
        http_version => '1.1',
        method       => $method,
        scheme       => 'http',
        path         => $path,
        query_string => $query_string,
        root_path    => '',
        headers      => $headers,
        client          => ['127.0.0.1', 12345],
        server          => ['testserver', 80],
        extensions      => \%HTTP_EXTENSIONS,
        'pagi.connection' => PAGI::Test::ConnectionState->new,
    };

    # Add state if lifespan is enabled
    $scope->{state} = $self->{state} if $self->{state};

    return $scope;
}

sub _build_response {
    my ($self, $events) = @_;

    my $status = 200;
    my @headers;
    my $body = '';
    my $response_started = 0;
    my $body_complete = 0;

    for my $event (@$events) {
        my $type = $event->{type} // '';

        if ($type eq 'http.response.start') {
            next if $response_started;
            $response_started = 1;
            $status = $event->{status} // 200;
            @headers = @{$event->{headers} // []};
        }
        elsif ($type eq 'http.response.body') {
            next unless $response_started;
            next if $body_complete;

            $body .= $self->_response_body_bytes($event);

            my $more = $event->{more} // 0;
            $body_complete = 1 unless $more;
        }
    }

    # Extract Set-Cookie headers and store cookies
    for my $h (@headers) {
        if (lc($h->[0]) eq 'set-cookie') {
            if ($h->[1] =~ /^([^=]+)=([^;]*)/) {
                $self->{cookies}{$1} = $2;
            }
        }
    }

    return PAGI::Test::Response->new(
        status  => $status,
        headers => \@headers,
        body    => $body,
    );
}

sub _response_body_bytes {
    my ($self, $event) = @_;

    return $event->{body} // '' if exists $event->{body};

    if (exists $event->{file}) {
        return _read_file_bytes(
            $event->{file},
            $event->{offset} // 0,
            $event->{length},
        );
    }

    if (exists $event->{fh}) {
        return _read_fh_bytes(
            $event->{fh},
            $event->{offset} // 0,
            $event->{length},
        );
    }

    return '';
}

sub _read_file_bytes {
    my ($path, $offset, $length) = @_;

    open my $fh, '<:raw', $path
        or croak "Cannot open file response '$path': $!";

    seek($fh, $offset, 0)
        or croak "Cannot seek file response '$path': $!"
        if $offset;

    my $content = _slurp_fh_bytes($fh, $length);
    close $fh;

    return $content;
}

sub _read_fh_bytes {
    my ($fh, $offset, $length) = @_;

    seek($fh, $offset, 0)
        or croak "Cannot seek filehandle response: $!"
        if $offset;

    return _slurp_fh_bytes($fh, $length);
}

sub _slurp_fh_bytes {
    my ($fh, $length) = @_;

    my $content = '';
    my $remaining = $length;

    while (1) {
        my $to_read = 65536;
        if (defined $remaining) {
            last if $remaining <= 0;
            $to_read = $remaining if $remaining < $to_read;
        }

        my $bytes_read = read($fh, my $chunk, $to_read);
        croak "Cannot read response body from filehandle: $!"
            unless defined $bytes_read;
        last if $bytes_read == 0;

        $content .= $chunk;
        $remaining -= $bytes_read if defined $remaining;
    }

    return $content;
}

sub websocket {
    my ($self, $path, @rest) = @_;

    require PAGI::Test::WebSocket;

    # Handle both: websocket($path, $callback) and websocket($path, %opts)
    # and websocket($path, %opts, $callback)
    my ($callback, %opts);
    if (@rest == 1 && ref($rest[0]) eq 'CODE') {
        $callback = $rest[0];
    } elsif (@rest % 2 == 0) {
        %opts = @rest;
    } elsif (@rest % 2 == 1 && ref($rest[-1]) eq 'CODE') {
        $callback = pop @rest;
        %opts = @rest;
    }

    $path //= '/';

    # Parse query string from path
    my $query_string = '';
    if ($path =~ s/\?(.*)$//) {
        $query_string = $1;
    }

    # Build headers
    my @headers = (['host', 'testserver']);

    # Add client default headers (normalized)
    my $default_pairs = _normalize_pairs($self->{headers});
    for my $pair (@$default_pairs) {
        push @headers, [lc($pair->[0]), $pair->[1]];
    }

    # Add request-specific headers (normalized, replace by key)
    if ($opts{headers}) {
        my $request_pairs = _normalize_pairs($opts{headers});
        my %replace_keys = map { lc($_->[0]) => 1 } @$request_pairs;

        # Filter out replaced headers from existing
        @headers = grep { !$replace_keys{$_->[0]} } @headers;

        # Add request headers
        for my $pair (@$request_pairs) {
            push @headers, [lc($pair->[0]), $pair->[1]];
        }
    }

    # Add cookies
    if (keys %{$self->{cookies}}) {
        my $cookie = join('; ', map { "$_=$self->{cookies}{$_}" } sort keys %{$self->{cookies}});
        push @headers, ['cookie', $cookie];
    }

    my $scope = {
        type         => 'websocket',
        # source of truth: released PAGI::Server scope advertisement
        pagi         => { version => '0.4', spec_version => '0.3' },
        http_version => '1.1',
        scheme       => 'ws',
        path         => $path,
        query_string => $query_string,
        root_path    => '',
        headers      => \@headers,
        client       => ['127.0.0.1', 12345],
        server       => ['testserver', 80],
        subprotocols => $opts{subprotocols} // [],
        extensions   => \%WEBSOCKET_EXTENSIONS,
    };

    $scope->{state} = $self->{state} if $self->{state};

    my $ws = PAGI::Test::WebSocket->new(app => $self->{app}, scope => $scope);
    $ws->_start;

    if ($callback) {
        eval { $callback->($ws) };
        my $err = $@;
        $ws->close unless $ws->is_closed;
        die $err if $err;
        return;
    }

    return $ws;
}

sub sse {
    my ($self, $path, @rest) = @_;

    require PAGI::Test::SSE;

    # Handle both: sse($path, $callback) and sse($path, %opts)
    # and sse($path, %opts, $callback)
    my ($callback, %opts);
    if (@rest == 1 && ref($rest[0]) eq 'CODE') {
        $callback = $rest[0];
    } elsif (@rest % 2 == 0) {
        %opts = @rest;
    } elsif (@rest % 2 == 1 && ref($rest[-1]) eq 'CODE') {
        $callback = pop @rest;
        %opts = @rest;
    }

    $path //= '/';

    # Parse query string from path
    my $query_string = '';
    if ($path =~ s/\?(.*)$//) {
        $query_string = $1;
    }

    # Build headers (SSE requires Accept: text/event-stream)
    my @headers = (
        ['host', 'testserver'],
        ['accept', 'text/event-stream'],
    );

    # Add client default headers (normalized)
    my $default_pairs = _normalize_pairs($self->{headers});
    for my $pair (@$default_pairs) {
        push @headers, [lc($pair->[0]), $pair->[1]];
    }

    # Add request-specific headers (normalized, replace by key)
    if ($opts{headers}) {
        my $request_pairs = _normalize_pairs($opts{headers});
        my %replace_keys = map { lc($_->[0]) => 1 } @$request_pairs;

        # Filter out replaced headers from existing
        @headers = grep { !$replace_keys{$_->[0]} } @headers;

        # Add request headers
        for my $pair (@$request_pairs) {
            push @headers, [lc($pair->[0]), $pair->[1]];
        }
    }

    # Add cookies
    if (keys %{$self->{cookies}}) {
        my $cookie = join('; ', map { "$_=$self->{cookies}{$_}" } sort keys %{$self->{cookies}});
        push @headers, ['cookie', $cookie];
    }

    # SSE supports all HTTP methods (GET is default, but POST/PUT work with
    # modern libraries like fetch-event-source used by htmx4, datastar, etc.)
    my $method = uc($opts{method} // 'GET');

    my $scope = {
        type         => 'sse',
        # source of truth: released PAGI::Server scope advertisement
        pagi         => { version => '0.4', spec_version => '0.3' },
        http_version => '1.1',
        method       => $method,
        scheme       => 'http',
        path         => $path,
        query_string => $query_string,
        root_path    => '',
        headers      => \@headers,
        client       => ['127.0.0.1', 12345],
        server       => ['testserver', 80],
        extensions   => \%SSE_EXTENSIONS,
    };

    $scope->{state} = $self->{state} if $self->{state};

    my $sse = PAGI::Test::SSE->new(app => $self->{app}, scope => $scope);
    $sse->_start;

    if ($sse->_declined) {
        # The app declined (sse.http.response.*) instead of starting a
        # stream -- mirror the server: hand back the real HTTP response it
        # sent, not an SSE connection object. There is no stream to hand a
        # callback either, so the callback (if any) is never invoked.
        return PAGI::Test::Response->new(
            status  => $sse->_decline_status,
            headers => $sse->_decline_headers,
            body    => $sse->_decline_body,
        );
    }

    if ($callback) {
        eval { $callback->($sse) };
        my $err = $@;
        $sse->close unless $sse->is_closed;
        die $err if $err;
        return;
    }

    return $sse;
}

sub start {
    my ($self) = @_;
    return $self if $self->{started};
    return $self unless $self->{lifespan};

    $self->{state} = {};

    my $scope = {
        type          => 'lifespan',
        # source of truth: released PAGI::Server scope advertisement
        pagi          => { version => '0.4', spec_version => '0.3' },
        state  => $self->{state},
    };

    my $phase = 'startup';
    my $pending_future;

    my $receive = async sub {
        if ($phase eq 'startup') {
            $phase = 'running';
            return { type => 'lifespan.startup' };
        }
        # Wait for shutdown
        $pending_future = Future->new;
        return await $pending_future;
    };

    # Strict: illegal events (per PAGI::SendValidation's lifespan rules) fail
    # the returned Future -- a result reported for the wrong phase (e.g. a
    # shutdown result sent while still in startup) is a real bug in the app
    # under test, not something this canonical test client should tolerate.
    my $sv = PAGI::SendValidation->new(scope_type => 'lifespan');

    # Resolves when the app signals startup: done on lifespan.startup.complete,
    # failed (with the app's message) on lifespan.startup.failed. $shutdown is
    # the symmetric counterpart for stop() below, created here (not in stop())
    # because both phases share this one $send closure over the app's single
    # long-lived lifespan coroutine.
    my $startup  = Future->new;
    my $shutdown = Future->new;
    my $send = async sub {
        my ($event) = @_;

        if (my $err = $sv->check($event)) {
            die $err->message . "\n";
        }

        my $type = $event->{type} // '';
        if ($type eq 'lifespan.startup.complete') {
            $startup->done unless $startup->is_ready;
        }
        elsif ($type eq 'lifespan.startup.failed') {
            $startup->fail($event->{message} // "lifespan startup failed\n")
                unless $startup->is_ready;
        }
        elsif ($type eq 'lifespan.shutdown.complete') {
            $shutdown->done unless $shutdown->is_ready;
        }
        elsif ($type eq 'lifespan.shutdown.failed') {
            $shutdown->fail($event->{message} // "lifespan shutdown failed\n")
                unless $shutdown->is_ready;
        }
    };

    $self->{lifespan_sv}       = $sv;
    $self->{lifespan_pending}  = \$pending_future;
    $self->{lifespan_shutdown} = $shutdown;
    $self->{lifespan_future}   = $self->{app}->($scope, $receive, $send);

    $self->_await_lifespan_phase($startup, 'startup');

    $self->{started} = 1;
    return $self;
}

sub stop {
    my ($self) = @_;
    return $self unless $self->{started};
    return $self unless $self->{lifespan};

    # The server delivers the shutdown event to the app now -- declare the
    # phase current before doing so, since a synchronous shutdown hook's
    # send() (driven by ->done below, before it returns) needs $sv already
    # in 'shutdown' to accept lifespan.shutdown.complete/.failed.
    $self->{lifespan_sv}->enter_phase('shutdown') if $self->{lifespan_sv};

    # Resolve the pending future with shutdown event
    if ($self->{lifespan_pending} && ${$self->{lifespan_pending}}) {
        ${$self->{lifespan_pending}}->done({ type => 'lifespan.shutdown' });
    }

    $self->_await_lifespan_phase($self->{lifespan_shutdown}, 'shutdown')
        if $self->{lifespan_shutdown};

    $self->{started} = 0;
    return $self;
}

# Drives $result_future (the startup or shutdown result Future built in
# start()) to readiness, following the same three-path resolution for both
# phases: a result already signaled synchronously, the app's lifespan
# coroutine having unwound without ever signaling a result for this phase, or
# a real off-loop wait needing the event loop driven up to a timeout. ->get
# rethrows on a .failed result or the backstop timeout, so this dies exactly
# as the pre-B11 start() always did for startup -- stop() now does the same
# for shutdown.
sub _await_lifespan_phase {
    my ($self, $result_future, $phase_name) = @_;

    if ($result_future->is_ready) {
        # A synchronous hook has already signaled by the time we get here.
        # Rethrow on failure; otherwise this is a no-op. No event loop
        # involved in this common path.
        $result_future->get;
        return;
    }

    if ($self->{lifespan_future}->is_ready) {
        # The app unwound without signaling this phase's result at all.
        # Surface its own exception if it failed, otherwise report the
        # protocol violation rather than waiting for a signal that will
        # never come.
        $self->{lifespan_future}->get;
        croak "PAGI lifespan app returned without sending "
            . "lifespan.${phase_name}.complete or lifespan.${phase_name}.failed";
    }

    # The hook suspended on real off-loop I/O. Drive the event loop until it
    # signals, the same way _request drives a request with ->get, instead of
    # busy-waiting a deadline that never advances the loop. Off-loop I/O is
    # only possible when Future::IO is present, so require it lazily here
    # (it is a recommended, not required, prereq).
    require Future::IO;
    my $timeout = 5;
    my $drive = async sub {
        await Future->wait_any(
            $result_future,
            Future::IO->sleep($timeout)->then(sub {
                Future->fail(
                    "PAGI lifespan $phase_name did not complete within ${timeout} seconds\n"
                );
            }),
        );
    };
    $drive->()->get;
}

sub state { shift->{state} // {} }

sub run {
    my ($class, $app, $callback) = @_;

    my $client = $class->new(app => $app, lifespan => 1);
    $client->start;

    eval { $callback->($client) };
    my $err = $@;

    $client->stop;
    die $err if $err;
}

sub _url_encode {
    my ($str) = @_;
    $str =~ s/([^A-Za-z0-9_\-.])/sprintf("%%%02X", ord($1))/eg;
    return $str;
}

# HTTP/1.1 connection-specific header stripping (PAGI spec: "Over HTTP/1.1
# the server must ignore or strip application-supplied Transfer-Encoding and
# Connection -- it supplies its own -- and SHOULD log when it does"). This
# mock only ever speaks HTTP/1.1 (see http_version in _build_scope), so it
# mirrors PAGI::Server::Connection's H1 rule only -- transfer-encoding and
# connection -- not the H2 six-name strip (connection, keep-alive,
# proxy-connection, transfer-encoding, upgrade, te), which has no bearing on
# an in-process test double that never speaks HTTP/2.
my %H1_CONNECTION_SPECIFIC_HEADER = map { $_ => 1 } qw(transfer-encoding connection);

# Returns a new arrayref with app-supplied transfer-encoding/connection pairs
# removed, warning once per stripped occurrence (not deduplicated by name --
# two 'connection' headers warn twice). Does not mutate $headers.
sub _strip_h1_connection_headers {
    my ($headers) = @_;
    my @kept;
    for my $h (@$headers) {
        my ($name, $value) = @$h;
        if ($H1_CONNECTION_SPECIFIC_HEADER{lc $name}) {
            warn "PAGI::Test::Client: connection-specific header '$name' stripped from HTTP/1.1 response\n";
            next;
        }
        push @kept, $h;
    }
    return \@kept;
}

my @HTTP_DATE_DAYS   = qw(Sun Mon Tue Wed Thu Fri Sat);
my @HTTP_DATE_MONTHS = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);

# RFC 7231 IMF-fixdate, e.g. "Sun, 06 Nov 1994 08:49:37 GMT" -- the same
# shape PAGI::Server::Protocol::HTTP1's format_date produces, reimplemented
# here rather than depending on the PAGI::Server distribution from this
# toolkit-only mock.
sub _format_http_date {
    my @gmt = gmtime(time);
    return sprintf("%s, %02d %s %04d %02d:%02d:%02d GMT",
        $HTTP_DATE_DAYS[$gmt[6]], $gmt[3], $HTTP_DATE_MONTHS[$gmt[4]], $gmt[5] + 1900,
        $gmt[2], $gmt[1], $gmt[0]);
}

# Normalize various input formats to arrayref of [key, value] pairs.
# Supports:
#   - Hash with scalar values: { key => 'value' }
# Set a header on a headers structure (hashref or arrayref of pairs).
# If $replace is true, replaces existing value. Otherwise only sets if not present.
sub _set_header {
    my ($headers_ref, $name, $value, $replace) = @_;
    $replace //= 0;

    if (!defined $$headers_ref) {
        $$headers_ref = { $name => $value };
        return;
    }

    if (ref($$headers_ref) eq 'HASH') {
        if ($replace) {
            $$headers_ref->{$name} = $value;
        } else {
            $$headers_ref->{$name} //= $value;
        }
    } elsif (ref($$headers_ref) eq 'ARRAY') {
        # Check if header already exists (case-insensitive)
        my $found_idx;
        for my $i (0 .. $#{$$headers_ref}) {
            if (lc($$headers_ref->[$i][0]) eq lc($name)) {
                $found_idx = $i;
                last;
            }
        }
        if (defined $found_idx) {
            $$headers_ref->[$found_idx][1] = $value if $replace;
        } else {
            push @{$$headers_ref}, [$name, $value];
        }
    }
}

#   - Hash with arrayref values: { key => ['v1', 'v2'] }
#   - Arrayref of pairs: [['key', 'v1'], ['key', 'v2']]
# Returns arrayref of [key, value] pairs.
sub _normalize_pairs {
    my ($input) = @_;
    return [] unless defined $input;

    # Arrayref of pairs: [['key', 'val'], ['key', 'val2']]
    if (ref($input) eq 'ARRAY') {
        # Validate it looks like pairs
        for my $pair (@$input) {
            croak "Expected arrayref of [key, value] pairs"
                unless ref($pair) eq 'ARRAY' && @$pair == 2;
        }
        return $input;
    }

    # Hash (with scalar or arrayref values)
    if (ref($input) eq 'HASH') {
        my @pairs;
        for my $key (sort keys %$input) {
            my $val = $input->{$key};
            if (ref($val) eq 'ARRAY') {
                # Multiple values for this key
                push @pairs, [$key, $_] for @$val;
            } else {
                # Single value
                push @pairs, [$key, $val // ''];
            }
        }
        return \@pairs;
    }

    croak "Expected hashref or arrayref of pairs, got " . ref($input);
}

# Build headers array, merging defaults with request-specific headers.
# Request headers replace client defaults by key (case-insensitive).
sub _build_headers {
    my ($self, $request_headers) = @_;

    my @headers;

    # Default headers
    push @headers, ['host', 'testserver'];

    # Normalize client default headers
    my $default_pairs = _normalize_pairs($self->{headers});

    # Normalize request-specific headers
    my $request_pairs = _normalize_pairs($request_headers);

    # Build set of keys to replace (lowercase)
    my %replace_keys;
    for my $pair (@$request_pairs) {
        $replace_keys{lc($pair->[0])} = 1;
    }

    # Add client defaults (skip if being replaced)
    for my $pair (@$default_pairs) {
        push @headers, [lc($pair->[0]), $pair->[1]]
            unless $replace_keys{lc($pair->[0])};
    }

    # Add request-specific headers
    for my $pair (@$request_pairs) {
        push @headers, [lc($pair->[0]), $pair->[1]];
    }

    # Add cookies
    if (keys %{$self->{cookies}}) {
        my $cookie = join('; ', map { "$_=$self->{cookies}{$_}" } sort keys %{$self->{cookies}});
        push @headers, ['cookie', $cookie];
    }

    return \@headers;
}

1;

__END__

=head1 NAME

PAGI::Test::Client - Test client for PAGI applications

=head1 SYNOPSIS

    use PAGI::Test::Client;

    my $client = PAGI::Test::Client->new(app => $app);

    # Simple GET
    my $res = $client->get('/');
    is $res->status, 200;
    is $res->text, 'Hello World';

    # GET with query parameters
    my $res = $client->get('/search', query => { q => 'perl' });

    # POST with JSON body
    my $res = $client->post('/api/users', json => { name => 'John' });

    # POST with form data
    my $res = $client->post('/login', form => { user => 'admin' });

    # Custom headers
    my $res = $client->get('/api', headers => { Authorization => 'Bearer xyz' });

    # Multiple values for same header/query/form field
    my $res = $client->get('/search',
        query   => { tag => ['perl', 'async'] },       # ?tag=perl&tag=async
        headers => { Accept => ['text/html', 'application/json'] },
    );

    # Arrayref of pairs for explicit ordering
    my $res = $client->get('/api',
        headers => [['X-Custom', 'first'], ['X-Custom', 'second']],
    );

    # Multi-value form (checkboxes, multi-select)
    my $res = $client->post('/survey',
        form => { colors => ['red', 'blue', 'green'] },
    );

    # Session cookies persist across requests
    $client->post('/login', form => { user => 'admin', pass => 'secret' });
    my $res = $client->get('/dashboard');  # authenticated!

=head1 DESCRIPTION

PAGI::Test::Client allows you to test PAGI applications without starting
a real server. It invokes your app directly by constructing the PAGI
protocol messages ($scope, $receive, $send), making tests fast and simple.

This is inspired by Starlette's TestClient but adapted for Perl and PAGI's
specific features like first-class SSE support.

B<This is a lightweight in-process test harness, not a transport simulator.>
It is best suited for unit and integration tests of application logic, routing,
cookies, and basic protocol flows. For behavior that depends on real socket I/O,
HTTP framing, backpressure, or server lifecycle semantics, prefer testing
against L<PAGI::Server>.

=head1 SEND STRICTNESS (http)

The C<$send> coderef given to your app during an HTTP request is strict: it
validates every event against the PAGI http send-sequencing rules via
L<PAGI::SendValidation> and fails the returned Future (the app's C<await
$send->(...)> dies) for anything a real server would reject -- an
unrecognized or missing event C<type> (C<malformed>/C<unknown_type>), an
out-of-order event such as a duplicate C<http.response.start> or a body
chunk before it (C<sequence>), or undeclared C<http.response.trailers>
(C<sequence>). A rejected event is never appended to the assembled
response. There is no lenient mode -- a canonical test client must not
accept what the server would fail; see L<PAGI::SendValidation/RULES> for
the exact http rule set.

An app that returns without reaching a legal terminal state (no terminal
body chunk, or declared trailers never sent -- the C<incomplete> category)
is treated as an abnormal disconnect, not a clean completion: C<finalize>
reports it, C<pagi.connection> fires C<on_disconnect('server_error')>
instead of C<on_complete>, and a warning is issued, mirroring how a real
server logs an incomplete response.

An exception the app throws is likewise judged against how much of the
wire contract was already satisfied: if it happens before the response
reached a legal terminal state, the existing synthetic 500 +
C<server_error> disconnect behavior applies (see L</raise_app_exceptions>
below). If it happens B<after> the response is already complete, the real
response stands, C<on_complete> fires (not C<on_disconnect>), and a
warning documents the stray post-completion exception -- the response the
app actually sent to the wire is not retroactively invalidated by a bug in
cleanup code that runs after it.

=head1 RESPONSE HEADERS (http)

This mock is B<H1-flavored>: it only ever advertises C<http_version =E<gt>
'1.1'> (see L</SCOPE EXTENSIONS> below for the HTTP/2-adjacent implications
of that), and its response-header handling mirrors
C<PAGI::Server::Connection>'s HTTP/1.1 rule, not its HTTP/2 rule. Two things
happen to every C<http.response.start> event's headers before they reach
C<PAGI::Test::Response>:

=over 4

=item *

Any app-supplied C<Transfer-Encoding> or C<Connection> header is stripped --
this mock owns response framing, the same way a real HTTP/1.1 server does --
warning once per stripped occurrence (two C<Connection> headers warn twice).
This is deliberately narrower than an HTTP/2 six-name strip: C<Upgrade>,
C<TE>, and C<Keep-Alive> are ordinary application headers on HTTP/1.1 and
pass through untouched.

=item *

A C<Date> header is added if the app didn't supply its own; an app-supplied
C<Date> is preserved verbatim, not overwritten.

=item *

A response carrying an C<Upgrade> header gains C<Connection: upgrade> --
RFC 9110 obliges any C<Upgrade> sender to send the pair, and per the PAGI
spec the server supplies that token itself (the app's own C<Connection>
header having been stripped above).

=back

=head1 SCOPE EXTENSIONS

Every scope's C<extensions> key advertises exactly the extension set this
mock genuinely implements -- never more than L<PAGI::SendValidation> (see
L<PAGI::SendValidation/RULES>) is wired to accept for that scope, since the
two are the same shared data structure (see the module source's
C<%HTTP_EXTENSIONS> / C<%WEBSOCKET_EXTENSIONS> / C<%SSE_EXTENSIONS>), not two
independently-maintained lists that could drift:

=over 4

=item * C<http> and C<sse> -- empty (C<{}>). C<http.fullflush>'s real
contract is "block until bytes are flushed to the transport"; this mock has
no transport to flush (every event is captured synchronously in-process), so
there is nothing genuine to honor. Sending C<http.fullflush> through this
mock always fails as an unadvertised extension.

=item * C<websocket> -- C<{ 'websocket.http.response' =E<gt> {} }>. The
extension denial path (C<websocket.http.response.start>/C<.body>) is
concretely implemented by L<PAGI::Test::WebSocket> (its own C<denial> /
C<denial_complete> states), so it is genuinely advertised.

=back

=head1 CONSTRUCTOR

=head2 new

    my $client = PAGI::Test::Client->new(
        app      => $app,           # Required: PAGI app coderef
        headers  => { ... },        # Optional: default headers
        lifespan => 1,              # Optional: enable lifespan (default: 0)
    );

=head3 Options

=over 4

=item app (required)

The PAGI application to test. This native application position accepts the two
forms supported by L<PAGI::Utils/to_app>: a coderef or an instantiated
component object with a C<to_app> method:

    # Coderef (existing style)
    my $client = PAGI::Test::Client->new(app => $coderef);

    # Component object
    my $client = PAGI::Test::Client->new(app => MyApp::Main->new(%opts));

Package-name strings are rejected synchronously. Load and construct the
component explicitly so configuration and object identity stay visible:

    use MyApp::Main;
    my $client = PAGI::Test::Client->new(
        app => MyApp::Main->new(%opts),
    );

=item headers

Default headers to include in every request. Supports multiple formats:

    # Simple hash (single values)
    headers => { 'X-API-Key' => 'secret' }

    # Hash with arrayref values (multiple values per header)
    headers => { Accept => ['application/json', 'text/html'] }

    # Arrayref of pairs (explicit ordering)
    headers => [['Accept', 'application/json'], ['Accept', 'text/html']]

Request-specific headers with the same name will B<replace> (not append to)
these default headers.

=item lifespan

If true, the client will send lifespan.startup when started and
lifespan.shutdown when stopped. Default is false (most tests don't need it).

=item raise_app_exceptions

Controls how application exceptions are handled. Default is B<false>.

When B<false> (default): Exceptions are trapped. If the response had not yet
reached a legal terminal state, this converts to a 500 response, mimicking
how a real server behaves; the exception is available via
C<< $response->exception >>. If the response had B<already> completed (see
L</SEND STRICTNESS (http)> above), the real response is returned instead --
the exception did not corrupt anything already sent to the wire, so
inventing a 500 in its place would misreport what happened.

    my $res = $client->get('/broken');
    is $res->status, 500;
    like $res->exception, qr/Can't call method/;

When B<true>: Exceptions propagate to the test, useful for debugging:

    my $client = PAGI::Test::Client->new(
        app => $app,
        raise_app_exceptions => 1,
    );
    # This will die with the actual exception
    my $res = $client->get('/broken');

=back

=head1 HTTP METHODS

All HTTP methods return a L<PAGI::Test::Response> object.

=head2 get

    my $res = $client->get($path, %options);

=head2 post

    my $res = $client->post($path, %options);

=head2 put

    my $res = $client->put($path, %options);

=head2 patch

    my $res = $client->patch($path, %options);

=head2 delete

    my $res = $client->delete($path, %options);

=head2 head

    my $res = $client->head($path, %options);

=head2 options

    my $res = $client->options($path, %options);

=head3 Request Options

=over 4

=item headers => { ... } or [ [...], [...] ]

Additional headers for this request. Supports multiple formats:

    # Simple hash
    headers => { Authorization => 'Bearer xyz' }

    # Multiple values (arrayref in hash)
    headers => { Accept => ['application/json', 'text/html'] }

    # Arrayref of pairs (preserves order)
    headers => [['X-Custom', 'first'], ['X-Custom', 'second']]

Request headers with the same name as client default headers will B<replace>
the defaults (not append).

=item query => { ... } or [ [...], [...] ]

Query string parameters. Supports multiple formats:

    # Simple hash
    query => { q => 'perl' }

    # Multiple values
    query => { tag => ['perl', 'async'] }  # ?tag=perl&tag=async

    # Arrayref of pairs
    query => [['tag', 'perl'], ['tag', 'async']]

B<Note:> Query params are B<appended> to any existing query string in the path.
To avoid duplicates, put all params either in the path or in the query option,
not both with the same key.

=item json => { ... }

JSON request body. Automatically sets Content-Type to application/json.

=item form => { ... } or [ [...], [...] ]

Form-encoded request body. Sets Content-Type to application/x-www-form-urlencoded.
Supports multiple formats:

    # Simple hash
    form => { user => 'admin', pass => 'secret' }

    # Multiple values (checkboxes, multi-select)
    form => { colors => ['red', 'blue', 'green'] }

    # Arrayref of pairs
    form => [['color', 'red'], ['color', 'blue']]

=item body => $bytes

Raw request body bytes.

=back

=head1 LIMITATIONS

=over 4

=item *

HTTP request bodies are delivered as a single C<http.request> event. This
client does B<not> currently simulate multi-event request body streaming or
disconnects mid-request-body.

=item *

HTTP response trailers (C<http.response.trailers>) are not exposed through
L<PAGI::Test::Response>. If your application depends on trailer semantics,
test it against L<PAGI::Server>.

=item *

This client invokes the app directly and does not simulate transport-level
behavior such as chunked transfer framing, socket backpressure, kernel write
ordering, TLS, or HTTP/2.

=item *

Lifespan support is intended for basic shared-state tests. It is lighter-weight
than the real server lifecycle and should not be treated as a full compliance
test for startup/shutdown behavior.

=item *

WebSocket and SSE testing is delegated to L<PAGI::Test::WebSocket> and
L<PAGI::Test::SSE>, which intentionally provide simplified in-process models
of those protocols.

=back

=head1 SESSION METHODS

=head2 cookies

    my $hashref = $client->cookies;

Returns all current session cookies.

=head2 cookie

    my $value = $client->cookie('session_id');

Returns a specific cookie value.

=head2 set_cookie

    $client->set_cookie('theme', 'dark');

Manually sets a cookie.

=head2 clear_cookies

    $client->clear_cookies;

Clears all session cookies.

=head1 WEBSOCKET

=head2 websocket

    # Callback style (auto-close)
    $client->websocket('/ws', sub {
        my ($ws) = @_;
        $ws->send_text('hello');
        is $ws->receive_text, 'echo: hello';
    });

    # Explicit style
    my $ws = $client->websocket('/ws');
    $ws->send_text('hello');
    is $ws->receive_text, 'echo: hello';
    $ws->close;

    # With options
    my $ws = $client->websocket('/ws',
        headers      => { Authorization => 'Bearer xyz' },
        subprotocols => ['chat', 'json'],
    );

    # Options with callback
    $client->websocket('/ws', headers => { 'X-Token' => 'abc' }, sub {
        my ($ws) = @_;
        # ...
    });

See L<PAGI::Test::WebSocket> for the WebSocket connection API, including
its send strictness (L<PAGI::Test::WebSocket/SEND STRICTNESS>), the
portable and extension denial paths, and C<simulate_abnormal_close>.

=head1 SSE (Server-Sent Events)

=head2 sse

    # Callback style (auto-close)
    $client->sse('/events', sub {
        my ($sse) = @_;
        my $event = $sse->receive_event;
        is $event->{data}, 'connected';
    });

    # Explicit style
    my $sse = $client->sse('/events');
    my $event = $sse->receive_event;
    $sse->close;

    # With headers (e.g., for reconnection)
    my $sse = $client->sse('/events',
        headers => { 'Last-Event-ID' => '42' },
    );

    # Options with callback
    $client->sse('/events', headers => { Authorization => 'Bearer xyz' }, sub {
        my ($sse) = @_;
        # ...
    });

    # A decline (sse.http.response.*) returns a PAGI::Test::Response, not
    # an SSE connection object -- there is no stream to hand a callback,
    # so any callback given is not invoked.
    my $res = $client->sse('/nope');
    is $res->status, 404;

See L<PAGI::Test::SSE> for the SSE connection API and its send strictness
(L<PAGI::Test::SSE/SEND STRICTNESS>).

=head1 LIFESPAN

=head2 start

    $client->start;

Triggers lifespan.startup. Only needed if C<< lifespan => 1 >> was passed
to the constructor.

Waits for the app to signal C<lifespan.startup.complete> before returning. If
the startup hook awaits real off-loop I/O (via L<Future::IO>), C<start> drives
the event loop until it completes rather than giving up. If startup B<fails>
(the app sends C<lifespan.startup.failed>, e.g. because a startup hook died),
C<start> C<die>s with the failure message instead of returning silently. A
startup that never signals within a few seconds C<die>s with a timeout error.

The lifespan C<$send> coderef is strict, like the http path (see L</SEND
STRICTNESS (http)> above): a result event reported for the wrong phase (for
example the app sending C<lifespan.shutdown.complete> while still in the
startup phase) fails the app's C<await $send-E<gt>(...)> instead of being
silently accepted; see L<PAGI::SendValidation/RULES> ("lifespan") for the
exact rule set.

=head2 stop

    $client->stop;

Triggers lifespan.shutdown and waits for the app to signal
C<lifespan.shutdown.complete> before returning -- symmetric with C<start>'s
handling of startup in every respect: a shutdown hook awaiting real off-loop
I/O is driven the same way, a B<failed> shutdown (C<lifespan.shutdown.failed>)
C<die>s with the failure message instead of returning silently, and a
shutdown that never signals within a few seconds C<die>s with a timeout
error.

=head2 state

    my $state = $client->state;

Returns the shared state hashref from lifespan.

=head2 run

    PAGI::Test::Client->run($app, sub {
        my ($client) = @_;
        # ... tests ...
    });

Class method that creates a client with lifespan enabled, calls start,
runs your callback, then calls stop. Exceptions propagate.

=head1 SEE ALSO

L<PAGI::Test::Response>, L<PAGI::Test::WebSocket>, L<PAGI::Test::SSE>

=cut
