#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::App::Router;
use PAGI::Test::Client;

sub raw_http_app {
    my ($argument_counts) = @_;
    return sub {
        my ($scope, $receive, $send) = @_;
        push @$argument_counts, scalar @_;
        $send->({
            type => 'http.response.start',
            status => 209,
            headers => [['content-type', 'text/plain']],
        })->get;
        $send->({
            type => 'http.response.body',
            body => 'raw ' . $scope->{path_params}{id},
            more => 0,
        })->get;
        return Future->done;
    };
}

subtest 'ordinary HTTP targets receive Context and emit immediate or Future Responses' => sub {
    my @normal_kinds;
    my $router = PAGI::App::Router->new;
    $router->get('/immediate/{id}' => sub {
        my ($c) = @_;
        push @normal_kinds, [ref($c), scalar @_];
        return $c->response->status(201)->text('immediate ' . $c->path_param('id'));
    });
    $router->get('/future' => sub {
        my ($c) = @_;
        push @normal_kinds, [ref($c), scalar @_];
        return Future->done($c->response->status(202)->text('future'));
    });

    my $client = PAGI::Test::Client->new(app => $router->to_app);
    my $immediate = $client->get('/immediate/42');
    my $future = $client->get('/future');

    is([$immediate->status, $immediate->content], [201, 'immediate 42'],
        'an immediate Response is emitted through the shared adapter');
    is([$future->status, $future->content], [202, 'future'],
        'a Future-backed Response is emitted through the same adapter');
    is(\@normal_kinds, [
        ['PAGI::Context::HTTP', 1],
        ['PAGI::Context::HTTP', 1],
    ], 'ordinary HTTP handlers receive only an HTTP Context');
};

subtest 'explicit raw HTTP targets retain all three native channels' => sub {
    my @raw_argument_counts;
    my $router = PAGI::App::Router->new;
    $router->get('/raw/{id}', raw => raw_http_app(\@raw_argument_counts));

    my $client = PAGI::Test::Client->new(app => $router->to_app);
    my $raw = $client->get('/raw/7');

    is([$raw->status, $raw->content], [209, 'raw 7'],
        'an explicit raw HTTP route owns native response events');
    is(\@raw_argument_counts, [3], 'a raw HTTP route receives all three PAGI channels');
};

subtest 'ordinary and raw WebSocket targets receive their declared contracts' => sub {
    my (@normal, @raw);
    my $router = PAGI::App::Router->new;
    $router->websocket('/ws/{room}' => sub {
        my ($c) = @_;
        push @normal, [ref($c), scalar @_, $c->path_param('room')];
        $c->accept->get;
        $c->send_text('normal ' . $c->path_param('room'))->get;
        return $c->close(1000, 'done');
    });
    $router->websocket('/raw-ws/{room}', raw => sub {
        my ($scope, $receive, $send) = @_;
        push @raw, [scalar @_, $scope->{path_params}{room}];
        $receive->()->get;
        $send->({ type => 'websocket.accept' })->get;
        $send->({ type => 'websocket.send', text => 'raw ' . $scope->{path_params}{room} })->get;
        $send->({ type => 'websocket.close', code => 1000, reason => 'done' })->get;
        return Future->done;
    });

    my $client = PAGI::Test::Client->new(app => $router->to_app);
    $client->websocket('/ws/lobby', sub {
        my ($ws) = @_;
        is($ws->receive_text, 'normal lobby', 'normal WebSocket Context emitted text');
    });
    $client->websocket('/raw-ws/native', sub {
        my ($ws) = @_;
        is($ws->receive_text, 'raw native', 'raw WebSocket app emitted text');
    });

    is(\@normal, [['PAGI::Context::WebSocket', 1, 'lobby']],
        'ordinary WebSocket handler receives only its Context subclass');
    is(\@raw, [[3, 'native']], 'raw WebSocket target receives the three channels');
};

subtest 'ordinary and raw SSE targets receive their declared contracts' => sub {
    my (@normal, @raw);
    my $router = PAGI::App::Router->new;
    $router->sse('/events/{stream}' => sub {
        my ($c) = @_;
        push @normal, [ref($c), scalar @_, $c->path_param('stream')];
        $c->start->get;
        $c->send_event(event => 'normal', data => $c->path_param('stream'))->get;
        return $c->close;
    });
    $router->sse('/raw-events/{stream}', raw => sub {
        my ($scope, $receive, $send) = @_;
        push @raw, [scalar @_, $scope->{path_params}{stream}];
        $send->({ type => 'sse.start', status => 200, headers => [] })->get;
        $send->({
            type => 'sse.send',
            event => 'raw',
            data => $scope->{path_params}{stream},
        })->get;
        $send->({ type => 'sse.close' })->get;
        return Future->done;
    });

    my $client = PAGI::Test::Client->new(app => $router->to_app);
    $client->sse('/events/news', sub {
        my ($sse) = @_;
        my $event = $sse->receive_event;
        is([$event->{event}, $event->{data}], ['normal', 'news'],
            'normal SSE Context emitted an event');
    });
    $client->sse('/raw-events/native', sub {
        my ($sse) = @_;
        my $event = $sse->receive_event;
        is([$event->{event}, $event->{data}], ['raw', 'native'],
            'raw SSE app emitted an event');
    });

    is(\@normal, [['PAGI::Context::SSE', 1, 'news']],
        'ordinary SSE handler receives only its Context subclass');
    is(\@raw, [[3, 'native']], 'raw SSE target receives the three channels');
};

