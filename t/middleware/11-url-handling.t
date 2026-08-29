#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use IO::Async::Loop;
use JSON::MaybeXS;
use Scalar::Util qw(dualvar refaddr);

use PAGI::Middleware::Rewrite;
use PAGI::Middleware::HTTPSRedirect;
use PAGI::Middleware::ReverseProxy;
use PAGI::Middleware::Healthcheck;
use PAGI::Request;

my $loop = IO::Async::Loop->new;

sub make_scope {
    my (%opts) = @_;
    return {
        type         => 'http',
        method       => $opts{method} // 'GET',
        path         => $opts{path} // '/',
        scheme       => $opts{scheme} // 'http',
        query_string => $opts{query_string},
        headers      => $opts{headers} // [],
        client       => $opts{client} // ['192.168.1.100', 12345],
        server       => $opts{server} // ['127.0.0.1', 5000],
    };
}

sub run_async (&) {
    my ($code) = @_;
    $loop->await($code->());
}

sub response_header_values {
    my ($event, $name) = @_;
    return map { $_->[1] }
        grep { lc($_->[0]) eq lc($name) } @{$event->{headers}};
}

# ===================
# Rewrite Middleware Tests
# ===================

subtest 'Rewrite middleware - exact match' => sub {
    my $rewrite = PAGI::Middleware::Rewrite->new(
        rules => [{ from => '/old', to => '/new' }],
    );

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $rewrite->wrap($app);
    my $scope = make_scope(path => '/old');

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    is $captured_scope->{path}, '/new', 'path rewritten';
    is $captured_scope->{original_path}, '/old', 'original path preserved';
};

subtest 'Rewrite middleware - regex with captures' => sub {
    my $rewrite = PAGI::Middleware::Rewrite->new(
        rules => [{ from => qr{^/user/(\d+)}, to => '/users/$1' }],
    );

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $rewrite->wrap($app);
    my $scope = make_scope(path => '/user/123');

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    is $captured_scope->{path}, '/users/123', 'path rewritten with capture';
};

