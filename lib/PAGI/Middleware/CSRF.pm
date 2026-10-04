package PAGI::Middleware::CSRF;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future;
use Future::AsyncAwait;
use PAGI::Utils::Random qw(secure_random_bytes);
use PAGI::Utils::SecureCompare qw(secure_compare);
use PAGI::Response::Text ();
use PAGI::Utils ();

=head1 NAME

PAGI::Middleware::CSRF - Cross-Site Request Forgery protection middleware

=head1 SYNOPSIS

    use PAGI::Compose qw(compose);
    use PAGI::Response qw(response);
    use PAGI::Routing qw(middleware);

    # Refuse a failed check with a 403 text response (the default)
    middleware('CSRF');

    # Refuse it with your own application or Response
    middleware('CSRF',
        refuse => response('JSON', { detail => 'CSRF token validation failed' }, status => 403));

    # Let the application decide: every request reaches it, with the outcome
    # recorded for csrf($request)->valid and ->failure
    middleware('CSRF', refuse => 0);

    # Keep the token in the session (Session middleware must wrap this one)
    middleware('CSRF', session => 1);

L<PAGI::CSRF/SYNOPSIS> shows both modes in full, as complete applications.

=head1 DESCRIPTION

PAGI::Middleware::CSRF provides protection against Cross-Site Request
Forgery attacks by validating tokens on state-changing requests. Its default
refusal is a plain 403 text response; C<refuse> replaces it, or lets the
application decide. L<PAGI::CSRF/SYNOPSIS> shows both, as complete
applications.

Every unsafe request first passes an origin check, modelled on Go's
C<CrossOriginProtection>: a C<Sec-Fetch-Site> header must be C<same-origin>
or C<none>; without one, an C<Origin> header's host and port must equal the
C<Host> header. An origin in C<trusted_origins> always passes, and a request
with neither header (a non-browser client, or an older browser) is left to
the token check. A failure is recorded as C<cross_origin>.

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

=item * trusted_origins (default: [])

Origins, besides the request's own, whose unsafe requests may pass the
origin check -- for example an application on C<https://app.example.com>
posting to an API on C<https://api.example.com>. Each is a scheme and host
with an optional port (C<http://localhost:3000>), nothing else. The token
check still applies.

=item * refuse (default: a 403 text response)

What answers an unsafe request whose token check fails. Absent: a
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

    # Absent: the default refusal. Exactly 0: the application decides.
    my $refuse = PAGI::Utils::_refuse_option('CSRF', $config, 1);
    $self->{refuse} = !defined($refuse) ? PAGI::Response::Text->new(
            'CSRF token validation failed', status => 403,
        )->to_app
        : ref($refuse) ? $refuse
        : undef;
    PAGI::Utils::_reject_unknown_options('CSRF', $config,
        qw(cookie_name httponly refuse safe_methods secure session token_header trusted_origins));
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
# host with an optional port, and nothing else.
sub _trusted_origins {
    my ($origins) = @_;
    die 'CSRF trusted_origins must be an arrayref of origins' unless ref($origins) eq 'ARRAY';
    my %trusted;
    for my $origin (@$origins) {
        die 'CSRF trusted_origins entries must be a scheme and host, like https://app.example.com'
            unless defined($origin) && !ref($origin) && $origin =~ m{\Ahttps?://[^/?#\s]+\z}i;
        $trusted{lc $origin} = 1;
    }
    return \%trusted;
}

sub wrap {
    my ($self, $app) = @_;

    return async sub {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # $stored is the token this request must match: the session's, or the
        # cookie's (undef when the client has none yet).
        my ($token, $stored) = $self->_token_for($scope);
        my %recorded = ('pagi.csrf_token' => $token);
        unless ($self->{safe_methods}{$scope->{method}}) {
            my $failure = $self->_origin_failure($scope)
                // $self->_failure_for($stored, $self->_get_submitted_token($scope));
            $recorded{'pagi.csrf_failure'} = $failure if defined $failure;
        }

        # A minted token is set on whatever response leaves, a refusal
        # included, so the client's next attempt can carry it. The event is
        # copied: an application may reuse its headers arrayref, and a
        # cookie added to it would reach every later client.
        my $wrapped_send = $self->{session} || defined $stored ? $send : async sub {
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

        my $target = exists($recorded{'pagi.csrf_failure'}) && $self->{refuse}
            ? $self->{refuse} : $app;
        await $target->($self->modify_scope($scope, \%recorded), $receive, $wrapped_send);
    };
}

# Why an unsafe request's header check fails, or undef when it passes.
# Compared in constant time.
sub _failure_for {
    my ($self, $cookie_token, $submitted) = @_;
    return 'missing_cookie' unless defined($cookie_token) && length($cookie_token);
    return 'missing_token' unless defined($submitted) && length($submitted);
    return 'mismatch' unless secure_compare($submitted, $cookie_token);
    return undef;
}

# 32 bytes from the system's secure random source, as 64 hex characters.
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
in a cookie, and an unsafe request is valid only if it also carries the
same token another way -- a request header (the default) or a form field
(C<refuse =E<gt> 0>). The page's script can read the cookie, or the page
can carry the token itself (required under C<httponly> or C<session>).

=head2 Header flow (the default)

Use this for JSON/AJAX APIs, where the client can set a custom request
header. The middleware validates the header itself; the app is never called
on a mismatch.

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

=head2 Form flow (refuse => 0)

Use this for server-rendered HTML forms. A plain C<< <form> >> POST has no
way to add a custom header, so the default would 403 every such submission --
that's precisely why C<refuse =E<gt> 0> exists: the middleware issues the
token (on every method, including the POST itself) and records its header
check, but never refuses; the app validates once it has parsed the submitted
params.

Embed the token as a hidden field:

    my $guard = csrf($request);

    <input type="hidden" name="_csrf_token" value="<%= $guard->token %>">

Then, in the handler, verify the submitted value against the one the
middleware stashed in scope:

    use PAGI::Response qw(response);

    return response('Text', 'CSRF token validation failed', status => 403)
        unless $guard->verify($params->{_csrf_token});

The same helper works in a raw-scope application:

    my $guard = csrf($scope);
    my $token = $guard->token;
    my $valid = $guard->verify($params->{_csrf_token});

=head1 SECURITY

Without C<session =E<gt> 1> the token is a double-submit cookie: the
middleware checks that the request's header (or the application's form
field) equals the request's own C<csrf_token> cookie. Anyone who can write
cookies for your domain can plant a token they know -- OWASP: the pattern
"is bypassable by an attacker who can write cookies on the target domain
(e.g., via a vulnerable sibling subdomain, DNS takeover, or plaintext-HTTP
cookie injection on a non-C<__Host-> cookie)". The origin check narrows
this: current browsers send C<Sec-Fetch-Site>, so a forged request from a
sibling subdomain (C<same-site>) is still refused, but a client that sends
neither C<Sec-Fetch-Site> nor C<Origin> is protected by the token alone.

=over 4

=item * C<session =E<gt> 1> binds the token to the session, so a planted
cookie is useless. Use it whenever the application has a session.

=item * Over HTTPS, C<< cookie_name => '__Host-csrf_token', secure => 1 >>
stops subdomains overwriting the cookie (browsers refuse a C<__Host->
cookie set with a C<Domain>, without C<Secure>, or off C<Path=/>).

=item * The origin check compares C<Origin> with the C<Host> header this
middleware is handed. Put L<PAGI::Middleware::ReverseProxy> outside it when
a proxy rewrites C<Host>, or list the public origin in C<trusted_origins>.

=back

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::CSRF> - request-first and raw-scope token access and verification

=cut
