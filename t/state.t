use strict;
use warnings;
use Test2::V0;

use PAGI::State qw(app_state);

{
    package Local::State::NoDefault;
    PAGI::State->import;
}

{
    package Local::State::Named;
    PAGI::State->import('app_state');
}

{
    package Local::State::All;
    PAGI::State->import(':ALL');
}

{
    package Local::State::Source;
    sub scope { return $_[0]{scope} }
}

ok(!Local::State::NoDefault->can('app_state'), 'app_state is not exported by default');
ok(Local::State::Named->can('app_state'), 'app_state is available as a named export');
ok(Local::State::All->can('app_state'), 'uppercase :ALL exports app_state');

my $lowercase_tag_error;
{
    local $SIG{__WARN__} = sub { };
    $lowercase_tag_error = dies { PAGI::State->import(':all') };
}
like($lowercase_tag_error, qr/"?:all"? is not defined|Can't continue/i,
    'lowercase :all is not an export tag');

my $state_import_error;
{
    local $SIG{__WARN__} = sub { };
    $state_import_error = dies { PAGI::State->import('state') };
}
like($state_import_error, qr/"?state"? is not exported|Can't continue/i,
    'state is not an export');

my $compiled = eval q{
    package Local::State::V540;
    use v5.40;
    use PAGI::State qw(app_state);
    sub build { app_state({ type => 'http', state => { db => 'pool' } }) }
    1;
};
ok($compiled, 'app_state imports in a v5.40 compilation unit') or diag($@);
isa_ok(Local::State::V540::build(), ['PAGI::State'], 'compiled import invokes app_state');

subtest 'construction and read access' => sub {
    my $scope = { type => 'http', state => { db => 'pool' } };
    my $state = app_state($scope);

    isa_ok($state, ['PAGI::State']);
    is($state->get('db'), 'pool', 'strict get returns a present value');
    is($state->get('optional', undef), undef, 'default get permits an absent key');
    like(dies { $state->get('typo') }, qr/State key 'typo'.*db/i,
        'strict get names the missing and available keys');
    ok($state->exists('db'), 'exists reports a present key');
    ok(!$state->exists('missing'), 'exists rejects an absent key');
    is([$state->keys], ['db'], 'keys returns state keys');
    is($state->data, exact_ref($scope->{state}), 'data returns the backing hashref');
    ok(!$state->can('set') && !$state->can('delete'), 'state has no mutation methods');

    like(dies { $state->get() }, qr/get.*1 or 2 arguments/i,
        'get rejects a missing key argument');
    like(dies { $state->get('a', 'b', 'c') }, qr/get.*1 or 2 arguments/i,
        'get rejects too many arguments');
};

subtest 'optional and malformed state' => sub {
    is(app_state({ type => 'http' }), undef, 'absent state is optional');
    isa_ok(app_state({ type => 'http', state => {} }), ['PAGI::State'],
        'an empty state hash is present');
    like(dies { app_state({ type => 'http', state => [] }) }, qr/state.*hashref/i,
        'a malformed present state dies');
};

subtest 'scope source normalization' => sub {
    my $scope = { type => 'http', state => { db => 'pool' } };
    my $source = bless { scope => $scope }, 'Local::State::Source';

    is(app_state($source)->data, exact_ref($scope->{state}),
        'an object with scope is accepted');
    like(dies { app_state() }, qr/exactly one scope hashref or object/i,
        'no source is rejected');
    like(dies { app_state($scope, $scope) }, qr/exactly one scope hashref or object/i,
        'multiple sources are rejected');
};

subtest 'deprecated hash dereference and warning policy' => sub {
    my $state = app_state({ type => 'http', state => { db => 'pool' } });
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    local $ENV{PAGI_SILENCE_STATE_HASHREF_WARNING};

    my ($first, $second) = ($state->{db}, $state->{db});
    is([$first, $second], ['pool', 'pool'], 'deprecated dereference still works');
    is(scalar @warnings, 1, 'one callsite warns only once');
    like($warnings[0], qr/deprecat.*data/i, 'warning points to the explicit data escape');

    my $third = $state->{db};
    is($third, 'pool', 'a second dereference callsite still works');
    is(scalar @warnings, 2, 'a second callsite warns separately');

    isnt(ref($state), 'HASH', 'overload does not fake hashref identity');
    is(ref($state->data), 'HASH', 'data is the explicit raw escape');
    my $before_method = scalar @warnings;
    is($state->get('db'), 'pool', 'methods do not recurse through hash overload');
    is(scalar @warnings, $before_method, 'methods do not warn');
};

subtest 'warning suppression requires exactly 1' => sub {
    my $state = app_state({ type => 'http', state => { db => 'pool' } });
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    {
        local $ENV{PAGI_SILENCE_STATE_HASHREF_WARNING} = '1';
        my $value = $state->{db};
        is($value, 'pool', 'exact suppression value preserves dereference');
    }
    is(scalar @warnings, 0, 'exact value 1 suppresses the warning');

    {
        local $ENV{PAGI_SILENCE_STATE_HASHREF_WARNING} = '0';
        my $value = $state->{db};
        is($value, 'pool', 'zero suppression value preserves dereference');
    }
    {
        local $ENV{PAGI_SILENCE_STATE_HASHREF_WARNING} = '';
        my $value = $state->{db};
        is($value, 'pool', 'empty suppression value preserves dereference');
    }
    {
        local $ENV{PAGI_SILENCE_STATE_HASHREF_WARNING};
        my $value = $state->{db};
        is($value, 'pool', 'missing suppression value preserves dereference');
    }
    is(scalar @warnings, 3, 'zero, empty, and missing values each warn');
};

done_testing;
