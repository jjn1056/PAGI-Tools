use strict;
use warnings;
use Test2::V0;
use File::Spec;
use FindBin qw($Bin);
use Scalar::Util qw(blessed refaddr);
use lib "$Bin/../examples/endpoint-class-demo/lib";
use lib "$Bin/../lib";

use PAGI::Test::Client;

use MyApp::Main;
use MyApp::API;
use MyApp::API::Events;

my %load_error;
for my $class (qw(MyApp::API::User MyApp::StatusSocket)) {
    (my $file = "$class.pm") =~ s{::}{/}g;
    eval { require $file; 1 } or $load_error{$class} = $@;
}

my @users = (
    { id => 1, name => 'Alice' },
    { id => 2, name => 'Bob' },
);

subtest 'ordinary assemblers expose immutable configured endpoint leaves' => sub {
    for my $class (qw(
        MyApp::Main MyApp::API MyApp::API::User
        MyApp::StatusSocket MyApp::API::Events
    )) {
        ok(!$load_error{$class}, "$class loads")
            or diag($load_error{$class});
        next if $load_error{$class};

        ok($class->can('new'), "$class constructs an object");
        ok(!$class->can('to_router'), "$class has no Endpoint Router conversion");
        ok(!$class->can('middleware_as'), "$class has no reflective middleware binding");
        ok(!$class->can('app_as'), "$class has no reflective application binding");
        ok(!$class->can('state'), "$class has no Endpoint Router state surface");

        my $inherits_endpoint_router;
        {
            no strict 'refs';
            $inherits_endpoint_router = grep {
                $_ eq 'PAGI::Endpoint::Router'
            } @{"${class}::ISA"};
        }
        ok(!$inherits_endpoint_router,
            "$class does not inherit Endpoint Router");
    }

    my $events = MyApp::API::Events->new;
    my $api = MyApp::API->new(events => $events, users => \@users);
    my $main = MyApp::Main->new(api => $api);

    ok($main->can('routes'), 'Main exposes ordinary route declarations');
    ok($api->can('routing'), 'API exposes a reusable immutable Router');
    ok($main->can('public_root'), 'asset owner exposes its direct app_path result');

    if ($main->can('public_root')) {
        local $ENV{PAGI_HOME};
        delete $ENV{PAGI_HOME};
        is($main->public_root,
            File::Spec->canonpath(File::Spec->rel2abs(
                "$Bin/../examples/endpoint-class-demo/public")),
            'direct app_path call resolves public from the owning module lib root');
    }

    my ($main_routes, $api_routing);
    my $main_error = dies { $main_routes = $main->routes };
    my $api_error = dies { $api_routing = $api->routing };
    ok(!$main_error, 'Main builds its immutable route list') or diag($main_error);
    ok(!$api_error, 'API builds its immutable routing subtree') or diag($api_error);

    return if $main_error || $api_error
        || $load_error{'MyApp::API::User'}
        || $load_error{'MyApp::StatusSocket'};

    is(scalar @$main_routes, 4, 'Main retains home, API, status, and static declarations');
    isa_ok($api_routing, 'PAGI::Routing::Router');
    is([sort keys %{$api_routing->named_routes}], [qw(
        /events/stream /index /show /tools/status
    )], 'API subtree retains its complete local logical namespace');

    my ($home, $api_mount, $status_socket, $static) = @$main_routes;
    isa_ok($home, 'PAGI::Routing::Route');
    is(ref($home->endpoint), 'CODE', 'home uses an explicit binding closure');
    isa_ok($api_mount->app, 'PAGI::Routing::Router');
    is([sort keys %{$api_mount->app->named_routes}], [qw(
        /events/stream /index /show /tools/status
    )], 'Main mounts the API object configured as one immutable Router');
    isa_ok($status_socket->endpoint, 'MyApp::StatusSocket');
    isa_ok($static->app, 'PAGI::App::File');

    my ($index, $show, $tools, $event_mount) = @{$api_routing->routes};
    is(ref($index->endpoint), 'CODE', 'API index uses an explicit binding closure');
    isa_ok($show->endpoint, 'MyApp::API::User');
    is($show->methods, [qw(GET HEAD OPTIONS)],
        'HTTP endpoint capability supplies exact leaf methods');
    is(refaddr($show->endpoint->{users}), refaddr(\@users),
        'configured HTTP endpoint retains the application user collection');
    is(scalar @{$index->middleware}, 1, 'API index retains token middleware');
    is(scalar @{$show->middleware}, 1, 'API user retains token middleware');
    is(ref($tools->app->routes->[0]->endpoint), 'CODE',
        'tool status uses an explicit binding closure');

    my $stream = $event_mount->app->routes->[0];
    isa_ok($stream->endpoint, 'MyApp::API::Events');
    is(refaddr($stream->endpoint), refaddr($events),
        'configured SSE endpoint is retained as the exact leaf object');

    for my $leaf ($home, $status_socket, $index, $show,
        $tools->app->routes->[0], $stream) {
        ok(ref($leaf->endpoint), $leaf->path . ' has no package-name string target');
    }
};

