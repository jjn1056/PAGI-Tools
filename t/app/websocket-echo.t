use v5.24;
use warnings;
use Test2::V0;
use Future;
use PAGI::Test::Client;

use PAGI::App::WebSocket::Echo;

sub client { PAGI::Test::Client->new(app => PAGI::App::WebSocket::Echo->new) }

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

subtest '"bye": the app closes the connection' => sub {
    my $ws = client()->websocket('/');
    $ws->send_text('hello');
    is $ws->receive_text, 'hello', 'echoes until then';
    $ws->send_text('bye');
    $ws->pump;
    ok $ws->is_closed, 'then closes';
    is $ws->close_code, 1000, 'a normal close';
};

subtest '"bye" as bytes is a message like any other' => sub {
    client()->websocket('/', sub {
        my ($ws) = @_;
        $ws->send_bytes('bye');
        is $ws->receive_bytes, 'bye', 'echoed';
        ok !$ws->is_closed, 'still open';
    });
};

subtest 'the client closes: the session ends cleanly' => sub {
    my $ws = client()->websocket('/');
    ok lives { $ws->close(1001, 'going away') }, 'no error from the app';
    ok $ws->is_closed, 'closed';
    is [$ws->close_code, $ws->close_reason], [1001, 'going away'], "the client's own Close";
};

subtest 'the connection fails: the session ends without an error' => sub {
    my $ws = client()->websocket('/');
    ok lives { $ws->simulate_abnormal_close(reason => 'read_error') }, 'no error from the app';
    ok $ws->is_closed, 'closed';
};

subtest 'a client gone before the accept: nothing sent' => sub {
    my @sent;
    ok lives {
        PAGI::App::WebSocket::Echo->new->to_app->({ type => 'websocket' },
            sub { Future->done({ type => 'websocket.disconnect', code => 1006 }) },
            sub { push @sent, shift; Future->done })->get;
    }, 'it returns, without an error';
    is \@sent, [], 'no accept';
};

subtest 'refuses anything but a WebSocket' => sub {
    my $app = PAGI::App::WebSocket::Echo->new->to_app;
    like(dies { $app->({ type => 'http' }, sub {}, sub {})->get },
        qr/\AUnsupported scope type: http\n/, 'says which');
};

done_testing;
