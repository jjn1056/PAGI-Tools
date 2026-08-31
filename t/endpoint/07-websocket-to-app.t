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

{
    package Local::WrongWebSocketCache;
    sub new { return bless { scope => $_[1] }, $_[0] }
    sub scope { return $_[0]{scope} }
}

{
    package Local::DyingWebSocketCache;
    sub new { return bless {}, $_[0] }
    sub scope { die 'cached scope exploded' }
}

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
    my $app = SimpleWSEndpoint->to_app;

    ref_ok($app, 'CODE', 'to_app returns coderef');
};

subtest 'app creates a WebSocket wrapper and calls handle' => sub {
    my $app = SimpleWSEndpoint->to_app;

    my @sent;
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $idx = 0;

    my $scope = { type => 'websocket', path => '/ws', headers => [] };
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { push @sent, $_[0]; Future->done };

    $app->($scope, $receive, $send)->get;

    ok(@sent > 0, 'sent events');
    is($sent[0]{type}, 'websocket.accept', 'accepted connection');
};

subtest 'one compiled app constructs a fresh endpoint for each connection' => sub {
    {
        package FreshWebSocketEndpoint;
        use parent 'PAGI::Endpoint::WebSocket';
        our @instances;
        sub on_connect {
            push @instances, $_[0];
            return $_[1]->accept;
        }
    }

    @FreshWebSocketEndpoint::instances = ();
    my $app = FreshWebSocketEndpoint->to_app;
    for my $connection (1, 2) {
        $app->(
            { type => 'websocket', path => "/ws/$connection", headers => [] },
            sub { Future->done({ type => 'websocket.disconnect', code => 1000 }) },
            sub { Future->done },
        )->get;
    }

    is(scalar @FreshWebSocketEndpoint::instances, 2,
        'both connections reached their endpoint instance');
    isnt(refaddr($FreshWebSocketEndpoint::instances[0]),
        refaddr($FreshWebSocketEndpoint::instances[1]),
        'the compiled app does not retain endpoint state between connections');
};

subtest 'app reuses only a compatible exact-scope WebSocket cache' => sub {
    {
        package CacheAwareEndpoint;
        use parent 'PAGI::Endpoint::WebSocket';
        our $seen;
        sub on_connect {
            ($seen) = $_[1];
            return $_[1]->accept;
        }
    }

    for my $case (
        'parent WebSocket',
        'wrong class',
        'throwing scope',
        'same scope WebSocket',
    ) {
        subtest $case => sub {
            my $scope = { type => 'websocket', path => '/ws', headers => [] };
            my $parent_scope = { type => 'websocket', path => '/parent', headers => [] };
            my $parent = PAGI::WebSocket->new(
                $parent_scope, sub { Future->done }, sub { Future->done },
            );
            my $cached = $case eq 'parent WebSocket'
                ? $parent
                : $case eq 'wrong class'
                    ? Local::WrongWebSocketCache->new($scope)
                    : $case eq 'throwing scope'
                        ? Local::DyingWebSocketCache->new
                        : PAGI::WebSocket->new(
                            $scope, sub { Future->done }, sub { Future->done },
                        );
            $scope->{'pagi.websocket'} = $cached;
            $CacheAwareEndpoint::seen = undef;

            CacheAwareEndpoint->to_app->(
                $scope,
                sub { Future->done({ type => 'websocket.disconnect', code => 1000 }) },
                sub { Future->done },
            )->get;

            isa_ok($CacheAwareEndpoint::seen, ['PAGI::WebSocket'],
                'the endpoint receives a WebSocket');
            is(refaddr($CacheAwareEndpoint::seen->scope), refaddr($scope),
                'the endpoint connection owns the selected scope');
            if ($case eq 'same scope WebSocket') {
                is(refaddr($CacheAwareEndpoint::seen), refaddr($cached),
                    'the same-scope exact class cache is reused');
            }
            else {
                isnt(refaddr($CacheAwareEndpoint::seen), refaddr($cached),
                    'the incompatible cached object is replaced');
            }
        };
    }
};

done_testing;
