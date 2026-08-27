#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';

use PAGI::App::Router;
use PAGI::Compose qw(compose);
use PAGI::Routing qw(middleware mount route router);

{
    package Local::UpgradeEndpoint;
    use parent 'PAGI::Endpoint::Router';

    sub routes {
        my ($self, $r) = @_;
        $r->http_default($self->app_as('not_found_app'));
        $r->mount('/child', routes => sub {
            my ($child) = @_;
            $child->get('/' => sub { return $_[0]->text('endpoint child') });
        })->name('child');
    }

    sub not_found_app {
        my ($self, $scope, $receive, $send) = @_;
        return main::response_app(404, 'endpoint missing')->(
            $scope, $receive, $send,
        );
    }
}

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

sub slurp_file {
    my ($file) = @_;
    open my $handle, '<', $file or die "Cannot read $file: $!";
    local $/;
    my $source = <$handle>;
    close $handle or die "Cannot close $file: $!";
    return $source;
}

subtest 'executable routing-composition migration matrix' => sub {
    my $native = response_app(200, 'native');

    ok(lives { mount('/current', app => $native) },
        'functional Mount accepts a named application');
    ok(lives { mount('/current', routes => []) },
        'functional Mount accepts a structural route list');
    ok(lives { middleware('RequestId', header => 'X-Request-ID') },
        'middleware package strings retain their explicit loading contract');

    like(dies { mount('/legacy' => $native) },
        qr/mount option list must be key\/value pairs|unknown mount option/,
        'the positional Mount before-form is executable and rejected');
    like(dies { mount('/legacy', router => router(routes => [])) },
        qr/unknown mount option 'router'/,
        'the router-option before-form is executable and rejected');
    like(dies { mount('/legacy', app => 'Local::LegacyApp') },
        qr/mount app must be a coderef or instantiated object with to_app/,
        'the package-name application before-form is executable and rejected');

    my $callback_calls = 0;
    my $mutable = PAGI::App::Router->new;
    ok(lives {
        $mutable->mount('/mutable', routes => sub {
            my ($child) = @_;
            ++$callback_calls;
            $child->get('/' => sub { return $_[0]->text('mutable child') });
            return 'ignored';
        })->name('mutable');
    }, 'mutable Mount routes callback is accepted');
    is($callback_calls, 1,
        'mutable callback runs once during declaration and receives its child');
    my ($mutable_events, $mutable_error) = run_http(
        $mutable->to_app, path => '/mutable', raw_path => '/mutable',
    );
    is($mutable_error, undef, 'mutable callback child constructs and dispatches');
    is(response_body($mutable_events), 'mutable child',
        'the exact Mount spelling normalizes to the child root');

    my $endpoint = Local::UpgradeEndpoint->new;
    ok(lives { $endpoint->to_router },
        'Endpoint routes callback and app_as default construct');
    my ($endpoint_child, $endpoint_child_error) = run_http(
        $endpoint->to_app, path => '/child/', raw_path => '/child/',
    );
    is($endpoint_child_error, undef, 'Endpoint callback child dispatches');
    is(response_body($endpoint_child), 'endpoint child',
        'Endpoint callback stays bound to the same Endpoint object');
    my ($endpoint_missing, $endpoint_missing_error) = run_http(
        $endpoint->to_app, path => '/missing', raw_path => '/missing',
    );
    is($endpoint_missing_error, undef, 'Endpoint app_as HTTP default dispatches');
    is([response_status($endpoint_missing), response_body($endpoint_missing)],
        [404, 'endpoint missing'], 'app_as supplies a native application');
};

subtest 'Mount normalization and raw versus mounted application positions' => sub {
    my @seen;
    my $capture = sub {
        my ($kind) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            push @seen, [$kind, $scope->{path}, $scope->{root_path}];
            await Future->wrap(response_app(200, $kind)->(@_));
        };
    };
    my $app = router(routes => [
        route('/exact', raw => $capture->('raw')),
        mount('/prefix', app => $capture->('mount')),
        mount('/normalized', routes => [
            route('/' => sub { return $_[0]->text('normalized') }),
        ]),
    ])->to_app;

    for my $path ('/normalized', '/normalized/') {
        my ($events, $error) = run_http(
            $app, path => $path, raw_path => $path,
        );
        is($error, undef, "$path reaches the constructed child Router");
        is(response_body($events), 'normalized',
            "$path selects the same child root leaf");
    }

    run_http($app, path => '/exact', raw_path => '/exact');
    run_http($app, path => '/prefix/tail', raw_path => '/prefix/tail');
    is(\@seen, [
        ['raw', '/exact', ''],
        ['mount', '/tail', '/prefix'],
    ], 'raw keeps an exact leaf while Mount consumes and records its prefix');
};

