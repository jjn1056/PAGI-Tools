#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use PAGI::Response::Text ();
use PAGI::Routing qw(router route websocket sse mount middleware);

{
    package Local::ConfiguredMiddleware;
    sub new { return bless {}, $_[0] }
    sub wrap { return $_[1] }
}

{
    package Local::InvalidWrapMiddleware;
    sub new { return bless {}, $_[0] }
    sub wrap { return 'not an app' }
}

sub scope {
    my (%change) = @_;
    return {
        type => 'http', method => 'GET', path => '/', root_path => '',
        raw_path => '/', path_params => {}, headers => [], %change,
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
    my ($label, $trace) = @_;
    return sub {
        my ($inner) = @_;
        return sub {
            push @$trace, $label . ':' . ($_[0]{type} // '');
            return $inner->(@_);
        };
    };
}

subtest 'all core middleware boundaries reject bare entries' => sub {
    my $handler = sub { return PAGI::Response::Text->new('ok') };
    my @constructors = (
        ['Router', sub { router(routes => [], middleware => $_[0]) }],
        ['HTTP Route', sub { route('/http' => $handler, middleware => $_[0]) }],
        ['WebSocket Route', sub { websocket('/socket' => async sub { await $_[0]->close }, middleware => $_[0]) }],
        ['SSE Route', sub { sse('/events' => async sub { await $_[0]->close }, middleware => $_[0]) }],
        ['app Mount', sub { mount('/app', app => sub { return }, middleware => $_[0]) }],
        ['routes Mount', sub { mount('/routes', routes => [], middleware => $_[0]) }],
    );
    my @entries = (
        ['class', 'RequestId'],
        ['factory', sub { return $_[0] }],
        ['object', Local::ConfiguredMiddleware->new],
        ['hashref', {}],
    );
    for my $constructor (@constructors) {
        for my $entry (@entries) {
            like dies { $constructor->[1]->([$entry->[1]]) },
                qr/middleware entry 0 must be a PAGI::Routing::Middleware description returned by middleware\(\.\.\.\)/,
                "$constructor->[0] rejects bare $entry->[0]";
        }
    }
};

subtest 'explicit descriptions run across Route Mount Router and protocols' => sub {
    my @trace;
    my $app = router(
        middleware => [middleware(tracing_factory('router', \@trace))],
        routes => [
            mount('/api', middleware => [middleware(tracing_factory('mount', \@trace))], routes => [
                route('/item' => sub {
                    push @trace, 'handler:http';
                    return PAGI::Response::Text->new('ok');
                }, middleware => [middleware(tracing_factory('route', \@trace))]),
            ]),
            websocket('/socket' => async sub {
                push @trace, 'handler:websocket';
                await $_[0]->close;
            }, middleware => [middleware(tracing_factory('websocket', \@trace))]),
            sse('/events' => async sub {
                push @trace, 'handler:sse';
                await $_[0]->close;
            }, middleware => [middleware(tracing_factory('sse', \@trace))]),
        ],
    )->to_app;

    run_scope($app, scope(path => '/api/item', raw_path => '/api/item'));
    run_scope($app, scope(type => 'websocket', path => '/socket', raw_path => '/socket'));
    run_scope($app, scope(type => 'sse', path => '/events', raw_path => '/events'));
    is(\@trace, [
        'router:http', 'mount:http', 'route:http', 'handler:http',
        'router:websocket', 'websocket:websocket', 'handler:websocket',
        'router:sse', 'sse:sse', 'handler:sse',
    ], 'explicit descriptions keep outer-to-inner ordering for every protocol');
};

subtest 'first listed explicit description remains outermost' => sub {
    my @trace;
    my $app = route('/ordered' => sub {
        push @trace, 'handler';
        return PAGI::Response::Text->new('ok');
    }, middleware => [
        middleware(tracing_factory('outer', \@trace)),
        middleware(tracing_factory('inner', \@trace)),
    ])->to_app;
    run_scope($app, scope(path => '/ordered'));
    is(\@trace, [qw(outer:http inner:http handler)],
        'the first list entry executes outermost');
};

subtest 'invalid described factory and wrap results fail during to_app' => sub {
    like dies {
        route('/factory' => sub { return PAGI::Response::Text->new('ok') },
            middleware => [middleware(sub { return 'not an app' })])->to_app;
    }, qr/middleware factory must return a PAGI application value/,
        'invalid factory result fails at compilation';
    like dies {
        route('/future' => sub { return PAGI::Response::Text->new('ok') },
            middleware => [middleware(sub { return Future->done(sub { }) })])->to_app;
    }, qr/middleware factory must return a PAGI application value.*Future/,
        'Future factory result fails at compilation';
    like dies {
        route('/wrap' => sub { return PAGI::Response::Text->new('ok') },
            middleware => [middleware(Local::InvalidWrapMiddleware->new)])->to_app;
    }, qr/middleware wrap must return a PAGI application value/,
        'invalid wrap result fails at compilation';
};

done_testing;
