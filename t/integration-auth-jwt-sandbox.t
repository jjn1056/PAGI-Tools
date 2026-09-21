use strict;
use warnings;

use Test2::V0;
use FindBin qw($Bin);

BEGIN {
    if ($] < 5.040) {
        plan skip_all => 'examples/auth-jwt-sandbox requires Perl 5.40';
        exit;
    }
    eval { require Crypt::JWT; Crypt::JWT->import(qw(encode_jwt)); 1 }
        or plan skip_all => 'Crypt::JWT is required for the optional JWT sandbox example';
}
use PAGI::Test::Client;

my $secret = 'learning-only-secret-not-for-production-0123456789';

sub load_example {
    my ($filename, $package) = @_;
    my $path = "$Bin/../examples/auth-jwt-sandbox/$filename";
    my $source = "package $package; do q{$path}";
    local $! = 0;
    my $app = eval $source;
    my $error = $@ || (!defined($app) ? "$!" : '');

    ok(!$error, "$filename loads in its own package") or diag($error);
    isa_ok($app, 'PAGI::Compose');
    return $app;
}

sub signed_token {
    my (%claims) = @_;
    return encode_jwt(
        key     => $secret,
        alg     => 'HS256',
        payload => \%claims,
    );
}

sub bearer_headers {
    my ($token) = @_;
    return { Authorization => "Bearer $token" };
}

