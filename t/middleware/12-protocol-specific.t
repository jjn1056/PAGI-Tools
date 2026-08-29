#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use IO::Async::Loop;

use PAGI::Middleware::SSE::Retry;
use PAGI::Middleware::Auth::Basic;
use PAGI::Middleware::Auth::Bearer;
use PAGI::Middleware::CSRF;
use PAGI::Middleware::ContentNegotiation;
use PAGI::Middleware::FormBody;
use PAGI::Middleware::JSONBody;
use PAGI::Middleware::Maintenance;
use PAGI::Middleware::RateLimit;
use PAGI::Middleware::TrustedHosts;

my $loop = IO::Async::Loop->new;

sub run_async (&) {
    my ($code) = @_;
    $loop->await($code->());
}

# ===================
# SSE::Retry Tests
# ===================

subtest 'SSE::Retry - sends retry hint on start' => sub {
    my $retry = PAGI::Middleware::SSE::Retry->new(
        retry => 5000,
        include_on_start => 1,
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'sse.start' });
        await $send->({ type => 'sse.send', data => 'test' });
    };

    my $wrapped = $retry->wrap($app);
    my $scope = { type => 'sse', headers => [] };

    my @events;
    run_async {
        $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e });
    };

    is scalar(@events), 3, 'three events sent';
    is $events[0]{type}, 'sse.start', 'first is sse.start';
    is $events[1]{type}, 'sse.send', 'second is retry hint';
    is $events[1]{retry}, 5000, 'retry value set';
    is $events[2]{type}, 'sse.send', 'third is data event';
};

subtest 'SSE::Retry - adds retry to scope' => sub {
    my $retry = PAGI::Middleware::SSE::Retry->new(retry => 3000);

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'sse.start' });
    };

    my $wrapped = $retry->wrap($app);
    my $scope = { type => 'sse', headers => [] };

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    is $captured_scope->{'pagi.sse.retry'}, 3000, 'retry in scope';
};

subtest 'SSE::Retry - passes through non-SSE' => sub {
    my $retry = PAGI::Middleware::SSE::Retry->new();

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $retry->wrap($app);
    my $scope = { type => 'http', method => 'GET', path => '/' };

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    ok !exists $captured_scope->{'pagi.sse.retry'}, 'no retry for HTTP';
};

subtest 'HTTP policy middleware preserves non-HTTP event streams and send settlement' => sub {
    my @cases = (
        ['Auth::Basic', sub {
            PAGI::Middleware::Auth::Basic->new(
                authenticator => sub { 0 },
            );
        }],
        ['Auth::Bearer', sub {
            PAGI::Middleware::Auth::Bearer->new(
                validator => sub { undef },
            );
        }],
        ['CSRF', sub {
            PAGI::Middleware::CSRF->new(secret => 'test-secret');
        }],
        ['ContentNegotiation', sub {
            PAGI::Middleware::ContentNegotiation->new(
                supported_types => ['application/json'],
                strict          => 1,
            );
        }],
        ['FormBody', sub { PAGI::Middleware::FormBody->new }],
        ['JSONBody', sub { PAGI::Middleware::JSONBody->new }],
        ['Maintenance', sub {
            PAGI::Middleware::Maintenance->new(enabled => 1);
        }],
        ['RateLimit', sub {
            PAGI::Middleware::RateLimit->new(burst => 0);
        }],
        ['TrustedHosts', sub {
            PAGI::Middleware::TrustedHosts->new(hosts => ['example.com']);
        }],
    );

    my @downstream = (
        { type => 'sse.start' },
        { type => 'sse.send', data => 'first' },
        { type => 'sse.send', data => 'second' },
    );

    for my $case (@cases) {
        my ($name, $middleware) = @$case;
        subtest $name => sub {
            my $start_gate = Future->new;
            my @events;
            my $calls = 0;
            my $wrapped = $middleware->()->wrap(async sub {
                my ($scope, $receive, $send) = @_;
                for my $event (@downstream) {
                    await $send->($event);
                }
            });
            my $scope = {
                type    => 'sse',
                path    => '/events',
                headers => [['Accept', 'application/problem+json']],
            };
            my $running = $wrapped->(
                $scope,
                async sub { { type => 'sse.disconnect' } },
                sub {
                    push @events, $_[0];
                    return ++$calls == 1 ? $start_gate : Future->done;
                },
            );

            is \@events, [$downstream[0]],
                "$name forwards the first event without buffering later events";
            ok !$running->is_ready,
                "$name waits for the downstream send Future";
            $start_gate->done;
            $loop->await($running);
            is \@events, \@downstream,
                "$name preserves the complete non-HTTP event stream literally";
            ok !$start_gate->is_cancelled,
                "$name does not cancel the server-owned send Future";
        };
    }
};

done_testing;
