#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;
use JSON::MaybeXS qw(decode_json);
use Scalar::Util qw(refaddr);

use lib 'lib';

use PAGI::Middleware::CORS;
use PAGI::Middleware::SecurityHeaders;
use PAGI::Middleware::TrustedHosts;
use PAGI::Middleware::CSRF;
use PAGI::Context;
use PAGI::Headers;

my $loop = IO::Async::Loop->new;

sub run_async {
    my ($code) = @_;
    my $future = $code->();
    $loop->await($future);
}

sub response_header_values {
    my ($event, $name) = @_;
    return map { $_->[1] }
        grep { lc($_->[0]) eq lc($name) } @{$event->{headers}};
}

# =============================================================================
# Test: CORS middleware handles preflight requests
# =============================================================================

subtest 'CORS handles preflight OPTIONS request' => sub {
    my $mw = PAGI::Middleware::CORS->new(
        origins => ['https://example.com'],
        methods => ['GET', 'POST', 'PUT'],
        headers => ['Content-Type', 'Authorization'],
    );

    my $app_called = 0;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $app_called = 1;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/api/resource',
                method  => 'OPTIONS',
                headers => [
                    ['origin', 'https://example.com'],
                    ['access-control-request-method', 'POST'],
                ],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    ok !$app_called, 'app not called for preflight';
    is $sent[0]{status}, 204, 'preflight returns 204';

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]{headers}};
    is $headers{'access-control-allow-origin'}, 'https://example.com', 'Allow-Origin header present';
    like $headers{'access-control-allow-methods'}, qr/POST/, 'Allow-Methods contains POST';
    like $headers{'access-control-allow-headers'}, qr/Content-Type/, 'Allow-Headers present';
};

subtest 'CORS adds headers to actual requests' => sub {
    my $mw = PAGI::Middleware::CORS->new(
        origins     => ['https://example.com'],
        credentials => 1,
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'application/json']],
        });
        await $send->({
            type => 'http.response.body',
            body => '{"data":"test"}',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/api/data',
                method  => 'GET',
                headers => [['origin', 'https://example.com']],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]{headers}};
    is $headers{'access-control-allow-origin'}, 'https://example.com', 'Origin header on response';
    is $headers{'access-control-allow-credentials'}, 'true', 'Credentials header present';
};

subtest 'CORS rejects unknown origins' => sub {
    my $mw = PAGI::Middleware::CORS->new(
        origins => ['https://allowed.com'],
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/api/data',
                method  => 'GET',
                headers => [['origin', 'https://evil.com']],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    # Response should not have CORS headers for unknown origin
    my @cors_headers = grep { $_->[0] =~ /^access-control/i } @{$sent[0]{headers}};
    is scalar(@cors_headers), 0, 'no CORS headers for unknown origin';
};

# =============================================================================
# Test: SecurityHeaders middleware adds security headers
# =============================================================================

subtest 'SecurityHeaders adds X-Content-Type-Options' => sub {
    my $mw = PAGI::Middleware::SecurityHeaders->new;

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/html']],
        });
        await $send->({
            type => 'http.response.body',
            body => '<html>Test</html>',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]{headers}};
    is $headers{'x-content-type-options'}, 'nosniff', 'X-Content-Type-Options is nosniff';
};

subtest 'SecurityHeaders adds X-Frame-Options' => sub {
    my $mw = PAGI::Middleware::SecurityHeaders->new(
        x_frame_options => 'DENY',
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]{headers}};
    is $headers{'x-frame-options'}, 'DENY', 'X-Frame-Options is DENY';
};

subtest 'SecurityHeaders adds all default headers' => sub {
    my $mw = PAGI::Middleware::SecurityHeaders->new;

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]{headers}};
    ok exists $headers{'x-frame-options'}, 'X-Frame-Options present';
    ok exists $headers{'x-content-type-options'}, 'X-Content-Type-Options present';
    ok exists $headers{'x-xss-protection'}, 'X-XSS-Protection present';
    ok exists $headers{'referrer-policy'}, 'Referrer-Policy present';
};

