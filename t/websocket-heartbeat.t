use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use PAGI::WebSocket;

# Mock scope, receive, send for testing
my $scope = {
    type    => 'websocket',
    path    => '/test',
    headers => [],
};

my @sent_messages;
my $send = sub {
    my ($msg) = @_;
    push @sent_messages, $msg;
    return Future->done;
};

my $receive = sub { Future->done({ type => 'websocket.connect' }) };

subtest 'start_heartbeat method exists' => sub {
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    ok($ws->can('start_heartbeat'), 'start_heartbeat method exists');
};

subtest 'start_heartbeat returns self for chaining' => sub {
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->_set_state('connected');
    my $result = $ws->start_heartbeat(25);
    is(ref($result), ref($ws), 'returns same type');
    ok($result == $ws, 'returns $self for chaining');
};

subtest 'start_heartbeat with 0 interval does nothing' => sub {
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->_set_state('connected');
    my $result = $ws->start_heartbeat(0);
    is($result, $ws, 'returns $self');
    ok(!exists $ws->{_heartbeat_timer}, 'no timer created for 0 interval');
};

subtest 'stop_heartbeat method exists' => sub {
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    ok($ws->can('stop_heartbeat'), 'stop_heartbeat method exists');
};

subtest 'param method for route parameters' => sub {
    my $scope_with_params = {
        type    => 'websocket',
        path    => '/test',
        headers => [],
        'pagi.router' => { params => { id => '42', name => 'test' } },
    };
    my $ws = PAGI::WebSocket->new($scope_with_params, $receive, $send);

    is($ws->param('id'), '42', 'param returns route parameter');
    is($ws->param('name'), 'test', 'param returns another route parameter');
    is($ws->param('missing'), undef, 'param returns undef for missing');
};

subtest 'params method returns all route parameters' => sub {
    my $scope_with_params = {
        type    => 'websocket',
        path    => '/test',
        headers => [],
        'pagi.router' => { params => { foo => 'bar', baz => 'qux' } },
    };
    my $ws = PAGI::WebSocket->new($scope_with_params, $receive, $send);

    my $params = $ws->params;
    is($params, { foo => 'bar', baz => 'qux' }, 'params returns all route params');
};

subtest 'param returns undef when no route params in scope' => sub {
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    is($ws->param('anything'), undef, 'param returns undef when no params');
    is($ws->params, {}, 'params returns empty hash when no params');
};

done_testing;
