use strict;
use warnings;
use Test2::V0;
use Future;
use FindBin qw($Bin);
use lib "$Bin/../../examples/websocket-chat-v2/lib";
use PAGI::Test::ConnectionState;
use ChatApp::WebSocket;

subtest 'chat cleanup is registered before accept can end connection' => sub {
    my $conn = PAGI::Test::ConnectionState->new(websocket => 1);
    my $future = ChatApp::WebSocket::handler()->({type => 'websocket', pagi => { spec_version => '0.6' }, 'pagi.connection' => $conn}, sub {die 'receive after end'}, sub {
        $conn->_mark_disconnected('peer_closed', 'during accept');
        return Future->done;
    });
    ok($future->is_ready && !$future->is_failed, 'early terminal accept returns without late registration or session/timer creation');
    diag($future->failure) if $future->is_failed;
};

subtest 'dashboard cleanup is registered before welcome send can end connection' => sub {
    my $app = do "$Bin/../../examples/sse-dashboard/app.pl";
    die $@ || $! unless $app;
    my $conn = PAGI::Test::ConnectionState->new;
    my $stderr = '';
    local *STDERR;
    open STDERR, '>', \$stderr or die $!;
    my $future = $app->({type => 'sse', path => '/events', pagi => { spec_version => '0.6' }, 'pagi.connection' => $conn}, sub {die 'receive after end'}, sub {
        $conn->_mark_disconnected('peer_closed', 'during welcome');
        return Future->done;
    });
    ok($future->is_ready && !$future->is_failed, 'early terminal welcome returns without late registration or broadcaster creation');
    diag($future->failure) if $future->is_failed;
    like($stderr, qr/SSE client .* disconnected/, 'registered cleanup removed subscriber during awaited I/O');
};
done_testing;
