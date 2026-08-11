#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Scalar::Util qw(refaddr);

use lib 'lib', 't/lib';
use PAGI::App::Router;
use PAGI::Compose qw(compose);
use PAGI::Endpoint::Router ();
use PAGI::Routing qw(middleware route router);

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

    sub new_context {
        my $self = shift;
        ++$self->{manual_context_calls};
        return $self->SUPER::new_context(@_);
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
        my ($self, $c) = @_;
        $self->{seen_state} = $c->state;
        push @{$self->{compiled_contexts}}, ref($c);
        return $c->text(defined $c->state->{phase} ? $c->state->{phase} : 'empty');
    }

    sub socket {
        push @{$_[0]{compiled_contexts}}, ref($_[1]);
        return Future->done;
    }

    sub events {
        push @{$_[0]{compiled_contexts}}, ref($_[1]);
        return Future->done;
    }
}

{
    package Local::UpgradeChildEndpoint;
    use parent 'PAGI::Endpoint::Router';
    sub routes { $_[1]->get('/item/{id}' => 'show')->name('show') }
    sub show { return $_[1]->text('nested:' . $_[1]->path_param('id')) }
}

{
    package Local::UpgradeParentEndpoint;
    use parent 'PAGI::Endpoint::Router';
    sub new { return bless { child => $_[1] }, $_[0] }
    sub routes {
        my ($self, $r) = @_;
        $r->mount('/child', router => $self->{child})->name('child');
    }
}

