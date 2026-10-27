use strict;
use warnings;
use Test2::V0;

require PAGI::Request;
use PAGI::Stash;

sub request_for {
    my ($scope) = @_;
    return PAGI::Request->new($scope, sub { die 'body unavailable' });
}

subtest 'absent state is an empty facade whose get and data say why' => sub {
    my $request = request_for({ type => 'http' });

    ok(!$request->has_state, 'has_state is false when state is absent');
    my $state = $request->state;
    isa_ok($state, ['PAGI::State'], 'state is a facade even when absent');
    is([$state->keys], [], 'and it is empty');
    like(dies { $state->get('notes') },
        qr/\AState key 'notes' does not exist: this scope has no application state \(did lifespan startup run\? PAGI::Test::Client needs lifespan => 1\) at /,
        'get names the likely cause');
    like(dies { $state->data },
        qr/\AState data is unavailable: this scope has no application state \(did lifespan startup run\? PAGI::Test::Client needs lifespan => 1\) at /,
        'data does too');
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
    like(dies { $state->get('missing') }, qr/\AState key 'missing' does not exist\. Available keys: config, db at /,
        'request state access is strict, with the message unchanged');
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
    my $scope = { type => 'http', state => { db => 'connection' }, 'pagi.stash' => {} };
    my $request = request_for($scope);
    my $stash = PAGI::Stash->new($request);
    $stash->set(user => 'alice');

    is($request->state->get('db'), 'connection', 'state has application data');
    is($stash->get('user'), 'alice', 'stash has request data');
    ok(!$request->state->exists('user'), 'state does not contain stash data');
    ok(!$stash->exists('db'), 'stash does not contain state data');
};

done_testing;
