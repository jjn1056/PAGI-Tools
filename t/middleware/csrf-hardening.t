use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Middleware::CSRF;

# Runs one request through $mw around an app that answers 200 'app'.
# Returns the sent events and the scopes the app saw.
sub run_csrf {
    my ($mw, %request) = @_;
    my (@sent, @seen);
    my $wrapped = $mw->wrap(async sub {
        my ($scope, $receive, $send) = @_;
        push @seen, $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'app', more => 0 });
    });
    $wrapped->(
        {
            type    => $request{type} // 'http',
            path    => '/submit',
            method  => $request{method} // 'POST',
            headers => $request{headers} // [],
            %{ $request{scope} // {} },
        },
        async sub { { type => 'http.disconnect' } },
        async sub { my ($event) = @_; push @sent, $event; return },
    )->get;
    return (\@sent, \@seen);
}

# The CSRF cookie set on the first sent event, or undef.
sub set_cookie_of {
    my ($sent) = @_;
    my ($cookie) = map { $_->[1] }
        grep { lc($_->[0]) eq 'set-cookie' && $_->[1] =~ /\Acsrf_token=/ }
        @{ $sent->[0]{headers} // [] };
    return $cookie;
}

subtest 'secret is removed' => sub {
    like(dies { PAGI::Middleware::CSRF->new(secret => 's') },
        qr/\QCSRF no longer takes a secret: its tokens are random; for tokens bound to the session use session => 1\E/,
        'passing secret dies, naming the replacement');
    ok(lives { PAGI::Middleware::CSRF->new }, 'no option is required');
};

subtest 'tokens are random hex' => sub {
    my $mw = PAGI::Middleware::CSRF->new;
    my (undef, $first)  = run_csrf($mw, method => 'GET');
    my (undef, $second) = run_csrf($mw, method => 'GET');
    like($first->[0]{'pagi.csrf_token'}, qr/\A[0-9a-f]{64}\z/, '64 lowercase hex characters');
    isnt($first->[0]{'pagi.csrf_token'}, $second->[0]{'pagi.csrf_token'}, 'a fresh token per new client');
};

subtest 'the cookie is readable by JavaScript by default' => sub {
    my ($sent) = run_csrf(PAGI::Middleware::CSRF->new, method => 'GET');
    like(set_cookie_of($sent), qr/\Acsrf_token=[0-9a-f]{64}; Path=\/; SameSite=Strict\z/,
        'no HttpOnly');
};

subtest 'httponly => 1 flags it' => sub {
    my ($sent) = run_csrf(PAGI::Middleware::CSRF->new(httponly => 1), method => 'GET');
    like(set_cookie_of($sent), qr/\Acsrf_token=[0-9a-f]{64}; Path=\/; HttpOnly; SameSite=Strict\z/,
        'HttpOnly when asked');
    like(dies { PAGI::Middleware::CSRF->new(httponly => 'yes') },
        qr/\QCSRF httponly must be 0 or 1\E/, 'any other value dies');
};

# A POST whose cookie and header carry the same token, plus extra headers.
sub post_with_token {
    my ($mw, @extra) = @_;
    return run_csrf($mw, headers => [
        ['host', 'example.com'], ['cookie', 'csrf_token=abc'], ['x-csrf-token', 'abc'], @extra,
    ]);
}

subtest 'the origin check' => sub {
    my $mw = PAGI::Middleware::CSRF->new;
    my @cases = (
        ['Sec-Fetch-Site same-origin',            200, ['sec-fetch-site', 'same-origin']],
        ['Sec-Fetch-Site none',                   200, ['sec-fetch-site', 'none']],
        ['Sec-Fetch-Site same-site',              403, ['sec-fetch-site', 'same-site']],
        ['Sec-Fetch-Site cross-site',             403, ['sec-fetch-site', 'cross-site']],
        ['Sec-Fetch-Site in mixed case',          200, ['sec-fetch-site', 'Same-Origin']],
        ['same-origin wins over a foreign Origin', 200, ['sec-fetch-site', 'same-origin'], ['origin', 'https://evil.example']],
        # https Origin against a scope left http (no scheme): the scheme is not compared
        ['Origin equal to Host',                  200, ['origin', 'https://example.com']],
        ['Origin equal to Host, other case',      200, ['origin', 'https://Example.COM']],
        ['Origin on another host',                403, ['origin', 'https://evil.example']],
        ['Origin on another port',                403, ['origin', 'https://example.com:8443']],
        ['Origin null',                           403, ['origin', 'null']],
        ['neither header',                        200],
    );
    for my $case (@cases) {
        my ($label, $status, @extra) = @$case;
        my ($sent) = post_with_token($mw, @extra);
        is($sent->[0]{status}, $status, "$label: $status");
    }
};

subtest 'the origin check compares the host header it is handed' => sub {
    my ($sent) = run_csrf(PAGI::Middleware::CSRF->new, headers => [
        ['host', 'public.example'], ['cookie', 'csrf_token=abc'], ['x-csrf-token', 'abc'],
        ['origin', 'https://public.example'],
    ]);
    is($sent->[0]{status}, 200, 'an outer layer that rewrote host is honoured');
};

subtest 'safe methods are not origin-checked' => sub {
    my ($sent) = run_csrf(PAGI::Middleware::CSRF->new, method => 'GET',
        headers => [['host', 'example.com'], ['sec-fetch-site', 'cross-site']]);
    is($sent->[0]{status}, 200, 'a cross-site GET passes');
};

subtest 'trusted_origins' => sub {
    my $mw = PAGI::Middleware::CSRF->new(trusted_origins => ['https://app.example.com']);
    my ($sent) = post_with_token($mw, ['sec-fetch-site', 'cross-site'], ['origin', 'https://app.example.com']);
    is($sent->[0]{status}, 200, 'a trusted origin passes even cross-site');
    ($sent) = post_with_token($mw, ['sec-fetch-site', 'cross-site'], ['origin', 'https://APP.example.com']);
    is($sent->[0]{status}, 200, 'matched without regard to case');
    ($sent) = run_csrf($mw, headers => [['host', 'example.com'], ['origin', 'https://app.example.com']]);
    is($sent->[0]{status}, 403, 'the token check still runs');
    like(dies { PAGI::Middleware::CSRF->new(trusted_origins => 'https://app.example.com') },
        qr/\QCSRF trusted_origins must be an arrayref of origins\E/, 'a plain string dies');
    for my $bad ('https://app.example.com/', 'app.example.com', 'https://app.example.com/path', '') {
        like(dies { PAGI::Middleware::CSRF->new(trusted_origins => [$bad]) },
            qr/\QCSRF trusted_origins entries must be a scheme and host, like https:\/\/app.example.com\E/,
            "'$bad' dies");
    }
    ok(lives { PAGI::Middleware::CSRF->new(trusted_origins => ['http://localhost:3000']) }, 'a port is fine');
    for my $bad ('https://*.example.com', 'https://user@app.example.com', 'ftp://app.example.com') {
        like(dies { PAGI::Middleware::CSRF->new(trusted_origins => [$bad]) },
            qr/\QCSRF trusted_origins entries must be a scheme and host\E/, "'$bad' dies");
    }
    ok(lives { PAGI::Middleware::CSRF->new(trusted_origins => ['http://[::1]:3000']) }, 'an IPv6 host is fine');
    my $default_port = PAGI::Middleware::CSRF->new(
        trusted_origins => ['https://app.example.com:443', 'http://localhost:80']);
    ($sent) = post_with_token($default_port, ['sec-fetch-site', 'cross-site'], ['origin', 'https://app.example.com']);
    is($sent->[0]{status}, 200, 'a default port is dropped, as browsers drop it from Origin');
    ($sent) = post_with_token($default_port, ['sec-fetch-site', 'cross-site'], ['origin', 'http://localhost']);
    is($sent->[0]{status}, 200, 'for http as well');
};

subtest 'a cross-origin request is recorded under refuse => 0' => sub {
    require PAGI::CSRF;
    my (undef, $seen) = post_with_token(PAGI::Middleware::CSRF->new(refuse => 0),
        ['sec-fetch-site', 'cross-site']);
    my $guard = PAGI::CSRF->new($seen->[0]);
    is($guard->failure, 'cross_origin', 'failure is cross_origin');
    is($guard->valid, 0, 'not valid');
    is($guard->verify('abc'), 0, 'verify refuses even the right token');
};

subtest 'session => 1 keeps the token in the session' => sub {
    my $mw = PAGI::Middleware::CSRF->new(session => 1);
    my $session = {};
    my ($sent, $seen) = run_csrf($mw, method => 'GET', scope => { 'pagi.session' => $session });
    like($session->{csrf_token}, qr/\A[0-9a-f]{64}\z/, 'a token is stored in the session');
    is($seen->[0]{'pagi.csrf_token'}, $session->{csrf_token}, 'and offered to the application');
    is(set_cookie_of($sent), undef, 'no CSRF cookie is set');

    my $token = $session->{csrf_token};
    ($sent) = run_csrf($mw, scope => { 'pagi.session' => $session },
        headers => [['x-csrf-token', $token]]);
    is($sent->[0]{status}, 200, 'the session token in the header passes');
    is($session->{csrf_token}, $token, 'and the token is kept');

    ($sent) = run_csrf($mw, scope => { 'pagi.session' => $session },
        headers => [['x-csrf-token', 'abc'], ['cookie', 'csrf_token=abc']]);
    is($sent->[0]{status}, 403, 'a planted cookie with a matching header fails');

    my (undef, $seen2) = run_csrf(PAGI::Middleware::CSRF->new(session => 1, refuse => 0),
        scope => { 'pagi.session' => { csrf_token => $token } }, headers => [['x-csrf-token', 'nope']]);
    is($seen2->[0]{'pagi.csrf_failure'}, 'mismatch', 'a wrong token is a mismatch');
    my (undef, $seen3) = run_csrf(PAGI::Middleware::CSRF->new(session => 1, refuse => 0),
        scope => { 'pagi.session' => {} });
    is($seen3->[0]{'pagi.csrf_failure'}, 'missing_token', 'no header is missing_token');
};

subtest 'session => 1 needs Session middleware' => sub {
    my $mw = PAGI::Middleware::CSRF->new(session => 1);
    like(dies { run_csrf($mw, method => 'GET') },
        qr/\QCSRF session => 1 needs Session middleware outside it (missing pagi.session)\E/,
        'an http request with no session dies');
    for my $type (qw(websocket sse)) {
        ok(lives { run_csrf($mw, type => $type, method => 'GET') }, "a $type scope passes through");
    }
};

subtest 'session and httponly do not combine' => sub {
    like(dies { PAGI::Middleware::CSRF->new(session => 1, httponly => 1) },
        qr/\QCSRF httponly has no cookie to flag under session => 1: the token lives in the session\E/,
        'dies at construction');
    like(dies { PAGI::Middleware::CSRF->new(session => 2) }, qr/\QCSRF session must be 0 or 1\E/,
        'session takes 0 or 1');
};

subtest 'session => 1 with the real Session middleware' => sub {
    require PAGI::Middleware::Session;
    require PAGI::Test::Client;
    my $app = PAGI::Middleware::Session->new->wrap(
        PAGI::Middleware::CSRF->new(session => 1)->wrap(async sub {
            my ($scope, $receive, $send) = @_;
            await $send->({ type => 'http.response.start', status => 200,
                headers => [['content-type', 'text/plain']] });
            await $send->({ type => 'http.response.body', body => $scope->{'pagi.csrf_token'}, more => 0 });
        }));
    my $client = PAGI::Test::Client->new(app => $app);
    my $token = $client->get('/')->text;
    like($token, qr/\A[0-9a-f]{64}\z/, 'the page gets a token');
    ok(!defined $client->cookie('csrf_token'), 'no CSRF cookie reaches the client');
    is($client->get('/')->text, $token, 'the session keeps the same token');
    is($client->post('/', headers => { 'X-CSRF-Token' => $token })->status, 200, 'it verifies');
    is($client->post('/', headers => { 'X-CSRF-Token' => 'abc' })->status, 403, 'another does not');
};

subtest 'session => 1 replaces the token when the session is regenerated' => sub {
    my $mw = PAGI::Middleware::CSRF->new(session => 1);
    my $session = { csrf_token => 'a' x 64, _regenerated => 1 };
    run_csrf($mw, method => 'GET', scope => { 'pagi.session' => $session });
    like($session->{csrf_token}, qr/\A[0-9a-f]{64}\z/, 'a fresh token');
    isnt($session->{csrf_token}, 'a' x 64, 'not the one held before');

    my $kept = { csrf_token => 'b' x 64 };
    run_csrf($mw, method => 'GET', scope => { 'pagi.session' => $kept });
    is($kept->{csrf_token}, 'b' x 64, 'an unregenerated session keeps its token');
};

subtest 'a token known before login is useless after it' => sub {
    require PAGI::Middleware::Session;
    require PAGI::Session;
    require PAGI::Test::Client;
    my $app = PAGI::Middleware::Session->new->wrap(
        PAGI::Middleware::CSRF->new(session => 1)->wrap(async sub {
            my ($scope, $receive, $send) = @_;
            my $session = PAGI::Session->new($scope);
            $session->regenerate if $scope->{path} eq '/login';
            $session->destroy    if $scope->{path} eq '/logout';
            await $send->({ type => 'http.response.start', status => 200,
                headers => [['content-type', 'text/plain']] });
            await $send->({ type => 'http.response.body', body => $scope->{'pagi.csrf_token'}, more => 0 });
        }));
    my $client = PAGI::Test::Client->new(app => $app);
    my $before = $client->get('/')->text;
    is($client->post('/login', headers => { 'X-CSRF-Token' => $before })->status, 200, 'log in');
    my $after = $client->get('/')->text;
    like($after, qr/\A[0-9a-f]{64}\z/, 'the session has a token after login');
    isnt($after, $before, 'and it is a new one');
    is($client->post('/', headers => { 'X-CSRF-Token' => $before })->status, 403,
        'the token from before login is refused');
    is($client->post('/', headers => { 'X-CSRF-Token' => $after })->status, 200, 'the new one passes');

    is($client->post('/logout', headers => { 'X-CSRF-Token' => $after })->status, 200, 'log out');
    my $fresh = $client->get('/')->text;
    isnt($fresh, $after, 'a destroyed session starts over with a new token');
};

done_testing;
