#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Endpoint::SSE;

# Mock SSE
package MockSSE {
    use v5.32;
    use feature 'signatures';
    no warnings 'experimental::signatures';
    use Future::AsyncAwait;

    sub new ($class) {
        bless {
            sent => [],
            started => 0,
            keepalive => 0,
            closed => 0,
        }, $class
    }
    async sub start ($self) { $self->{started} = 1; return $self }
    sub keepalive ($self, $interval) { $self->{keepalive} = $interval; return $self }
    sub on_close ($self, $cb) { $self->{on_close_cb} = $cb; return $self }
    async sub send_event ($self, %opts) { push @{$self->{sent}}, \%opts }
    async sub run ($self) {
        # Simulate disconnect
        if ($self->{on_close_cb}) {
            $self->{on_close_cb}->();
        }
    }
    sub sent ($self) { $self->{sent} }
    sub last_event_id ($self) { undef }
}

package MetricsEndpoint {
    use parent 'PAGI::Endpoint::SSE';
    use v5.32;
    use feature 'signatures';
    no warnings 'experimental::signatures';
    use Future::AsyncAwait;

    sub keepalive_interval { 25 }

    our @log;

    async sub on_connect ($self, $sse) {
        push @log, 'connect';
        await $sse->send_event(event => 'connected', data => { ok => 1 });
    }

    sub on_disconnect ($self, $sse) {
        push @log, 'disconnect';
    }
}

subtest 'lifecycle methods are called' => sub {
    @MetricsEndpoint::log = ();

    my $sse = MockSSE->new;
    my $endpoint = MetricsEndpoint->new;

    $endpoint->handle($sse)->get;

    is($MetricsEndpoint::log[0], 'connect', 'on_connect called');
    is($MetricsEndpoint::log[1], 'disconnect', 'on_disconnect called');
};

subtest 'keepalive is configured' => sub {
    my $sse = MockSSE->new;
    my $endpoint = MetricsEndpoint->new;

    $endpoint->handle($sse)->get;

    is($sse->{keepalive}, 25, 'keepalive interval set');
};

subtest 'events are sent' => sub {
    my $sse = MockSSE->new;
    my $endpoint = MetricsEndpoint->new;

    $endpoint->handle($sse)->get;

    is($sse->sent->[0]{event}, 'connected', 'event sent');
};

subtest 'to_app returns PAGI-compatible coderef' => sub {
    my $app = MetricsEndpoint->to_app;

    ref_ok($app, 'CODE', 'to_app returns coderef');
};

done_testing;
