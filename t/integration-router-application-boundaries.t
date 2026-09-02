use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/lib";
use Future;
use Future::AsyncAwait;
use PAGI::Response ();
use PAGI::Response::Text ();
use PAGI::Compose qw(compose);
use PAGI::Routing qw(router route mount middleware);
use PAGI::Routing::URL qw(path_for);
use PAGI::Utils qw(request_response);
use TestRoutes::Admin ();
use TestRoutes::Users ();

sub run_http {
    my ($app, $path, %changes) = @_;
    my @events;
    my $scope = {
        type         => 'http',
        http_version => '1.1',
        method       => 'GET',
        scheme       => 'http',
        path         => $path,
        raw_path     => $path,
        root_path    => '',
        path_params  => {},
        query_string => '',
        headers      => [],
        server       => ['testserver', 80],
        client       => ['127.0.0.1', 50000],
        %changes,
    };
    my $receive = sub {
        return Future->done({
            type => 'http.request', body => '', more => 0,
        });
    };
    my $send = sub {
        my ($event) = @_;
        push @events, $event;
        return Future->done;
    };

    Future->wrap($app->($scope, $receive, $send))->get;
    return \@events;
}

sub response_body {
    my ($events) = @_;
    return join '', map { $_->{body} // '' }
        grep { ($_->{type} // '') eq 'http.response.body' } @$events;
}

sub response_header {
    my ($events, $name) = @_;
    my ($start) = grep { ($_->{type} // '') eq 'http.response.start' } @$events;
    return unless $start;
    for my $pair (@{$start->{headers} // []}) {
        return $pair->[1] if lc($pair->[0]) eq lc($name);
    }
    return;
}

sub source_text {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot open $path: $!\n";
    local $/;
    my $source = <$fh>;
    close $fh or die "cannot close $path: $!\n";
    return $source;
}

{
    package Local::MountedIntegrationApp;

    sub new { return bless { compilations => 0 }, $_[0] }
    sub compilations { $_[0]{compilations} }
    sub to_app {
        my ($self) = @_;
        ++$self->{compilations};
        return async sub {
            my ($scope, $receive, $send) = @_;
            await $send->({
                type => 'http.response.start', status => 200,
                headers => [['x-child-path', $scope->{path}]],
            });
            await $send->({
                type => 'http.response.body', body => 'mounted integration', more => 0,
            });
        };
    }
}

local $ENV{PAGI_ENV} = 'production';

subtest 'background-task example limits native dispatch to response-first routes' => sub {
    my $file = "$Bin/../examples/background-tasks/app.pl";
    my $source = source_text($file);
    like($source,
        qr{compose\(routes\s*=>\s*\[.*?route\('/'\s*=>\s*sub\s*\{}s,
        'background-task root uses an ordinary Request handler in Compose');
    my $native_routes = () = $source =~ /\bas_app\s*\(/g;
    is($native_routes, 3,
        'only routes that perform work after response emission use as_app');
    like($source,
        qr{mount\('/ws'\s*,\s*app\s*=>\s*async sub}s,
        'background-task WebSocket remains a direct native Mount application');
    unlike($source, qr/PAGI::App::Router|\$router->(?:get|post|websocket|sse|mount)\b|->to_router/,
        'background-task example has no mutable frontend or snapshot conversion');
    my $app = do $file;
    my $load_error = $@;
    ok(!$load_error, 'background-task example loads cleanly')
        or diag($load_error);
    isa_ok($app, 'PAGI::Compose');
    my $events = run_http($app->to_app, '/');
    like(response_body($events), qr/Background Tasks Demo/,
        'the root Router dispatches the ordinary index handler through Compose');
};

subtest 'shared route fixtures execute declarative Router graphs' => sub {
    my $admin = TestRoutes::Admin->to_app;
    is(response_body(run_http($admin, '/')), 'admin_dashboard',
        'the direct application fixture dispatches its root route');
    is(response_body(run_http($admin, '/settings')), 'admin_settings',
        'the direct application fixture dispatches its sibling route');

    my $users = TestRoutes::Users->router;
    is([sort keys %{$users->named_routes}], ['/list', '/show'],
        'the Router fixture publishes its declarative names');
    is(response_body(run_http($users->to_app, '/42')), 'user_detail',
        'the Router fixture dispatches through the immutable compiler');
};

subtest 'a directly mounted application object compiles once per parent graph' => sub {
    my $component = Local::MountedIntegrationApp->new;
    my $middleware_builds = 0;
    my $mount_middleware = middleware(sub {
        my ($inner) = @_;
        ++$middleware_builds;
        return $inner;
    });
    my $app = router(routes => [
        mount('/service', app => $component,
            middleware => [$mount_middleware]),
        route('/service/item' => sub {
            return PAGI::Response::Text->new('parent resumed');
        }),
    ])->to_app;

    is([$component->compilations, $middleware_builds], [1, 1],
        'the object and Mount middleware compile once at the parent boundary');
    my $events = run_http($app, '/service/item');
    is(response_body($events), 'mounted integration',
        'the selected child application owns completion');
    is($events->[0]{headers}, [['x-child-path', '/item']],
        'the child receives the rewritten remainder');
    run_http($app, '/service/again');
    is([$component->compilations, $middleware_builds], [1, 1],
        'requests do not recompile the child or Mount middleware');
};

subtest 'a configured immutable child Router retains its Mount boundary contract' => sub {
    my (@trace, @full_metadata, @default_metadata);
    my ($default_calls, $parent_calls) = (0, 0);
    my $tracing = sub {
        my ($label) = @_;
        return middleware(sub {
            my ($inner) = @_;
            return async sub {
                push @trace, "$label before";
                await Future->wrap($inner->(@_));
                push @trace, "$label after";
            };
        });
    };
    my $snapshot_metadata = sub {
        my ($scope) = @_;
        my $frames = $scope->{'pagi.routing'}{frames};
        my $frame = $frames->[-1];
        return {
            frame_count => scalar @$frames,
            logical_namespace => $frame->{logical_namespace},
            captures => { %{$frame->{captures}} },
            mounts => [map { +{%$_} } @{$frame->{mounts}}],
            match => defined $frame->{match} ? { %{$frame->{match}} } : undef,
        };
    };

    my $child = router(
        desc => 'Configured child',
        middleware => [$tracing->('child Router')],
        http_default => async sub {
            my ($scope, $receive, $send) = @_;
            ++$default_calls;
            push @trace, 'child default';
            push @default_metadata, $snapshot_metadata->($scope);
            await Future->wrap($send->({
                type => 'http.response.start', status => 404,
                headers => [['x-origin', 'configured child']],
            }));
            await Future->wrap($send->({
                type => 'http.response.body', body => 'child missing', more => 0,
            }));
        },
        routes => [
            route('/items/{id:\d+}' => sub {
                my ($request) = @_;
                push @trace, 'handler';
                push @full_metadata, $snapshot_metadata->($request->scope);
                return PAGI::Response::Text->new(path_for($request, 'show'));
            }, methods => 'GET', name => 'show', desc => 'Show item'),
        ],
    );
    my $parent = router(routes => [
        mount('/api/{tenant}', app => $child,
            name => 'api', desc => 'API boundary',
            constraints => { tenant => qr/\A[a-z]+\z/ },
            middleware => [$tracing->('Mount')]),
        route('/api/{tenant}/items/{id}' => sub {
            ++$parent_calls;
            return PAGI::Response::Text->new('parent POST');
        }, methods => 'POST'),
        route('/api/{tenant}/missing' => sub {
            ++$parent_calls;
            return PAGI::Response::Text->new('parent fallback');
        }),
    ]);

    is($parent->path_for('/api/show', { tenant => 'acme', id => 7 }),
        '/api/acme/items/7',
        'the parent Resolver discovers the configured child through its named Mount');
    is($child->path_for('/show', { id => 8 }), '/items/8',
        'Mount placement does not change child-local reverse discovery');

    my $app = $parent->to_app;
    my $full = run_http($app, '/api/acme/items/7');
    is(response_body($full), '/api/acme/items/7',
        'request-relative discovery uses the active Mount placement');
    is(\@trace, [
        'Mount before', 'child Router before', 'handler',
        'child Router after', 'Mount after',
    ], 'Mount and child Router middleware retain their declared onion order');
    is($full_metadata[0], {
        frame_count => 2,
        logical_namespace => '/api',
        captures => { tenant => 'acme', id => 7 },
        mounts => [{
            path => '/api/{tenant}', name => 'api', desc => 'API boundary',
        }],
        match => {
            kind => 'route', route => '/api/{tenant}/items/{id:\d+}',
            name => '/api/show', logical_namespace => '/api',
            desc => 'Show item',
        },
    }, 'the configured child publishes effective Mount and leaf metadata');

    @trace = ();
    my $partial = run_http(
        $app, '/api/acme/items/7', method => 'POST',
    );
    is([$partial->[0]{status}, response_header($partial, 'Allow')],
        [405, 'GET, HEAD'],
        'the configured child owns PARTIAL and its local Allow set');
    is(\@trace, [
        'Mount before', 'child Router before',
        'child Router after', 'Mount after',
    ], 'child PARTIAL remains inside both configured middleware boundaries');

    @trace = ();
    my $none = run_http($app, '/api/acme/missing');
    is([$none->[0]{status}, response_header($none, 'X-Origin'), response_body($none)],
        [404, 'configured child', 'child missing'],
        'the configured child http_default owns NONE');
    is(\@trace, [
        'Mount before', 'child Router before', 'child default',
        'child Router after', 'Mount after',
    ], 'the child http_default remains inside both middleware boundaries');
    is($default_metadata[0], {
        frame_count => 2,
        logical_namespace => '/api',
        captures => { tenant => 'acme' },
        mounts => [{
            path => '/api/{tenant}', name => 'api', desc => 'API boundary',
        }],
        match => undef,
    }, 'child NONE retains the selected Mount metadata without a leaf match');
    is([$default_calls, $parent_calls], [1, 0],
        'FULL, PARTIAL, and NONE never resume parent sibling scanning');
};

subtest 'request_response is the explicit bridge at application-native positions' => sub {
    my $handler = sub { return PAGI::Response::Text->new('bridged') };
    my @cases = (
        ['Router http_default', router(routes => [], http_default => request_response($handler))->to_app],
        ['Mount app', router(routes => [mount('/bridge', app => request_response($handler))])->to_app, '/bridge'],
        ['Direct native app', request_response($handler)->to_app],
    );
    for my $case (@cases) {
        my ($label, $app, $path) = @$case;
        is(response_body(run_http($app, $path // '/')), 'bridged',
            "$label accepts the explicit Request handler adapter");
    }
};

done_testing;