sub exercise_shared_routes {
    my ($label, $app) = @_;
    my $client = PAGI::Test::Client->new(app => $app);

    my $missing = $client->get('/protected');
    is($missing->status, 401, "$label rejects missing credentials");
    is($missing->json,
        { error => 'Please sign in to access the vault.' },
        "$label returns the public missing-credentials message");
    is($missing->header('WWW-Authenticate'), 'Bearer realm="jwt-sandbox"',
        "$label challenges missing credentials without a token error");

    my $bad_token = 'absolute-gibberish-token';
    my $bad = $client->get('/protected', headers => bearer_headers($bad_token));
    is($bad->status, 401, "$label rejects an invalid token");
    is($bad->json,
        { error => 'Please sign in to access the vault.' },
        "$label keeps invalid-token failures public-safe");
    like($bad->header('WWW-Authenticate'), qr/error="invalid_token"/,
        "$label identifies invalid token credentials in its challenge");
    unlike($bad->text, qr/\Q$bad_token\E|decode|JWT|Crypt::JWT| at \S+ line \d+/i,
        "$label exposes neither the token nor a raw decoder exception");

    my $malformed = $client->get('/protected', headers => {
        Authorization => 'Bearer first second',
    });
    is($malformed->status, 400, "$label rejects malformed Bearer syntax");
    is($malformed->json,
        { error => 'Malformed Authorization header.' },
        "$label explains malformed credentials without echoing them");
    like($malformed->header('WWW-Authenticate'), qr/error="invalid_request"/,
        "$label identifies malformed credentials in its challenge");

    my $duplicate = $client->get('/protected', headers => [
        ['Authorization', 'Bearer first'],
        ['Authorization', 'Bearer second'],
    ]);
    is($duplicate->status, 400, "$label rejects duplicate Authorization fields");
    is($duplicate->json,
        { error => 'Malformed Authorization header.' },
        "$label does not choose among duplicate credentials");
    like($duplicate->header('WWW-Authenticate'), qr/error="invalid_request"/,
        "$label challenges duplicate credentials as an invalid request");

    my $unsupported = $client->get('/protected', headers => {
        Authorization => 'Basic Z3Vlc3Q6Z3Vlc3Q=',
    });
    is($unsupported->status, 401, "$label treats another scheme as a guest");
    is($unsupported->json,
        { error => 'Please sign in to access the vault.' },
        "$label returns the public guest message for another scheme");
    is($unsupported->header('WWW-Authenticate'), 'Bearer realm="jwt-sandbox"',
        "$label does not report an unsupported scheme as rejected Bearer credentials");

    my $login = $client->post('/login', headers => bearer_headers($bad_token));
    is($login->status, 200, "$label serves login despite rejected credentials");
    is($login->header('Cache-Control'), 'no-store',
        "$label prevents storage of the learning token response");
    my $issued = $login->json->{token};
    ok(defined($issued) && !ref($issued) && length($issued),
        "$label login issues a token");

    my $public = $client->get('/', headers => bearer_headers($bad_token));
    is($public->status, 200, "$label serves the public page despite rejected credentials");
    like($public->text, qr/<h1>JWT Learning Sandbox<\/h1>/,
        "$label serves the shared learning page");

    my $accepted = $client->get('/protected', headers => bearer_headers($issued));
    is($accepted->status, 200, "$label accepts its login-issued token");
    is($accepted->json, {
        message            => 'Success! You accessed the vault.',
        user_authenticated => T(),
        username           => 'alice_dev',
        assigned_scopes    => ['authenticated'],
    }, "$label returns identity and only the explicit authenticated grant");
    is($accepted->header('WWW-Authenticate'), undef,
        "$label omits a challenge after successful authentication");

    my $expired_token = signed_token(sub => 'old_user', exp => time - 60);
    my $expired = $client->get('/protected', headers => bearer_headers($expired_token));
    is($expired->status, 401, "$label rejects an expired token");
    is($expired->json,
        { error => 'Please sign in to access the vault.' },
        "$label returns the public rejection message for an expired token");
    like($expired->header('WWW-Authenticate'), qr/error="invalid_token"/,
        "$label challenges an expired token as invalid");

    my $wrong_signature = encode_jwt(
        key     => 'different-learning-secret-with-enough-bytes-9876543210',
        alg     => 'HS256',
        payload => { sub => 'mallory', exp => time + 3600 },
    );
    my $invalid_signature = $client->get('/protected',
        headers => bearer_headers($wrong_signature));
    is($invalid_signature->status, 401, "$label rejects an invalid signature");
    is($invalid_signature->json,
        { error => 'Please sign in to access the vault.' },
        "$label returns the public rejection message for an invalid signature");
    like($invalid_signature->header('WWW-Authenticate'), qr/error="invalid_token"/,
        "$label challenges an invalid signature as invalid");

    my $no_subject_token = signed_token(exp => time + 3600);
    my $no_subject = $client->get('/protected',
        headers => bearer_headers($no_subject_token));
    is($no_subject->status, 401, "$label rejects a token without sub");
    is($no_subject->json,
        { error => 'Please sign in to access the vault.' },
        "$label returns the public rejection message for a missing subject");
    like($no_subject->header('WWW-Authenticate'), qr/error="invalid_token"/,
        "$label challenges a missing subject as invalid credentials");

    my $role_only_token = signed_token(
        sub  => 'role_user',
        exp  => time + 3600,
        role => 'administrator',
    );
    my $role_only = $client->get('/protected',
        headers => bearer_headers($role_only_token));
    is($role_only->status, 200, "$label accepts a valid token with a role claim");
    is($role_only->json->{assigned_scopes}, ['authenticated'],
        "$label does not turn role into an implicit grant");
}

my $group_app = load_example('app.pl', 'Local::JWTGroupExample');
my $inline_app = load_example('app2.pl', 'Local::JWTInlineExample');

subtest 'group-protected application' => sub {
    exercise_shared_routes('group app', $group_app);

    my $client = PAGI::Test::Client->new(app => $group_app);
    my $missing_catalog = $client->get('/protected/catalog');
    is($missing_catalog->status, 401, 'catalog shares the group authentication requirement');
    is($missing_catalog->header('WWW-Authenticate'), 'Bearer realm="jwt-sandbox"',
        'catalog challenges missing credentials');

    my $login = $client->post('/login');
    my $catalog = $client->get('/protected/catalog',
        headers => bearer_headers($login->json->{token}));
    is($catalog->status, 200, 'catalog accepts the login-issued token');
    is($catalog->json, { items => ['Notebook', 'Pencil'] },
        'catalog returns its protected payload');
};

subtest 'inline three-route application' => sub {
    exercise_shared_routes('inline app', $inline_app);

    my $client = PAGI::Test::Client->new(app => $inline_app);
    my $catalog = $client->get('/protected/catalog');
    is($catalog->status, 404, 'inline comparison remains a three-route application');
};

done_testing;
