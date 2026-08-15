#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;
use File::Temp qw(tempfile);
use JSON::MaybeXS ();

use lib 'lib';

use PAGI::App::Healthcheck;
use PAGI::App::Loader;
use PAGI::App::Throttle;

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
        ok((grep { $_->[0] eq 'content-type' && $_->[1] =~ /application\/json/ } @{$sent[0]{headers}}),
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

# =============================================================================
# Test: PAGI::App::Loader
# =============================================================================

subtest 'App::Loader loads app from file' => sub {

    subtest 'loads valid app file' => sub {
        my ($fh, $filename) = tempfile(SUFFIX => '.pl', UNLINK => 1);
        print $fh q{
            use strict;
            use warnings;
            use Future::AsyncAwait;

            async sub {
                my ($scope, $receive, $send) = @_;
                await $send->({ type => 'http.response.start', status => 200, headers => [] });
                await $send->({ type => 'http.response.body', body => 'Loaded!', more => 0 });
            };
        };
        close $fh;

        my $app = PAGI::App::Loader->new(file => $filename)->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 200, 'loaded app responds';
        is $sent[1]{body}, 'Loaded!', 'correct response';
    };

    subtest 'invalid HTTP app negotiates a Pages 500' => sub {
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };

        my $app = PAGI::App::Loader->new(file => '/nonexistent/app.pl')->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                {
                    type    => 'http',
                    path    => '/',
                    headers => [['Accept', 'application/json']],
                },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 500, 'returns 500 for invalid file';
        my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]{headers}};
        is $headers{'content-type'}, 'application/problem+json',
            'load failure negotiates problem JSON';
        is $headers{'cache-control'}, 'no-store', 'load failure is not stored';
        my $problem = JSON::MaybeXS::decode_json($sent[1]{body});
        is $problem->{status}, 500, 'problem status matches the wire status';
        is $problem->{title}, 'Internal Server Error',
            'problem document uses the stock title';
        like "@warnings", qr/Error loading|did not return a coderef/,
            'load failure is logged (captured, not leaked to STDERR)';
    };

    subtest 'invalid non-HTTP app croaks without HTTP events' => sub {
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };

        my $app = PAGI::App::Loader->new(file => '/nonexistent/app.pl')->to_app;
        my @sent;

        like dies {
            $app->(
                { type => 'websocket', path => '/' },
                async sub { { type => 'websocket.disconnect' } },
                async sub { my ($event) = @_; push @sent, $event },
            )->get;
        }, qr/^application could not be loaded for scope type 'websocket'/,
            'failure names the unsupported scope type';
        is \@sent, [], 'load failure emits no HTTP events on a non-HTTP scope';
    };
};

# =============================================================================
# Test: PAGI::App::Throttle
# =============================================================================

