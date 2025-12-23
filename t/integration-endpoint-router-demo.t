use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../examples/endpoint-router-demo/lib";
use lib "$Bin/../lib";

use PAGI::Test::Client;

# Load example app modules
subtest 'example app modules load' => sub {
    my $main_loaded = eval { require MyApp::Main; 1 };
    ok($main_loaded, 'MyApp::Main loads') or diag $@;

    my $api_loaded = eval { require MyApp::API; 1 };
    ok($api_loaded, 'MyApp::API loads') or diag $@;
};

subtest 'MyApp::Main class structure' => sub {
    ok(MyApp::Main->can('new'), 'has new');
    ok(MyApp::Main->can('to_app'), 'has to_app');
    ok(MyApp::Main->can('routes'), 'has routes');
    ok(MyApp::Main->can('on_startup'), 'has on_startup');
    ok(MyApp::Main->can('on_shutdown'), 'has on_shutdown');
    ok(MyApp::Main->can('home'), 'has home handler');
    ok(MyApp::Main->can('ws_echo'), 'has ws_echo handler');
    ok(MyApp::Main->can('sse_metrics'), 'has sse_metrics handler');
};

subtest 'MyApp::API subrouter class structure' => sub {
    ok(MyApp::API->can('routes'), 'has routes');
    ok(MyApp::API->can('get_info'), 'has get_info handler');
    ok(MyApp::API->can('list_users'), 'has list_users handler');
    ok(MyApp::API->can('get_user'), 'has get_user handler');
    ok(MyApp::API->can('create_user'), 'has create_user handler');
};

# Use PAGI::Test::Client with lifespan support for proper testing
subtest 'app routes work with lifespan' => sub {
    my $app = MyApp::Main->to_app;

    PAGI::Test::Client->run($app, sub {
        my ($client) = @_;

        # Test home page - state should be initialized via on_startup
        subtest 'home page' => sub {
            my $res = $client->get('/');
            is($res->status, 200, '/ returns 200');
            like($res->text, qr/Endpoint Router Demo/, 'body contains app name from state');
        };

        # Test API info route via mount
        subtest 'API info' => sub {
            my $res = $client->get('/api/info');
            is($res->status, 200, '/api/info returns 200');
            like($res->text, qr/version/, 'body contains version');
        };

        # Test API route listing users
        subtest 'API users list' => sub {
            my $res = $client->get('/api/users');
            is($res->status, 200, '/api/users returns 200');
            like($res->text, qr/Alice|Bob/, 'body contains user names');
        };

        # Test API route with param
        subtest 'API user by id' => sub {
            my $res = $client->get('/api/users/1');
            is($res->status, 200, '/api/users/1 returns 200');
            like($res->text, qr/Alice/, 'body contains Alice');
        };

        # Test WebSocket route
        subtest 'WebSocket echo' => sub {
            $client->websocket('/ws/echo', sub {
                my ($ws) = @_;
                my $msg = $ws->receive_json;
                is($msg->{type}, 'connected', 'received connected message');
            });
        };

        # Test SSE route
        subtest 'SSE metrics' => sub {
            $client->sse('/events/metrics', sub {
                my ($sse) = @_;
                my $event = $sse->receive_event;
                is($event->{event}, 'connected', 'received connected event');
            });
        };
    });
};

done_testing;
