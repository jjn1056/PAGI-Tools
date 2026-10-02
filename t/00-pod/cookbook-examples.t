#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use File::Temp qw(tempfile);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);

use lib 'lib';
use PAGI::Compose qw(compose);
use PAGI::Response qw(response);
use PAGI::Routing qw(middleware mount route router sse websocket);

sub slurp_file {
    my ($file) = @_;
    open my $handle, '<', $file or die "Cannot read $file: $!";
    local $/;
    my $source = <$handle>;
    close $handle or die "Cannot close $file: $!";
    return $source;
}

sub cookbook_apples_block {
    my ($cookbook) = @_;
    my $heading = '=head2 Complete Declarative Apples Application';
    my $position = index $cookbook, $heading;
    die 'Complete Declarative Apples Application section not found'
        if $position < 0;
    my @lines = split /\n/, substr($cookbook, $position);
    my (@block, $started);
    for my $line (@lines) {
        if (!$started) {
            next unless $line eq '  use v5.40;';
            $started = 1;
        }
        last if length($line) && $line !~ /^  /;
        push @block, length($line) ? substr($line, 2) : '';
    }
    pop @block while @block && $block[-1] eq '';
    return join("\n", @block) . "\n";
}

sub pod_section {
    my ($source, $heading) = @_;
    my $start = index $source, $heading;
    die "section not found: $heading" if $start < 0;
    my $body = substr $source, $start;
    $body =~ s/\A\Q$heading\E\n//;
    $body =~ s/\n=head[12]\s.*\z//s;
    return $body;
}

sub first_code_block {
    my ($source, $heading) = @_;
    my $section = pod_section($source, $heading);
    my @lines = split /\n/, $section;
    my (@block, $started);
    for my $line (@lines) {
        if (!$started) {
            next unless $line =~ /^  \S/;
            $started = 1;
        }
        last if length($line) && $line !~ /^  /;
        push @block, length($line) ? substr($line, 2) : '';
    }
    pop @block while @block && $block[-1] eq '';
    die "code block not found: $heading" unless @block;
    return join("\n", @block) . "\n";
}

sub code_block_containing {
    my ($source, $heading, $needle) = @_;
    my $section = pod_section($source, $heading);
    my @lines = split /\n/, $section;
    my @blocks;
    my @block;
    for my $line (@lines) {
        if ($line =~ /^  /) {
            push @block, length($line) ? substr($line, 2) : '';
        }
        elsif ($line eq '' && @block) {
            push @block, '';
        }
        elsif (@block) {
            pop @block while @block && $block[-1] eq '';
            push @blocks, join("\n", @block) . "\n";
            @block = ();
        }
    }
    if (@block) {
        pop @block while @block && $block[-1] eq '';
        push @blocks, join("\n", @block) . "\n";
    }
    my ($match) = grep { index($_, $needle) >= 0 } @blocks;
    die "code block containing '$needle' not found after $heading"
        unless defined $match;
    return $match;
}