# =============================================================================
# Test: TrustedHosts middleware validates Host header
# =============================================================================

subtest 'TrustedHosts allows valid hosts' => sub {
    my $mw = PAGI::Middleware::TrustedHosts->new(
        hosts => ['example.com', 'www.example.com'],
    );

    my $app_called = 0;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $app_called = 1;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/',
                method  => 'GET',
                headers => [['host', 'example.com']],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    ok $app_called, 'app called for valid host';
    is $sent[0]{status}, 200, 'status is 200';
};

subtest 'TrustedHosts rejects invalid hosts' => sub {
    my $mw = PAGI::Middleware::TrustedHosts->new(
        hosts => ['example.com'],
    );

    my $app_called = 0;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $app_called = 1;
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/',
                method  => 'GET',
                headers => [['host', 'evil.com']],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    ok !$app_called, 'app not called for invalid host';
    is $sent[0]{status}, 400, 'status is 400 Bad Request';
};

subtest 'TrustedHosts generic failures negotiate through Pages' => sub {
    my @cases = (
        {
            name    => 'missing Host',
            headers => [],
        },
        {
            name    => 'duplicate Host',
            headers => [['Host', 'example.com'], ['host', 'example.com']],
        },
        {
            name    => 'structurally malformed Host',
            headers => [['Host', 'example.com/path']],
        },
        {
            name    => 'allowlist-rejected valid Host',
            headers => [['Host', 'other.example']],
        },
    );
    my @representations = (
        ['application/problem+json', 'application/problem+json'],
        ['text/plain', 'text/plain; charset=utf-8'],
    );

    for my $case (@cases) {
        for my $representation (@representations) {
            my ($accept, $content_type) = @$representation;
            my $mw = PAGI::Middleware::TrustedHosts->new(
                hosts => ['example.com'],
            );
            my $app_calls = 0;
            my $wrapped = $mw->wrap(async sub { $app_calls++ });
            my @sent;
            my @headers = (@{$case->{headers}}, ['Accept', $accept]);

            run_async(async sub {
                await $wrapped->(
                    {
                        type    => 'http',
                        path    => '/',
                        method  => 'GET',
                        headers => \@headers,
                    },
                    async sub { { type => 'http.disconnect' } },
                    async sub { my ($event) = @_; push @sent, $event },
                );
            });

            my $label = "$case->{name} with $accept";
            is $app_calls, 0, "$label does not call downstream";
            is scalar(@sent), 2, "$label sends a complete response";
            is $sent[0]{status}, 400, "$label retains status 400";
            is [response_header_values($sent[0], 'Content-Type')],
                [$content_type], "$label negotiates the requested representation";
            is [response_header_values($sent[0], 'Cache-Control')],
                ['no-store'], "$label uses the Pages error cache policy";
            is [response_header_values($sent[0], 'Vary')],
                ['Accept'], "$label varies negotiated responses on Accept";

            if ($accept eq 'application/problem+json') {
                my $problem = eval { decode_json($sent[1]{body}) };
                ok $problem, "$label renders a JSON problem document";
                if ($problem) {
                    is $problem->{status}, 400, "$label renders problem status";
                    is $problem->{detail},
                        'The server could not understand the request.',
                        "$label does not expose the rejected authority";
                }
            }
            else {
                is $sent[1]{body},
                    "400 Bad Request\n\nThe server could not understand the request.\n",
                    "$label renders the generic Pages text body";
            }
        }
    }
};

subtest 'TrustedHosts supports wildcard patterns' => sub {
    my $mw = PAGI::Middleware::TrustedHosts->new(
        hosts => ['*.example.com'],
    );

    my $app_called = 0;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $app_called = 1;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/',
                method  => 'GET',
                headers => [['host', 'api.example.com']],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; },
        );
    });

    ok $app_called, 'wildcard pattern matches subdomain';
};

