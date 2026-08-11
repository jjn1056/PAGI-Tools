#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;

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

subtest 'App Router HTTP handlers receive one Context' => sub {
    my @seen;
    my $router = PAGI::App::Router->new;
    $router->get('/hello' => sub {
        my ($c) = @_;
        push @seen, [ref($c), scalar @_];
        return $c->text('Hello!');
    });
    $router->get('/users/{id}' => sub {
        my ($c) = @_;
        push @seen, [ref($c), scalar @_, $c->request->path_param('id')];
        return $c->json({ id => $c->path_param('id') });
    });
    my $app = $router->to_app;

    is(body(run_scope($app, path => '/hello')), 'Hello!',
        'HTTP Context returns an immediate Response');
    like(body(run_scope($app, path => '/users/42')), qr/"id"\s*:\s*"?42"?/,
        'request and Context see the shared capture');
    is(\@seen, [
        ['PAGI::Context::HTTP', 1],
        ['PAGI::Context::HTTP', 1, 42],
    ], 'ordinary HTTP handlers never receive native channels');
};

subtest 'App Router WebSocket and SSE handlers receive their Context subclasses' => sub {
    my @seen;
    my $router = PAGI::App::Router->new;
    $router->websocket('/ws/echo/{room}' => sub {
        my ($c) = @_;
        push @seen, [ref($c), scalar @_, $c->websocket->path_param('room')];
        $c->accept->get;
        return $c->close(1000, 'done');
    });
    $router->sse('/events/{channel}' => sub {
        my ($c) = @_;
        push @seen, [ref($c), scalar @_, $c->sse->path_param('channel')];
        return $c->send_event(
            event => 'connected', data => { channel => $c->path_param('channel') },
        );
    });
    my $app = $router->to_app;

    my $ws = run_scope($app,
        type => 'websocket', method => undef, path => '/ws/echo/test-room');
    my $sse = run_scope($app,
        type => 'sse', method => undef, path => '/events/news');
    is([map { $_->{type} } @$ws], ['websocket.accept', 'websocket.close'],
        'WebSocket Context owns protocol events');
    ok((grep { ($_->{type} // '') eq 'sse.send' } @$sse),
        'SSE Context owns protocol events');
    is(\@seen, [
        ['PAGI::Context::WebSocket', 1, 'test-room'],
        ['PAGI::Context::SSE', 1, 'news'],
    ], 'protocol handlers receive exactly one typed Context');
};

subtest 'native middleware can add Context-visible state' => sub {
    my @seen;
    my $middleware = sub {
        my ($inner) = @_;
        return sub {
            my ($scope, $receive, $send) = @_;
            $scope->{state}{db} = 'connected';
            $scope->{'pagi.stash'}{user} = { id => 1 };
            return $inner->($scope, $receive, $send);
        };
    };
    my $router = PAGI::App::Router->new;
    $router->get('/protected' => [$middleware] => sub {
        my ($c) = @_;
        push @seen, [
            $c->state->{db},
            $c->stash->get('user')->{id},
            $c->header('authorization'),
        ];
        return $c->json({ user_id => $c->stash->get('user')->{id} });
    });

    my $events = run_scope(
        $router->to_app,
        path => '/protected',
        state => {},
        headers => [['authorization', 'Bearer valid']],
    );
    like(body($events), qr/"user_id"\s*:\s*1/,
        'Context handler returns state derived from middleware');
    is(\@seen, [['connected', 1, 'Bearer valid']],
        'Context exposes state, stash, and headers from its routed scope');
};

subtest 'routing metadata enables relative Context reverse routing' => sub {
    my @seen;
    my $router = PAGI::App::Router->new;
    $router->group('/people/{person_id}' => sub {
        my ($people) = @_;
        $people->get('/profile' => sub {
            my ($c) = @_;
            my $frame = $c->scope->{'pagi.routing'}{frames}[-1];
            push @seen, {
                path => $c->path_for('show'),
                name => $frame->{match}{name},
                namespace => $frame->{logical_namespace},
                has_old => exists $c->scope->{'pagi.router'} ? 1 : 0,
            };
            return $c->text($seen[-1]{path});
        })->name('show');
    })->name('people');

    is(body(run_scope($router->to_app, path => '/people/7/profile')),
        '/people/7/profile', 'relative link inherits the active capture');
    is(\@seen, [{
        path => '/people/7/profile',
        name => '/people/show',
        namespace => '/people',
        has_old => 0,
    }], 'Context consumes shared pagi.routing metadata only');
};

done_testing;
