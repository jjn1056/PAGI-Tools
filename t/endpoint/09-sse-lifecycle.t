#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::Endpoint::SSE;

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

subtest 'lifecycle via to_app' => sub {
    @MetricsEndpoint::log = ();
    ($MetricsEndpoint::seen_connect, $MetricsEndpoint::seen_disconnect) = ();

    my $app = MetricsEndpoint->to_app;
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'sse.disconnect' }) };

    my $scope = {
        type    => 'sse',
        path    => '/events',
        headers => [],
    };

    $app->($scope, $receive, $send)->get;

    is($MetricsEndpoint::log[0], 'connect', 'on_connect called');
    is($MetricsEndpoint::log[1], 'disconnect', 'on_disconnect called');
    is(ref($MetricsEndpoint::seen_connect), 'PAGI::SSE',
        'on_connect receives the direct SSE stream');
    is(refaddr($MetricsEndpoint::seen_connect), refaddr($MetricsEndpoint::seen_disconnect),
        'connect and disconnect receive the exact same stream');
    is(refaddr($MetricsEndpoint::seen_connect->scope), refaddr($scope),
        'the direct stream owns the selected scope');
};

subtest 'events are sent' => sub {
    @MetricsEndpoint::log = ();

    my $app = MetricsEndpoint->to_app;
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'sse.disconnect' }) };

    $app->({ type => 'sse', path => '/events', headers => [] },
           $receive, $send)->get;

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
    my $receive = sub { Future->done({ type => 'sse.disconnect' }) };

    $app->({ type => 'sse', path => '/events', headers => [] },
           $receive, $send)->get;

    is([map { $_->{type} } @sent], ['sse.start'],
        'the default lifecycle starts one stream');
};

subtest 'one compiled app constructs a fresh endpoint for each connection' => sub {
    {
        package FreshSSEEndpoint;
        use parent 'PAGI::Endpoint::SSE';
        our @instances;
        sub on_connect {
            push @instances, $_[0];
            return $_[1]->start;
        }
    }

    @FreshSSEEndpoint::instances = ();
    my $app = FreshSSEEndpoint->to_app;
    for my $connection (1, 2) {
        $app->(
            { type => 'sse', path => "/events/$connection", headers => [] },
            sub { Future->done({ type => 'sse.disconnect' }) },
            sub { Future->done },
        )->get;
    }

    is(scalar @FreshSSEEndpoint::instances, 2,
        'both connections reached their endpoint instance');
    isnt(refaddr($FreshSSEEndpoint::instances[0]),
        refaddr($FreshSSEEndpoint::instances[1]),
        'the compiled app does not retain endpoint state between connections');
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
    my $receive = sub { Future->done({ type => 'sse.disconnect' }) };

    $app->({ type => 'sse', path => '/events', headers => [] },
           $receive, $send)->get;

    is($ImmediateSSEEndpoint::seen, 'PAGI::SSE',
        'direct callback accepts an immediate return value');
};

subtest 'failed on_connect Future propagates through the endpoint app' => sub {
    {
        package FailingSSEEndpoint;
        use parent 'PAGI::Endpoint::SSE';

        sub on_connect { Future->fail("connect hook failed\n") }
    }

    like(dies {
        FailingSSEEndpoint->to_app->(
            { type => 'sse', path => '/events', headers => [] },
            sub { Future->done({ type => 'sse.disconnect' }) },
            sub { Future->done },
        )->get;
    }, qr/connect hook failed/, 'failed connect Future is not swallowed');
};

subtest 'on_disconnect remains synchronous and its return is not awaited' => sub {
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
    my $running = SynchronousDisconnectEndpoint->to_app->(
        { type => 'sse', path => '/events', headers => [] },
        sub { Future->done({ type => 'sse.disconnect' }) },
        sub { Future->done },
    );
    is($running->get, undef, 'endpoint completes without disconnect return');
    is($SynchronousDisconnectEndpoint::called, 1, 'disconnect hook was called');
    ok(!$SynchronousDisconnectEndpoint::returned->is_ready,
        'disconnect return Future was not awaited');
};

subtest 'to_app returns PAGI-compatible coderef' => sub {
    my $app = MetricsEndpoint->to_app;
    ref_ok($app, 'CODE', 'to_app returns coderef');
};

done_testing;
