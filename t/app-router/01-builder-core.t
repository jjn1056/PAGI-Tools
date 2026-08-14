#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::App::Router ();
use PAGI::App::Router::Builder ();
use PAGI::Routing::Middleware ();

{
    package Local::StringifiedOption;
    use overload '""' => sub { return 'methods' }, fallback => 1;
}

subtest 'constructor copies and normalizes router configuration' => sub {
    my $factory = sub { return $_[0] };
    my $middleware = [$factory];

    my $builder = PAGI::App::Router::Builder->new(
        desc       => 'root routes',
        middleware => $middleware,
    );

    my $options = $builder->_router_options;
    is($options->{desc}, 'root routes', 'stores the top-level description');
    ok(!exists $options->{not_found},
        'materialized Router options have no not-found callback key');
    ok(!exists $options->{method_not_allowed},
        'materialized Router options have no method-not-allowed callback key');
    ok($options->{middleware}[0]->isa('PAGI::Routing::Middleware'),
        'normalizes top-level middleware immediately');

    push @$middleware, sub { return $_[0] };
    push @{$options->{middleware}}, PAGI::Routing::Middleware->new(sub { return $_[0] });
    is(scalar @{$builder->_router_options->{middleware}}, 1,
        'top-level middleware lists are defensive');

    like dies { PAGI::App::Router::Builder->new('desc') },
        qr/router option list must be key\/value pairs/,
        'odd router options are rejected';
    like dies { PAGI::App::Router::Builder->new(unknown => 1) },
        qr/unknown router option 'unknown'/,
        'unknown router options are rejected';
    like dies { PAGI::App::Router::Builder->new(desc => []) },
        qr/desc must be a string/,
        'invalid descriptions are rejected';
    for my $class (qw(PAGI::App::Router::Builder PAGI::App::Router)) {
        my $instance = $class->new;
        ok(!$instance->can('not_found'), "$class has no not-found accessor");
        ok(!$instance->can('method_not_allowed'),
            "$class has no method-not-allowed accessor");
        for my $removed (qw(not_found method_not_allowed)) {
            like dies { $class->new($removed => sub { }) },
                qr/unknown router option '\Q$removed\E'/,
                "$class rejects removed option '$removed'";
        }
    }
};

subtest 'all leaf declarations retain one exact ordered record sequence' => sub {
    my $builder = PAGI::App::Router::Builder->new;
    my $handler = sub { return 'context result' };
    my $raw = sub { return 'native result' };
    my $factory = sub { return $_[0] };
    my $methods = ['RPC'];

    $builder->get('/get' => $handler);
    $builder->post('/post' => $handler);
    $builder->put('/put' => $handler);
    $builder->patch('/patch' => $handler);
    $builder->delete('/delete' => $handler);
    $builder->head('/head' => $handler);
    $builder->options('/options' => $handler);
    $builder->any('/any' => $handler);
    $builder->route('/rpc' => $handler, methods => $methods);
    $builder->websocket('/socket' => $handler);
    $builder->sse('/events' => $handler);
    $builder->get('/raw', raw => $raw);
    $builder->get('/wrapped' => [$factory] => $handler);

    my $records = $builder->_declarations;
    is(
        [map { [$_->{node_kind}, $_->{methods}, $_->{path}] } @$records],
        [
            ['route',     ['GET'],     '/get'],
            ['route',     ['POST'],    '/post'],
            ['route',     ['PUT'],     '/put'],
            ['route',     ['PATCH'],   '/patch'],
            ['route',     ['DELETE'],  '/delete'],
            ['route',     ['HEAD'],    '/head'],
            ['route',     ['OPTIONS'], '/options'],
            ['route',     '*',         '/any'],
            ['route',     ['RPC'],     '/rpc'],
            ['websocket', undef, '/socket'],
            ['sse', undef, '/events'],
            ['route',     ['GET'], '/raw'],
            ['route',     ['GET'], '/wrapped'],
        ],
        'all declarations preserve one exact insertion order across protocols',
    );
    ok($records->[11]{is_raw}, 'explicit raw tag is retained on raw target');
    is(refaddr($records->[11]{target}), refaddr($raw), 'raw target identity is retained');
    ok($records->[12]{middleware}[0]->isa('PAGI::Routing::Middleware'),
        'positional middleware is normalized at declaration time');

    $methods->[0] = 'CHANGED';
    $records->[0]{methods}[0] = 'CHANGED';
    push @{$records->[12]{middleware}}, PAGI::Routing::Middleware->new($factory);
    is($builder->_declarations->[8]{methods}, ['RPC'], 'method lists are defensive');
    is(scalar @{$builder->_declarations->[12]{middleware}}, 1,
        'record middleware lists are defensive');
};

