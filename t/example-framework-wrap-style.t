use v5.40;
use Test2::V0;
use PAGI::Test::Client;
use FindBin qw($Bin);

my $app = do("$Bin/../examples/framework-wrap-style/app.pl")
    or die "app: $@";
my $client = PAGI::Test::Client->new(app => $app);

my $res = $client->get('/tenants/acme/notes/7');
is($res->status, 200, 'a chained match reaches the leaf');
is($res->json, { note => 'buy apples' }, "each match saw its own path params");

is($client->get('/tenants/nope/notes/7')->status, 404, 'the bridge refuses');

$res = $client->get('/private');
is($res->status, 401, 'an HTTP exception answered by the built-in response');
like($res->header('WWW-Authenticate'), qr/^Bearer realm="mini"/, 'carrying its challenge');

$res = $client->get('/seen');
is($res->status, 204, 'a no-body status through the generic path');
like($res->header('Set-Cookie'), qr/^seen=1/, 'with its staged cookie');
ok(!defined $res->header('Content-Type') && !defined $res->header('Content-Length'),
    'and no content headers');

$res = $client->get('/pixel');
is($res->header('Content-Type'), 'image/gif', 'the staged type beats the base default');

$res = $client->get('/csv');
is($res->header('Content-Type'), 'text/csv; charset=utf-8', "a staged type keeps Text's charset");

$res = $client->get('/old');
is($res->status, 302, 'an untyped bodyless redirect');
is($res->header('Location'), '/tenants/acme/notes/7', 'with its staged Location');
ok(!defined $res->header('Content-Type'), 'and no Content-Type, as Starlette');

$res = $client->get('/nowhere', headers => { Accept => 'application/json' });
is($res->status, 404, 'a page turned into a response');
is($res->header('X-Mini'), '1', "with the framework's header on it");

done_testing;