subtest 'TrustedHosts rejects invalid Host authority before downstream' => sub {
    my @cases = (
        [
            [['Host', 'example.com'], ['host', 'example.com'], ['Accept', 'text/plain']],
            'duplicate identical Host',
            ['example.com'],
        ],
        [
            [['Host', 'example.com'], ['host', 'evil.example'], ['Accept', 'text/plain']],
            'duplicate conflicting Host',
            ['example.com'],
        ],
        [
            [['Host', 'example.com/path'], ['Accept', 'text/plain']],
            'malformed Host',
            ['example.com/path'],
        ],
    );

    for my $case (@cases) {
        my $mw = PAGI::Middleware::TrustedHosts->new(hosts => $case->[2]);
        my $app_calls = 0;
        my $wrapped = $mw->wrap(async sub { $app_calls++ });
        my @sent;

        run_async(async sub {
            await $wrapped->(
                {
                    type    => 'http',
                    path    => '/',
                    method  => 'GET',
                    headers => $case->[0],
                },
                async sub { { type => 'http.disconnect' } },
                async sub { my ($event) = @_; push @sent, $event },
            );
        });

        is $app_calls, 0, "$case->[1] does not call downstream";
        is scalar(@sent), 2, "$case->[1] sends start and terminal body";
        is $sent[0]{type}, 'http.response.start', "$case->[1] sends response start";
        is $sent[0]{status}, 400, "$case->[1] returns 400";
        is $sent[1], {
            type => 'http.response.body',
            body => "400 Bad Request\n\nThe server could not understand the request.\n",
            more => 0,
        }, "$case->[1] returns the generic Pages terminal body";
    }
};

subtest 'TrustedHosts applies allowlist and allow_empty after structural validation' => sub {
    my @cases = (
        {
            name        => 'valid Host with explicit port',
            config      => { hosts => ['example.com:8080'] },
            headers     => [['Host', 'example.com:8080']],
            app_calls   => 1,
            first_status => 200,
        },
        {
            name        => 'missing Host allowed by allow_empty',
            config      => { hosts => ['example.com'], allow_empty => 1 },
            headers     => [],
            app_calls   => 1,
            first_status => 200,
        },
        {
            name        => 'missing Host rejected without allow_empty',
            config      => { hosts => ['example.com'] },
            headers     => [],
            app_calls   => 0,
            first_status => 400,
        },
    );

    for my $case (@cases) {
        my $mw = PAGI::Middleware::TrustedHosts->new(%{$case->{config}});
        my $app_calls = 0;
        my $wrapped = $mw->wrap(async sub {
            my ($scope, $receive, $send) = @_;
            $app_calls++;
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        });
        my @sent;

        run_async(async sub {
            await $wrapped->(
                {
                    type    => 'http',
                    path    => '/',
                    method  => 'GET',
                    headers => $case->{headers},
                },
                async sub { { type => 'http.disconnect' } },
                async sub { my ($event) = @_; push @sent, $event },
            );
        });

        is $app_calls, $case->{app_calls}, "$case->{name}: downstream call count";
        is $sent[0]{status}, $case->{first_status}, "$case->{name}: response status";
    }
};

subtest 'TrustedHosts rejects undefined headers even when empty Host is allowed' => sub {
    my $mw = PAGI::Middleware::TrustedHosts->new(
        hosts       => ['example.com'],
        allow_empty => 1,
    );
    my $app_calls = 0;
    my $wrapped = $mw->wrap(async sub { $app_calls++ });
    my @sent;

    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/',
                method  => 'GET',
                headers => undef,
            },
            async sub { { type => 'http.disconnect' } },
            async sub { my ($event) = @_; push @sent, $event },
        );
    });

    is $app_calls, 0, 'undefined headers container does not call downstream';
    is scalar(@sent), 2, 'undefined headers container sends start and terminal body';
    is $sent[0]{type}, 'http.response.start', 'undefined headers container sends response start';
    is $sent[0]{status}, 400, 'undefined headers container returns 400';
    like $sent[1]{body}, qr{<title>400 Bad Request</title>},
        'undefined headers container returns the default Pages HTML body';
};

