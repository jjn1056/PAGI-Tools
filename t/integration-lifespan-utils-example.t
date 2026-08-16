use strict;
use warnings;

use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use PAGI::Test::Client;

my $app_file = "$Bin/../examples/14-lifespan-utils/app.pl";
my $app = do $app_file;
my $load_error = $@ || $!;
ok(!$load_error, 'lifespan-utils example loads cleanly') or diag($load_error);
is(ref($app), 'CODE', 'lifespan-utils example returns a PAGI application');

SKIP: {
    skip 'lifespan-utils example did not load', 4 unless ref($app) eq 'CODE';

    my ($response, $stderr);
    {
        local *STDERR;
        open STDERR, '>', \$stderr or die "cannot capture STDERR: $!";
        PAGI::Test::Client->run($app, sub {
            my ($client) = @_;
            $response = $client->get('/',
                headers => { Accept => 'text/plain' });
        });
    }

    is($response->status, 200, 'HTTP branch returns the welcome response');
    is($response->content_type, 'text/plain; charset=utf-8',
        'welcome response uses the requested text representation');
    like($response->text, qr/\AWelcome to PAGI\n/,
        'welcome response uses the shared Pages copy');
    like($response->text, qr{https://metacpan\.org/pod/PAGI},
        'welcome response links to the PAGI documentation');
}

done_testing;