subtest 'leaf grammar distinguishes Context targets from explicit raw targets' => sub {
    my $builder = PAGI::App::Router::Builder->new;
    my $handler = sub { };
    my $raw = sub { };
    my $factory = sub { return $_[0] };

    $builder->get('/normal' => $handler);
    $builder->get('/wrapped' => [$factory] => $handler);
    $builder->get('/raw', raw => $raw);
    $builder->get('/raw-wrapped' => [$factory], raw => $raw);
    $builder->route('/rpc' => $handler, methods => ['RPC']);

    like dies { $builder->get('/missing') }, qr/requires a target/,
        'a declaration requires one target';
    like dies { $builder->get('/extra' => $handler => 'extra') },
        qr/option list must be key\/value pairs|requires exactly one target/,
        'extra positional values are rejected';
    like dies { $builder->get('/odd' => $handler, method => 'GET') },
        qr/unknown route option 'method'/,
        'unrecognized named tails are rejected';
    like dies { $builder->websocket('/socket' => $handler, methods => ['GET']) },
        qr/WebSocket routes do not accept methods/,
        'WebSocket declarations reject methods';
    like dies { $builder->sse('/events' => $handler, methods => ['GET']) },
        qr/SSE routes do not accept methods/,
        'SSE declarations reject methods';
    like dies { $builder->route('/missing-methods' => $handler) },
        qr/route requires methods option/,
        'generic route declarations require methods';
    like dies { $builder->get('/raw', raw => undef) }, qr/raw target must be defined/,
        'raw tags require their target';
    like dies { $builder->get('/normal' => 'native') }, qr/handler must be a coderef/,
        'ordinary targets must be Context handler coderefs';
    like dies { $builder->get('/bad-middleware' => [undef] => $handler) },
        qr/middleware entry 0 must be/,
        'invalid positional middleware entries are rejected';
    like dies {
        $builder->route('/stringified' => $handler,
            bless({}, 'Local::StringifiedOption') => ['GET']);
    }, qr/route option names must be strings/,
        'stringified reference option keys are rejected before hash construction';
};

subtest 'last declaration modifiers update only the latest compatible route' => sub {
    my $builder = PAGI::App::Router::Builder->new;
    my $handler = sub { };
    my $constraints = { id => qr/\d+/ };

    is($builder->get('/one/{id}' => $handler), $builder, 'route declarations return the builder');
    is($builder->name('one')->desc('first')->constraints(%$constraints), $builder,
        'all modifiers return the builder');
    $constraints->{id} = qr/[a-z]+/;
    $builder->post('/two' => $handler);

    my $records = $builder->_declarations;
    is($records->[0]{name}, 'one', 'name updates the preceding route');
    is($records->[0]{desc}, 'first', 'description updates the preceding route');
    my $node = $builder->_materialize_nodes(undef)->[0];
    is($node->_pattern->match_route('/one/42'), { id => '42' },
        'materialized constraints accept the originally declared value');
    is($node->_pattern->match_route('/one/abc'), undef,
        'materialized constraints reject values outside the original declaration');
    is($records->[1]{name}, undef, 'later declarations do not inherit a name');
    is($records->[1]{desc}, undef, 'later declarations do not inherit a description');
    is($records->[1]{constraints}, undef, 'later declarations do not inherit constraints');

    my $empty = PAGI::App::Router::Builder->new;
    like dies { $empty->name('missing') },
        qr/name called without a preceding compatible declaration/,
        'name requires a preceding compatible declaration';
    like dies { $empty->desc('missing') },
        qr/desc called without a preceding compatible declaration/,
        'desc requires a preceding compatible declaration';
    like dies { $empty->constraints(id => qr/.+/) },
        qr/constraints called without a preceding compatible declaration/,
        'constraints requires a preceding compatible declaration';
    like dies { $builder->name('with/slash') }, qr/name must be one logical address segment/,
        'name uses shared logical segment validation';
    like dies { $builder->desc([]) }, qr/desc must be a string/,
        'description uses shared text validation';
    like dies { $builder->constraints('id') }, qr/constraints option list must be key\/value pairs/,
        'constraints require key/value pairs';
};

subtest 'materialization defers immutable HTTP normalization to Route' => sub {
    my $builder = PAGI::App::Router::Builder->new;
    my $handler = sub { };

    $builder->get('/get' => $handler);
    $builder->route('/rpc' => $handler, methods => ['RPC']);
    $builder->any('/any' => $handler);
    $builder->websocket('/socket' => $handler);
    $builder->sse('/events' => $handler);

    my $nodes = $builder->_materialize_nodes(undef);
    is([map { [$_->kind, $_->methods, $_->path] } @$nodes], [
        ['route', ['GET', 'HEAD'], '/get'],
        ['route', ['RPC'], '/rpc'],
        ['route', '*', '/any'],
        ['websocket', undef, '/socket'],
        ['sse', undef, '/events'],
    ], 'immutable Route owns method normalization, including automatic HEAD');
};

done_testing;