subtest 'TrustedHosts structurally malformed headers retain safe Accept negotiation' => sub {
    my @cases = (
        {
            name    => 'scalar header entry',
            invalid => sub { 'Host: rejected.example' },
        },
        {
            name    => 'hashref header entry',
            invalid => sub { { Host => 'rejected.example' } },
        },
        {
            name    => 'wrong-length header pair',
            invalid => sub { ['Host', 'rejected.example', 'extra'] },
        },
        {
            name    => 'reference header name',
            invalid => sub { [['Host'], 'rejected.example'] },
        },
        {
            name        => 'reference header value with inherited cache',
            invalid     => sub { ['Host', ['rejected.example']] },
            stale_cache => 1,
        },
    );
    my @representations = (
        ['application/problem+json', 'application/problem+json'],
        ['text/plain', 'text/plain; charset=utf-8'],
    );

    for my $case (@cases) {
        for my $representation (@representations) {
            my ($accept, $content_type) = @$representation;
            my $headers = [
                $case->{invalid}->(),
                ['AcCePt', $accept],
            ];
            my $header_bytes = JSON::MaybeXS->new(canonical => 1)->encode($headers);
            my $scope = {
                type    => 'http',
                path    => '/',
                method  => 'GET',
                headers => $headers,
            };
            if ($case->{stale_cache}) {
                $scope->{'pagi.request.headers'} = PAGI::Headers->new([
                    ['Accept', 'text/html'],
                ]);
            }
            my $original_headers = $scope->{headers};
            my $original_cache = $scope->{'pagi.request.headers'};
            my $mw = PAGI::Middleware::TrustedHosts->new(
                hosts => ['example.com'],
            );
            my $app_calls = 0;
            my $wrapped = $mw->wrap(async sub { $app_calls++ });
            my @sent;
            my $future = $wrapped->(
                $scope,
                async sub { { type => 'http.disconnect' } },
                async sub { my ($event) = @_; push @sent, $event },
            );
            $loop->await($future);

            my $label = "$case->{name} with $accept";
            ok $future->is_done, "$label completes without an internal diagnostic";
            is $app_calls, 0, "$label does not call downstream";
            is scalar(@sent), 2, "$label sends exactly start and terminal body";
            if (@sent == 2) {
                is $sent[0]{type}, 'http.response.start',
                    "$label sends response start first";
                is $sent[0]{status}, 400, "$label retains status 400";
                is [response_header_values($sent[0], 'Content-Type')],
                    [$content_type],
                    "$label negotiates using the surviving Accept pair";
                is $sent[1]{type}, 'http.response.body',
                    "$label sends a terminal response body";
                is $sent[1]{more}, 0, "$label terminates the response";
                unlike $sent[1]{body}, qr/rejected\.example/,
                    "$label does not expose rejected header input";

                if ($accept eq 'application/problem+json') {
                    my $problem = eval { decode_json($sent[1]{body}) };
                    ok $problem, "$label renders a JSON problem document";
                    if ($problem) {
                        is $problem->{status}, 400,
                            "$label renders problem status";
                        is $problem->{detail},
                            'The server could not understand the request.',
                            "$label renders only the safe generic detail";
                    }
                }
                else {
                    is $sent[1]{body},
                        "400 Bad Request\n\nThe server could not understand the request.\n",
                        "$label renders the safe generic text body";
                }
            }

            is refaddr($scope->{headers}), refaddr($original_headers),
                "$label preserves the original header container";
            my $current_header_bytes = JSON::MaybeXS->new(canonical => 1)
                ->encode($scope->{headers});
            is $current_header_bytes,
                $header_bytes, "$label does not mutate malformed header data";
            if ($case->{stale_cache}) {
                is refaddr($scope->{'pagi.request.headers'}), refaddr($original_cache),
                    "$label leaves the original request header cache untouched";
            }
        }
    }
};

