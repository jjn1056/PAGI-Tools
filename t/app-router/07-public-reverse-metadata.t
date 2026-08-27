#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::App::Router;
use PAGI::Response ();
use PAGI::Routing::URL qw(path_for);
use PAGI::Test::Client;

{
    package Local::RawAppObject;

    sub new {
        my ($class, $app) = @_;
        return bless { app => $app, builds => 0 }, $class;
    }
    sub to_app {
        my ($self) = @_;
        ++$self->{builds};
        return $self->{app};
    }
}

{
    package Local::BrokenRawAppObject;
    sub new { return bless {}, $_[0] }
    sub to_app { return bless {}, 'Local::NotACoderef' }
}

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

subtest 'ordinary HTTP targets receive Request and emit immediate or Future Responses' => sub {
    my @normal_kinds;
    my $router = PAGI::App::Router->new;
    $router->get('/immediate/{id}' => sub {
        my ($request) = @_;
        push @normal_kinds, [ref($request), scalar @_];
        return PAGI::Response->text(
            'immediate ' . $request->path_param('id'), status => 201,
        );
    });
    $router->get('/future' => sub {
        my ($request) = @_;
        push @normal_kinds, [ref($request), scalar @_];
        return Future->done(PAGI::Response->text('future', status => 202));
    });

    my $client = PAGI::Test::Client->new(app => $router->to_app);
    my $immediate = $client->get('/immediate/42');
    my $future = $client->get('/future');

    is([$immediate->status, $immediate->content], [201, 'immediate 42'],
        'an immediate Response is emitted through the shared adapter');
    is([$future->status, $future->content], [202, 'future'],
        'a Future-backed Response is emitted through the same adapter');
    is(\@normal_kinds, [
        ['PAGI::Request', 1],
        ['PAGI::Request', 1],
    ], 'ordinary HTTP handlers receive only a Request');
};

subtest 'explicit raw HTTP targets retain all three native channels' => sub {
    my @raw_argument_counts;
    my $raw_object = Local::RawAppObject->new(
        raw_http_app(\@raw_argument_counts),
    );
    my $router = PAGI::App::Router->new;
    $router->get('/raw/{id}', raw => $raw_object);

    is($raw_object->{builds}, 0, 'raw object is not compiled at declaration');
    my $app = $router->to_app;
    is($raw_object->{builds}, 1, 'raw HTTP object compiles once per to_app');
    my $client = PAGI::Test::Client->new(app => $app);
    my $raw = $client->get('/raw/7');

    is([$raw->status, $raw->content], [209, 'raw 7'],
        'an explicit raw HTTP route owns native response events');
    is(\@raw_argument_counts, [3], 'a raw HTTP route receives all three PAGI channels');
    is($raw_object->{builds}, 1, 'requests never recompile the raw object');
    like(dies {
        PAGI::App::Router->new
            ->get('/broken', raw => Local::BrokenRawAppObject->new)
            ->to_app;
    }, qr/to_app must return a coderef/,
        'a broken raw application object fails at compilation');
};

subtest 'ordinary and raw WebSocket targets receive their declared contracts' => sub {
    my (@normal, @raw);
    my $router = PAGI::App::Router->new;
    $router->websocket('/ws/{room}' => sub {
        my ($websocket) = @_;
        push @normal, [ref($websocket), scalar @_, $websocket->path_param('room')];
        $websocket->accept->get;
        $websocket->send_text('normal ' . $websocket->path_param('room'))->get;
        return $websocket->close(1000, 'done');
    });
    my $raw_object = Local::RawAppObject->new(sub {
        my ($scope, $receive, $send) = @_;
        push @raw, [scalar @_, $scope->{path_params}{room}];
        $receive->()->get;
        $send->({ type => 'websocket.accept' })->get;
        $send->({ type => 'websocket.send', text => 'raw ' . $scope->{path_params}{room} })->get;
        $send->({ type => 'websocket.close', code => 1000, reason => 'done' })->get;
        return Future->done;
    });
    $router->websocket('/raw-ws/{room}', raw => $raw_object);

    my $app = $router->to_app;
    is($raw_object->{builds}, 1, 'raw WebSocket object compiles once');
    my $client = PAGI::Test::Client->new(app => $app);
    $client->websocket('/ws/lobby', sub {
        my ($ws) = @_;
        is($ws->receive_text, 'normal lobby', 'normal WebSocket object emitted text');
    });
    $client->websocket('/raw-ws/native', sub {
        my ($ws) = @_;
        is($ws->receive_text, 'raw native', 'raw WebSocket app emitted text');
    });

    is(\@normal, [['PAGI::WebSocket', 1, 'lobby']],
        'ordinary WebSocket handler receives only its protocol object');
    is(\@raw, [[3, 'native']], 'raw WebSocket target receives the three channels');
};