subtest 'public documentation publishes one final routing model' => sub {
    my $lead = qr/Route\s+matches\s+a\s+complete\s+URL\s+leaf\.\s+Mount\s+composes\s+an\s+application\s+under\s+a\s+prefix\.\s+Router\s+selects\s+and\s+owns\s+routing\s+outcomes\.\s+Middleware\s+wraps\s+behavior\.\s+Compose\s+owns\s+the\s+application\s+root\s+and\s+lifespan\./s;
    for my $file (
        'README.md',
        'lib/PAGI/Tools.pm',
        'lib/PAGI/Tools/Tutorial.pod',
        'lib/PAGI/Tools/Cookbook.pod',
        'lib/PAGI/Routing.pm',
    ) {
        like(slurp_file($file), $lead, "$file leads with the five-part model");
    }

    my @live_docs = (
        'README.md',
        'lib/PAGI/Tools.pm',
        'lib/PAGI/Tools/Tutorial.pod',
        'lib/PAGI/Tools/Cookbook.pod',
        'lib/PAGI/Routing.pm',
        'lib/PAGI/Routing/Mount.pm',
        'lib/PAGI/Routing/Router.pm',
        'lib/PAGI/Routing/Compiler.pm',
        'lib/PAGI/Compose.pm',
        'lib/PAGI/App/Router.pm',
        'lib/PAGI/Endpoint/Router.pm',
        'lib/PAGI/App/Cascade.pm',
        'lib/PAGI/App/File.pm',
        'lib/PAGI/App/URLMap.pm',
        'lib/PAGI/Middleware/ErrorHandler.pm',
        'lib/PAGI/Pages.pm',
        'lib/PAGI/Response.pm',
    );
    my $retired_live_api = qr/PAGI::Routing::Trace|pagi\.routing\.trace|PAGI::Middleware::Routing::(?:NotFound|MethodNotAllowed)|mount\('\/[^']*'\s*=>|router\s*=>|\bgroup\s*\(/;
    my %classified_non_routing_api = (
        'lib/PAGI/Tools/Tutorial.pod' => [
            qr/\$urlmap->mount\('\/(?:api|admin|static)' =>/,
        ],
        'lib/PAGI/Routing/Router.pm' => [
            qr/PAGI::Routing::Resolver->new\(router => \$self\)/,
        ],
        'lib/PAGI/Routing/Compiler.pm' => [
            qr/inspectable_router => blessed\(\$node->app\)/,
        ],
        'lib/PAGI/App/Router.pm' => [
            qr/There is no positional Mount target, C<< router => >> form, or C<group>/,
        ],
        'lib/PAGI/App/URLMap.pm' => [
            qr/\$map->mount\('\/(?:api|static)'\s*=>/,
        ],
    );
    for my $file (@live_docs) {
        my @unclassified;
        for my $line (split /\n/, slurp_file($file)) {
            next unless $line =~ $retired_live_api;
            my $allowed = 0;
            for my $pattern (@{$classified_non_routing_api{$file} || []}) {
                $allowed = 1 if $line =~ $pattern;
            }
            push @unclassified, $line unless $allowed;
        }
        is(\@unclassified, [],
            "$file has no unclassified retired routing API");
    }

    my $upgrading = slurp_file('UPGRADING.md');
    like($upgrading, qr/^## Routing composition redesign$/m,
        'upgrade guide has one complete routing-composition section');
    for my $replacement (
        'mount(\'/x\', app => $app)',
        'mount(\'/x\', routes => sub',
        'Router `http_default`',
        'Compose',
        'package-name application',
        'OpenAPI and schema support remain deferred',
    ) {
        like($upgrading, qr/\Q$replacement\E/,
            "upgrade guide covers $replacement");
    }

    my $changes = slurp_file('Changes');
    like($changes, qr/\A# Revision history for PAGI-Tools\s+0\.002003 - UNRELEASED\b/s,
        'release note stays inside unreleased 0.002003');
    like($changes, qr/Route matches a complete URL leaf/,
        'release note records the routing composition redesign');
};

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
