#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Scalar::Util qw(refaddr);
use TestApps::FakeMiddleware;
use PAGI::Routing qw(router route websocket sse mount middleware);

{
    package Local::ConfiguredMiddleware;
    sub new { return bless { wraps => 0 }, $_[0] }
    sub wraps { return $_[0]->{wraps} }
    sub wrap {
        my ($self, $inner) = @_;
        ++$self->{wraps};
        return sub { return $inner->(@_) };
    }
}

sub scope {
    my (%change) = @_;
    return {
        type        => 'http',
        method      => 'GET',
        path        => '/',
        root_path   => '',
        raw_path    => '/',
        path_params => {},
        headers     => [],
        %change,
    };
}

sub run_scope {
    my ($app, $request_scope) = @_;
    my @events;
    $app->(
        $request_scope,
        sub { return Future->done({ type => 'unused.receive' }) },
        sub { push @events, $_[0]; return Future->done },
    )->get;
    return \@events;
}

sub tracing_factory {
    my ($label, $builds, $runs) = @_;
    return sub {
        my ($inner) = @_;
        push @$builds, $label;
        return sub {
            my ($request_scope, $receive, $send) = @_;
            push @$runs, "$label:$request_scope->{type}";
            return $inner->($request_scope, $receive, $send);
        };
    };
}

subtest 'all four middleware entry forms normalize without protocol work' => sub {
    my $factory = sub { my ($inner) = @_; return $inner };
    my $object = Local::ConfiguredMiddleware->new;
    my $explicit = middleware('^TestApps::FakeMiddleware');
    my $class_constructions = 0;

    no warnings 'redefine';
    local *TestApps::FakeMiddleware::new = sub {
        ++$class_constructions;
        return bless {}, 'TestApps::FakeMiddleware';
    };

    my $child = router(routes => []);
    my @forms = (
        ['Router', sub { return router(routes => [], middleware => $_[0]) }],
        ['HTTP route', sub { return route('/http' => sub { return $_[0]->text('ok') }, middleware => $_[0]) }],
        ['WebSocket route', sub { return websocket('/socket' => async sub { await $_[0]->close }, middleware => $_[0]) }],
        ['SSE route', sub { return sse('/events' => async sub { await $_[0]->close }, middleware => $_[0]) }],
        ['inline mount', sub { return mount('/inline', routes => [], middleware => $_[0]) }],
        ['Router mount', sub { return mount('/router', router => $child, name => 'child', middleware => $_[0]) }],
        ['opaque mount', sub { return mount('/opaque' => sub { return }, middleware => $_[0]) }],
    );

    for my $form (@forms) {
        my ($label, $build) = @$form;
        my $entries = [
            '^TestApps::FakeMiddleware',
            $factory,
            $object,
            $explicit,
        ];
        my $description = $build->($entries);
        my $normalized = $description->middleware;

        isnt(refaddr($normalized), refaddr($entries), "$label copies its middleware list");
        is(scalar @$normalized, 4, "$label normalizes every entry");
        isa_ok($normalized->[0], ['PAGI::Routing::Middleware'], "$label normalizes a class name");
        is($normalized->[0]->factory, $entries->[0], "$label retains class target value");
        is(refaddr($normalized->[1]->factory), refaddr($factory), "$label retains factory target identity");
        is(refaddr($normalized->[2]->factory), refaddr($object), "$label retains object target identity");
        is(refaddr($normalized->[3]), refaddr($explicit), "$label retains explicit descriptor identity");
    }

    is($class_constructions, 0, 'normalization does not construct direct classes');
    is($object->wraps, 0, 'normalization does not wrap direct objects');
};

subtest 'router, inline mount, and HTTP route factories keep nested order' => sub {
    my (@builds, @runs);
    my $router_factory = tracing_factory('router', \@builds, \@runs);
    my $mount_factory  = tracing_factory('mount',  \@builds, \@runs);
    my $route_factory  = tracing_factory('route',  \@builds, \@runs);
    my $app = router(
        middleware => [$router_factory],
        routes => [
            mount('/api', routes => [
                route('/item' => sub {
                    push @runs, 'handler:http';
                    return $_[0]->text('ok');
                }, middleware => [$route_factory]),
            ], middleware => [$mount_factory]),
        ],
    )->to_app;

    is(\@builds, [qw(route mount router)],
        'compilation folds inner boundaries before outer boundaries');
    run_scope($app, scope(path => '/api/item', raw_path => '/api/item'));
    is(\@runs, [qw(router:http mount:http route:http handler:http)],
        'first visible execution proceeds outermost to handler');
};

subtest 'opaque mount, WebSocket, and SSE accept bare factories' => sub {
    my (@builds, @runs);
    my $opaque = tracing_factory('opaque', \@builds, \@runs);
    my $ws = tracing_factory('ws', \@builds, \@runs);
    my $events = tracing_factory('sse', \@builds, \@runs);
    my $app = router(routes => [
        mount('/opaque' => async sub {
            my ($request_scope, $receive, $send) = @_;
            await $send->({ type => 'http.response.start', status => 204, headers => [] });
            await $send->({ type => 'http.response.body', body => '', more => 0 });
        }, middleware => [$opaque]),
        websocket('/socket' => async sub {
            push @runs, 'handler:websocket';
            await $_[0]->close(1000, 'done');
        }, middleware => [$ws]),
        sse('/events' => async sub {
            push @runs, 'handler:sse';
            await $_[0]->close;
        }, middleware => [$events]),
    ])->to_app;

    run_scope($app, scope(path => '/opaque', raw_path => '/opaque'));
    run_scope($app, scope(type => 'websocket', path => '/socket', raw_path => '/socket'));
    run_scope($app, scope(type => 'sse', path => '/events', raw_path => '/events'));
    is(\@runs, [
        'opaque:http',
        'ws:websocket', 'handler:websocket',
        'sse:sse', 'handler:sse',
    ], 'each protocol and opaque boundary executes its bare factory wrapper');
};