subtest 'App::Throttle rate limiting' => sub {

    # Reset throttle state between tests
    PAGI::App::Throttle->reset_all;

    subtest 'allows requests within limit' => sub {
        my $inner_app = async sub  {
        my ($scope, $receive, $send) = @_;
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        };

        my $app = PAGI::App::Throttle->new(
            app   => $inner_app,
            rate  => 10,
            burst => 5,
        )->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/', client => ['127.0.0.1', 12345] },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 200, 'first request allowed';
    };

    subtest 'blocks requests over limit' => sub {
        PAGI::App::Throttle->reset_all;

        my $inner_app = async sub  {
        my ($scope, $receive, $send) = @_;
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        };

        my $app = PAGI::App::Throttle->new(
            app     => $inner_app,
            rate    => 100,
            burst   => 2,  # Only allow 2 requests
            key_for => sub { 'test_key' },
        )->to_app;

        # Make requests until rate limited
        my $limited = 0;
        for my $i (1..5) {
            my @sent;
            run_async(async sub {
                await $app->(
                    { type => 'http', path => '/' },
                    async sub { { type => 'http.disconnect' } },
                    async sub  {
        my ($event) = @_; push @sent, $event },
                );
            });
            if ($sent[0]{status} == 429) {
                $limited = 1;
                last;
            }
        }

        ok $limited, 'eventually rate limited';
    };

    subtest 'adds rate limit headers' => sub {
        PAGI::App::Throttle->reset_all;

        my $inner_app = async sub  {
        my ($scope, $receive, $send) = @_;
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        };

        my $app = PAGI::App::Throttle->new(
            app     => $inner_app,
            rate    => 10,
            burst   => 10,
            headers => 1,
        )->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        ok((grep { $_->[0] eq 'x-ratelimit-limit' } @{$sent[0]{headers}}), 'has limit header');
        ok((grep { $_->[0] eq 'x-ratelimit-remaining' } @{$sent[0]{headers}}), 'has remaining header');
    };

    subtest '429 response includes Retry-After' => sub {
        PAGI::App::Throttle->reset_all;

        my $inner_app = async sub  {
        my ($scope, $receive, $send) = @_;
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        };

        my $app = PAGI::App::Throttle->new(
            app     => $inner_app,
            rate    => 100,
            burst   => 1,
            key_for => sub { 'retry_test' },
        )->to_app;

        # Exhaust tokens
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; },
            );
        });

        # Next should be rate limited
        my @sent;
        run_async(async sub {
            await $app->(
                {
                    type    => 'http',
                    path    => '/',
                    headers => [['Accept', 'application/json']],
                },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 429, 'returns 429';
        for my $name (qw(retry-after x-ratelimit-limit x-ratelimit-remaining x-ratelimit-reset)) {
            my @values = map { $_->[1] }
                grep { lc($_->[0]) eq $name } @{$sent[0]{headers}};
            is scalar(@values), 1, "has exactly one $name field";
        }
        my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]{headers}};
        is $headers{'content-type'}, 'application/problem+json',
            'built-in limit response negotiates problem JSON';
        ok exists $headers{'retry-after'}, 'has Retry-After header';
        is $headers{'x-ratelimit-limit'}, 1, 'retains X-RateLimit-Limit';
        is $headers{'x-ratelimit-remaining'}, 0, 'retains X-RateLimit-Remaining';
        ok exists $headers{'x-ratelimit-reset'}, 'retains X-RateLimit-Reset';
        my $problem = JSON::MaybeXS::decode_json($sent[1]{body});
        is $problem->{status}, 429, 'problem status matches the wire status';
    };

    subtest 'custom on_limit response remains literal' => sub {
        PAGI::App::Throttle->reset_all;

        my $app = PAGI::App::Throttle->new(
            app     => async sub { },
            rate    => 0.001,
            burst   => 1,
            key_for => sub { 'custom_limit' },
            on_limit => async sub {
                my ($scope, $receive, $send, $retry_after) = @_;
                await $send->({
                    type    => 'http.response.start',
                    status  => 409,
                    headers => [['content-type', 'application/x-custom-limit']],
                });
                await $send->({
                    type => 'http.response.body', body => "custom:$retry_after", more => 0,
                });
            },
        )->to_app;

        run_async(async sub {
            await $app->(
                { type => 'http', path => '/', headers => [] },
                async sub { { type => 'http.disconnect' } },
                async sub { },
            );
        });

        my @sent;
        run_async(async sub {
            await $app->(
                {
                    type    => 'http',
                    path    => '/',
                    headers => [['Accept', 'application/json']],
                },
                async sub { { type => 'http.disconnect' } },
                async sub { my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 409, 'custom handler retains its status';
        is $sent[0]{headers}, [['content-type', 'application/x-custom-limit']],
            'custom handler retains its literal headers';
        like $sent[1]{body}, qr/^custom:\d+$/, 'custom handler retains its literal body';
    };

    subtest 'non-HTTP scopes pass until exhaustion then croak without HTTP events' => sub {
        PAGI::App::Throttle->reset_all;

        my $child_calls = 0;
        my $app = PAGI::App::Throttle->new(
            app => async sub {
                my ($scope, $receive, $send) = @_;
                $child_calls++;
                await $send->({ type => 'websocket.close', code => 1000 });
            },
            rate    => 0.001,
            burst   => 1,
            key_for => sub { 'websocket_limit' },
        )->to_app;

        my @first_events;
        run_async(async sub {
            await $app->(
                { type => 'websocket', path => '/' },
                async sub { { type => 'websocket.disconnect' } },
                async sub { my ($event) = @_; push @first_events, $event },
            );
        });
        is \@first_events, [{ type => 'websocket.close', code => 1000 }],
            'an allowed non-HTTP scope retains child protocol behavior';

        my @limited_events;
        like dies {
            $app->(
                { type => 'websocket', path => '/' },
                async sub { { type => 'websocket.disconnect' } },
                async sub { my ($event) = @_; push @limited_events, $event },
            )->get;
        }, qr/^built-in rate-limit response is HTTP-only; configure on_limit for scope type 'websocket'/,
            'failure names on_limit and the unsupported scope type';
        is \@limited_events, [], 'exhaustion emits no HTTP events on a non-HTTP scope';
        is $child_calls, 1, 'the exhausted request does not reach the child';
    };
};

done_testing;
