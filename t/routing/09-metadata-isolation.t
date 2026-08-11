#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);

use PAGI::Routing qw(router route websocket sse mount middleware);
use PAGI::Routing::Resolver;

our $CONCURRENT_PROVIDER_CALLS = 0;
sub ConcurrentId {
    ++$CONCURRENT_PROVIDER_CALLS;
    return qr/(?:one|two)/;
}

sub scope {
    my (%changes) = @_;
    return {
        type        => 'http',
        method      => 'GET',
        path        => '/',
        root_path   => '',
        raw_path    => '/',
        path_params => {},
        headers     => [],
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

sub current_frame {
    my ($request_scope) = @_;
    my $container = $request_scope->{'pagi.routing'};
    return $container->{frames}[-1];
}

sub snapshot {
    my ($label, $request_scope) = @_;
    my $container = $request_scope->{'pagi.routing'};
    my $frame = current_frame($request_scope);
    return {
        label        => $label,
        container_id => refaddr($container),
        frames_id    => refaddr($container->{frames}),
        frame_id     => refaddr($frame),
        mounts_id    => refaddr($frame->{mounts}),
        captures_id  => refaddr($frame->{captures}),
        logical_namespace => $frame->{logical_namespace},
        captures     => { %{$frame->{captures}} },
        mounts       => [map { +{%$_} } @{$frame->{mounts}}],
        match        => defined $frame->{match} ? {%{$frame->{match}}} : undef,
    };
}

sub observing_middleware {
    my ($label, $observations) = @_;
    return middleware(sub {
        my ($inner) = @_;
        return async sub {
            my ($request_scope) = @_;
            push @$observations, snapshot("$label before", $request_scope);
            my $returned = $inner->(@_);
            await Future->wrap($returned);
            push @$observations, snapshot("$label after", $request_scope);
        };
    });
}

sub response_body {
    my ($events) = @_;
    return join '', map { $_->{body} // '' }
        grep { ($_->{type} // '') eq 'http.response.body' } @$events;
}

subtest 'metadata is installed before middleware and records effective mounted leaves' => sub {
    my @observations;
    my $router_middleware = observing_middleware('router', \@observations);
    my $outer_mount_middleware = observing_middleware('outer mount', \@observations);
    my $inner_mount_middleware = observing_middleware('inner mount', \@observations);
    my $route_middleware = observing_middleware('route', \@observations);

    my $app = router(
        middleware => [$router_middleware],
        routes => [
            mount('/tenants/{tenant}',
                routes => [
                    mount('/api',
                        routes => [
                            route('/users/{id}' => sub {
                                my ($c) = @_;
                                push @observations, snapshot('handler', $c->scope);
                                return $c->text('ok');
                            },
                                name => 'show',
                                desc => 'Show one user',
                                middleware => [$route_middleware],
                            ),
                        ],
                        middleware => [$inner_mount_middleware],
                    ),
                ],
                name      => 'tenant',
                desc => 'Tenant boundary',
                middleware => [$outer_mount_middleware],
            ),
        ],
    )->to_app;

    run_scope($app, scope(
        path => '/tenants/acme/api/users/42',
        raw_path => '/tenants/acme/api/users/42',
    ));

    is(
        [map { $_->{label} } @observations],
        [
            'router before',
            'outer mount before',
            'inner mount before',
            'route before',
            'handler',
            'route after',
            'inner mount after',
            'outer mount after',
            'router after',
        ],
        'metadata observers retain normal middleware ordering',
    );
    is($observations[0]{mounts}, [], 'router middleware initially sees no mount selections');
    is($observations[0]{match}, undef, 'router middleware initially sees no leaf match');
    is([$observations[0]{logical_namespace}, $observations[0]{captures}],
        ['/', {}], 'a new API frame starts at the root with a fresh empty snapshot');
    is($observations[1]{mounts}, [
        {
            path => '/tenants/{tenant}',
            name      => 'tenant',
            desc => 'Tenant boundary',
        },
    ], 'outer mount metadata is installed before its middleware');
    is([$observations[1]{logical_namespace}, $observations[1]{captures}],
        ['/tenant', { tenant => 'acme' }],
        'the named outer mount advances namespace and snapshots its capture');
    is($observations[2]{mounts}, [
        {
            path => '/tenants/{tenant}',
            name      => 'tenant',
            desc => 'Tenant boundary',
        },
        {
            path => '/api',
            name      => undef,
            desc => undef,
        },
    ], 'nested mount descriptors preserve declaration order and undefined fields');
    is([$observations[2]{logical_namespace}, $observations[2]{captures}],
        ['/tenant', { tenant => 'acme' }],
        'an unnamed inline mount retains namespace and replaces the prefix snapshot');
    is($observations[3]{match}, {
        kind => 'route',
        route => '/tenants/{tenant}/api/users/{id}',
        name => '/tenant/show',
        logical_namespace => '/tenant',
        desc => 'Show one user',
    }, 'effective leaf metadata is installed before route middleware');
    is([$observations[3]{logical_namespace}, $observations[3]{captures}],
        ['/tenant', { tenant => 'acme', id => 42 }],
        'the FULL leaf replaces state with its namespace and all effective captures');
    isnt($observations[0]{captures_id}, $observations[1]{captures_id},
        'the first mount replaces the root capture hash');
    isnt($observations[1]{captures_id}, $observations[2]{captures_id},
        'the nested mount replaces the outer capture hash');
    isnt($observations[2]{captures_id}, $observations[3]{captures_id},
        'the FULL leaf replaces the mount capture hash');
    is($observations[4]{match}, $observations[3]{match}, 'the handler sees the same effective match');
    is($observations[-1]{match}, $observations[3]{match}, 'outer middleware sees the final match after downstream');

    my %frame_ids = map { $_->{frame_id} => 1 } @observations;
    my %mount_ids = map { $_->{mounts_id} => 1 } @observations;
    is(scalar keys %frame_ids, 1, 'all levels in one compiled router share one request-local frame');
    is(scalar keys %mount_ids, 1, 'all levels in one compiled router share one request-local mounts array');
};

subtest 'generated outcomes, short circuits, and application mounts publish only selected metadata' => sub {
    my @generated;
    my $generated_app = router(
        middleware => [observing_middleware('generated router', \@generated)],
        routes => [
            mount('/api', routes => [
                route('/items' => sub { return $_[0]->text('items') }, methods => 'GET'),
            ]),
        ],
    )->to_app;

    run_scope($generated_app, scope(path => '/missing', raw_path => '/missing'));
    is($generated[-1]{mounts}, [], 'a root generated 404 has no mount chain');
    is($generated[-1]{match}, undef, 'a root generated 404 has no match');
    is([$generated[-1]{logical_namespace}, $generated[-1]{captures}],
        ['/', {}], 'a root generated 404 retains the root namespace and empty snapshot');

    @generated = ();
    run_scope($generated_app, scope(
        path => '/api/missing',
        raw_path => '/api/missing',
    ));
    is($generated[-1]{mounts}, [{ path => '/api', name      => undef, desc => undef }],
        'an inline child 404 retains the selected mount chain');
    is($generated[-1]{match}, undef, 'an inline child 404 has no leaf match');
    is([$generated[-1]{logical_namespace}, $generated[-1]{captures}],
        ['/', {}], 'an unnamed inline child 404 retains its owning prefix state');

    @generated = ();
    run_scope($generated_app, scope(
        method => 'POST',
        path => '/api/items',
        raw_path => '/api/items',
    ));
    is($generated[-1]{mounts}, [{ path => '/api', name      => undef, desc => undef }],
        'an inline child 405 retains the selected mount chain');
    is($generated[-1]{match}, undef, 'a partial route does not publish a leaf match');
    is([$generated[-1]{logical_namespace}, $generated[-1]{captures}],
        ['/', {}], 'a PARTIAL leaf does not replace generated 405 state');

    my $handler_calls = 0;
    my @short_circuit;
    my $short_circuit_middleware = middleware(sub {
        my ($inner) = @_;
        return async sub {
            my ($request_scope, $receive, $send) = @_;
            push @short_circuit, snapshot('short circuit', $request_scope);
            await $send->({
                type => 'http.response.start', status => 204, headers => [],
            });
            await $send->({
                type => 'http.response.body', body => '', more => 0,
            });
        };
    });
    my $short_app = route('/short' => sub {
        ++$handler_calls;
        return $_[0]->text('must not run');
    },
        name => 'short',
        desc => 'Short-circuited route',
        middleware => [$short_circuit_middleware],
    )->to_app;
    run_scope($short_app, scope(path => '/short', raw_path => '/short'));
    is($handler_calls, 0, 'route middleware may short-circuit the selected handler');
    is($short_circuit[0]{match}, {
        kind => 'route',
        route => '/short',
        name => '/short',
        logical_namespace => '/',
        desc => 'Short-circuited route',
    }, 'selection publishes a leaf before route middleware can short-circuit');

    my @application_mount;
    my $mounted_target = async sub {
        my ($request_scope, $receive, $send) = @_;
        push @application_mount, snapshot('mounted target', $request_scope);
        await $send->({
            type => 'http.response.start', status => 200, headers => [],
        });
        await $send->({
            type => 'http.response.body', body => 'mounted', more => 0,
        });
    };
    my $mounted_app = router(routes => [
        mount('/api', routes => [
            mount('/assets' => $mounted_target,
                desc => 'Opaque assets',
                middleware => [observing_middleware('application mount', \@application_mount)],
            ),
        ], name      => 'api', desc => 'API boundary'),
    ])->to_app;
    run_scope($mounted_app, scope(
        path => '/api/assets/logo.svg',
        raw_path => '/api/assets/logo.svg',
    ));
    is($application_mount[0]{match}, {
        kind => 'mount',
        route => '/api/assets',
        name => undef,
        logical_namespace => '/api',
        desc => 'Opaque assets',
    }, 'a nested application mount publishes its complete terminal pattern before middleware');
    is($application_mount[0]{mounts}, [
        { path => '/api', name      => 'api', desc => 'API boundary' },
    ], 'an opaque terminal mount retains inline ancestry without adding itself as a descriptor');
    is($application_mount[1]{match}, $application_mount[0]{match},
        'the mounted application receives the terminal parent match');
};

subtest 'separately compiled routers append frames without overwriting legacy metadata' => sub {
    my @child_scopes;
    my $child = router(routes => [
        route('/items/{id}' => sub {
            my ($c) = @_;
            push @child_scopes, $c->scope;
            return $c->text('child');
        }, name => 'show', desc => 'Child item'),
    ])->to_app;

    my @parent_observations;
    my $parent = router(
        middleware => [observing_middleware('parent', \@parent_observations)],
        routes => [
            mount('/api' => $child, desc => 'Child application'),
        ],
    )->to_app;
    my $legacy = { route => { name => 'legacy', path => '/old' } };
    my $incoming = scope(
        path => '/api/items/7',
        raw_path => '/api/items/7',
        'pagi.router' => $legacy,
    );

    run_scope($parent, $incoming);

    my $child_scope = $child_scopes[0];
    my $frames = $child_scope->{'pagi.routing'}{frames};
    is(scalar @$frames, 2, 'a separately compiled child app appends its own routing frame');
    is($frames->[0]{match}, {
        kind => 'mount',
        route => '/api',
        name => undef,
        logical_namespace => '/',
        desc => 'Child application',
    }, 'the parent frame retains its terminal application-mount match');
    is($frames->[1]{match}, {
        kind => 'route',
        route => '/items/{id}',
        name => '/show',
        logical_namespace => '/',
        desc => 'Child item',
    }, 'the child frame records its own application-relative route');
    is(
        [map { $_->{root_path} } @$frames],
        ['', '/api'],
        'each compiled router records the root_path at its own entry boundary',
    );
    isnt(refaddr($frames->[0]), refaddr($frames->[1]), 'parent and child use distinct current frames');
    isnt(refaddr($frames->[0]{resolver}), refaddr($frames->[1]{resolver}),
        'independently compiled routers retain their own immutable resolvers');
    is(refaddr($child_scope->{'pagi.router'}), refaddr($legacy),
        'the existing pagi.router value survives by reference');
    is($child_scope->{'pagi.router'}, $legacy, 'the existing pagi.router content survives unchanged');
    is($incoming->{'pagi.routing'}, undef, 'metadata bootstrap does not add a key to the incoming scope');
    is($parent_observations[-1]{match}, $frames->[0]{match},
        'parent middleware retains its terminal frame after the child completes');
};

subtest 'a path-only ancestor resolver forms an incompatible routing boundary' => sub {
    my $path_only = bless {}, 'Local::PathOnlyResolver';
    my $foreign_frame = {
        resolver          => $path_only,
        logical_namespace => '/',
        captures          => {},
        mounts            => [],
        match             => undef,
    };
    my $foreign_container = {
        version => 1,
        frames => [$foreign_frame],
    };
    my @seen;
    my $app = route('/inside' => sub {
        my ($c) = @_;
        push @seen, {
            scope => $c->scope,
            reverse_path => $c->path_for('inside'),
        };
        return $c->text('inside');
    }, name => 'inside')->to_app;
    my $incoming = scope(
        path => '/inside',
        raw_path => '/inside',
        'pagi.routing' => $foreign_container,
    );

    my $events = run_scope($app, $incoming);
    my $fresh = $seen[0]{scope}{'pagi.routing'};
    is(scalar @{$fresh->{frames}}, 1,
        'the path-only resolver ancestry is excluded from the fresh v1 container');
    isnt(refaddr($fresh->{frames}[0]{resolver}), refaddr($path_only),
        'the new current frame uses the compiled Router resolver');
    is($seen[0]{reverse_path}, '/inside',
        'Context reverse generation works from the new current frame');
    is(response_body($events), 'inside', 'dispatch completes through the fresh boundary');
    is(refaddr($incoming->{'pagi.routing'}), refaddr($foreign_container),
        'the incompatible incoming container remains untouched');
};

subtest 'supported ancestry composes while foreign routing values form fresh boundaries' => sub {
    my $ancestor_resolver = PAGI::Routing::Resolver->new(routes => []);
    my $ancestor_frame = {
        resolver          => $ancestor_resolver,
        logical_namespace => '/',
        captures          => {},
        mounts            => [{ path => '/outer', name      => undef, desc => undef }],
        match             => { kind => 'mount', route => '/outer' },
    };
    my $ancestor_frames = [$ancestor_frame];
    my $ancestor_container = { version => 1, frames => $ancestor_frames };
    my @seen;
    my $app = route('/inside' => sub {
        my ($c) = @_;
        push @seen, $c->scope;
        return $c->text('inside');
    }, name => 'inside')->to_app;
    my $incoming = scope(
        path => '/inside',
        raw_path => '/inside',
        'pagi.routing' => $ancestor_container,
    );

    run_scope($app, $incoming);
    my $composed = $seen[-1]{'pagi.routing'};
    is(scalar @{$composed->{frames}}, 2, 'a supported v1 container contributes its ancestor frames');
    is(refaddr($composed->{frames}[0]), refaddr($ancestor_frame),
        'valid ancestor frames are retained by reference without mutation');
    isnt(refaddr($composed), refaddr($ancestor_container), 'the child receives a new v1 container');
    isnt(refaddr($composed->{frames}), refaddr($ancestor_frames), 'the child receives a new frame array');
    is($ancestor_container, { version => 1, frames => [$ancestor_frame] },
        'the incoming supported container remains untouched');

    my @foreign_cases = (
        ['scalar', 'foreign-routing-value'],
        ['opaque hash', { owner => 'other-router', frames => [$ancestor_frame] }],
        ['newer version', { version => 2, frames => [$ancestor_frame] }],
        ['malformed v1', { version => 1, frames => 'not-an-array' }],
        ['malformed prior frame', { version => 1, frames => [{ mounts => [] }] }],
        ['malformed prior mounts', {
            version => 1,
            frames => [{
                resolver => $ancestor_resolver,
                mounts => 'not-an-array',
                match => undef,
            }],
        }],
        ['malformed prior match', {
            version => 1,
            frames => [{
                resolver => $ancestor_resolver,
                mounts => [],
                match => 'not-a-hash',
            }],
        }],
        ['malformed prior root_path', {
            version => 1,
            frames => [{
                resolver => $ancestor_resolver,
                logical_namespace => '/',
                captures => {},
                mounts => [],
                match => undef,
                root_path => [],
            }],
        }],
        ['malformed prior namespace', {
            version => 1,
            frames => [{
                resolver => $ancestor_resolver,
                logical_namespace => 'relative',
                captures => {},
                mounts => [],
                match => undef,
            }],
        }],
        ['malformed prior captures', {
            version => 1,
            frames => [{
                resolver => $ancestor_resolver,
                logical_namespace => '/',
                captures => [],
                mounts => [],
                match => undef,
            }],
        }],
    );
    for my $case (@foreign_cases) {
        my ($label, $foreign) = @$case;
        my $request_scope = scope(
            path => '/inside',
            raw_path => '/inside',
            'pagi.routing' => $foreign,
        );
        my $foreign_id = ref($foreign) ? refaddr($foreign) : undef;

        run_scope($app, $request_scope);
        my $fresh = $seen[-1]{'pagi.routing'};
        is($fresh->{version}, 1, "$label receives a fresh supported version");
        is(scalar @{$fresh->{frames}}, 1, "$label ancestry is ignored at the incompatible boundary");
        is($fresh->{frames}[0]{match}{route}, '/inside', "$label still dispatches through the new router");
        is($request_scope->{'pagi.routing'}, $foreign, "$label remains unchanged in the incoming scope");
        is(refaddr($request_scope->{'pagi.routing'}), $foreign_id, "$label retains incoming reference identity")
            if ref($foreign);
    }
};

subtest 'matched capture snapshots do not alias mutable scope path parameters' => sub {
    my @seen;
    my $mutate_prefix_params = middleware(sub {
        my ($inner) = @_;
        return sub {
            my ($request_scope) = @_;
            $request_scope->{path_params}{account_id} = 'middleware-mutated';
            return $inner->(@_);
        };
    });
    my $app = router(routes => [
        mount('/api/{account_id}', routes => [
            route('/items/{item_id}' => sub {
                my ($c) = @_;
                my $frame = current_frame($c->scope);
                my $original_scope_params = $c->scope->{path_params};
                push @seen, {
                    frame_id => refaddr($frame),
                    scope_params_id => refaddr($original_scope_params),
                    captures_id => refaddr($frame->{captures}),
                    logical_namespace => $frame->{logical_namespace},
                    captures_before => { %{$frame->{captures}} },
                };

                $original_scope_params->{account_id} = 'mutated';
                $original_scope_params->{item_id} = 'mutated';
                $c->scope->{path_params} = {
                    account_id => 'replaced',
                    item_id => 'replaced',
                };

                $seen[-1]{captures_after} = { %{$frame->{captures}} };
                $seen[-1]{link_after} = $c->path_for('show');
                return $c->text('snapshot');
            }, name => 'show'),
        ], name      => 'api', middleware => [$mutate_prefix_params]),
    ])->to_app;

    run_scope($app, scope(
        path => '/api/acme/items/7',
        raw_path => '/api/acme/items/7',
    ));

    isnt($seen[0]{captures_id}, $seen[0]{scope_params_id},
        'the frame capture snapshot is a distinct hash from scope path_params');
    is($seen[0]{logical_namespace}, '/api',
        'the full leaf records its containing namespace');
    is($seen[0]{captures_before}, { account_id => 'acme', item_id => 7 },
        'the full leaf snapshot includes all effective captures');
    is($seen[0]{captures_after}, $seen[0]{captures_before},
        'mutating and replacing scope path_params leaves the snapshot unchanged');
    is($seen[0]{link_after}, '/api/acme/items/7',
        'relative generation continues to use the immutable request snapshot');
};

subtest 'compiled middleware state follows documented ownership boundaries' => sub {
    my $factory_builds = 0;
    my @ordinary_counts;
    my $stateful = middleware(sub {
        my ($inner) = @_;
        ++$factory_builds;
        my $requests = 0;
        return sub {
            $_[0]{ordinary_count} = ++$requests;
            return $inner->(@_);
        };
    });
    my $routing = router(
        middleware => [$stateful],
        routes => [route('/state' => sub {
            my ($c) = @_;
            push @ordinary_counts, $c->scope->{ordinary_count};
            return $c->text('state');
        })],
    );
    my $first_app = $routing->to_app;
    my $second_app = $routing->to_app;
    is($factory_builds, 2, 'each to_app call builds one independent middleware instance');
    run_scope($first_app, scope(path => '/state')) for 1 .. 2;
    run_scope($second_app, scope(path => '/state'));
    is(\@ordinary_counts, [1, 2, 1],
        'one compiled app shares ordinary middleware state while another compiled app starts fresh');

    my $shared_object = bless { requests => 0, builds => 0 }, 'Local::SharedMiddleware';
    my @object_counts;
    my $object_routing = router(
        middleware => [middleware($shared_object)],
        routes => [route('/object' => sub {
            my ($c) = @_;
            push @object_counts, $c->scope->{shared_object_count};
            return $c->text('object');
        })],
    );
    my $object_first = $object_routing->to_app;
    my $object_second = $object_routing->to_app;
    run_scope($object_first, scope(path => '/object'));
    run_scope($object_second, scope(path => '/object'));
    is($shared_object->{builds}, 2, 'an explicit middleware object is wrapped once by each compilation');
    is(\@object_counts, [1, 2], 'the explicit object retains caller-owned state across compiled apps');

    my $shared_closure_count = 0;
    my @closure_counts;
    my $capturing = middleware(sub {
        my ($inner) = @_;
        return sub {
            $_[0]{shared_closure_count} = ++$shared_closure_count;
            return $inner->(@_);
        };
    });
    my $closure_routing = router(
        middleware => [$capturing],
        routes => [route('/closure' => sub {
            my ($c) = @_;
            push @closure_counts, $c->scope->{shared_closure_count};
            return $c->text('closure');
        })],
    );
    my $closure_first = $closure_routing->to_app;
    my $closure_second = $closure_routing->to_app;
    run_scope($closure_first, scope(path => '/closure'));
    run_scope($closure_second, scope(path => '/closure'));
    is(\@closure_counts, [1, 2], 'a factory closure retains its explicit external state across compilations');

    my $subtree_builds = 0;
    my @subtree_instances;
    my $per_occurrence = middleware(sub {
        my ($inner) = @_;
        my $instance = ++$subtree_builds;
        return sub {
            $_[0]{subtree_instance} = $instance;
            return $inner->(@_);
        };
    });
    my @subtree = (
        route('/item' => sub {
            my ($c) = @_;
            push @subtree_instances, $c->scope->{subtree_instance};
            return $c->text('item');
        }, middleware => [$per_occurrence]),
    );
    my $twice = router(routes => [
        mount('/first', routes => \@subtree),
        mount('/second', routes => \@subtree),
    ])->to_app;
    run_scope($twice, scope(path => '/first/item'));
    run_scope($twice, scope(path => '/second/item'));
    is($subtree_builds, 2, 'the same inline subtree receives a wrapper graph per mount occurrence');
    isnt($subtree_instances[0], $subtree_instances[1],
        'the two inline mount occurrences execute different wrapper instances');
};

subtest 'concurrent requests isolate frames, matches, parameters, and generated response state' => sub {
    my (@contexts, @gates);
    $CONCURRENT_PROVIDER_CALLS = 0;
    my $app = router(routes => [
        mount('/api', routes => [
            route('/items/{id:&ConcurrentId}' => sub {
                my ($c) = @_;
                push @contexts, $c;
                my $gate = Future->new;
                push @gates, $gate;
                return $gate;
            }, name => 'show'),
        ]),
    ])->to_app;
    is($CONCURRENT_PROVIDER_CALLS, 1,
        'the concurrent provider is resolved once while constructing its source Pattern');

    my (@first_events, @second_events);
    my $first = $app->(
        scope(path => '/api/items/one', raw_path => '/api/items/one'),
        \&receive,
        sub { push @first_events, $_[0]; return Future->done },
    );
    my $second = $app->(
        scope(path => '/api/items/two', raw_path => '/api/items/two'),
        \&receive,
        sub { push @second_events, $_[0]; return Future->done },
    );

    is(scalar @contexts, 2, 'both handlers start before either pending response resolves');
    ok(!$first->is_ready && !$second->is_ready, 'both request Futures remain independently pending');
    my $first_scope = $contexts[0]->scope;
    my $second_scope = $contexts[1]->scope;
    my $first_container = $first_scope->{'pagi.routing'};
    my $second_container = $second_scope->{'pagi.routing'};
    my $first_frame = current_frame($first_scope);
    my $second_frame = current_frame($second_scope);
    isnt(refaddr($first_scope->{path_params}), refaddr($second_scope->{path_params}),
        'concurrent requests have distinct path-parameter hashes');
    is([$first_scope->{path_params}{id}, $second_scope->{path_params}{id}], ['one', 'two'],
        'concurrent path parameters retain their own captured values');
    isnt(refaddr($first_container), refaddr($second_container),
        'concurrent requests have distinct metadata containers');
    isnt(refaddr($first_container->{frames}), refaddr($second_container->{frames}),
        'concurrent requests have distinct frame arrays');
    isnt(refaddr($first_frame), refaddr($second_frame),
        'concurrent requests have distinct current frames');
    isnt(refaddr($first_frame->{mounts}), refaddr($second_frame->{mounts}),
        'concurrent requests have distinct mount arrays');
    isnt(refaddr($first_frame->{match}), refaddr($second_frame->{match}),
        'concurrent requests have distinct match records');
    isnt(refaddr($first_frame->{captures}), refaddr($second_frame->{captures}),
        'concurrent requests have distinct capture snapshots');
    is([$first_frame->{logical_namespace}, $second_frame->{logical_namespace}],
        ['/', '/'], 'concurrent requests retain their own current namespaces');
    is([$first_frame->{captures}{id}, $second_frame->{captures}{id}],
        ['one', 'two'], 'concurrent frames retain distinct capture values');
    is([$contexts[0]->path_for('show'), $contexts[1]->path_for('show')],
        ['/api/items/one', '/api/items/two'],
        'concurrent Context links use only their own request captures');
    is($CONCURRENT_PROVIDER_CALLS, 1,
        'concurrent matching and reverse generation reuse the normalized provider predicate');
    is(refaddr($first_frame->{resolver}), refaddr($second_frame->{resolver}),
        'concurrent requests share only the immutable compiled resolver');
    is($first_frame->{match}{route}, '/api/items/{id:&ConcurrentId}',
        'the first match uses the effective provider-backed mounted pattern');
    is($second_frame->{match}{route}, '/api/items/{id:&ConcurrentId}',
        'the second match uses the same immutable provider-backed pattern');
    push @{$first_frame->{mounts}}, { path => '/consumer-only' };
    $first_frame->{match}{consumer_marker} = 'first';
    is(scalar @{$second_frame->{mounts}}, 1, 'a first-request mount update is absent from the second request');
    is($second_frame->{match}{consumer_marker}, undef, 'a first-request match update is absent from the second request');

    $gates[0]->done($contexts[0]->text('one'));
    $gates[1]->done($contexts[1]->text('two'));
    $first->get;
    $second->get;
    is(response_body(\@first_events), 'one', 'the first pending request completes with its own response');
    is(response_body(\@second_events), 'two', 'the second pending request completes with its own response');

    my (@fallback_contexts, @fallback_gates);
    my $fallback_app = router(
        routes => [
            route('/method' => sub { return $_[0]->text('get') }, methods => 'GET'),
        ],
        method_not_allowed => sub {
            my ($c) = @_;
            push @fallback_contexts, $c;
            my $gate = Future->new;
            push @fallback_gates, $gate;
            return $gate;
        },
    )->to_app;
    my (@fallback_one_events, @fallback_two_events);
    my $fallback_one = $fallback_app->(
        scope(method => 'POST', path => '/method'),
        \&receive,
        sub { push @fallback_one_events, $_[0]; return Future->done },
    );
    my $fallback_two = $fallback_app->(
        scope(method => 'DELETE', path => '/method'),
        \&receive,
        sub { push @fallback_two_events, $_[0]; return Future->done },
    );
    is(scalar @fallback_contexts, 2, 'both generated 405 handlers start concurrently');
    isnt(refaddr($fallback_contexts[0]->response), refaddr($fallback_contexts[1]->response),
        'generated response accumulators are request-local');
    is($fallback_contexts[0]->response->header('Allow'), 'GET, HEAD',
        'the first fallback receives its computed Allow');
    is($fallback_contexts[1]->response->header('Allow'), 'GET, HEAD',
        'the second fallback receives its own computed Allow');
    $fallback_contexts[0]->response->header('Allow' => 'PATCH');
    is($fallback_contexts[1]->response->header('Allow'), 'GET, HEAD',
        'mutating one fallback accumulator does not affect the other');
    $fallback_gates[0]->done($fallback_contexts[0]->text('first 405'));
    $fallback_gates[1]->done($fallback_contexts[1]->text('second 405'));
    $fallback_one->get;
    $fallback_two->get;
    is(response_body(\@fallback_one_events), 'first 405', 'the first generated response completes independently');
    is(response_body(\@fallback_two_events), 'second 405', 'the second generated response completes independently');
};

subtest 'reentrant dispatch appends a frame without changing the outer invocation' => sub {
    my ($app, $inner_scope, $outer_scope_after);
    my $routing = router(routes => [
        route('/outer' => async sub {
            my ($c) = @_;
            my @events;
            my $inner_request = {
                %{$c->scope},
                path => '/inner',
                raw_path => '/inner',
            };
            await $app->(
                $inner_request,
                \&receive,
                sub { push @events, $_[0]; return Future->done },
            );
            $outer_scope_after = $c->scope;
            return $c->text('outer');
        }, name => 'outer'),
        route('/inner' => sub {
            my ($c) = @_;
            $inner_scope = $c->scope;
            return $c->text('inner');
        }, name => 'inner'),
    ]);
    $app = $routing->to_app;

    run_scope($app, scope(path => '/outer', raw_path => '/outer'));

    my $inner_frames = $inner_scope->{'pagi.routing'}{frames};
    my $outer_frames = $outer_scope_after->{'pagi.routing'}{frames};
    is(scalar @$inner_frames, 2, 'a reentrant invocation appends its own frame');
    is(scalar @$outer_frames, 1, 'the outer invocation retains only its own frame array');
    is(refaddr($inner_frames->[0]), refaddr($outer_frames->[0]),
        'the reentrant invocation retains the outer frame as ancestry');
    isnt(refaddr($inner_frames->[1]), refaddr($outer_frames->[0]),
        'the reentrant invocation allocates a distinct current frame');
    is($outer_frames->[0]{match}{route}, '/outer', 'the outer match survives reentrant dispatch');
    is($inner_frames->[1]{match}{route}, '/inner', 'the inner invocation records its own match');
    is(refaddr($inner_frames->[0]{resolver}), refaddr($inner_frames->[1]{resolver}),
        'reentrant calls through one compiled app share its immutable resolver');
};

subtest 'WebSocket and SSE leaves publish protocol-specific effective metadata' => sub {
    my @seen;
    my $app = router(routes => [
        mount('/api', routes => [
            websocket('/socket/{room}' => sub {
                my ($c) = @_;
                push @seen, snapshot('websocket', $c->scope);
                return Future->done;
            }, name => 'socket', desc => 'Chat socket'),
            sse('/events/{stream}' => sub {
                my ($c) = @_;
                push @seen, snapshot('sse', $c->scope);
                return Future->done;
            }, name => 'events', desc => 'Event stream'),
        ], name      => 'api'),
    ])->to_app;

    run_scope($app, scope(
        type => 'websocket',
        method => undef,
        path => '/api/socket/lobby',
        raw_path => '/api/socket/lobby',
    ));
    run_scope($app, scope(
        type => 'sse',
        method => undef,
        path => '/api/events/news',
        raw_path => '/api/events/news',
    ));

    is($seen[0]{match}, {
        kind => 'websocket',
        route => '/api/socket/{room}',
        name => '/api/socket',
        logical_namespace => '/api',
        desc => 'Chat socket',
    }, 'WebSocket selection publishes its protocol kind and effective name');
    is($seen[1]{match}, {
        kind => 'sse',
        route => '/api/events/{stream}',
        name => '/api/events',
        logical_namespace => '/api',
        desc => 'Event stream',
    }, 'SSE selection publishes its protocol kind and effective name');
};

{
    package Local::PathOnlyResolver;

    sub path_for { return '/legacy' }
}

{
    package Local::SharedMiddleware;

    sub wrap {
        my ($self, $inner) = @_;
        ++$self->{builds};
        return sub {
            $_[0]{shared_object_count} = ++$self->{requests};
            return $inner->(@_);
        };
    }
}

done_testing;
