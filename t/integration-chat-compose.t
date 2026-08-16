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
my $http_source = source_text($http_file);

like($http_source,
    qr/PAGI::App::File->app_path\('public'\)->to_app/,
    'chat HTTP uses the application-relative file app');
unlike($http_source,
    qr/_serve_static|_send_(?:404|500)|%MIME_TYPES|File::Basename|File::Spec|\$path\s*=~\s*s|\bopen\b/,
    'chat HTTP contains no manual static server');

my $app = do $app_file;
my $load_error = $@ || $!;
ok(!$load_error, 'chat app loads cleanly') or diag($load_error);
is(ref($app), 'CODE', 'chat app returns one compiled PAGI coderef');

SKIP: {
    skip 'chat app did not load', 17 unless ref($app) eq 'CODE';

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
        return $app->($scope, $receive, $observed_send);
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
        'an unknown API path is completed by the inner HTTP child');
    like($missing->text, qr/<h1>Not Found<\/h1>/,
        'the child uses its negotiated Compose routing fallback');
    is($starts_by_path{'/api/not-a-route'}, 1,
        'the opaque outer mount and root Compose emit no second response');
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
