#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Scalar::Util qw(blessed refaddr);

use lib 'lib', 't/lib';
use PAGI::App::Router;
use PAGI::Compose qw(compose);
use PAGI::Endpoint::Router ();
use PAGI::Response::Text ();
use PAGI::Routing qw(middleware mount route router sse websocket);
use PAGI::Routing::Route ();
use PAGI::Utils qw(as_app);

sub scope {
    my (%change) = @_;
    my $path = exists $change{path} ? $change{path} : '/';
    return {
        type        => 'http',
        method      => 'GET',
        path        => $path,
        raw_path    => $path,
        root_path   => '',
        path_params => {},
        headers     => [],
        %change,
    };
}

sub run_scope_with_channels {
    my ($app, $request_scope) = @_;
    my @events;
    my $receive = sub {
        return Future->done({ type => 'http.request', body => '', more => 0 });
    };
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    $app->($request_scope, $receive, $send)->get;
    return (\@events, $receive, $send);
}

sub run_scope {
    my ($events) = run_scope_with_channels(@_);
    return $events;
}

sub response_body {
    my ($events) = @_;
    return join '', map { defined $_->{body} ? $_->{body} : '' }
        grep { (defined $_->{type} ? $_->{type} : '') eq 'http.response.body' }
        @$events;
}

sub response_status {
    my ($events) = @_;
    my ($start) = grep {
        (defined $_->{type} ? $_->{type} : '') eq 'http.response.start'
    } @$events;
    return defined $start ? $start->{status} : undef;
}

sub response_header {
    my ($events, $name) = @_;
    my ($start) = grep {
        (defined $_->{type} ? $_->{type} : '') eq 'http.response.start'
    } @$events;
    return unless $start;
    for my $pair (@{$start->{headers}}) {
        return $pair->[1] if lc($pair->[0]) eq lc($name);
    }
    return;
}

subtest 'Route synopsis uses its executable named constructor' => sub {
    open my $handle, '<', 'lib/PAGI/Routing/Route.pm'
        or die "Cannot read Route POD: $!";
    my $pod = do { local $/; <$handle> };
    close $handle or die "Cannot close Route POD: $!";

    my ($synopsis) = $pod =~ /
        =head1\ SYNOPSIS\n\n
        ((?:[ ]{4}[^\n]*\n)+)
    /x;
    ok(defined $synopsis, 'Route synopsis contains one indented example');
    return unless defined $synopsis;

    $synopsis =~ s/^[ ]{4}//mg;
    my $executed = eval "$synopsis\n1;";
    ok($executed, 'Route synopsis constructs successfully') or diag($@);
};

sub routing_match_projection {
    my ($protocol) = @_;
    my $frame = $protocol->scope->{'pagi.routing'}{frames}[-1];
    return {
        logical_namespace => $frame->{logical_namespace},
        captures => { %{$frame->{captures}} },
        mounts => [map {
            +{ path => $_->{path}, name => $_->{name}, desc => $_->{desc} }
        } @{$frame->{mounts}}],
        match => {
            kind => $frame->{match}{kind},
            route => $frame->{match}{route},
            name => $frame->{match}{name},
            logical_namespace => $frame->{match}{logical_namespace},
        },
    };
}

sub representative_handlers {
    my ($seen) = @_;
    return {
        post => sub {
            my ($request) = @_;
            return PAGI::Response::Text->new('post ' . $request->path_param('id'));
        },
        get => sub {
            my ($request) = @_;
            push @$seen, {
                label => 'get',
                request_method => $request->method,
                routing => routing_match_projection($request),
            };
            return PAGI::Response::Text->new(
                'get ' . $request->path_param('id'), status => 207,
            );
        },
        mounted => sub {
            my ($request) = @_;
            push @$seen, {
                label => 'mounted',
                routing => routing_match_projection($request),
            };
            return PAGI::Response::Text->new(join ':',
                $request->path_param('tenant'),
                $request->path_param('child_id'));
        },
        websocket => sub {
            my ($websocket) = @_;
            push @$seen, {
                label => 'websocket',
                routing => routing_match_projection($websocket),
            };
            return $websocket->close(1000, 'representative');
        },
        sse => sub {
            my ($sse) = @_;
            push @$seen, {
                label => 'sse',
                routing => routing_match_projection($sse),
            };
            return $sse->close;
        },
    };
}

