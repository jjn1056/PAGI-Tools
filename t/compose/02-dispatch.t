#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";
use ComposeTest qw(scope run_scope capture_send);
use PAGI::Compose qw(compose);
use PAGI::Response::Text ();
use PAGI::Routing qw(mount route websocket sse);
use PAGI::Utils qw(as_app);

subtest 'routes mode dispatches HTTP WebSocket and SSE' => sub {
    my $app = compose(routes => [
        route('/' => sub { return PAGI::Response::Text->new('home') }),
        websocket('/ws' => async sub {
            my ($c) = @_;
            await $c->accept;
            await $c->send_text('hello');
            await $c->close;
        }),
        sse('/events' => sub {
            my ($c) = @_;
            $c->start->get;
            $c->send('ready')->get;
            $c->close->get;
        }),
    ])->to_app;

    my $http = run_scope($app, scope(path => '/'));
    is([map { $_->{type} } @$http],
        [qw(http.response.start http.response.body)],
        'HTTP route emits one response pair');
    is($http->[0]{status}, 200, 'HTTP route status is retained');
    is($http->[1],
        { type => 'http.response.body', body => 'home', more => 0 },
        'HTTP route emits its returned response body');
    is(run_scope($app, scope(type => 'websocket', path => '/ws')), [
        { type => 'websocket.accept' },
        { type => 'websocket.send', text => 'hello' },
        { type => 'websocket.close', code => 1000, reason => '' },
    ], 'WebSocket route receives its direct protocol object');
    is(run_scope($app, scope(type => 'sse', path => '/events')), [
        { type => 'sse.start', status => 200 },
        { type => 'sse.send', data => 'ready' },
        { type => 'sse.close' },
    ], 'SSE route receives its direct protocol object');
};

{
    package Local::ComposeComponent;
    our $COMPILES = 0;
    sub new { return bless {}, $_[0] }
    sub to_app {
        ++$COMPILES;
        return sub {
            my ($scope, $receive, $send) = @_;
            $send->({
                type => 'http.response.start', status => 204, headers => [],
            })->get;
            return $send->({
                type => 'http.response.body', body => '', more => 0,
            });
        };
    }
}
{
    package Local::CountingRouter;
    use parent 'PAGI::Routing::Router';
    our $TO_APP_CALLS = 0;

    sub to_app {
        my ($self) = @_;
        ++$TO_APP_CALLS;
        return $self->SUPER::to_app;
    }
}

subtest 'retained Router compiles once per Compose to_app' => sub {
    local $Local::CountingRouter::TO_APP_CALLS = 0;
    my $routing = Local::CountingRouter->new(routes => [
        route('/' => sub { return PAGI::Response::Text->new('home') }),
    ]);
    my $description = compose(router => $routing);
    is($Local::CountingRouter::TO_APP_CALLS, 0,
        'Compose construction does not compile Router');
    my $app_one = $description->to_app;
    is($Local::CountingRouter::TO_APP_CALLS, 1,
        'first Compose to_app compiles retained Router once');
    my $app_two = $description->to_app;
    is($Local::CountingRouter::TO_APP_CALLS, 2,
        'second Compose to_app creates one fresh Router graph');
    my $one_events = run_scope($app_one, scope());
    is([$one_events->[0]{status}, $one_events->[1]{body}], [200, 'home'],
        'first compiled app dispatches independently');
    my $two_events = run_scope($app_two, scope());
    is([$two_events->[0]{status}, $two_events->[1]{body}], [200, 'home'],
        'second compiled app dispatches independently');
};

subtest 'selected native immediate and Future-backed completion remain normalized' => sub {
    my $immediate_calls = 0;
    my $immediate = compose(routes => [
        route('/immediate' => as_app(sub {
            my ($scope, $receive, $send) = @_;
            ++$immediate_calls;
            $send->({
                type => 'http.response.start', status => 204, headers => [],
            })->get;
            $send->({
                type => 'http.response.body', body => '', more => 0,
            })->get;
            return;
        })),
    ])->to_app;
    is(run_scope($immediate, scope(path => '/immediate')), [
        { type => 'http.response.start', status => 204, headers => [] },
        { type => 'http.response.body', body => '', more => 0 },
    ], 'immediate app emits its complete response');
    is($immediate_calls, 1, 'immediate app completes normally');

    my $pending = Future->new;
    my $future_app = compose(routes => [
        route('/future' => as_app(sub {
            my ($scope, $receive, $send) = @_;
            $send->({
                type => 'http.response.start', status => 204, headers => [],
            })->get;
            $send->({
                type => 'http.response.body', body => '', more => 0,
            })->get;
            return $pending;
        })),
    ])->to_app;
    my ($send) = capture_send();
    my $running = $future_app->(
        scope(path => '/future'),
        sub { return Future->done },
        $send,
    );
    ok(!$running->is_ready, 'compiled app awaits a pending target Future');
    $pending->done('ignored target value');
    is($running->get, undef, 'target result is inert');
};

subtest 'routed object targets compile once per to_app' => sub {
    local $Local::ComposeComponent::COMPILES = 0;
    my $object_description = compose(routes => [
        route('/object' => Local::ComposeComponent->new),
    ]);
    my $object_app = $object_description->to_app;
    run_scope($object_app, scope(path => '/object'));
    run_scope($object_app, scope(path => '/object'));
    is($Local::ComposeComponent::COMPILES, 1, 'requests reuse one object compilation');
    my $object_app_two = $object_description->to_app;
    is($Local::ComposeComponent::COMPILES, 2, 'second to_app recompiles object');
};

subtest 'no-hook lifespan succeeds without state and never reaches target' => sub {
    my $target_calls = 0;
    my $app = compose(routes => [
        route('/' => sub {
            ++$target_calls;
            return PAGI::Response::Text->new('target');
        }),
    ])->to_app;
    my $events = run_scope($app, scope(type => 'lifespan'), [
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    ]);
    is($events, [
        { type => 'lifespan.startup.complete' },
        { type => 'lifespan.shutdown.complete' },
    ], 'Compose uniformly supports no-hook lifecycle');
    is($target_calls, 0, 'target never receives lifespan');
};

subtest 'only the outer composition owns nested lifecycle' => sub {
    my $inner_startup = 0;
    my $request_calls = 0;
    my $inner = compose(
        routes => [route('/' => sub {
            ++$request_calls;
            return PAGI::Response::Text->new('inner');
        })],
        lifespan => { startup => sub { ++$inner_startup; return } },
    );
    my $outer = compose(routes => [
        mount('/inner', app => $inner->to_app),
    ])->to_app;
    run_scope($outer, scope(type => 'lifespan'), [
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    ]);
    is($inner_startup, 0, 'outer owner never delegates lifecycle to nested Compose');
    run_scope($outer, scope(path => '/inner/'));
    is($request_calls, 1, 'nested Compose remains a normal request target');
};

done_testing;
