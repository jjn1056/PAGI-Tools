package PAGI::Middleware::CSRF;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future;
use Future::AsyncAwait;
use PAGI::Utils::Random qw(secure_random_bytes);
use PAGI::Utils::SecureCompare qw(secure_compare);
use PAGI::Request ();
use PAGI::Response::Text ();
use PAGI::Utils ();

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

    # Accept plain HTML forms: a form post without the header is left to
    # csrf_protect on its route, which reads the csrf_token field
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
form, which cannot set a header). The middleware never reads the body: the
body is the application's, and reaches it untouched. It checks the header;
an empty header counts as not sent. Without C<form_field> a request without
the header is refused. With it, an C<application/x-www-form-urlencoded> or
C<multipart/form-data> request without the header reaches the application
with C<missing_token> recorded, for L<PAGI::CSRF/csrf_protect> on its route
to read the field from the handler's own Request (see L</"Form flow (plain HTML forms)">). Any
other body without the header, JSON included, is refused.

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

The form field that L<PAGI::CSRF/csrf_protect> reads the token from, usually
C<csrf_token> (the name of the default cookie and of the session key). Set,
an unsafe form post that came without the header and passed the origin check
is not refused here: it is left to C<csrf_protect> on its route, and the
middleware records the field and C<refuse> in the scope for it. C<undef>, the
default, means no form flow: a request without the header is refused.
Anything else but a non-empty string dies.

=item * refuse (default: a 403 text response)

What answers an unsafe request that fails the origin or token check. Absent: a
C<403 text/plain> response, C<CSRF token validation failed>. An application
-- a Request handler (a coderef called with one
L<PAGI::Request>, returning a Response or an application) or an object
with C<to_app>, which
includes every L<PAGI::Response> -- answers instead, and can read the reason
with C<< csrf($request)->failure >>. Exactly C<0>: the middleware never refuses;
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
    # The field csrf_protect reads; absent or undef, there is no form flow.
    $self->{form_field} = $config->{form_field};
    die 'CSRF form_field must be a field name, like csrf_token, or undef for no form flow'
        if defined($self->{form_field}) && (ref($self->{form_field}) || !length($self->{form_field}));
    die "CSRF 'body_buffer' was removed: it never reads the body"
        if exists $config->{body_buffer};

    # Absent: the default refusal. Exactly 0: the application decides.
    # refuse_given is the option as given, for csrf_protect, which answers
    # with it after reading the body: a Request handler is then called with
    # that same Request.
    my $refuse = PAGI::Utils::_refuse_option('CSRF', $config, 1);
    my $default = PAGI::Response::Text->new('CSRF token validation failed', status => 403);
    $self->{refuse} = !defined($refuse) ? $default->to_app
        : ref($refuse) ? $refuse
        : undef;
    $self->{refuse_given} = !defined($refuse) ? $default : $config->{refuse};
    PAGI::Utils::_reject_unknown_options('CSRF', $config,
        qw(cookie_name form_field httponly refuse safe_methods secure session
            token_header trusted_origins));
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
        $recorded{'pagi.csrf_form'} = { field => $self->{form_field}, refuse => $self->{refuse_given} }
            if defined($self->{form_field}) && $self->{refuse};
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

        # A form post without the header is left to csrf_protect, which
        # reads the field from the handler's Request; the body is never read
        # here.
        my $for_the_handler = defined($failure) && $failure eq 'missing_token'
            && defined($self->{form_field}) && PAGI::Request->new($scope, $receive)->is_form;
        my $target = defined($failure) && $self->{refuse} && !$for_the_handler
            ? $self->{refuse} : $app;
        await $target->($self->modify_scope($scope, \%recorded), $receive, $wrapped_send);
    };
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
a hidden C<csrf_token> field. Run the middleware with C<form_field> and wrap
each form route's handler in L<PAGI::CSRF/csrf_protect>:

    use PAGI::CSRF qw(csrf csrf_protect);

    <input type="hidden" name="csrf_token" value="<%= csrf($request)->token %>">

    route('/tasks' => csrf_protect(\&create), methods => ['POST']),
    ...
    middleware => [middleware('CSRF', form_field => 'csrf_token')],

C<csrf_protect> reads the field from the handler's own Request, refuses a
missing or wrong one before the handler runs, and the handler reads its
fields as usual, from that same parse:

    my $form = await $request->form_params;

One token serves every form on the page. A form route without
C<csrf_protect> accepts a post without the token: only the origin check
stands in front of it.

=head2 Streamed uploads

A route that streams a form upload with C<multipart_stream> does not use
C<csrf_protect>, which would parse the whole form first. A client that can
set the header (a script uploading with fetch) sends it, and the middleware
checks it. A plain HTML form cannot: when the request sent no header
(C<< csrf($request)->failure >> is C<missing_token>), take the token from
the stream's first part and check it with C<< csrf($request)->verify >>,
which also fails a cross-origin request. Refuse any other failure, such as a
header that did not match. L<PAGI::Tools::Cookbook/CSRF on a streamed
upload> has a complete application. In a raw-scope application the same
check is:

    my $guard = csrf($scope);
    my $valid = $guard->verify($token_from_the_stream);

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
