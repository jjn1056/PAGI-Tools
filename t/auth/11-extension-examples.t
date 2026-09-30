use strict;
use warnings;
use Test2::V0;
BEGIN {
    if ($] < 5.040) {
        plan skip_all => 'auth extension examples require Perl 5.40';
        exit;
    }
}
use FindBin qw($Bin);
use PAGI::Auth;
use PAGI::Test::Client;

my $examples = "$Bin/../../examples/auth-extensions";

sub run_script {
    my ($name) = @_;
    open my $output, '-|', $^X, '-Ilib', "$examples/$name" or die $!;
    local $/;
    my $text = <$output>;
    close $output;
    is($? >> 8, 0, "$name exits successfully");
    return $text // '';
}

sub load_app {
    my ($name) = @_;
    my $app;
    if ($name eq '02-basic-backend.pl') {
        $app = do { package AuthExtensions::Test::Basic; do "$examples/$name" };
    } elsif ($name eq '03-context-and-placement.pl') {
        $app = do { package AuthExtensions::Test::Context; do "$examples/$name" };
    } elsif ($name eq '04-response-applications.pl') {
        $app = do { package AuthExtensions::Test::Response; do "$examples/$name" };
    } elsif ($name eq '05-protocol-admission.pl') {
        $app = do { package AuthExtensions::Test::Protocol; do "$examples/$name" };
    } else {
        die "Unexpected example $name";
    }
    ok(defined $app, "$name loads") or diag($@ || $!);
    return PAGI::Test::Client->new(app => $app) if defined $app;
    return;
}

subtest 'users and results script' => sub {
    my $output = run_script('01-users-and-results.pl');
    like($output, qr/^guest: Visitor; authenticated: 0$/m, 'duck-typed guest appears');
    like($output, qr/^guest grant: 1$/m, 'guest can have explicit grants');
    like($output, qr/^helper forms: function class instance new$/m, 'all invocation forms run');
    like($output, qr/^result: alice; note rejected; expired$/m, 'result readers and failure run');
    like($output, qr/^future: alice$/m, 'future result resolves');
    like($output, qr/^scope policy: admin=1 manager-edit=1 viewer=0$/m, 'compound policy runs');
    like($output, qr/^live scopes: 1; copy unchanged: 1$/m, 'reference semantics are visible');
};

{
    package DemoGuest;
    sub new { bless {}, shift }
    sub is_authenticated { 0 }
    sub identity { '' }
    sub display_name { 'Visitor' }
}
{
    package DemoAuth;
    use parent 'PAGI::Auth';
    sub unauth_result {
        my ($self, %args) = @_;
        $args{user} = DemoGuest->new unless exists $args{user};
        return $self->SUPER::unauth_result(%args);
    }
}
my $factory = DemoAuth->new;
is($factory->unauth_result->user->display_name, 'Visitor',
    'subclass delegates to SUPER with its own guest default');
is(PAGI::Auth::unauth_result()->user->display_name, '',
    'base function retains built-in guest default');

subtest 'Basic backend app' => sub {
    my $client = load_app('02-basic-backend.pl') or return;
    my $missing = $client->get('/staff');
    is($missing->status, 401, 'missing credentials are refused');
    is($missing->header('WWW-Authenticate'), 'Basic realm="staff"', 'handler selects Basic challenge');
    my $good = $client->get('/staff', headers => { Authorization => 'Basic YWRhOnRlc3Q=' });
    is($good->status, 200, 'fixed learning credential succeeds');
    is($good->json->{identity}, 'ada', 'backend returns authenticated user');
    my $bad = $client->get('/staff', headers => { Authorization => 'Basic YWRhOm5v' });
    is($bad->status, 401, 'incorrect credential is refused');
    is($bad->json->{error}, 'Credentials were not accepted.', 'failure message reaches application');
    my $duplicate = $client->get('/staff', headers => [
        [Authorization => 'Basic YWRhOnRlc3Q='],
        [Authorization => 'Basic YWRhOnRlc3Q='],
    ]);
    is($duplicate->status, 401, 'duplicate fields are rejected before convenience decoding');
};

