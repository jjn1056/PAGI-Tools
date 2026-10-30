#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::Endpoint::WebSocket;
use PAGI::WebSocket;
use PAGI::Routing qw(router websocket);
use lib 't/lib';
use PAGITest::Connected qw(ws_scope receive_from);

package SimpleWSEndpoint {
    use parent 'PAGI::Endpoint::WebSocket';
    use Future::AsyncAwait;

    async sub on_connect {
        my ($self, $websocket) = @_;
        await $websocket->accept;
        await $websocket->send_text("Welcome!");
    }
}

subtest 'to_app returns PAGI-compatible coderef' => sub {
    my $app = SimpleWSEndpoint->new->to_app;

    ref_ok($app, 'CODE', 'to_app returns coderef');
};

subtest 'app creates a WebSocket wrapper and calls handle' => sub {
    my $app = SimpleWSEndpoint->new->to_app;

    my @sent;
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.disconnect', code => 1000 },
    );

    my $scope   = ws_scope(path => '/ws');
    my $receive = receive_from($scope, @events);
    my $send = sub { push @sent, $_[0]; Future->done };

    $app->($scope, $receive, $send)->get;

    ok(@sent > 0, 'sent events');
    is($sent[0]{type}, 'websocket.accept', 'accepted connection');
};

subtest 'websocket route accepts a configured endpoint object' => sub {
    {
        package RoutedConfiguredWebSocketEndpoint;
        use parent 'PAGI::Endpoint::WebSocket';
        our @hubs;

        sub on_connect {
            push @hubs, $_[0]->{hub};
            return $_[1]->accept;
        }
    }

    @RoutedConfiguredWebSocketEndpoint::hubs = ();
    my $hub = {};
    my $configured = RoutedConfiguredWebSocketEndpoint->new(hub => $hub);
    my $app = router(routes => [
        websocket('/chat' => $configured),
    ])->to_app;

    my $scope = ws_scope(path => '/chat');
    $app->(
        $scope,
        receive_from($scope, { type => 'websocket.disconnect', code => 1000 }),
        sub { Future->done },
    )->get;

    is \@RoutedConfiguredWebSocketEndpoint::hubs, [$hub],
        'websocket route uses the configured endpoint object';
};

subtest 'app builds its own WebSocket, never one built earlier over the scope' => sub {
    {
        package CacheAwareEndpoint;
        use parent 'PAGI::Endpoint::WebSocket';
        our $seen;
        sub on_connect {
            ($seen) = $_[1];
            return $_[1]->accept;
        }
    }

    my $scope = ws_scope(path => '/ws');
    my $receive = receive_from($scope, { type => 'websocket.disconnect', code => 1000 });
    my $earlier = PAGI::WebSocket->new($scope, $receive, sub { Future->done });
    $CacheAwareEndpoint::seen = undef;

    CacheAwareEndpoint->new->to_app->($scope, $receive, sub { Future->done })->get;

    isa_ok($CacheAwareEndpoint::seen, ['PAGI::WebSocket'],
        'the endpoint receives a WebSocket');
    isnt(refaddr($CacheAwareEndpoint::seen), refaddr($earlier),
        'a new one, not the one built earlier (RV1)');
    is(refaddr($CacheAwareEndpoint::seen->scope), refaddr($scope),
        'over the scope the endpoint was called with');
    ok(!exists $scope->{'pagi.websocket'}, 'nothing is cached in the scope');
};

done_testing;