subtest 'TrustedHosts preserves non-HTTP pass-through gate' => sub {
    my $mw = PAGI::Middleware::TrustedHosts->new(hosts => ['example.com']);
    my $seen_scope;
    my $scope = {
        type    => 'websocket',
        path    => '/socket',
        headers => [['Host', 'one.example'], ['host', 'two.example']],
    };
    my $wrapped = $mw->wrap(async sub {
        ($seen_scope) = @_;
    });

    run_async(async sub {
        await $wrapped->(
            $scope,
            async sub { { type => 'websocket.disconnect' } },
            async sub { },
        );
    });

    is $seen_scope, $scope, 'WebSocket scope with duplicate Host passes through untouched';
};

subtest 'TrustedHosts does not catch downstream exceptions' => sub {
    my $mw = PAGI::Middleware::TrustedHosts->new(hosts => ['example.com']);
    my $diagnostic = "TrustedHosts downstream sentinel\n";
    my $wrapped = $mw->wrap(async sub { die $diagnostic });

    my $future = $wrapped->(
        {
            type    => 'http',
            path    => '/',
            method  => 'GET',
            headers => [['Host', 'example.com']],
        },
        async sub { { type => 'http.disconnect' } },
        async sub { },
    );
    $loop->await($future);

    ok $future->is_failed, 'wrapped Future remains failed';
    is [$future->failure]->[0], $diagnostic, 'exact downstream failure propagates';
};

# =============================================================================
# Test: CSRF middleware validates tokens on POST requests
# =============================================================================

subtest 'CSRF rejects POST without token' => sub {
    my $mw = PAGI::Middleware::CSRF->new(secret => 'test-secret');

    my $app_called = 0;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $app_called = 1;
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/submit',
                method  => 'POST',
                headers => [],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    ok !$app_called, 'app not called without token';
    is $sent[0]{status}, 403, 'status is 403 Forbidden';
};

subtest 'CSRF enforced default negotiates its generic 403 through Pages' => sub {
    my @representations = (
        ['application/problem+json', 'application/problem+json'],
        ['text/plain', 'text/plain; charset=utf-8'],
    );

    for my $representation (@representations) {
        my ($accept, $content_type) = @$representation;
        my $mw = PAGI::Middleware::CSRF->new(secret => 'test-secret');
        my $app_calls = 0;
        my $wrapped = $mw->wrap(async sub { $app_calls++ });
        my @sent;

        run_async(async sub {
            await $wrapped->(
                {
                    type    => 'http',
                    path    => '/submit',
                    method  => 'POST',
                    headers => [['Accept', $accept]],
                },
                async sub { { type => 'http.disconnect' } },
                async sub { my ($event) = @_; push @sent, $event },
            );
        });

        my $label = "CSRF rejection with $accept";
        is $app_calls, 0, "$label does not call downstream";
        is $sent[0]{status}, 403, "$label retains status 403";
        is [response_header_values($sent[0], 'Content-Type')],
            [$content_type], "$label negotiates the requested representation";
        is [response_header_values($sent[0], 'Cache-Control')],
            ['no-store'], "$label uses the Pages error cache policy";
        is [response_header_values($sent[0], 'Vary')],
            ['Accept'], "$label varies negotiated responses on Accept";

        if ($accept eq 'application/problem+json') {
            my $problem = eval { decode_json($sent[1]{body}) };
            ok $problem, "$label renders a JSON problem document";
            if ($problem) {
                is $problem->{status}, 403, "$label renders problem status";
                is $problem->{detail},
                    'You do not have permission to access this resource.',
                    "$label renders the generic Pages detail";
            }
        }
        else {
            is $sent[1]{body},
                "403 Forbidden\n\nYou do not have permission to access this resource.\n",
                "$label renders the generic Pages text body";
        }
    }
};

