#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw(refaddr);
use Future;
use Future::AsyncAwait;
use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";
use ComposeTest qw(scope run_scope capture_send);
use PAGI::Compose qw(compose);
use PAGI::Pages ();
use PAGI::Response::Text ();
use PAGI::Routing qw(mount route websocket sse router middleware);
use PAGI::Utils qw(as_app_object);

sub recording_middleware {
    my ($label, $seen) = @_;
    return middleware(sub {
        my ($inner) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            push @$seen, "$label:before";
            my $result = await Future->wrap(
                $inner->($scope, $receive, $send),
            );
            push @$seen, "$label:after";
            return $result;
        };
    });
}

sub response_body {
    my ($events) = @_;
    return join '', map { $_->{body} // '' }
        grep { ($_->{type} // '') eq 'http.response.body' } @$events;
}

sub response_header {
    my ($events, $name) = @_;
    my ($start) = grep {
        ($_->{type} // '') eq 'http.response.start'
    } @$events;
    return unless $start;
    for my $pair (@{$start->{headers} // []}) {
        return $pair->[1] if lc($pair->[0]) eq lc($name);
    }
    return;
}

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

subtest 'Compose retains an explicit unnamed root Router Mount' => sub {
    my @order;
    my @seen_scope;
    my $child_default = PAGI::Pages->not_found(
        detail => 'child default',
    );
    my $child_leaf = route('/item/{id}' => sub {
        my ($request) = @_;
        push @seen_scope, [@{$request->scope}{qw(path raw_path root_path)}];
        push @order, 'handler';
        return PAGI::Response::Text->new('item:' . $request->path_param('id'));
    }, methods => ['GET'], name => 'show');
    my $child = router(
        routes       => [$child_leaf],
        middleware   => [recording_middleware('child', \@order)],
        http_default => $child_default,
        desc         => 'Preserved child',
    );
    my $root_mount = mount('/' => app => $child);
    my $composition = compose(
        routes     => [$root_mount],
        middleware => [recording_middleware('compose', \@order)],
    );

    isnt(refaddr($composition->router), refaddr($child),
        'Compose owns a distinct outer root Router');
    is(refaddr($composition->routes->[0]), refaddr($root_mount),
        'Compose routes expose the explicit root Mount');
    is(refaddr($composition->routes->[0]->app), refaddr($child),
        'root Mount retains child Router identity');
    is($composition->path_for('/show', { id => 7 }), '/item/7',
        'unnamed root Mount adds no namespace or slash');
    is(refaddr($composition->route_named('/show')), refaddr($child_leaf),
        'outer Resolver discovers mounted child leaf');
    is($child->desc, 'Preserved child', 'child description remains owned by child');
    is(refaddr($child->http_default), refaddr($child_default),
        'child default remains owned by child');

    my $legacy = compose(routes => [
        mount('/' => app => $child, name => 'legacy'),
    ]);
    is(refaddr($legacy->route_named('/legacy/show')), refaddr($child_leaf),
        'named root Mount contributes its namespace');
    ok(!defined($legacy->route_named('/show')),
        'named root Mount does not publish the child at the unnamed address');

    my $app = $composition->to_app;
    my $full = run_scope($app, scope(
        path => '/item/7', raw_path => '/edge/item/7', root_path => '/edge',
    ));
    is([$full->[0]{status}, $full->[1]{body}], [200, 'item:7'],
        'root-mounted child handles FULL');
    is(\@seen_scope, [['/item/7', '/edge/item/7', '/edge']],
        'root Mount preserves path arithmetic');
    is(\@order, [qw(compose:before child:before handler child:after compose:after)],
        'Compose middleware remains outside child Router middleware');

    my $partial = run_scope($app, scope(method => 'POST', path => '/item/7'));
    is($partial->[0]{status}, 405, 'child owns PARTIAL');
    is(response_header($partial, 'Allow'), 'GET, HEAD',
        'child publishes authoritative Allow');

    my $none = run_scope($app, scope(path => '/missing'));
    is($none->[0]{status}, 404, 'child owns NONE');
    like(response_body($none), qr/child default/,
        'child custom default remains active');

    my $ordered = compose(routes => [
        route('/outer' => sub {
            return PAGI::Response::Text->new('outer');
        }),
        mount('/' => app => $child),
        route('/after' => sub {
            return PAGI::Response::Text->new('unreachable');
        }),
    ])->to_app;
    my $outer = run_scope($ordered, scope(path => '/outer'));
    is([$outer->[0]{status}, $outer->[1]{body}], [200, 'outer'],
        'an earlier outer Route remains reachable');
    my $after = run_scope($ordered, scope(path => '/after'));
    is($after->[0]{status}, 404,
        'root Mount handles later sibling as child NONE');
    like(response_body($after), qr/child default/,
        'root Mount does not resume the later sibling');
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

subtest 'retained Router compiles fresh per Compose to_app without public to_app calls' => sub {
    local $Local::CountingRouter::TO_APP_CALLS = 0;
    my $routing = Local::CountingRouter->new(routes => [
        route('/' => sub { return PAGI::Response::Text->new('home') }),
    ]);
    my $description = compose(routes => [mount('/' => app => $routing)]);
    is($Local::CountingRouter::TO_APP_CALLS, 0,
        'Compose construction does not compile Router');
    my $app_one = $description->to_app;
    is($Local::CountingRouter::TO_APP_CALLS, 0,
        'first Compose to_app compiles the mounted Router without calling its public to_app');
    my $app_two = $description->to_app;
    is($Local::CountingRouter::TO_APP_CALLS, 0,
        'second Compose to_app creates a fresh Router graph without calling its public to_app');
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
        route('/immediate' => as_app_object(sub {
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
        route('/future' => as_app_object(sub {
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
