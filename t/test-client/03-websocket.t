#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Time::HiRes ();

use PAGI::Test::Client;

# Simple echo WebSocket app
my $echo_app = async sub {
    my ($scope, $receive, $send) = @_;
    return unless $scope->{type} eq 'websocket';

    my $event = await $receive->();
    return unless $event->{type} eq 'websocket.connect';

    await $send->({ type => 'websocket.accept' });

    while (1) {
        my $msg = await $receive->();
        last if $msg->{type} eq 'websocket.disconnect';

        if (defined $msg->{text}) {
            await $send->({ type => 'websocket.send', text => "echo: $msg->{text}" });
        } elsif (defined $msg->{bytes}) {
            await $send->({ type => 'websocket.send', bytes => $msg->{bytes} });
        }
    }
};

subtest 'websocket text echo - callback style' => sub {
    my $client = PAGI::Test::Client->new(app => $echo_app);

    $client->websocket('/ws', sub {
        my ($ws) = @_;
        $ws->send_text('hello');
        is $ws->receive_text, 'echo: hello', 'echoed text';
        $ws->send_text('world');
        is $ws->receive_text, 'echo: world', 'echoed again';
    });

    pass 'websocket closed cleanly';
};

subtest 'websocket explicit style' => sub {
    my $client = PAGI::Test::Client->new(app => $echo_app);

    my $ws = $client->websocket('/ws');
    ok !$ws->is_closed, 'connection is open';

    $ws->send_text('test');
    is $ws->receive_text, 'echo: test', 'explicit style works';

    $ws->close;
    ok $ws->is_closed, 'connection is closed';
    is $ws->close_code, 1000, 'close code is 1000';
};

subtest 'websocket binary echo' => sub {
    my $client = PAGI::Test::Client->new(app => $echo_app);

    $client->websocket('/ws', sub {
        my ($ws) = @_;
        my $bytes = "\x00\x01\x02\x03";
        $ws->send_bytes($bytes);
        is $ws->receive_bytes, $bytes, 'echoed bytes';
    });
};

subtest 'websocket json convenience' => sub {
    # JSON echo app
    my $json_app = async sub {
        my ($scope, $receive, $send) = @_;
        return unless $scope->{type} eq 'websocket';

        my $event = await $receive->();
        return unless $event->{type} eq 'websocket.connect';

        await $send->({ type => 'websocket.accept' });

        while (1) {
            my $msg = await $receive->();
            last if $msg->{type} eq 'websocket.disconnect';

            if (defined $msg->{text}) {
                # Parse JSON, modify, send back
                require JSON::MaybeXS;
                my $data = JSON::MaybeXS::decode_json($msg->{text});
                $data->{echoed} = 1;
                my $response = JSON::MaybeXS::encode_json($data);
                await $send->({ type => 'websocket.send', text => $response });
            }
        }
    };

    my $client = PAGI::Test::Client->new(app => $json_app);

    $client->websocket('/api', sub {
        my ($ws) = @_;
        $ws->send_json({ action => 'ping', id => 123 });
        my $data = $ws->receive_json;
        is $data->{action}, 'ping', 'action preserved';
        is $data->{id}, 123, 'id preserved';
        is $data->{echoed}, 1, 'echoed flag added';
    });
};

subtest 'websocket path and query string' => sub {
    my $path_app = async sub {
        my ($scope, $receive, $send) = @_;
        return unless $scope->{type} eq 'websocket';

        my $event = await $receive->();
        return unless $event->{type} eq 'websocket.connect';

        await $send->({ type => 'websocket.accept' });

        my $msg = await $receive->();
        if ($msg->{type} eq 'websocket.receive') {
            my $response = "path=$scope->{path} query=$scope->{query_string}";
            await $send->({ type => 'websocket.send', text => $response });
        }
    };

    my $client = PAGI::Test::Client->new(app => $path_app);

    $client->websocket('/chat/room1?token=abc', sub {
        my ($ws) = @_;
        $ws->send_text('test');
        is $ws->receive_text, 'path=/chat/room1 query=token=abc', 'path and query parsed';
    });
};

subtest 'websocket close handling' => sub {
    my $client = PAGI::Test::Client->new(app => $echo_app);

    my $ws = $client->websocket('/ws');

    $ws->send_text('before close');
    is $ws->receive_text, 'echo: before close', 'message before close';

    ok !$ws->is_closed, 'not closed yet';

    $ws->close(1000, 'normal closure');

    ok $ws->is_closed, 'connection closed';
    is $ws->close_code, 1000, 'close code recorded';
    is $ws->close_reason, 'normal closure', 'close reason recorded';
};

subtest 'websocket error on send after close' => sub {
    my $client = PAGI::Test::Client->new(app => $echo_app);

    my $ws = $client->websocket('/ws');
    $ws->close;

    like dies { $ws->send_text('test') },
        qr/Cannot send on closed WebSocket/,
        'dies when sending on closed connection';
};

