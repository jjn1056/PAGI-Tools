#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../examples/websocket-chat-v2/lib";
use PAGI::Test::Client;

sub source_text {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot open $path: $!";
    local $/;
    my $source = <$fh>;
    close $fh or die "cannot close $path: $!";
    return $source;
}

my $app_file = "$Bin/../examples/websocket-chat-v2/app.pl";
my $http_file = "$Bin/../examples/websocket-chat-v2/lib/ChatApp/HTTP.pm";
my $http_source = source_text($http_file);

like($http_source,
    qr/PAGI::App::File->app_path\('public'\)->to_app/,
    'v2 chat HTTP uses the application-relative file app');
unlike($http_source,
    qr/_serve_static|_send_(?:404|500)|%MIME_TYPES|File::Basename|File::Spec|\$path\s*=~\s*s|\bopen\b/,
    'v2 chat HTTP contains no manual static server');

my $app = do $app_file;
my $load_error = $@ || $!;
ok(!$load_error, 'v2 chat app loads cleanly') or diag($load_error);
is(ref($app), 'CODE', 'v2 chat app returns one PAGI coderef');

subtest 'HTTP integration preserves static, API, lifespan, and logging behavior' => sub {
    plan skip_all => 'v2 chat app did not load' unless ref($app) eq 'CODE';

    my $stderr = '';
    local *STDERR;
    open STDERR, '>', \$stderr or die "cannot capture STDERR: $!";

    PAGI::Test::Client->run($app, sub {
        my ($client) = @_;

        my $index = $client->get('/');
        is($index->status, 200, 'v2 chat frontend remains reachable');
        like($index->text,
            qr/<title>PAGI Chat - Multi-User Chat Demo<\/title>/,
            'v2 root serves the shared chat frontend');

        my $css = $client->get('/css/style.css');
        is($css->status, 200, 'v2 chat stylesheet remains reachable');
        like($css->text, qr/--accent-color:\s*#4a90d9/,
            'v2 stylesheet content comes from the shared public directory');
        is($css->content_type, 'text/css',
            'v2 stylesheet uses the file app MIME type');

        my $missing = $client->get('/not-a-static-file',
            headers => { Accept => 'application/problem+json' });
        is($missing->status, 404,
            'v2 unknown non-API asset receives a terminal 404');
        is($missing->content_type, 'application/problem+json',
            'v2 static 404 honors problem JSON negotiation');
        is($missing->json->{status}, 404,
            'v2 negotiated problem identifies the missing asset status');

        my $stats = $client->get('/api/stats');
        is($stats->status, 200, 'v2 existing HTTP API remains reachable');
        ok(exists $stats->json->{rooms_count},
            'v2 existing statistics payload remains intact');

        my $api_missing = $client->get('/api/not-a-route',
            headers => { Accept => 'application/problem+json' });
        is($api_missing->status, 404,
            'v2 unmatched API path returns a terminal 404');
        is($api_missing->content_type, 'application/problem+json',
            'v2 unmatched API path negotiates a problem document');
        is($api_missing->json, {
            type   => 'about:blank',
            title  => 'Not Found',
            status => 404,
            detail => 'No API route matched',
        }, 'v2 unmatched API path uses the shared Pages representation');

        my $room_missing = $client->get('/api/room/missing/history',
            headers => { Accept => 'application/problem+json' });
        is($room_missing->status, 404,
            'v2 absent room returns a resource-level 404');
        is($room_missing->content_type, 'application/problem+json',
            'v2 absent room negotiates a problem document');
        is($room_missing->json, {
            type   => 'about:blank',
            title  => 'Not Found',
            status => 404,
            detail => 'Room not found',
        }, 'v2 absent room uses the shared Pages representation');
    });

    like($stderr, qr/\[lifespan\] Application starting up/,
        'v2 configured startup callback runs');
    like($stderr, qr/\[lifespan\] Application shutting down/,
        'v2 configured shutdown callback runs');
    like($stderr, qr/^\[http\] GET \/api\/stats 200 /m,
        'v2 application logging still surrounds HTTP dispatch');
};

done_testing;
