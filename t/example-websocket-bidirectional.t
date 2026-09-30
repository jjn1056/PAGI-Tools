use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use PAGI::Test::Client;

# The canonical full-duplex example: one handler receives one PAGI::WebSocket
# and runs a receive loop and an unprompted send loop at once. The helper
# serializes sends, so the two producers need no queue of their own.

my $file = "$Bin/../examples/websocket-bidirectional/app.pl";
my $source = do { open my $fh, '<', $file or die "$file: $!"; local $/; <$fh> };

like($source, qr/websocket\('\/'\s*=>\s*\\&duplex\)/, 'a WebSocket route takes the one-$ws handler');
like($source, qr/async sub duplex \{\s*my \(\$ws\) = \@_;/, 'the handler receives one PAGI::WebSocket');
like($source, qr/my \$incoming = \$ws->each_text\(/, 'receive loop on the WebSocket object');
like($source, qr/while \(\$ws->is_connected\)/, 'send loop guarded by the WebSocket object');
unlike($source, qr/\$queue_send|\$send_queue/, 'no hand-rolled send queue');
unlike($source, qr/PAGI::WebSocket->new|\(\$scope,\s*\$receive,\s*\$send\)|as_app_object/,
    'no raw PAGI application');

my $app = do $file;
is($@, '', 'the example loads');
ok($app && $app->can('to_app'), 'and is an application object');

my $client = PAGI::Test::Client->new(app => $app);
$client->websocket('/', sub {
    my ($ws) = @_;
    $ws->send_text('hello');
    is($ws->receive_text, 'you said: HELLO', 'the incoming branch echoes, uppercased');
    $ws->send_text('again');
    is($ws->receive_text, 'you said: AGAIN', 'on every message');
});
ok($client->websocket('/elsewhere')->is_closed, 'other paths are refused');

done_testing;
