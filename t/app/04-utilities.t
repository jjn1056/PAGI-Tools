#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;
use JSON::MaybeXS ();

use lib 'lib';

use PAGI::App::Healthcheck;

my $loop = IO::Async::Loop->new;

sub run_async {
    my ($code) = @_;
    my $future = $code->();
    $loop->await($future);
}

# =============================================================================
# Test: PAGI::App::Healthcheck
# =============================================================================

subtest 'App::Healthcheck' => sub {

    subtest 'returns healthy status' => sub {
        my $app = PAGI::App::Healthcheck->new->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/health' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 200, 'returns 200';
        ok((grep { lc($_->[0]) eq 'content-type' && $_->[1] =~ /application\/json/ } @{$sent[0]{headers}}),
            'returns JSON');

        my $body = JSON::MaybeXS::decode_json($sent[1]{body});
        is $body->{status}, 'ok', 'status is ok';
        ok exists $body->{timestamp}, 'has timestamp';
        ok exists $body->{uptime}, 'has uptime';
    };

    subtest 'includes version if provided' => sub {
        my $app = PAGI::App::Healthcheck->new(version => '1.0.0')->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/health' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        my $body = JSON::MaybeXS::decode_json($sent[1]{body});
        is $body->{version}, '1.0.0', 'version included';
    };

    subtest 'runs custom checks' => sub {
        my $app = PAGI::App::Healthcheck->new(
            checks => {
                database => sub { 1 },
                cache    => sub { 1 },
            },
        )->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/health' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        my $body = JSON::MaybeXS::decode_json($sent[1]{body});
        is $body->{checks}{database}{status}, 'ok', 'database check ok';
        is $body->{checks}{cache}{status}, 'ok', 'cache check ok';
    };

    subtest 'returns 503 when check fails' => sub {
        my $app = PAGI::App::Healthcheck->new(
            checks => {
                database => sub { 0 },  # Failure
            },
        )->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/health' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 503, 'returns 503';
        my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]{headers}};
        is $headers{'content-type'}, 'application/json',
            'unhealthy health checks retain their protocol JSON';
        my $body = JSON::MaybeXS::decode_json($sent[1]{body});
        is $body->{status}, 'error', 'overall status is error';
        is $body->{checks}{database}{status}, 'error', 'database check failed';
    };

    subtest 'handles check exceptions' => sub {
        my $app = PAGI::App::Healthcheck->new(
            checks => {
                broken => sub { die "Connection failed" },
            },
        )->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/health' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 503, 'returns 503';
        my $body = JSON::MaybeXS::decode_json($sent[1]{body});
        like $body->{checks}{broken}{message}, qr/Connection failed/, 'error message captured';
    };
};

subtest 'removed applications are not in the distribution' => sub {
    # A file check, not require: an older PAGI-Tools may be installed.
    ok !-e 'lib/PAGI/App/Throttle.pm',
        'PAGI::App::Throttle is gone: RateLimit is the one limiter';
    ok !-e 'lib/PAGI/App/Proxy.pm',
        'PAGI::App::Proxy is gone: its blocking I/O froze the event loop';
};

done_testing;
