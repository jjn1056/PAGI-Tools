#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::App::Router;
use PAGI::Routing qw(route router);
use PAGI::Test::Client;

{
    package Local::CountingAppRouter;
    our @ISA = ('PAGI::App::Router');

    sub _materialize_with {
        my ($self, $materializer) = @_;
        ++$self->{materializations};
        return $self->SUPER::_materialize_with($materializer);
    }
}

sub handler {
    my ($body) = @_;
    return sub { return $_[0]->text($body) };
}

sub native_app {
    my ($body, $calls) = @_;
    return async sub {
        my ($scope, $receive, $send) = @_;
        ++$$calls if $calls;
        await Future->wrap($send->({
            type => 'http.response.start', status => 200, headers => [],
        }));
        await Future->wrap($send->({
            type => 'http.response.body', body => $body, more => 0,
        }));
        return;
    };
}

subtest 'routes callback creates one synchronous child declaration' => sub {
    my ($child, $callback_calls);
    my $parent = Local::CountingAppRouter->new;
    my $returned = $parent->mount('/api', routes => sub {
        ($child) = @_;
        ++$callback_calls;
        $child->get('/users' => handler('users'))->name('users');
        return 'ignored';
    })->name('api');

    is($returned, $parent, 'mount and its modifier return the parent');
    isa_ok($child, 'PAGI::App::Router');
    isnt(refaddr($child), refaddr($parent), 'the callback receives a fresh child');
    is($callback_calls, 1, 'the callback runs synchronously exactly once');

    my $snapshot = $parent->to_router;
    is([$parent->{materializations}, $child->{materializations}], [1, 1],
        'the parent and callback child each materialize once per snapshot');
    my $mount = $snapshot->routes->[0];
    is([$mount->kind, $mount->path, $mount->name],
        ['mount', '/api', 'api'], 'the callback occupies one Mount position');
    isa_ok($mount->app, 'PAGI::Routing::Router');
    is([map { [$_->kind, $_->path, $_->name] } @{$mount->app->routes}],
        [['route', '/users', 'users']],
        'callback declarations become a real child Router application');
    is($snapshot->path_for('/api/users'), '/api/users',
        'the immutable child is discoverable through the named Mount');

    $child->get('/late' => handler('late'))->name('late');
    is([map { $_->path } @{$mount->app->routes}], ['/users'],
        'later child mutation cannot alter the retained snapshot');
    is([map { $_->path } @{$parent->to_router->routes->[0]->app->routes}],
        ['/users', '/late'], 'a later snapshot rebuilds the callback child');
    is([$parent->{materializations}, $child->{materializations}], [2, 2],
        'a second snapshot materializes each frontend exactly once again');
    is($callback_calls, 1, 'snapshotting never reruns the declaration callback');
};

subtest 'array routes and application mounts share one immutable shape' => sub {
    my $opaque_calls = 0;
    my $opaque = native_app('opaque', \$opaque_calls);
    my $named_child = router(routes => [
        route('/named' => handler('named'), name => 'leaf'),
    ]);
    my $unnamed_child = router(routes => [
        route('/unnamed' => handler('unnamed'), name => 'plain'),
    ]);

    my $builder = PAGI::App::Router->new;
    $builder->get('/first' => handler('first'));
    $builder->mount('/array', routes => [
        route('/leaf' => handler('array'), name => 'leaf'),
    ])->name('array');
    $builder->mount('/opaque', app => $opaque)->desc('opaque app');
    $builder->mount('/named', app => $named_child)->name('named');
    $builder->mount('/plain', app => $unnamed_child);
    $builder->get('/last' => handler('last'));

    my $nodes = $builder->to_router->routes;
    is([map { [$_->kind, $_->path] } @$nodes], [
        ['route', '/first'],
        ['mount', '/array'],
        ['mount', '/opaque'],
        ['mount', '/named'],
        ['mount', '/plain'],
        ['route', '/last'],
    ], 'routes and app Mounts remain at their written positions');
    isa_ok($nodes->[1]->app, 'PAGI::Routing::Router');
    is(refaddr($nodes->[2]->app), refaddr($opaque),
        'an opaque app is retained by identity');
    is(refaddr($nodes->[3]->app), refaddr($named_child),
        'a named immutable Router app retains identity');
    is(refaddr($nodes->[4]->app), refaddr($unnamed_child),
        'an unnamed immutable Router app retains identity');
    is([sort keys %{$builder->named_routes}],
        ['/array/leaf', '/named/leaf', '/plain'],
        'named and unnamed Router applications expose discoverable leaves');

    my $client = PAGI::Test::Client->new(app => $builder->to_app);
    is($client->get('/array/leaf')->text, 'array', 'array shorthand dispatches');
    is($client->get('/opaque/anything')->text, 'opaque', 'opaque app dispatches');
    is($opaque_calls, 1, 'the selected opaque app runs once for one request');
};

