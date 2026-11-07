use v5.24;
use warnings;
use Test2::V0;
use Future;

use PAGI::App::WebSocket::Echo;

# Runs the application against a list of events from the client, returning
# what it sent.
sub run_app {
    my ($app, $scope, @events) = @_;
    my @sent;
    $app->to_app->(
        $scope,
        sub { Future->done(shift @events) },
        sub { push @sent, $_[0]; Future->done },
    )->get;
    return @sent;
}

my $ws = { type => 'websocket', path => '/' };

subtest 'a PAGI::App' => sub {
    isa_ok(PAGI::App::WebSocket::Echo->new, ['PAGI::App'], 'the object');
};

subtest 'accepts, then echoes text' => sub {
    my @sent = run_app(PAGI::App::WebSocket::Echo->new, $ws,
        { type => 'websocket.receive', text => 'Hello' },
        { type => 'websocket.disconnect', code => 1000 });
    is(\@sent, [
        { type => 'websocket.accept' },
        { type => 'websocket.send', text => 'Hello' },
    ], 'the accept, then the text back');
};

subtest 'echoes bytes as bytes' => sub {
    my @sent = run_app(PAGI::App::WebSocket::Echo->new, $ws,
        { type => 'websocket.receive', bytes => "\x00\x01\x02" },
        { type => 'websocket.disconnect', code => 1000 });
    is($sent[1], { type => 'websocket.send', bytes => "\x00\x01\x02" }, 'the bytes back');
};

subtest 'on_connect gets the scope once the connection is accepted' => sub {
    my $got;
    run_app(PAGI::App::WebSocket::Echo->new(on_connect => sub { $got = shift }), $ws,
        { type => 'websocket.disconnect', code => 1000 });
    is($got, $ws, 'the scope');
};

subtest 'on_disconnect gets the scope, the close code and the reason' => sub {
    my @got;
    run_app(PAGI::App::WebSocket::Echo->new(on_disconnect => sub { @got = @_ }), $ws,
        { type => 'websocket.disconnect', code => 1001, reason => 'client_closed' });
    is(\@got, [$ws, 1001, 'client_closed'], 'all three');
};

subtest 'refuses anything but a WebSocket' => sub {
    my $app = PAGI::App::WebSocket::Echo->new->to_app;
    like(dies { $app->({ type => 'http' }, sub {}, sub {})->get },
        qr/\AUnsupported scope type: http\n/, 'says which');
};

done_testing;