subtest 'Rewrite middleware - redirect mode' => sub {
    my $rewrite = PAGI::Middleware::Rewrite->new(
        rules => [{ from => '/old', to => '/new' }],
        redirect => 1,
        redirect_code => 302,
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $rewrite->wrap($app);
    my $scope = make_scope(
        path    => '/old',
        headers => [['Accept', 'application/json']],
    );

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 302, 'redirect status';
    my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
    is $headers{location}, '/new', 'redirect location';
    is $headers{'content-type'}, 'text/html; charset=utf-8',
        'redirect target uses the semantic Redirect representation';
};

subtest 'Rewrite redirect preserves raw query before target fragment' => sub {
    my $rewrite = PAGI::Middleware::Rewrite->new(
        rules => [{ from => '/old', to => '/new?sort=date#results' }],
        redirect => 1,
        redirect_code => 308,
    );
    my $wrapped = $rewrite->wrap(async sub {
        die "redirect called downstream\n";
    });
    my @events;

    run_async {
        $wrapped->(
            make_scope(path => '/old', query_string => 'q=a%2Bb&x=%26'),
            async sub { {} },
            async sub { my ($event) = @_; push @events, $event },
        )
    };

    is $events[0]{status}, 308, 'configured redirect status is retained';
    my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
    is $headers{location}, '/new?sort=date&q=a%2Bb&x=%26#results',
        'raw query is inserted before the first fragment';
};

subtest 'redirect middleware constructors accept exactly Redirect statuses' => sub {
    my @factories = (
        Rewrite => sub {
            PAGI::Middleware::Rewrite->new(
                rules => [], redirect => 1, redirect_code => $_[0],
            );
        },
        HTTPSRedirect => sub {
            PAGI::Middleware::HTTPSRedirect->new(redirect_code => $_[0]);
        },
    );

    while (@factories) {
        my ($name, $factory) = splice(@factories, 0, 2);
        for my $status (301, 302, 303, 307, 308) {
            ok lives { $factory->($status) },
                "$name accepts redirect status $status";
        }

        for my $case (
            ['undefined', undef],
            ['zero', 0],
            ['non-redirect integer', 200],
            ['unsupported 3xx integer', 300],
            ['bodyless 304', 304],
            ['unused 305', 305],
            ['unused 306', 306],
            ['unsupported 309', 309],
            ['unsupported 399', 399],
            ['decimal string', '302.0'],
            ['leading-zero string', '0301'],
            ['empty string', ''],
            ['nonnumeric string', 'x'],
            ['array reference', []],
            ['hash reference', {}],
            ['code reference', sub { 301 }],
        ) {
            my ($label, $status) = @$case;
            my @warnings;
            my $error;
            {
                local $SIG{__WARN__} = sub { push @warnings, @_ };
                $error = dies { $factory->($status) };
            }
            like $error,
                qr/redirect_code.*301.*302.*303.*307.*308/i,
                "$name rejects $label redirect status at construction";
            is \@warnings, [], "$name rejects $label without warnings";
        }

        my @dualvar_cases = (
            [
                'canonical string with unsupported numeric facet',
                dualvar(999, '301'),
            ],
            [
                'supported numeric with noncanonical string facet',
                dualvar(301, '999'),
            ],
        );
        for my $case (@dualvar_cases) {
            my ($label, $status) = @$case;
            my @warnings;
            my $error;
            {
                local $SIG{__WARN__} = sub { push @warnings, @_ };
                $error = dies { $factory->($status) };
            }
            like $error,
                qr/redirect_code.*301.*302.*303.*307.*308/i,
                "$name rejects $label at construction";
            is \@warnings, [], "$name rejects $label without warnings";
        }

        my @supported = qw(301 302 303 307 308);
        for my $string_status (@supported) {
            for my $numeric_status (@supported) {
                next if $numeric_status eq $string_status;
                my $status = dualvar(0 + $numeric_status, $string_status);
                my @warnings;
                my $error;
                {
                    local $SIG{__WARN__} = sub { push @warnings, @_ };
                    $error = dies { $factory->($status) };
                }
                like $error,
                    qr/redirect_code.*301.*302.*303.*307.*308/i,
                    "$name rejects string $string_status with numeric "
                        . "$numeric_status at construction";
                is \@warnings, [],
                    "$name rejects unequal supported facets without warnings";
            }
        }

        my $matching;
        my @matching_warnings;
        {
            local $SIG{__WARN__} = sub { push @matching_warnings, @_ };
            $matching = $factory->(dualvar(307, '307'));
        }
        is $matching->{redirect_code}, 307,
            "$name stores a matching dualvar as the intended status";
        is \@matching_warnings, [],
            "$name accepts a matching dualvar without warnings";
    }
};

subtest 'Rewrite middleware - no match passes through' => sub {
    my $rewrite = PAGI::Middleware::Rewrite->new(
        rules => [{ from => '/old', to => '/new' }],
    );

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $rewrite->wrap($app);
    my $scope = make_scope(path => '/other');

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    is $captured_scope->{path}, '/other', 'path unchanged';
};

subtest 'Rewrite non-HTTP scopes pass through unchanged' => sub {
    my $rewrite = PAGI::Middleware::Rewrite->new(
        rules => [{ from => '/old', to => '/new#fragment' }],
        redirect => 1,
    );
    my $scope = {
        type         => 'websocket',
        path         => '/old',
        query_string => 'q=socket',
    };
    my $captured_scope;
    my @events;
    my $wrapped = $rewrite->wrap(async sub {
        my ($downstream_scope, $receive, $send) = @_;
        $captured_scope = $downstream_scope;
        await $send->({ type => 'websocket.accept' });
    });

    run_async {
        $wrapped->(
            $scope,
            async sub { {} },
            async sub { my ($event) = @_; push @events, $event },
        )
    };

    is refaddr($captured_scope), refaddr($scope),
        'Rewrite passes the original non-HTTP scope by identity';
    is \@events, [{ type => 'websocket.accept' }],
        'Rewrite forwards the protocol-specific child event unchanged';
};

# ===================
# HTTPSRedirect Middleware Tests
# ===================

subtest 'HTTPSRedirect - redirects HTTP to HTTPS' => sub {
    my $redirect = PAGI::Middleware::HTTPSRedirect->new();

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $redirect->wrap($app);
    my $scope = make_scope(
        scheme  => 'http',
        path    => '/test',
        headers => [
            ['Host', 'example.com'],
            ['Accept', 'application/json'],
        ],
    );

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 301, 'redirect status';
    my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
    is $headers{location}, 'https://example.com/test', 'redirects to HTTPS';
    is $headers{'content-type'}, 'text/html; charset=utf-8',
        'HTTPS target uses the semantic Redirect representation';
};

subtest 'HTTPSRedirect - passes through HTTPS' => sub {
    my $redirect = PAGI::Middleware::HTTPSRedirect->new();

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $redirect->wrap($app);
    my $scope = make_scope(scheme => 'https');

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 200, 'HTTPS passes through';
};

subtest 'HTTPSRedirect - HSTS remains local to secure pass-through' => sub {
    my $redirect = PAGI::Middleware::HTTPSRedirect->new(
        hsts => 1,
        hsts_max_age => 600,
    );
    my $wrapped = $redirect->wrap(async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type => 'http.response.start', status => 204, headers => [],
        });
        await $send->({ type => 'http.response.body', body => '', more => 0 });
    });
    my @events;

    run_async {
        $wrapped->(
            make_scope(scheme => 'https'),
            async sub { {} },
            async sub { my ($event) = @_; push @events, $event },
        )
    };

    is $events[0]{status}, 204, 'secure child retains its response status';
    is [response_header_values($events[0], 'Strict-Transport-Security')],
        ['max-age=600; includeSubDomains'],
        'secure child response receives the configured HSTS field';
};

