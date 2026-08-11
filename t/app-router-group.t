#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::App::Router;

sub run_scope {
    my ($app, %scope) = @_;
    my @events;
    my $receive = sub {
        return Future->done({ type => 'http.request', body => '', more => 0 });
    };
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    $app->({
        type => 'http', method => 'GET', path => '/', headers => [], %scope,
    }, $receive, $send)->get;
    return \@events;
}

sub body {
    my ($events) = @_;
    return join '', map { $_->{body} // '' }
        grep { ($_->{type} // '') eq 'http.response.body' } @$events;
}

sub handler {
    my ($label, $seen) = @_;
    return sub {
        my ($c) = @_;
        push @$seen, {
            label => $label,
            scope => $c->scope,
            params => $c->path_params,
        } if $seen;
        return $c->text($label);
    };
}

subtest 'a callback group is one fresh structural child' => sub {
    my ($child, $callback_calls);
    my $parent = PAGI::App::Router->new;
    my $returned = $parent->group('/api' => sub {
        ($child) = @_;
        ++$callback_calls;
        $child->get('/users' => handler('users'))->name('users');
        return 'ignored';
    })->name('api');

    is($returned, $parent, 'group and its modifier return the parent builder');
    isa_ok($child, 'PAGI::App::Router');
    isnt(refaddr($child), refaddr($parent), 'the callback never reuses the parent');
    is($callback_calls, 1, 'configuration callback runs synchronously once');

    my $snapshot = $parent->to_router;
    my $group = $snapshot->routes->[0];
    is([$group->kind, $group->path, $group->name], ['mount', '/api', 'api'],
        'the group occupies one parent node');
    is([map { [$_->kind, $_->path, $_->name] } @{$group->routes}],
        [['route', '/users', 'users']],
        'the callback declarations remain local to its inline child');
    is($parent->path_for('/api/users'), '/api/users',
        'the named group contributes one slash address segment');
};

subtest 'group prefixes, captures, and parent siblings dispatch normally' => sub {
    my @seen;
    my $router = PAGI::App::Router->new;
    $router->get('/health' => handler('health', \@seen));
    $router->group('/orgs/{org_id}' => sub {
        my ($org) = @_;
        $org->get('/info' => handler('info', \@seen));
        $org->group('/teams/{team_id}' => sub {
            my ($team) = @_;
            $team->get('/members' => handler('members', \@seen));
        });
    });
    my $app = $router->to_app;

    is(body(run_scope($app, path => '/health')), 'health',
        'a parent sibling remains reachable');
    @seen = ();
    is(body(run_scope($app, path => '/orgs/acme/info')), 'info',
        'an outer grouped route dispatches');
    is($seen[0]{params}, { org_id => 'acme' }, 'outer prefix capture reaches Context');
    @seen = ();
    is(body(run_scope($app, path => '/orgs/acme/teams/eng/members')), 'members',
        'a nested grouped route dispatches');
    is($seen[0]{params}, { org_id => 'acme', team_id => 'eng' },
        'nested prefix captures accumulate');
    is(run_scope($app, path => '/teams/eng/members')->[0]{status}, 404,
        'group paths are required');
};

subtest 'group and route middleware remain separate onion layers' => sub {
    my @order;
    my $middleware = sub {
        my ($label) = @_;
        return sub {
            my ($inner) = @_;
            return sub {
                push @order, "$label before";
                my $result = $inner->(@_);
                $result->on_ready(sub { push @order, "$label after" });
                return $result;
            };
        };
    };

    my $router = PAGI::App::Router->new;
    $router->group('/api' => [$middleware->('group')] => sub {
        my ($api) = @_;
        $api->get('/data' => [$middleware->('route')] => sub {
            push @order, 'handler';
            return $_[0]->text('data');
        });
    });

    is(body(run_scope($router->to_app, path => '/api/data')), 'data',
        'the wrapped group handler responds');
    is(\@order, [
        'group before', 'route before', 'handler', 'route after', 'group after',
    ], 'group middleware wraps route middleware exactly once');
};

subtest 'group naming uses local segments and canonical slash addresses' => sub {
    my $router = PAGI::App::Router->new;
    $router->group('/api/v1' => sub {
        my ($v1) = @_;
        $v1->get('/users' => handler('users'))->name('list');
        $v1->get('/users/{id}' => handler('user'))->name('show');
    })->name('v1');

    is([sort keys %{$router->named_routes}], ['/v1/list', '/v1/show'],
        'group and leaf segments form canonical slash addresses');
    is($router->path_for('/v1/list'), '/api/v1/users',
        'a named grouped route includes its path prefix');
    is($router->path_for('/v1/show', { id => 5 }), '/api/v1/users/5',
        'grouped reverse routing renders parameters');
    my $literal_dot = PAGI::App::Router->new;
    $literal_dot->group('/api' => sub {
        $_[0]->get('/x' => handler('x'))->name('show');
    })->name('api.v1');
    is($literal_dot->path_for('/api.v1/show'), '/api/x',
        'a dot in one local name stays a literal address component');
    like(dies { $literal_dot->path_for('/api/v1/show') },
        qr/unknown route name/, 'dots never expand into hierarchy separators');
};

subtest 'group constraints and generated outcomes remain subtree owned' => sub {
    my $router = PAGI::App::Router->new;
    $router->group('/api/{version}' => sub {
        my ($api) = @_;
        $api->get('/items/{id:\d+}' => handler('item'));
        $api->post('/items/{id:\d+}' => handler('create'));
    })->name('api')->desc('API version')->constraints(version => qr/\Av\d+\z/);
    my $app = $router->to_app;

    is(body(run_scope($app, path => '/api/v2/items/7')), 'item',
        'group and leaf constraints both qualify dispatch');
    is(run_scope($app, path => '/api/latest/items/7')->[0]{status}, 404,
        'a rejected group constraint is no match');
    my $partial = run_scope($app, method => 'DELETE', path => '/api/v2/items/7');
    is($partial->[0]{status}, 405, 'the inline subtree owns its 405');
    my ($allow) = map { $_->[1] }
        grep { lc($_->[0]) eq 'allow' } @{$partial->[0]{headers}};
    is($allow, 'GET, HEAD, POST', 'grouped siblings retain first-seen Allow order');

    my $mount = $router->to_router->routes->[0];
    is([$mount->desc, ref($mount->constraints->{version})],
        ['API version', 'Regexp'],
        'group metadata and normalized constraints reach the immutable mount');
};

subtest 'groups can contain normal WebSocket and SSE Context handlers' => sub {
    my @seen;
    my $router = PAGI::App::Router->new;
    $router->group('/realtime' => sub {
        my ($realtime) = @_;
        $realtime->websocket('/chat/{room}' => sub {
            push @seen, [ref($_[0]), $_[0]->path_param('room')];
            return Future->done;
        });
        $realtime->sse('/events/{channel}' => sub {
            push @seen, [ref($_[0]), $_[0]->path_param('channel')];
            return Future->done;
        });
    });
    my $app = $router->to_app;

    run_scope($app, type => 'websocket', method => undef, path => '/realtime/chat/general');
    run_scope($app, type => 'sse', method => undef, path => '/realtime/events/news');
    is(\@seen, [
        ['PAGI::Context::WebSocket', 'general'],
        ['PAGI::Context::SSE', 'news'],
    ], 'protocol Contexts preserve group captures and kinds');
};

subtest 'removed group target forms fail without loading or copying routers' => sub {
    my $router = PAGI::App::Router->new;
    my $other = PAGI::App::Router->new;

    like(dies { $router->group('/api' => $other) },
        qr/group requires a callback/, 'a group never copies another mutable router');
    like(dies { $router->group('/api' => 'TestRoutes::Users') },
        qr/group requires a callback/, 'a group never loads a route package');
    like(dies { $router->group('/api' => { invalid => 1 }) },
        qr/group requires a callback/, 'a group accepts only a callback target');
    ok(!TestRoutes::Users->can('router'),
        'the rejected package spelling did not load the package');
};

done_testing;
