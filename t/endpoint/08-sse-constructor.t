#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::SSE;
use lib 't/lib';
use PAGITest::Connected qw(sse_scope receive_from);

# Runs an SSE app until it parks on its stream, then ends the connection as a
# server does when the client goes away.
sub run_until_client_leaves {
    my ($app, $scope) = @_;
    my $running = $app->($scope, receive_from($scope), sub { Future->done });
    $scope->{'pagi.connection'}->_mark_disconnected('client_closed');
    return $running->get;
}

subtest 'can create SSE endpoint subclass' => sub {
    require PAGI::Endpoint::SSE;

    package NotificationEndpoint {
        use parent 'PAGI::Endpoint::SSE';
        use Future::AsyncAwait;

        async sub on_connect {
            my ($self, $sse) = @_;
            await $sse->send_event(event => 'welcome', data => { time => time() });
        }

        sub on_disconnect {
            my ($self, $sse) = @_;
            # cleanup subscriber
        }
    }

    my $endpoint = NotificationEndpoint->new;
    isa_ok($endpoint, 'PAGI::Endpoint::SSE');
};

subtest 'keepalive_interval has default' => sub {
    require PAGI::Endpoint::SSE;

    is(PAGI::Endpoint::SSE->keepalive_interval, 0, 'default keepalive_interval is 0 (disabled)');
};

subtest 'subclass can override keepalive' => sub {
    package LiveEndpoint {
        use parent 'PAGI::Endpoint::SSE';
        sub keepalive_interval { 30 }
    }

    is(LiveEndpoint->keepalive_interval, 30, 'custom keepalive_interval');
};

subtest 'class to_app constructs its endpoint immediately and only once' => sub {
    {
        package Local::ConstructionCountingSSE;
        use parent 'PAGI::Endpoint::SSE';
        our $NEW_CALLS = 0;

        sub new {
            my ($class, @args) = @_;
            $NEW_CALLS++;
            return PAGI::Endpoint::SSE::new($class, @args);
        }

        sub on_connect { return $_[1]->start }
    }

    $Local::ConstructionCountingSSE::NEW_CALLS = 0;
    my $app = Local::ConstructionCountingSSE->new->to_app;

    is $Local::ConstructionCountingSSE::NEW_CALLS, 1,
        'class to_app constructs the endpoint immediately';

    for my $connection (1, 2) {
        run_until_client_leaves($app, sse_scope(path => "/events/$connection"));
    }

    is $Local::ConstructionCountingSSE::NEW_CALLS, 1,
        'connections do not construct additional endpoint objects';
};

subtest 'app builds its own SSE stream, never one built earlier over the scope' => sub {
    {
        package CacheAwareEndpoint;
        use parent 'PAGI::Endpoint::SSE';
        our $seen;
        sub on_connect {
            ($seen) = $_[1];
            return $_[1]->start;
        }
    }

    my $scope = sse_scope(path => '/events');
    my $earlier = PAGI::SSE->new($scope, receive_from($scope), sub { Future->done });
    $CacheAwareEndpoint::seen = undef;

    run_until_client_leaves(CacheAwareEndpoint->new->to_app, $scope);

    isa_ok($CacheAwareEndpoint::seen, ['PAGI::SSE'],
        'the endpoint receives an SSE stream');
    isnt(refaddr($CacheAwareEndpoint::seen), refaddr($earlier),
        'a new one, not the one built earlier (RV1)');
    is(refaddr($CacheAwareEndpoint::seen->scope), refaddr($scope),
        'over the scope the endpoint was called with');
    ok(!exists $scope->{'pagi.sse'}, 'nothing is cached in the scope');
};

done_testing;
