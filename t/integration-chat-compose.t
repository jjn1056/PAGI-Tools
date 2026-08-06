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
    skip 'chat app did not load', 6 unless ref($app) eq 'CODE';

    my $stderr = '';
    my $stats;
    {
        local *STDERR;
        open STDERR, '>', \$stderr or die "cannot capture STDERR: $!";
        PAGI::Test::Client->run($app, sub {
            my ($client) = @_;
            $stats = $client->get('/api/stats');
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
}

done_testing;
