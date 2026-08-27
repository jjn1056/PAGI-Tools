#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;

use lib 'lib';
use PAGI::App::Router;
use PAGI::Context ();
use PAGI::Response ();
use PAGI::Routing::URL qw(path_for);
use PAGI::Stash qw(stash);

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

subtest 'App Router HTTP handlers receive one Request while Context remains available' => sub {
    ok(PAGI::Context->can('new'),
        'the standalone Context family is not removed by the routing migration');
    my @seen;
    my $router = PAGI::App::Router->new;
    $router->get('/hello' => sub {
        my ($request) = @_;
        push @seen, [ref($request), scalar @_];
        return PAGI::Response->text('Hello!');
    });
    $router->get('/users/{id}' => sub {
        my ($request) = @_;
        push @seen, [ref($request), scalar @_, $request->path_param('id')];
        return PAGI::Response->json({ id => $request->path_param('id') });
    });
    my $app = $router->to_app;

    is(body(run_scope($app, path => '/hello')), 'Hello!',
        'HTTP Request handler returns an immediate Response');
    like(body(run_scope($app, path => '/users/42')), qr/"id"\s*:\s*"?42"?/,
        'Request sees the shared capture');
    is(\@seen, [
        ['PAGI::Request', 1],
        ['PAGI::Request', 1, 42],
    ], 'ordinary HTTP handlers never receive native channels');
};

subtest 'App Router WebSocket and SSE handlers receive direct protocol objects' => sub {
    my @seen;
    my $router = PAGI::App::Router->new;
    $router->websocket('/ws/echo/{room}' => sub {
        my ($websocket) = @_;
        push @seen, [ref($websocket), scalar @_, $websocket->path_param('room')];
        $websocket->accept->get;
        return $websocket->close(1000, 'done');
    });
    $router->sse('/events/{channel}' => sub {
        my ($sse) = @_;
        push @seen, [ref($sse), scalar @_, $sse->path_param('channel')];
        return $sse->send_event(
            event => 'connected', data => { channel => $sse->path_param('channel') },
        );
    });
    my $app = $router->to_app;

    my $ws = run_scope($app,
        type => 'websocket', method => undef, path => '/ws/echo/test-room');
    my $sse = run_scope($app,
        type => 'sse', method => undef, path => '/events/news');
    is([map { $_->{type} } @$ws], ['websocket.accept', 'websocket.close'],
        'WebSocket object owns protocol events');
    ok((grep { ($_->{type} // '') eq 'sse.send' } @$sse),
        'SSE object owns protocol events');
    is(\@seen, [
        ['PAGI::WebSocket', 1, 'test-room'],
        ['PAGI::SSE', 1, 'news'],
    ], 'protocol handlers receive exactly one typed protocol object');
};

subtest 'native middleware can add Request-visible helper state' => sub {
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
        my ($request) = @_;
        push @seen, [
            $request->state->get('db'),
            stash($request)->get('user')->{id},
            $request->header('authorization'),
        ];
        return PAGI::Response->json({
            user_id => stash($request)->get('user')->{id},
        });
    });

    my $events = run_scope(
        $router->to_app,
        path => '/protected',
        state => {},
        headers => [['authorization', 'Bearer valid']],
    );
    like(body($events), qr/"user_id"\s*:\s*1/,
        'Request handler returns state derived from middleware');
    is(\@seen, [['connected', 1, 'Bearer valid']],
        'Request and explicit helper expose data from the routed scope');
};

subtest 'routing metadata enables relative Request reverse routing' => sub {
    my @seen;
    my $router = PAGI::App::Router->new;
    $router->mount('/people/{person_id}', routes => sub {
        my ($people) = @_;
        $people->get('/profile' => sub {
            my ($request) = @_;
            my $frame = $request->scope->{'pagi.routing'}{frames}[-1];
            push @seen, {
                path => path_for($request, 'show'),
                name => $frame->{match}{name},
                namespace => $frame->{logical_namespace},
                has_old => exists $request->scope->{'pagi.router'} ? 1 : 0,
            };
            return PAGI::Response->text($seen[-1]{path});
        })->name('show');
    })->name('people');

    is(body(run_scope($router->to_app, path => '/people/7/profile')),
        '/people/7/profile', 'relative link inherits the active capture');
    is(\@seen, [{
        path => '/people/7/profile',
        name => '/people/show',
        namespace => '/people',
        has_old => 0,
    }], 'Request URL helper consumes shared pagi.routing metadata only');
};

done_testing;
