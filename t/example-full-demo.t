use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use PAGI::Test::Client;

# full-demo is the runnable companion to PAGI::Tools' QUICK TOUR: HTTP,
# streaming (including NDJSON), WebSocket and SSE handlers, route names with
# path_for/url_for, and Compose lifespan state.

my $file = "$Bin/../examples/full-demo/app.pl";
my $source = do { open my $fh, '<', $file or die "$file: $!"; local $/; <$fh> };

like($source, qr/response\('NDJSON',/, 'it streams NDJSON');
like($source, qr/path_for\(\$request/, 'it builds links from route names');
unlike($source, qr/maybe_sleep|HAS_FUTURE_IO/, 'no fallback for a missing Future::IO');
unlike($source, qr/\)->to_app;\s*\z/, 'returns the Compose application object');

my ($app, $stderr) = (undef, '');
{
    local *STDERR;
    open STDERR, '>', \$stderr or die $!;
    $app = do $file;
}
is($@, '', 'the example loads');
isa_ok($app, 'PAGI::Compose');

my %res;
{
    local *STDERR;
    open STDERR, '>', \$stderr or die $!;
    PAGI::Test::Client->run($app, sub {
        my ($client) = @_;
        $res{hello}  = $client->get('/');
        $res{echo}   = $client->post('/echo', body => 'ping',
            headers => { 'Content-Type' => 'text/plain' });
        $res{export} = $client->get('/export');
        $res{routes} = $client->get('/routes');
        $res{note}     = $client->post('/notes', body => '{"text":"hi"}',
            headers => { 'Content-Type' => 'application/json' });
        $res{bad_note} = $client->post('/notes', body => '{nope',
            headers => { 'Content-Type' => 'application/json' });
        $client->websocket('/ws/echo', sub {
            my ($ws) = @_;
            $ws->send_text('hi');
            is($ws->receive_text, 'Echo: hi', 'the WebSocket echoes');
        });
    });
}

is($res{hello}->text, 'Hello, World!', 'the root says hello');
is([$res{echo}->text, $res{echo}->header('x-echoed-length')], ['ping', 4],
    'POST /echo returns the body and its length');

is($res{export}->header('content-type'), 'application/x-ndjson', '/export is NDJSON');
my @records = map { JSON::PP->new->decode($_) } split /\n/, $res{export}->text;
is([map { $_->{n} } @records], [1, 2, 3], 'one record per line');

is($res{routes}->json->{paths}, {
    hello       => '/',
    echo        => '/echo',
    notes       => '/notes',
    http_stream => '/stream',
    export      => '/export',
    ws_echo     => '/ws/echo',
    sse_events  => '/events',
}, 'every route is reachable by name');
is($res{note}->status, 201, 'a JSON note is saved');
is([$res{bad_note}->status, $res{bad_note}->json],
    [400, { error => 'The request body is not valid JSON.' }],
    'a body that is not JSON answers 400 in JSON through the ErrorHandler');

like($res{routes}->json->{export_url}, qr{\Ahttps?://[^/]+/export\z},
    'and url_for gives an absolute URL');

like($stderr, qr/\[STARTUP\] Application ready!/, 'the startup hook ran');
like($stderr, qr/\[SHUTDOWN\] Shutting down after \d+s, handled \d+ requests/,
    'and the shutdown hook reports from shared state');

done_testing;

use JSON::PP ();
