use strict;
use warnings;

use Test2::V0;
use FindBin qw($Bin);
use PAGI::Test::Client;

my $app_file = "$Bin/../examples/pages/app.pl";
my $app = do $app_file;
my $load_error = $@ || $!;
ok(!$load_error, 'Pages example loads cleanly') or diag($load_error);
isa_ok($app, 'PAGI::Compose');

subtest 'Pages example exercises handler, adapter, raw, and lifespan forms' => sub {
    plan skip_all => 'Pages example did not load'
        unless ref($app) eq 'PAGI::Compose';

    my $state;
    PAGI::Test::Client->run($app, sub {
        my ($client) = @_;
        $state = $client->state;
        is($state->{pages_example}, 'started',
            'Compose startup receives server-owned lifespan state');

        my $welcome = $client->get('/', headers => { Accept => 'text/html' });
        is($welcome->status, 200, 'Welcome route responds');
        is($welcome->content_type, 'text/html; charset=utf-8',
            'Welcome route negotiates HTML');
        like($welcome->text, qr/<title>200 Welcome to PAGI<\/title>/,
            'Welcome route renders the stock Pages document');

        my $redirect = $client->get('/old');
        is($redirect->status, 308, 'fixed route returns a permanent redirect');
        is($redirect->header('Location'), '/new',
            'fixed route publishes its Pages redirect target');

        my $route_child = $client->get('/old/child',
            headers => { Accept => 'text/plain' });
        is($route_child->status, 404,
            'an exact Route does not own descendant paths');
        is($route_child->header('Location'), undef,
            'the descendant does not reach the redirect endpoint');

        my $problem = $client->get('/missing',
            headers => { Accept => 'application/problem+json' });
        is($problem->status, 404, 'missing route returns Not Found');
        is($problem->content_type, 'application/problem+json',
            'error route negotiates problem JSON');
        is($problem->json->{status}, 404,
            'problem JSON identifies the terminal status');
        is($problem->json->{title}, 'Not Found',
            'problem JSON carries the stock title');

        my $mounted = $client->get('/terminal/child',
            headers => { Accept => 'text/plain' });
        is($mounted->status, 410,
            'request_app adapts the Gone handler for Mount ownership');
        is($mounted->content_type, 'text/plain; charset=utf-8',
            'mounted endpoint negotiates text');
        like($mounted->text, qr/^410 Gone/m,
            'mounted descendant renders the Gone page');

        my $request = $client->get('/request');
        is($request->status, 404,
            'Request handler returns its unsent Response value');
        is($request->header('X-Demo'), 'Request response value',
            'Request handler modifies the Response before Router sends it');
        is($request->content_type, 'text/plain; charset=utf-8',
            'Request handler fixes the text representation');

        my $raw = $client->get('/raw');
        is($raw->status, 404, 'raw closure sends its Response explicitly');
        is($raw->header('X-Demo'), 'raw response value',
            'raw closure modifies the Response before respond');
        is($raw->content_type, 'text/plain; charset=utf-8',
            'raw closure sends the fixed text representation');
    });

    is($state->{pages_example}, 'stopped',
        'Compose shutdown updates the same lifespan state');
};

done_testing;
