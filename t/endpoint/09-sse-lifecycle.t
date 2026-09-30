#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::Endpoint::SSE;
use PAGI::Routing qw(router sse);
use lib 't/lib';
use PAGITest::Connected qw(sse_scope receive_from);

# Runs an SSE app until it parks on its stream, then ends the connection as a
# server does when the client goes away.
sub run_until_client_leaves {
    my ($app, $scope, $send) = @_;
    my $running = $app->($scope, receive_from($scope), $send // sub { Future->done });
    $scope->{'pagi.connection'}->_mark_disconnected('client_closed');
    return $running->get;
}

package MetricsEndpoint {
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;

    sub keepalive_interval { 25 }

    our @log;
    our ($seen_connect, $seen_disconnect);

    async sub on_connect {
        my ($self, $sse) = @_;
        push @log, 'connect';
        $seen_connect = $sse;
        await $sse->send_event(event => 'connected', data => { ok => 1 });
    }

    sub on_disconnect {
        my ($self, $sse) = @_;
        $seen_disconnect = $sse;
        push @log, 'disconnect';
    }
}

{
    package Local::ConfiguredSSE;
    use parent 'PAGI::Endpoint::SSE';
    our $NEW_CALLS = 0;
    our @SEEN_IDS;

    sub new {
        my ($class, @args) = @_;
        $NEW_CALLS++;
        return PAGI::Endpoint::SSE::new($class, @args);
    }

    sub on_connect {
        push @SEEN_IDS, Scalar::Util::refaddr($_[0]);
        return $_[1]->start;
    }
}

{
    package Local::OverlappingConfiguredSSE;
    use parent 'PAGI::Endpoint::SSE';

    our (%GATES, @RECEIVER_IDS, @PROTOCOL_IDS, @SCOPE_IDS);

    async sub on_connect {
        my ($self, $sse) = @_;
        my $path = $sse->scope->{path};

        push @RECEIVER_IDS, Scalar::Util::refaddr($self);
        push @PROTOCOL_IDS, Scalar::Util::refaddr($sse);
        push @SCOPE_IDS, Scalar::Util::refaddr($sse->scope);

        await $GATES{$path};
        await $sse->start;
    }
}

subtest 'lifecycle via to_app' => sub {
    @MetricsEndpoint::log = ();
    ($MetricsEndpoint::seen_connect, $MetricsEndpoint::seen_disconnect) = ();

    my $app = MetricsEndpoint->to_app;
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $scope = sse_scope(path => '/events');

    run_until_client_leaves($app, $scope, $send);

    is($MetricsEndpoint::log[0], 'connect', 'on_connect called');
    is($MetricsEndpoint::log[1], 'disconnect', 'on_disconnect called');
    is(ref($MetricsEndpoint::seen_connect), 'PAGI::SSE',
        'on_connect receives the direct SSE stream');
    is(refaddr($MetricsEndpoint::seen_connect), refaddr($MetricsEndpoint::seen_disconnect),
        'connect and disconnect receive the exact same stream');
    is(refaddr($MetricsEndpoint::seen_connect->scope), refaddr($scope),
        'the direct stream owns the selected scope');
};

subtest 'configured endpoint to_app retains the exact object across connections' => sub {
    $Local::ConfiguredSSE::NEW_CALLS = 0;
    @Local::ConfiguredSSE::SEEN_IDS = ();

    my $hub = {};
    my $configured = Local::ConfiguredSSE->new(hub => $hub);
    my $app = $configured->to_app;

    for my $connection (1, 2) {
        run_until_client_leaves($app, sse_scope(path => "/events/$connection"));
    }

    is $Local::ConfiguredSSE::NEW_CALLS, 1,
        'configured object was not reconstructed';
    is \@Local::ConfiguredSSE::SEEN_IDS,
        [refaddr($configured), refaddr($configured)],
        'connections use the exact configured object';
};

subtest 'overlapping streams retain the endpoint and isolate stream objects' => sub {
    my $first_gate = Future->new;
    my $second_gate = Future->new;
    %Local::OverlappingConfiguredSSE::GATES = (
        '/events/first'  => $first_gate,
        '/events/second' => $second_gate,
    );
    @Local::OverlappingConfiguredSSE::RECEIVER_IDS = ();
    @Local::OverlappingConfiguredSSE::PROTOCOL_IDS = ();
    @Local::OverlappingConfiguredSSE::SCOPE_IDS = ();

    my $endpoint = Local::OverlappingConfiguredSSE->new(bus => {});
    my $app = $endpoint->to_app;
    my $first_scope  = sse_scope(path => '/events/first');
    my $second_scope = sse_scope(path => '/events/second');

    my $first = $app->($first_scope, receive_from($first_scope), sub { Future->done });
    ok(!$first->is_ready, 'the first stream is held inside on_connect');
    is scalar(@Local::OverlappingConfiguredSSE::RECEIVER_IDS), 1,
        'the first stream entered the endpoint before the second began';

    my $second = $app->($second_scope, receive_from($second_scope), sub { Future->done });
    ok(!$second->is_ready,
        'the second stream overlaps the first inside on_connect');
    is \@Local::OverlappingConfiguredSSE::RECEIVER_IDS,
        [refaddr($endpoint), refaddr($endpoint)],
        'both in-flight streams use the exact configured endpoint';
    isnt $Local::OverlappingConfiguredSSE::PROTOCOL_IDS[0],
        $Local::OverlappingConfiguredSSE::PROTOCOL_IDS[1],
        'overlapping streams receive distinct SSE objects';
    is \@Local::OverlappingConfiguredSSE::SCOPE_IDS,
        [refaddr($first_scope), refaddr($second_scope)],
        'each SSE object retains its own exact stream scope';

    $first_gate->done;
    $second_gate->done;
    $_->{'pagi.connection'}->_mark_disconnected('client_closed')
        for $first_scope, $second_scope;
    is $first->get, undef, 'the released first stream completes cleanly';
    is $second->get, undef, 'the released second stream completes cleanly';
};

subtest 'events are sent' => sub {
    @MetricsEndpoint::log = ();

    my $app = MetricsEndpoint->to_app;
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };

    run_until_client_leaves($app, sse_scope(path => '/events'), $send);

    my @types = map { $_->{type} } @sent;
    my ($start_idx) = grep { $types[$_] eq 'sse.start' } 0 .. $#types;
    my ($event_idx) = grep { $types[$_] eq 'sse.send' } 0 .. $#types;
    ok(defined $event_idx, 'send_event emits an SSE event');
    ok(defined $start_idx && $start_idx < $event_idx,
        'send_event lazily starts the stream before emitting its event');
};