subtest 'CSRF allows POST with valid token' => sub {
    my $mw = PAGI::Middleware::CSRF->new(secret => 'test-secret');

    # Generate a token first with a GET request
    my $token;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $token = $scope->{csrf_token};
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    # GET request to get token
    my @sent1;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/',
                method  => 'GET',
                headers => [],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent1, $event },
        );
    });

    ok $token, 'token generated on GET';

    # Extract Set-Cookie token
    my $cookie_token;
    for my $h (@{$sent1[0]{headers}}) {
        if (lc($h->[0]) eq 'set-cookie' && $h->[1] =~ /csrf_token=([^;]+)/) {
            $cookie_token = $1;
            last;
        }
    }
    ok $cookie_token, 'token set in cookie';

    # POST request with token
    my $post_called = 0;
    my $post_app = async sub  {
        my ($scope, $receive, $send) = @_;
        $post_called = 1;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Created',
            more => 0,
        });
    };

    my $wrapped2 = $mw->wrap($post_app);

    my @sent2;
    run_async(async sub {
        await $wrapped2->(
            {
                type    => 'http',
                path    => '/submit',
                method  => 'POST',
                headers => [
                    ['cookie', "csrf_token=$cookie_token"],
                    ['x-csrf-token', $cookie_token],
                ],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent2, $event },
        );
    });

    ok $post_called, 'app called with valid token';
    is $sent2[0]{status}, 200, 'POST succeeds with valid token';
};

subtest 'CSRF allows GET without token' => sub {
    my $mw = PAGI::Middleware::CSRF->new(secret => 'test-secret');

    my $app_called = 0;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $app_called = 1;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/page',
                method  => 'GET',
                headers => [],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    ok $app_called, 'app called for GET without token';
    is $sent[0]{status}, 200, 'GET succeeds without token';
};

# =============================================================================
# Test: CSRF 'enforce' config - 'header' (default) vs 'app' (issue-only)
# =============================================================================

subtest 'CSRF rejects invalid enforce value' => sub {
    like(
        dies { PAGI::Middleware::CSRF->new(secret => 'test-secret', enforce => 'bogus') },
        qr/enforce/,
        'constructor dies on an unrecognized enforce value',
    );
};

subtest "CSRF enforce => 'header' behaves exactly like the default" => sub {
    my $mw = PAGI::Middleware::CSRF->new(secret => 'test-secret', enforce => 'header');

    my $app_called = 0;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $app_called = 1;
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/submit',
                method  => 'POST',
                headers => [],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    ok !$app_called, 'app not called without token';
    is $sent[0]{status}, 403, 'status is 403 Forbidden, same as default enforcement';
};

subtest "CSRF enforce => 'app' passes an unsafe request through with no token" => sub {
    my $mw = PAGI::Middleware::CSRF->new(secret => 'test-secret', enforce => 'app');

    my $seen_token;
    my $app_called = 0;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $app_called   = 1;
        $seen_token   = $scope->{csrf_token};
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/submit',
                method  => 'POST',
                headers => [],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    ok $app_called, "app mode: unsafe POST with no submitted token still reaches the app";
    is $sent[0]{status}, 200, 'no auto-403 in app mode';
    ok $seen_token, 'a freshly minted token is stashed into scope';

    my ($set_cookie) = grep { lc($_->[0]) eq 'set-cookie' } @{$sent[0]{headers}};
    ok $set_cookie, 'Set-Cookie issued for the freshly minted token';
    like $set_cookie->[1], qr/\Q$seen_token\E/, 'Set-Cookie carries the same token stashed in scope';
};

