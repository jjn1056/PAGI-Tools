use v5.24;
use warnings;
use Test2::V0;
use Future;
use PAGI::Test::Client;

use PAGI::App::WebSocket::Echo;

sub client { PAGI::Test::Client->new(app => PAGI::App::WebSocket::Echo->new(@_)) }

subtest 'a PAGI::App' => sub {
    isa_ok(PAGI::App::WebSocket::Echo->new, ['PAGI::App'], 'the object');
};

subtest 'echoes text as text' => sub {
    client()->websocket('/', sub {
        my ($ws) = @_;
        $ws->send_text('Hello');
        is $ws->receive_text, 'Hello', 'the text back';
        $ws->send_text('again');
        is $ws->receive_text, 'again', 'and the next';
    });
};

subtest 'echoes bytes as bytes' => sub {
    client()->websocket('/', sub {
        my ($ws) = @_;
        $ws->send_bytes("\x00\x01\x02");
        is $ws->receive_bytes, "\x00\x01\x02", 'the bytes back';
    });
};

subtest 'on_connect gets the scope once the connection is accepted' => sub {
    my $got;
    client(on_connect => sub { $got = shift })->websocket('/chat', sub { });
    is $got->{path}, '/chat', 'the scope';
};

subtest 'on_disconnect when the client closes: its code and reason' => sub {
    my @got;
    my $ws = client(on_disconnect => sub { @got = @_ })->websocket('/chat');
    $ws->close(1001, 'going away');
    is $got[0]{path}, '/chat', 'the scope';
    is [@got[1, 2]], [1001, 'going away'], "the client's close code and reason";
};

subtest 'on_disconnect when the connection fails: 1006, and why on the connection' => sub {
    my @got;
    my $ws = client(on_disconnect => sub { @got = @_ })->websocket('/');
    $ws->simulate_abnormal_close(reason => 'read_error');
    is [@got[1, 2]], [1006, undef], 'no Close from the client: 1006 and no reason';
    is $got[0]{'pagi.connection'}->disconnect_reason, 'read_error', "and the connection says why";
};

subtest 'expects websocket.connect first' => sub {
    my $app = PAGI::App::WebSocket::Echo->new->to_app;
    my @events = ({ type => 'websocket.receive', text => 'x' }, { type => 'websocket.disconnect', code => 1000 });
    like(dies { $app->({ type => 'websocket' }, sub { Future->done(shift @events) }, sub { Future->done })->get },
        qr/\AExpected websocket\.connect, got websocket\.receive\n/, 'says what came instead');
};

subtest 'refuses anything but a WebSocket' => sub {
    my $app = PAGI::App::WebSocket::Echo->new->to_app;
    like(dies { $app->({ type => 'http' }, sub {}, sub {})->get },
        qr/\AUnsupported scope type: http\n/, 'says which');
};

done_testing;
