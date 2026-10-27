use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use PAGI::Test::Client;

# examples/tenant-orders: middleware read the request through Requests of
# their own and the route reads the body through its own. A Request writes
# nothing to the scope, so each reads what it was handed: the route reads
# legacy_items' rewritten body though request_log had read the original, and
# tenant sees the header legacy_api_key rewrote.

plan skip_all => 'examples/tenant-orders requires Perl 5.40' if $] < 5.040;

my $app = do "$Bin/../examples/tenant-orders/app.pl";
is($@, '', 'the example loads');
my $client = PAGI::Test::Client->new(app => $app);
my %json = ('Content-Type' => 'application/json');

my $res = $client->post('/orders', headers => { %json, Authorization => 'Bearer k-acme' },
    body => '{"items":["tea","cups"]}');
is([$res->status, $res->json], [201, { tenant => 'acme', region => 'eu', items => ['tea', 'cups'], auth => 'Bearer', legacy_key => 'gone' }],
    'a bearer client: the route reads its body');

$res = $client->post('/orders?region=us', headers => { %json, 'X-Api-Key' => 'k-globex' },
    body => '{"items":"coffee,filters,mugs"}');
is([$res->status, $res->json], [201, { tenant => 'globex', region => 'us', items => ['coffee', 'filters', 'mugs'], auth => 'Bearer', legacy_key => 'gone' }],
    "a legacy client: the route reads the rewritten body, though request_log read the original, and sees the rewritten header");

$res = $client->post('/orders', headers => { %json, Authorization => 'Bearer k-acme' },
    body => '{"items":"tea,cups"}');
is([$res->status, $res->json->{items}], [201, ['tea', 'cups']],
    "items sent as a string: the route reads legacy_items' list, though request_log read the string");

$res = $client->post('/orders', headers => { %json, 'X-Api-Key' => 'k-nobody' }, body => '{}');
is([$res->status, $res->header('WWW-Authenticate'), $res->json], [401, 'Bearer', { error => 'unknown API key' }],
    'an unknown key is refused before the route');

is($client->get('/log')->json, [
    'POST /orders (bearer token, 24 bytes)',
    'POST /orders (legacy key, 31 bytes)',
    'POST /orders (bearer token, 20 bytes)',
    'POST /orders (legacy key, 2 bytes)',
    'GET /log (anonymous, 0 bytes)',
], 'request_log read each caller and body size from its own Request');

done_testing;
