#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw(refaddr);
use overload ();

use lib 'lib';
use PAGI::App::Router;
use PAGI::App::Router::Builder ();
use PAGI::Routing::Router ();

sub context_handler {
    return sub {
        my ($c) = @_;
        return $c->text('ok');
    };
}

sub native_app {
    return sub {
        my ($scope, $receive, $send) = @_;
        return;
    };
}

subtest 'the public class is only the mutable Builder facade' => sub {
    my $router = PAGI::App::Router->new;

    isa_ok($router, 'PAGI::App::Router::Builder');
    for my $method (qw(
        get post put patch delete head options any route websocket sse
        group mount name desc constraints to_router to_app
        named_routes route_named path_for
    )) {
        ok($router->can($method), "public facade provides $method");
    }

    for my $removed (qw(uri_for as namespace auto_head)) {
        ok(!$router->can($removed), "removed $removed surface is absent");
    }
    for my $old_array (qw(routes websocket_routes sse_routes mounts)) {
        ok(!exists $router->{$old_array}, "old $old_array route array is absent");
    }
    is(overload::Method($router, '&{}'), undef,
        'the public builder has no coderef overload');
    like(
        dies { PAGI::App::Router->new(auto_head => 0) },
        qr/unknown router option 'auto_head'/,
        'the old automatic-HEAD option is not retained',
    );
};

subtest 'direct routes, structural groups, and both mount forms materialize in written order' => sub {
    my $people = PAGI::App::Router->new;
    $people->get('/{id}' => context_handler())->name('show');

    my $opaque = native_app();
    my $router = PAGI::App::Router->new(desc => 'public routes');
    my $group_child;
    $router->get('/direct' => context_handler())->name('direct');
    $router->group('/api' => sub {
        my ($child) = @_;
        $group_child = $child;
        $child->post('/items' => context_handler())->name('items');
    })->name('api');
    $router->mount('/people', router => $people)->name('people');
    $router->mount('/assets' => $opaque)->desc('opaque assets');

    isa_ok($group_child, 'PAGI::App::Router');
    isnt(refaddr($group_child), refaddr($router),
        'a group callback receives a fresh public child');

    my $snapshot = $router->to_router;
    isa_ok($snapshot, 'PAGI::Routing::Router');
    is($snapshot->desc, 'public routes', 'top-level configuration reaches the snapshot');

    my $nodes = $snapshot->routes;
    is(
        [map { [$_->kind, $_->path, $_->name, $_->is_raw] } @$nodes],
        [
            ['route', '/direct', 'direct', 0],
            ['mount', '/api', 'api', 0],
            ['mount', '/people', 'people', 0],
            ['mount', '/assets', undef, 1],
        ],
        'one immutable node sequence preserves direct, group, and mount order',
    );
    is(
        [map { [$_->kind, $_->path, $_->name] } @{$nodes->[1]->routes}],
        [['route', '/items', 'items']],
        'the group remains an inspectable inline structural child',
    );
    isa_ok($nodes->[2]->router, 'PAGI::Routing::Router');
    is($nodes->[3]->target, $opaque, 'the opaque mount retains its native target');
};

subtest 'snapshots are fresh and convenience inspection rematerializes' => sub {
    my $router = PAGI::App::Router->new;
    $router->get('/first' => context_handler())->name('first');

    my $first = $router->to_router;
    $router->get('/second' => context_handler())->name('second');
    my $second = $router->to_router;

    isnt(refaddr($first), refaddr($second), 'each to_router call returns a fresh Router');
    is([sort keys %{$first->named_routes}], ['/first'],
        'an earlier snapshot never gains later declarations');
    is([sort keys %{$second->named_routes}], ['/first', '/second'],
        'a later snapshot sees later declarations');
    isnt(
        refaddr($first->route_named('/first')),
        refaddr($second->route_named('/first')),
        'fresh snapshots contain independent immutable leaves',
    );

    my $retained = $router->to_router;
    is(
        refaddr($retained->route_named('/first')),
        refaddr($retained->route_named('/first')),
        'a retained immutable Router provides stable route identity',
    );
    isnt(
        refaddr($router->route_named('/first')),
        refaddr($router->route_named('/first')),
        'builder route_named delegates through a fresh snapshot each time',
    );
    is([sort keys %{$router->named_routes}], ['/first', '/second'],
        'builder named_routes delegates to immutable inspection');
    is($router->path_for('/second'), '/second',
        'builder path_for delegates to immutable reverse routing');
};

{
    package Local::CountingPublicRouter;
    our @ISA = ('PAGI::App::Router');

    sub to_router {
        my ($self) = @_;
        ++$self->{snapshot_calls};
        return PAGI::Routing::Router->new(routes => []);
    }
}

subtest 'to_app compiles exactly one retained snapshot' => sub {
    my $router = bless { snapshot_calls => 0 }, 'Local::CountingPublicRouter';
    my $app = $router->to_app;

    is(ref($app), 'CODE', 'to_app returns a compiled PAGI application');
    is($router->{snapshot_calls}, 1, 'to_app requests exactly one immutable snapshot');
};

done_testing;
