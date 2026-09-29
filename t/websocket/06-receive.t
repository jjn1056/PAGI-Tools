#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use JSON::MaybeXS;

use lib 'lib';
use lib 't/lib';
use PAGI::WebSocket;
use PAGITest::Connected qw(ws_scope receive_from);

subtest 'receive returns raw event' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'Hello' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $send = sub { Future->done };
    my $scope   = ws_scope();
    my $receive = receive_from($scope, @events);
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my $event = $ws->receive->get;
    is($event->{type}, 'websocket.receive', 'got receive event');
    is($event->{text}, 'Hello', 'has text');
};

subtest 'receive returns undef on disconnect' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.disconnect', code => 1000, reason => 'Bye' },
    );
    my $send = sub { Future->done };
    my $scope   = ws_scope();
    my $receive = receive_from($scope, @events);
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my $event = $ws->receive->get;
    is($event, undef, 'returns undef on disconnect');
    ok($ws->is_closed, 'marked as closed');
    is($ws->close_code, 1000, 'close code captured');
    is($ws->close_reason, 'Bye', 'close reason captured');
};

subtest 'receive_text returns text content' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'Hello, World!' },
    );
    my $send = sub { Future->done };
    my $scope   = ws_scope();
    my $receive = receive_from($scope, @events);
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my $text = $ws->receive_text->get;
    is($text, 'Hello, World!', 'received text');
};

subtest 'receive_text skips binary frames' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', bytes => "\x00\x01" },
        { type => 'websocket.receive', text => 'Text message' },
    );
    my $send = sub { Future->done };
    my $scope   = ws_scope();
    my $receive = receive_from($scope, @events);
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my $text = $ws->receive_text->get;
    is($text, 'Text message', 'skipped binary, got text');
};

subtest 'receive_bytes returns binary content' => sub {
    my $binary = "\x00\x01\x02\xFF";
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', bytes => $binary },
    );
    my $send = sub { Future->done };
    my $scope   = ws_scope();
    my $receive = receive_from($scope, @events);
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my $bytes = $ws->receive_bytes->get;
    is($bytes, $binary, 'received bytes');
};

subtest 'receive_json decodes JSON text' => sub {
    my $data = { action => 'greet', name => 'Alice' };
    my $json = encode_json($data);
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => $json },
    );
    my $send = sub { Future->done };
    my $scope   = ws_scope();
    my $receive = receive_from($scope, @events);
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my $received = $ws->receive_json->get;
    is($received, $data, 'JSON decoded correctly');
};

subtest 'receive_json dies on invalid JSON' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'not valid json{' },
    );
    my $send = sub { Future->done };
    my $scope   = ws_scope();
    my $receive = receive_from($scope, @events);
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    like(
        dies { $ws->receive_json->get },
        qr/JSON|malformed/i,
        'dies on invalid JSON'
    );
};

subtest 'receive methods return undef when closed' => sub {
    my @events = (
        { type => 'websocket.connect' },
    );
    my $send = sub { Future->done };
    my $scope   = ws_scope();
    my $receive = receive_from($scope, @events);
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;
    $ws->close->get;

    # The peer answers the Close and the server completes the connection.
    my $connection = $scope->{'pagi.connection'};
    $connection->_set_peer_close(1000, '');
    $connection->_mark_complete;

    is($ws->receive->get, undef, 'receive returns undef when closed');
    is($ws->receive_text->get, undef, 'receive_text returns undef when closed');
    is($ws->receive_bytes->get, undef, 'receive_bytes returns undef when closed');
    is($ws->receive_json->get, undef, 'receive_json returns undef when closed');
};

done_testing;
