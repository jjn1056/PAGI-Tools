use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

# Load the module
my $loaded = eval { require PAGI::Endpoint::Router; 1 };
ok($loaded, 'PAGI::Endpoint::Router loads') or diag $@;

subtest 'basic class structure' => sub {
    ok(PAGI::Endpoint::Router->can('new'), 'has new');
    ok(PAGI::Endpoint::Router->can('to_app'), 'has to_app');
    ok(PAGI::Endpoint::Router->can('stash'), 'has stash');
    ok(PAGI::Endpoint::Router->can('routes'), 'has routes');
    ok(PAGI::Endpoint::Router->can('on_startup'), 'has on_startup');
    ok(PAGI::Endpoint::Router->can('on_shutdown'), 'has on_shutdown');
};

subtest 'stash is a hashref' => sub {
    my $router = PAGI::Endpoint::Router->new;
    is(ref($router->stash), 'HASH', 'stash is hashref');

    $router->stash->{test} = 'value';
    is($router->stash->{test}, 'value', 'stash persists values');
};

subtest 'to_app returns coderef' => sub {
    my $app = PAGI::Endpoint::Router->to_app;
    is(ref($app), 'CODE', 'to_app returns coderef');
};

done_testing;
