use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Test::Client;

# PAGI::Test::Client records the disconnect detail PAGI::Server records for
# each terminal outcome (PAGI-Server's lib/PAGI/Server/Connection.pm, cited
# per case). A test-client behaviour change gets an UPGRADING entry.

# Runs $app under $protocol ('sse' or 'websocket'); returns the connection.
sub ended {
    my ($protocol, $app) = @_;
    my $c;
    my $client = PAGI::Test::Client->new(app => async sub {
        my ($scope, @channels) = @_;
        $c = $scope->{'pagi.connection'};
        await $app->(@channels);
    });
    eval { $client->$protocol('/'); 1 };
    return $c;
}

subtest 'an SSE app that dies after sse.start' => sub {
    # Connection.pm:7451, via _detail_from_error (:43-51): the first line,
    # without " at FILE line N".
    my $c = ended(sse => async sub {
        my ($receive, $send) = @_;
        await $send->({ type => 'sse.start' });
        die "the feed broke\nsecond line\n";
    });
    is($c->disconnect_reason, 'server_error', 'server_error');
    is($c->disconnect_detail, 'the feed broke', 'the first line');

    $c = ended(sse => async sub {
        my ($receive, $send) = @_;
        await $send->({ type => 'sse.start' });
        die 'the feed broke';
    });
    is($c->disconnect_detail, 'the feed broke', 'without the location Perl adds');
};

subtest 'an SSE app that dies before sse.start' => sub {
    # Connection.pm:1780-1781: _detail_from_error when the app failed.
    my $c = ended(sse => async sub { die "no feed today\n" });
    is($c->disconnect_detail, 'no feed today', 'the first line');
};

subtest 'an SSE app that returns without starting' => sub {
    # Connection.pm:7498 (and :1781): no response was started.
    my $c = ended(sse => async sub { return });
    is($c->disconnect_reason, 'server_error', 'server_error');
    is($c->disconnect_detail, 'no response was started', 'no response was started');
};

subtest 'an SSE app that returns after sse.start without sse.close' => sub {
    # Connection.pm:7451.
    my $c = ended(sse => async sub {
        my ($receive, $send) = @_;
        await $send->({ type => 'sse.start' });
    });
    is($c->disconnect_detail, 'sse.start without sse.close', 'sse.start without sse.close');
};

for my $protocol ('sse', 'websocket') {
    subtest "a $protocol refusal left unfinished" => sub {
        # Connection.pm:7475 (SSE) and :8197 (WebSocket).
        my $c = ended($protocol => async sub {
            my ($receive, $send) = @_;
            await $send->({ type => 'http.response.start', status => 403, headers => [] });
            await $send->({ type => 'http.response.body', body => 'no', more => 1 });
        });
        is($c->disconnect_reason, 'server_error', 'server_error');
        is($c->disconnect_detail, 'refusal started but never completed',
            'refusal started but never completed');
    };
}

subtest 'a WebSocket app that returns without a closing handshake' => sub {
    # Connection.pm:8261.
    my $c = ended(websocket => async sub {
        my ($receive, $send) = @_;
        await $receive->();
        await $send->({ type => 'websocket.accept' });
    });
    is($c->disconnect_reason, 'server_error', 'server_error');
    is($c->disconnect_detail, 'accepted socket left without a closing handshake',
        'accepted socket left without a closing handshake');
};

done_testing;
