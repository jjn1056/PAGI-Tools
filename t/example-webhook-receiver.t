use strict;
use warnings;
use Test2::V0;

BEGIN { plan skip_all => 'examples/webhook-receiver requires Perl 5.40' if $] < 5.040 }
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Digest::SHA qw(hmac_sha256_hex);
use File::Temp qw(tempdir);
use PAGI::Test::Client;

# The webhook receiver: a signed delivery is logged and answers 202, an
# unsigned or missigned one is a 401, a signed non-JSON body is the stock
# 400, and the page and JSON views read the log back.

my $dir = tempdir(CLEANUP => 1);
local $ENV{WEBHOOK_LOG}    = "$dir/deliveries.jsonl";
local $ENV{WEBHOOK_SECRET} = 'test-secret';

my $app = do "$Bin/../examples/webhook-receiver/app.pl";
is($@, '', 'the example loads');
isa_ok($app, 'PAGI::Compose');

my $client = PAGI::Test::Client->new(app => $app);

sub signed {
    my ($body, %headers) = @_;
    return [
        ['x-hub-signature-256' => 'sha256=' . hmac_sha256_hex($body, 'test-secret')],
        map { [$_ => $headers{$_}] } sort keys %headers,
    ];
}

my $body = '{"action":"opened","number":7}';
my $res = $client->post('/hooks/github', body => $body,
    headers => signed($body, 'x-github-event' => 'pull_request', 'x-github-delivery' => 'd-1'));
is($res->status, 202, 'a signed delivery is accepted');
is($res->json, { ok => 1, id => 'd-1' }, 'and answers with its id');

$res = $client->post('/hooks/github', body => $body);
is($res->status, 401, 'an unsigned delivery is refused');

$res = $client->post('/hooks/github', body => $body,
    headers => [['x-hub-signature-256' => 'sha256=' . hmac_sha256_hex($body, 'wrong')]]);
is($res->status, 401, 'and so is one signed with another secret');

$res = $client->post('/hooks/github', body => 'not json', headers => signed('not json'));
is($res->status, 400, 'a signed body that is not JSON is a 400');
like($res->text, qr/not valid JSON/, 'from the RequestBody exception');

is($client->get('/hooks/github')->status, 405, 'GET on the hook is the router 405');

$res = $client->get('/');
is($res->status, 200, 'the status page is served');
like($res->text, qr/1 deliveries/, 'counting the logged delivery');
like($res->text, qr/<code>pull_request<\/code> d-1/, 'and listing it');

$res = $client->get('/deliveries.json?n=1');
is($res->status, 200, 'the JSON view is served');
is($res->json->[0]{payload}, { action => 'opened', number => 7 }, 'with the parsed payload');

done_testing;
