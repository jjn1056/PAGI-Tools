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

subtest 'each_message iterates until disconnect' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'msg1' },
        { type => 'websocket.receive', text => 'msg2' },
        { type => 'websocket.receive', text => 'msg3' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $send = sub { Future->done };
    my $scope   = ws_scope();
    my $receive = receive_from($scope, @events);
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my @received;
    $ws->each_message(async sub {
        my ($event) = @_;
        push @received, $event->{text};
    })->get;

    is(\@received, ['msg1', 'msg2', 'msg3'], 'received all messages');
    ok($ws->is_closed, 'connection closed after iteration');
};

subtest 'each_text iterates text frames' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', bytes => "\x00" },  # skipped
        { type => 'websocket.receive', text => 'hello' },
        { type => 'websocket.receive', text => 'world' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $send = sub { Future->done };
    my $scope   = ws_scope();
    my $receive = receive_from($scope, @events);
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my @received;
    $ws->each_text(async sub {
        my ($text) = @_;
        push @received, $text;
    })->get;

    is(\@received, ['hello', 'world'], 'received text messages only');
};

subtest 'each_bytes iterates binary frames' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'ignored' },
        { type => 'websocket.receive', bytes => "\x00\x01" },
        { type => 'websocket.receive', bytes => "\xff" },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $scope = ws_scope();
    my $ws = PAGI::WebSocket->new(
        $scope,
        receive_from($scope, @events),
        sub { Future->done },
    );
    $ws->accept->get;

    my @received;
    $ws->each_bytes(async sub { push @received, $_[0] })->get;

    is(\@received, ["\x00\x01", "\xff"],
        'each_bytes yields binary frames and skips text frames');
};

subtest 'each_json iterates and decodes' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => '{"n":1}' },
        { type => 'websocket.receive', text => '{"n":2}' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $send = sub { Future->done };
    my $scope   = ws_scope();
    my $receive = receive_from($scope, @events);
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my @received;
    $ws->each_json(async sub {
        my ($data) = @_;
        push @received, $data->{n};
    })->get;

    is(\@received, [1, 2], 'received and decoded JSON');
};

subtest 'callback can send responses' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'ping' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $scope   = ws_scope();
    my $receive = receive_from($scope, @events);
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;
    @sent = ();

    $ws->each_text(async sub {
        my ($text) = @_;
        await $ws->send_text("pong: $text");
    })->get;

    is($sent[0]{text}, 'pong: ping', 'callback sent response');
};

subtest 'exception in callback propagates' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'trigger' },
    );
    my $send = sub { Future->done };
    my $scope   = ws_scope();
    my $receive = receive_from($scope, @events);
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    like(
        dies {
            $ws->each_text(async sub {
                die "Intentional error";
            })->get;
        },
        qr/Intentional error/,
        'exception propagates'
    );
};

subtest 'each_message: on_close runs when the connection ends after a callback dies' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'boom' },
    );
    my $send = sub { Future->done };
    my $scope   = ws_scope();
    my $receive = receive_from($scope, @events);
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my $cleanup_ran = 0;
    $ws->on_close(async sub { $cleanup_ran = 1 });

    like(
        dies {
            $ws->each_message(async sub { die "boom in each_message\n" })->get;
        },
        qr/boom in each_message/,
        'exception still propagates'
    );

    ok(!$cleanup_ran, 'a dying callback alone does not start cleanup');

    # The handler died; the server ends the connection abnormally.
    $scope->{'pagi.connection'}->_mark_disconnected('server_error');

    ok($cleanup_ran, 'on_close ran despite each_message callback dying');
};

subtest 'each_text: on_close runs when the connection ends after a callback dies' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'boom' },
    );
    my $send = sub { Future->done };
    my $scope   = ws_scope();
    my $receive = receive_from($scope, @events);
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my $cleanup_ran = 0;
    $ws->on_close(async sub { $cleanup_ran = 1 });

    like(
        dies {
            $ws->each_text(async sub { die "boom in each_text\n" })->get;
        },
        qr/boom in each_text/,
        'exception still propagates'
    );

    ok(!$cleanup_ran, 'a dying callback alone does not start cleanup');

    # The handler died; the server ends the connection abnormally.
    $scope->{'pagi.connection'}->_mark_disconnected('server_error');

    ok($cleanup_ran, 'on_close ran despite each_text callback dying');
};

subtest 'each_bytes: on_close runs when the connection ends after a callback dies' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', bytes => "\x00\x01" },
    );
    my $send = sub { Future->done };
    my $scope   = ws_scope();
    my $receive = receive_from($scope, @events);
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my $cleanup_ran = 0;
    $ws->on_close(async sub { $cleanup_ran = 1 });

    like(
        dies {
            $ws->each_bytes(async sub { die "boom in each_bytes\n" })->get;
        },
        qr/boom in each_bytes/,
        'exception still propagates'
    );

    ok(!$cleanup_ran, 'a dying callback alone does not start cleanup');

    # The handler died; the server ends the connection abnormally.
    $scope->{'pagi.connection'}->_mark_disconnected('server_error');

    ok($cleanup_ran, 'on_close ran despite each_bytes callback dying');
};

subtest 'each_json: on_close runs when the connection ends after a callback dies' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => '{"n":1}' },
    );
    my $send = sub { Future->done };
    my $scope   = ws_scope();
    my $receive = receive_from($scope, @events);
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my $cleanup_ran = 0;
    $ws->on_close(async sub { $cleanup_ran = 1 });

    like(
        dies {
            $ws->each_json(async sub { die "boom in each_json\n" })->get;
        },
        qr/boom in each_json/,
        'exception still propagates'
    );

    ok(!$cleanup_ran, 'a dying callback alone does not start cleanup');

    # The handler died; the server ends the connection abnormally.
    $scope->{'pagi.connection'}->_mark_disconnected('server_error');

    ok($cleanup_ran, 'on_close ran despite each_json callback dying');
};

done_testing;
