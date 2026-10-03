#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use IO::Async::Loop;
use JSON::MaybeXS ();

use PAGI::Middleware::Debug;
use PAGI::Middleware::Lint;
use PAGI::Middleware::Maintenance;
use PAGI::Response::HTML ();
use PAGI::Utils ();
use PAGI::Response::Text ();
use PAGI::Middleware::Healthcheck;
use PAGI::Middleware::MethodOverride;

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
    };
}

sub run_async (&) {
    my ($code) = @_;
    $loop->await($code->());
}

sub assert_maintenance_settlement {
    my ($maintenance, $label) = @_;
    my ($start_gate, $body_gate) = (Future->new, Future->new);
    my @events;
    my $wrapped = $maintenance->wrap(async sub {
        die "$label rejection reached downstream";
    });
    my $running = $wrapped->(
        make_scope(headers => [['Accept', 'text/plain']]),
        sub { Future->done({ type => 'http.disconnect' }) },
        sub {
            push @events, $_[0];
            return @events == 1 ? $start_gate : $body_gate;
        },
    );

    is scalar(@events), 1, "$label emits only response start before settlement";
    ok !$running->is_ready, "$label waits for response-start settlement";
    $start_gate->done;
    is scalar(@events), 2, "$label emits one body after response-start settlement";
    ok !$running->is_ready, "$label waits for terminal-body settlement";
    $body_gate->done;
    is dies { $loop->await($running) }, undef,
        "$label completes after the terminal send settles";
    ok !$start_gate->is_cancelled && !$body_gate->is_cancelled,
        "$label does not cancel server-owned send Futures";
}

# ===================
# Debug Middleware Tests
# ===================

subtest 'Debug middleware - injects panel into HTML when enabled' => sub {
    my $debug = PAGI::Middleware::Debug->new(enabled => 1);

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/html']],
        });
        await $send->({
            type => 'http.response.body',
            body => '<html><body>Hello</body></html>',
            more => 0,
        });
    };

    my $wrapped = $debug->wrap($app);
    my $scope = make_scope();

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is scalar(@events), 2, 'two events sent';
    like $events[1]{body}, qr/pagi-debug-panel/, 'panel injected';
    like $events[1]{body}, qr/PAGI Debug Panel/, 'panel title present';
};

subtest 'Debug middleware - does not inject when disabled' => sub {
    my $debug = PAGI::Middleware::Debug->new(enabled => 0);

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/html']],
        });
        await $send->({
            type => 'http.response.body',
            body => '<html><body>Hello</body></html>',
            more => 0,
        });
    };

    my $wrapped = $debug->wrap($app);
    my $scope = make_scope();

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    unlike $events[1]{body}, qr/pagi-debug-panel/, 'no panel when disabled';
};

subtest 'Debug middleware - skips non-HTML responses' => sub {
    my $debug = PAGI::Middleware::Debug->new(enabled => 1);

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'application/json']],
        });
        await $send->({
            type => 'http.response.body',
            body => '{"status":"ok"}',
            more => 0,
        });
    };

    my $wrapped = $debug->wrap($app);
    my $scope = make_scope();

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[1]{body}, '{"status":"ok"}', 'JSON unchanged';
};

# ===================
# Lint Middleware Tests
# ===================

subtest 'Lint middleware - warns on missing response' => sub {
    my @warnings;
    my $lint = PAGI::Middleware::Lint->new(
        on_warning => sub { push @warnings, shift },
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        # App completes without sending response
    };

    my $wrapped = $lint->wrap($app);
    my $scope = make_scope();

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    ok grep(/http.response.start/, @warnings), 'warned about missing response.start';
};

subtest 'Lint middleware - warns on response body before start' => sub {
    my @warnings;
    my $lint = PAGI::Middleware::Lint->new(
        on_warning => sub { push @warnings, shift },
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        # Send body without start
        await $send->({ type => 'http.response.body', body => 'test', more => 0 });
    };

    my $wrapped = $lint->wrap($app);
    my $scope = make_scope();

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    ok grep(/before http.response.start/, @warnings), 'warned about body before start';
};

