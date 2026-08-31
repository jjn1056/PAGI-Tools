use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use Scalar::Util qw(blessed);
use PAGI::Test::Client;

my $app_file = "$Bin/../examples/compose/app.pl";
my $app = do $app_file;
my $load_error = $@ || $!;
ok(!$load_error, 'Compose example loads cleanly') or diag($load_error);
ok(blessed($app) && $app->can('to_app'),
    'example returns an instantiated PAGI application component');
my $compiled = blessed($app) && $app->can('to_app')
    ? $app->to_app
    : undef;
is(ref($compiled), 'CODE', 'the application component compiles to one PAGI app');

SKIP: {
    skip 'example did not compile', 8 unless ref($compiled) eq 'CODE';
    my $state;
    PAGI::Test::Client->run($compiled, sub {
        my ($client) = @_;
        $state = $client->state;
        my $response = $client->get('/');
        is($response->status, 200, 'home route responds');
        is($response->json, {
            message => 'ready',
            request_id => 'compose-demo',
        }, 'handler sees lifecycle state and application middleware scope');
        is($response->header('X-Request-ID'), 'compose-demo',
            'application middleware changes response');

        my $head = $client->head('/');
        is($head->status, 200, 'automatic HEAD resolves the GET route');
        is($head->content, '', 'final Compose boundary suppresses the body');
        is($head->header('Content-Length'), $response->header('Content-Length'),
            'HEAD preserves GET-equivalent representation length');
    });
    is($state->{started}, 1, 'startup mutated server-provided state');
    is($state->{stopped}, 1, 'shutdown ran against the same state');
}

done_testing;
