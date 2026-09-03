use strict;
use warnings;

use Test2::V0;
use FindBin qw($Bin);
use Scalar::Util qw(blessed);
use lib "$Bin/../lib";
use PAGI::Test::Client;

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
    ['background-tasks',        'APP'],
    ['full-demo',               'CODE'],
    ['sse-close',               'CODE'],
    ['test-lifespan-shutdown',  'CODE'],
    ['websocket-bidirectional', 'CODE'],
    ['websocket-echo-v2',       'CODE'],
);
my %loaded_apps;

for my $case (@examples) {
    my ($directory, $expected) = @$case;

    subtest "$directory is executable" => sub {
        my $file = "$Bin/../examples/$directory/app.pl";
        if ($directory eq 'background-tasks') {
            my $source = source_text($file);
            unlike($source, qr/PAGI::App::Router/,
                'background tasks does not import the mutable App Router');
            unlike($source, qr/\$router->(?:get|post|websocket|sse|mount)\b/,
                'background tasks has no mutable route declarations');
            like($source,
                qr/use PAGI::Routing qw\(route mount\);/,
                'background tasks imports immutable route declarations');
            like($source,
                qr/route\('\/'\s*=>\s*sub\s*\{/s,
                'background tasks uses an ordinary Request handler for its index');
            my $native_routes = () = $source =~ /\bas_app_object\s*\(/g;
            is($native_routes, 3,
                'only response-first background-task routes remain native applications');
            like($source,
                qr/mount\('\/ws'\s*,\s*app\s*=>\s*async sub/s,
                'background tasks mounts its native WebSocket application directly');
        }
        if ($directory eq 'full-demo') {
            my $source = source_text($file);
            unlike($source, qr/PAGI::App::Router/,
                'full demo does not import the mutable App Router');
            unlike($source, qr/\$router->(?:get|post|websocket|sse|mount)\b/,
                'full demo has no mutable route declarations');
            like($source,
                qr/use PAGI::Routing qw\(route websocket sse\);/,
                'full demo imports immutable route declarations');
            unlike($source, qr/\bas_app_object\s*\(/,
                'full demo demonstrates direct high-level protocol handlers');
            like($source,
                qr/route\('\/'\s*=>\s*sub\s*\{/s,
                'full demo uses an ordinary Request handler for HTTP');
            like($source,
                qr/websocket\('\/ws\/echo'\s*=>\s*async sub\s*\{/s,
                'full demo uses a direct WebSocket object handler');
            like($source,
                qr/sse\('\/events'\s*=>\s*async sub\s*\{/s,
                'full demo uses a direct SSE object handler');
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

        $loaded_apps{$directory} = $app unless $load_error;

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

subtest 'background tasks serves its native root application' => sub {
    my $app = $loaded_apps{'background-tasks'};
    skip_all 'background tasks did not load' unless $app;

    my $client = PAGI::Test::Client->new(app => $app);
    my $response = $client->get('/');
    is($response->status, 200, 'root route responds successfully');
    like($response->text, qr/Background Tasks Demo/,
        'root route preserves its demonstration page');
};

subtest 'full demo serves its high-level root handler' => sub {
    my $app = $loaded_apps{'full-demo'};
    skip_all 'full demo did not load' unless $app;

    my $client = PAGI::Test::Client->new(app => $app);
    my $response = $client->get('/');
    is($response->status, 200, 'root route responds successfully');
    is($response->text, 'Hello, World!',
        'root route preserves its native response');
};

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