subtest "CSRF enforce => 'app' preserves an application-owned Context response" => sub {
    my $mw = PAGI::Middleware::CSRF->new(
        secret => 'test-secret', enforce => 'app',
    );
    my @sent;
    my $send = async sub { my ($event) = @_; push @sent, $event };
    my $wrapped = $mw->wrap(async sub {
        my ($scope, $receive, $downstream_send) = @_;
        my $ctx = PAGI::Context->new($scope, $receive, $downstream_send);
        await $ctx->respond(
            $ctx->text('application-owned CSRF rejection', status => 403),
        );
    });

    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/submit',
                method  => 'POST',
                headers => [['Accept', 'application/problem+json']],
            },
            async sub { { type => 'http.disconnect' } },
            $send,
        );
    });

    is $sent[0]{status}, 403, 'application retains its chosen status';
    is [response_header_values($sent[0], 'Content-Type')],
        ['text/plain; charset=utf-8'],
        'application Context response remains literal text despite Accept';
    is [response_header_values($sent[0], 'Vary')], [],
        'application Context response does not gain Pages negotiation metadata';
    is $sent[1]{body}, 'application-owned CSRF rejection',
        'application Context response body remains byte-for-byte literal';
};

subtest "CSRF enforce => 'app' stashes the existing COOKIE token, not a new one" => sub {
    my $mw = PAGI::Middleware::CSRF->new(secret => 'test-secret', enforce => 'app');

    # First, a GET establishes a cookie token.
    my $cookie_token;
    my $get_app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };
    my @sent1;
    run_async(async sub {
        await $mw->wrap($get_app)->(
            { type => 'http', path => '/', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent1, $event },
        );
    });
    for my $h (@{$sent1[0]{headers}}) {
        if (lc($h->[0]) eq 'set-cookie' && $h->[1] =~ /csrf_token=([^;]+)/) {
            $cookie_token = $1;
        }
    }
    ok $cookie_token, 'cookie token issued on GET';

    # Now an unsafe POST with no submitted token at all (app owns validation) --
    # scope must carry the SAME cookie token, unchanged, not a regenerated one.
    my $seen_token;
    my $post_app = async sub  {
        my ($scope, $receive, $send) = @_;
        $seen_token = $scope->{csrf_token};
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'Created', more => 0 });
    };

    my @sent2;
    run_async(async sub {
        await $mw->wrap($post_app)->(
            {
                type    => 'http',
                path    => '/submit',
                method  => 'POST',
                headers => [['cookie', "csrf_token=$cookie_token"]],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent2, $event },
        );
    });

    is $sent2[0]{status}, 200, 'app mode never auto-rejects';
    is $seen_token, $cookie_token, 'scope carries the COOKIE token, not a freshly minted one';

    my @set_cookie = grep { lc($_->[0]) eq 'set-cookie' } @{$sent2[0]{headers}};
    is scalar(@set_cookie), 0, 'no Set-Cookie re-issued when the cookie token already existed';
};

subtest 'CSRF cookie has no Secure attribute by default' => sub {
    my $mw = PAGI::Middleware::CSRF->new(secret => 'test-secret');

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my @sent;
    run_async(async sub {
        await $mw->wrap($app)->(
            { type => 'http', path => '/', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    my ($set_cookie) = grep { lc($_->[0]) eq 'set-cookie' } @{$sent[0]{headers}};
    ok $set_cookie, 'cookie issued';
    unlike $set_cookie->[1], qr/;\s*Secure/, 'no Secure attribute by default (would break plain-http dev usage)';
};

subtest "CSRF cookie includes Secure attribute when secure => 1" => sub {
    my $mw = PAGI::Middleware::CSRF->new(secret => 'test-secret', secure => 1);

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my @sent;
    run_async(async sub {
        await $mw->wrap($app)->(
            { type => 'http', path => '/', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    my ($set_cookie) = grep { lc($_->[0]) eq 'set-cookie' } @{$sent[0]{headers}};
    ok $set_cookie, 'cookie issued';
    like $set_cookie->[1], qr/;\s*Secure/, 'Secure attribute present when configured';
};

done_testing;