sub build_functional_representative {
    my ($seen) = @_;
    my $handler = representative_handlers($seen);
    my $child = router(
        desc => 'Child routes',
        routes => [
            route('/detail/{child_id}' => $handler->{mounted},
                name => 'detail', desc => 'Mounted detail'),
        ],
    );
    return router(
        desc => 'Representative routes',
        routes => [
            route('/resource/{id}' => $handler->{post},
                methods => 'POST', name => 'post_resource',
                desc => 'POST resource'),
            route('/resource/{id}' => $handler->{get},
                methods => 'GET', name => 'get_resource',
                desc => 'GET resource'),
            mount('/api/{tenant}', app => $child,
                name => 'api', desc => 'API boundary'),
            websocket('/socket/{room}' => $handler->{websocket},
                name => 'socket', desc => 'Socket route'),
            sse('/events/{stream}' => $handler->{sse},
                name => 'events', desc => 'Event route'),
        ],
    );
}

sub build_app_representative {
    my ($seen) = @_;
    my $handler = representative_handlers($seen);
    my $child = PAGI::App::Router->new(desc => 'Child routes');
    $child->get('/detail/{child_id}' => $handler->{mounted})
        ->name('detail')->desc('Mounted detail');

    my $builder = PAGI::App::Router->new(desc => 'Representative routes');
    $builder->post('/resource/{id}' => $handler->{post})
        ->name('post_resource')->desc('POST resource');
    $builder->get('/resource/{id}' => $handler->{get})
        ->name('get_resource')->desc('GET resource');
    $builder->mount('/api/{tenant}', app => $child->to_router)
        ->name('api')->desc('API boundary');
    $builder->websocket('/socket/{room}' => $handler->{websocket})
        ->name('socket')->desc('Socket route');
    $builder->sse('/events/{stream}' => $handler->{sse})
        ->name('events')->desc('Event route');
    return $builder->to_router;
}

sub immutable_router_projection;

sub immutable_node_projection {
    my ($node) = @_;
    my $projection = {
        kind => $node->kind,
        path => $node->path,
        name => $node->name,
        desc => $node->desc,
        methods => $node->methods,
    };
    my $child = $node->can('app') && blessed($node->app)
        && $node->app->isa('PAGI::Routing::Router') ? $node->app : undef;
    $projection->{router} = immutable_router_projection($child)
        if defined $child;
    return $projection;
}

sub immutable_router_projection {
    my ($routing) = @_;
    return {
        desc => $routing->desc,
        routes => [map { immutable_node_projection($_) } @{$routing->routes}],
    };
}

sub exercise_representative {
    my ($routing, $seen) = @_;
    my $app = compose(router => $routing)->to_app;
    my $full = run_scope($app, scope(path => '/resource/7'));
    my $partial = run_scope($app, scope(
        method => 'DELETE', path => '/resource/7'));
    my $head = run_scope($app, scope(
        method => 'HEAD', path => '/resource/7'));
    my $mounted = run_scope($app, scope(
        path => '/api/acme/detail/9'));
    my $socket = run_scope($app, scope(
        type => 'websocket', method => undef, path => '/socket/lobby'));
    my $events = run_scope($app, scope(
        type => 'sse', method => undef, path => '/events/news'));
    return {
        full => [response_status($full), response_body($full)],
        partial => [response_status($partial), response_header($partial, 'Allow')],
        head => [response_status($head), response_body($head)],
        mounted => [response_status($mounted), response_body($mounted)],
        websocket => $socket,
        sse => $events,
        seen => $seen,
    };
}

sub native_app {
    my ($label, $seen) = @_;
    return sub {
        my ($request_scope, $receive, $send) = @_;
        push @$seen, {
            label     => $label,
            scope     => $request_scope,
            receive   => $receive,
            send      => $send,
            arg_count => scalar @_,
        } if $seen;
        $send->({ type => 'http.response.start', status => 200, headers => [] })->get;
        $send->({ type => 'http.response.body', body => $label, more => 0 })->get;
        return Future->done;
    };
}

sub channel_probe {
    my ($label, $seen) = @_;
    return sub {
        my ($request_scope, $receive, $send) = @_;
        push @$seen, {
            label     => $label,
            scope     => $request_scope,
            receive   => $receive,
            send      => $send,
            arg_count => scalar @_,
        };
        return Future->done;
    };
}

{
    package Local::UpgradeObjectMiddleware;
    sub new { return bless { trace => $_[1] }, $_[0] }
    sub wrap {
        my ($self, $inner) = @_;
        return sub {
            push @{$self->{trace}}, 'object';
            return $inner->(@_);
        };
    }
}

