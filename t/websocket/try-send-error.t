use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use PAGI::WebSocket;
use lib 't/lib';
use PAGITest::Connected qw(ws_scope);

# try_send_* must honor its contract — returns false on a failed send, never
# throws — WITHOUT fabricating a 1006 "Connection lost" disconnect or marking a
# live socket closed. A real send error (encoding/validation/bug) is NOT a
# disconnect, so the connection state must be left untouched. This is
# distinct from a send after close: a send after the app's OWN close never
# reaches the transport (is_closed short-circuits it below); a send after the
# PEER already closed is a tolerated no-op per spec (dropped, not delivered,
# but does not raise) — neither of those is the failure this test exercises.

sub connected_ws_that_dies {
    my $scope = ws_scope(path => '/ws');
    my $ws = PAGI::WebSocket->new(
        $scope, sub { Future->done }, sub {
            die "real send error\n" if $_[0]{type} eq 'websocket.send';
            Future->done;
        },
    );
    $ws->accept->get;
    return $ws;
}

for my $m (qw(try_send_text try_send_bytes try_send_json)) {
    subtest "$m: failure returns 0 and leaves connection state intact" => sub {
        my $ws = connected_ws_that_dies();
        my $arg = $m eq 'try_send_json' ? { a => 1 } : 'payload';

        my $ok = $ws->$m($arg)->get;

        is $ok, 0, "$m returns false on a failed send";
        ok !$ws->is_closed, 'a non-disconnect error does NOT mark the socket closed';
        is $ws->close_code, undef, 'no fabricated 1006 close code';
        is $ws->close_reason, undef, 'no fabricated close reason (state untouched)';
    };
}

subtest 'try_send on an already-closed socket still short-circuits to 0' => sub {
    my $scope = ws_scope(path => '/ws');
    my @sent;
    my $ws = PAGI::WebSocket->new(
        $scope, sub { Future->done }, sub { push @sent, $_[0]; Future->done },
    );
    $ws->accept->get;
    @sent = ();

    # The peer closes and the server completes the connection.
    my $connection = $scope->{'pagi.connection'};
    $connection->_set_peer_close(1000, 'done');
    $connection->_mark_complete;

    is $ws->try_send_text('x')->get, 0, 'returns 0 when already closed';
    is \@sent, [], 'nothing reaches the transport';
};

done_testing;
