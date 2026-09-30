use v5.40;

# Inline three-route variant for comparison with the Python learning app.
use Crypt::JWT qw(encode_jwt decode_jwt);

use PAGI::Auth qw(auth auth_result unauth_result www_authenticate);
use PAGI::Auth::SimpleUser;
use PAGI::Compose qw(compose);
use PAGI::Response qw(json_response file_response);
use PAGI::Routing qw(route middleware);
use PAGI::Utils qw(app_path);

# Public teaching key and dummy login, matching the Python learning example.
my $secret = 'learning-only-secret-not-for-production-0123456789';
my $page = app_path('public', 'index.html');

# Pass this callback directly, or supply an object with authenticate instead.
sub jwt_backend ($request) {
    my $token;
    my $parsed = eval {
        $token = $request->bearer_token(raise_on_error => 1);
        1;
    };
    return unauth_result(failure => {
        code => 'malformed_authorization',
        message => 'Expected one Authorization header containing a Bearer token.',
    }) unless $parsed;
    return unauth_result() unless defined $token;

    my $claims;
    my $verified = eval {
        $claims = decode_jwt(
            token        => $token,
            key          => $secret,
            accepted_alg => 'HS256',
            verify_exp   => 1,
        );
        1;
    };

    # A guest is an explicit result. Middleware establishes it and continues.
    # These failures mean token rejection; the malformed-header case is above.
    # Application response code can distinguish rejection from absent credentials.
    return unauth_result(
        failure => {
            message => 'The token is invalid or expired.',
        },
    ) unless $verified;

    return unauth_result(
        failure => {
            message => 'The token must identify a user.',
        },
    ) unless ref($claims) eq 'HASH'
        && defined($claims->{sub})
        && !ref($claims->{sub})
        && length($claims->{sub});

    return auth_result(
        user => PAGI::Auth::SimpleUser->new(
            identity     => $claims->{sub},
            display_name => $claims->{sub},
        ),
        scopes => ['authenticated'],
    );
}

sub login ($request) {
    # A real login would verify the caller's credentials before issuing a token.
    my $token = encode_jwt(
        key => $secret,
        alg => 'HS256',
        payload => {
            sub  => 'alice_dev',
            exp  => time + 3600,
            role => 'developer',
        },
    );

    return json_response(
        { token => $token },
        headers => ['Cache-Control' => 'no-store'],
    );
}

sub protected_route ($request) {
    my $context = auth($request);
    my $user = $context->user;

    # This endpoint owns its authentication check, just like the Python example.
    unless ($user->is_authenticated) {
        my $failure = $context->failure;
        my $malformed = $failure
            && ($failure->code // '') eq 'malformed_authorization';
        my @params = (realm => 'jwt-sandbox');
        push @params, error => ($malformed ? 'invalid_request' : 'invalid_token')
            if $failure;

        return json_response(
            { error => $malformed ? 'Malformed Authorization header.'
                     : 'Please sign in to access the vault.' },
            status  => $malformed ? 400 : 401,
            headers => [
                'WWW-Authenticate' => www_authenticate('Bearer', @params),
            ],
        );
    }

    return json_response({
        message            => 'Success! You accessed the vault.',
        user_authenticated => $user->is_authenticated ? \1 : \0,
        username           => $user->identity,
        assigned_scopes    => $context->credentials->scopes,
    });
}

compose(
    # Authentication establishes context; each endpoint decides whether to require it.
    middleware => [
        middleware('Authentication',
            backend => \&jwt_backend,
        ),
    ],
    routes => [
        route('/' => file_response(
            $page,
            content_type => 'text/html; charset=utf-8',
        ), methods => ['GET']),

        route('/login' => \&login, methods => ['POST']),
        route('/protected' => \&protected_route, methods => ['GET']),
    ],
);
