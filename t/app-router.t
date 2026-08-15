#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;

use lib 'lib';
use PAGI::App::Router;
use PAGI::Compose qw(compose);

sub channels {
    my @events;
    my $receive = sub {
        return Future->done({ type => 'http.request', body => '', more => 0 });
    };
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    return ($receive, $send, \@events);
}

sub run_scope {
    my ($app, %scope) = @_;
    my ($receive, $send, $events) = channels();
    $app->({
        type => 'http',
        method => 'GET',
        path => '/',
        headers => [],
        %scope,
    }, $receive, $send)->get;
    return $events;
}

sub response_body {
    my ($events) = @_;
    return join '', map { $_->{body} // '' }
        grep { ($_->{type} // '') eq 'http.response.body' } @$events;
}

sub response_header {
    my ($events, $name) = @_;
    my ($start) = grep { ($_->{type} // '') eq 'http.response.start' } @$events;
    return unless $start;
    for my $pair (@{$start->{headers} // []}) {
        return $pair->[1] if lc($pair->[0]) eq lc($name);
    }
    return;
}

sub handler {
    my ($label, $calls) = @_;
    return sub {
        my ($c) = @_;
        push @$calls, {
            label => $label,
            scope => $c->scope,
            params => $c->path_params,
        } if $calls;
        return $c->text($label);
    };
}

subtest 'ordinary HTTP routing uses Context handlers and shared path grammar' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;
    $router->get('/users' => handler('list', \@calls));
    $router->get('/users/{id}' => handler('show', \@calls));
    $router->post('/users' => handler('create', \@calls));
    $router->get('/files/*path' => handler('file', \@calls));
    my $app = compose(app => $router)->to_app;

    is(response_body(run_scope($app, path => '/users')), 'list',
        'a static route dispatches');
    @calls = ();
    is(response_body(run_scope($app, path => '/users/42')), 'show',
        'a brace parameter route dispatches');
    is($calls[0]{params}, { id => 42 }, 'the Context exposes captured parameters');
    is(response_body(run_scope($app, method => 'POST', path => '/users')), 'create',
        'method siblings share a path');
    @calls = ();
    is(response_body(run_scope($app, path => '/files/docs/readme.txt')), 'file',
        'the terminal wildcard route dispatches');
    is($calls[0]{params}, { path => 'docs/readme.txt' },
        'the wildcard preserves its remaining path');

    my $missing = run_scope($app, path => '/missing');
    is($missing->[0]{status}, 404,
        'an unknown path receives the Compose automatic 404');
    is(response_header($missing, 'Content-Type'), 'text/html; charset=utf-8',
        'the automatic 404 uses the negotiated Pages representation');
    like(response_body($missing), qr{<h1>Not Found</h1>},
        'the automatic 404 renders the Pages not-found body');
    my $wrong = run_scope($app, method => 'DELETE', path => '/users');
    is([$wrong->[0]{status}, response_header($wrong, 'Allow')],
        [405, 'GET, HEAD, POST'],
        'PARTIAL siblings produce the first-seen shared Allow value');
};

subtest 'literal paths and constraints use the shared Pattern implementation' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;
    $router->get('/api/v1.0/report[2024]' => handler('literal', \@calls));
    $router->get('/people/{id:\d+}' => handler('number', \@calls));
    $router->get('/people/{name:[A-Za-z]+}' => handler('name', \@calls));
    $router->get('/posts/{slug}' => handler('post', \@calls))
        ->constraints(slug => qr/\A[a-z0-9-]+\z/);
    my $app = compose(app => $router)->to_app;

    is(response_body(run_scope($app, path => '/api/v1.0/report[2024]')), 'literal',
        'regex metacharacters remain literal path text');
    is(run_scope($app, path => '/api/v1X0/report[2024]')->[0]{status}, 404,
        'a literal dot is not a wildcard');
    is(response_body(run_scope($app, path => '/people/42')), 'number',
        'an inline numeric constraint selects its route');
    is(response_body(run_scope($app, path => '/people/Alice')), 'name',
        'constraint failure continues to a later declaration');
    is(run_scope($app, path => '/people/a1')->[0]{status}, 404,
        'failure of every inline constraint is NONE');
    is(response_body(run_scope($app, path => '/posts/first-post')), 'post',
        'a chained constraint accepts an exact value');
    is(run_scope($app, path => '/posts/BAD')->[0]{status}, 404,
        'a chained constraint rejects before handler invocation');

    like(dies { PAGI::App::Router->new->constraints(id => qr/.+/) },
        qr/constraints called without a preceding compatible declaration/,
        'constraints requires a compatible declaration');
    like(dies {
        my $bad = PAGI::App::Router->new;
        $bad->get('/bad/{id}' => handler('bad'))
            ->constraints(id => 'not a constraint');
        $bad->to_router;
    }, qr/constraint 'id' must be/, 'invalid constraint values use shared validation');
};

subtest 'any and generic route declarations replace the old method option' => sub {
    my $router = PAGI::App::Router->new;
    $router->any('/health' => handler('health'));
    $router->route('/resource' => handler('resource'), methods => ['GET', 'POST']);
    my $app = compose(app => $router)->to_app;

    for my $method (qw(GET POST PUT DELETE PATCH HEAD OPTIONS)) {
        is(run_scope($app, method => $method, path => '/health')->[0]{status}, 200,
            "any dispatches $method");
    }
    is(response_body(run_scope($app, method => 'POST', path => '/resource')),
        'resource', 'generic route accepts an explicit method list');
    my $wrong = run_scope($app, method => 'DELETE', path => '/resource');
    is([$wrong->[0]{status}, response_header($wrong, 'Allow')],
        [405, 'GET, HEAD, POST'], 'generic methods drive the 405 result');
    like(dies {
        PAGI::App::Router->new->any('/old' => handler('old'), method => ['GET']);
    }, qr/unknown route option 'method'/, 'the old any method option is not retained');
};

subtest 'opaque and routing-aware mounts remain distinct' => sub {
    my @calls;
    my $child = PAGI::App::Router->new;
    $child->get('/users/{id}' => handler('child', \@calls))->name('show');

    my $opaque = sub {
        my ($scope, $receive, $send) = @_;
        push @calls, { label => 'opaque', scope => $scope };
        $send->({ type => 'http.response.start', status => 200, headers => [] })->get;
        $send->({ type => 'http.response.body', body => 'opaque', more => 0 })->get;
        return Future->done;
    };

    my $router = PAGI::App::Router->new;
    $router->mount('/people', router => $child)->name('people');
    $router->mount('/assets' => $opaque);
    my $app = $router->to_app;

    is(response_body(run_scope($app, path => '/people/users/7')), 'child',
        'a routing-aware mount dispatches its immutable child');
    is($calls[0]{scope}{path}, '/users/7', 'the mount rewrites the child path');
    is($calls[0]{scope}{root_path}, '/people', 'the mount extends root_path');
    is($router->path_for('/people/show', { id => 7 }), '/people/users/7',
        'a routing-aware mount exposes child names');

    @calls = ();
    is(response_body(run_scope($app, path => '/assets/css/site.css')), 'opaque',
        'an opaque mount owns the matching prefix');
    is($calls[0]{scope}{path}, '/css/site.css', 'opaque mount receives a stripped path');
    is($router->route_named('/assets/hidden'), undef,
        'opaque internals are not inspectable');

    like(dies { PAGI::App::Router->new->mount('/bad' => $child) },
        qr/mutable router frontend cannot be used as a opaque mount target/,
        'mutable frontends require router => at known boundaries');
    like(dies { PAGI::App::Router->new->mount('/bad' => 'TestRoutes::Admin') },
        qr/opaque mount target must be a coderef or object with to_app/,
        'mounts do not load package-name strings');
};

subtest 'written mount order replaces longest-prefix sorting' => sub {
    my $native = sub {
        my ($label) = @_;
        return sub {
            my ($scope, $receive, $send) = @_;
            $send->({ type => 'http.response.start', status => 200, headers => [] })->get;
            $send->({ type => 'http.response.body', body => $label, more => 0 })->get;
            return Future->done;
        };
    };

    my $broad_first = PAGI::App::Router->new;
    $broad_first->mount('/api' => $native->('broad'));
    $broad_first->mount('/api/v2' => $native->('specific'));
    is(response_body(run_scope($broad_first->to_app, path => '/api/v2/info')),
        'broad', 'an earlier broad mount owns before a longer prefix');

    my $specific_first = PAGI::App::Router->new;
    $specific_first->mount('/api/v2' => $native->('specific'));
    $specific_first->mount('/api' => $native->('broad'));
    is(response_body(run_scope($specific_first->to_app, path => '/api/v2/info')),
        'specific', 'putting the specific mount first changes ownership');
};

subtest 'normal WebSocket and SSE declarations receive protocol Contexts' => sub {
    my @seen;
    my $router = PAGI::App::Router->new;
    $router->websocket('/ws/{room}' => sub {
        my ($c) = @_;
        push @seen, [ref($c), $c->path_param('room')];
        return Future->done;
    });
    $router->sse('/events/{channel}' => sub {
        my ($c) = @_;
        push @seen, [ref($c), $c->path_param('channel')];
        return Future->done;
    });
    my $app = $router->to_app;

    run_scope($app, type => 'websocket', method => undef, path => '/ws/lobby');
    run_scope($app, type => 'sse', method => undef, path => '/events/news');
    is(\@seen, [
        ['PAGI::Context::WebSocket', 'lobby'],
        ['PAGI::Context::SSE', 'news'],
    ], 'protocol-specific Contexts receive shared captures');

    my $miss = run_scope(
        $app,
        type => 'websocket',
        method => undef,
        path => '/ws/missing/extra',
        extensions => { 'websocket.http.response' => {} },
    );
    is($miss->[0]{status}, 404, 'an unmatched protocol route uses the shared decline');
    is(run_scope($app, type => 'lifespan'), [], 'compiled routing ignores lifespan');
};

subtest 'immutable inspection replaces private public route arrays' => sub {
    my $router = PAGI::App::Router->new;
    $router->get('/users/{id:\d+}' => handler('user'))
        ->name('user')
        ->constraints(id => qr/\A\d+\z/);
    my $snapshot = $router->to_router;
    my $route = $snapshot->route_named('/user');

    is([$route->kind, $route->path, $route->name, $route->methods],
        ['route', '/users/{id:\d+}', 'user', ['GET', 'HEAD']],
        'the immutable route exposes normalized public metadata');
    is($snapshot->path_for('/user', { id => 9 }), '/users/9',
        'inspection and reverse routing use the same immutable constraint');
    like(dies { $snapshot->path_for('/user', { id => 'nine' }) },
        qr/failed constraint/, 'reverse routing rejects an invalid value');
};

done_testing;
