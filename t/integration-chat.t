#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../examples/chat/lib";
use PAGI::Test::Client;

# The chat example is the showcase for HTTP, WebSocket and SSE together, so it
# is written in the style the toolkit recommends: one-object handlers on
# declarative routes, Response values, and no event loop named in app code.

my $dir = "$Bin/../examples/chat";

sub source_text {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot open $path: $!";
    local $/;
    my $source = <$fh>;
    close $fh or die "cannot close $path: $!";
    return $source;
}

my %source = map { $_ => source_text("$dir/$_") }
    qw(app.pl lib/ChatApp/HTTP.pm lib/ChatApp/WebSocket.pm lib/ChatApp/SSE.pm lib/ChatApp/State.pm);

subtest 'the example is written in the recommended style' => sub {
    my $app = $source{'app.pl'};
    like($app, qr/websocket\('\/ws\/chat'\s*=>\s*\\&ChatApp::WebSocket::chat\)/,
        'the WebSocket route takes a one-$ws handler');
    like($app, qr/sse\('\/events'\s*=>\s*\\&ChatApp::SSE::events\)/,
        'the SSE route takes a one-$sse handler');
    like($app, qr/mount\('\/api',\s*app\s*=>\s*ChatApp::HTTP::routing\(\)\)/,
        'the HTTP API is a Router mounted at /api');
    like($app, qr/route\('\/\*path'\s*=>\s*PAGI::App::File->from_app_path\('public'\)\)/,
        'static files are an HTTP catch-all route to the file application');

    for my $file (sort keys %source) {
        unlike($source{$file}, qr/\bas_app_object\b/, "$file does not need as_app_object");
        unlike($source{$file}, qr/IO::Async/, "$file names no event loop");
        unlike($source{$file}, qr/type\s*=>\s*'(?:websocket|sse|http\.response)\./,
            "$file sends no hand-built protocol events");
        unlike($source{$file}, qr/PAGI::(?:WebSocket|SSE)->new|\(\$scope,\s*\$receive,\s*\$send\)/,
            "$file builds no protocol objects from raw channels")
            unless $file eq 'app.pl';    # app.pl's logging middleware wraps the raw app
    }

    ok(!-l "$dir/public", 'public assets are ordinary files that can ship to CPAN');
    ok(-f "$dir/public/$_", "ships $_") for qw(index.html css/style.css js/app.js);
};

subtest 'system events reach SSE subscribers live, not only on reconnect' => sub {
    require ChatApp::State;
    my @sent;
    my $subscriber = bless { sent => \@sent }, 'ChatTest::Subscriber';
    ChatApp::State::add_sse_subscriber('live-test', $subscriber, 0);
    ChatApp::State::add_room('live-test-room', 'tester');
    ChatApp::State::remove_sse_subscriber('live-test');
    ChatApp::State::remove_room('live-test-room');

    is([map { $_->{event} } @sent], ['room_created'],
        'creating a room pushes room_created to a connected subscriber');
    is($sent[0]{data}{room}, 'live-test-room', 'with the event data');
    like($sent[0]{id}, qr/\A\d+\z/, 'and its id, for Last-Event-ID catch-up');
};

my $app = do "$dir/app.pl";
my $load_error = $@ || $!;
ok(!$load_error, 'chat app loads cleanly') or diag($load_error);
isa_ok($app, 'PAGI::Compose');

