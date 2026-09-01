use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use Scalar::Util qw(blessed);
use lib "$Bin/../examples/endpoint-router-demo/lib";
use lib "$Bin/../lib";

use PAGI::Test::Client;

use MyApp::Main;
use MyApp::API;
use MyApp::API::Events;

sub source_text {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot open $path: $!\n";
    local $/;
    my $source = <$fh>;
    close $fh or die "cannot close $path: $!\n";
    return $source;
}

subtest 'Main mounts its application-relative public component' => sub {
    my $path = "$Bin/../examples/endpoint-router-demo/lib/MyApp/Main.pm";
    my $source = source_text($path);
    like($source,
        qr{mount\('/'\s*,\s*app\s*=>\s*PAGI::App::File->from_app_path\('public'\)\)},
        'module-layout Router mounts the returned component');
    unlike($source, qr/PAGI::App::File->app_path\('public'\)->to_app/,
        'module passes the component to the Router without compiling it');
    unlike($source, qr/PAGI::App::File->new\s*\(|File::Basename|File::Spec/,
        'module contains no manual static-root arithmetic');
};

subtest 'the example exposes explicit Endpoint objects without Endpoint state' => sub {
    for my $class (qw(MyApp::Main MyApp::API MyApp::API::Events)) {
        ok($class->can('new'), "$class constructs an object");
        ok($class->can('routes'), "$class declares routes");
        ok($class->can('to_router'), "$class materializes a Router");
        ok(!$class->can('state'), "$class has no Endpoint state surface");
    }
};

subtest 'Endpoint methods receive direct protocol objects' => sub {
    my $main = source_text(
        "$Bin/../examples/endpoint-router-demo/lib/MyApp/Main.pm",
    );
    my $api = source_text(
        "$Bin/../examples/endpoint-router-demo/lib/MyApp/API.pm",
    );
    my $events = source_text(
        "$Bin/../examples/endpoint-router-demo/lib/MyApp/API/Events.pm",
    );

    like($main, qr/sub home\s*\{.*?my \(\$self, \$request\) = \@_/s,
        'HTTP Endpoint method receives Request');
    like($main, qr/sub status_socket\s*\{.*?my \(\$self, \$websocket\) = \@_/s,
        'WebSocket Endpoint method receives WebSocket');
    like($events, qr/sub stream\s*\{.*?my \(\$self, \$sse\) = \@_/s,
        'SSE Endpoint method receives SSE');
    like($api, qr/\$self->new_request\(\$scope, \$receive\)/,
        'native middleware explicitly constructs Request');
    unlike($api . $main . $events, qr/new_context|\$c\b/,
        'demo no longer relies on Context');
};

subtest 'the nested demo exercises the complete Endpoint design' => sub {
    local $ENV{PAGI_HOME};
    delete $ENV{PAGI_HOME};

    my $events = MyApp::API::Events->new;
    my $api    = MyApp::API->new(events => $events);
    my $main   = MyApp::Main->new(api => $api);
    my $router = $main->to_router;

    isa_ok($router, 'PAGI::Routing::Router');
    is([sort keys %{$router->named_routes}], [qw(
        /api/events/stream /api/index /api/show /api/tools/status
        /home /status_socket
    )], 'nested local names form canonical absolute addresses');

    my $app_file = "$Bin/../examples/endpoint-router-demo/app.pl";
    my $app_source = source_text($app_file);
    unlike($app_source, qr/compose\s*\(\s*app\s*=>/s,
        'Endpoint Router demo does not use retired Compose app mode');
    like($app_source, qr/compose\s*\(\s*router\s*=>\s*\$main->to_router/s,
        'Endpoint Router demo crosses its mutable frontend with to_router');
    my $app = do $app_file;
    my $load_error = $@ || $!;
    ok(!$load_error, 'the real Endpoint demo app file loads cleanly')
        or diag($load_error);
    isa_ok($app, 'PAGI::Compose');
    ok(blessed($app) && $app->can('to_app'),
        'the real app file returns a to_app-capable object');

    my $resource;
    PAGI::Test::Client->run($app, sub {
        my ($client) = @_;
        $resource = $client->state->{resource};

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
            'DemoToken realm="endpoint-router-demo"',
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
        like($show->text, qr/Alice/, 'item handler sees its typed path capture');

        my $tools_path = $router->path_for('/api/tools/status');
        is($tools_path, '/api/tools/status',
            'callback child publishes its composed reverse address');
        my $tools = $client->get($tools_path);
        is($tools->status, 200,
            'Endpoint routes callback binds methods to the API object');
        is($tools->json, { status => 'ready', resource => 'demo-resource' },
            'callback-bound handler reads shared lifespan state');

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
        is($api_missing->status, 404,
            'API Router owns its unmatched path');
        is($api_missing->json, {
            type   => 'about:blank',
            title  => 'Not Found',
            status => 404,
            detail => 'No API Endpoint route matched',
        }, 'app_as custom default renders the API boundary policy');

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