{
    package Local::UpgradeEndpoint;
    use parent 'PAGI::Endpoint::Router';

    sub new { return bless { trace => [] }, $_[0] }

    sub new_request {
        my $self = shift;
        ++$self->{manual_request_calls};
        return $self->SUPER::new_request(@_);
    }

    sub routes {
        my ($self, $r) = @_;
        my $middleware = $self->middleware_as('observe');
        $r->get('/state' => [$middleware] => 'show_state')->name('state');
        $r->websocket('/socket' => [$middleware] => 'socket')->name('socket');
        $r->sse('/events' => [$middleware] => 'events')->name('events');
    }

    sub observe {
        my ($self, $inner) = @_;
        return sub {
            my ($request_scope) = @_;
            push @{$self->{trace}}, $request_scope->{type};
            return $inner->(@_);
        };
    }

    sub show_state {
        my ($self, $request) = @_;
        $self->{seen_state} = $request->state;
        push @{$self->{compiled_protocols}}, ref($request);
        return PAGI::Response::Text->new(
            $request->has_state ? $request->state->get('phase') : 'empty',
        );
    }

    sub socket {
        push @{$_[0]{compiled_protocols}}, ref($_[1]);
        return Future->done;
    }

    sub events {
        push @{$_[0]{compiled_protocols}}, ref($_[1]);
        return Future->done;
    }
}

{
    package Local::UpgradeChildEndpoint;
    use parent 'PAGI::Endpoint::Router';
    sub routes { $_[1]->get('/item/{id}' => 'show')->name('show') }
    sub show {
        return PAGI::Response::Text->new('nested:' . $_[1]->path_param('id'));
    }
}

{
    package Local::UpgradeParentEndpoint;
    use parent 'PAGI::Endpoint::Router';
    sub new { return bless { child => $_[1] }, $_[0] }
    sub routes {
        my ($self, $r) = @_;
        $r->mount('/child', app => $self->{child}->to_router)->name('child');
    }
}

