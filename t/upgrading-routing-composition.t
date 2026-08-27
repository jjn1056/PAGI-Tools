#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';

use PAGI::App::Router;
use PAGI::Compose qw(compose);
use PAGI::Routing qw(mount route router);

sub http_scope {
    my (%changes) = @_;
    my $path = exists $changes{path} ? $changes{path} : '/';
    return {
        type         => 'http',
        http_version => '1.1',
        method       => 'GET',
        scheme       => 'http',
        path         => $path,
        raw_path     => $path,
        root_path    => '',
        query_string => '',
        headers      => [],
        server       => ['testserver', 80],
        client       => ['127.0.0.1', 50000],
        %changes,
    };
}

sub receive_request {
    return Future->done({
        type => 'http.request',
        body => '',
        more => 0,
    });
}

sub run_http {
    my ($app, %changes) = @_;
    my (@events, @warnings);
    my $error;
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $ok = eval {
            Future->wrap($app->(
                http_scope(%changes),
                \&receive_request,
                $send,
            ))->get;
            1;
        };
        $error = $@ unless $ok;
    }
    return (\@events, $error, \@warnings);
}

sub response_start {
    my ($events) = @_;
    return (grep {
        ($_->{type} // '') eq 'http.response.start'
    } @$events)[0];
}

sub response_status {
    my ($events) = @_;
    my $start = response_start($events);
    return defined $start ? $start->{status} : undef;
}

sub response_body {
    my ($events) = @_;
    return join '', map { $_->{body} // '' }
        grep { ($_->{type} // '') eq 'http.response.body' } @$events;
}

sub response_header {
    my ($events, $name) = @_;
    my $start = response_start($events);
    return unless $start;
    for my $header (@{$start->{headers} || []}) {
        return $header->[1]
            if lc($header->[0] // '') eq lc($name);
    }
    return;
}

sub response_app {
    my ($status, $body) = @_;
    return async sub {
        my ($scope, $receive, $send) = @_;
        await Future->wrap($send->({
            type => 'http.response.start', status => $status, headers => [],
        }));
        await Future->wrap($send->({
            type => 'http.response.body', body => $body, more => 0,
        }));
    };
}

subtest 'Router http_default replaces application 404 middleware' => sub {
    my $default_calls = 0;
    my $routing = router(
        http_default => async sub {
            my ($scope, $receive, $send) = @_;
            ++$default_calls;
            await Future->wrap(response_app(404, 'custom missing')->(@_));
        },
        routes => [
            route('/items' => sub { return $_[0]->text('items') },
                methods => 'GET'),
        ],
    );

    my ($missing, $missing_error) = run_http(
        $routing->to_app, path => '/missing', raw_path => '/missing',
    );
    is($missing_error, undef, 'custom HTTP default completes');
    is([response_status($missing), response_body($missing)],
        [404, 'custom missing'], 'HTTP NONE selects the Router default');
    is($default_calls, 1, 'the custom default runs once');

    my ($method, $method_error) = run_http(
        $routing->to_app,
        method => 'POST', path => '/items', raw_path => '/items',
    );
    is($method_error, undef, 'built-in method outcome completes');
    is(response_status($method), 405,
        'HTTP PARTIAL uses the Router built-in 405');
    is(response_header($method, 'Allow'), 'GET, HEAD',
        'the built-in 405 publishes its exact method union');
    is($default_calls, 1, 'PARTIAL does not invoke the HTTP default');
};

subtest 'nested Router owns its outcomes and Mount app/routes are explicit' => sub {
    my ($child_defaults, $parent_defaults, $later_parent) = (0, 0, 0);
    my $child = router(
        http_default => async sub {
            ++$child_defaults;
            await Future->wrap(response_app(404, 'child missing')->(@_));
        },
        routes => [
            route('/item' => sub { return $_[0]->text('child item') },
                methods => 'GET'),
        ],
    );
    my $parent = router(
        http_default => async sub {
            ++$parent_defaults;
            await Future->wrap(response_app(404, 'parent missing')->(@_));
        },
        routes => [
            mount('/child', app => $child),
            mount('/inline', routes => [
                route('/item' => sub { return $_[0]->text('inline item') }),
            ]),
            route('/child/missing' => sub {
                ++$later_parent;
                return $_[0]->text('later parent');
            }),
        ],
    )->to_app;

    my ($missing, $missing_error) = run_http(
        $parent, path => '/child/missing', raw_path => '/child/missing',
    );
    is($missing_error, undef, 'nested NONE completes at the child');
    is([response_status($missing), response_body($missing)],
        [404, 'child missing'], 'selected child owns its HTTP default');

    my ($method, $method_error) = run_http(
        $parent, method => 'POST', path => '/child/item', raw_path => '/child/item',
    );
    is($method_error, undef, 'nested PARTIAL completes at the child');
    is([response_status($method), response_header($method, 'Allow')],
        [405, 'GET, HEAD'], 'selected child owns its built-in 405');

    my ($inline, $inline_error) = run_http(
        $parent, path => '/inline/item', raw_path => '/inline/item',
    );
    is($inline_error, undef, 'routes shorthand builds a complete child Router');
    is(response_body($inline), 'inline item',
        'Mount routes dispatches through the constructed child');
    is([$child_defaults, $parent_defaults, $later_parent], [1, 0, 0],
        'child outcomes never resume parent routing or parent default policy');
};

subtest 'removed declaration spellings fail instead of aliasing' => sub {
    for my $option ('not_found', 'method_not_allowed') {
        like(
            dies { router(routes => [], $option => sub { return }) },
            qr/unknown router option '\Q$option\E'/,
            "removed Router $option option is unknown",
        );
        like(
            dies { PAGI::App::Router->new($option => sub { return }) },
            qr/unknown router option '\Q$option\E'/,
            "removed App Router $option option is unknown",
        );
    }

    my $native = response_app(200, 'native');
    my $immutable = router(routes => []);
    like(dies { mount('/legacy' => $native) },
        qr/mount option list must be key\/value pairs|unknown mount option/,
        'functional positional Mount target is rejected');
    like(dies { mount('/legacy', router => $immutable) },
        qr/unknown mount option 'router'/,
        'functional router target option is rejected');
    like(dies { PAGI::App::Router->new->mount('/legacy' => $native) },
        qr/mount option list must be key\/value pairs|unknown mount option/,
        'mutable positional Mount target is rejected');
    like(dies {
        PAGI::App::Router->new->mount('/legacy', router => $immutable);
    }, qr/unknown mount option 'router'/,
        'mutable router target option is rejected');

    ok(!PAGI::App::Router->can('group'), 'App Router has no group method');
    ok(!PAGI::Endpoint::Router->can('group'),
        'Endpoint Router facade has no group method');
    my $mount = mount('/current', app => $native);
    ok(!$mount->can('router'), 'Mount has no router accessor');
    ok(!$mount->can('target'), 'Mount has no target accessor');
    ok(!$mount->can('is_raw'), 'Mount has no mode accessor');
};

subtest 'native application positions reject package strings' => sub {
    like(dies { mount('/legacy', app => 'Local::LegacyApp') },
        qr/mount app must be a coderef or instantiated object with to_app/,
        'functional Mount app rejects a package string');
    like(dies { router(routes => [], http_default => 'Local::LegacyApp') },
        qr/router http_default must be a coderef or instantiated object with to_app/,
        'Router HTTP default rejects a package string');
    like(dies {
        PAGI::App::Router->new->mount('/legacy', app => 'Local::LegacyApp');
    }, qr/mount app must be a coderef or instantiated object with to_app/,
        'mutable Mount app rejects a package string');
    like(dies {
        PAGI::App::Router->new->get('/raw' => raw => 'Local::LegacyApp');
    }, qr/raw application must be a coderef or instantiated object with to_app/,
        'raw application rejects a package string');
    ok(!$INC{'Local/LegacyApp.pm'}, 'rejection never loads the package');
};

subtest 'direct Router remains low-level and Compose supplies safety' => sub {
    my $routing = router(routes => [
        route('/silent' => raw => sub { return Future->done }),
    ]);

    my ($direct, $direct_error, $direct_warnings) = run_http(
        $routing->to_app, path => '/silent', raw_path => '/silent',
    );
    is($direct_error, undef, 'direct Router permits selected application silence');
    is([$direct, $direct_warnings], [[], []],
        'direct Router emits neither safety events nor warnings');

    local $ENV{PAGI_ENV} = 'production';
    my ($safe, $safe_error, $safe_warnings) = run_http(
        compose(app => $routing)->to_app,
        path => '/silent', raw_path => '/silent',
    );
    is($safe_error, undef, 'Compose contains the before-start failure');
    is(response_status($safe), 500, 'Compose emits its production-safe 500');
    is(scalar @$safe_warnings, 1, 'Compose reports the lifecycle failure once');
};

subtest 'retired routing support modules are not loadable' => sub {
    my @removed = (
        join('::', qw(PAGI Routing Trace)),
        join('::', qw(PAGI Routing Trace Recorder)),
        join('::', qw(PAGI Routing Trace Snapshot)),
        join('::', qw(PAGI Middleware Routing), '_' . 'Fallback'),
        join('::', qw(PAGI Middleware Routing), 'Not' . 'Found'),
        join('::', qw(PAGI Middleware Routing), 'Method' . 'NotAllowed'),
    );
    for my $module (@removed) {
        my $file = $module;
        $file =~ s{::}{/}g;
        $file .= '.pm';
        my $loaded = eval { require $file; 1 };
        ok(!$loaded, "$module was removed instead of deprecated");
    }
};

subtest 'Router Compose and Context have no retired evidence channel' => sub {
    my @files = (
        'lib/PAGI/Routing/Router.pm',
        'lib/PAGI/App/Router.pm',
        'lib/PAGI/App/Router/Builder.pm',
        'lib/PAGI/App/Router/Materializer.pm',
        'lib/PAGI/Compose.pm',
        'lib/PAGI/Compose/Compiler.pm',
        'lib/PAGI/Compose/ResponseGuard.pm',
        'lib/PAGI/Context.pm',
        'lib/PAGI/Context/HTTP.pm',
        'lib/PAGI/Context/SSE.pm',
        'lib/PAGI/Context/WebSocket.pm',
    );
    my @retired = (
        join('::', qw(PAGI Routing Trace)),
        join('.', qw(pagi routing trace)),
        join('::', qw(PAGI Middleware Routing), 'Not' . 'Found'),
        join('::', qw(PAGI Middleware Routing), 'Method' . 'NotAllowed'),
        'check' . 'point',
        'attempt' . 's',
        join('_', qw(routing declined)),
        join('_', qw(allowed methods)),
    );
    for my $file (@files) {
        open my $handle, '<', $file or die "Cannot read $file: $!";
        local $/;
        my $source = <$handle>;
        close $handle or die "Cannot close $file: $!";
        for my $retired (@retired) {
            unlike($source, qr/\Q$retired\E/,
                "$file does not consume retired routing evidence '$retired'");
        }
    }
};

done_testing;
