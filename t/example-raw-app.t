use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);

BEGIN { plan skip_all => 'examples/raw-app requires Perl 5.40' if $] < 5.040 }

use lib "$Bin/../lib", "$Bin/../examples/raw-app/lib";
use PAGI::Test::Client;

# A classic PAGI application in a module: RawApp is a PAGI::App whose call
# is the application itself, with no Compose. It handles lifespan, http and
# websocket scopes directly.

my $provider = do "$Bin/../examples/raw-app/lib/RawApp.pm" or die $@ || $!;
can_ok $provider, 'to_app';
ok RawApp->isa('PAGI::App') && !RawApp->isa('PAGI::App::Compose'), 'a PAGI::App, not a Compose';

PAGI::Test::Client->run($provider, sub {
    my ($client) = @_;

    my $res = $client->get('/');
    is [$res->status, $res->header('Content-Type'), $res->text],
        [200, 'text/plain; charset=utf-8', "Hello from a classic PAGI application.\n"], 'GET /';

    is $client->get('/hits')->text, "Hits: 1\n", 'the counter lifespan put in the shared state';
    is $client->get('/hits')->text, "Hits: 2\n", 'counts up across requests';

    $res = $client->post('/hits', body => 'x');
    is [$res->status, $res->header('Allow')], [405, 'GET, HEAD'], 'POST is a 405 with Allow';

    $res = $client->get('/nowhere');
    is [$res->status, $res->text], [404, "No such page: /nowhere\n"], 'anything else is a 404';

    my $ws = $client->websocket('/echo');
    $ws->send_text('hi');
    is $ws->receive_text, 'echo: hi', 'the WebSocket echoes text';
    $ws->send_bytes("\x00\x01");
    is $ws->receive_bytes, "\x00\x01", 'and bytes';
    $ws->close;

    my $refused = $client->websocket('/elsewhere');
    ok $refused->refused, 'a WebSocket elsewhere is refused before accept';
    is [$refused->response->status, $refused->response->text], [404, "No socket here.\n"];

    my $sse = $client->sse('/hits');
    is [$sse->status, $sse->text], [404, "No event stream here.\n"], 'an event-stream request is refused';
});

subtest 'one request from the shell, without a server' => sub {
    my ($out, $err) = ('', '');
    my $status = do {
        open my $o, '>', \$out or die; open my $e, '>', \$err or die;
        local *STDOUT = $o; local *STDERR = $e;
        RawApp->new->run(GET => '/hits');
    };
    is [$status, $out], [0, "Hits: 1\n"], 'run answers it, lifespan included';
    like $err, qr{\AHTTP/1\.1 200\n}, 'the status on STDERR';
};

done_testing;
