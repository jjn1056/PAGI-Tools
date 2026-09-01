use strict;
use warnings;

use Test2::V0;
use FindBin qw($Bin);
use Scalar::Util qw(blessed);
use lib "$Bin/../lib";

my @examples = (
    ['09-psgi-bridge',          'CODE'],
    ['full-demo',               'CODE'],
    ['sse-close',               'CODE'],
    ['test-lifespan-shutdown',  'CODE'],
    ['websocket-bidirectional', 'CODE'],
    ['websocket-echo-v2',       'CODE'],
);

for my $case (@examples) {
    my ($directory, $expected) = @$case;

    subtest "$directory is executable" => sub {
        my $file = "$Bin/../examples/$directory/app.pl";
        my $stderr = '';
        my $app;
        my $load_error;
        {
            local *STDERR;
            open STDERR, '>', \$stderr
                or die "cannot capture STDERR for $directory: $!";
            $app = do $file;
            $load_error = $@ || $!;
        }

        ok(!$load_error, "$directory loads cleanly") or diag($load_error);
        if ($expected eq 'CODE') {
            is(ref($app), 'CODE', "$directory returns a native PAGI application");
        }
        else {
            ok(blessed($app) && $app->can('to_app'),
                "$directory returns a to_app-capable application");
        }
    };
}

done_testing;
