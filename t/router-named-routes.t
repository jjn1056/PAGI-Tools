#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::App::Router;
use PAGI::Response::Text ();

sub handler { return sub { return PAGI::Response::Text->new('ok') } }

subtest 'public names are local segments and inspection uses slash addresses' => sub {
    my $router = PAGI::App::Router->new;
    $router->get('/users' => handler())->name('list');
    $router->get('/users/{id}' => handler())->name('show');
    $router->post('/users' => handler())->name('create');

    is([sort keys %{$router->named_routes}], ['/create', '/list', '/show'],
        'root names are canonical absolute slash addresses');
    is($router->path_for('/list'), '/users', 'a static name renders its path');
    is($router->path_for('/show', { id => 42 }), '/users/42',
        'a parameterized name renders its capture');
    is($router->path_for('/create'), '/users',
        'method siblings may render the same path under distinct names');
    ok(!$router->can('uri_for'), 'uri_for is removed rather than aliased');
    ok(!$router->can('as'), 'as is removed rather than aliased');
};

subtest 'path_for renders sorted query and one escaped fragment' => sub {
    my $router = PAGI::App::Router->new;
    $router->get('/search/{term}' => handler())->name('search');

    is(
        $router->path_for(
            '/search',
            { term => 'two words' },
            { page => 2, 'a key' => 'A&B' },
            'result details',
        ),
        '/search/two%20words?a%20key=A%26B&page=2#result%20details',
        'path, query, and fragment use shared component encoding',
    );
    is(
        $router->path_for('/search',
            params => { term => 'perl' },
            fragment => ''),
        '/search/perl#',
        'named reverse arguments and an empty fragment are supported',
    );
};

subtest 'reverse errors use the immutable Resolver contract' => sub {
    my $router = PAGI::App::Router->new;
    $router->get('/users/{id}' => handler())->name('show');

    like(dies { $router->path_for('/missing') },
        qr/unknown route name '\/missing'/, 'unknown exact address fails');
    like(dies { $router->path_for('/show') },
        qr/missing path parameter 'id'/, 'missing path parameter fails');
    like(dies { $router->path_for('/show', { id => 1, extra => 2 }) },
        qr/unexpected path parameter 'extra'/, 'extra path parameter fails');
    is($router->route_named('/missing'), undef,
        'route_named returns undef for an unknown exact address');
};

subtest 'name validates the preceding declaration and local segment' => sub {
    my $router = PAGI::App::Router->new;
    like(dies { $router->name('missing') },
        qr/name called without a preceding compatible declaration/,
        'name requires a preceding compatible declaration');
    $router->get('/test' => handler());
    like(dies { $router->name('') },
        qr/name must be one logical address segment/, 'empty name fails');

    my $dotted = PAGI::App::Router->new;
    $dotted->get('/test' => handler())->name('users.show');
    is($dotted->path_for('/users.show'), '/test',
        'a dotted local name remains one literal address component');
    like(dies { $dotted->path_for('/users/show') }, qr/unknown route name/,
        'a dot never acts as a hierarchy separator');
    my $slashed = PAGI::App::Router->new;
    $slashed->get('/test' => handler());
    like(dies { $slashed->name('users/show') },
        qr/name must be one logical address segment/,
        'composed slash addresses are derived rather than declared locally');
};

subtest 'WebSocket, SSE, wildcard, and generic routes reverse uniformly' => sub {
    my $router = PAGI::App::Router->new;
    $router->websocket('/ws/{room}' => sub { })->name('socket');
    $router->sse('/events/{channel}' => sub { })->name('events');
    $router->get('/files/*path' => handler())->name('files');
    $router->any('/health' => handler())->name('health');
    $router->route('/items/{id:\d+}' => handler(), methods => ['GET', 'PUT'])
        ->name('item');

    is($router->path_for('/socket', { room => 'general' }), '/ws/general',
        'WebSocket route reverses');
    is($router->path_for('/events', { channel => 'news' }), '/events/news',
        'SSE route reverses');
    is($router->path_for('/files', { path => 'docs/read me.txt' }),
        '/files/docs/read%20me.txt', 'wildcard components reverse independently');
    is($router->path_for('/health'), '/health', 'any route reverses');
    is($router->path_for('/item', { id => 5 }), '/items/5',
        'generic route applies an inline constraint');
    like(dies { $router->path_for('/item', { id => 'five' }) },
        qr/failed constraint/, 'reverse constraint failure is reported');
};

subtest 'known mounts compose nested names without copying them' => sub {
    my $users = PAGI::App::Router->new;
    $users->get('/' => handler())->name('list');
    $users->get('/{id}' => handler())->name('show');

    my $api = PAGI::App::Router->new;
    $api->mount('/users', app => $users->to_router)->name('users');

    my $main = PAGI::App::Router->new;
    $main->get('/' => handler())->name('home');
    $main->mount('/api', app => $api->to_router)->name('api');

    is([sort keys %{$main->named_routes}], [
        '/api/users/list', '/api/users/show', '/home',
    ], 'known mount placement names compose recursively');
    is($main->path_for('/home'), '/', 'root route remains available');
    is($main->path_for('/api/users/list'), '/api/users/',
        'nested root leaf keeps its trailing slash');
    is($main->path_for('/api/users/show', { id => 7 }), '/api/users/7',
        'nested parameter path includes every mount prefix');

    my $snapshot = $main->to_router;
    my $first = $snapshot->route_named('/api/users/show');
    is(refaddr($first), refaddr($snapshot->route_named('/api/users/show')),
        'a retained snapshot preserves leaf identity');
    is(refaddr($main->route_named('/api/users/show')),
        refaddr($main->route_named('/api/users/show')),
        'explicit immutable child snapshots retain caller-owned leaf identity');
};

subtest 'opaque mounts accept placement metadata but publish no leaf names' => sub {
    my $opaque = sub { return Future->done };
    my $router = PAGI::App::Router->new;
    $router->mount('/legacy', app => $opaque)->name('legacy');
    is($router->to_router->routes->[0]->name, 'legacy',
        'an opaque Mount retains its local placement name');
    is($router->named_routes, {}, 'opaque target contributes no names');
};

done_testing;
