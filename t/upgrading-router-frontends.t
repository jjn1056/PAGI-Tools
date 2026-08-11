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

sub run_scope {
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
    return \@events;
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
        return $c->text(defined $c->state->{phase} ? $c->state->{phase} : 'empty');
    }

    sub socket { return Future->done }
    sub events { return Future->done }
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
        name => 'declaration order governs overlapping mounts',
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
            my $router = PAGI::App::Router->new;
            $router->get('/metadata' => sub {
                my ($c) = @_;
                $seen = {
                    routing => $c->scope->{'pagi.routing'},
                    old     => $c->scope->{'pagi.router'},
                };
                return $c->text('metadata');
            })->name('metadata');
            run_scope($router->to_app, scope(path => '/metadata'));
            is($seen->{routing}{version}, 1, 'the routing container is versioned');
            ok(!defined $seen->{old}, 'the removed metadata key is not published');
        },
    },
    {
        name => 'path_for validates constraints and percent-encodes values',
        run  => sub {
            my $router = PAGI::App::Router->new;
            $router->get('/people/{id}' => sub { return $_[0]->text('person') })
                ->name('show')->constraints(id => qr/\A\d+\z/);
            is($router->path_for('/show', { id => 42 }, { q => 'a b' }),
                '/people/42?q=a%20b', 'valid parameters and query values render safely');
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
            $router->get('/raw' => raw => native_app('raw', \@raw_seen));
            $router->mount('/opaque' => native_app('mount', \@mount_seen));
            my $app = $router->to_app;
            is(run_scope($app, scope(method => 'POST', path => '/raw'))
                    ->[0]{status},
                405, 'raw HTTP remains method-aware');
            is(response_body(run_scope($app,
                scope(method => 'POST', path => '/opaque/child'))),
                'mount', 'opaque mount owns a matching prefix for POST');
            is([$mount_seen[0]{scope}{path}, $mount_seen[0]{scope}{root_path}],
                ['/child', '/opaque'], 'mount rewrites path and root_path');
            is(scalar @raw_seen, 0, 'the wrong-method raw target was never invoked');
        },
    },
);

for my $case (@migration_cases) {
    subtest $case->{name} => $case->{run};
}

subtest 'removed compatibility surface stays absent' => sub {
    ok(!PAGI::App::Router->can('uri_for'), 'App Router has no uri_for alias');
    ok(!PAGI::App::Router->can('as'), 'App Router has no as alias');
    ok(!PAGI::App::Router->can('namespace'), 'App Router has no public namespace');
    ok(!PAGI::Routing::Mount->can('namespace'), 'Mount has no public namespace accessor');
    ok(!PAGI::Endpoint::Router->can('state'), 'Endpoint has no state method');
    ok(!PAGI::Endpoint::Router->can('context_class'),
        'Endpoint has no context_class hook');
};

done_testing;