subtest 'context and placement app' => sub {
    my $client = load_app('03-context-and-placement.pl') or return;
    my $outer = $client->get('/outer', headers => { Authorization => 'Demo outer' });
    is($outer->json->{identity}, 'outer', 'outer context installed');
    my $inner = $client->get('/inner/item', headers => { Authorization => 'Demo outer' });
    is($inner->json->{identity}, 'inner', 'nested context replaces outer identity');
    is($inner->json->{outer}, 'outer', 'outer observation survives nested call');
    is($inner->json->{outer_grant_visible}, 0, 'outer grant does not leak into nested result');
    is($inner->json->{can_edit}, 0, 'manual ownership requires matching identity and grant');
    my $allowed = $client->get('/inner/item', headers => { Authorization => 'Demo inner' });
    is($allowed->json->{can_edit}, 1, 'matching owner and grant permits edit');
};

subtest 'response applications app' => sub {
    my $client = load_app('04-response-applications.pl') or return;
    my $source = do {
        open my $fh, '<', "$examples/04-response-applications.pl" or die $!;
        local $/; <$fh>;
    };
    unlike($source, qr/\bas_app_object\b/,
        'a handler returns a native application as bare CODE; no adapter needed');
    for my $path (qw(sync async response pages object native group)) {
        my $missing = $client->get("/$path");
        is($missing->status, 401, "$path chooses refusal");
        my $ok = $client->get("/$path", headers => { Authorization => 'Bearer accepted', Accept => 'application/json' });
        is($ok->status, 200, "$path accepts credential");
    }
    is($client->get('/pages', headers => { Accept => 'application/json' })->header('Content-Type'),
        'application/problem+json', 'Pages negotiates JSON problem representation');
};

subtest 'protocol admission app' => sub {
    my $client = load_app('05-protocol-admission.pl') or return;
    is($client->get('/http')->status, 401, 'HTTP absence refused');
    is($client->get('/http', headers => { Authorization => 'Bearer accepted' })->status,
        200, 'HTTP accepted');
    for my $protocol (qw(websocket sse)) {
        my $path = $protocol eq 'websocket' ? '/socket' : '/events';
        my $denied = $client->$protocol($path);
        if ($protocol eq 'websocket') {
            ok($denied->is_closed, 'denied WebSocket closes cleanly');
        } else {
            is($denied->status, 401, 'SSE refusal is an HTTP response');
            is($denied->json->{error}, 'An access token is required.',
                'public refusal reads installed failure');
        }
        my $accepted = $client->$protocol($path,
            headers => { Authorization => 'Bearer accepted' });
        ok($accepted->is_closed, "$protocol accepted lifecycle closes cleanly");
    }
};

subtest 'header primitives script' => sub {
    my $output = run_script('06-header-primitives.pl');
    like($output, qr/^formatter: Bearer realm="notes"$/m, 'formatter path runs');
    like($output, qr/^repeated: Basic realm="staff" \| Bearer realm="notes"$/m, 'repeated fields run');
    like($output, qr/^opaque: Negotiate YWJj$/m, 'opaque raw challenge preserved');
    like($output, qr/^digest: Digest realm="notes", qop="auth,auth-int"$/m, 'Digest value is quoted');
    like($output,
        qr/^digest raw: Digest realm="notes", nonce="example-nonce", qop="auth", algorithm=SHA-256, stale=true$/m,
        'raw Digest challenge keeps algorithm and stale unquoted');
    like($output, qr/resource_metadata="https:\/\/notes\.example\/\.well-known\/oauth-protected-resource\/mcp"/, 'resource metadata is header only');
    like($output, qr/^insufficient: 403; Bearer realm="notes", error="insufficient_scope", scope="notes:read"$/m,
        'application constructs explicit scope refusal');
};

done_testing;
