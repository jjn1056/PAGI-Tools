use strict;
use warnings;
use Test2::V0;

require PAGI::Request;
use PAGI::Stash;

sub request_for {
    my ($scope) = @_;
    return PAGI::Request->new($scope, sub { die 'body unavailable' });
}

subtest 'absent state is optional' => sub {
    my $request = request_for({ type => 'http' });

    ok(!$request->has_state, 'has_state is false when state is absent');
    is($request->state, undef, 'state is undef when absent');
};

subtest 'empty and populated state return a strict facade' => sub {
    my $empty_request = request_for({ type => 'http', state => {} });
    ok($empty_request->has_state, 'an empty state hash is present');
    isa_ok($empty_request->state, ['PAGI::State'], 'empty state returns a facade');

    my $scope = {
        type  => 'http',
        state => { db => 'test-connection', config => { env => 'test' } },
    };
    my $request = request_for($scope);
    my $state = $request->state;

    ok($request->has_state, 'has_state is true for a state hash');
    isa_ok($state, ['PAGI::State']);
    is($state->get('db'), 'test-connection', 'state reads application data');
    is($state->get('config')->{env}, 'test', 'state preserves nested values');
    like(dies { $state->get('missing') }, qr/State key 'missing'.*config.*db|State key 'missing'.*db.*config/i,
        'request state access is strict');
    is($request->state->data, exact_ref($scope->{state}),
        'repeated access uses the same backing data without promising facade identity');
};

subtest 'malformed present state is rejected' => sub {
    for my $malformed ([], 'state', bless({}, 'Local::State::HashObject')) {
        my $request = request_for({ type => 'http', state => $malformed });
        like(dies { $request->has_state }, qr/Request state.*hashref/i,
            'has_state validates the present state shape');
        like(dies { $request->state }, qr/state.*hashref/i,
            'state validates the present state shape');
    }
};

subtest 'application state is separate from request stash' => sub {
    my $scope = { type => 'http', state => { db => 'connection' } };
    my $request = request_for($scope);
    my $stash = PAGI::Stash->new($request);
    $stash->set(user => 'alice');

    is($request->state->get('db'), 'connection', 'state has application data');
    is($stash->get('user'), 'alice', 'stash has request data');
    ok(!$request->state->exists('user'), 'state does not contain stash data');
    ok(!$stash->exists('db'), 'stash does not contain state data');
};

done_testing;