subtest 'the nested class demo preserves HTTP, WebSocket, SSE, and lifespan behavior' => sub {
    local $ENV{PAGI_HOME};
    delete $ENV{PAGI_HOME};

    my $app_file = "$Bin/../examples/endpoint-class-demo/app.pl";
    my $app = do $app_file;
    my $load_error = $@ || $!;
    ok(!$load_error, 'the real endpoint-class demo app file loads cleanly')
        or diag($load_error);
    return if $load_error;

    isa_ok($app, 'PAGI::Compose');
    ok(blessed($app) && $app->can('to_app'),
        'the real app file returns a to_app-capable object');
    is([sort keys %{$app->named_routes}], [qw(
        /api/events/stream /api/index /api/show /api/tools/status
        /home /status_socket
    )], 'nested local names form canonical absolute addresses');

    my ($resource, $metrics);
    PAGI::Test::Client->run($app, sub {
        my ($client) = @_;
        $resource = $client->state->{resource};
        $metrics = $client->state->{metrics};

        my $home = $client->get('/');
        is($home->status, 200, 'home responds through Main');
        like($home->text, qr{href="(/api/index)"}, 'home generates the API link');

        my $static = $client->get('/index.html');
        is($static->status, 200, 'mounted public file responds');
        like($static->text, qr/Static file served!/, 'public file comes from the example root');

        my ($api_index_path) = $home->text =~ qr{href="(/api/index)"};
        my $denied = $client->get($api_index_path,
            headers => { Accept => 'text/plain' });
        is($denied->status, 401, 'API middleware rejects a missing demo token');
        is($denied->header('WWW-Authenticate'),
            'DemoToken realm="endpoint-class-demo"',
            'API middleware publishes its authentication challenge');
        is($denied->content_type, 'text/plain; charset=utf-8',
            'API middleware denial negotiates the Pages text response');
        like($denied->text, qr/demo token required/,
            'API middleware includes the documented denial detail');

        my $index = $client->get($api_index_path,
            headers => { 'X-Demo-Token' => 'demo-token' });
        is($index->status, 200, 'API index accepts the demo token');
        like($index->text, qr{href="(/api/show/1)"}, 'API generates a local item link');

        my ($show_path) = $index->text =~ qr{href="(/api/show/1)"};
        my $show = $client->get($show_path,
            headers => { 'X-Demo-Token' => 'demo-token' });
        is($show->status, 200, 'generated API item link resolves');
        like($show->text, qr/Alice/, 'item endpoint sees its typed path capture');

        my $tools_path = $app->path_for('/api/tools/status');
        is($tools_path, '/api/tools/status',
            'callback child publishes its composed reverse address');
        my $tools = $client->get($tools_path);
        is($tools->status, 200, 'API status closure handles its exact leaf');
        is($tools->json, { status => 'ready', resource => 'demo-resource' },
            'status handler reads shared lifespan state');

        my $missing_user = $client->get('/api/show/999', headers => {
            'X-Demo-Token' => 'demo-token',
            Accept         => 'application/problem+json',
        });
        is($missing_user->status, 404,
            'missing API user returns a resource-level 404');
        is($missing_user->content_type, 'application/problem+json',
            'missing API user negotiates a problem document');
        is($missing_user->json, {
            type   => 'about:blank',
            title  => 'Not Found',
            status => 404,
            detail => 'User not found',
        }, 'missing API user uses the shared Pages representation');

        my $api_missing = $client->get('/api/not-a-route', headers => {
            Accept => 'application/problem+json',
        });
        is($api_missing->status, 404, 'API Router owns its unmatched path');
        is($api_missing->json, {
            type   => 'about:blank',
            title  => 'Not Found',
            status => 404,
            detail => 'No API endpoint route matched',
        }, 'immutable API Router renders its custom boundary policy');

        my $api_wrong_method = $client->post('/api/index', headers => {
            'X-Demo-Token' => 'demo-token',
        });
        is($api_wrong_method->status, 405,
            'the mounted API Router retains its automatic method mismatch');
        is($api_wrong_method->header('Allow'), 'GET, HEAD',
            'the mounted API Router retains its own Allow union');

        $client->websocket('/status', sub {
            my ($ws) = @_;
            is($ws->receive_json, { type => 'ready', resource => 'demo-resource' },
                'root WebSocket endpoint reads lifespan state');
            $ws->send_json({ ping => 'demo' });
            is($ws->receive_json, { type => 'echo', data => { ping => 'demo' } },
                'root WebSocket endpoint handles one message');
        });

        $client->sse('/api/events/stream', sub {
            my ($sse) = @_;
            my $event = $sse->receive_event;
            is($event->{event}, 'ready', 'nested Events endpoint starts SSE');
            is($event->{data}, '{"resource":"demo-resource"}',
                'nested SSE endpoint reads lifespan state');
        });

        my $missing = $client->get('/api/events/missing');
        is($missing->status, 404, 'unmatched nested path retains shared 404 behavior');
    });

    is($resource, { name => 'demo-resource', open => 0, closed => 1 },
        'shutdown closes the resource owned by lifespan state');
    is($metrics, { requests => 4, websocket_messages => 1 },
        'HTTP and WebSocket handlers retain shared lifespan metrics');
};

done_testing;