subtest 'HTTPSRedirect - excludes paths' => sub {
    my $redirect = PAGI::Middleware::HTTPSRedirect->new(
        exclude => ['/health'],
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $redirect->wrap($app);
    my $scope = make_scope(scheme => 'http', path => '/health');

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 200, 'excluded path not redirected';
};

subtest 'HTTPSRedirect - builds redirect authority from Host or server' => sub {
    my @cases = (
        {
            name     => 'Host is preferred over server',
            scope    => make_scope(
                path    => '/preferred',
                headers => [['Host', 'header.example:8443']],
                server  => ['fallback.example', 80],
            ),
            location => 'https://header.example:8443/preferred',
        },
        {
            name     => 'explicit Host port 80 is preserved',
            scope    => make_scope(
                path    => '/port',
                headers => [['Host', 'example.com:80']],
            ),
            location => 'https://example.com:80/port',
        },
        {
            name     => 'absent Host falls back to HTTP default-port server',
            scope    => make_scope(
                path    => '/path',
                headers => [],
                server  => ['example.com', 80],
            ),
            location => 'https://example.com/path',
        },
        {
            name     => 'server IPv6 is bracketed',
            scope    => make_scope(
                path    => '/v6',
                headers => [],
                server  => ['2001:db8::1', 8080],
            ),
            location => 'https://[2001:db8::1]:8080/v6',
        },
        {
            name     => 'query string is retained',
            scope    => make_scope(
                path         => '/search',
                query_string => 'q=host&page=2',
                headers      => [['Host', 'example.com']],
            ),
            location => 'https://example.com/search?q=host&page=2',
        },
    );

    for my $case (@cases) {
        my $redirect = PAGI::Middleware::HTTPSRedirect->new;
        my $wrapped = $redirect->wrap(async sub { die "redirect called downstream\n" });
        my @events;

        run_async {
            $wrapped->(
                $case->{scope},
                async sub { {} },
                async sub { my ($event) = @_; push @events, $event },
            )
        };

        is $events[0]{status}, 301, "$case->{name}: redirect status";
        my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
        is $headers{location}, $case->{location}, "$case->{name}: redirect location";
    }
};

subtest 'HTTPSRedirect preserves raw query before path fragment' => sub {
    my $redirect = PAGI::Middleware::HTTPSRedirect->new(
        redirect_code => 303,
    );
    my $wrapped = $redirect->wrap(async sub {
        die "redirect called downstream\n";
    });
    my @events;

    run_async {
        $wrapped->(
            make_scope(
                path         => '/search?sort=date#results',
                query_string => 'q=a%2Bb&x=%26',
                headers      => [['Host', 'example.com']],
            ),
            async sub { {} },
            async sub { my ($event) = @_; push @events, $event },
        )
    };

    is $events[0]{status}, 303, 'configured redirect status is retained';
    my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
    is $headers{location},
        'https://example.com/search?sort=date&q=a%2Bb&x=%26#results',
        'raw query is inserted before the first fragment';
};

subtest 'HTTPSRedirect - invalid authority negotiates Pages 400' => sub {
    my @cases = (
        {
            name  => 'duplicate Host',
            scope => make_scope(
                headers => [
                    ['Host', 'example.com'],
                    ['host', 'evil.example'],
                    ['Accept', 'application/problem+json'],
                ],
                server  => ['fallback.example', 80],
            ),
            content_type => 'application/problem+json',
        },
        {
            name  => 'malformed Host',
            scope => make_scope(
                headers => [['Host', 'example.com/path']],
                server  => ['fallback.example', 80],
            ),
        },
        {
            name  => 'absent Host with unusable server',
            scope => make_scope(headers => [], server => ['bad..example', 80]),
        },
        {
            name  => 'undefined headers container',
            scope => do {
                my $scope = make_scope(server => ['fallback.example', 80]);
                $scope->{headers} = undef;
                $scope;
            },
        },
    );

    for my $case (@cases) {
        my $redirect = PAGI::Middleware::HTTPSRedirect->new;
        my $app_calls = 0;
        my $wrapped = $redirect->wrap(async sub { $app_calls++ });
        my @events;

        run_async {
            $wrapped->(
                $case->{scope},
                async sub { {} },
                async sub { my ($event) = @_; push @events, $event },
            )
        };

        is $app_calls, 0, "$case->{name}: downstream is not called";
        is scalar(@events), 2, "$case->{name}: start and terminal body are sent";
        is $events[0]{type}, 'http.response.start', "$case->{name}: response starts";
        is $events[0]{status}, 400, "$case->{name}: status is 400";
        my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
        is $headers{'content-type'},
            $case->{content_type} // 'text/html; charset=utf-8',
            "$case->{name}: Pages negotiates from the original scope";
        is $headers{'cache-control'}, 'no-store',
            "$case->{name}: Pages applies the error cache policy";
        unlike $events[1]{body}, qr/Invalid Host header|evil\.example/,
            "$case->{name}: response does not expose rejected authority data";
        if ($case->{content_type}) {
            my $problem = decode_json($events[1]{body});
            is $problem->{status}, 400,
                "$case->{name}: problem document carries status 400";
        }
    }
};

subtest 'redirect middleware inherits Redirect target validation before sending' => sub {
    my @cases = (
        [
            Rewrite => sub {
                my ($target) = @_;
                return PAGI::Middleware::Rewrite->new(
                    rules => [{ from => '/old', to => $target }],
                    redirect => 1,
                )->wrap(async sub { die "redirect called downstream\n" });
            },
            sub { make_scope(path => '/old') },
        ],
        [
            HTTPSRedirect => sub {
                return PAGI::Middleware::HTTPSRedirect->new->wrap(
                    async sub { die "redirect called downstream\n" },
                );
            },
            sub {
                my ($target) = @_;
                return make_scope(
                    path => $target,
                    headers => [['Host', 'example.com']],
                );
            },
        ],
    );

    for my $case (@cases) {
        my ($name, $wrap, $scope_for) = @$case;
        for my $target ("/bad\nnext", "/wide\x{263a}") {
            my $wrapped = $wrap->($target);
            my @events;
            my $future = $wrapped->(
                $scope_for->($target),
                async sub { {} },
                async sub { my ($event) = @_; push @events, $event },
            );
            $loop->await($future);
            ok $future->is_failed, "$name rejects unsafe logical target";
            like [$future->failure]->[0], qr/redirect location.*URI-reference/i,
                "$name reports Redirect target validation";
            is \@events, [], "$name rejects target before response start";
        }
    }
};

subtest 'semantic Redirect awaits and propagates send failure' => sub {
    my $diagnostic = "redirect send sentinel\n";
    my $wrapped = PAGI::Middleware::Rewrite->new(
        rules => [{ from => '/old', to => '/new' }],
        redirect => 1,
    )->wrap(async sub { die "redirect called downstream\n" });
    my $future = $wrapped->(
        make_scope(path => '/old'),
        async sub { {} },
        sub { Future->fail($diagnostic) },
    );
    $loop->await($future);

    ok $future->is_failed, 'redirect wrapper remains failed';
    is [$future->failure]->[0], $diagnostic,
        'exact Redirect response send failure propagates';
};

subtest 'HTTPSRedirect - non-HTTP downstream exception propagates' => sub {
    my $redirect = PAGI::Middleware::HTTPSRedirect->new;
    my $diagnostic = "HTTPSRedirect downstream sentinel\n";
    my $wrapped = $redirect->wrap(async sub { die $diagnostic });

    my $future = $wrapped->(
        {
            type    => 'websocket',
            path    => '/socket',
            scheme  => 'ws',
            headers => [['Host', 'one.example'], ['host', 'two.example']],
        },
        async sub { {} },
        async sub { },
    );
    $loop->await($future);

    ok $future->is_failed, 'wrapped Future remains failed';
    is [$future->failure]->[0], $diagnostic,
        'exact non-HTTP downstream failure propagates';
};

# ===================
# ReverseProxy Middleware Tests
# ===================

subtest 'ReverseProxy - updates client from X-Forwarded-For' => sub {
    my $proxy = PAGI::Middleware::ReverseProxy->new(
        trusted_proxies => ['127.0.0.1'],
    );

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $proxy->wrap($app);
    my $scope = make_scope(
        client  => ['127.0.0.1', 12345],
        headers => [['X-Forwarded-For', '203.0.113.50, 198.51.100.1']],
    );

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    is $captured_scope->{client}[0], '203.0.113.50', 'client IP from X-Forwarded-For';
    is $captured_scope->{original_client}[0], '127.0.0.1', 'original client preserved';
};

subtest 'ReverseProxy - updates scheme from X-Forwarded-Proto' => sub {
    my $proxy = PAGI::Middleware::ReverseProxy->new(
        trusted_proxies => ['127.0.0.1'],
    );

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $proxy->wrap($app);
    my $scope = make_scope(
        client  => ['127.0.0.1', 12345],
        scheme  => 'http',
        headers => [['X-Forwarded-Proto', 'https']],
    );

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    is $captured_scope->{scheme}, 'https', 'scheme updated from header';
};

subtest 'ReverseProxy - ignores untrusted proxies' => sub {
    my $proxy = PAGI::Middleware::ReverseProxy->new(
        trusted_proxies => ['10.0.0.1'],
    );

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $proxy->wrap($app);
    my $scope = make_scope(
        client  => ['192.168.1.100', 12345],  # Not trusted
        headers => [['X-Forwarded-For', '203.0.113.50']],
    );

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    is $captured_scope->{client}[0], '192.168.1.100', 'client IP unchanged for untrusted proxy';
};

subtest 'ReverseProxy - trusted forwarded Host replaces every Host exactly once' => sub {
    my @cases = (
        {
            name    => 'no incoming Host',
            headers => [
                ['X-First', 'one'],
                ['X-Forwarded-Host', 'public.example:8443'],
                ['X-Last', 'two'],
            ],
            expected => [
                ['X-First', 'one'],
                ['X-Forwarded-Host', 'public.example:8443'],
                ['X-Last', 'two'],
                ['host', 'public.example:8443'],
            ],
        },
        {
            name    => 'one incoming Host',
            headers => [
                ['Host', 'internal.example'],
                ['X-First', 'one'],
                ['X-Forwarded-Host', 'public.example:8443'],
                ['X-Last', 'two'],
            ],
            expected => [
                ['X-First', 'one'],
                ['X-Forwarded-Host', 'public.example:8443'],
                ['X-Last', 'two'],
                ['host', 'public.example:8443'],
            ],
        },
        {
            name    => 'multiple mixed-case incoming Host fields',
            headers => [
                ['X-First', 'one'],
                ['Host', 'internal.example'],
                ['X-Middle', 'middle'],
                ['hOsT', 'other-internal.example'],
                ['X-Forwarded-Host', 'public.example:8443'],
                ['X-Last', 'two'],
            ],
            expected => [
                ['X-First', 'one'],
                ['X-Middle', 'middle'],
                ['X-Forwarded-Host', 'public.example:8443'],
                ['X-Last', 'two'],
                ['host', 'public.example:8443'],
            ],
        },
    );

    for my $case (@cases) {
        my $proxy = PAGI::Middleware::ReverseProxy->new(
            trusted_proxies => ['127.0.0.1'],
        );
        my $captured_scope;
        my $wrapped = $proxy->wrap(async sub {
            my ($scope) = @_;
            $captured_scope = $scope;
        });
        my $scope = make_scope(
            client  => ['127.0.0.1', 12345],
            headers => $case->{headers},
        );
        my $json = JSON::MaybeXS->new(canonical => 1);
        my $scope_bytes = $json->encode($scope);
        my $input_headers = $scope->{headers};
        my @input_pairs = map { refaddr($_) } @$input_headers;

        run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

        my @host = grep {
            my $name = $_->[0];
            $name =~ tr/A-Z/a-z/;
            $name eq 'host';
        } @{$captured_scope->{headers}};
        is \@host, [['host', 'public.example:8443']],
            "$case->{name}: downstream sees exactly one validated Host";
        is $captured_scope->{headers}, $case->{expected},
            "$case->{name}: unrelated header order is retained and Host is appended";
        isnt refaddr($captured_scope), refaddr($scope),
            "$case->{name}: downstream receives a shallow scope copy";
        isnt refaddr($captured_scope->{headers}), refaddr($input_headers),
            "$case->{name}: rewritten headers use a new array";
        is $json->encode($scope), $scope_bytes,
            "$case->{name}: input scope bytes remain unchanged";
        is refaddr($scope->{headers}), refaddr($input_headers),
            "$case->{name}: input retains its header array";
        is [map { refaddr($_) } @{$scope->{headers}}], \@input_pairs,
            "$case->{name}: input retains every header pair";
    }
};

subtest 'ReverseProxy - trusted forwarded Host rejects ambiguity and invalid authority' => sub {
    my @cases = (
        {
            name    => 'repeated identical field',
            headers => [
                ['X-Forwarded-Host', 'public.example'],
                ['X-Forwarded-Host', 'public.example'],
                ['Accept', 'text/plain'],
            ],
        },
        {
            name    => 'repeated conflicting field',
            headers => [
                ['X-Forwarded-Host', 'public.example'],
                ['X-Forwarded-Host', 'evil.example'],
                ['Accept', 'text/plain'],
            ],
        },
        {
            name    => 'mixed-case repeated field',
            headers => [
                ['X-FoRwArDeD-HoSt', 'public.example'],
                ['x-forwarded-host', 'public.example'],
                ['Accept', 'text/plain'],
            ],
        },
        {
            name    => 'comma-containing value',
            headers => [
                ['X-Forwarded-Host', 'public.example, evil.example'],
                ['Accept', 'text/plain'],
            ],
        },
        {
            name    => 'malformed authority',
            headers => [
                ['X-Forwarded-Host', 'public.example/path'],
                ['Accept', 'text/plain'],
            ],
        },
        {
            name    => 'port exceeds 65535',
            headers => [
                ['X-Forwarded-Host', 'public.example:65536'],
                ['Accept', 'text/plain'],
            ],
        },
    );

    for my $case (@cases) {
        my $proxy = PAGI::Middleware::ReverseProxy->new(
            trusted_proxies => ['127.0.0.1'],
        );
        my $app_calls = 0;
        my $wrapped = $proxy->wrap(async sub { $app_calls++ });
        my $scope = make_scope(
            client  => ['127.0.0.1', 12345],
            headers => $case->{headers},
        );
        my @events;

        run_async {
            $wrapped->(
                $scope,
                async sub { {} },
                async sub { my ($event) = @_; push @events, $event },
            )
        };

        is $app_calls, 0, "$case->{name}: downstream is not called";
        is scalar(@events), 2, "$case->{name}: complete response is sent";
        is $events[0]{status}, 400, "$case->{name}: status remains 400";
        is [response_header_values($events[0], 'Content-Type')],
            ['text/plain; charset=utf-8'],
            "$case->{name}: Pages negotiates text";
        is [response_header_values($events[0], 'Cache-Control')],
            ['no-store'], "$case->{name}: Pages applies error cache policy";
        is [response_header_values($events[0], 'Vary')],
            ['Accept'], "$case->{name}: Pages varies on Accept";
        is $events[1], {
            type => 'http.response.body',
            body => "400 Bad Request\n\nThe server could not understand the request.\n",
            more => 0,
        }, "$case->{name}: generic Pages 400 response is sent";
    }
};

subtest 'ReverseProxy invalid forwarded authority negotiates problem JSON' => sub {
    my $proxy = PAGI::Middleware::ReverseProxy->new(
        trusted_proxies => ['127.0.0.1'],
    );
    my $app_calls = 0;
    my $wrapped = $proxy->wrap(async sub { $app_calls++ });
    my @events;

    run_async {
        $wrapped->(
            make_scope(
                client  => ['127.0.0.1', 12345],
                headers => [
                    ['X-Forwarded-Host', 'public.example/path'],
                    ['Accept', 'application/problem+json'],
                ],
            ),
            async sub { {} },
            async sub { my ($event) = @_; push @events, $event },
        )
    };

    is $app_calls, 0, 'invalid forwarded authority does not call downstream';
    is $events[0]{status}, 400, 'invalid forwarded authority retains status 400';
    is [response_header_values($events[0], 'Content-Type')],
        ['application/problem+json'],
        'invalid forwarded authority negotiates problem JSON';
    is [response_header_values($events[0], 'Cache-Control')],
        ['no-store'], 'problem response uses the Pages error cache policy';
    is [response_header_values($events[0], 'Vary')],
        ['Accept'], 'problem response varies on Accept';
    my $problem = eval { JSON::MaybeXS::decode_json($events[1]{body}) };
    ok $problem, 'invalid forwarded authority renders a JSON problem document';
    if ($problem) {
        is $problem->{status}, 400, 'problem document contains status 400';
        is $problem->{detail}, 'The server could not understand the request.',
            'problem document does not expose the rejected authority';
    }
};

subtest 'ReverseProxy - untrusted malformed forwarded Host passes through unchanged' => sub {
    my $proxy = PAGI::Middleware::ReverseProxy->new(
        trusted_proxies => ['10.0.0.1'],
    );
    my $captured_scope;
    my $app_calls = 0;
    my $wrapped = $proxy->wrap(async sub {
        ($captured_scope) = @_;
        $app_calls++;
    });
    my $scope = make_scope(
        client  => ['192.168.1.100', 12345],
        headers => [
            ['Host', 'internal.example'],
            ['X-Forwarded-Host', 'public.example/path'],
        ],
    );
    my $json = JSON::MaybeXS->new(canonical => 1);
    my $scope_bytes = $json->encode($scope);
    my @events;

    run_async {
        $wrapped->(
            $scope,
            async sub { {} },
            async sub { my ($event) = @_; push @events, $event },
        )
    };

    is $app_calls, 1, 'untrusted malformed field reaches downstream';
    is refaddr($captured_scope), refaddr($scope),
        'untrusted request passes the original scope through';
    is $json->encode($scope), $scope_bytes,
        'untrusted malformed field and scope remain byte-for-byte unchanged';
    is \@events, [], 'ReverseProxy sends no local rejection';
};

subtest 'ReverseProxy - non-HTTP scopes pass through outside Pages' => sub {
    my $proxy = PAGI::Middleware::ReverseProxy->new(trust_all => 1);
    my $captured_scope;
    my $app_calls = 0;
    my $scope = {
        type    => 'websocket',
        path    => '/socket',
        client  => ['127.0.0.1', 12345],
        headers => [['X-Forwarded-Host', 'public.example/path']],
    };
    my $wrapped = $proxy->wrap(async sub {
        ($captured_scope) = @_;
        $app_calls++;
    });
    my @events;

    run_async {
        $wrapped->(
            $scope,
            async sub { {} },
            async sub { my ($event) = @_; push @events, $event },
        )
    };

    is $app_calls, 1, 'non-HTTP scope reaches downstream once';
    is refaddr($captured_scope), refaddr($scope),
        'non-HTTP pass-through preserves the original scope';
    is \@events, [], 'non-HTTP pass-through emits no Pages response';
};

subtest 'ReverseProxy - rewritten scope does not inherit stale Request headers' => sub {
    my $proxy = PAGI::Middleware::ReverseProxy->new(
        trusted_proxies => ['127.0.0.1'],
    );
    my $scope = make_scope(
        client  => ['127.0.0.1', 12345],
        headers => [
            ['Host', 'internal.example'],
            ['X-Forwarded-Host', 'public.example:8443'],
        ],
    );
    my $original_request = PAGI::Request->new($scope, async sub { {} });
    $original_request->headers;
    my $original_cache = $scope->{'pagi.request.headers'};
    my $input_headers = $scope->{headers};

    my $wrapped = $proxy->wrap(async sub {
        my ($rewritten_scope) = @_;
        ok !exists($rewritten_scope->{'pagi.request.headers'}),
            'rewritten scope starts without the inherited Request header cache';
        my $downstream_request = PAGI::Request->new(
            $rewritten_scope,
            async sub { {} },
        );
        is $downstream_request->host, 'public.example:8443',
            'downstream host reads the forwarded value from raw headers';
        is $downstream_request->header('host'), 'public.example:8443',
            'downstream header lookup builds a fresh forwarded Host snapshot';
    });

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    is refaddr($scope->{'pagi.request.headers'}), refaddr($original_cache),
        'original scope retains ownership of its cached snapshot';
    is $scope->{'pagi.request.headers'}->get('host'), 'internal.example',
        'original cached snapshot retains its original Host';
    is refaddr($scope->{headers}), refaddr($input_headers),
        'original scope retains its raw header array';
    is $scope->{headers}, [
        ['Host', 'internal.example'],
        ['X-Forwarded-Host', 'public.example:8443'],
    ], 'original raw headers remain unchanged';
};

# ===================
# Healthcheck Middleware Tests
# ===================

subtest 'Healthcheck - returns health status' => sub {
    my $health = PAGI::Middleware::Healthcheck->new(
        path => '/health',
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'App', more => 0 });
    };

    my $wrapped = $health->wrap($app);
    my $scope = make_scope(path => '/health');

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 200, 'health check returns 200';
    my $body = JSON::MaybeXS::decode_json($events[1]{body});
    is $body->{status}, 'ok', 'status is ok';
};

