use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../examples/declarative-routing/lib";
use PAGI::Test::Client;

my $app_file = "$Bin/../examples/declarative-routing/app.pl";

my $package_loaded = eval {
    require MyApp::Routes::Home;
    1;
};
ok($package_loaded, 'the example handler package loads normally')
    or diag($@);

my $app = do $app_file;
my $load_error = $@ || $!;
ok(!$load_error, 'the example app file loads cleanly')
    or diag($load_error);
is(ref($app), 'CODE', 'the app file returns a compiled PAGI application');

SKIP: {
    skip 'the example app did not load', 24 unless ref($app) eq 'CODE';

    my $client = PAGI::Test::Client->new(app => $app);

    my $home = $client->get('/');
    is($home->status, 200, 'home route responds');
    like($home->text, qr{<h1>Declarative PAGI</h1>}, 'home route uses the package handler');
    is($home->header('X-Route-Demo'), 'home', 'route middleware sees and changes the response stream');

    my $item = $client->get('/api/items/42');
    is($item->status, 200, 'constrained mounted route responds');
    is(
        $item->json,
        {
            id   => '42',
            path => '/api/items/42',
            url  => 'http://testserver/api/items/42',
        },
        'mounted handler receives its capture and generates path and absolute URL',
    );

    my $constraint_miss = $client->get('/api/items/not-a-number',
        headers => { Accept => 'application/problem+json' });
    is($constraint_miss->status, 404, 'failed route constraint reaches custom not-found');
    is($constraint_miss->content_type, 'application/problem+json',
        'constraint miss negotiates a problem document');
    is($constraint_miss->json, {
        type   => 'about:blank',
        title  => 'Not Found',
        status => 404,
        detail => 'No route matched',
    }, 'custom not-found body uses the shared Pages representation');

    my $missing = $client->get('/missing',
        headers => { Accept => 'application/problem+json' });
    is($missing->status, 404, 'unknown path uses custom not-found');
    is($missing->content_type, 'application/problem+json',
        'unknown path negotiates a problem document');
    is($missing->json, {
        type   => 'about:blank',
        title  => 'Not Found',
        status => 404,
        detail => 'No route matched',
    }, 'custom not-found policy remains application-owned');

    my $wrong_method = $client->post('/api/items/42',
        headers => { Accept => 'application/problem+json' });
    is($wrong_method->status, 405, 'wrong method uses custom method-not-allowed');
    is($wrong_method->header('Allow'), 'GET, HEAD', '405 publishes first-seen Allow');
    is($wrong_method->content_type, 'application/problem+json',
        'custom 405 negotiates a problem document');
    is(
        $wrong_method->json,
        {
            type   => 'about:blank',
            title  => 'Method Not Allowed',
            status => 405,
            detail => 'Method not allowed',
        },
        'custom 405 handler renders Pages from routing evidence',
    );

    my $head = $client->head('/');
    is($head->status, 200, 'automatic HEAD selects the GET route');
    is($head->content, '', 'application HEAD boundary suppresses the body');
    is($head->header('Content-Length'), $home->header('Content-Length'), 'HEAD keeps GET-equivalent Content-Length');
    is($head->header('X-Route-Demo'), 'home', 'route middleware still runs for HEAD');

    my $generated = $client->get('/api/items/7')->json;
    is($generated->{path}, '/api/items/7', 'path_for renders the mounted route');
    is($generated->{url}, 'http://testserver/api/items/7', 'url_for uses validated request authority');
}

done_testing;