subtest 'ordinary and raw SSE targets receive their declared contracts' => sub {
    my (@normal, @raw);
    my $router = PAGI::App::Router->new;
    $router->sse('/events/{stream}' => sub {
        my ($sse) = @_;
        push @normal, [ref($sse), scalar @_, $sse->path_param('stream')];
        $sse->start->get;
        $sse->send_event(event => 'normal', data => $sse->path_param('stream'))->get;
        return $sse->close;
    });
    my $raw_object = Local::RawAppObject->new(sub {
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
    $router->sse('/raw-events/{stream}', raw => $raw_object);

    my $app = $router->to_app;
    is($raw_object->{builds}, 1, 'raw SSE object compiles once');
    my $client = PAGI::Test::Client->new(app => $app);
    $client->sse('/events/news', sub {
        my ($sse) = @_;
        my $event = $sse->receive_event;
        is([$event->{event}, $event->{data}], ['normal', 'news'],
            'normal SSE object emitted an event');
    });
    $client->sse('/raw-events/native', sub {
        my ($sse) = @_;
        my $event = $sse->receive_event;
        is([$event->{event}, $event->{data}], ['raw', 'native'],
            'raw SSE app emitted an event');
    });

    is(\@normal, [['PAGI::SSE', 1, 'news']],
        'ordinary SSE handler receives only its protocol object');
    is(\@raw, [[3, 'native']], 'raw SSE target receives the three channels');
};

subtest 'slash names, relative Request links, constraints, and metadata share one resolver' => sub {
    my @seen;
    my $router = PAGI::App::Router->new;
    $router->mount('/orgs/{org}', routes => sub {
        my ($org) = @_;
        $org->mount('/people', routes => sub {
            my ($people) = @_;
            $people->get('/{id}' => sub {
                my ($request) = @_;
                my $container = $request->scope->{'pagi.routing'};
                my $frame = $container->{frames}[-1];
                push @seen, {
                    has_routing => ref($container) eq 'HASH',
                    version => $container->{version},
                    has_old_router => exists $request->scope->{'pagi.router'} ? 1 : 0,
                    logical_namespace => $frame->{logical_namespace},
                    captures => { %{$frame->{captures}} },
                    match => { %{$frame->{match}} },
                    link => path_for($request,
                        'show', {}, { 'a key' => 'x y' }, 'part one',
                    ),
                };
                return PAGI::Response->text($seen[-1]{link});
            })->name('show')->desc('Show person')->constraints(id => qr/\A\d+\z/);
            $people->get('/{id}' => sub {
                return PAGI::Response->text('constraint fallback');
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
        'Request-relative reverse routing inherits the active captures');
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

subtest 'custom HTTP default and explicit HEAD use the shared compiler' => sub {
    my @default_scopes;
    my $default = Local::RawAppObject->new(sub {
        my ($scope, $receive, $send) = @_;
        push @default_scopes, [$scope->{type}, scalar @_];
        $send->({
            type => 'http.response.start', status => 404,
            headers => [['content-type', 'text/plain']],
        })->get;
        $send->({
            type => 'http.response.body', body => 'custom missing', more => 0,
        })->get;
        return Future->done;
    });
    my $router = PAGI::App::Router->new(http_default => $default);
    $router->get('/only' => sub { return PAGI::Response->text('only') });
    $router->head('/report' => sub {
        return PAGI::Response->text('explicit', status => 203);
    });
    $router->get('/report' => sub {
        return PAGI::Response->text('automatic', status => 200);
    });

    my $app = $router->to_app;
    is($default->{builds}, 1, 'HTTP default object compiles once');
    my $client = PAGI::Test::Client->new(app => $app);
    my $missing = $client->get('/missing');
    my $wrong_method = $client->post('/only');
    my $head = $client->head('/report');
    my $get = $client->get('/report');

    is([$missing->status, $missing->content], [404, 'custom missing'],
        'custom HTTP default owns NONE');
    is([$wrong_method->status, $wrong_method->header('Allow')],
        [405, 'GET, HEAD'],
        'PARTIAL remains the Router stock 405 rather than invoking the default');
    like($wrong_method->content, qr/Method Not Allowed/,
        'the PARTIAL body comes from the stock negotiated page');
    is(\@default_scopes, [['http', 3]],
        'the custom default receives exactly the three HTTP channels for NONE only');
    is([$head->status, $head->content_length, $head->content], [203, 8, ''],
        'an explicit HEAD declared before GET wins and is body-suppressed');
    is([$get->status, $get->content], [200, 'automatic'],
        'GET skips the earlier HEAD partial and reaches its own route');
    is($default->{builds}, 1, 'requests never recompile the HTTP default');
};

done_testing;
