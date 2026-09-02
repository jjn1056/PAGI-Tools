use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use PAGI::Test::Client;

sub source_text {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot open $path: $!";
    local $/;
    my $source = <$fh>;
    close $fh or die "cannot close $path: $!";
    return $source;
}

my @cases = (
    {
        name  => 'endpoint demo',
        file  => "$Bin/../examples/endpoint-demo/app.pl",
        title => qr/PAGI Endpoint Demo/,
        shape => qr{mount\('/'\s*,\s*app\s*=>\s*PAGI::App::File->from_app_path\('public'\)\s*\)},
        class => 'PAGI::Compose',
    },
    {
        name  => 'SSE dashboard',
        file  => "$Bin/../examples/sse-dashboard/app.pl",
        title => qr/PAGI Live Dashboard/,
        shape => qr{PAGI::App::File->from_app_path\('public'\)->to_app},
    },
    {
        name  => 'contact form',
        file  => "$Bin/../examples/13-contact-form/app.pl",
        title => qr/Contact Form/,
        shape => qr{PAGI::App::File->from_app_path\('public'\)->to_app},
    },
);

for my $case (@cases) {
    subtest $case->{name} => sub {
        my $source = source_text($case->{file});
        like($source, $case->{shape}, 'uses the application-relative constructor');
        unlike($source, qr/PAGI::App::File->new\s*\(/,
            'contains no manual App File constructor');

        local $ENV{PAGI_HOME};
        delete $ENV{PAGI_HOME};
        local $ENV{PAGI_ENV} = 'production';
        my $app = do $case->{file};
        my $load_error = $@ || $!;
        ok(!$load_error, 'loads cleanly') or diag($load_error);
        if ($case->{class}) {
            isa_ok($app, $case->{class});
        }
        else {
            is(ref($app), 'CODE', 'returns a native PAGI application');
        }

        SKIP: {
            skip 'example did not load', ($case->{name} eq 'endpoint demo' ? 17 : 2)
                unless ref($app) eq 'CODE'
                    || ($case->{class} && ref($app) eq $case->{class});
            my $client = PAGI::Test::Client->new(app => $app);
            my $response = $client->get('/');
            is($response->status, 200, 'static index responds');
            like($response->text, $case->{title}, 'index comes from the public root');

            if ($case->{name} eq 'endpoint demo') {
                like($source,
                    qr{mount\('/'\s*=>\s*app\s*=>\s*\$router\)},
                    'endpoint demo mounts the App Router application directly');
                unlike($source, qr/\$router->to_router/,
                    'endpoint demo does not materialize an unused snapshot');
                unlike($source,
                    qr/\$ctx\b|PAGI::Context|->request|->websocket|->sse/,
                    'endpoint callbacks do not reach through a Context object');
                like($source,
                    qr/async sub get \{\n        my \(\$self, \$request\) = \@_;\n        return PAGI::Response::JSON->new\(\\\@messages\);/,
                    'HTTP GET accepts its direct request object');
                like($source,
                    qr/async sub post \{\n        my \(\$self, \$request\) = \@_;\n        my \$data = await \$request->json;/,
                    'HTTP POST names and uses its direct request object');
                like($source,
                    qr/package EchoWS \{.*?async sub on_connect \{\n        my \(\$self, \$websocket\) = \@_;.*?await \$websocket->accept;.*?async sub on_receive \{\n        my \(\$self, \$websocket, \$data\) = \@_;.*?await \$websocket->send_json/s,
                    'WebSocket hooks name and use their direct WebSocket object');
                like($source,
                    qr/package MessageEvents \{.*?async sub on_connect \{\n        my \(\$self, \$sse\) = \@_;.*?stash\(\$sse\)->set\(sub_id => \$id\);.*?sub on_disconnect \{\n        my \(\$self, \$sse\) = \@_;.*?stash\(\$sse\)->get/s,
                    'SSE hooks name and use their direct SSE object and stash');

                my $missing = $client->get('/not-a-static-file');
                is($missing->status, 404,
                    'unresolved endpoint-demo root request is complete');
                ok(defined $missing->content,
                    'unresolved root request includes a terminal body');
                is($missing->content_length, length($missing->content),
                    'unresolved root response advertises its complete body');

                my $unsupported = $client->post('/api/messages');
                is($unsupported->status, 415,
                    'message API rejects a request without JSON content type');
                is($unsupported->content_type, 'application/problem+json',
                    'content-type rejection uses a problem document');
                is($unsupported->json, {
                    type   => 'about:blank',
                    title  => 'Unsupported Media Type',
                    status => 415,
                    detail => 'Content-Type must be application/json',
                }, 'content-type rejection uses the shared Pages representation');

                my $messages = $client->get('/api/messages');
                is($messages->status, 200, 'message API lists messages');
                is($messages->json, [
                    { id => 1, text => 'Hello, World!' },
                    { id => 2, text => 'Welcome to PAGI Endpoints' },
                ], 'message API lists its initial JSON messages');

                my $created = $client->post('/api/messages', json => {
                    text => 'Direct request object',
                });
                is($created->status, 201, 'message API creates a JSON message');
                is($created->json, {
                    id   => 3,
                    text => 'Direct request object',
                }, 'created message preserves the JSON request data');
            }
        }
    };
}

my $endpoint = source_text($cases[0]{file});
unlike($endpoint, qr/File::Basename|File::Spec|dirname\s*\(/,
    'endpoint demo has no obsolete path arithmetic');

my $bidirectional = source_text("$Bin/../examples/websocket-bidirectional/app.pl");
unlike($bidirectional, qr/\$ctx\b|PAGI::Context/,
    'bidirectional WebSocket example has no Context dependency');
like($bidirectional,
    qr/use PAGI::WebSocket;.*?my \$websocket = PAGI::WebSocket->new\(\$scope, \$receive, \$send\);.*?await \$websocket->accept;/s,
    'bidirectional WebSocket example constructs and accepts one direct object');
like($bidirectional,
    qr/my \$incoming = \$websocket->each_text\(async sub \{/,
    'bidirectional receive loop uses the direct WebSocket object');
like($bidirectional,
    qr/await \$websocket->send_text_if_connected.*?while \(\$websocket->is_connected\)/s,
    'bidirectional send queue and loop use the direct WebSocket object');

my $dashboard = source_text($cases[1]{file});
unlike($dashboard, qr/File::Basename|File::Spec|dirname\s*\(/,
    'SSE dashboard has no obsolete path arithmetic');

my $contact = source_text($cases[2]{file});
like($contact,
    qr/my \$UPLOAD_DIR = File::Spec->catdir\(dirname\(__FILE__\), 'uploads'\)/,
    'contact form retains its explicit writable upload path');
unlike($contact, qr/\$PUBLIC_DIR/,
    'contact form no longer calculates a static public path');

done_testing;
