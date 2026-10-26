package PAGI::Middleware::CSRF;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future;
use Future::AsyncAwait;
use PAGI::Utils::Random qw(secure_random_bytes);
use PAGI::Utils::SecureCompare qw(secure_compare);
use Scalar::Util qw(blessed);
use HTTP::MultiPartParser ();
use PAGI::Exception::RequestBody ();
use PAGI::Request ();
use PAGI::Request::MultipartStream ();
use PAGI::Response::Text ();
use PAGI::Utils ();
use PAGI::Utils::Middleware qw(record_receive);

=head1 NAME

PAGI::Middleware::CSRF - Cross-Site Request Forgery protection middleware

=head1 SYNOPSIS

    use PAGI::Tools qw(compose middleware response route);

    # Refuse a failed check with a 403 text response (the default)
    my $app = compose(
        routes     => [route('/' => sub { response('Text', 'hello') })],
        middleware => [middleware('CSRF')],
    );

Its other modes:

    # Refuse it with your own application or Response
    middleware('CSRF',
        refuse => response('JSON', { detail => 'CSRF token validation failed' }, status => 403));

    # Let the application decide: every request reaches it, with the outcome
    # recorded for csrf($request)->valid and ->failure
    middleware('CSRF', refuse => 0);

    # Keep the token in the session (Session middleware must wrap this one)
    middleware('CSRF', session => 1);

    # Accept plain HTML forms: a form post without the header has its
    # csrf_token field read here, and the route reads the whole body as usual
    middleware('CSRF', form_field => 'csrf_token');

L<PAGI::CSRF/SYNOPSIS> shows both modes in full, as complete applications.

C<middleware('CSRF', ...)> also goes in a Router's, Mount's or Route's
C<middleware> list. It constructs the middleware and wraps the application
inside it, which you can do yourself:

    use PAGI::Middleware::CSRF;

    my $wrapped = PAGI::Middleware::CSRF->new->wrap($native_app);

Without Compose, L<PAGI::Middleware::Builder> composes middleware the way
Plack::Builder does.

=head1 DESCRIPTION

PAGI::Middleware::CSRF provides protection against Cross-Site Request
Forgery attacks by validating tokens on state-changing requests. Its default
refusal is a plain 403 text response; C<refuse> replaces it, or lets the
application decide. L<PAGI::CSRF/SYNOPSIS> shows both, as complete
applications.

An unsafe request carries its token in the C<token_header> header (a
script, a JSON API) or in the C<form_field> field of its form (a plain HTML
form, which cannot set a header). The header is checked first; an empty
header counts as not sent, and a request whose header matches has its body
left unread. Without C<form_field> a request without the header is refused.
With it, an C<application/x-www-form-urlencoded> request without the header
has its body read here -- at most C<max_form_size> bytes, through a recording
receive -- and its first C<form_field> field compared with the token (a form
carries one; were there two, the first decides, where Django's middleware
takes the last, so that a multipart upload can stream past its token); whoever
runs next, the application or C<refuse>, is handed a receive that delivers
the whole body again, so the route reads its form as usual. A body over
C<max_form_size> is answered here with a plain-text 413. A
C<multipart/form-data> request without the header is read only as far as its
token part, in byte order, so the answer does not depend on how the client's
bytes arrived and an upload after the token still streams to the route: a
file part before the token is refused (put the hidden token field first --
browsers send fields in document order), no limit is applied here to a part
after it, and a body that cannot be parsed is answered with a plain-text 400.
Any other body without the header, JSON included, is refused.

Every unsafe request first passes an origin check, modelled on Go's
C<CrossOriginProtection>: a C<Sec-Fetch-Site> header must be C<same-origin>
or C<none>; without one, an C<Origin> header's host and port must equal the
C<Host> header. An origin in C<trusted_origins> always passes, and a request
with neither header (a non-browser client, or an older browser) is left to
the token check. A failure is recorded as C<cross_origin>.

