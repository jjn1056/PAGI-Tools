#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::App::Router::Builder ();
use PAGI::Compose qw(compose);
use PAGI::Response::Text ();
use PAGI::Routing::Router ();
use PAGI::Test::Client ();

sub handler {
    my ($body, $counter) = @_;
    return sub {
        my ($request) = @_;
        ++$$counter if $counter;
        return PAGI::Response::Text->new($body);
    };
}

sub opaque_app {
    my ($body, $counter) = @_;
    return async sub {
        my ($scope, $receive, $send) = @_;
        ++$$counter if $counter;
        await $send->({
            type => 'http.response.start',
            status => 200,
            headers => [['content-type' => 'text/plain']],
        });
        await $send->({
            type => 'http.response.body', body => $body, more => 0,
        });
    };
}

sub client_for {
    my ($builder) = @_;
    return PAGI::Test::Client->new(app => $builder->to_app);
}

sub complete_client_for {
    my ($builder) = @_;
    return PAGI::Test::Client->new(
        app => compose(app => $builder)->to_app,
    );
}

sub router_methods_exist {
    my ($builder) = @_;
    my $ok = 1;
    for my $method (qw(mount to_router to_app)) {
        $ok = 0 unless ok($builder->can($method), "Builder provides $method");
    }
    return $ok;
}

subtest 'routes and app Mounts retain one structural shape' => sub {
    my $builder = PAGI::App::Router::Builder->new;
    return unless router_methods_exist($builder);

    my $parent_identity = refaddr($builder);
    my ($child_identity, $callback_calls);
    my $factory = sub { return $_[0] };
    my $callback_return = bless {}, 'Local::IgnoredMountReturn';
    my $returned = $builder->mount('/api/{tenant}', routes => sub {
        my ($child) = @_;
        ++$callback_calls;
        $child_identity = refaddr($child);
        $child->get('/users/{id}' => handler('nested'))
            ->name('users')->desc('users route')->constraints(id => qr/\d+/);
        $child->mount('/v2', routes => sub {
            my ($grandchild) = @_;
            $grandchild->post('/items' => handler('deep'))->name('items');
        })->name('v2')->desc('nested Mount');
        return $callback_return;
    }, middleware => [$factory]);
    is($returned, $builder, 'Mount ignores the callback return and returns the parent');
    isnt($child_identity, $parent_identity, 'routes callback receives a fresh child Builder');
    is($callback_calls, 1, 'routes callback runs synchronously exactly once');
    $builder->name('api')->desc('API Mount')->constraints(tenant => qr/[a-z]+/);

    my $opaque = opaque_app('opaque');
    $builder->mount('/assets/{bucket}', app => $opaque)
        ->name('assets')->desc('opaque assets')
        ->constraints(bucket => qr/[a-z]+/);

    my $immutable = PAGI::Routing::Router->new(routes => []);
    $builder->mount('/immutable', app => $immutable, middleware => [$factory])
        ->name('immutable')->desc('immutable child');

    my $records = $builder->_declarations;
    is([map { $_->{node_kind} } @$records],
        [qw(mount mount mount)],
        'one declaration array retains every Mount in written order');
    ok(!exists $records->[0]{router} && !exists $records->[0]{is_raw},
        'Mount records contain no retired router or mode keys');
    ok(exists $records->[0]{child} && exists $records->[1]{app},
        'Mount records distinguish declaration children from application values');

    my $router = $builder->to_router;
    my $nodes = $router->routes;
    isa_ok($nodes->[0], 'PAGI::Routing::Mount');
    is([$nodes->[0]->path, $nodes->[0]->name, $nodes->[0]->desc],
        ['/api/{tenant}', 'api', 'API Mount'],
        'a callback becomes one Mount with its local metadata');
    is($nodes->[0]->constraints, { tenant => qr/[a-z]+/ },
        'Mount constraints are materialized');
    is(scalar @{$nodes->[0]->middleware}, 1,
        'named Mount middleware is retained once');
    is([map { [$_->kind, $_->path, $_->name] } @{$nodes->[0]->app->routes}], [
        ['route', '/users/{id}', 'users'],
        ['mount', '/v2', 'v2'],
    ], 'nested callback contents remain ordered in a child Router');
    is([map { [$_->kind, $_->path, $_->name] }
            @{$nodes->[0]->app->routes->[1]->app->routes}],
        [['route', '/items', 'items']],
        'a second callback level becomes another Router application');

    is(refaddr($nodes->[1]->app), refaddr($opaque),
        'an opaque app is stored untouched');
    is([$nodes->[1]->name, $nodes->[1]->desc, $nodes->[1]->constraints],
        ['assets', 'opaque assets', { bucket => qr/[a-z]+/ }],
        'opaque app Mounts retain all chained modifiers');
    is(refaddr($nodes->[2]->app), refaddr($immutable),
        'an immutable Router mount retains child identity');
    is([$nodes->[2]->name, $nodes->[2]->desc],
        ['immutable', 'immutable child'],
        'immutable Router apps retain placement metadata');
};

