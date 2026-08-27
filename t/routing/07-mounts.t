#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);

use PAGI::Routing qw(router route mount middleware);
use PAGI::Routing::Trace;

our $MOUNT_PROVIDER_CALLS = 0;
sub MountProvider { ++$MOUNT_PROVIDER_CALLS; return qr/accepted/ }

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
        mount('/api', app => $mounted, middleware => [$scope_middleware]),
    ])->to_app;

    my ($parent_scope, $parent_trace)
        = PAGI::Routing::Trace->_ensure_http_scope(scope(
        path        => '/api/users',
        root_path   => '/outer',
        raw_path    => '/outer/api/users%20raw',
        path_params => { retained => 'yes' },
    ));
    run_scope($app, $parent_scope);
    run_app(
        $app,
        path      => '/api',
        root_path => '',
        raw_path  => '/api',
    );
    run_app(
        $app,
        path      => '/api/rooted',
        root_path => '/',
        raw_path  => '/api/rooted',
    );
    run_app(
        $app,
        path      => '/api/trailing',
        root_path => '/outer/',
        raw_path  => '/outer/api/trailing',
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
    is($seen[2]{root_path}, '/api', 'a root-only incoming prefix joins with one boundary slash');
    is($seen[3]{root_path}, '/outer/api', 'a trailing incoming prefix joins with one boundary slash');
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
    is($parent_scope->{'pagi.routing.trace'}, $parent_trace,
        'the incoming compatible Trace remains installed on the parent scope');
    is(
        [@{$middleware_seen[0]}{qw(path root_path raw_path)}],
        ['/users', '/outer/api', '/outer/api/users%20raw'],
        'mount middleware receives the rewritten child scope before the mounted application',
    );
};

subtest 'an exact Mount prefix enters a child root without redirecting' => sub {
    my @paths;
    my $child = router(routes => [
        route('/' => sub {
            push @paths, $_[0]->scope->{path};
            return $_[0]->text('apples');
        }),
    ]);
    my $app = router(routes => [
        mount('/apples', app => $child),
    ])->to_app;

    my $exact = run_app($app, path => '/apples', raw_path => '/apples');
    my $slash = run_app($app, path => '/apples/', raw_path => '/apples/');

    is([map { response_start($_)->{status} } ($exact, $slash)], [200, 200],
        'exact and trailing-slash spellings reach the child without a redirect');
    is([response_body($exact), response_body($slash)], ['apples', 'apples'],
        'both spellings select the child root leaf');
    is(\@paths, ['/', '/'],
        'the child root leaf receives slash for both spellings');
};

