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
    ['psgi-bridge',          'APP'],
    ['background-tasks',        'APP'],
    ['full-demo',               'APP'],
    ['sse-close',               'APP'],
    ['test-lifespan-shutdown',  'CODE'],
    ['websocket-bidirectional', 'APP'],
    ['websocket-echo',       'APP'],
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
                qr/use PAGI::Tools qw\(compose response route websocket\);/,
                'background tasks imports immutable route declarations');
            like($source,
                qr/route\('\/'\s*=>\s*sub\s*\{/s,
                'background tasks uses an ordinary Request handler for its index');
            unlike($source, qr/\bas_app_object\b/,
                'every background-task route is an ordinary handler (John, 2026-09-30)');
            like($source,
                qr/websocket\('\/ws'\s*=>\s*\\&messages\)/,
                'background tasks declares its WebSocket as a one-$ws handler');
        }
        if ($directory eq 'full-demo') {
            my $source = source_text($file);
            unlike($source, qr/PAGI::App::Router/,
                'full demo does not import the mutable App Router');
            unlike($source, qr/\$router->(?:get|post|websocket|sse|mount)\b/,
                'full demo has no mutable route declarations');
            like($source,
                qr/use PAGI::Tools qw\([^)]*\broute\b[^)]*\bwebsocket\b[^)]*\);/,
                'full demo imports immutable route declarations (PAGI::Routing\'s, through PAGI::Tools)');
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

subtest 'endpoint demo names endpoint classes at routes' => sub {
    my $source = source_text("$Bin/../examples/endpoint-demo/app.pl");

    unlike($source, qr/use PAGI::App::Router;/,
        'endpoint demo does not import the mutable App Router');
    unlike($source, qr/->to_app\b/,
        'endpoint demo does not materialize endpoint applications manually');
    like($source,
        qr/route\('\/api\/messages'\s*=>\s*endpoint\('MessageAPI'\),\s*
            middleware\s*=>\s*\[middleware\(\$access_log\),\s*middleware\(\$require_json\)\]/x,
        'HTTP endpoint is a direct route with its existing middleware');
    like($source,
        qr/websocket\('\/ws\/echo'\s*=>\s*endpoint\('EchoWS'\),\s*
            middleware\s*=>\s*\[middleware\(\$timing\)\]/x,
        'WebSocket endpoint uses protocol-neutral middleware (AccessLog logs HTTP only)');
    like($source,
        qr/sse\('\/events'\s*=>\s*endpoint\('MessageEvents'\),\s*
            middleware\s*=>\s*\[middleware\('Stash'\),\s*middleware\(\$timing\)\]/x,
        'SSE endpoint is a direct route with the Stash its stream uses and its existing middleware');
    like($source,
        qr/route\('\/\*path'\s*=>\s*PAGI::App::File->from_app_path\('public'\)\)/,
        'static files are the final HTTP-only catch-all route');
    like($source,
        qr/PAGI::HTTPConnection->new\(\$scope\)->headers->content_type \/\/ ''/,
        'the JSON check reads the parsed media type through PAGI::HTTPConnection');
    unlike($source, qr/\$scope->\{headers\}/,
        'no middleware reads the raw scope headers by hand');
};

subtest 'example middleware reads the request through PAGI::HTTPConnection' => sub {
    my %reads = (
        'endpoint-class-demo/lib/MyApp/API.pm' =>
            qr/PAGI::HTTPConnection->new\(\$scope\)->header\('x-demo-token'\)/,
        'tenant-orders/app.pl' =>
            qr/PAGI::HTTPConnection->new\(\$scope\)->headers->get_single\('x-api-key'\).*?my \$conn = PAGI::HTTPConnection->new\(\$scope\);.*?\$conn->header\('authorization'\).*?\$conn->query_param\('region'\)/s,
        'signed-requests/app.pl' =>
            qr/PAGI::HTTPConnection->new\(\$scope\)->header\('x-signature'\)/,
        'state-lifetimes/lib/MyApp/Middleware/AccessLog.pm' =>
            qr/PAGI::HTTPConnection->new\(\$scope\)->state/,
    );
    for my $file (sort keys %reads) {
        my $source = source_text("$Bin/../examples/$file");
        like($source, $reads{$file}, "$file reads through PAGI::HTTPConnection");
        unlike($source, qr/grep \{ lc\(\$_->\[0\]\) eq '[a-z-]+' \} \@\{ ?\$scope->\{headers\}/,
            "$file has no hand-written header loop");
    }
};

done_testing;
