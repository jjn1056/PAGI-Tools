#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../examples/10-chat-showcase/lib";
use PAGI::Test::Client;

sub source_text {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot open $path: $!";
    local $/;
    my $source = <$fh>;
    close $fh or die "cannot close $path: $!";
    return $source;
}

my $app_file = "$Bin/../examples/10-chat-showcase/app.pl";
my $http_file = "$Bin/../examples/10-chat-showcase/lib/ChatApp/HTTP.pm";
my $app_source = source_text($app_file);
my $http_source = source_text($http_file);

for my $case (
    ['chat root', $app_source],
    ['chat HTTP child', $http_source],
) {
    my ($label, $source) = @$case;
    unlike($source, qr/PAGI::App::Router/,
        "$label does not use the mutable App Router frontend");
    unlike($source, qr/\$router->to_router/,
        "$label does not materialize an unused snapshot");
}

like($app_source,
    qr/websocket\('\/ws\/chat'\s*=>\s*as_app_object\(\$ws_handler\)\)/,
    'chat root declares the WebSocket native triplet endpoint directly');
like($app_source,
    qr/sse\('\/events'\s*=>\s*as_app_object\(\$sse_handler\)\)/,
    'chat root declares the SSE native triplet endpoint directly');
like($app_source,
    qr/route\('\/\*path'\s*=>\s*as_app_object\(\$http_handler\),\s*methods\s*=>\s*'\*'\)/,
    'chat root declares the HTTP fallback native triplet endpoint directly');
unlike($app_source,
    qr/mount\('\/'\s*=>\s*app\s*=>/,
    'chat root has no opaque router mount');

like($http_source,
    qr/compose\(routes\s*=>\s*\[\s*route\('\/api\/rooms'/s,
    'chat HTTP declares API routes directly in Compose');
unlike($http_source,
    qr/mount\('\/'\s*=>\s*app\s*=>/,
    'chat HTTP has no opaque router mount');

like($http_source,
    qr/PAGI::App::File->from_app_path\('public'\)->to_app/,
    'chat HTTP uses the application-relative file app');
unlike($http_source,
    qr/_serve_static|_send_(?:404|500)|%MIME_TYPES|File::Basename|File::Spec|\$path\s*=~\s*s|\bopen\b/,
    'chat HTTP contains no manual static server');

my $app = do $app_file;
my $load_error = $@ || $!;
ok(!$load_error, 'chat app loads cleanly') or diag($load_error);
isa_ok($app, 'PAGI::Compose');

SKIP: {
    skip 'chat app did not load', 26
        unless ref($app) eq 'PAGI::Compose';

    my $native_app = $app->to_app;
    my $stderr = '';
    my $stats;
    my $missing;
    my $index;
    my $css;
    my $missing_asset;
    my %starts_by_path;
    my $observed_app = sub {
        my ($scope, $receive, $send) = @_;
        my $path = $scope->{path} // '';
        my $observed_send = sub {
            my ($event) = @_;
            $starts_by_path{$path}++
                if ($event->{type} // '') eq 'http.response.start';
            return $send->($event);
        };
        return $native_app->($scope, $receive, $observed_send);
    };
    {
        local *STDERR;
        open STDERR, '>', \$stderr or die "cannot capture STDERR: $!";
        PAGI::Test::Client->run($observed_app, sub {
            my ($client) = @_;
            $stats = $client->get('/api/stats');
            $missing = $client->get('/api/not-a-route');
            $index = $client->get('/');
            $css = $client->get('/css/style.css');
            $missing_asset = $client->get('/not-a-static-file',
                headers => { Accept => 'application/problem+json' });

            $client->websocket('/ws/chat?name=RootMount', sub {
                my ($ws) = @_;
                my $connected = $ws->receive_json;
                is($connected->{type}, 'connected',
                    'direct root route accepts WebSocket chat');
                is($connected->{name}, 'RootMount',
                    'WebSocket chat receives its query string through the direct route');
                my $joined = $ws->receive_json;
                is($joined->{type}, 'joined',
                    'WebSocket chat retains its initial room notification');
                $ws->send_json({ type => 'ping', ts => 17 });
                is($ws->receive_json, { type => 'pong', ts => 17 },
                    'direct root route preserves WebSocket message dispatch');
            });

            my $websocket_miss = $client->websocket('/ws/missing');
            ok($websocket_miss->is_closed,
                'a WebSocket miss completes its extension denial');
            ok(!defined $websocket_miss->close_code,
                'the extension denial does not emit an RFC6455 close code');

            $client->sse('/events', sub {
                my ($sse) = @_;
                my $event = $sse->receive_event;
                is($event->{event}, 'room_created',
                    'direct root route starts the showcase SSE replay');
            });

            my $sse_miss = $client->sse('/events/missing');
            isa_ok($sse_miss, 'PAGI::Test::Response');
            is($sse_miss->status, 404,
                'an SSE miss declines as the root Router response');
        });

    }

    is($stats->status, 200, 'existing HTTP API remains reachable');
    ok(exists $stats->json->{rooms_count}, 'existing statistics payload remains intact');
    like($stderr, qr/\[lifespan\] Application starting up/,
        'configured startup callback runs');
    like($stderr, qr/\[lifespan\] Application shutting down/,
        'configured shutdown callback runs');
    like($stderr, qr/^\[http\] GET \/api\/stats 200 /m,
        'application logging surrounds HTTP dispatch');
    like($stderr, qr/^\[lifespan\] - - - /m,
        'application logging surrounds the complete lifespan loop');
    is($missing->status, 404,
        'an unknown API path is completed by the inner HTTP application');
    like($missing->text, qr/<h1>Not Found<\/h1>/,
        'the internal API Compose uses its negotiated routing default');
    is($starts_by_path{'/api/not-a-route'}, 1,
        'the HTTP fallback and root Compose emit no second response');
    is($index->status, 200, 'chat frontend remains reachable');
    like($index->text, qr/<title>PAGI Chat - Multi-User Chat Demo<\/title>/,
        'root serves the chat frontend from the public directory');
    is($css->status, 200, 'chat stylesheet remains reachable');
    like($css->text, qr/--accent-color:\s*#4a90d9/,
        'stylesheet content comes from the public directory');
    is($css->content_type, 'text/css',
        'stylesheet uses the file app MIME type');
    is($missing_asset->status, 404,
        'an unknown non-API asset receives a terminal 404');
    is($missing_asset->content_type, 'application/problem+json',
        'the static 404 honors problem JSON negotiation');
    is($missing_asset->json->{status}, 404,
        'the negotiated problem identifies the missing asset status');
}

done_testing;