subtest 'trailing declarations, dynamic prefixes, and nested mounts use actual captures' => sub {
    my @trailing;
    my $trailing_app = router(routes => [
        mount('/api/', app => async sub {
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
        path_params => { retained => 'yes' },
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
        'nested mounted applications combine disjoint prefix and leaf captures',
    );
};

subtest 'path parameter merges are fresh and disjoint before child invocation' => sub {
    my ($mount_calls, $leaf_calls) = (0, 0);
    my $mounted = router(routes => [
        route('/{id}' => sub {
            ++$leaf_calls;
            return $_[0]->text('must not run');
        }),
    ]);
    my $hidden = Local::CountedComponent->new($mounted);
    my $app = router(routes => [
        mount('/tenants/{id}', app => $hidden),
        mount('/accounts/{account}', app => async sub {
            ++$mount_calls;
            await response_app('must not run')->(@_);
        }),
    ])->to_app;

    like(
        dies {
            run_app($app,
                path => '/tenants/outer/inner',
                raw_path => '/tenants/outer/inner');
        },
        qr/duplicate path parameter 'id' while entering '\/inner'/,
        'a Router hidden by an app object rejects a duplicate leaf capture',
    );
    is($leaf_calls, 0, 'the hidden Router rejects the collision before its leaf runs');

    my $incoming = { account => 'existing' };
    like(
        dies {
            run_app($app,
                path => '/accounts/new',
                raw_path => '/accounts/new',
                path_params => $incoming);
        },
        qr/duplicate path parameter 'account' while entering '\/accounts\/new'/,
        'a Mount rejects a duplicate incoming capture before its child runs',
    );
    is($mount_calls, 0, 'the mounted coderef is not invoked after a merge collision');
    is($incoming, { account => 'existing' },
        'a rejected merge leaves the parent path-parameter hash unchanged');
};

subtest 'mounted Router runtime metadata publishes named and unnamed captures' => sub {
    my @frames;
    my $blogs = router(routes => [
        route('/{blog_id}' => sub {
            my $frame = $_[0]->scope->{'pagi.routing'}{frames}[-1];
            push @frames, {
                root_path => $frame->{root_path},
                namespace => $frame->{logical_namespace},
                captures => { %{$frame->{captures}} },
                scope_root => $_[0]->scope->{root_path},
            };
            return $_[0]->text('blog');
        }, name => 'show'),
        route('/*rest' => sub {
            my $frame = $_[0]->scope->{'pagi.routing'}{frames}[-1];
            push @frames, {
                root_path => $frame->{root_path},
                namespace => $frame->{logical_namespace},
                captures => { %{$frame->{captures}} },
                scope_root => $_[0]->scope->{root_path},
            };
            return $_[0]->text('catchall');
        }),
    ]);
    my $person = router(routes => [
        mount('/{person_id}/blog', app => $blogs, name => 'blog'),
    ]);
    my $app = router(routes => [
        mount('/person', app => $person, name => 'person'),
    ])->to_app;

    is(response_body(run_app($app,
        path => '/person/42/blog/7', raw_path => '/person/42/blog/7',
        root_path => '/proxy')), 'blog',
        'the named mounted leaf completes normally');
    is(response_body(run_app($app,
        path => '/person/42/blog/missing/path',
        raw_path => '/person/42/blog/missing/path', root_path => '/proxy')),
        'catchall', 'the unnamed catchall completes normally');
    is(\@frames, [
        {
            root_path => '/proxy',
            namespace => '/person/blog',
            captures => { person_id => 42, blog_id => 7 },
            scope_root => '/proxy/person/42/blog',
        },
        {
            root_path => '/proxy',
            namespace => '/person/blog',
            captures => { person_id => 42, rest => 'missing/path' },
            scope_root => '/proxy/person/42/blog',
        },
    ], 'compiled Mounts publish the root boundary, namespace, and selected captures');
};

subtest 'provider constraints select every mounted application form once' => sub {
    $MOUNT_PROVIDER_CALLS = 0;
    my (@middleware_seen, @shorthand_seen, @router_seen, @coderef_seen);
    my $selected_mount = middleware(sub {
        my ($inner) = @_;
        return sub {
            push @middleware_seen, $_[0]{root_path};
            return $inner->(@_);
        };
    });
    my $known = router(routes => [
        route('/leaf' => sub {
            push @router_seen, $_[0]->path_param('id');
            return $_[0]->text('known ' . $_[0]->path_param('id'));
        }),
    ]);
    my $app = router(routes => [
        mount('/shorthand-provider/{id:&MountProvider}', routes => [
            route('/leaf' => sub {
                push @shorthand_seen, $_[0]->path_param('id');
                return $_[0]->text('shorthand ' . $_[0]->path_param('id'));
            }),
        ], middleware => [$selected_mount]),
        mount('/router-provider/{id:&MountProvider}',
            app => $known, name => 'known',
            middleware => [$selected_mount]),
        mount('/coderef-provider/{id:&MountProvider}', app => async sub {
            push @coderef_seen, $_[0]{path_params}{id};
            await response_app('coderef ' . $_[0]{path_params}{id})->(@_);
        }, middleware => [$selected_mount]),
    ])->to_app;

    is($MOUNT_PROVIDER_CALLS, 3,
        'each provider-backed Mount resolves its provider once at construction');

    my @accepted = (
        ['/shorthand-provider/accepted/leaf', 'shorthand accepted'],
        ['/router-provider/accepted/leaf', 'known accepted'],
        ['/coderef-provider/accepted/leaf', 'coderef accepted'],
    );
    for my $case (@accepted) {
        my ($path, $body) = @$case;
        my $events = run_app($app, path => $path, raw_path => $path);
        is(response_start($events)->{status}, 200,
            "$path completes with HTTP 200");
        is(response_body($events), $body,
            "$path selects its constrained mount");
    }

    for my $prefix (qw(shorthand-provider router-provider coderef-provider)) {
        my $path = "/$prefix/rejected/leaf";
        my $events = run_app($app, path => $path, raw_path => $path);
        is($events, [],
            "$prefix provider rejection leaves the Router unanswered");
    }

    is(\@shorthand_seen, ['accepted'], 'routes shorthand runs only for the accepted prefix');
    is(\@router_seen, ['accepted'], 'Router child runs only for the accepted prefix');
    is(\@coderef_seen, ['accepted'], 'coderef child runs only for the accepted prefix');
    is(scalar @middleware_seen, 3,
        'mount middleware runs only for the three selected prefixes');
    is($MOUNT_PROVIDER_CALLS, 3,
        'dispatch completion never reinvokes a resolved Mount provider');
};

subtest 'a root mount consumes nothing and leaves path arithmetic unchanged' => sub {
    my @seen;
    my $app = router(routes => [
        mount('/', app => async sub {
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
        mount('/api', app => response_app('earlier mount')),
        route('/api/exact' => sub { return $_[0]->text('later route') }),
    ])->to_app;
    is(
        response_body(run_app($earlier, path => '/api/exact', raw_path => '/api/exact')),
        'earlier mount',
        'an earlier mount preempts a later exact route',
    );

    my $broad = router(routes => [
        mount('/api', app => response_app('broad mount')),
        mount('/api/admin', app => response_app('narrow mount')),
    ])->to_app;
    is(
        response_body(run_app($broad, path => '/api/admin/users', raw_path => '/api/admin/users')),
        'broad mount',
        'an earlier broad mount preempts a later narrow mount',
    );

    my $constraint_fallback = router(routes => [
        mount('/api/{tenant}', app => response_app('must not run'),
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
    is($missing, [], 'an unanswered routes-shorthand child remains terminal');

    my $child_405 = router(routes => [
        route('/api/item' => sub { return $_[0]->text('parent GET') }, methods => 'GET'),
        mount('/api', app => response_app(
            'child method',
            status => 405,
            headers => [['Allow' => 'PATCH']],
        )),
    ])->to_app;
    my $method = run_app(
        $child_405,
        method => 'PUT',
        path => '/api/item',
        raw_path => '/api/item',
    );
    is(response_start($method)->{status}, 405, 'the mounted application controls its 405 status');
    is(response_header($method, 'Allow'), 'PATCH', 'the parent partial GET is not merged into the child application Allow');
};

subtest 'routes-shorthand Mount fallback middleware owns local decline evidence' => sub {
    my @fallback_calls;
    my $app = router(routes => [
        route('/api/item' => sub { return $_[0]->text('parent POST') }, methods => 'POST'),
        mount('/api', routes => [
                route('/item' => sub { return $_[0]->text('child GET') }, methods => 'GET'),
        ], middleware => [
            middleware('Routing::NotFound', handler => sub {
                my ($context) = @_;
                push @fallback_calls, ['not_found', $context->request->path];
                return $context->response
                    ->header('X-Fallback' => 'shorthand')
                    ->text('child missing');
            }),
            middleware('Routing::MethodNotAllowed', handler => sub {
                my ($context, $snapshot) = @_;
                push @fallback_calls,
                    ['method_not_allowed', join(', ', @{$snapshot->allowed_methods})];
                return $context->response
                    ->header('X-Fallback' => 'shorthand')
                    ->text('child method');
            }),
        ]),
    ])->to_app;

    my $method = run_app(
        $app,
        method => 'PUT',
        path => '/api/item',
        raw_path => '/api/item',
    );
    is(response_start($method)->{status}, 405, 'the shorthand child fallback renders 405');
    is(response_header($method, 'Allow'), 'GET, HEAD', 'the child uses a fresh local Allow set without parent POST');
    is(response_header($method, 'X-Fallback'), 'shorthand', 'the Mount rendered its child outcome');

    my $missing = run_app(
        $app,
        path => '/api/missing',
        raw_path => '/api/missing',
    );
    is(response_start($missing)->{status}, 404, 'the shorthand child fallback renders 404');
    is(response_body($missing), 'child missing', 'the Mount renders inside its child Router');
    is(
        \@fallback_calls,
        [
            ['method_not_allowed', 'GET, HEAD'],
            ['not_found', '/missing'],
        ],
        'both child handlers observe rewritten scope and child-only evidence',
    );
};

subtest 'Mount middleware surrounds fallback-rendered child declines while route middleware is full-only' => sub {
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
                middleware => [
                    tracing_middleware('mount', \@trace),
                    middleware('Routing::NotFound', handler => sub {
                        push @trace, 'not found';
                        return $_[0]->text('missing');
                    }),
                    middleware('Routing::MethodNotAllowed', handler => sub {
                        push @trace, 'method not allowed';
                        return $_[0]->text('wrong method');
                    }),
                ],
            ),
        ],
    )->to_app;

    run_app($app, path => '/api/missing', raw_path => '/api/missing');
    is(
        \@trace,
        ['mount before', 'not found', 'mount after'],
        'Mount middleware surrounds its rendered child 404',
    );
    is($route_runs, 0, 'route middleware does not run for child 404');

    @trace = ();
    run_app($app, method => 'POST', path => '/api/item', raw_path => '/api/item');
    is(
        \@trace,
        ['mount before', 'method not allowed', 'mount after'],
        'Mount middleware surrounds its rendered child 405',
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
            mount('/api', app => $component,
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

subtest 'two mount occurrences compile independent wrapper-local state' => sub {
    my $factory_calls = 0;
    my $next_wrapper = 0;
    my $stateful_middleware = middleware(sub {
        my ($inner) = @_;
        ++$factory_calls;
        my $wrapper = ++$next_wrapper;
        my $requests = 0;

        return sub {
            my ($request_scope, $receive, $send) = @_;
            my $child_scope = {
                %$request_scope,
                'task7.wrapper' => $wrapper,
                'task7.requests' => ++$requests,
            };
            return $inner->($child_scope, $receive, $send);
        };
    });
    my $shared_leaf = route('/state', raw => async sub {
        my ($request_scope, $receive, $send) = @_;
        my $body = join ':',
            $request_scope->{'task7.wrapper'},
            $request_scope->{'task7.requests'};
        await response_app($body)->(@_);
    }, middleware => [$stateful_middleware]);
    my $app = router(routes => [
        mount('/left', routes => [$shared_leaf]),
        mount('/right', routes => [$shared_leaf]),
    ])->to_app;

    is($factory_calls, 2, 'the shared subtree middleware factory runs once for each mount occurrence');
    is(
        response_body(run_app($app, path => '/left/state', raw_path => '/left/state')),
        '1:1',
        'the first mount starts its own wrapper-local request state',
    );
    is(
        response_body(run_app($app, path => '/left/state', raw_path => '/left/state')),
        '1:2',
        'a second request reuses the first mount occurrence wrapper',
    );
    is(
        response_body(run_app($app, path => '/right/state', raw_path => '/right/state')),
        '2:1',
        'the second mount has a distinct wrapper and independent local state',
    );
    is($factory_calls, 2, 'neither mount recompiles the shared subtree per request');
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