subtest 'Healthcheck - passes through other paths' => sub {
    my $health = PAGI::Middleware::Healthcheck->new(
        path => '/health',
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'App', more => 0 });
    };

    my $wrapped = $health->wrap($app);
    my $scope = make_scope(path => '/api');

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[1]{body}, 'App', 'non-health path passes through';
};

subtest 'Healthcheck - runs custom checks' => sub {
    my $health = PAGI::Middleware::Healthcheck->new(
        path => '/health',
        checks => {
            always_ok => sub { 1 },
            always_fail => sub { 0 },
        },
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'App', more => 0 });
    };

    my $wrapped = $health->wrap($app);
    my $scope = make_scope(path => '/health');

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 503, 'returns 503 when check fails';
    my $body = JSON::MaybeXS::decode_json($events[1]{body});
    is $body->{status}, 'error', 'status is error';
    is $body->{checks}{always_ok}{status}, 'ok', 'passing check reported';
    is $body->{checks}{always_fail}{status}, 'error', 'failing check reported';
};

subtest 'Healthcheck - liveness probe' => sub {
    my $health = PAGI::Middleware::Healthcheck->new(
        path => '/health',
        live_path => '/healthz',
        checks => { db => sub { die "Database down" } },
    );

    my $app = async sub { };

    my $wrapped = $health->wrap($app);
    my $scope = make_scope(path => '/healthz');

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 200, 'liveness always returns 200';
};

subtest 'Healthcheck owned responses use the native HTTP triplet' => sub {
    my $health = PAGI::Middleware::Healthcheck->new(path => '/health');
    my $wrapped = $health->wrap(async sub { die 'health request reached downstream' });
    my @events;
    my $future = $wrapped->(
        make_scope(path => '/health'),
        undef,
        async sub { my ($event) = @_; push @events, $event },
    );
    $loop->await($future);

    ok $future->is_failed, 'invalid receive callback rejects health emission';
    like [$future->failure]->[0], qr/receive.*coderef/i,
        'health response reports the native receive requirement';
    is \@events, [], 'triplet validation happens before health response start';
};

done_testing;
