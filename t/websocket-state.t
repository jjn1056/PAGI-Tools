use strict;
use warnings;
use Test2::V0;

require PAGI::WebSocket;
use PAGI::Stash;
use lib 't/lib';
use PAGITest::Connected qw(ws_scope);

subtest 'state facade reads from scope' => sub {
    my $scope = ws_scope(
        path  => '/ws',
        state => { db => 'test-connection', room => 'lobby' },
    );

    my $ws = PAGI::WebSocket->new($scope, sub { }, sub { });

    my $state = $ws->state;
    ok($ws->has_state, 'has_state recognizes injected application state');
    isa_ok($state, ['PAGI::State']);
    is($state->get('db'), 'test-connection', 'state reads application data strictly');
    is($state->data, exact_ref($scope->{state}), 'facade keeps the exact scope state hash');
};

subtest 'state facade is absent when not set' => sub {
    my $scope = ws_scope(path => '/ws');

    my $missing = PAGI::WebSocket->new($scope, sub { }, sub { });

    ok(!$missing->has_state, 'has_state is false when application state is absent');
    is($missing->state, undef, 'state is undef when application state is absent');
};

subtest 'malformed state is rejected' => sub {
    my $malformed = PAGI::WebSocket->new(ws_scope(
        state => [],
    ), sub { }, sub { });

    like(
        dies { $malformed->has_state },
        qr/PAGI::WebSocket state must be a hashref/,
        'has_state rejects malformed present state',
    );
    like(
        dies { $malformed->state },
        qr/state.*hashref/i,
        'state rejects malformed present state',
    );
};

subtest 'state is separate from stash' => sub {
    my $scope = ws_scope(
        path  => '/ws',
        state => { db => 'connection' },
    );

    my $ws = PAGI::WebSocket->new($scope, sub { }, sub { });

    my $stash = PAGI::Stash->new($ws);
    $stash->set(room => 'lobby');

    is($ws->state->get('db'), 'connection', 'state has app data');
    is($stash->get('room'), 'lobby', 'stash has connection data');
    ok(!$ws->state->exists('room'), 'state does not have stash data');
};

subtest 'connection_state for internal state' => sub {
    my $scope = ws_scope(path => '/ws');

    my $ws = PAGI::WebSocket->new($scope, sub { }, sub { });

    is($ws->connection_state, 'connecting', 'connection_state returns internal state');
};

done_testing;