subtest 'Lint middleware - strict mode throws' => sub {
    my @warnings;
    my $lint = PAGI::Middleware::Lint->new(
        strict => 1,
        on_warning => sub { push @warnings, shift },  # Won't be called in strict mode
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        # Send body without start - this will trigger lint warning
        await $send->({ type => 'http.response.body', body => 'test', more => 0 });
    };

    my $wrapped = $lint->wrap($app);
    my $scope = make_scope();

    my $died = 0;
    my $err_msg = '';
    eval {
        $loop->await(
            $wrapped->($scope, async sub { {} }, async sub { })->else(sub {
                my ($failure) = @_;
                $err_msg = $failure;
                $died = 1;
                return Future->done;
            })
        );
    };
    if ($@) {
        $err_msg = $@;
        $died = 1;
    }

    ok $died || $err_msg =~ /Lint/, 'strict mode throws or catches error';
};

subtest 'Lint middleware - preserves original error with lint context' => sub {
    my $lint = PAGI::Middleware::Lint->new(strict => 1);

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        die "Original app error: something broke\n";
    };

    my $wrapped = $lint->wrap($app);
    my $scope = make_scope();

    my $err_msg = '';
    eval {
        $loop->await(
            $wrapped->($scope, async sub { {} }, async sub { })->else(sub {
                my ($failure) = @_;
                $err_msg = $failure;
                return Future->done;
            })
        );
    };
    $err_msg = $@ if $@ && !$err_msg;

    like $err_msg, qr/Original app error: something broke/,
        'original error message preserved';
    like $err_msg, qr/Lint note:.*http\.response\.start/,
        'lint context included';
};

subtest 'Lint middleware - accepts valid response' => sub {
    my @warnings;
    my $lint = PAGI::Middleware::Lint->new(
        on_warning => sub { push @warnings, shift },
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $lint->wrap($app);
    my $scope = make_scope();

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    is scalar(@warnings), 0, 'no warnings for valid response';
};

# ===================
# Maintenance Middleware Tests
# ===================

sub maintenance_events {
    my ($maintenance) = @_;
    my $wrapped = $maintenance->wrap(async sub { die 'downstream must not run' });
    my @events;
    run_async { $wrapped->(make_scope(headers => [['Accept', 'application/json']]),
        async sub { {} }, async sub { my ($event) = @_; push @events, $event }) };
    my @retry_after = map { $_->[1] } grep { lc($_->[0]) eq 'retry-after' } @{ $events[0]{headers} };
    my ($content_type) = map { $_->[1] } grep { lc($_->[0]) eq 'content-type' } @{ $events[0]{headers} };
    return ($events[0]{status}, $content_type, \@retry_after, $events[1]{body});
}

subtest 'Maintenance middleware - serves a plain 503 when enabled' => sub {
    my ($status, $type, $retry, $body) = maintenance_events(
        PAGI::Middleware::Maintenance->new(enabled => 1, retry_after => 120));
    is [$status, $type, $retry, $body],
        [503, 'text/plain; charset=utf-8', [120], 'Service Unavailable'],
        'plain text whatever the Accept, with one Retry-After';
};

subtest 'Maintenance middleware - response replaces the default' => sub {
    my $page = PAGI::Response::HTML->new('<h1>Back soon</h1>', status => 503,
        headers => ['Retry-After' => 5]);
    my ($status, $type, $retry, $body) = maintenance_events(
        PAGI::Middleware::Maintenance->new(enabled => 1, retry_after => 60, response => $page));
    is [$status, $type, $body], [503, 'text/html; charset=utf-8', '<h1>Back soon</h1>'],
        'the given response answers';
    is $retry, [60], 'retry_after replaces any Retry-After the response carries';

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 503, headers => [] });
        await $send->({ type => 'http.response.body', body => 'from an app', more => 0 });
    };
    ($status, undef, $retry, $body) = maintenance_events(
        PAGI::Middleware::Maintenance->new(enabled => 1,
            response => PAGI::Utils::as_app_object($app)));
    is [$status, $retry, $body], [503, [], 'from an app'],
        'an application answers too; no retry_after, no Retry-After';
};