SKIP: {
    skip 'chat app did not load', 1 unless ref($app) eq 'PAGI::Compose';

    my $native_app = $app->to_app;
    my ($stderr, %starts_by_path, %res) = ('');
    my $observed_app = sub {
        my ($scope, $receive, $send) = @_;
        my $path = $scope->{path} // '';
        return $native_app->($scope, $receive, sub {
            my ($event) = @_;
            $starts_by_path{$path}++ if ($event->{type} // '') eq 'http.response.start';
            return $send->($event);
        });
    };
    {
        local *STDERR;
        open STDERR, '>', \$stderr or die "cannot capture STDERR: $!";
        PAGI::Test::Client->run($observed_app, sub {
            my ($client) = @_;
            my $problem = { Accept => 'application/problem+json' };
            $res{stats}        = $client->get('/api/stats');
            $res{rooms}        = $client->get('/api/rooms');
            $res{history}      = $client->get('/api/room/general/history');
            $res{missing}      = $client->get('/api/not-a-route');
            $res{missing_json} = $client->get('/api/not-a-route', headers => $problem);
            $res{room_missing} = $client->get('/api/room/missing/history', headers => $problem);
            $res{index}        = $client->get('/');
            $res{css}          = $client->get('/css/style.css');
            $res{asset_missing} = $client->get('/not-a-static-file', headers => $problem);

            $client->websocket('/ws/chat?name=RootMount', sub {
                my ($ws) = @_;
                my $connected = $ws->receive_json;
                is($connected->{type}, 'connected', 'the WebSocket route accepts chat');
                is($connected->{name}, 'RootMount', 'with the name from the query string');
                is($ws->receive_json->{type}, 'joined', 'and joins the general room');
                $ws->send_json({ type => 'ping', ts => 17 });
                is($ws->receive_json, { type => 'pong', ts => 17 },
                    'application pings are answered');
            });

            my $websocket_miss = $client->websocket('/ws/missing');
            ok($websocket_miss->is_closed, 'a WebSocket miss is refused');
            ok(!defined $websocket_miss->close_code, 'with no RFC 6455 close code');

            $client->sse('/events', sub {
                my ($sse) = @_;
                is($sse->receive_event->{event}, 'room_created',
                    'SSE replays recent system events first');
            });

            my $sse_miss = $client->sse('/events/missing');
            is($sse_miss->status, 404, 'an SSE miss is declined with 404');
        });
    }

    is($res{stats}->status, 200, 'the stats API answers');
    ok(exists $res{stats}->json->{rooms_count}, 'with the statistics payload');
    ok((grep { $_->{name} eq 'general' } @{ $res{rooms}->json }), 'the rooms API lists general');
    is($res{history}->status, 200, 'a room history answers');

    is($res{missing}->status, 404, 'an unknown API path answers 404');
    like($res{missing}->text, qr/<h1>Not Found<\/h1>/, 'negotiated as HTML by default');
    is($starts_by_path{'/api/not-a-route'}, 2, 'one response per request, no second response');
    is($res{missing_json}->json, {
        type => 'about:blank', title => 'Not Found', status => 404,
        detail => 'No API route matched',
    }, 'or as a problem document');
    is($res{room_missing}->json, {
        type => 'about:blank', title => 'Not Found', status => 404,
        detail => 'Room not found',
    }, 'an absent room is a resource-level 404');

    is($res{index}->status, 200, 'the frontend is served');
    like($res{index}->text, qr/<title>PAGI Chat - Multi-User Chat Demo<\/title>/,
        'from the public directory');
    is($res{css}->content_type, 'text/css', 'with file MIME types');
    like($res{css}->text, qr/--accent-color:\s*#4a90d9/, 'and file contents');
    is($res{asset_missing}->status, 404, 'an unknown asset answers 404');
    is($res{asset_missing}->content_type, 'application/problem+json',
        'honoring problem JSON negotiation');

    like($stderr, qr/\[lifespan\] Application starting up/, 'startup runs');
    like($stderr, qr/\[lifespan\] Application shutting down/, 'shutdown runs');
    like($stderr, qr/^\[http\] GET \/api\/stats 200 /m, 'HTTP requests are logged');
    like($stderr, qr/^\[websocket\] - \/ws\/chat /m, 'WebSocket connections are logged');
    like($stderr, qr/^\[lifespan\] - - - /m, 'the lifespan loop is logged');
}

done_testing;

package ChatTest::Subscriber;
sub try_send_event {
    my ($self, %event) = @_;
    push @{ $self->{sent} }, \%event;
    return Future->done(1);
}