my @migration_cases = (
    {
        name => 'three public frontends materialize one routing model',
        run  => sub {
            my $immutable = router(routes => [
                route('/direct' => sub { return $_[0]->text('direct') }),
            ]);
            my $builder = PAGI::App::Router->new;
            $builder->get('/builder' => sub { return $_[0]->text('builder') });
            my $endpoint = Local::UpgradeEndpoint->new;
            is([
                ref($immutable),
                ref($builder->to_router),
                ref($endpoint->to_router),
            ], [('PAGI::Routing::Router') x 3],
                'functional, closure, and method frontends share Router snapshots');
        },
    },
    {
        name => 'App HTTP handlers receive a Context',
        run  => sub {
            my $seen;
            my $router = PAGI::App::Router->new;
            $router->get('/context' => sub {
                my ($c) = @_;
                $seen = [ref($c), scalar @_];
                return $c->text('context');
            });
            my $events = run_scope($router->to_app, scope(path => '/context'));
            is($seen, ['PAGI::Context::HTTP', 1],
                'ordinary handler receives exactly one HTTP Context');
            is(response_body($events), 'context', 'the compiler emits its Response');
        },
    },
    {
        name => 'raw is an explicit native-channel route form',
        run  => sub {
            my @seen;
            my $router = PAGI::App::Router->new;
            $router->get('/raw' => raw => native_app('raw', \@seen));
            is(response_body(run_scope($router->to_app, scope(path => '/raw'))),
                'raw', 'the raw target emits its native response');
            is($seen[0]{arg_count}, 3, 'raw receives scope, receive, and send');
            is($seen[0]{scope}{path}, '/raw', 'raw does not strip its matched path');
        },
    },
    {
        name => 'generic route is path-first with methods',
        run  => sub {
            my $router = PAGI::App::Router->new;
            $router->route('/resource' => sub { return $_[0]->text('resource') },
                methods => ['GET', 'POST'])->name('resource');
            my $route = $router->to_router->route_named('/resource');
            is([$route->path, $route->methods],
                ['/resource', ['GET', 'HEAD', 'POST']],
                'path and normalized methods retain the path-first declaration');
        },
    },
    {
        name => 'nested names use slash addresses',
        run  => sub {
            my $router = PAGI::App::Router->new;
            $router->group('/api' => sub {
                $_[0]->get('/people/{id}' => sub { return $_[0]->text('person') })
                    ->name('show');
            })->name('api');
            is($router->path_for('/api/show', { id => 7 }), '/api/people/7',
                'group and leaf names form one slash address');
        },
    },
    {
        name => 'known mounts use name and expose child routes',
        run  => sub {
            my $child = PAGI::App::Router->new;
            $child->get('/people/{id}' => sub { return $_[0]->text('person') })
                ->name('show');
            my $router = PAGI::App::Router->new;
            $router->mount('/api', router => $child)->name('api');
            is($router->path_for('/api/show', { id => 8 }), '/api/people/8',
                'name assigns the logical mount segment');
        },
    },
    {
        name => 'group callbacks receive a fresh child builder',
        run  => sub {
            my ($child_identity, $child_class);
            my $router = PAGI::App::Router->new;
            $router->group('/group' => sub {
                my ($child) = @_;
                $child_identity = refaddr($child);
                $child_class = ref($child);
                $child->get('/inside' => sub { return $_[0]->text('inside') });
            });
            isnt($child_identity, refaddr($router), 'the callback does not reuse its parent');
            is($child_class, 'PAGI::App::Router', 'the child is another public builder');
        },
    },
    {
        name => 'mutable mount targets are constructed objects',
        run  => sub {
            my $child = Local::UpgradeChildEndpoint->new;
            my $router = PAGI::App::Router->new;
            $router->mount('/endpoint', router => $child)->name('endpoint');
            is($router->path_for('/endpoint/show', { id => 9 }), '/endpoint/item/9',
                'an explicitly constructed Endpoint object materializes as a known mount');
        },
    },
    {
        name => 'declaration order governs routes and mounts',
        run  => sub {
            my (@broad_seen, @specific_seen);
            my $router = PAGI::App::Router->new;
            $router->mount('/api' => native_app('broad', \@broad_seen));
            $router->mount('/api/v2' => native_app('specific', \@specific_seen));
            is(response_body(run_scope($router->to_app,
                scope(path => '/api/v2/items'))), 'broad',
                'the earlier broad mount owns the request');
            is([scalar @broad_seen, scalar @specific_seen], [1, 0],
                'the later longer prefix is not sorted ahead');

            my $mount_first = PAGI::App::Router->new;
            $mount_first->mount('/owned' => native_app('mount', []));
            $mount_first->get('/owned' => sub { return $_[0]->text('route') });
            is(response_body(run_scope($mount_first->to_app,
                scope(path => '/owned'))), 'mount',
                'an earlier mount owns before a later exact route');

            my $route_first = PAGI::App::Router->new;
            $route_first->get('/owned' => sub { return $_[0]->text('route') });
            $route_first->mount('/owned' => native_app('mount', []));
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
            my $explicit = middleware('^TestApps::FakeMiddleware');
            my $router = PAGI::App::Router->new;
            $router->get('/middleware' => [
                '^TestApps::FakeMiddleware', $factory, $object, $explicit,
            ] => sub { push @trace, 'handler'; return $_[0]->text('ok') })
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
                    $r->get('/boundary' => sub { return $_[0]->text('router') });
                    return $r;
                }],
                ['group', 'http', sub {
                    my ($entry) = @_;
                    my $r = PAGI::App::Router->new;
                    $r->group('/boundary' => [$entry] => sub {
                        $_[0]->get('/inside' => sub { return $_[0]->text('group') });
                    });
                    return $r;
                }],
                ['mount', 'http', sub {
                    my ($entry) = @_;
                    my $r = PAGI::App::Router->new;
                    $r->mount('/boundary' => [$entry] => channel_probe('mount', []));
                    return $r;
                }],
                ['HTTP route', 'http', sub {
                    my ($entry) = @_;
                    my $r = PAGI::App::Router->new;
                    $r->get('/boundary' => [$entry] => sub {
                        return $_[0]->text('http');
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
                my $path = $label eq 'group' ? '/boundary/inside' : '/boundary';
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
        name => 'new_context is an explicit local helper only',
        run  => sub {
            my $endpoint = Local::UpgradeEndpoint->new;
            my $empty_app = sub { return Future->done };
            my ($events, $receive, $send) = run_scope_with_channels(
                $empty_app, scope(path => '/manual'));
            my $manual = $endpoint->new_context(
                scope(path => '/manual'), $receive, $send,
            );
            isa_ok($manual, ['PAGI::Context::HTTP'],
                'an explicit helper call selects the shared HTTP Context');
            is([$endpoint->{manual_context_calls}, $events], [1, []],
                'calling the overridden helper performs no protocol I/O');

            my $app = $endpoint->to_app;
            run_scope($app, scope(path => '/state'));
            run_scope($app, scope(type => 'websocket', method => undef,
                path => '/socket'));
            run_scope($app, scope(type => 'sse', method => undef,
                path => '/events'));
            is($endpoint->{compiled_contexts}, [
                'PAGI::Context::HTTP',
                'PAGI::Context::WebSocket',
                'PAGI::Context::SSE',
            ], 'compiled handlers receive shared protocol Contexts');
            is($endpoint->{manual_context_calls}, 1,
                'materialization and dispatch never call the local override');
        },
    },
    {
        name => 'Endpoint reads server-owned lifespan state through Context',
        run  => sub {
            my $endpoint = Local::UpgradeEndpoint->new;
            my $state = {};
            my $app = compose(
                app => $endpoint->to_app,
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
                'startup state is visible to the route Context');
            is(refaddr($endpoint->{seen_state}), refaddr($state),
                'the Context retains server state identity');
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
                my ($c) = @_;
                $seen = {
                    routing => $c->scope->{'pagi.routing'},
                    old     => $c->scope->{'pagi.router'},
                };
                return $c->text('metadata');
            })->name('show');
            my $router = PAGI::App::Router->new;
            $router->mount('/api/{tenant}', router => $child)->name('api');
            run_scope($router->to_app,
                scope(path => '/api/acme/items/42'));
            is($seen->{routing}{version}, 1, 'the routing container is versioned');
            is(ref($seen->{routing}{frames}), 'ARRAY',
                'the routing container exposes its frame stack');
            is(scalar @{$seen->{routing}{frames}}, 1,
                'a known mounted Router shares the current owner frame');
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
            $router->get('/people/{id}' => sub { return $_[0]->text('person') })
                ->name('show')->constraints(id => qr/\A\d+\z/);
            $router->get('/tags/{name}' => sub { return $_[0]->text('tag') })
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
            $router->get('/one' => sub { return $_[0]->text('one') })->name('one');
            my $first = $router->to_router;
            my $second = $router->to_router;
            isnt(refaddr($first), refaddr($second), 'each materialization is fresh');
            $router->get('/two' => sub { return $_[0]->text('two') })->name('two');
            ok(!defined $first->route_named('/two'),
                'a retained snapshot is isolated from later builder changes');
            is($first->path_for('/one'), '/one',
                'inspection on one retained snapshot stays internally stable');
        },
    },
    {
        name => 'raw routes and opaque mounts have different ownership',
        run  => sub {
            my (@raw_seen, @mount_seen);
            my $router = PAGI::App::Router->new;
            $router->get('/raw-http/{id}' => raw =>
                channel_probe('raw-http', \@raw_seen))->name('raw_http');
            $router->websocket('/raw-ws/{room}' => raw =>
                channel_probe('raw-ws', \@raw_seen))->name('raw_ws');
            $router->sse('/raw-sse/{channel}' => raw =>
                channel_probe('raw-sse', \@raw_seen))->name('raw_sse');
            $router->mount('/opaque/{tenant}' =>
                channel_probe('mount', \@mount_seen));

            my $routing = $router->to_router;
            is([map { $routing->route_named($_)->kind }
                    qw(/raw_http /raw_ws /raw_sse)],
                [qw(route websocket sse)],
                'raw leaves remain visible with their protocol kinds');
            ok(!defined $routing->route_named('/opaque/hidden'),
                'opaque mount internals are not inspectable');

            my $app = $routing->to_app;
            my ($http_events, $http_receive, $http_send) =
                run_scope_with_channels($app, scope(
                    method => 'GET', path => '/raw-http/7', root_path => '/edge'));
            my ($ws_events, $ws_receive, $ws_send) =
                run_scope_with_channels($app, scope(
                    type => 'websocket', method => undef,
                    path => '/raw-ws/lobby', root_path => '/edge'));
            my ($sse_events, $sse_receive, $sse_send) =
                run_scope_with_channels($app, scope(
                    type => 'sse', method => undef,
                    path => '/raw-sse/news', root_path => '/edge'));

            is([map { [$_->{label}, $_->{scope}{type}, $_->{arg_count}] }
                    @raw_seen], [
                    ['raw-http', 'http', 3],
                    ['raw-ws', 'websocket', 3],
                    ['raw-sse', 'sse', 3],
                ], 'explicit raw HTTP, WebSocket, and SSE own native channels');
            is([
                refaddr($raw_seen[0]{receive}), refaddr($raw_seen[0]{send}),
                refaddr($raw_seen[1]{receive}), refaddr($raw_seen[1]{send}),
                refaddr($raw_seen[2]{receive}), refaddr($raw_seen[2]{send}),
            ], [
                refaddr($http_receive), refaddr($http_send),
                refaddr($ws_receive), refaddr($ws_send),
                refaddr($sse_receive), refaddr($sse_send),
            ], 'raw leaves receive the exact supplied receive and send channels');
            is([map { [$_->{scope}{path}, $_->{scope}{root_path}] } @raw_seen], [
                ['/raw-http/7', '/edge'],
                ['/raw-ws/lobby', '/edge'],
                ['/raw-sse/news', '/edge'],
            ], 'raw leaves preserve path and root_path');
            is([$http_events, $ws_events, $sse_events], [[], [], []],
                'the raw probes own events without compiler response adaptation');

            is([map {
                    my $frame = $_->{scope}{'pagi.routing'}{frames}[-1];
                    [$frame->{match}{kind}, $frame->{match}{name}]
                } @raw_seen], [
                    ['route', '/raw_http'],
                    ['websocket', '/raw_ws'],
                    ['sse', '/raw_sse'],
                ], 'raw leaves publish selected leaf metadata');

            is(run_scope($app, scope(method => 'POST',
                    path => '/raw-http/7'))->[0]{status},
                405, 'raw HTTP remains method-aware');
            is(scalar @raw_seen, 3,
                'the wrong-method request never invokes the raw HTTP target');

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
    my $declaration_result = $router->mount('/child', router => $child);
    is(refaddr($declaration_result), refaddr($router),
        'a declaration returns its App Router builder');
    ok(!$declaration_result->can('as'),
        'the declaration result has no removed as modifier');
    $declaration_result->name('child');
    ok(!PAGI::App::Router->can('namespace'), 'App Router has no public namespace');
    ok(!PAGI::Routing::Mount->can('namespace'), 'Mount has no public namespace accessor');
    ok(!PAGI::Endpoint::Router->can('state'), 'Endpoint has no state method');
    ok(!PAGI::Endpoint::Router->can('context_class'),
        'Endpoint has no context_class hook');
};

done_testing;