subtest 'Maintenance middleware - body, content_type and bad responses die' => sub {
    for my $option (qw(body content_type)) {
        like dies { PAGI::Middleware::Maintenance->new(enabled => 1, $option => 'x') },
            qr/\QMaintenance '$option' is replaced by 'response'\E/, "$option names its replacement";
    }
    for my $value (undef, '', 0, 'yes') {
        my $label = defined $value ? "'$value'" : 'undef';
        like dies { PAGI::Middleware::Maintenance->new(enabled => 1, response => $value) },
            qr/\QMaintenance 'response' must be an application\E/, "response $label";
    }
};

subtest 'maintenance-owned rejections await concrete response emission' => sub {
    assert_maintenance_settlement(
        PAGI::Middleware::Maintenance->new(enabled => 1),
        'default plain 503',
    );
    assert_maintenance_settlement(
        PAGI::Middleware::Maintenance->new(
            enabled  => 1,
            response => PAGI::Response::Text->new('literal maintenance', status => 503),
        ),
        'a given 503',
    );
};

subtest 'Maintenance middleware - passes through when disabled' => sub {
    my $maintenance = PAGI::Middleware::Maintenance->new(enabled => 0);

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $maintenance->wrap($app);
    my $scope = make_scope();

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 200, 'passes through when disabled';
};

subtest 'Maintenance middleware - bypasses for allowed IPs' => sub {
    my $maintenance = PAGI::Middleware::Maintenance->new(
        enabled    => 1,
        bypass_ips => ['192.168.1.100'],
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $maintenance->wrap($app);
    my $scope = make_scope(client => ['192.168.1.100', 12345]);

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 200, 'bypasses for allowed IP';
};

subtest 'Maintenance middleware - bypasses for allowed paths' => sub {
    my $maintenance = PAGI::Middleware::Maintenance->new(
        enabled      => 1,
        bypass_paths => ['/health'],
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $maintenance->wrap($app);
    my $scope = make_scope(path => '/health');

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 200, 'bypasses for health path';
};

subtest 'Healthcheck middleware - unhealthy response remains protocol JSON' => sub {
    my $health = PAGI::Middleware::Healthcheck->new(
        path   => '/health',
        checks => { database => sub { 0 } },
    );
    my $wrapped = $health->wrap(async sub { die 'downstream must not run' });
    my $scope = make_scope(
        path    => '/health',
        headers => [['Accept', 'text/html']],
    );

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub {
        my ($event) = @_; push @events, $event }) };

    is $events[0]{status}, 503, 'unhealthy check remains 503';
    my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
    is $headers{'content-type'}, 'application/json',
        'health-check media type ignores Pages negotiation';
    my $document = JSON::MaybeXS::decode_json($events[1]{body});
    is $document->{status}, 'error', 'protocol status remains in the JSON body';
    is $document->{checks}{database}{status}, 'error',
        'protocol check details remain in the JSON body';
};

# ===================
# MethodOverride Middleware Tests
# ===================

subtest 'MethodOverride - overrides from header' => sub {
    my $override = PAGI::Middleware::MethodOverride->new();

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $override->wrap($app);
    my $scope = make_scope(
        method  => 'POST',
        headers => [['x-http-method-override', 'DELETE']],
    );

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    is $captured_scope->{method}, 'DELETE', 'method overridden';
    is $captured_scope->{'pagi.original_method'}, 'POST', 'original method preserved';
};

subtest 'MethodOverride - overrides from query param' => sub {
    my $override = PAGI::Middleware::MethodOverride->new();

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $override->wrap($app);
    my $scope = make_scope(
        method       => 'POST',
        query_string => '_method=PUT',
    );

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    is $captured_scope->{method}, 'PUT', 'method overridden from query';
};

subtest 'MethodOverride - ignores non-POST requests' => sub {
    my $override = PAGI::Middleware::MethodOverride->new();

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $override->wrap($app);
    my $scope = make_scope(
        method  => 'GET',
        headers => [['x-http-method-override', 'DELETE']],
    );

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    is $captured_scope->{method}, 'GET', 'GET not overridden';
};

subtest 'MethodOverride - rejects disallowed methods' => sub {
    my $override = PAGI::Middleware::MethodOverride->new(
        allowed_methods => [qw(DELETE)],
    );

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $override->wrap($app);
    my $scope = make_scope(
        method  => 'POST',
        headers => [['x-http-method-override', 'PUT']],
    );

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    is $captured_scope->{method}, 'POST', 'PUT not allowed, stays POST';
};

done_testing;