my @migration_cases = (
    {
        name => 'functional and App frontends describe and run one routing model',
        run  => sub {
            my (@functional_seen, @app_seen);
            my $functional = build_functional_representative(\@functional_seen);
            my $app = build_app_representative(\@app_seen);
            my $expected_projection = {
                desc => 'Representative routes',
                routes => [
                    {
                        kind => 'route', path => '/resource/{id}',
                        name => 'post_resource', desc => 'POST resource',
                        methods => ['POST'],
                    },
                    {
                        kind => 'route', path => '/resource/{id}',
                        name => 'get_resource', desc => 'GET resource',
                        methods => ['GET', 'HEAD'],
                    },
                    {
                        kind => 'mount', path => '/api/{tenant}', name => 'api',
                        desc => 'API boundary', methods => undef,
                        router => {
                            desc => 'Child routes',
                            routes => [{
                                kind => 'route', path => '/detail/{child_id}',
                                name => 'detail', desc => 'Mounted detail',
                                methods => ['GET', 'HEAD'],
                            }],
                        },
                    },
                    {
                        kind => 'websocket', path => '/socket/{room}',
                        name => 'socket', desc => 'Socket route',
                        methods => undef,
                    },
                    {
                        kind => 'sse', path => '/events/{stream}',
                        name => 'events', desc => 'Event route',
                        methods => undef,
                    },
                ],
            };
            is([
                immutable_router_projection($functional),
                immutable_router_projection($app),
            ], [$expected_projection, $expected_projection],
                'both frontends expose the same ordered public immutable-node projection');

            my $expected_behavior = {
                full => [207, 'get 7'],
                partial => [405, 'POST, GET, HEAD'],
                head => [207, ''],
                mounted => [200, 'acme:9'],
                websocket => [{
                    type => 'websocket.close', code => 1000,
                    reason => 'representative',
                }],
                sse => [{ type => 'sse.close' }],
                seen => [
                    {
                        label => 'get', request_method => 'GET',
                        routing => {
                            logical_namespace => '/', captures => { id => 7 },
                            mounts => [],
                            match => {
                                kind => 'route', route => '/resource/{id}',
                                name => '/get_resource', logical_namespace => '/',
                            },
                        },
                    },
                    {
                        label => 'get', request_method => 'HEAD',
                        routing => {
                            logical_namespace => '/', captures => { id => 7 },
                            mounts => [],
                            match => {
                                kind => 'route', route => '/resource/{id}',
                                name => '/get_resource', logical_namespace => '/',
                            },
                        },
                    },
                    {
                        label => 'mounted',
                        routing => {
                            logical_namespace => '/api',
                            captures => { tenant => 'acme', child_id => 9 },
                            mounts => [{
                                path => '/api/{tenant}', name => 'api',
                                desc => 'API boundary',
                            }],
                            match => {
                                kind => 'route',
                                route => '/api/{tenant}/detail/{child_id}',
                                name => '/api/detail', logical_namespace => '/api',
                            },
                        },
                    },
                    {
                        label => 'websocket',
                        routing => {
                            logical_namespace => '/', captures => { room => 'lobby' },
                            mounts => [],
                            match => {
                                kind => 'websocket', route => '/socket/{room}',
                                name => '/socket', logical_namespace => '/',
                            },
                        },
                    },
                    {
                        label => 'sse',
                        routing => {
                            logical_namespace => '/', captures => { stream => 'news' },
                            mounts => [],
                            match => {
                                kind => 'sse', route => '/events/{stream}',
                                name => '/events', logical_namespace => '/',
                            },
                        },
                    },
                ],
            };
            is([
                exercise_representative($functional, \@functional_seen),
                exercise_representative($app, \@app_seen),
            ], [$expected_behavior, $expected_behavior],
                'both frontends share FULL, PARTIAL/405, automatic HEAD, mount, protocol, and metadata behavior');
        },
    },
    {
        name => 'App HTTP handlers receive a Request',
        run  => sub {
            my $seen;
            my $router = PAGI::App::Router->new;
            $router->get('/context' => sub {
                my ($request) = @_;
                $seen = [ref($request), scalar @_];
                return PAGI::Response::Text->new('request');
            });
            my $events = run_scope($router->to_app, scope(path => '/context'));
            is($seen, ['PAGI::Request', 1],
                'ordinary handler receives exactly one HTTP Request');
            is(response_body($events), 'request', 'the compiler emits its Response');
        },
    },
    {
        name => 'as_app is the explicit native-channel Route form',
        run  => sub {
            my @seen;
            my $router = PAGI::App::Router->new;
            $router->get('/native' => as_app(native_app('native', \@seen)));
            is(response_body(run_scope($router->to_app, scope(path => '/native'))),
                'native', 'the application endpoint emits its native response');
            is($seen[0]{arg_count}, 3,
                'the application endpoint receives scope, receive, and send');
            is($seen[0]{scope}{path}, '/native',
                'the exact Route does not strip its matched path');
        },
    },
    {
        name => 'generic route is path-first with methods',
        run  => sub {
            my $router = PAGI::App::Router->new;
            $router->route('/resource' => sub {
                return PAGI::Response::Text->new('resource');
            },
                methods => ['GET', 'POST'])->name('resource');
            my $route = $router->to_router->route_named('/resource');
            is([$route->path, $route->methods],
                ['/resource', ['GET', 'HEAD', 'POST']],
                'path and normalized methods retain the path-first declaration');
        },
    },
    {
        name => 'routes Mount names use slash addresses',
        run  => sub {
            my $router = PAGI::App::Router->new;
            $router->mount('/api', routes => sub {
                $_[0]->get('/people/{id}' => sub {
                    return PAGI::Response::Text->new('person');
                })
                    ->name('show');
            })->name('api');
            is($router->path_for('/api/show', { id => 7 }), '/api/people/7',
                'Mount and leaf names form one slash address');
        },
    },
    {
        name => 'known mounts use name and expose child routes',
        run  => sub {
            my $child = PAGI::App::Router->new;
            $child->get('/people/{id}' => sub {
                return PAGI::Response::Text->new('person');
            })
                ->name('show');
            my $router = PAGI::App::Router->new;
            $router->mount('/api', app => $child->to_router)->name('api');
            is($router->path_for('/api/show', { id => 8 }), '/api/people/8',
                'name assigns the logical mount segment');
        },
    },
    {
        name => 'routes callbacks receive a fresh child builder',
        run  => sub {
            my ($child_identity, $child_class);
            my $router = PAGI::App::Router->new;
            $router->mount('/group', routes => sub {
                my ($child) = @_;
                $child_identity = refaddr($child);
                $child_class = ref($child);
                $child->get('/inside' => sub {
                    return PAGI::Response::Text->new('inside');
                });
            });
            isnt($child_identity, refaddr($router), 'the callback does not reuse its parent');
            is($child_class, 'PAGI::App::Router', 'the child is another public builder');
        },
    },
    {
        name => 'mutable mount targets use explicit immutable snapshots',
        run  => sub {
            my $child = Local::UpgradeChildEndpoint->new;
            my $router = PAGI::App::Router->new;
            $router->mount('/endpoint', app => $child->to_router)->name('endpoint');
            is($router->path_for('/endpoint/show', { id => 9 }), '/endpoint/item/9',
                'an explicitly materialized Endpoint Router is a known mount');
        },
    },
    {
        name => 'declaration order governs routes and mounts',
        run  => sub {
            my (@broad_seen, @specific_seen);
            my $router = PAGI::App::Router->new;
            $router->mount('/api', app => native_app('broad', \@broad_seen));
            $router->mount('/api/v2', app => native_app('specific', \@specific_seen));
            is(response_body(run_scope($router->to_app,
                scope(path => '/api/v2/items'))), 'broad',
                'the earlier broad mount owns the request');
            is([scalar @broad_seen, scalar @specific_seen], [1, 0],
                'the later longer prefix is not sorted ahead');

            my $mount_first = PAGI::App::Router->new;
            $mount_first->mount('/owned', app => native_app('mount', []));
            $mount_first->get('/owned' => sub {
                return PAGI::Response::Text->new('route');
            });
            is(response_body(run_scope($mount_first->to_app,
                scope(path => '/owned'))), 'mount',
                'an earlier mount owns before a later exact route');

            my $route_first = PAGI::App::Router->new;
            $route_first->get('/owned' => sub {
                return PAGI::Response::Text->new('route');
            });
            $route_first->mount('/owned', app => native_app('mount', []));
            is(response_body(run_scope($route_first->to_app,
                scope(path => '/owned'))), 'route',
                'an earlier exact route owns before a later mount');
        },
    },
    {
        name => 'middleware accepts all four universal forms',
        run  => sub {
            my @trace;
            my $factory = sub {
                my ($inner) = @_;
                return sub { push @trace, 'factory'; return $inner->(@_) };
            };
            my $object = Local::UpgradeObjectMiddleware->new(\@trace);
            my $explicit = middleware('+TestApps::FakeMiddleware');
            my $router = PAGI::App::Router->new;
            $router->get('/middleware' => [
                '+TestApps::FakeMiddleware', $factory, $object, $explicit,
            ] => sub {
                push @trace, 'handler';
                return PAGI::Response::Text->new('ok');
            })
                ->name('middleware');
            my $descriptions = $router->to_router
                ->route_named('/middleware')->middleware;
            is([map { ref($_) } @$descriptions],
                [('PAGI::Routing::Middleware') x 4],
                'class, factory, object, and explicit description all normalize');
            is(response_body(run_scope($router->to_app,
                scope(path => '/middleware'))), 'ok', 'the mixed list compiles');
            is(\@trace, ['factory', 'object', 'handler'],
                'native wrappers execute in listed onion order');

            my @positions = (
                ['router', 'http', sub {
                    my ($entry) = @_;
                    my $r = PAGI::App::Router->new(middleware => [$entry]);
                    $r->get('/boundary' => sub {
                        return PAGI::Response::Text->new('router');
                    });
                    return $r;
                }],
                ['routes Mount', 'http', sub {
                    my ($entry) = @_;
                    my $r = PAGI::App::Router->new;
                    $r->mount('/boundary', routes => sub {
                        $_[0]->get('/inside' => sub {
                            return PAGI::Response::Text->new('routes Mount');
                        });
                    }, middleware => [$entry]);
                    return $r;
                }],
                ['mount', 'http', sub {
                    my ($entry) = @_;
                    my $r = PAGI::App::Router->new;
                    $r->mount('/boundary',
                        app => channel_probe('mount', []),
                        middleware => [$entry]);
                    return $r;
                }],
                ['HTTP route', 'http', sub {
                    my ($entry) = @_;
                    my $r = PAGI::App::Router->new;
                    $r->get('/boundary' => [$entry] => sub {
                        return PAGI::Response::Text->new('http');
                    });
                    return $r;
                }],
                ['WebSocket route', 'websocket', sub {
                    my ($entry) = @_;
                    my $r = PAGI::App::Router->new;
                    $r->websocket('/boundary' => [$entry] => sub {
                        return Future->done;
                    });
                    return $r;
                }],
                ['SSE route', 'sse', sub {
                    my ($entry) = @_;
                    my $r = PAGI::App::Router->new;
                    $r->sse('/boundary' => [$entry] => sub {
                        return Future->done;
                    });
                    return $r;
                }],
            );

            for my $position (@positions) {
                my ($label, $type, $build) = @$position;
                my ($builds, @runs) = (0);
                my $entry = sub {
                    my ($inner) = @_;
                    ++$builds;
                    return sub {
                        push @runs, "$label:$_[0]{type}";
                        return $inner->(@_);
                    };
                };
                my $boundary_router = $build->($entry);
                my $path = $label eq 'routes Mount'
                    ? '/boundary/inside' : '/boundary';
                run_scope($boundary_router->to_app,
                    scope(type => $type, method => $type eq 'http' ? 'GET' : undef,
                        path => $path));
                is([$builds, \@runs], [1, ["$label:$type"]],
                    "$label accepts and executes the universal factory form");
            }
        },
    },
    {
        name => 'Endpoint middleware_as supplies native middleware',
        run  => sub {
            my $endpoint = Local::UpgradeEndpoint->new;
            is(response_body(run_scope($endpoint->to_app,
                scope(path => '/state'))), 'empty', 'Endpoint handler dispatches');
            is($endpoint->{trace}, ['http'],
                'the local factory wraps the native application call');
        },
    },
    {
        name => 'new_request is an explicit local helper only',
        run  => sub {
            my $endpoint = Local::UpgradeEndpoint->new;
            my $empty_app = sub { return Future->done };
            my ($events, $receive, $send) = run_scope_with_channels(
                $empty_app, scope(path => '/manual'));
            ok(!$endpoint->can('new_context'),
                'the removed Context helper has no compatibility alias');
            my $manual = $endpoint->new_request(
                scope(path => '/manual'), $receive,
            );
            isa_ok($manual, ['PAGI::Request'],
                'an explicit helper call constructs a strict HTTP Request');
            like(dies {
                $endpoint->new_request(scope(type => 'sse'), $receive);
            }, qr/HTTP scope/i, 'the explicit helper rejects an SSE scope');
            is([$endpoint->{manual_request_calls}, $events], [2, []],
                'calling the overridden helper performs no protocol I/O');

            my $app = $endpoint->to_app;
            run_scope($app, scope(path => '/state'));
            run_scope($app, scope(type => 'websocket', method => undef,
                path => '/socket'));
            run_scope($app, scope(type => 'sse', method => undef,
                path => '/events'));
            is($endpoint->{compiled_protocols}, [
                'PAGI::Request',
                'PAGI::WebSocket',
                'PAGI::SSE',
            ], 'compiled handlers receive shared direct protocol objects');
            is($endpoint->{manual_request_calls}, 2,
                'materialization and dispatch never call the local override');
        },
    },
    {
        name => 'Endpoint reads server-owned lifespan state through Request',
        run  => sub {
            my $endpoint = Local::UpgradeEndpoint->new;
            my $state = {};
            my $app = compose(
                router => $endpoint->to_router,
                lifespan => { startup => sub { $_[0]{phase} = 'ready' } },
            )->to_app;
            my @messages = (
                { type => 'lifespan.startup' },
                { type => 'lifespan.shutdown' },
            );
            $app->(
                scope(type => 'lifespan', state => $state),
                sub { return Future->done(shift @messages) },
                sub { return Future->done },
            )->get;
            is(response_body(run_scope($app,
                scope(path => '/state', state => $state))), 'ready',
                'startup state is visible to the route Request');
            is(refaddr($endpoint->{seen_state}->data), refaddr($state),
                'the Request State retains server state identity');
        },
    },
    {
        name => 'Endpoint objects nest through router mounts',
        run  => sub {
            my $child = Local::UpgradeChildEndpoint->new;
            my $parent = Local::UpgradeParentEndpoint->new($child);
            is($parent->to_router->path_for('/child/show', { id => 10 }),
                '/child/item/10', 'nested Endpoint names remain inspectable');
            is(response_body(run_scope($parent->to_app,
                scope(path => '/child/item/10'))), 'nested:10',
                'nested Endpoint dispatch stays inside shared routing');
        },
    },
    {
        name => 'route middleware is protocol-independent',
        run  => sub {
            my $endpoint = Local::UpgradeEndpoint->new;
            my $app = $endpoint->to_app;
            run_scope($app, scope(type => 'websocket', method => undef,
                path => '/socket'));
            run_scope($app, scope(type => 'sse', method => undef,
                path => '/events'));
            is($endpoint->{trace}, ['websocket', 'sse'],
                'one native middleware form wraps WebSocket and SSE routes');
        },
    },
    {
        name => 'matched metadata is published under pagi.routing',
        run  => sub {
            my $seen;
            my $child = PAGI::App::Router->new;
            $child->get('/items/{id}' => sub {
                my ($request) = @_;
                $seen = {
                    routing => $request->scope->{'pagi.routing'},
                    old     => $request->scope->{'pagi.router'},
                };
                return PAGI::Response::Text->new('metadata');
            })->name('show');
            my $router = PAGI::App::Router->new;
            $router->mount('/api/{tenant}', app => $child->to_router)->name('api');
            run_scope($router->to_app,
                scope(path => '/api/acme/items/42'));
            is($seen->{routing}{version}, 1, 'the routing container is versioned');
            is(ref($seen->{routing}{frames}), 'ARRAY',
                'the routing container exposes its frame stack');
            is(scalar @{$seen->{routing}{frames}}, 2,
                'an explicit child Router adds its selected owner frame');
            my $frame = $seen->{routing}{frames}[-1];
            is($frame->{logical_namespace}, '/api',
                'the frame records the effective logical namespace');
            is($frame->{captures}, { tenant => 'acme', id => '42' },
                'the frame records prefix and leaf captures');
            is([
                $frame->{match}{kind},
                $frame->{match}{route},
                $frame->{match}{name},
                $frame->{match}{logical_namespace},
            ], [
                'route', '/api/{tenant}/items/{id}', '/api/show', '/api',
            ], 'the frame identifies the effective selected leaf');
            is($frame->{mounts}, [{
                path => '/api/{tenant}', name => 'api', desc => undef,
            }], 'the frame retains inspectable mount ancestry');
            ok(!defined $seen->{old}, 'the removed metadata key is not published');
        },
    },
    {
        name => 'path_for validates constraints and percent-encodes values',
        run  => sub {
            my $router = PAGI::App::Router->new;
            $router->get('/people/{id}' => sub {
                return PAGI::Response::Text->new('person');
            })
                ->name('show')->constraints(id => qr/\A\d+\z/);
            $router->get('/tags/{name}' => sub {
                return PAGI::Response::Text->new('tag');
            })
                ->name('tag')->constraints(name => qr/\A[[:print:]]+\z/);
            is($router->path_for('/show', { id => 42 }, { q => 'a b' }),
                '/people/42?q=a%20b', 'valid parameters and query values render safely');
            is($router->path_for('/tag',
                { name => 'Perl tools' },
                { from => 'upgrade guide' },
                'examples one'),
                '/tags/Perl%20tools?from=upgrade%20guide#examples%20one',
                'path, query, and fragment values are percent-encoded');
            like(dies { $router->path_for('/show', { id => 'forty two' }) },
                qr/failed constraint/, 'invalid reverse parameters fail before rendering');
        },
    },
    {
        name => 'to_router returns stable retained snapshots',
        run  => sub {
            my $router = PAGI::App::Router->new;
            $router->get('/one' => sub {
                return PAGI::Response::Text->new('one');
            })->name('one');
            my $first = $router->to_router;
            my $second = $router->to_router;
            isnt(refaddr($first), refaddr($second), 'each materialization is fresh');
            $router->get('/two' => sub {
                return PAGI::Response::Text->new('two');
            })->name('two');
            ok(!defined $first->route_named('/two'),
                'a retained snapshot is isolated from later builder changes');
            is($first->path_for('/one'), '/one',
                'inspection on one retained snapshot stays internally stable');
        },
    },
    {
        name => 'application Routes and opaque Mounts have different ownership',
        run  => sub {
            my (@route_seen, @mount_seen);
            my $router = PAGI::App::Router->new;
            $router->get('/native-http/{id}' =>
                as_app(channel_probe('native-http', \@route_seen)))
                ->name('native_http');
            $router->websocket('/native-ws/{room}' =>
                as_app(channel_probe('native-ws', \@route_seen)))
                ->name('native_ws');
            $router->sse('/native-sse/{channel}' =>
                as_app(channel_probe('native-sse', \@route_seen)))
                ->name('native_sse');
            $router->mount('/opaque/{tenant}',
                app => channel_probe('mount', \@mount_seen));

            my $routing = $router->to_router;
            is([map { $routing->route_named($_)->kind }
                    qw(/native_http /native_ws /native_sse)],
                [qw(route websocket sse)],
                'application leaves remain visible with their protocol kinds');
            ok(!defined $routing->route_named('/opaque/hidden'),
                'opaque mount internals are not inspectable');

            my $app = $routing->to_app;
            my ($http_events, $http_receive, $http_send) =
                run_scope_with_channels($app, scope(
                    method => 'GET', path => '/native-http/7', root_path => '/edge'));
            my ($ws_events, $ws_receive, $ws_send) =
                run_scope_with_channels($app, scope(
                    type => 'websocket', method => undef,
                    path => '/native-ws/lobby', root_path => '/edge'));
            my ($sse_events, $sse_receive, $sse_send) =
                run_scope_with_channels($app, scope(
                    type => 'sse', method => undef,
                    path => '/native-sse/news', root_path => '/edge'));

            is([map { [$_->{label}, $_->{scope}{type}, $_->{arg_count}] }
                    @route_seen], [
                    ['native-http', 'http', 3],
                    ['native-ws', 'websocket', 3],
                    ['native-sse', 'sse', 3],
                ], 'application-valued HTTP, WebSocket, and SSE Routes own native channels');
            is([map { refaddr($_->{receive}) } @route_seen], [
                refaddr($http_receive),
                refaddr($ws_receive),
                refaddr($sse_receive),
            ], 'application Routes receive the exact supplied receive channels');
            ok((grep { ref($_->{send}) eq 'CODE' } @route_seen) == 3,
                'application Routes receive the Router-owned send boundary');
            is([map { [$_->{scope}{path}, $_->{scope}{root_path}] } @route_seen], [
                ['/native-http/7', '/edge'],
                ['/native-ws/lobby', '/edge'],
                ['/native-sse/news', '/edge'],
            ], 'application Routes preserve path and root_path');
            is([$http_events, $ws_events, $sse_events], [[], [], []],
                'the application probes own events without response adaptation');

            is([map {
                    my $frame = $_->{scope}{'pagi.routing'}{frames}[-1];
                    [$frame->{match}{kind}, $frame->{match}{name}]
                } @route_seen], [
                    ['route', '/native_http'],
                    ['websocket', '/native_ws'],
                    ['sse', '/native_sse'],
                ], 'application Routes publish selected leaf metadata');

            my $wrong = run_scope($app, scope(
                method => 'POST', path => '/native-http/7'));
            is(response_status($wrong), 405,
                'application-Route method exhaustion emits the built-in 405');
            is(response_header($wrong, 'Allow'), 'GET, HEAD',
                'the default GET application Route contributes automatic HEAD');
            is(scalar @route_seen, 3,
                'the wrong-method request never invokes the application endpoint');

            run_scope($app, scope(method => 'POST',
                path => '/opaque/acme/http', root_path => '/edge'));
            run_scope($app, scope(type => 'websocket', method => undef,
                path => '/opaque/acme/socket', root_path => '/edge'));
            run_scope($app, scope(type => 'sse', method => undef,
                path => '/opaque/acme/events', root_path => '/edge'));
            is([map { $_->{scope}{type} } @mount_seen],
                [qw(http websocket sse)],
                'opaque mount owns its prefix for all three protocols');
            is([map { [$_->{scope}{path}, $_->{scope}{root_path}] }
                    @mount_seen], [
                    ['/http', '/edge/opaque/acme'],
                    ['/socket', '/edge/opaque/acme'],
                    ['/events', '/edge/opaque/acme'],
                ], 'opaque mount strips its prefix and extends root_path');
            is([map {
                    my $frame = $_->{scope}{'pagi.routing'}{frames}[-1];
                    [$frame->{match}{kind}, $frame->{match}{route},
                        $frame->{captures}{tenant}]
                } @mount_seen], [
                    ['mount', '/opaque/{tenant}', 'acme'],
                    ['mount', '/opaque/{tenant}', 'acme'],
                    ['mount', '/opaque/{tenant}', 'acme'],
                ], 'opaque metadata stops at the matched mount boundary');
        },
    },
);