subtest 'websocket receive timeout' => sub {
    # App that never sends anything
    my $silent_app = async sub {
        my ($scope, $receive, $send) = @_;
        return unless $scope->{type} eq 'websocket';

        my $event = await $receive->();
        return unless $event->{type} eq 'websocket.connect';

        await $send->({ type => 'websocket.accept' });

        # Wait for disconnect, but never send anything
        while (1) {
            my $msg = await $receive->();
            last if $msg->{type} eq 'websocket.disconnect';
        }
    };

    my $client = PAGI::Test::Client->new(app => $silent_app);

    my $ws = $client->websocket('/ws');

    my $started = Time::HiRes::time();
    like dies { $ws->receive_text(0.5) },
        qr/Timeout waiting for WebSocket text message/,
        'receive_text times out';
    ok(Time::HiRes::time() - $started >= 0.4, 'after its timeout, not at once');

    $ws->close;
};

subtest 'receive_text waits for a message sent after real I/O' => sub {
    require Future::IO;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $event = await $receive->();
        return unless $event->{type} eq 'websocket.connect';
        await $send->({ type => 'websocket.accept' });
        await Future::IO->sleep(0.2);
        await $send->({ type => 'websocket.send', text => 'after sleep' });
        while (1) {
            my $msg = await $receive->();
            last if $msg->{type} eq 'websocket.disconnect';
        }
    };
    my $ws = PAGI::Test::Client->new(app => $app)->websocket('/ws');
    is($ws->receive_text(2), 'after sleep', 'the message arrives');
    $ws->close;
};

subtest 'receive gives up at once when no more data can arrive' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $event = await $receive->();
        return unless $event->{type} eq 'websocket.connect';
        await $send->({ type => 'websocket.accept' });
        await $send->({ type => 'websocket.close', code => 1000 });
        while (1) {
            my $msg = await $receive->();
            last if $msg->{type} eq 'websocket.disconnect';
        }
    };
    my $ws = PAGI::Test::Client->new(app => $app)->websocket('/ws', close_mode => 'manual');
    my $started = Time::HiRes::time();
    like dies { $ws->receive_text(2) }, qr/Timeout waiting for WebSocket text message/,
        'after the app\'s Close, nothing more is coming';
    ok(Time::HiRes::time() - $started < 1, 'so it does not wait out the timeout');
    $ws->close;
    $ws->complete_close;
};

subtest 'a handler that awaits real I/O before accept connects' => sub {
    require Future::IO;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $event = await $receive->();
        return unless $event->{type} eq 'websocket.connect';
        await Future::IO->sleep(0.1);
        await $send->({ type => 'websocket.accept' });
        await $send->({ type => 'websocket.send', text => 'hello' });
        while (1) {
            my $msg = await $receive->();
            last if $msg->{type} eq 'websocket.disconnect';
        }
    };
    my $ws = PAGI::Test::Client->new(app => $app)->websocket('/ws');
    is($ws->receive_text(2), 'hello', 'the connection is accepted');
    $ws->close;
};

subtest 'an app Close that arrives during a receive ends the wait' => sub {
    require Future::IO;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $event = await $receive->();
        return unless $event->{type} eq 'websocket.connect';
        await $send->({ type => 'websocket.accept' });
        await Future::IO->sleep(0.2);
        await $send->({ type => 'websocket.close', code => 1000 });
        while (1) {
            my $msg = await $receive->();
            last if $msg->{type} eq 'websocket.disconnect';
        }
    };
    my $ws = PAGI::Test::Client->new(app => $app)->websocket('/ws', close_mode => 'manual');
    my $started = Time::HiRes::time();
    like dies { $ws->receive_text(1.5) }, qr/Timeout waiting for WebSocket text message/,
        'no more data can arrive after the app\'s Close';
    ok(Time::HiRes::time() - $started < 1, 'so the wait ends when the Close arrives');
    $ws->close;
    $ws->complete_close;
};

subtest 'a handshake that times out is abandoned' => sub {
    require Future::IO;
    local $PAGI::Test::_Drive::TIMEOUT = 0.2;
    my $resumed = 0;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $event = await $receive->();
        return unless $event->{type} eq 'websocket.connect';
        await Future::IO->sleep(0.4);
        $resumed = 1;
        await $send->({ type => 'websocket.accept' });
    };
    like(dies { PAGI::Test::Client->new(app => $app)->websocket('/ws') },
        qr/WebSocket handshake did not complete within 0\.2 seconds/, 'it says it timed out');
    Future::IO->sleep(0.4)->get;    # drive the loop past the handler's wake-up
    is($resumed, 0, 'and the handler does not resume later');
};

done_testing;
