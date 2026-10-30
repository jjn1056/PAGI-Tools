use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use lib 't/lib';
use PAGI::WebSocket;
use PAGI::Response::Text;
use PAGITest::Connected qw(ws_scope);

# A helper owns the connection from the moment it issues its accept or its
# refusal's http.response.start, not from when that send completes. Here the
# server has marked the response started and holds the send's Future, as it
# does under backpressure, while another branch of the same handler sends.

# A helper whose send records each event, marks the response started as a
# server does, and returns $reply->($event) (default: done).
sub helper_with_send {
    my ($reply) = @_;
    my $scope = ws_scope(path => '/ws');
    my $connection = $scope->{'pagi.connection'};
    my @sent;
    my $send = sub {
        my ($event) = @_;
        push @sent, $event;
        my $result = $reply ? $reply->($event) : Future->done;
        $connection->_mark_response_started
            if $event->{type} =~ /^(?:websocket\.accept|http\.response\.start)$/;
        return $result;
    };
    return (PAGI::WebSocket->new($scope, sub { Future->new }, $send), \@sent);
}

subtest 'during its own pending accept a concurrent send_text is sent' => sub {
    my $hold = Future->new;
    my ($ws, $sent) = helper_with_send(sub { $_[0]{type} eq 'websocket.accept' ? $hold : Future->done });

    my $accept = $ws->accept;
    ok !$accept->is_ready, 'the accept is still pending';

    my $text;
    ok lives { $text = $ws->send_text('hello'); $text->get }, 'send_text lives';
    is $sent, [{ type => 'websocket.accept' }, { type => 'websocket.send', text => 'hello' }],
        'the text follows the accept to the server';

    $hold->done;
    $accept->get;
    ok $ws->is_connected, 'the accept completes';
};

# With its accept issued the helper is in the "this helper answered" row:
# each of these behaves as it does after the accept, in call order.
for my $case (
    [close         => sub { $_[0]->close(1000) },
        [{ type => 'websocket.close', code => 1000, reason => '' }]],
    [close_or_deny => sub { $_[0]->close_or_deny(1000, 'bye') },
        [{ type => 'websocket.close', code => 1000, reason => 'bye' }]],
    [keepalive     => sub { $_[0]->keepalive(10) },
        [{ type => 'websocket.keepalive', interval => 10 }]],
    [try_send_text => sub { $_[0]->try_send_text('hello') },
        [{ type => 'websocket.send', text => 'hello' }]],
) {
    my ($name, $call, $expected) = @$case;
    subtest "during its own pending accept a concurrent $name is sent" => sub {
        my $hold = Future->new;
        my ($ws, $sent) = helper_with_send(sub { $_[0]{type} eq 'websocket.accept' ? $hold : Future->done });

        my $accept = $ws->accept;
        my $operation;
        ok lives { $operation = $call->($ws) }, "$name lives";
        is $sent, [{ type => 'websocket.accept' }, @$expected], "$name follows the accept to the server";

        $hold->done;
        $accept->get;
        ok lives { $operation->get }, "$name completes";
        isnt $ws->connection_state, 'connecting', 'the accept settled';
        is $ws->connection_state, ($name =~ /close/ ? 'closing' : 'connected'),
            'the completed accept does not undo a close made while it was pending';
    };
}

subtest 'during its own pending accept a concurrent receive reads' => sub {
    my $hold = Future->new;
    my $scope = ws_scope(path => '/ws');
    my $connection = $scope->{'pagi.connection'};
    my $reads = 0;
    my $ws = PAGI::WebSocket->new($scope,
        sub { $reads++; Future->done({ type => 'websocket.receive', text => 'hi' }) },
        sub { $connection->_mark_response_started; $hold });

    my $accept = $ws->accept;
    is $ws->receive_text->get, 'hi', 'receive_text gets the message';
    is $reads, 1, 'from the receive';
    $hold->done;
    $accept->get;
};

subtest 'during its own pending refusal a concurrent send_text fails as refusing' => sub {
    my $hold = Future->new;
    my ($ws, $sent) = helper_with_send(sub { $_[0]{type} eq 'http.response.start' ? $hold : Future->done });

    my $refusal = $ws->deny(PAGI::Response::Text->new('no', status => 403));
    like dies { $ws->send_text('hello')->get }, qr/^this helper is refusing the connection /,
        'send_text croaks the refusing message, not the ownership one';
    is [map { $_->{type} } @$sent], ['http.response.start'], 'nothing more is sent';

    $hold->done;
    $refusal->get;
    is [map { $_->{type} } @$sent], ['http.response.start', 'http.response.body'],
        'the refusal completes';
};

# D6: a rejected own accept raises at its await. The helper keeps the claim
# it recorded when it sent the accept and is still treated as the answerer:
# every operation behaves as on an accepted socket, and its sends reach the
# server (as Starlette's WebSocket, which marks itself connected before
# awaiting the accept). Rejected before the server marked the response
# started (the send dies) and after it (the send's Future fails).
for my $case (
    [dies  => sub { die "accept rejected\n" }],
    [fails => sub { Future->fail("accept rejected\n") }],
) {
    my ($how, $reject) = @$case;
    subtest "an accept whose send $how: it raises, and the helper acts as accepted" => sub {
        my $reply = sub { $_[0]{type} eq 'websocket.accept' ? $reject->() : Future->done };
        my ($ws, $sent) = helper_with_send($reply);

        like dies { $ws->accept->get }, qr/^accept rejected$/, 'the accept raises the error';
        is $ws->connection_state, 'connecting', 'no special state';
        is $ws->scope->{'pagi.connection'}->response_started, ($how eq 'fails' ? 1 : 0),
            'the server marked the response started ' . ($how eq 'fails' ? 'before' : 'never');

        $ws->send_text('a')->get;
        is $ws->try_send_text('b')->get, 1, 'try_send_text sends';
        $ws->keepalive(5)->get;
        $ws->close(1000)->get;
        is $sent, [
            { type => 'websocket.accept' },
            { type => 'websocket.send', text => 'a' },
            { type => 'websocket.send', text => 'b' },
            { type => 'websocket.keepalive', interval => 5 },
            { type => 'websocket.close', code => 1000, reason => '' },
        ], 'send_text, try_send_text, keepalive and close reach the server';

        my ($other, $other_sent) = helper_with_send($reply);
        like dies { $other->accept->get }, qr/^accept rejected$/, 'another rejected accept';
        $other->close_or_deny(1011, 'bye')->get;
        is $other_sent, [
            { type => 'websocket.accept' },
            { type => 'websocket.close', code => 1011, reason => 'bye' },
        ], 'close_or_deny closes rather than denying';
    };
}

# The "connection ended" row holds during a pending accept too.
subtest 'a pending accept on a connection that then ends: try_send_* return 0' => sub {
    my $hold = Future->new;
    my ($ws, $sent) = helper_with_send(sub { $_[0]{type} eq 'websocket.accept' ? $hold : Future->done });
    my $accept = $ws->accept;
    $ws->scope->{'pagi.connection'}->_mark_disconnected('client_closed');

    is $ws->try_send_text('x')->get, 0, 'try_send_text returns 0';
    is $ws->try_send_bytes('x')->get, 0, 'try_send_bytes returns 0';
    is $ws->try_send_json({})->get, 0, 'try_send_json returns 0';
    is $sent, [{ type => 'websocket.accept' }], 'nothing more is sent';
    $hold->done;
    $accept->get;
};

done_testing;