subtest 'slash names, relative Context links, constraints, and metadata share one resolver' => sub {
    my @seen;
    my $router = PAGI::App::Router->new;
    $router->group('/orgs/{org}' => sub {
        my ($org) = @_;
        $org->group('/people' => sub {
            my ($people) = @_;
            $people->get('/{id}' => sub {
                my ($c) = @_;
                my $container = $c->scope->{'pagi.routing'};
                my $frame = $container->{frames}[-1];
                push @seen, {
                    has_routing => ref($container) eq 'HASH',
                    version => $container->{version},
                    has_old_router => exists $c->scope->{'pagi.router'} ? 1 : 0,
                    logical_namespace => $frame->{logical_namespace},
                    captures => { %{$frame->{captures}} },
                    match => { %{$frame->{match}} },
                    link => $c->path_for(
                        'show', {}, { 'a key' => 'x y' }, 'part one',
                    ),
                };
                return $c->text($seen[-1]{link});
            })->name('show')->desc('Show person')->constraints(id => qr/\A\d+\z/);
            $people->get('/{id}' => sub {
                return $_[0]->text('constraint fallback');
            });
        })->name('people');
    })->name('org');

    is(
        [sort keys %{$router->named_routes}],
        ['/org/people/show'],
        'nested local names become one canonical slash address',
    );
    is(
        $router->path_for(
            '/org/people/show',
            { org => 'acme', id => 7 },
            { 'a key' => 'x y' },
            'part one',
        ),
        '/orgs/acme/people/7?a%20key=x%20y#part%20one',
        'public reverse routing validates captures and renders query and fragment',
    );
    like(
        dies {
            $router->path_for('/org/people/show', { org => 'acme', id => 'seven' });
        },
        qr/path parameter 'id' failed constraint/,
        'public reverse routing applies the shared constraint',
    );

    my $client = PAGI::Test::Client->new(app => $router->to_app);
    my $matched = $client->get('/orgs/acme/people/7');
    my $rejected = $client->get('/orgs/acme/people/seven');

    is($matched->content,
        '/orgs/acme/people/7?a%20key=x%20y#part%20one',
        'Context relative reverse routing inherits the active captures');
    is($rejected->content, 'constraint fallback',
        'dispatch continues in declaration order after a failed constraint');
    is(\@seen, [{
        has_routing => 1,
        version => 1,
        has_old_router => 0,
        logical_namespace => '/org/people',
        captures => { org => 'acme', id => 7 },
        match => {
            kind => 'route',
            route => '/orgs/{org}/people/{id}',
            name => '/org/people/show',
            logical_namespace => '/org/people',
            desc => 'Show person',
        },
        link => '/orgs/acme/people/7?a%20key=x%20y#part%20one',
    }], 'dispatch publishes shared pagi.routing metadata and no pagi.router key');
};

subtest 'custom generated outcomes and explicit HEAD use the shared compiler' => sub {
    my @generated;
    my $router = PAGI::App::Router->new(
        not_found => sub {
            my ($c) = @_;
            push @generated, ['not_found', $c->response->status, $c->response->header('Allow')];
            return $c->text('custom missing');
        },
        method_not_allowed => sub {
            my ($c) = @_;
            push @generated, ['method_not_allowed', $c->response->status, $c->response->header('Allow')];
            return $c->text('custom method');
        },
    );
    $router->get('/only' => sub { return $_[0]->text('only') });
    $router->head('/report' => sub {
        return $_[0]->response->status(203)->text('explicit');
    });
    $router->get('/report' => sub {
        return $_[0]->response->status(200)->text('automatic');
    });

    my $client = PAGI::Test::Client->new(app => $router->to_app);
    my $missing = $client->get('/missing');
    my $wrong_method = $client->post('/only');
    my $head = $client->head('/report');
    my $get = $client->get('/report');

    is([$missing->status, $missing->content], [404, 'custom missing'],
        'custom not-found handler receives and returns the seeded response');
    is([$wrong_method->status, $wrong_method->header('Allow'), $wrong_method->content],
        [405, 'GET, HEAD', 'custom method'],
        'custom method handler keeps the shared first-seen Allow outcome');
    is(\@generated, [
        ['not_found', 404, undef],
        ['method_not_allowed', 405, 'GET, HEAD'],
    ], 'custom generated handlers receive ordinary HTTP Contexts');
    is([$head->status, $head->content_length, $head->content], [203, 8, ''],
        'an explicit HEAD declared before GET wins and is body-suppressed');
    is([$get->status, $get->content], [200, 'automatic'],
        'GET skips the earlier HEAD partial and reaches its own route');
};

done_testing;
