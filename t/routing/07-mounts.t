#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);

use PAGI::Routing qw(router route mount middleware);

sub scope {
    my (%changes) = @_;
    return {
        type       => 'http',
        method     => 'GET',
        path       => '/',
        root_path  => '',
        raw_path   => '/',
        path_params => {},
        headers    => [],
        %changes,
    };
}

sub receive {
    return Future->done({
        type => 'http.request',
        body => '',
        more => 0,
    });
}

sub run_app {
    my ($app, %scope_changes) = @_;
    return run_scope($app, scope(%scope_changes));
}

sub run_scope {
    my ($app, $request_scope) = @_;
    my @events;
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };

    $app->($request_scope, \&receive, $send)->get;
    return \@events;
}

sub response_app {
    my ($body, %opts) = @_;
    my $status = $opts{status} || 200;
    my $headers = $opts{headers} || [];

    return async sub {
        my ($request_scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => $status,
            headers => $headers,
        });
        await $send->({
            type => 'http.response.body',
            body => $body,
            more => 0,
        });
    };
}

sub response_start {
    my ($events) = @_;
    return (grep { ($_->{type} // '') eq 'http.response.start' } @$events)[0];
}

sub response_header {
    my ($events, $name) = @_;
    my $start = response_start($events);
    return unless $start;
    for my $pair (@{$start->{headers} // []}) {
        return $pair->[1] if lc($pair->[0]) eq lc($name);
    }
    return;
}

sub response_body {
    my ($events) = @_;
    return join '', map { $_->{body} // '' }
        grep { ($_->{type} // '') eq 'http.response.body' } @$events;
}

sub tracing_middleware {
    my ($label, $trace) = @_;
    return middleware(sub {
        my ($inner) = @_;
        return async sub {
            push @$trace, "$label before";
            my $returned = $inner->(@_);
            await Future->wrap($returned);
            push @$trace, "$label after";
        };
    });
}

subtest 'application mounts rewrite static and exact-prefix scopes' => sub {
    my @seen;
    my @middleware_seen;
    my $mounted = async sub {
        my ($request_scope, $receive, $send) = @_;
        push @seen, $request_scope;
        await response_app('mounted')->(@_);
    };
    my $scope_middleware = middleware(sub {
        my ($inner) = @_;
        return sub {
            push @middleware_seen, $_[0];
            return $inner->(@_);
        };
    });
    my $app = router(routes => [
        mount('/api' => $mounted, middleware => [$scope_middleware]),
    ])->to_app;

    my $parent_scope = scope(
        path        => '/api/users',
        root_path   => '/outer',
        raw_path    => '/outer/api/users%20raw',
        path_params => { retained => 'yes' },
    );
    run_scope($app, $parent_scope);
    run_app(
        $app,
        path      => '/api',
        root_path => '',
        raw_path  => '/api',
    );

    is(
        { map { $_ => $seen[0]{$_} } qw(path root_path raw_path path_params) },
        {
            path        => '/users',
            root_path   => '/outer/api',
            raw_path    => '/outer/api/users%20raw',
            path_params => { retained => 'yes' },
        },
        'a static mount strips only its decoded prefix and retains original raw bytes and parameters',
    );
    is($seen[1]{path}, '/', 'an exact non-root mount prefix produces slash rather than an empty path');
    is($seen[1]{root_path}, '/api', 'an exact mount extends an empty root path');
    is($seen[1]{raw_path}, '/api', 'an exact mount retains raw_path');
    isnt(refaddr($seen[0]), refaddr($parent_scope), 'the mounted application receives a shallow child scope');
    isnt(refaddr($seen[0]{path_params}), refaddr($parent_scope->{path_params}),
        'the mounted application receives request-local path parameters');
    is(
        [@{$parent_scope}{qw(path root_path raw_path)}],
        ['/api/users', '/outer', '/outer/api/users%20raw'],
        'scope rewriting leaves the parent scope unchanged',
    );
    is($parent_scope->{path_params}, { retained => 'yes' },
        'path-parameter merging leaves the parent hash unchanged');
    is(
        [@{$middleware_seen[0]}{qw(path root_path raw_path)}],
        ['/users', '/outer/api', '/outer/api/users%20raw'],
        'mount middleware receives the rewritten child scope before the mounted application',
    );
};

subtest 'trailing declarations, dynamic prefixes, and nested mounts use actual captures' => sub {
    my @trailing;
    my $trailing_app = router(routes => [
        mount('/api/' => async sub {
            push @trailing, $_[0];
            await response_app('trailing')->(@_);
        }),
    ])->to_app;
    run_app($trailing_app, path => '/api/items', raw_path => '/api/items');
    is($trailing[0]{path}, '/items', 'a trailing slash declaration has the same mount boundary');
    is($trailing[0]{root_path}, '/api', 'the normalized boundary does not duplicate a slash');

    my @seen;
    my $app = router(routes => [
        mount('/tenants/{tenant}',
            routes => [
                mount('/api/{version}', routes => [
                    route('/users/{id}', raw => async sub {
                        push @seen, $_[0];
                        await response_app('nested')->(@_);
                    }),
                ]),
            ],
            constraints => { tenant => qr/[a-z]+/ },
        ),
    ])->to_app;

    run_app(
        $app,
        path        => '/tenants/acme/api/v2/users/42',
        root_path   => '/edge',
        raw_path    => '/edge/tenants/acme/api/v2/users%2F42',
        path_params => { retained => 'yes', tenant => 'stale', id => 'stale' },
    );

    is(
        { map { $_ => $seen[0]{$_} } qw(path root_path raw_path path_params) },
        {
            path      => '/users/42',
            root_path => '/edge/tenants/acme/api/v2',
            raw_path  => '/edge/tenants/acme/api/v2/users%2F42',
            path_params => {
                retained => 'yes',
                tenant   => 'acme',
                version  => 'v2',
                id       => '42',
            },
        },
        'nested mounts append actual decoded prefixes while mount and leaf captures override unknown incoming collisions',
    );
};

subtest 'a root mount consumes nothing and leaves path arithmetic unchanged' => sub {
    my @seen;
    my $app = router(routes => [
        mount('/' => async sub {
            push @seen, $_[0];
            await response_app('root')->(@_);
        }),
    ])->to_app;

    run_app(
        $app,
        path      => '/users/42',
        root_path => '',
        raw_path  => '/users%2F42',
    );
    run_app(
        $app,
        path      => '/users/42',
        root_path => '/outer',
        raw_path  => '/outer/users%2F42',
    );

    is(
        [map { [@{$_}{qw(path root_path raw_path)}] } @seen],
        [
            ['/users/42', '', '/users%2F42'],
            ['/users/42', '/outer', '/outer/users%2F42'],
        ],
        'root mounts preserve empty and nonempty root paths along with decoded and raw paths',
    );
};

subtest 'mount ownership follows declaration order without inspecting child outcomes' => sub {
    my $earlier = router(routes => [
        mount('/api' => response_app('earlier mount')),
        route('/api/exact' => sub { return $_[0]->text('later route') }),
    ])->to_app;
    is(
        response_body(run_app($earlier, path => '/api/exact', raw_path => '/api/exact')),
        'earlier mount',
        'an earlier mount preempts a later exact route',
    );

    my $broad = router(routes => [
        mount('/api' => response_app('broad mount')),
        mount('/api/admin' => response_app('narrow mount')),
    ])->to_app;
    is(
        response_body(run_app($broad, path => '/api/admin/users', raw_path => '/api/admin/users')),
        'broad mount',
        'an earlier broad mount preempts a later narrow mount',
    );

    my $constraint_fallback = router(routes => [
        mount('/api/{tenant}' => response_app('must not run'),
            constraints => { tenant => sub { return 0 } }),
        route('/api/acme' => sub { return $_[0]->text('later match') }),
    ])->to_app;
    is(
        response_body(run_app($constraint_fallback, path => '/api/acme', raw_path => '/api/acme')),
        'later match',
        'a failed mount constraint lets scanning continue',
    );

    my $child_missing = router(routes => [
        mount('/api', routes => []),
        route('/api/missing' => sub { return $_[0]->text('parent resumed') }),
    ])->to_app;
    my $missing = run_app($child_missing, path => '/api/missing', raw_path => '/api/missing');
    is(response_start($missing)->{status}, 404, 'an inline child 404 remains final');
    is(response_body($missing), 'Not Found', 'the parent does not resume after the inline child 404');

    my $opaque_405 = router(routes => [
        route('/api/item' => sub { return $_[0]->text('parent GET') }, methods => 'GET'),
        mount('/api' => response_app(
            'child method',
            status => 405,
            headers => [['Allow' => 'PATCH']],
        )),
    ])->to_app;
    my $method = run_app(
        $opaque_405,
        method => 'PUT',
        path => '/api/item',
        raw_path => '/api/item',
    );
    is(response_start($method)->{status}, 405, 'an opaque child controls its 405 status');
    is(response_header($method, 'Allow'), 'PATCH', 'the parent partial GET is not merged into the opaque child Allow');
};

subtest 'inline mounts reset Allow and inherit HTTP fallback handlers' => sub {
    my @fallback_calls;
    my $app = router(
        routes => [
            route('/api/item' => sub { return $_[0]->text('parent POST') }, methods => 'POST'),
            mount('/api', routes => [
                route('/item' => sub { return $_[0]->text('child GET') }, methods => 'GET'),
            ]),
        ],
        not_found => sub {
            push @fallback_calls, ['not_found', $_[0]->request->path];
            return $_[0]->response->header('X-Fallback' => 'inherited')->text('child missing');
        },
        method_not_allowed => sub {
            push @fallback_calls, ['method_not_allowed', $_[0]->response->header('Allow')];
            return $_[0]->response->header('X-Fallback' => 'inherited')->text('child method');
        },
    )->to_app;

    my $method = run_app(
        $app,
        method => 'PUT',
        path => '/api/item',
        raw_path => '/api/item',
    );
    is(response_start($method)->{status}, 405, 'the inherited method fallback keeps the generated child status');
    is(response_header($method, 'Allow'), 'GET, HEAD', 'the child uses a fresh local Allow set without parent POST');
    is(response_header($method, 'X-Fallback'), 'inherited', 'the inherited method fallback rendered the child outcome');

    my $missing = run_app(
        $app,
        path => '/api/missing',
        raw_path => '/api/missing',
    );
    is(response_start($missing)->{status}, 404, 'the inherited not-found fallback keeps the generated child status');
    is(response_body($missing), 'child missing', 'the inherited not-found handler renders inside the subtree');
    is(
        \@fallback_calls,
        [
            ['method_not_allowed', 'GET, HEAD'],
            ['not_found', '/missing'],
        ],
        'both inherited handlers observe the rewritten child request and local generated state',
    );
};

subtest 'mount middleware surrounds generated child results while route middleware stays full-only' => sub {
    my @trace;
    my $route_runs = 0;
    my $route_middleware = middleware(sub {
        my ($inner) = @_;
        return sub {
            ++$route_runs;
            return $inner->(@_);
        };
    });
    my $app = router(
        routes => [
            mount('/api',
                routes => [
                    route('/item' => sub {
                        return $_[0]->text('item');
                    }, methods => 'GET', middleware => [$route_middleware]),
                ],
                middleware => [tracing_middleware('mount', \@trace)],
            ),
        ],
        not_found => sub {
            push @trace, 'not found';
            return $_[0]->text('missing');
        },
        method_not_allowed => sub {
            push @trace, 'method not allowed';
            return $_[0]->text('wrong method');
        },
    )->to_app;

    run_app($app, path => '/api/missing', raw_path => '/api/missing');
    is(
        \@trace,
        ['mount before', 'not found', 'mount after'],
        'mount middleware surrounds an inherited child 404',
    );
    is($route_runs, 0, 'route middleware does not run for child 404');

    @trace = ();
    run_app($app, method => 'POST', path => '/api/item', raw_path => '/api/item');
    is(
        \@trace,
        ['mount before', 'method not allowed', 'mount after'],
        'mount middleware surrounds an inherited child 405',
    );
    is($route_runs, 0, 'route middleware does not run for child 405');
};

subtest 'application-mounted routers retain independent middleware boundaries and compile once' => sub {
    my @trace;
    my $mount_middleware_compilations = 0;
    my $counted_mount_middleware = middleware(sub {
        my ($inner) = @_;
        ++$mount_middleware_compilations;
        return $inner;
    });
    my $child = router(
        middleware => [tracing_middleware('child router', \@trace)],
        routes => [
            route('/item' => sub {
                push @trace, 'handler';
                return $_[0]->text('item');
            }, middleware => [tracing_middleware('child route', \@trace)]),
        ],
    );
    my $component = Local::CountedComponent->new($child);
    my $app = router(
        middleware => [tracing_middleware('parent router', \@trace)],
        routes => [
            mount('/api' => $component,
                middleware => [
                    tracing_middleware('mount', \@trace),
                    $counted_mount_middleware,
                ]),
        ],
    )->to_app;

    is($component->compilations, 1, 'the application mount target is coerced once while compiling the parent graph');
    is($mount_middleware_compilations, 1, 'mount middleware is resolved once while compiling the parent graph');
    run_app($app, path => '/api/item', raw_path => '/api/item');
    is(
        \@trace,
        [
            'parent router before',
            'mount before',
            'child router before',
            'child route before',
            'handler',
            'child route after',
            'child router after',
            'mount after',
            'parent router after',
        ],
        'parent, mount, child router, and child route middleware form distinct nested boundaries',
    );

    @trace = ();
    run_app($app, path => '/api/item', raw_path => '/api/item');
    is($component->compilations, 1, 'the mounted target is not recoerced per request');
    is($mount_middleware_compilations, 1, 'mount middleware is not rebuilt per request');
};

done_testing;

{
    package Local::CountedComponent;

    sub new {
        my ($class, $target) = @_;
        return bless { target => $target, compilations => 0 }, $class;
    }

    sub to_app {
        my ($self) = @_;
        ++$self->{compilations};
        return $self->{target}->to_app;
    }

    sub compilations { $_[0]->{compilations} }
}