sub perl_script_runs {
    my ($label, $source) = @_;
    my ($handle, $path) = tempfile(SUFFIX => '.pl');
    print {$handle} $source or die "Cannot write $path: $!";
    close $handle or die "Cannot close $path: $!";

    my ($input, $output);
    my $error = gensym;
    my $pid = open3($input, $output, $error, $^X, '-Ilib', $path);
    close $input;
    my $stdout = do { local $/; <$output> // '' };
    my $stderr = do { local $/; <$error> // '' };
    waitpid $pid, 0;
    is $?, 0, "$label executes as published" or diag $stdout . $stderr;
}

my $cookbook = slurp_file('lib/PAGI/Tools/Cookbook.pod');
my $tutorial = slurp_file('lib/PAGI/Tools/Tutorial.pod');

subtest 'canonical apples block stays synchronized with the runnable example' => sub {
    my $example = slurp_file('examples/starlette-apples/app.pl');
    $example =~ s/\A#![^\n]*\n//;
    is cookbook_apples_block($cookbook), $example,
        'the complete Cookbook block is the runnable apples source without its shebang';
};

subtest 'Cookbook publishes the complete declarative topology' => sub {
    like $cookbook,
        qr/Endpoint::HTTP\/WebSocket\/SSE.*?one exact route.*?Route.*?exact path.*?Mount.*?prefix.*?Router.*?ordered children.*?Compose.*?lifespan/is,
        'the five-layer topology appears in the Cookbook';
    like $cookbook, qr/route\('\/messages'\s*=>\s*MessageAPI->new/,
        'HTTP endpoint object is placed at one exact Route';
    like $cookbook, qr/websocket\('\/chat'\s*=>\s*ChatEndpoint->new/,
        'WebSocket endpoint object is placed at one exact Route';
    like $cookbook, qr/sse\('\/events'\s*=>\s*EventEndpoint->new/,
        'SSE endpoint object is placed at one exact Route';
    like $cookbook, qr/sub routing.*?return router\(/s,
        'ordinary object assembly returns an immutable Router';
    like $cookbook, qr/compose\(\s*routes\s*=>\s*\[/s,
        'Compose receives root routes directly';
    like $cookbook,
        qr/use PAGI::Utils qw\(app_path\).*?sub public_root.*?app_path\('public'\)/s,
        'app_path is called directly by the asset-owning module';
};

subtest 'published standalone recipes compile and construct their values' => sub {
    my $exact = first_code_block($cookbook,
        '=head2 Class-Based Exact Leaves and Ordinary Assemblers');
    perl_script_runs(
        'class-based exact leaves',
        $exact
            . "die 'expected Compose' unless ref(\$app) eq 'PAGI::Compose';\n"
            . "use PAGI::Test::Client;\n"
            . "my \$response = PAGI::Test::Client->new(app => \$app)->get('/api/messages');\n"
            . "die 'expected useful message response' unless \$response->status == 200 && \$response->json->[0]{text} eq 'hello';\n",
    );
    my $rate_limit = first_code_block($cookbook,
        '=head2 In-Loop WebSocket Rate Limiting');
    perl_script_runs(
        'WebSocket rate limiter',
        $rate_limit . "die 'expected WebSocket Route' unless \$chat_route->kind eq 'websocket';\n",
    );
    my $xsendfile = first_code_block(
        $cookbook, '=head3 Custom Download Handler');
    perl_script_runs(
        'custom XSendfile download',
        $xsendfile
            . "die 'expected Router' unless ref(\$router) eq 'PAGI::Routing::Router';\n"
            . "die 'expected wrapped application' unless ref(\$app) eq 'CODE';\n",
    );
};

subtest 'protocol refusal recipe executes all six forms on both protocols' => sub {
    my $recipe = first_code_block($cookbook,
        '=head2 Refusing WebSocket and SSE with applications');
    my $checks = <<'PERL';
use PAGI::Test::Client;
my $client = PAGI::Test::Client->new(app => $app);
for my $form (qw(response handler async-handler pages object native)) {
    my %ws_options = $form eq 'pages'
        ? (headers => {Accept => 'text/html'}) : ();
    my $socket = $client->websocket("/ws/$form", %ws_options);
    die "$form WebSocket was accepted" unless $socket->refused;
    my $ws_response = $socket->response;
    die "$form WebSocket status" unless $ws_response->status == 503;

    my %sse_options = $form eq 'pages'
        ? (headers => {Accept => 'application/problem+json'}) : ();
    my $sse_response = $client->sse("/events/$form", %sse_options);
    die "$form SSE started" unless $sse_response->isa('PAGI::Test::Response');
    die "$form SSE status" unless $sse_response->status == 503;

    if ($form eq 'response') {
        die 'response WebSocket body' unless $ws_response->text eq 'Scheduled maintenance';
        die 'response SSE body' unless $sse_response->json->{form} eq 'response';
    }
    elsif ($form eq 'handler') {
        die 'handler WebSocket path' unless $ws_response->json->{path} eq '/ws/handler';
        die 'handler SSE path' unless $sse_response->json->{path} eq '/events/handler';
    }
    elsif ($form eq 'async-handler') {
        die 'async WebSocket notice' unless $ws_response->json->{notice} eq 'notice-service:/ws/async-handler';
        die 'async SSE notice' unless $sse_response->json->{notice} eq 'notice-service:/events/async-handler';
    }
    elsif ($form eq 'pages') {
        die 'Pages WebSocket HTML' unless $ws_response->content_type eq 'text/html; charset=utf-8';
        die 'Pages SSE JSON' unless $sse_response->content_type eq 'application/problem+json';
    }
    elsif ($form eq 'object') {
        die 'object WebSocket scope' unless $ws_response->text eq 'Custom application: /ws/object';
        die 'object SSE scope' unless $sse_response->text eq 'Custom application: /events/object';
    }
    else {
        die 'native WebSocket body' unless $ws_response->text eq 'Scheduled maintenance';
        die 'native SSE body' unless $sse_response->text eq 'Scheduled maintenance';
    }
}
PERL
    perl_script_runs('protocol refusal application forms', $recipe . $checks);
};

subtest 'custom Request route helper recipe executes as published' => sub {
    my $recipe = first_code_block(
        $cookbook, '=head2 Custom Request Route Helpers');
    perl_script_runs(
        'custom Request route helper',
        $recipe
            . "use PAGI::Test::Client;\n"
            . "my \$captured = PAGI::Test::Client->new(app => \$route->to_app)->get('/reports');\n"
            . "die 'expected custom Request response' unless \$captured->status == 200 && \$captured->content eq 'Example Corp reports';\n",
    );
};

subtest 'Serving behind a proxy prefix recipe executes as published' => sub {
    my $recipe = first_code_block($cookbook, '=head2 Serving behind a proxy prefix');
    perl_script_runs(
        'proxy prefix recipe',
        $recipe
            . "die 'path' unless \$report->{path} eq '/reports';\n"
            . "die 'root' unless \$report->{root_path} eq '/app';\n"
            . "die 'here' unless \$report->{here} eq '/app/reports?x=1';\n"
            . "die 'link' unless \$report->{link} eq '/app/reports';\n",
    );
};

subtest 'Declaring what a route requires recipe executes as published' => sub {
    my $recipe = first_code_block($cookbook, '=head2 Declaring what a route requires');
    perl_script_runs(
        'requires recipe',
        $recipe
            . "use PAGI::Test::Client;\n"
            . "my \$c = PAGI::Test::Client->new(app => \$app);\n"
            . "my %as = map { \$_ => { Authorization => \"Bearer \$_\", Accept => 'application/json' } } qw(reader editor);\n"
            . "die 'me: reader allowed' unless \$c->get('/me', headers => \$as{reader})->json->{me} eq 'reader';\n"
            . "die 'me: guest refused' unless \$c->get('/me', headers => { Accept => 'application/json' })->status == 403;\n"
            . "die 'notes: reader refused' unless \$c->post('/notes', headers => \$as{reader}, json => {})->status == 403;\n"
            . "die 'notes: editor allowed' unless \$c->post('/notes', headers => \$as{editor}, json => { t => 1 })->status == 201;\n"
            . "die 'audit: hidden' unless \$c->get('/audit', headers => \$as{editor})->status == 404;\n"
            . "my \$r = \$c->get('/home');\n"
            . "die 'home: redirect' unless \$r->status == 303 && \$r->header('location') eq '/login?next=%2Fhome';\n",
    );
};

subtest 'Bad request bodies recipe executes as published' => sub {
    my $default = code_block_containing($cookbook, '=head2 Bad request bodies', 'create_note_kindly');
    my $uniform = code_block_containing($cookbook, '=head2 Bad request bodies', 'my $uniform');
    perl_script_runs(
        'bad request bodies recipe',
        $default . $uniform
            . "use PAGI::Test::Client;\n"
            . "my \%bad = (body => '{not json', headers => { 'Content-Type' => 'application/json', Accept => 'application/json' });\n"
            . "my \$client = PAGI::Test::Client->new(app => \$app);\n"
            . "my \$res = \$client->post('/notes', \%bad);\n"
            . "die 'default: expected a 400 problem document' unless \$res->status == 400 && \$res->header('content-type') eq 'application/problem+json';\n"
            . "\$res = \$client->post('/notes/kindly', \%bad);\n"
            . "die 'kindly: expected its own 400' unless \$res->status == 400 && \$res->json->{error} =~ /Send a JSON object/;\n"
            . "\$res = \$client->post('/notes/kindly', body => '{\"text\":\"hi\"}', headers => { 'Content-Type' => 'application/json' });\n"
            . "die 'kindly: a valid body is created' unless \$res->status == 201;\n"
            . "\$res = PAGI::Test::Client->new(app => \$uniform)->post('/notes', \%bad);\n"
            . "die 'uniform: expected the handler shape' unless \$res->status == 400 && \$res->json->{error} eq 'The request body is not valid JSON.';\n",
    );
};

subtest 'Streaming Response Extension NDJSON recipe executes as published' => sub {
    my $recipe = first_code_block($cookbook,
        '=head2 Streaming Response Extension: NDJSON');
    perl_script_runs(
        'streaming response extension NDJSON recipe',
        $recipe
            . "use PAGI::Test::Client;\n"
            . "my \$captured = PAGI::Test::Client->new(app => \$response->to_app)->get('/');\n"
            . "die 'expected two newline-terminated JSON records' unless \$captured->content eq qq|{\\\"id\\\":1}\\n{\\\"id\\\":2}\\n|;\n",
    );
};

subtest 'Tutorial routing object example executes exactly as published' => sub {
    my $source = code_block_containing(
        $tutorial,
        '=head2 2.3 One Routing API, Five Boundaries',
        'package MyApp::People;',
    );
    perl_script_runs(
        'Tutorial routing object',
        $source
            . "die 'expected mounted people Router' unless \$people_mount->kind eq 'mount';\n",
    );
};

subtest 'finite endpoint method prose matches Route construction' => sub {
    my $section = pod_section(
        $cookbook, '=head2 Class-Based Exact Leaves and Ordinary Assemblers');
    my $mounts = pod_section(
        $cookbook, '=head2 Inline, Router, and Application Mounts');
    unlike $mounts, qr/explicit Route declaration wins/,
        'mount comparison does not claim finite methods bypass endpoint capability';
    like $mounts,
        qr/finite.*?method.*?C<allowed_methods>.*?restriction/is,
        'mount comparison states the finite endpoint restriction rule';
    like $section, qr/C<allowed_methods> is consulted once.*?finite/is,
        'finite explicit methods consult one capability snapshot';
    like $section, qr/finite.*?C<methods>.*?must be a restriction/is,
        'finite explicit methods must restrict the capability snapshot';
    like $section,
        qr/Only scalar.*?methods => '\*'.*?bypasses/is,
        'only scalar star bypasses endpoint method capability';
};

subtest 'representative final forms construct' => sub {
    my $factory = sub {
        my ($inner) = @_;
        return sub { return $inner->(@_) };
    };
    my $child = router(routes => [
        route('/' => sub { return response('Text', 'child') }, name => 'index'),
    ]);
    my $root = compose(routes => [
        route('/health' => sub { return response('Text', 'ok') },
            middleware => [middleware($factory)]),
        mount('/child', app => $child, name => 'child'),
        websocket('/chat' => sub { return $_[0]->close }),
        sse('/events' => sub { return $_[0]->close }),
    ]);
    isa_ok $child, 'PAGI::Routing::Router';
    isa_ok $root, 'PAGI::Compose';
    is $root->path_for('/child/index'), '/child/',
        'mounted child remains discoverable for reverse routing';
};

unlike $cookbook,
    qr/PAGI::(?:App|Endpoint)::Router|\b(?:App|Endpoint) Router\b|->to_router|middleware_as|app_as/,
    'Cookbook contains no removed frontend syntax';

done_testing;
