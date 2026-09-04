#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::Endpoint::HTTP;
use PAGI::Endpoint::WebSocket;
use PAGI::Endpoint::SSE;
use PAGI::Response;
use PAGI::Response::Empty ();
use PAGI::Response::JSON ();
use PAGI::Routing qw(route router sse websocket);
use PAGI::Test::Client ();

# A realistic multi-protocol endpoint setup
package MyApp::UserAPI {
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;

    async sub get {
        my ($self, $request) = @_;
        ++$self->{calls}{get};
        return PAGI::Response::JSON->new({ users => ['alice', 'bob'] });
    }

    async sub post {
        my ($self, $request) = @_;
        ++$self->{calls}{post};
        return PAGI::Response::JSON->new({ created => 1 }, status => 201);
    }

    async sub delete {
        my ($self, $request) = @_;
        ++$self->{calls}{delete};
        return PAGI::Response::Empty->new(status => 204);
    }
}

package MyApp::ChatWS {
    use parent 'PAGI::Endpoint::WebSocket';
    use Future::AsyncAwait;

    sub encoding { 'json' }

    async sub on_connect {
        my ($self, $websocket) = @_;
        ++$self->{connections};
        await $websocket->accept;
        await $websocket->send_json({ type => 'welcome' });
    }

    async sub on_receive {
        my ($self, $websocket, $data) = @_;
        ++$self->{messages};
        await $websocket->send_json({ type => 'echo', data => $data });
    }
}

package MyApp::EventsSSE {
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;

    sub keepalive_interval { 30 }

    async sub on_connect {
        my ($self, $sse) = @_;
        ++$self->{connections};
        await $sse->send_event(
            event => 'connected',
            data  => { server_time => time() },
        );
    }
}

subtest 'HTTP endpoint handles CRUD' => sub {
    ok(MyApp::UserAPI->can('get'), 'has get');
    ok(MyApp::UserAPI->can('post'), 'has post');
    ok(MyApp::UserAPI->can('delete'), 'has delete');
    ok(!MyApp::UserAPI->can('patch'), 'no patch');

    my @allowed = MyApp::UserAPI->new->allowed_methods;
    ok((grep { $_ eq 'GET' } @allowed), 'GET in allowed');
    ok((grep { $_ eq 'POST' } @allowed), 'POST in allowed');
    ok((grep { $_ eq 'DELETE' } @allowed), 'DELETE in allowed');
};

subtest 'WebSocket endpoint has correct encoding' => sub {
    is(MyApp::ChatWS->encoding, 'json', 'JSON encoding');
};

subtest 'SSE endpoint has keepalive configured' => sub {
    is(MyApp::EventsSSE->keepalive_interval, 30, 'keepalive is 30s');
};

subtest 'all endpoints produce PAGI apps' => sub {
    my $http_app = MyApp::UserAPI->to_app;
    my $ws_app = MyApp::ChatWS->to_app;
    my $sse_app = MyApp::EventsSSE->to_app;

    ref_ok($http_app, 'CODE', 'HTTP app is coderef');
    ref_ok($ws_app, 'CODE', 'WS app is coderef');
    ref_ok($sse_app, 'CODE', 'SSE app is coderef');
};

subtest 'declarative Router dispatches configured endpoint objects for every protocol' => sub {
    my $http = MyApp::UserAPI->new;
    my $ws = MyApp::ChatWS->new;
    my $events = MyApp::EventsSSE->new;
    my $routing = router(routes => [
        route('/users' => $http, name => 'users'),
        websocket('/chat' => $ws, name => 'chat'),
        sse('/events' => $events, name => 'events'),
    ]);

    is([map { refaddr($_->endpoint) } @{$routing->routes}],
        [map { refaddr($_) } ($http, $ws, $events)],
        'declarations retain the exact configured endpoint objects');

    my $client = PAGI::Test::Client->new(app => $routing->to_app);
    is($client->get('/users')->json, { users => ['alice', 'bob'] },
        'HTTP endpoint dispatches through the declarative Route');
    is($client->post('/users')->status, 201,
        'HTTP verb dispatch remains owned by the endpoint object');
    is($client->delete('/users')->status, 204,
        'a third endpoint verb remains reachable through one exact leaf');
    is($http->{calls}, { get => 1, post => 1, delete => 1 },
        'HTTP dispatch uses the configured receiver');

    $client->websocket('/chat', sub {
        my ($socket) = @_;
        is($socket->receive_json, { type => 'welcome' },
            'configured WebSocket endpoint handles connect');
        $socket->send_json({ ping => 'configured' });
        is($socket->receive_json,
            { type => 'echo', data => { ping => 'configured' } },
            'configured WebSocket endpoint handles a message');
    });
    is([$ws->{connections}, $ws->{messages}], [1, 1],
        'WebSocket dispatch uses the configured receiver');

    $client->sse('/events', sub {
        my ($stream) = @_;
        my $event = $stream->receive_event;
        is($event->{event}, 'connected',
            'configured SSE endpoint handles connect');
    });
    is($events->{connections}, 1,
        'SSE dispatch uses the configured receiver');
};

done_testing;
