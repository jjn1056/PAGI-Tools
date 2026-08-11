use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../examples/endpoint-router-demo/lib";
use lib "$Bin/../lib";

use PAGI::Compose qw(compose);
use PAGI::Test::Client;

use MyApp::Main;
use MyApp::API;
use MyApp::API::Events;

subtest 'the example exposes explicit Endpoint objects without Endpoint state' => sub {
    for my $class (qw(MyApp::Main MyApp::API MyApp::API::Events)) {
        ok($class->can('new'), "$class constructs an object");
        ok($class->can('routes'), "$class declares routes");
        ok($class->can('to_router'), "$class materializes a Router");
        ok(!$class->can('state'), "$class has no Endpoint state surface");
    }
};

subtest 'the nested demo exercises the complete Endpoint design' => sub {
    my $events = MyApp::API::Events->new;
    my $api    = MyApp::API->new(events => $events);
    my $main   = MyApp::Main->new(api => $api);
    my $router = $main->to_router;

    isa_ok($router, 'PAGI::Routing::Router');
    is([sort keys %{$router->named_routes}], [qw(
        /api/events/stream /api/index /api/show /home /status_socket
    )], 'nested local names form canonical absolute addresses');

    my $resource;
    my $app = compose(
        app => $router,
        lifespan => {
            startup => sub {
                my ($state) = @_;
                $resource = $state->{resource} = { name => 'demo-resource', open => 1 };
                $state->{metrics} = { requests => 0, websocket_messages => 0 };
            },
            shutdown => sub {
                my ($state) = @_;
                $state->{resource}{open} = 0;
                $state->{resource}{closed} = 1;
            },
        },
    )->to_app;

    PAGI::Test::Client->run($app, sub {
        my ($client) = @_;

        my $home = $client->get('/');
        is($home->status, 200, 'home responds through Main');
        like($home->text, qr{href="(/api/index)"}, 'home generates the API link');

        my ($api_index_path) = $home->text =~ qr{href="(/api/index)"};
        my $denied = $client->get($api_index_path);
        is($denied->status, 401, 'API middleware rejects a missing demo token');
        is($denied->text, 'demo token required',
            'API middleware returns the documented denial body');
        is($denied->content_type, 'text/plain; charset=utf-8',
            'API middleware denial uses the Context text response');

        my $index = $client->get($api_index_path,
            headers => { 'X-Demo-Token' => 'demo-token' });
        is($index->status, 200, 'API index accepts the demo token');
        like($index->text, qr{href="(/api/show/1)"}, 'API generates a local item link');

        my ($show_path) = $index->text =~ qr{href="(/api/show/1)"};
        my $show = $client->get($show_path,
            headers => { 'X-Demo-Token' => 'demo-token' });
        is($show->status, 200, 'generated API item link resolves');
        like($show->text, qr/Alice/, 'item handler sees its typed path capture');

        $client->websocket('/status', sub {
            my ($ws) = @_;
            is($ws->receive_json, { type => 'ready', resource => 'demo-resource' },
                'root WebSocket reads lifespan state');
            $ws->send_json({ ping => 'demo' });
            is($ws->receive_json, { type => 'echo', data => { ping => 'demo' } },
                'root WebSocket handles one message');
        });

        $client->sse('/api/events/stream', sub {
            my ($sse) = @_;
            my $event = $sse->receive_event;
            is($event->{event}, 'ready', 'nested Events object starts SSE');
            is($event->{data}, '{"resource":"demo-resource"}',
                'nested SSE reads lifespan state');
        });

        my $missing = $client->get('/api/events/missing',
            headers => { 'X-Demo-Token' => 'demo-token' });
        is($missing->status, 404, 'unmatched nested path retains shared 404 behavior');
    });

    is($resource, { name => 'demo-resource', open => 0, closed => 1 },
        'shutdown closes the resource owned by lifespan state');
};

done_testing;