subtest 'Mount middleware is named and first-listed outermost' => sub {
    my (@build, @runtime);
    my $factory = sub {
        my ($label) = @_;
        return sub {
            my ($inner) = @_;
            push @build, $label;
            return async sub {
                push @runtime, "$label before";
                await Future->wrap($inner->(@_));
                push @runtime, "$label after";
                return;
            };
        };
    };
    my $builder = PAGI::App::Router->new;
    $builder->mount('/api',
        routes => sub {
            $_[0]->get('/item' => sub {
                push @runtime, 'handler';
                return $_[0]->text('item');
            });
        },
        middleware => [$factory->('outer'), $factory->('inner')],
    );

    my $app = $builder->to_app;
    is(\@build, ['inner', 'outer'], 'Mount wrappers build inner to outer');
    is(PAGI::Test::Client->new(app => $app)->get('/api/item')->text,
        'item', 'the wrapped Mount dispatches');
    is(\@runtime, [
        'outer before', 'inner before', 'handler',
        'inner after', 'outer after',
    ], 'the first Mount middleware entry is outermost');
};

subtest 'only app or routes named grammar is accepted' => sub {
    my $app = native_app('app');
    my $immutable = router(routes => []);

    ok(!PAGI::App::Router->new->can('group'), 'group is absent');
    like(dies { PAGI::App::Router->new->group('/x' => sub { }) },
        qr/locate object method "group"/, 'group has no hidden compatibility path');
    like(dies { PAGI::App::Router->new->mount('/x' => $app) },
        qr/mount option list must be key\/value pairs|unknown mount option/,
        'a positional application target is rejected');
    like(dies { PAGI::App::Router->new->mount('/x', router => $immutable) },
        qr/unknown mount option 'router'/, 'router target mode is rejected');
    like(dies { PAGI::App::Router->new->mount('/x') },
        qr/mount requires exactly one of app or routes/,
        'a Mount requires a target option');
    like(dies {
        PAGI::App::Router->new->mount('/x', app => $app, routes => []);
    }, qr/mount requires exactly one of app or routes/,
        'a Mount cannot have both app and routes');
    like(dies { PAGI::App::Router->new->mount('/x', routes => 'No::Routes') },
        qr/mount routes must be an arrayref or callback/,
        'routes rejects strings');
    like(dies { PAGI::App::Router->new->mount('/x', app => 'No::App') },
        qr/mount app must be a coderef or instantiated object with to_app/,
        'app rejects package strings without loading them');
    like(dies {
        PAGI::App::Router->new->mount('/x' => [sub { $_[0] }], app => $app);
    }, qr/mount option list must be key\/value pairs|mount option names must be strings/,
        'positional Mount middleware is rejected');
    like(dies {
        PAGI::App::Router->new->mount('/x', app => $app, name => 'x');
    }, qr/unknown mount option 'name'/,
        'name remains a chained modifier rather than a Mount option');
    ok(!$INC{'No/App.pm'}, 'rejected package app was not loaded');
};

done_testing;