subtest 'parameter and static routes keep exact declaration precedence' => sub {
    my $parameter_first = PAGI::App::Router::Builder->new;
    return unless router_methods_exist($parameter_first);
    $parameter_first->get('/{slug}' => handler('parameter'));
    $parameter_first->get('/about' => handler('static'));
    is(client_for($parameter_first)->get('/about')->text, 'parameter',
        'a parameter route written before a static route wins');

    my $static_first = PAGI::App::Router::Builder->new;
    $static_first->get('/about' => handler('static'));
    $static_first->get('/{slug}' => handler('parameter'));
    is(client_for($static_first)->get('/about')->text, 'static',
        'a static route written first wins without specificity sorting');
};

subtest 'the first of two FULL routes wins and later handlers do not execute' => sub {
    my ($first_calls, $second_calls) = (0, 0);
    my $builder = PAGI::App::Router::Builder->new;
    return unless router_methods_exist($builder);
    $builder->get('/same' => handler('first', \$first_calls));
    $builder->get('/same' => handler('second', \$second_calls));
    is(client_for($builder)->get('/same')->text, 'first',
        'the first FULL route supplies the response');
    is([$first_calls, $second_calls], [1, 0],
        'scanning stops before the second FULL handler');
};

subtest 'a PARTIAL continues scanning to a later FULL route' => sub {
    my ($get_calls, $post_calls) = (0, 0);
    my $builder = PAGI::App::Router::Builder->new;
    return unless router_methods_exist($builder);
    $builder->get('/item' => handler('GET', \$get_calls));
    $builder->post('/item' => handler('POST', \$post_calls));
    is(client_for($builder)->post('/item')->text, 'POST',
        'GET PARTIAL does not hide a later POST FULL');
    is([$get_calls, $post_calls], [0, 1],
        'only the later FULL handler executes');
};

subtest 'Compose fallback Allow follows first-seen sibling declaration order' => sub {
    my $get_first = PAGI::App::Router::Builder->new;
    return unless router_methods_exist($get_first);
    $get_first->get('/item' => handler('GET'));
    $get_first->post('/item' => handler('POST'));
    is(complete_client_for($get_first)->delete('/item')->header('Allow'),
        'GET, HEAD, POST', 'GET then POST retains first-seen Allow order');

    my $post_first = PAGI::App::Router::Builder->new;
    $post_first->post('/item' => handler('POST'));
    $post_first->get('/item' => handler('GET'));
    is(complete_client_for($post_first)->delete('/item')->header('Allow'),
        'POST, GET, HEAD', 'POST then GET retains first-seen Allow order');
};

subtest 'prefix mounts own at their declaration position relative to routes' => sub {
    my ($mount_calls, $route_calls) = (0, 0);
    my $mount_first = PAGI::App::Router::Builder->new;
    return unless router_methods_exist($mount_first);
    $mount_first->mount('/api', app => opaque_app('mount', \$mount_calls));
    $mount_first->get('/api/item' => handler('route', \$route_calls));
    is(client_for($mount_first)->get('/api/item')->text, 'mount',
        'an earlier matching prefix mount owns immediately');
    is([$mount_calls, $route_calls], [1, 0],
        'the later sibling route does not run after mount ownership');

    ($mount_calls, $route_calls) = (0, 0);
    my $route_first = PAGI::App::Router::Builder->new;
    $route_first->get('/api/item' => handler('route', \$route_calls));
    $route_first->mount('/api', app => opaque_app('mount', \$mount_calls));
    is(client_for($route_first)->get('/api/item')->text, 'route',
        'an earlier FULL sibling route wins before a matching mount');
    is([$mount_calls, $route_calls], [0, 1],
        'the later mount does not run after route selection');
};

