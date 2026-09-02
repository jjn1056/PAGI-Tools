use strict;
use warnings;

use Test2::V0;
use FindBin qw($Bin);
use Scalar::Util qw(blessed);
use lib "$Bin/../lib";

sub source_text {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot open $path: $!\n";
    local $/;
    my $source = <$fh>;
    close $fh or die "cannot close $path: $!\n";
    return $source;
}

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
        if ($directory eq 'full-demo') {
            my $source = source_text($file);
            like($source,
                qr{mount\('/'\s*=>\s*app\s*=>\s*\$router\)},
                'full demo mounts the App Router application directly');
            unlike($source, qr/\$router->to_router/,
                'full demo does not materialize an unused snapshot');
        }
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

subtest 'endpoint demo declares endpoint objects directly' => sub {
    my $source = source_text("$Bin/../examples/endpoint-demo/app.pl");

    unlike($source, qr/use PAGI::App::Router;/,
        'endpoint demo does not import the mutable App Router');
    unlike($source, qr/->to_app\b/,
        'endpoint demo does not materialize endpoint applications manually');
    like($source,
        qr/route\('\/api\/messages'\s*=>\s*MessageAPI->new,\s*
            middleware\s*=>\s*\[middleware\(\$access_log\),\s*middleware\(\$require_json\)\]/x,
        'HTTP endpoint is a direct route with its existing middleware');
    like($source,
        qr/websocket\('\/ws\/echo'\s*=>\s*EchoWS->new,\s*
            middleware\s*=>\s*\[middleware\(\$access_log\),\s*middleware\(\$timing\)\]/x,
        'WebSocket endpoint is a direct route with its existing middleware');
    like($source,
        qr/sse\('\/events'\s*=>\s*MessageEvents->new,\s*
            middleware\s*=>\s*\[middleware\(\$timing\)\]/x,
        'SSE endpoint is a direct route with its existing middleware');
    like($source,
        qr/mount\('\/'\s*=>\s*app\s*=>\s*PAGI::App::File->from_app_path\('public'\)\)/,
        'static files remain the final direct fallback mount');
};

done_testing;
