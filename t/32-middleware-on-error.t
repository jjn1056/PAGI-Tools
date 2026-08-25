#!/usr/bin/env perl

# =============================================================================
# Test: Middleware callback config storage
#
# Verifies that RequestId properly stores and invokes its generator
# callback config, both the default and a custom override.
# =============================================================================

use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

# =============================================================================
# Test: RequestId generator config
# =============================================================================

subtest 'RequestId generator config' => sub {
    require PAGI::Middleware::RequestId;

    # Test default generator exists
    my $mw = PAGI::Middleware::RequestId->new();
    ok($mw->{generator}, 'default generator callback exists');
    is(ref($mw->{generator}), 'CODE', 'generator is a coderef');

    # Test custom generator is stored
    my $custom_called = 0;
    my $custom_scope;

    my $mw2 = PAGI::Middleware::RequestId->new(
        generator => sub {
            my ($scope) = @_;
            $custom_called = 1;
            $custom_scope = $scope;
            return 'custom-id';
        },
    );

    # Invoke the callback manually to verify it's wired up
    my $id = $mw2->{generator}->({ type => 'http' });
    ok($custom_called, 'custom generator callback was invoked');
    is($custom_scope, { type => 'http' }, 'scope passed correctly');
    is($id, 'custom-id', 'return value passed correctly');
};

done_testing;
