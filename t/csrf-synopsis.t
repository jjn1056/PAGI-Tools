use strict;
use warnings;
use Test2::V0;
use PAGI::Test::Client;

open my $fh, '<', 'lib/PAGI/CSRF.pm' or die "lib/PAGI/CSRF.pm: $!";
my $pod = do { local $/; <$fh> };
my ($synopsis) = $pod =~ /^=head1 SYNOPSIS\n(.*?)^=head1 /ms;
ok(defined $synopsis, 'PAGI::CSRF has a SYNOPSIS');
my $code = join "\n", map { s/^    //r } grep { /^    / || /^\s*$/ } split /\n/, $synopsis;

my ($api, $form) = eval "$code;\n(\$api, \$form)";
ok($api && $form, 'the SYNOPSIS builds both applications') or diag($@);

subtest 'the middleware handles it' => sub {
    my $client = PAGI::Test::Client->new(app => $api);
    is($client->post('/save', json => {})->status, 403, 'no header: refused by the middleware');
    my $token = $client->cookie('csrf_token');
    ok($token, 'the refusal issued the token cookie');
    my $saved = $client->post('/save', json => {}, headers => { 'X-CSRF-Token' => $token });
    is($saved->status, 200, 'matching header: reaches the application');
};

subtest 'the application handles it' => sub {
    my $client = PAGI::Test::Client->new(app => $form);
    my ($token) = $client->get('/')->text =~ /name="csrf_token" value="([^"]+)"/;
    ok($token, 'the page hands over the token');
    is($client->post('/', form => { csrf_token => $token })->text, 'Saved', 'the posted field verifies');
    is($client->post('/', form => {})->status, 403, 'no field: the application refuses');
};

done_testing;