for my $case (@migration_cases) {
    subtest $case->{name} => $case->{run};
}

subtest 'removed compatibility surface stays absent' => sub {
    ok(!PAGI::App::Router->can('uri_for'), 'App Router has no uri_for alias');
    my $child = PAGI::App::Router->new;
    my $router = PAGI::App::Router->new;
    my $declaration_result = $router->mount(
        '/child', app => $child->to_router,
    );
    is(refaddr($declaration_result), refaddr($router),
        'a declaration returns its App Router builder');
    ok(!$declaration_result->can('as'),
        'the declaration result has no removed as modifier');
    $declaration_result->name('child');
    ok(!$router->can('group'), 'App Router has no group method');
    ok(!PAGI::App::Router->can('namespace'), 'App Router has no public namespace');
    ok(!PAGI::Routing::Mount->can('namespace'), 'Mount has no public namespace accessor');
    ok(!PAGI::Endpoint::Router->can('state'), 'Endpoint has no state method');
    ok(!PAGI::Endpoint::Router->can('context_class'),
        'Endpoint has no context_class hook');
};

subtest 'Compose retains an explicit Endpoint Router snapshot' => sub {
    my $endpoint = Local::UpgradeEndpoint->new;

    like(dies { compose(router => $endpoint) },
        qr/instantiated PAGI::Routing::Router/,
        'Compose does not guess Endpoint frontend materialization');

    my $routing = $endpoint->to_router;
    my $root = compose(router => $routing);
    is(refaddr($root->router), refaddr($routing),
        'explicit Endpoint Router snapshot is retained');
};

done_testing;