subtest 'default lifecycle starts the stream without an on_connect hook' => sub {
    my $app = PAGI::Endpoint::SSE->to_app;
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };

    run_until_client_leaves($app, sse_scope(path => '/events'), $send);

    is([map { $_->{type} } @sent], ['sse.start'],
        'the default lifecycle starts one stream');
};

subtest 'sse route accepts a configured endpoint object' => sub {
    {
        package RoutedConfiguredSSE;
        use parent 'PAGI::Endpoint::SSE';
        our @hubs;

        sub on_connect {
            push @hubs, $_[0]->{hub};
            return $_[1]->start;
        }
    }

    @RoutedConfiguredSSE::hubs = ();
    my $hub = {};
    my $configured = RoutedConfiguredSSE->new(hub => $hub);
    my $app = router(routes => [
        sse('/events' => $configured),
    ])->to_app;

    run_until_client_leaves($app, sse_scope(path => '/events'));

    is \@RoutedConfiguredSSE::hubs, [$hub],
        'sse route uses the configured endpoint object';
};

subtest 'immediate on_connect results are normalized' => sub {
    {
        package ImmediateSSEEndpoint;
        use parent 'PAGI::Endpoint::SSE';

        our $seen;

        sub on_connect {
            my ($self, $sse) = @_;
            $seen = ref($sse);
            $sse->start;
            return 'immediate connect result';
        }
    }

    my $app = ImmediateSSEEndpoint->to_app;
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };

    run_until_client_leaves($app, sse_scope(path => '/events'), $send);

    is($ImmediateSSEEndpoint::seen, 'PAGI::SSE',
        'direct callback accepts an immediate return value');
};

subtest 'failed on_connect Future propagates through the endpoint app' => sub {
    {
        package FailingSSEEndpoint;
        use parent 'PAGI::Endpoint::SSE';

        sub on_connect { Future->fail("connect hook failed\n") }
    }

    my $scope = sse_scope(path => '/events');
    like(dies {
        FailingSSEEndpoint->to_app->(
            $scope,
            receive_from($scope),
            sub { Future->done },
        )->get;
    }, qr/connect hook failed/, 'failed connect Future is not swallowed');
};

subtest 'on_disconnect Future is awaited by cleanup' => sub {
    {
        package SynchronousDisconnectEndpoint;
        use parent 'PAGI::Endpoint::SSE';
        our $returned = Future->new;
        our $called = 0;

        sub on_connect { $_[1]->start }
        sub on_disconnect {
            $called++;
            return $returned;
        }
    }

    $SynchronousDisconnectEndpoint::returned = Future->new;
    $SynchronousDisconnectEndpoint::called = 0;
    my $scope = sse_scope(path => '/events');
    my $running = SynchronousDisconnectEndpoint->to_app->(
        $scope, receive_from($scope), sub { Future->done },
    );
    $scope->{'pagi.connection'}->_mark_disconnected('client_closed');
    ok(!$running->is_ready, 'cleanup awaits disconnect hook');
    is($SynchronousDisconnectEndpoint::called, 1, 'disconnect hook was called');
    ok(!$SynchronousDisconnectEndpoint::returned->is_ready,
        'disconnect return Future is pending');
    $SynchronousDisconnectEndpoint::returned->done;
    is($running->get, undef, 'endpoint completes after disconnect hook');
};

subtest 'to_app returns PAGI-compatible coderef' => sub {
    my $app = MetricsEndpoint->to_app;
    ref_ok($app, 'CODE', 'to_app returns coderef');
};

done_testing;
