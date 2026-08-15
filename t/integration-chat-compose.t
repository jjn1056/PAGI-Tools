#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../examples/10-chat-showcase/lib";
use PAGI::Test::Client;

my $app_file = "$Bin/../examples/10-chat-showcase/app.pl";
my $app = do $app_file;
my $load_error = $@ || $!;
ok(!$load_error, 'chat app loads cleanly') or diag($load_error);
is(ref($app), 'CODE', 'chat app returns one compiled PAGI coderef');

SKIP: {
    skip 'chat app did not load', 9 unless ref($app) eq 'CODE';

    my $stderr = '';
    my $stats;
    my $missing;
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
}

done_testing;
