use strict;
use warnings;
use Test2::V0;
use PAGI::Utils qw(:env);

my @canonical = qw(development test staging production);
my @predicates = (
    [development => \&is_development],
    [test        => \&is_test],
    [staging     => \&is_staging],
    [production  => \&is_production],
);

subtest 'unset and empty default to production' => sub {
    local $ENV{PAGI_ENV};
    delete $ENV{PAGI_ENV};
    is(pagi_env(), 'production', 'unset defaults safely');
    ok(is_production(), 'unset satisfies the production predicate');

    $ENV{PAGI_ENV} = '';
    is(pagi_env(), 'production', 'empty defaults safely');
    ok(is_production(), 'empty satisfies the production predicate');
};

subtest 'canonical values and predicates share one contract' => sub {
    for my $environment (@canonical) {
        local $ENV{PAGI_ENV} = $environment;
        is(pagi_env(), $environment, "$environment is returned unchanged");
        for my $predicate (@predicates) {
            my ($name, $code) = @$predicate;
            is($code->() ? 1 : 0, $name eq $environment ? 1 : 0,
                "$name predicate for $environment");
        }
    }
};

subtest 'lookup is dynamic rather than cached' => sub {
    local $ENV{PAGI_ENV} = 'development';
    is(pagi_env(), 'development', 'first call sees development');
    $ENV{PAGI_ENV} = 'staging';
    is(pagi_env(), 'staging', 'next call sees the localized change');
    ok(is_staging(), 'predicate sees the same change');
};

subtest 'invalid nonempty values fail with the canonical list' => sub {
    for my $invalid ('Development', ' development', 'development ',
        'dev', 'prod', 'developement') {
        local $ENV{PAGI_ENV} = $invalid;
        like(
            dies { pagi_env() },
            qr/Invalid PAGI_ENV '\Q$invalid\E'; expected one of: development, test, staging, production/,
            "rejects [$invalid]",
        );
    }
};

subtest 'public helpers reject every argument' => sub {
    my @calls = (
        [pagi_env       => sub { pagi_env(undef) }],
        [is_development => sub { is_development('development') }],
        [is_test        => sub { is_test(undef) }],
        [is_staging     => sub { is_staging('staging') }],
        [is_production  => sub { is_production('production') }],
    );
    for my $call (@calls) {
        my ($name, $code) = @$call;
        like(dies { $code->() }, qr/\Q$name\E\(\) does not accept arguments/,
            "$name rejects arguments");
    }
};

subtest 'exports are optional and bundled' => sub {
    my @helpers = qw(pagi_env is_development is_test is_staging is_production);

    eval q{ package Local::NoEnvironmentExports; PAGI::Utils->import(); 1 }
        or die $@;
    ok(!Local::NoEnvironmentExports->can($_), "$_ is not default-exported")
        for @helpers;

    eval q{ package Local::EnvironmentExports; PAGI::Utils->import(':env'); 1 }
        or die $@;
    ok(Local::EnvironmentExports->can($_), ":env exports $_") for @helpers;
    ok(!Local::EnvironmentExports->can('app_path'),
        ':env contains no unrelated Utils helper');

    eval q{ package Local::AllUtilsExports; PAGI::Utils->import(':all'); 1 }
        or die $@;
    ok(Local::AllUtilsExports->can($_), ":all exports $_") for @helpers;
    ok(Local::AllUtilsExports->can('app_path'),
        ':all retains existing Utils helpers');

    is([sort @{$PAGI::Utils::EXPORT_TAGS{env}}], [sort @helpers],
        ':env contains exactly the five environment helpers');
};

done_testing;