A WebSocket handshake gets the same origin check: it carries the browser's
cookies and WebSockets are outside CORS, so a page on another site could
otherwise open an authenticated socket (cross-site WebSocket hijacking). A
cross-origin handshake is answered by C<refuse> before accept -- by default
the 403 -- or, under C<refuse =E<gt> 0>, reaches the application with
C<cross_origin> recorded. There is no token check on a handshake (a browser
cannot add headers to one); its scope carries the token for C<csrf($ws)>,
taken from the cookie or session without setting either. SSE requests are
not checked: a page on another site cannot read the stream.

=head1 CONFIGURATION

An option not listed here dies at construction.

=over 4

=item * token_header (default: 'X-CSRF-Token')

Header name to look for the CSRF token.

=item * cookie_name (default: 'csrf_token')

Cookie name for the CSRF token.

=item * safe_methods (default: ['GET', 'HEAD', 'OPTIONS', 'TRACE'])

HTTP methods that don't require CSRF validation.

=item * secure (default: 0)

Add the C<Secure> attribute to the CSRF cookie, restricting it to HTTPS
requests. Off by default so plain-HTTP development setups keep working;
for production HTTPS deployments, add C<< secure => 1 >>.

=item * httponly (default: 0)

Add C<HttpOnly> to the CSRF cookie, so scripts cannot read it. Off by
default: the double-submit pattern needs the page's script to send the
token back, and front-end libraries (Angular, Axios) read it from the
cookie. C<HttpOnly> adds no protection against cross-site requests; turn it
on if an audit requires it, and render C<< csrf($request)->token >> into
the page instead (see L</USAGE>).

=item * session (default: 0)

Keep the token in the session (C<csrf_token> in C<pagi.session>) instead of
its own cookie. A cookie planted by another site or a sibling subdomain then
means nothing; see L</SECURITY>. Needs L<PAGI::Middleware::Session> outside
this middleware; an C<http> request without it dies. No CSRF cookie is set,
so the page carries the token (C<< csrf($request)->token >>). Cannot be
combined with C<httponly>.

When the application regenerates the session -- as it should at login --
the token is replaced as that response starts, so a token known before
login is refused after it. A page rendered in that same response still
carries the old token: redirect after login, as usual, so the next page
gets the new one.

=item * trusted_origins (default: [])

