#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use IO::Async::Loop;
use MIME::Base64 qw(encode_base64);
use JSON::MaybeXS;
use Digest::SHA qw(hmac_sha256);

use PAGI::Middleware::Cookie;
use PAGI::Middleware::Session;
use PAGI::Middleware::Auth::Basic;
use PAGI::Middleware::Auth::Bearer;

my $loop = IO::Async::Loop->new;

sub make_scope {
    my (%opts) = @_;
    return {
        type    => 'http',
        method  => $opts{method} // 'GET',
        path    => $opts{path} // '/',
        headers => $opts{headers} // [],
    };
}

sub run_async (&) {
    my ($code) = @_;
    $loop->await($code->());
}

sub response_header_values {
    my ($event, $name) = @_;
    return map { $_->[1] }
        grep { lc($_->[0]) eq lc($name) } @{$event->{headers}};
}

sub assert_auth_rejection_settlement {
    my ($wrapped, $scope, $label) = @_;
    my ($start_gate, $body_gate) = (Future->new, Future->new);
    my @events;
    my $running = $wrapped->(
        $scope,
        sub { Future->done({ type => 'http.disconnect' }) },
        sub {
            push @events, $_[0];
            return @events == 1 ? $start_gate : $body_gate;
        },
    );

    is scalar(@events), 1, "$label emits only response start before settlement";
    ok !$running->is_ready, "$label waits for response-start settlement";
    $start_gate->done;
    is scalar(@events), 2, "$label emits one body after response-start settlement";
    ok !$running->is_ready, "$label waits for terminal-body settlement";
    $body_gate->done;
    is dies { $loop->await($running) }, undef,
        "$label completes after the terminal send settles";
    ok !$start_gate->is_cancelled && !$body_gate->is_cancelled,
        "$label does not cancel server-owned send Futures";
}

# ===================
# Cookie Middleware Tests
# ===================

subtest 'Cookie middleware - parses cookies' => sub {
    my $cookie = PAGI::Middleware::Cookie->new();

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $cookie->wrap($app);
    my $scope = make_scope(headers => [['Cookie', 'session=abc123; user=john']]);

    my $receive = async sub { {} };
    my $send = async sub { };

    run_async { $wrapped->($scope, $receive, $send) };

    ok exists $captured_scope->{'pagi.cookies'}, 'has cookies in scope';
    is $captured_scope->{'pagi.cookies'}{session}, 'abc123', 'session cookie parsed';
    is $captured_scope->{'pagi.cookies'}{user}, 'john', 'user cookie parsed';
};

subtest 'Cookie middleware - cookie jar sets response cookies' => sub {
    my $cookie = PAGI::Middleware::Cookie->new();

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $scope->{'pagi.cookie_jar'}->set('token', 'xyz789', httponly => 1, secure => 1);
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $cookie->wrap($app);
    my $scope = make_scope();

    my @events;
    my $receive = async sub { {} };
    my $send = async sub  {
        my ($event) = @_; push @events, $event };

    run_async { $wrapped->($scope, $receive, $send) };

    my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
    ok exists $headers{'set-cookie'}, 'has Set-Cookie header';
    like $headers{'set-cookie'}, qr/token=xyz789/, 'cookie value set';
    like $headers{'set-cookie'}, qr/HttpOnly/i, 'HttpOnly flag set';
    like $headers{'set-cookie'}, qr/Secure/i, 'Secure flag set';
};

# ===================
# Session Middleware Tests
# ===================

subtest 'Session middleware - creates new session' => sub {
    PAGI::Middleware::Session->clear_sessions();

    my $session = PAGI::Middleware::Session->new(secret => 'test-secret');

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        $scope->{'pagi.session'}{user_id} = 42;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $session->wrap($app);
    my $scope = make_scope();

    my @events;
    my $receive = async sub { {} };
    my $send = async sub  {
        my ($event) = @_; push @events, $event };

    run_async { $wrapped->($scope, $receive, $send) };

    ok exists $captured_scope->{'pagi.session'}, 'has session in scope';
    ok exists $captured_scope->{'pagi.session_id'}, 'has session_id';
    like $captured_scope->{'pagi.session_id'}, qr/^[a-f0-9]{64}$/, 'session ID is SHA256 hash';

    my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
    ok exists $headers{'set-cookie'}, 'has Set-Cookie header for new session';
};