subtest 'bare router factory surrounds unanswered routing and mixed lists retain order' => sub {
    my (@statuses, @runs);
    my $observer = sub {
        my ($inner) = @_;
        return sub {
            my ($request_scope, $receive, $send) = @_;
            push @runs, 'bare';
            my $observing_send = sub {
                my ($event) = @_;
                push @statuses, $event->{status}
                    if ($event->{type} // '') eq 'http.response.start';
                return $send->($event);
            };
            return $inner->($request_scope, $receive, $observing_send);
        };
    };
    my $explicit = middleware(sub {
        my ($inner) = @_;
        return sub { push @runs, 'explicit'; return $inner->(@_) };
    });
    my $app = router(
        routes => [route('/present' => sub { return $_[0]->text('present') })],
        middleware => [$observer, $explicit],
    )->to_app;

    run_scope($app, scope(path => '/missing'));
    run_scope($app, scope(method => 'POST', path => '/present'));
    is(\@runs, [qw(bare explicit bare explicit)],
        'mixed bare and explicit list keeps first-listed-outermost order');
    is(\@statuses, [], 'unanswered Router exhaustion emits no statuses');
};

subtest 'bare factory timing and failures remain compile-time behavior' => sub {
    my $builds = 0;
    my $description = route('/fresh' => sub { return $_[0]->text('fresh') },
        middleware => [sub { ++$builds; return $_[0] }]);
    my $one = $description->to_app;
    my $two = $description->to_app;
    is($builds, 2, 'each to_app creates a fresh wrapper occurrence');
    run_scope($one, scope(path => '/fresh'));
    run_scope($two, scope(path => '/fresh'));
    is($builds, 2, 'requests do not rerun the factory');

    like dies {
        route('/bad' => sub { return $_[0]->text('bad') },
            middleware => [sub { return 'not an app' }])->to_app
    }, qr/middleware factory must return PAGI app coderef/,
        'invalid bare factory result fails at to_app';
    like dies {
        router(routes => [], middleware => [sub {
            return Future->done(sub { })
        }])->to_app
    }, qr/middleware factory must return PAGI app coderef.*Future/,
        'accidentally async bare factory remains invalid';
};

subtest 'mixed direct entry forms resolve only while compiling and retain order' => sub {
    my @trace;
    my $factory_calls = 0;
    my $class_constructions = 0;
    my $class_wraps = 0;
    my $factory = sub {
        my ($inner) = @_;
        ++$factory_calls;
        return sub { push @trace, 'factory'; return $inner->(@_) };
    };
    my $object = bless { wraps => 0 }, 'Local::ConfiguredMiddleware';
    my $explicit = middleware('^TestApps::FakeMiddleware');

    no warnings 'redefine';
    local *Local::ConfiguredMiddleware::wrap = sub {
        my ($self, $inner) = @_;
        ++$self->{wraps};
        return sub { push @trace, 'object'; return $inner->(@_) };
    };
    local *TestApps::FakeMiddleware::new = sub {
        ++$class_constructions;
        return bless {}, 'TestApps::FakeMiddleware';
    };
    local *TestApps::FakeMiddleware::wrap = sub {
        my ($self, $inner) = @_;
        ++$class_wraps;
        return sub { push @trace, 'class'; return $inner->(@_) };
    };

    my $description = route('/mixed' => sub {
        push @trace, 'handler';
        return $_[0]->text('mixed');
    }, middleware => [
        '^TestApps::FakeMiddleware',
        $factory,
        $object,
        $explicit,
    ]);
    is($class_constructions, 0, 'class is not constructed before to_app');
    is($object->{wraps}, 0, 'object is not wrapped before to_app');
    is($factory_calls, 0, 'factory is not called before to_app');

    my $one = $description->to_app;
    my $two = $description->to_app;
    is($class_constructions, 4, 'class constructor runs once per compiled class occurrence');
    is($class_wraps, 4, 'class wrappers run once per compiled class occurrence');
    is($object->{wraps}, 2, 'object wrapper runs once per compiled occurrence');
    is($factory_calls, 2, 'factory runs once per compiled occurrence');

    run_scope($one, scope(path => '/mixed'));
    run_scope($two, scope(path => '/mixed'));
    is($class_constructions, 4, 'requests do not construct classes again');
    is($class_wraps, 4, 'requests do not wrap classes again');
    is($object->{wraps}, 2, 'requests do not wrap objects again');
    is($factory_calls, 2, 'requests do not rerun factories');
    is(\@trace, [
        qw(class factory object class handler class factory object class handler),
    ], 'the first listed middleware remains outermost at runtime');

    {
        local *TestApps::FakeMiddleware::wrap = sub { return 'not an app' };
        like dies {
            route('/invalid-class' => sub { return $_[0]->text('bad') }, middleware => [
                '^TestApps::FakeMiddleware',
            ])->to_app
        }, qr/middleware wrap must return PAGI app coderef/,
            'a direct class returning a non-coderef fails during compilation';
    }
};

done_testing;
