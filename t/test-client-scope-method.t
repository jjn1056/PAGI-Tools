#!/usr/bin/env perl

# =============================================================================
# Test: PAGI::Test::Client scope method field
#
# Per www.mkdn: SSE and WebSocket scopes must include the 'method' field
# just like HTTP scopes. This was a bug where the test client didn't include
# the method field in SSE/WebSocket scopes.
#
# GitHub issue: SSE scope method should be present (defaults to GET)
# =============================================================================

use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use Future::AsyncAwait;
use PAGI::Test::Client;

# =============================================================================
# SSE scope method tests
# =============================================================================

subtest 'SSE scope includes method field (default GET)' => sub {
    my $captured_scope;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;

        if ($scope->{type} eq 'sse') {
            await $send->({ type => 'sse.start', status => 200 });
            await $send->({ type => 'sse.send', data => 'test' });
        }
    };

    my $client = PAGI::Test::Client->new(app => $app);
    $client->sse('/events', sub {
        my ($sse) = @_;
        $sse->receive_event;
    });

    ok defined $captured_scope, 'scope was captured';
    is $captured_scope->{type}, 'sse', 'scope type is sse';
    ok exists $captured_scope->{method}, 'method field exists in SSE scope';
    is $captured_scope->{method}, 'GET', 'method defaults to GET';
};

subtest 'SSE scope supports custom method (POST)' => sub {
    my $captured_scope;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;

        if ($scope->{type} eq 'sse') {
            await $send->({ type => 'sse.start', status => 200 });
            await $send->({ type => 'sse.send', data => 'test' });
        }
    };

    my $client = PAGI::Test::Client->new(app => $app);
    $client->sse('/events', method => 'POST', sub {
        my ($sse) = @_;
        $sse->receive_event;
    });

    ok defined $captured_scope, 'scope was captured';
    is $captured_scope->{type}, 'sse', 'scope type is sse';
    is $captured_scope->{method}, 'POST', 'method is POST when specified';
};

subtest 'SSE method is uppercased' => sub {
    my $captured_scope;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;

        if ($scope->{type} eq 'sse') {
            await $send->({ type => 'sse.start', status => 200 });
            await $send->({ type => 'sse.send', data => 'test' });
        }
    };

    my $client = PAGI::Test::Client->new(app => $app);
    $client->sse('/events', method => 'put', sub {
        my ($sse) = @_;
        $sse->receive_event;
    });

    is $captured_scope->{method}, 'PUT', 'lowercase method is uppercased';
};

# =============================================================================
# WebSocket scope method tests
# =============================================================================

subtest 'WebSocket scope includes method field (always GET)' => sub {
    my $captured_scope;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;

        if ($scope->{type} eq 'websocket') {
            await $send->({ type => 'websocket.accept' });
            await $send->({ type => 'websocket.close', code => 1000 });
        }
    };

    my $client = PAGI::Test::Client->new(app => $app);
    $client->websocket('/ws', sub {
        my ($ws) = @_;
        # Just connect and let it close
    });

    ok defined $captured_scope, 'scope was captured';
    is $captured_scope->{type}, 'websocket', 'scope type is websocket';
    ok exists $captured_scope->{method}, 'method field exists in WebSocket scope';
    is $captured_scope->{method}, 'GET', 'WebSocket method is always GET';
};

# =============================================================================
# Verify method is usable for routing (user's use case)
# =============================================================================

subtest 'method can be used for route matching (sse.GET pattern)' => sub {
    my @matches;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        # User's pattern: join type and method with dot
        my $route_key = join('.', $scope->{type}, $scope->{method} // 'UNKNOWN');
        push @matches, $route_key;

        if ($scope->{type} eq 'sse') {
            await $send->({ type => 'sse.start', status => 200 });
            await $send->({ type => 'sse.send', data => 'done' });
        }
    };

    my $client = PAGI::Test::Client->new(app => $app);

    # Test GET SSE
    $client->sse('/events', sub {
        my ($sse) = @_;
        $sse->receive_event;
    });

    # Test POST SSE
    $client->sse('/events', method => 'POST', sub {
        my ($sse) = @_;
        $sse->receive_event;
    });

    is \@matches, ['sse.GET', 'sse.POST'], 'route keys match expected pattern';
};

done_testing;