Origins, besides the request's own, whose unsafe requests may pass the
origin check -- for example an application on C<https://app.example.com>
posting to an API on C<https://api.example.com>. Each is a scheme and host
with an optional port (C<http://localhost:3000>, C<http://[::1]:3000>),
nothing else; a default port is dropped, as browsers drop it from
C<Origin>. The token check still applies.

=item * form_field (default: undef)

The form field the token is read from, usually C<csrf_token> (the name of the
default cookie and of the session key). Set, an unsafe form post that came
without the header and passed the origin check has the field read from its
body here (see L</"Form flow (plain HTML forms)">). C<undef>, the default,
means no form flow: a request without the header is refused. Anything else
but a non-empty string dies.

=item * max_form_size (default: 1048576, 1 MiB)

The most bytes of a form body read here, ahead of the application, to find
its token -- the whole of a urlencoded body, or a multipart body up to its
token part, however large the upload after it. A form whose token is not
within that many bytes is answered with a plain-text 413 C<Request body too
large> (under C<< refuse => 0 >> it is not read further, C<missing_token> is
recorded, and the application gets the whole body). A positive integer;
anything else dies.

=item * refuse (default: a 403 text response)

What answers an unsafe request that fails the origin or token check. Absent: a
C<403 text/plain> response, C<CSRF token validation failed>. An application
-- a Request handler (a coderef called with one
L<PAGI::Request>, returning a Response or an application) or an object
with C<to_app>, which
includes every L<PAGI::Response> -- answers instead, and can read the reason
with C<< csrf($request)->failure >>; when the middleware read a form's body,
it is handed a receive that delivers the whole body, so it can read the form
to re-render it. It answers failed checks only: a form body over
C<max_form_size>, or one that cannot be parsed, is the client's error, not a
CSRF failure, and is answered by the middleware's own plain-text 413 or 400.
Exactly C<0>: the
middleware never refuses;
the request reaches the application with the outcome recorded for
C<< csrf($request)->valid >> and C<< ->failure >>. Any other plain value dies.

A native C<($scope, $receive, $send)> application is passed as
C<as_app_object($app)>. Objects -- every Response and L<PAGI::Pages> value --
mean the same in every slot, and are the portable form for anything also
given to middleware outside PAGI-Tools.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    die "CSRF 'enforce' was removed: use refuse => 0 for the application to decide; the default refuses"
        if exists $config->{enforce};
    die 'CSRF no longer takes a secret: its tokens are random; for tokens bound to the session use session => 1'
        if exists $config->{secret};

    $self->{token_header} = $config->{token_header} // 'X-CSRF-Token';
    $self->{cookie_name}  = $config->{cookie_name} // 'csrf_token';
    $self->{safe_methods} = { map { $_ => 1 } @{$config->{safe_methods} // [qw(GET HEAD OPTIONS TRACE)]} };
    $self->{secure}       = $config->{secure} // 0;
    $self->{httponly}     = _flag($config, 'httponly');
    $self->{session}      = _flag($config, 'session');
    die 'CSRF httponly has no cookie to flag under session => 1: the token lives in the session'
        if $self->{httponly} && $self->{session};
    $self->{trusted_origins} = _trusted_origins($config->{trusted_origins} // []);
    # The field a form's token is read from; absent or undef, no form flow.
    $self->{form_field} = $config->{form_field};
    die 'CSRF form_field must be a field name, like csrf_token, or undef for no form flow'
        if defined($self->{form_field}) && (ref($self->{form_field}) || !length($self->{form_field}));
    die "CSRF 'body_buffer' was removed: the form read is bounded by max_form_size"
        if exists $config->{body_buffer};
    # The most bytes of a form body read ahead of the application to find
    # its token.
    $self->{max_form_size} = $config->{max_form_size} // 1024 * 1024;
    die 'CSRF max_form_size must be a positive integer'
        unless !ref($self->{max_form_size}) && $self->{max_form_size} =~ /\A[1-9][0-9]*\z/;

    # Absent: the default refusal. Exactly 0: the application decides.
    my $refuse = PAGI::Utils::_refuse_option('CSRF', $config, 1);
    my $default = PAGI::Response::Text->new('CSRF token validation failed', status => 403);
    $self->{refuse} = !defined($refuse) ? $default->to_app
        : ref($refuse) ? $refuse
        : undef;
    PAGI::Utils::_reject_unknown_options('CSRF', $config,
        qw(cookie_name form_field httponly max_form_size refuse safe_methods secure
            session token_header trusted_origins));
}

# A 0-or-1 option; absent is 0.
sub _flag {
    my ($config, $name) = @_;
    my $value = $config->{$name} // 0;
    die "CSRF $name must be 0 or 1"
        unless !ref($value) && ($value eq '0' || $value eq '1');
    return $value + 0;
}

# trusted_origins as a lookup of lowercased origins: each a scheme and a
# host (a name or a bracketed IPv6 address) with an optional port, and
# nothing else. A default port is dropped, as browsers drop it from Origin,
# so the entry can match.
sub _trusted_origins {
    my ($origins) = @_;
    die 'CSRF trusted_origins must be an arrayref of origins' unless ref($origins) eq 'ARRAY';
    my %trusted;
    for my $origin (@$origins) {
        my ($scheme, $host, $port) = defined($origin) && !ref($origin)
            ? $origin =~ m{\A(https?)://([a-z0-9.-]+|\[[0-9a-f:.]+\])(?::([0-9]+))?\z}i
            : ();
        die 'CSRF trusted_origins entries must be a scheme and host, like https://app.example.com'
            unless defined $scheme;
        $scheme = lc $scheme;
        undef $port if defined($port) && $port eq ($scheme eq 'https' ? '443' : '80');
        $trusted{lc("$scheme://$host" . (defined $port ? ":$port" : ''))} = 1;
    }
    return \%trusted;
}

sub wrap {
    my ($self, $app) = @_;

    return async sub {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} eq 'websocket') {
            await $self->_websocket_handshake($app, $scope, $receive, $send);
            return;
        }
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # $stored is the token this request must match: the session's, or the
        # cookie's (undef when the client has none yet).
        my ($token, $stored) = $self->_token_for($scope);
        my %recorded = ('pagi.csrf_token' => $token);
        my $failure;
        unless ($self->{safe_methods}{$scope->{method}}) {
            $failure = $self->_origin_failure($scope)
                // $self->_failure_for($stored, $self->_get_submitted_token($scope));
            $recorded{'pagi.csrf_failure'} = $failure if defined $failure;
        }

        # A minted token is set on whatever response leaves, a refusal
        # included, so the client's next attempt can carry it. The event is
        # copied: an application may reuse its headers arrayref, and a
        # cookie added to it would reach every later client.
        my $wrapped_send = $self->{session} ? $self->_rotating_send($scope, $send)
            : defined $stored ? $send : async sub {
            my ($event) = @_;
            if ($event->{type} eq 'http.response.start') {
                my $cookie = "$self->{cookie_name}=$token; Path=/"
                    . ($self->{httponly} ? '; HttpOnly' : '')
                    . '; SameSite=Strict';
                $cookie .= "; Secure" if $self->{secure};
                $event = {
                    %$event,
                    headers => [@{$event->{headers} // []}, ['Set-Cookie', $cookie]],
                };
            }
            await $send->($event);
        };

        # A form post without the header: its token is read from the body,
        # through a recording receive, and whoever runs next -- the
        # application or the refusal -- is handed the replay of the whole
        # body.
        my $downstream = $receive;
        my $content_type = PAGI::Request->new($scope, $receive)->content_type;
        if (defined($failure) && $failure eq 'missing_token' && defined($self->{form_field})
                && ($content_type eq 'application/x-www-form-urlencoded' || $content_type eq 'multipart/form-data')) {
            my ($reading, $replaying) = record_receive($receive);
            $downstream = $replaying;
            my ($outcome, $value) = await $self->_form_token($scope, $reading);
            if ($outcome eq 'token') {
                $failure = $self->_failure_for($stored, $value);
            }
            elsif ($outcome ne 'missing' && $self->{refuse}) {
                # The body itself is the problem: answered here, not thrown --
                # in Compose an HTTP error thrown by application middleware is
                # a 500.
                my $error = $self->_body_error($outcome);
                await PAGI::Utils::invoke_app(
                    PAGI::Response::Text->new($error->client_message, status => $error->status_code),
                    $scope, $replaying, $wrapped_send);
                return;
            }
            if (defined $failure) { $recorded{'pagi.csrf_failure'} = $failure }
            else                  { delete $recorded{'pagi.csrf_failure'} }
        }
        my $target = defined($failure) && $self->{refuse} ? $self->{refuse} : $app;
        await $target->($self->modify_scope($scope, \%recorded), $downstream, $wrapped_send);
    };
}

# A form's token, read from $reading (the recording receive): ('token',
# $value) for the first form_field field, ('missing') for none, ('too_large')
# when the body runs past max_form_size first, ('malformed') for a body that
# cannot be read as a form. Anything else that fails propagates.
async sub _form_token {
    my ($self, $scope, $reading) = @_;
    my $request = PAGI::Request->new($scope, $reading);
    return await $self->_multipart_token($request, $reading) if $request->content_type eq 'multipart/form-data';
    my $body;
    my $read = eval {
        $body = await PAGI::Request->new($scope, _counting_receive($reading, $self->{max_form_size}))->body;
        1;
    };
    unless ($read) {
        my $error = $@;
        return ('too_large') if blessed($error) && $error->isa('PAGI::Middleware::CSRF::_OverBudget');
        die $error;
    }
    # The first occurrence decides, parsed as form_params parses it.
    for my $pair (split /[&;]/, $body) {
        my ($name, $value) = split /=/, $pair, 2;
        next unless defined($name) && length($name)
            && PAGI::Request::_url_decode($name) eq $self->{form_field};
        return ('token', PAGI::Request::_url_decode($value // ''));
    }
    return ('missing');
}

# A multipart form's token, read in byte order: the events from $reading are
# fed to the parser in slices no longer than the budget left, and the parts
# decide as they come -- the form_field part's value, a file before it
# (missing), the parser's error (malformed) -- and once decided nothing after
# counts: no limit is applied to a later part here, the route's own parse
# applies its limits to the whole body. So the answer is the same however the
# client's bytes were split into events. Nothing is read after deciding.
async sub _multipart_token {
    my ($self, $request, $reading) = @_;
    my $parameters = $request->headers->content_type_parameters;
    my $boundary = defined($parameters) ? $parameters->{boundary} : undef;
    return ('malformed') unless defined($boundary) && length($boundary);

    my ($outcome, $value, $collecting, $collected, $fed) = (undef, undef, 0, '', 0);
    # The parser takes fewer boundary characters than RFC 2046 allows (no
    # space, no '@'); one it refuses is a body that cannot be parsed, as the
    # route's own parse would find. Any other failure propagates.
    my $parser = eval { HTTP::MultiPartParser->new(
        boundary  => $boundary,
        on_header => sub {
            my ($lines) = @_;
            return if defined $outcome;
            my $part = PAGI::Request::MultipartStream::_disposition($lines);
            if (defined $part->{filename}) { $outcome = 'missing'; return }
            $collecting = defined($part->{name}) && $part->{name} eq $self->{form_field};
        },
        on_body => sub {
            my ($chunk, $final) = @_;
            return if defined($outcome) || !$collecting;
            $collected .= $chunk;
            ($outcome, $value) = ('token', $collected) if $final;
        },
        on_error => sub { $outcome //= 'malformed' },
    ) };
    unless ($parser) {
        my $error = $@;
        return ('malformed') if $error =~ /\bboundary\b/;
        die $error;
    }
    my $left = $self->{max_form_size};
    until (defined $outcome) {
        my $event = await $reading->();
        if (($event->{type} // '') ne 'http.request') {
            # A disconnect after the closing boundary ends a complete body, as
            # the route's own parse takes it: no token part. One before it is
            # the client leaving mid-body, as the route's own read would see.
            if ($fed) { $parser->finish }
            if (!defined($outcome) || $outcome ne 'malformed') {
                $outcome //= 'missing';
                last;
            }
            my $connection = $request->connection;
            my $reason = ($connection ? $connection->disconnect_reason : undef) // 'disconnect';
            die "Request body incomplete: client disconnected mid-body ($reason)\n";
        }
        my $bytes = $event->{body} // '';
        while (length($bytes) && !defined($outcome)) {
            if ($left <= 0) { $outcome = 'too_large'; last }
            my $slice = substr($bytes, 0, $left, '');
            $left -= length $slice;
            $fed = 1;
            $parser->parse($slice);
        }
        next if defined $outcome;
        unless ($event->{more}) {
            $parser->finish;
            $outcome //= 'missing';
        }
    }
    return ($outcome, $value);
}

# The receive a form is read through: past $budget bytes of body it dies with
# an _OverBudget, which _form_token reports as too_large. The event is already
# recorded, so the replay still delivers it.
sub _counting_receive {
    my ($receive, $budget) = @_;
    my $seen = 0;
    return async sub {
        my $event = await $receive->();
        if (($event->{type} // '') eq 'http.request') {
            $seen += length($event->{body} // '');
            die bless({}, 'PAGI::Middleware::CSRF::_OverBudget') if $seen > $budget;
        }
        return $event;
    };
}

# The client's error for a form body the middleware could not read, as the
# route's own read would raise it.
sub _body_error {
    my ($self, $outcome) = @_;
    return $outcome eq 'too_large'
        ? PAGI::Exception::RequestBody->new(status_code => 413, reason => 'too_large', message => 'Request body too large')
        : PAGI::Exception::RequestBody->new(status_code => 400, reason => 'invalid_multipart',
            message => 'The multipart request body could not be parsed.');    # the route's own parser's words
}

# Why a submitted token fails to match, or undef when it passes. Compared
# in constant time.
sub _failure_for {
    my ($self, $cookie_token, $submitted) = @_;
    return 'missing_cookie' unless defined($cookie_token) && length($cookie_token);
    return 'missing_token' unless defined($submitted) && length($submitted);
    return 'mismatch' unless secure_compare($submitted, $cookie_token);
    return undef;
}

# Under session => 1: when the application regenerated the session (at
# login), the session gets a new token as the response starts -- before
# Session, outside this middleware, saves it -- so a token known before
# login, perhaps through a planted session cookie, is useless after it.
sub _rotating_send {
    my ($self, $scope, $send) = @_;
    return async sub {
        my ($event) = @_;
        my $session = $scope->{'pagi.session'};
        $session->{csrf_token} = $self->_generate_token()
            if $event->{type} eq 'http.response.start' && $session->{_regenerated};
        await $send->($event);
    };
}

# A WebSocket handshake carries the browser's cookies and is outside CORS, so
# a page on another site could otherwise open an authenticated socket
# (cross-site WebSocket hijacking): it gets the same origin check as an unsafe
# request, and a failure is refused before accept, like any refusal. There is
# no token check -- a browser cannot add headers to a handshake. The token is
# offered for csrf($ws) without side effects: no cookie is set and no session
# is created.
async sub _websocket_handshake {
    my ($self, $app, $scope, $receive, $send) = @_;
    my $session = $scope->{'pagi.session'};
    my $token = ($self->{session}
            ? (ref($session) eq 'HASH' ? $session->{csrf_token} : undef)
            : $self->_get_cookie_token($scope))
        // $self->_generate_token();
    my %recorded = ('pagi.csrf_token' => $token);
    my $failure = $self->_origin_failure($scope);
    $recorded{'pagi.csrf_failure'} = $failure if defined $failure;
    my $target = defined($failure) && $self->{refuse} ? $self->{refuse} : $app;
    await $target->($self->modify_scope($scope, \%recorded), $receive, $send);
}

# The token for this request and the one it must match. Under session => 1
# both are the session's, created there on first use; otherwise the client's
# existing cookie -- never a regenerated one, so a token the client already
# holds still has something to match -- or a fresh token when it has none.
sub _token_for {
    my ($self, $scope) = @_;
    if ($self->{session}) {
        my $session = $scope->{'pagi.session'};
        die 'CSRF session => 1 needs Session middleware outside it (missing pagi.session)'
            unless ref($session) eq 'HASH';
        my $token = $session->{csrf_token} //= $self->_generate_token();
        return ($token, $token);
    }
    my $cookie = $self->_get_cookie_token($scope);
    return ($cookie // $self->_generate_token(), $cookie);
}

# Why an unsafe request fails the origin check, or undef when it passes.
# Modelled on Go's net/http CrossOriginProtection: Sec-Fetch-Site decides
# when present; otherwise Origin's host and port must equal Host (the
# scheme is not compared: a TLS-terminating proxy leaves the scope http).
# A request with neither header is left to the token check.
sub _origin_failure {
    my ($self, $scope) = @_;
    my $origin = $self->_get_header($scope, 'origin');
    return undef if defined($origin) && $self->{trusted_origins}{lc $origin};

    my $site = $self->_get_header($scope, 'sec-fetch-site');
    if (defined $site) {
        $site = lc $site;
        return $site eq 'same-origin' || $site eq 'none' ? undef : 'cross_origin';
    }
    return undef unless defined $origin;

    my ($authority) = $origin =~ m{\A[a-z][a-z0-9+.-]*://([^/?#]+)\z}i;
    my $host = $self->_get_header($scope, 'host');
    return undef if defined($authority) && defined($host) && lc($authority) eq lc($host);
    return 'cross_origin';
}

# 32 bytes from the system's secure random source, as 64 hex characters.
sub _generate_token {
    return unpack('H*', secure_random_bytes(32));
}

sub _get_cookie_token {
    my ($self, $scope) = @_;

    my $cookie_header = $self->_get_header($scope, 'cookie');
    return unless $cookie_header;

    my $name = $self->{cookie_name};
    if ($cookie_header =~ /(?:^|;\s*)\Q$name\E=([^;]+)/) {
        return $1;
    }
    return;
}

sub _get_submitted_token {
    my ($self, $scope) = @_;
    return $self->_get_header($scope, $self->{token_header});
}

sub _get_header {
    my ($self, $scope, $name) = @_;

    $name = lc($name);
    for my $h (@{$scope->{headers} // []}) {
        return $h->[1] if lc($h->[0]) eq $name;
    }
    return;
}

1;

__END__

=head1 USAGE

The CSRF middleware uses a double-submit token: it issues a random token
in a cookie (or keeps it in the session), and an unsafe request is valid
only if it also carries the same token another way -- a request header or a
form field. The page's script can read the cookie, or the page can carry
the token itself (required under C<httponly> or C<session>).

=head2 Header flow (scripts and JSON APIs)

Use this when the client can set a custom request header (fetch, XHR, an
API client). The middleware never reads such a request's body.

Render the token into the page once (a C<< <meta> >> tag is the usual spot),
reading it from the CSRF facade (or let the script read the cookie, unless
C<httponly> is on):

    my $guard = csrf($request);
    my $token = $guard->token;

    <meta name="csrf-token" content="<%= $token %>">

Then have client-side script read the meta tag and send it back as the
configured header:

    const token = document.querySelector('meta[name="csrf-token"]').content;
    fetch('/api/resource', {
        method: 'POST',
        headers: { 'X-CSRF-Token': token },
    });

Angular and Axios read an C<XSRF-TOKEN> cookie and send C<X-XSRF-TOKEN>
on their own: C<< cookie_name => 'XSRF-TOKEN', token_header => 'X-XSRF-TOKEN' >>.

=head2 Form flow (plain HTML forms)

A plain C<< <form> >> POST cannot add a header, so it carries the token in
a hidden C<csrf_token> field. Run the middleware with C<form_field>, and
render the token into each form:

    <input type="hidden" name="csrf_token" value="<%= csrf($request)->token %>">

    route('/tasks' => \&create, methods => ['POST']),
    ...
    middleware => [middleware('CSRF', form_field => 'csrf_token')],

The middleware reads the field from the body -- a urlencoded body whole, at
most C<max_form_size> bytes, a multipart body only as far as its token part
-- and refuses a missing or wrong one before any route runs. The route is
handed a receive that delivers the whole body again, and reads its fields as
usual:

    my $form = await $request->form_params;

The form is therefore parsed twice, once here for one field and once by the
route. One token serves every form on the page. Were a form to carry two
token fields, the first decides (Django's middleware takes the last), so
that a multipart upload can stream past its token.

=head2 Streamed uploads

A route that streams a form upload with C<multipart_stream> needs nothing
of its own. The form puts its hidden token field before the file -- browsers
send fields in document order -- and the middleware reads only as far as
it; the route then streams the upload, the token part first, as it arrives.
A file part before the token is refused (C<missing_token>). A client that
can set the header (a script uploading with fetch) sends it instead, and
then nothing is read here. L<PAGI::Tools::Cookbook/CSRF on a streamed
upload> has a complete application.

=head1 SECURITY

Without C<session =E<gt> 1> the token is a double-submit cookie: the
middleware checks that the request's header (or form
field) equals the request's own C<csrf_token> cookie. Anyone who can write
cookies for your domain can plant a token they know -- OWASP: the pattern
"is bypassable by an attacker who can write cookies on the target domain
(e.g., via a vulnerable sibling subdomain, DNS takeover, or plaintext-HTTP
cookie injection on a non-C<__Host-> cookie)". The origin check narrows
this: browsers send C<Sec-Fetch-Site> over HTTPS and C<Origin> on a POST,
so a forged request from a sibling subdomain is still refused, but a client
that sends neither header is protected by the token alone.

=over 4

=item * C<session =E<gt> 1> binds the token to the session, so a planted
CSRF cookie is useless, and replaces it when the session is regenerated at
login, so neither is a planted session cookie's token. Use it whenever the
application has a session.

=item * Over HTTPS, C<< cookie_name => '__Host-csrf_token', secure => 1 >>
stops subdomains overwriting the cookie (browsers refuse a C<__Host->
cookie set with a C<Domain>, without C<Secure>, or off C<Path=/>).

=item * The origin check compares C<Origin> with the C<Host> header this
middleware is handed. When a proxy rewrites C<Host>, put
L<PAGI::Middleware::ReverseProxy> outside this middleware and have the proxy
send C<X-Forwarded-Host> with the public host, including any non-default
port (ReverseProxy restores C<Host> only from that header, and only from a
trusted proxy); or list the public origin in C<trusted_origins>.

=back

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::CSRF> - request-first and raw-scope token access and verification

=cut
