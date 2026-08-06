#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use PAGI::Routing qw(router route websocket sse mount middleware);

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

subtest 'bare router factory sees generated outcomes and mixed lists retain order' => sub {
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
    is(\@statuses, [404, 405], 'router wrapper sees both generated outcomes');
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

done_testing;