subtest 'Session middleware - restores existing session' => sub {
    PAGI::Middleware::Session->clear_sessions();

    my $session_mw = PAGI::Middleware::Session->new(secret => 'test-secret');

    # First request - create session
    my $session_id;
    my $app1 = async sub  {
        my ($scope, $receive, $send) = @_;
        $session_id = $scope->{'pagi.session_id'};
        $scope->{'pagi.session'}{counter} = 1;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    run_async { $session_mw->wrap($app1)->(make_scope(), async sub { {} }, async sub { }) };

    # Second request - restore session
    my $captured_session;
    my $app2 = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_session = $scope->{'pagi.session'};
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $scope2 = make_scope(headers => [['Cookie', "pagi_session=$session_id"]]);
    run_async { $session_mw->wrap($app2)->($scope2, async sub { {} }, async sub { }) };

    is $captured_session->{counter}, 1, 'session data restored';
};

# ===================
# Auth::Basic Middleware Tests
# ===================

subtest 'Auth::Basic - returns 401 without credentials' => sub {
    my $auth = PAGI::Middleware::Auth::Basic->new(
        realm => 'Test',
        authenticator => sub { 1 },
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $auth->wrap($app);
    my $scope = make_scope();

    my @events;
    my $receive = async sub { {} };
    my $send = async sub  {
        my ($event) = @_; push @events, $event };

    run_async { $wrapped->($scope, $receive, $send) };

    is $events[0]{status}, 401, 'returns 401 Unauthorized';
    my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
    like $headers{'www-authenticate'}, qr/Basic realm="Test"/, 'has WWW-Authenticate header';
};

subtest 'Auth::Basic - accepts valid credentials' => sub {
    my $auth = PAGI::Middleware::Auth::Basic->new(
        authenticator => sub  {
        my ($user, $pass) = @_;
            return $user eq 'admin' && $pass eq 'secret';
        },
    );

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $auth->wrap($app);
    my $credentials = encode_base64('admin:secret', '');
    my $scope = make_scope(headers => [['Authorization', "Basic $credentials"]]);

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 200, 'request succeeds';
    is $captured_scope->{'pagi.auth'}{username}, 'admin', 'username in scope';
};

subtest 'Auth::Basic - rejects invalid credentials' => sub {
    my $auth = PAGI::Middleware::Auth::Basic->new(
        authenticator => sub  {
        my ($user, $pass) = @_;
            return $user eq 'admin' && $pass eq 'secret';
        },
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $auth->wrap($app);
    my $credentials = encode_base64('admin:wrong', '');
    my $scope = make_scope(headers => [['Authorization', "Basic $credentials"]]);

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 401, 'returns 401 for wrong password';
};

subtest 'Auth defaults negotiate missing, malformed, and rejected credentials' => sub {
    my @schemes = (
        {
            name      => 'Basic',
            challenge => 'Basic realm="Test", charset="UTF-8"',
            detail    => {
                missing   => 'Authentication is required to access this resource.',
                malformed => 'Authentication is required to access this resource.',
                rejected  => 'Authentication is required to access this resource.',
            },
            middleware => sub {
                return PAGI::Middleware::Auth::Basic->new(
                    realm => 'Test', authenticator => sub { 0 },
                );
            },
            headers => {
                missing   => [],
                malformed => [['Authorization', 'Digest credentials']],
                rejected  => [[
                    'Authorization',
                    'Basic ' . encode_base64('admin:wrong', ''),
                ]],
            },
        },
        {
            name      => 'Bearer',
            challenge => 'Bearer realm="Test"',
            detail    => {
                missing   => 'Token required',
                malformed => 'Invalid authorization header',
                rejected  => 'Invalid token',
            },
            middleware => sub {
                return PAGI::Middleware::Auth::Bearer->new(
                    realm => 'Test', validator => sub { undef },
                );
            },
            headers => {
                missing   => [],
                malformed => [['Authorization', 'Basic credentials']],
                rejected  => [['Authorization', 'Bearer rejected-token']],
            },
        },
    );
    my @representations = (
        ['application/problem+json', 'application/problem+json'],
        ['text/plain', 'text/plain; charset=utf-8'],
    );

    for my $scheme (@schemes) {
        for my $failure (qw(missing malformed rejected)) {
            for my $representation (@representations) {
                my ($accept, $content_type) = @$representation;
                my $wrapped = $scheme->{middleware}->()->wrap(async sub {
                    die "$scheme->{name} $failure credentials reached downstream\n";
                });
                my @events;
                my @headers = (
                    @{$scheme->{headers}{$failure}},
                    ['Accept', $accept],
                );

                run_async {
                    $wrapped->(
                        make_scope(headers => \@headers),
                        async sub { {} },
                        async sub { my ($event) = @_; push @events, $event },
                    )
                };

                my $label = "$scheme->{name} $failure with $accept";
                is scalar(@events), 2, "$label sends one complete response";
                is $events[0]{status}, 401, "$label retains status 401";
                is [response_header_values($events[0], 'WWW-Authenticate')],
                    [$scheme->{challenge}], "$label emits one exact challenge";
                is [response_header_values($events[0], 'Content-Type')],
                    [$content_type], "$label negotiates the requested representation";
                is [response_header_values($events[0], 'Cache-Control')],
                    ['no-store'], "$label uses the Pages error cache policy";
                is [response_header_values($events[0], 'Vary')],
                    ['Accept'], "$label varies negotiated responses on Accept";
                is [response_header_values($events[0], 'Content-Length')],
                    [length($events[1]{body})], "$label computes Content-Length";

                if ($accept eq 'application/problem+json') {
                    my $problem = eval { decode_json($events[1]{body}) };
                    ok $problem, "$label renders a JSON problem document";
                    if ($problem) {
                        is $problem->{status}, 401, "$label renders problem status";
                        is $problem->{title}, 'Unauthorized', "$label renders problem title";
                        is $problem->{detail}, $scheme->{detail}{$failure},
                            "$label renders the safe failure detail";
                    }
                }
                else {
                    is $events[1]{body},
                        "401 Unauthorized\n\n$scheme->{detail}{$failure}\n",
                        "$label renders the Pages text body";
                }
            }
        }
    }
};

subtest 'Auth realms quote backslash before quote and emit one challenge' => sub {
    my @realms = (
        ['team "blue"', 'team \\"blue\\"'],
        ['team\\blue',  'team\\\\blue'],
    );
    my @schemes = (
        [
            'Basic',
            sub {
                my ($realm) = @_;
                return PAGI::Middleware::Auth::Basic->new(
                    realm => $realm, authenticator => sub { 1 },
                );
            },
            sub { my ($quoted) = @_; return qq{Basic realm="$quoted", charset="UTF-8"} },
        ],
        [
            'Bearer',
            sub {
                my ($realm) = @_;
                return PAGI::Middleware::Auth::Bearer->new(
                    realm => $realm, validator => sub { {} },
                );
            },
            sub { my ($quoted) = @_; return qq{Bearer realm="$quoted"} },
        ],
    );

    for my $scheme (@schemes) {
        for my $realm (@realms) {
            my ($input, $quoted) = @$realm;
            my $wrapped = $scheme->[1]->($input)->wrap(async sub {
                die "$scheme->[0] missing credentials reached downstream\n";
            });
            my @events;

            run_async {
                $wrapped->(
                    make_scope(headers => [['Accept', 'text/plain']]),
                    async sub { {} },
                    async sub { my ($event) = @_; push @events, $event },
                )
            };

            is [response_header_values($events[0], 'WWW-Authenticate')],
                [$scheme->[2]->($quoted)],
                "$scheme->[0] safely quotes realm '$input' once";
        }
    }
};

subtest 'authentication-owned rejections await concrete response emission' => sub {
    my @cases = (
        [
            'Basic 401',
            PAGI::Middleware::Auth::Basic->new(
                realm => 'Test', authenticator => sub { 0 },
            ),
        ],
        [
            'Bearer 401',
            PAGI::Middleware::Auth::Bearer->new(
                realm => 'Test', validator => sub { undef },
            ),
        ],
    );

    for my $case (@cases) {
        my $wrapped = $case->[1]->wrap(async sub {
            die "$case->[0] rejection reached downstream";
        });
        assert_auth_rejection_settlement(
            $wrapped,
            make_scope(headers => [['Accept', 'text/plain']]),
            $case->[0],
        );
    }
};

subtest 'Auth realms reject field delimiters before any response event' => sub {
    my @bad_realms = (
        ["team\rred", 'CR'],
        ["team\nred", 'LF'],
        ["team\x09red", 'control'],
    );
    my @schemes = (
        [
            'Basic',
            sub {
                PAGI::Middleware::Auth::Basic->new(
                    realm => $_[0], authenticator => sub { 1 },
                )
            },
        ],
        [
            'Bearer',
            sub {
                PAGI::Middleware::Auth::Bearer->new(
                    realm => $_[0], validator => sub { {} },
                )
            },
        ],
    );

    for my $scheme (@schemes) {
        for my $bad (@bad_realms) {
            my @events;
            my $wrapped = $scheme->[1]->($bad->[0])->wrap(async sub {
                die "$scheme->[0] injected realm reached downstream\n";
            });
            my $future = $wrapped->(
                make_scope(),
                async sub { {} },
                async sub { my ($event) = @_; push @events, $event },
            );
            $loop->await($future);

            ok $future->is_failed, "$scheme->[0] $bad->[1] realm fails";
            like [$future->failure]->[0], qr/field-value|challenge/i,
                "$scheme->[0] $bad->[1] realm reports header validation";
            is \@events, [],
                "$scheme->[0] $bad->[1] realm emits no response event";
        }
    }
};

# ===================
# Auth::Bearer Middleware Tests
# ===================

sub make_jwt {
    my ($claims, $secret) = @_;
    my $header = encode_json({ alg => 'HS256', typ => 'JWT' });
    my $payload = encode_json($claims);

    my $header_b64 = _base64url_encode($header);
    my $payload_b64 = _base64url_encode($payload);
    my $signature = _base64url_encode(hmac_sha256("$header_b64.$payload_b64", $secret));

    return "$header_b64.$payload_b64.$signature";
}

sub _base64url_encode {
    my $data = shift;
    my $encoded = MIME::Base64::encode_base64($data, '');
    $encoded =~ tr{+/}{-_};
    $encoded =~ s/=+$//;
    return $encoded;
}

subtest 'Auth::Bearer - returns 401 without token' => sub {
    my $auth = PAGI::Middleware::Auth::Bearer->new(secret => 'test-secret');

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $auth->wrap($app);
    my $scope = make_scope();

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 401, 'returns 401 without token';
};

subtest 'Auth::Bearer - accepts valid JWT' => sub {
    my $secret = 'jwt-secret-key';
    my $auth = PAGI::Middleware::Auth::Bearer->new(secret => $secret);

    my $token = make_jwt({ sub => 'user123', exp => time() + 3600 }, $secret);

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $auth->wrap($app);
    my $scope = make_scope(headers => [['Authorization', "Bearer $token"]]);

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 200, 'request succeeds';
    is $captured_scope->{'pagi.auth'}{claims}{sub}, 'user123', 'JWT claims in scope';
};

subtest 'Auth::Bearer - rejects expired JWT' => sub {
    my $secret = 'jwt-secret-key';
    my $auth = PAGI::Middleware::Auth::Bearer->new(secret => $secret);

    my $token = make_jwt({ sub => 'user123', exp => time() - 3600 }, $secret);

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $auth->wrap($app);
    my $scope = make_scope(headers => [['Authorization', "Bearer $token"]]);

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 401, 'rejects expired token';
};

subtest 'Auth::Bearer - rejects invalid signature' => sub {
    my $auth = PAGI::Middleware::Auth::Bearer->new(secret => 'correct-secret');

    my $token = make_jwt({ sub => 'user123' }, 'wrong-secret');

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $auth->wrap($app);
    my $scope = make_scope(headers => [['Authorization', "Bearer $token"]]);

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 401, 'rejects invalid signature';
};

subtest 'Auth::Bearer - _secure_compare rejects undef inputs' => sub {
    my $auth = PAGI::Middleware::Auth::Bearer->new(secret => 'test-secret');

    ok(!$auth->_secure_compare(undef, 'abc'), 'undef vs string returns false');
    ok(!$auth->_secure_compare('abc', undef), 'string vs undef returns false');
    ok(!$auth->_secure_compare(undef, undef), 'undef vs undef returns false');
    ok(!$auth->_secure_compare('', undef), 'empty string vs undef returns false');
    ok(!$auth->_secure_compare(undef, ''), 'undef vs empty string returns false');
};

# ===================
# Session Cookie SameSite Tests
# ===================

subtest 'Session middleware - default cookie includes SameSite=Lax' => sub {
    PAGI::Middleware::Session->clear_sessions();

    my $session = PAGI::Middleware::Session->new(secret => 'test-secret');

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $session->wrap($app);
    my $scope = make_scope();

    my @events;
    my $receive = async sub { {} };
    my $send = async sub {
        my ($event) = @_; push @events, $event };

    run_async { $wrapped->($scope, $receive, $send) };

    my @set_cookies = map { $_->[1] }
        grep { lc($_->[0]) eq 'set-cookie' } @{$events[0]{headers}};
    ok scalar(@set_cookies), 'has Set-Cookie header';
    like $set_cookies[0], qr/SameSite=Lax/, 'default cookie includes SameSite=Lax';
};

subtest 'Session middleware - custom samesite overrides default' => sub {
    PAGI::Middleware::Session->clear_sessions();

    my $session = PAGI::Middleware::Session->new(
        secret => 'test-secret',
        cookie_options => {
            httponly => 1,
            path     => '/',
            samesite => 'Strict',
        },
    );

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $session->wrap($app);
    my $scope = make_scope();

    my @events;
    my $receive = async sub { {} };
    my $send = async sub {
        my ($event) = @_; push @events, $event };

    run_async { $wrapped->($scope, $receive, $send) };

    my @set_cookies = map { $_->[1] }
        grep { lc($_->[0]) eq 'set-cookie' } @{$events[0]{headers}};
    ok scalar(@set_cookies), 'has Set-Cookie header';
    like $set_cookies[0], qr/SameSite=Strict/, 'custom samesite=Strict is used';
    unlike $set_cookies[0], qr/SameSite=Lax/, 'default Lax is not present';
};

done_testing;