subtest 'root and api mounts are never reordered by prefix length' => sub {
    my $root_first = PAGI::App::Router::Builder->new;
    return unless router_methods_exist($root_first);
    $root_first->mount('/', app => opaque_app('root'));
    $root_first->mount('/api', app => opaque_app('api'));
    is(client_for($root_first)->get('/api/item')->text, 'root',
        'an earlier root mount beats a longer later prefix');

    my $api_first = PAGI::App::Router::Builder->new;
    $api_first->mount('/api', app => opaque_app('api'));
    $api_first->mount('/', app => opaque_app('root'));
    is(client_for($api_first)->get('/api/item')->text, 'api',
        'an earlier api mount beats a later root mount');
};

subtest 'callback Mounts own requests at their written parent position' => sub {
    my $before = PAGI::App::Router::Builder->new;
    return unless router_methods_exist($before);
    $before->mount('/api', routes => sub {
        $_[0]->get('/item' => handler('Mount before'));
    });
    $before->get('/api/item' => handler('parent after'));
    is(client_for($before)->get('/api/item')->text, 'Mount before',
        'a callback Mount before a parent sibling owns first');

    my $between = PAGI::App::Router::Builder->new;
    $between->get('/api/item' => handler('parent partial'));
    $between->mount('/api', routes => sub {
        $_[0]->post('/item' => handler('Mount between'));
    });
    $between->post('/api/item' => handler('parent after'));
    is(client_for($between)->post('/api/item')->text, 'Mount between',
        'a callback Mount between parent siblings wins after an earlier PARTIAL');

    my $after = PAGI::App::Router::Builder->new;
    $after->get('/api/item' => handler('parent partial'));
    $after->post('/api/item' => handler('parent before'));
    $after->mount('/api', routes => sub {
        $_[0]->post('/item' => handler('Mount after'));
    });
    is(client_for($after)->post('/api/item')->text, 'parent before',
        'a callback Mount after a parent FULL sibling is not hoisted');
};

subtest 'mixed protocols and two nested levels retain exact node order' => sub {
    my $builder = PAGI::App::Router::Builder->new;
    return unless router_methods_exist($builder);
    $builder->websocket('/socket-a' => sub { });
    $builder->get('/http-a' => handler('http a'));
    $builder->sse('/events-a' => sub { });
    $builder->mount('/one', routes => sub {
        my ($one) = @_;
        $one->post('/parent-first' => handler('parent first'));
        $one->mount('/two', routes => sub {
            my ($two) = @_;
            $two->sse('/deep-events' => sub { });
            $two->get('/deep-http' => handler('deep http'));
            $two->websocket('/deep-socket' => sub { });
        });
        $one->get('/parent-last' => handler('parent last'));
    });
    $builder->post('/http-b' => handler('http b'));

    my $root = $builder->to_router->routes;
    is([map { [$_->kind, $_->path] } @$root], [
        ['websocket', '/socket-a'],
        ['route', '/http-a'],
        ['sse', '/events-a'],
        ['mount', '/one'],
        ['route', '/http-b'],
    ], 'HTTP, WebSocket, SSE, and Mount nodes share one unsorted root order');
    my $one = $root->[3]->app->routes;
    is([map { [$_->kind, $_->path] } @$one], [
        ['route', '/parent-first'],
        ['mount', '/two'],
        ['route', '/parent-last'],
    ], 'first nested level retains declarations around its child Mount');
    my $two = $one->[1]->app->routes;
    is([map { [$_->kind, $_->path] } @$two], [
        ['sse', '/deep-events'],
        ['route', '/deep-http'],
        ['websocket', '/deep-socket'],
    ], 'second nested level retains its mixed protocol order');
    is(client_for($builder)->get('/one/two/deep-http')->text, 'deep http',
        'the two-level ordered tree dispatches to its nested HTTP handler');
};

done_testing;
