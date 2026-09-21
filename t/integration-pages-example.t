use strict;
use warnings;

use Test2::V0;
use FindBin qw($Bin);
use PAGI::Test::Client;

use PAGI::Pages;

my $client = PAGI::Test::Client->new(app => PAGI::Pages->welcome);
my $html = $client->get('/', headers => { Accept => 'text/html' });
is($html->status, 200, 'the bare Pages application serves HTTP through Test::Client');
is($html->content_type, 'text/html; charset=utf-8',
    'the root application negotiates HTML per HTTP invocation');
like($html->text, qr/<title>200 Welcome to PAGI<\/title>/,
    'the root invocation renders the stock Pages document');

my $app_file = "$Bin/../examples/pages/app.pl";
my $example = do $app_file;
my $load_error = $@ || $!;
ok(!$load_error, 'the complete Pages example loads cleanly')
    or diag($load_error);
isa_ok($example, 'PAGI::Compose');

subtest 'class, configured, exported, Route, Mount, and lifespan forms execute' => sub {
    plan skip_all => 'Pages example did not load'
        unless ref($example) eq 'PAGI::Compose';

    my $state;
    PAGI::Test::Client->run($example, sub {
        my ($example_client) = @_;
        $state = $example_client->state;
        is($state->{pages_example}, 'started',
            'Compose starts the Pages example lifespan');

        my $welcome = $example_client->get('/',
            headers => { Accept => 'text/html' });
        is($welcome->status, 200,
            'exported Welcome application works directly in Route');
        like($welcome->text, qr/<title>200 Welcome to PAGI<\/title>/,
            'direct application Route negotiates HTML');

        my $unknown = $example_client->get('/definitely-missing');
        is($unknown->status, 404,
            'Compose root default handles an unknown page');

        my $missing = $example_client->get('/missing',
            headers => { Accept => 'application/problem+json' });
        is($missing->status, 404,
            'class factory application works directly in Route');
        is($missing->content_type, 'application/problem+json',
            'class factory application negotiates problem JSON');

        my $configured = $example_client->get('/configured');
        is($configured->status, 404,
            'configured Pages policy works directly in Route');
        is($configured->content_type, 'text/plain; charset=utf-8',
            'configured policy supplies its text default');
        like($configured->text, qr/configured Pages policy/,
            'configured policy retains its application detail');

        my $redirect = $example_client->get('/old');
        is($redirect->status, 308,
            'direct redirect application responds');
        is($redirect->header('Location'), '/new',
            'returned redirect application retains its target');

        my $terminal = $example_client->delete('/terminal/anything',
            headers => { Accept => 'text/plain' });
        is($terminal->status, 410,
            'direct Pages application owns the complete Mount subtree');

        my $request = $example_client->get('/request');
        is($request->status, 404,
            'one-Request handler returns a request-derived Pages application');
        like($request->text, qr/No page at \/request/,
            'returned application includes request-derived detail');
        is($request->header('X-Demo'), 'Request application value',
            'returned application retains configured headers');

    });

    is($state->{pages_example}, 'stopped',
        'Compose stops the Pages example lifespan');
};

done_testing;
