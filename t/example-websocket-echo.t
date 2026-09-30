use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use PAGI::Test::Client;

# The smallest WebSocket application: one route, one handler, one $ws.

my $file = "$Bin/../examples/websocket-echo/app.pl";
my $source = do { open my $fh, '<', $file or die "$file: $!"; local $/; <$fh> };

like($source, qr/websocket\('\/'\s*=>\s*\\&echo\)/, 'a WebSocket route takes the one-$ws handler');
unlike($source, qr/PAGI::WebSocket->new|\(\$scope,\s*\$receive,\s*\$send\)|as_app_object/,
    'no raw PAGI application');

my ($app, $stderr) = (undef, '');
$app = do $file;
is($@, '', 'the example loads');
isa_ok($app, 'PAGI::Compose');

{
    local *STDERR;
    open STDERR, '>', \$stderr or die $!;
    PAGI::Test::Client->new(app => $app)->websocket('/', sub {
        my ($ws) = @_;
        $ws->send_text('hi');
        is($ws->receive_text, 'echo: hi', 'text is echoed');
        $ws->close(1000, 'bye');
    });
}
like($stderr, qr/Client disconnected: 1000/, 'the close is logged with the peer code');
unlike($stderr, qr/uninitialized/, 'without warnings');

done_testing;
