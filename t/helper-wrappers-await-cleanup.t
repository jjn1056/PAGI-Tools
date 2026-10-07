use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 't/lib';
use PAGITest::Connected qw(ws_scope sse_scope);
use PAGI::Compose qw(compose);
use PAGI::Routing qw(websocket sse);
use PAGI::Endpoint::WebSocket;
use PAGI::Endpoint::SSE;
use PAGI::Test::Client;

# Each wrapper that runs a helper handler ends its call only after the scope
# has ended and the helper's on_close cleanup has finished.

my $gate;
my $accept_first = 1;

{
    package TestCleanupWS;
    use parent -norequire, 'PAGI::Endpoint::WebSocket';
    use Future::AsyncAwait;
    async sub handle {
        my ($self, $ws) = @_;
        $ws->on_close(sub { $gate });
        await $ws->accept if $accept_first;
        return;
    }
}
{
    package TestCleanupSSE;
    use parent -norequire, 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;
    async sub handle {
        my ($self, $sse) = @_;
        $sse->on_close(sub { $gate });
        await $sse->start if $accept_first;
        return;
    }
}

my $ws_handler = async sub {
    my ($ws) = @_;
    $ws->on_close(sub { $gate });
    await $ws->accept if $accept_first;
};
my $sse_handler = async sub {
    my ($sse) = @_;
    $sse->on_close(sub { $gate });
    await $sse->start if $accept_first;
};

my @wrappers = (
    [ 'websocket route', sub { ws_scope(path => '/x') },
      compose(routes => [ websocket('/x' => $ws_handler) ])->to_app ],
    [ 'sse route', sub { sse_scope(path => '/x') },
      compose(routes => [ sse('/x' => $sse_handler) ])->to_app ],
    [ 'PAGI::Endpoint::WebSocket', sub { ws_scope(path => '/x') }, TestCleanupWS->to_app ],
    [ 'PAGI::Endpoint::SSE', sub { sse_scope(path => '/x') }, TestCleanupSSE->to_app ],
);

for my $wrapper (@wrappers) {
    my ($name, $make_scope, $app) = @$wrapper;
    subtest "$name: the call waits for the scope end, then the cleanup" => sub {
        $gate = Future->new;
        $accept_first = 1;
        my $scope = $make_scope->();
        my $call = $app->($scope, sub { Future->new }, sub { Future->done });
        ok(!$call->is_ready, 'waits for the scope to end');
        $scope->{'pagi.connection'}->_mark_complete;
        ok(!$call->is_ready, 'then for on_close');
        $gate->done;
        ok($call->is_done, 'then completes');
    };
    subtest "$name: a handler that returns before accepting does not hang" => sub {
        $gate = Future->done;
        $accept_first = 0;
        my $call = $app->($make_scope->(), sub { Future->new }, sub { Future->done });
        ok($call->is_ready, 'the call completes');
    };
}

subtest "a routed call under the test kit's manual close mode waits for the handshake" => sub {
    my %state;
    my $app = compose(routes => [ websocket('/x' => async sub {
        my ($ws) = @_;
        $ws->on_close(sub { $state{cleaned}++; return });
        await $ws->accept;
        await $ws->close;
        $state{handler_returned} = 1;
    }) ])->to_app;
    my $ws = PAGI::Test::Client->new(app => $app)->websocket('/x', close_mode => 'manual');
    ok($state{handler_returned}, 'the handler returned after sending its Close');
    ok(!$state{cleaned}, 'on_close waits for the closing handshake');
    ok(!$ws->{app_future}->is_ready, "the route's call waits for it too");
    $ws->close;            # the peer answers the Close
    $ws->complete_close;   # and the transport completes
    is($state{cleaned}, 1, 'then on_close runs');
    ok($ws->{app_future}->is_done, "and the route's call completes");
};

done_testing;
