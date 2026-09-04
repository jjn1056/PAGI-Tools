use strict;
use warnings;
use Test2::V0;

require PAGI::SSE;

subtest 'state facade reads from scope' => sub {
    my $scope = {
        type    => 'sse',
        path    => '/events',
        headers => [],
        state => { db => 'test-connection', room => 'lobby' },
    };

    my $sse = PAGI::SSE->new($scope, sub { }, sub { });

    my $state = $sse->state;
    ok($sse->has_state, 'has_state recognizes injected application state');
    isa_ok($state, ['PAGI::State']);
    is($state->get('db'), 'test-connection', 'state reads application data strictly');
    is($state->data, exact_ref($scope->{state}), 'facade keeps the exact scope state hash');
};

subtest 'state facade is absent when not set' => sub {
    my $scope = {
        type    => 'sse',
        path    => '/events',
        headers => [],
    };

    my $missing = PAGI::SSE->new($scope, sub { }, sub { });

    ok(!$missing->has_state, 'has_state is false when application state is absent');
    is($missing->state, undef, 'state is undef when application state is absent');
};

subtest 'malformed state is rejected' => sub {
    my $malformed = PAGI::SSE->new({
        type  => 'sse',
        state => [],
    }, sub { }, sub { });

    like(
        dies { $malformed->has_state },
        qr/PAGI::SSE state must be a hashref/,
        'has_state rejects malformed present state',
    );
    like(
        dies { $malformed->state },
        qr/state.*hashref/i,
        'state rejects malformed present state',
    );
};

subtest 'connection_state for internal state' => sub {
    my $scope = {
        type    => 'sse',
        path    => '/events',
        headers => [],
    };

    my $sse = PAGI::SSE->new($scope, sub { }, sub { });

    is($sse->connection_state, 'pending', 'connection_state returns internal state');
};

done_testing;
