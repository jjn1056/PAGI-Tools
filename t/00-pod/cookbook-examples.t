#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use File::Temp qw(tempdir tempfile);
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

# The Perl a recipe is written for, when it is newer than this one: a recipe
# that begins "use v5.40;" runs only on 5.40 and later.
sub perl_needed {
    my ($source) = @_;
    my ($minor) = $source =~ /^\s*use v5\.(\d+)/m or return;
    return $] < 5 + $minor / 1000 ? "5.$minor" : undef;
}

sub perl_script_runs {
    my ($label, $source) = @_;
    if (my $needed = perl_needed($source)) {
        SKIP: { skip "$label is written for Perl $needed", 1 }
        return;
    }
    my ($handle, $path) = tempfile(SUFFIX => '.pl', UNLINK => 1);
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
    like $cookbook, qr/route\('\/messages'\s*=>\s*endpoint\('MessageAPI'/,
        'HTTP endpoint class is named at one exact Route';
    like $cookbook, qr/websocket\('\/chat'\s*=>\s*endpoint\('ChatEndpoint'/,
        'WebSocket endpoint class is named at one exact Route';
    like $cookbook, qr/sse\('\/events'\s*=>\s*endpoint\('EventEndpoint'/,
        'SSE endpoint class is named at one exact Route';
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

subtest "An Application's Request Class recipe executes as published" => sub {
    my $recipe = first_code_block($cookbook, "=head2 An Application's Request Class");
    perl_script_runs(
        'application Request class recipe',
        $recipe
            . "use PAGI::Test::Client;\n"
            . "my \$response = PAGI::Test::Client->new(app => \$app)->get('/reports');\n"
            . "die 'expected the class helper' unless \$response->status == 200 && \$response->text eq 'Example Corp reports';\n",
    );
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

subtest 'Linking inside a mounted app recipe executes as published' => sub {
    my $recipe = first_code_block($cookbook, '=head2 Linking inside a mounted app');
    perl_script_runs(
        'mounted app links',
        $recipe
            . "die 'absolute from the root' unless \$from_root->{note} eq '/api/notes/1';\n"
            . "die 'relative sibling' unless \$from_api->{notes} eq '/api/notes';\n"
            . "die 'parent' unless \$from_api->{home} eq '/';\n",
    );
};


subtest 'Linking to static files recipe executes as published' => sub {
    my $recipe = code_block_containing($cookbook,
        '=head2 Linking to static files', "{ path => 'css/app.css' }");
    perl_script_runs(
        'static file links',
        $recipe
            . "die 'css' unless \$links->{css} eq '/app/static/css/app.css';\n"
            . "die 'prefix' unless \$links->{prefix} eq '/app/static';\n",
    );
};

subtest 'Constraint Forms recipe shows the route its typed-text example names' => sub {
    my $heading = '=head2 Constraint Forms and Wildcard Safety';
    like first_code_block($cookbook, $heading), qr{route\('/typed/\{id:&Int\}'},
        'the /typed route is the first example';
    like pod_section($cookbook, $heading), qr{C</typed/09> matches},
        'and the typed-text paragraph that names it is kept';
};

subtest 'Matched-Route Metadata recipe executes as published' => sub {
    my $recipe = first_code_block($cookbook, '=head2 Matched-Route Metadata');
    # The recipe's closing comment says what @log holds; the run must match it.
    my ($published) = $recipe =~ /^# \@log is now:\n((?:#   .*\n)+)/m;
    ok($published, 'the recipe says what @log holds');
    my @want = map { s/\A#   //r } split /\n/, $published // '';
    perl_script_runs(
        'matched-route metadata recipe',
        $recipe
            . 'my $want = join "|", ' . join(', ', map { "q{$_}" } @want) . ";\n"
            . "die 'log: ' . join('|', \@log) unless join('|', \@log) eq \$want;\n",
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
            . "die 'default: expected a plain 400' unless \$res->status == 400 && \$res->content_type eq 'text/plain; charset=utf-8' && \$res->text eq 'The request body is not valid JSON.';\n"
            . "\$res = \$client->post('/notes/kindly', \%bad);\n"
            . "die 'kindly: expected its own 400' unless \$res->status == 400 && \$res->json->{error} =~ /Send a JSON object/;\n"
            . "\$res = \$client->post('/notes/kindly', body => '{\"text\":\"hi\"}', headers => { 'Content-Type' => 'application/json' });\n"
            . "die 'kindly: a valid body is created' unless \$res->status == 201;\n"
            . "\$res = PAGI::Test::Client->new(app => \$uniform)->post('/notes', \%bad);\n"
            . "die 'uniform: expected the handler shape' unless \$res->status == 400 && \$res->json->{error} eq 'The request body is not valid JSON.';\n",
    );
};

subtest 'Streaming Response Formats recipe executes as published' => sub {
    my $recipe = first_code_block($cookbook,
        '=head2 Streaming Response Formats');
    perl_script_runs(
        'streaming response formats recipe',
        $recipe
            . "use PAGI::Test::Client;\n"
            . "my \$res = PAGI::Test::Client->new(app => \$response->to_app)->get('/');\n"
            . "die 'expected two TSV rows' unless \$res->content eq qq|id\\tname\\n1\\tAda\\n|;\n"
            . "die 'expected the TSV type' unless \$res->header('Content-Type') eq 'text/tab-separated-values; charset=utf-8';\n"
            . "local \$SIG{__WARN__} = sub { die \"warned: \$_[0]\" };\n"
            . "die 'expected an undef field to be empty' unless \$response->format_item(['a', undef]) eq qq|a\\t\\n|;\n",
    );
};

subtest 'Thrown pages recipe executes as published' => sub {
    my $recipe = code_block_containing($cookbook,
        '=head3 Thrown pages and house-styled errors', "middleware('ErrorHandler'");
    my $miss = code_block_containing($cookbook,
        '=head3 Thrown pages and house-styled errors', 'http_default');
    perl_script_runs(
        'thrown pages recipe',
        "use PAGI::Compose qw(compose);\nuse PAGI::Routing qw(middleware route);\n"
            . "use PAGI::Exception::HTTP;\nuse PAGI::Test::Client;\n"
            . "my \$psgi_called = 0;\n"
            . "{ package Local::PlackStyle; sub new { bless {}, \$_[0] } sub to_app { \$psgi_called++; sub { [200, [], ['psgi']] } } }\n"
            . "my \$errors = do {\n" . $recipe . "};\n"
            . "my \$app = compose(middleware => [\$errors], routes => [\n"
            . "    route('/plack' => sub { die Local::PlackStyle->new }),\n"
            . "    route('/page' => sub { die response('Text', 'down', status => 503) }),\n"
            . "    route('/fact' => sub { die PAGI::Exception::HTTP->new(404, 'nope') }),\n"
            . "],\n" . $miss . ");\n"
            . "local \$SIG{__WARN__} = sub {};\n"
            . "my \$client = PAGI::Test::Client->new(app => \$app);\n"
            . "my \$res = \$client->get('/plack');\n"
            . "die 'plack-style: expected the stock 500' unless \$res->status == 500;\n"
            . "die 'plack-style: its PSGI to_app ran as a PAGI app' if \$psgi_called;\n"
            . "\$res = \$client->get('/page');\n"
            . "die 'a 503 page answers as thrown' unless \$res->status == 503 && \$res->text eq 'down';\n"
            . "\$res = \$client->get('/fact');\n"
            . "die 'a fact gets the house style' unless \$res->status == 404 && \$res->json->{error} eq 'nope';\n"
            . "\$res = \$client->post('/fact');\n"
            . "die 'a wrong method gets the house style and keeps Allow' unless \$res->status == 405\n"
            . "    && \$res->json->{error} eq 'Method Not Allowed' && (\$res->header('Allow') // '') eq 'GET, HEAD';\n"
            . "\$res = \$client->get('/nope');\n"
            . "die 'a routing miss gets it from http_default' unless \$res->status == 404 && \$res->json->{error} eq 'Not Found';\n",
    );
};

subtest 'Watching or changing the request body recipe executes as published' => sub {
    my $recipe = first_code_block($cookbook, '=head2 Watching or changing the request body');
    my $checks = <<'PERL';
use IO::Compress::Gzip qw(gzip);
use PAGI::Test::Client;
my @logged;
local $SIG{__WARN__} = sub { push @logged, @_ };
my $client = PAGI::Test::Client->new(app => $app);
my $text = "hello, " x 1000;
gzip(\$text => \my $packed) or die 'gzip failed';
my $res = $client->post('/echo', body => $packed, headers => { 'Content-Encoding' => 'gzip' });
die 'gzip: got ' . $res->status . ' ' . substr($res->text, 0, 60) . "\n"
    unless $res->status == 200 && $res->text eq "identity: $text";
die "logged: @logged" unless "@logged" eq 'request body: ' . length($text) . " bytes\n";
@logged = ();
$res = $client->post('/echo', body => 'plain');
die 'plain: got ' . $res->text . "\n" unless $res->text eq 'identity: plain';
$res = $client->post('/echo', body => 'not gzip', headers => { 'Content-Encoding' => 'gzip' });
die 'bad gzip: got ' . $res->status . "\n" unless $res->status == 400;
my $bomb_text = 'x' x (11 * 1024 * 1024);
gzip(\$bomb_text => \my $bomb) or die 'gzip failed';
die 'the bomb is not small: ' . length($bomb) . "\n" unless length($bomb) < 64 * 1024;
$res = $client->post('/echo', body => $bomb, headers => { 'Content-Encoding' => 'gzip' });
die 'bomb: got ' . $res->status . "\n" unless $res->status == 413;
PERL
    perl_script_runs('Watching or changing the request body recipe', $recipe . $checks);
};

subtest 'CSRF on a streamed upload recipe executes as published' => sub {
    my $recipe = first_code_block($cookbook, '=head2 CSRF on a streamed upload');
    my $checks = <<'PERL';
use PAGI::Test::Client;
my $client = PAGI::Test::Client->new(app => $app);
my ($token) = $client->get('/notes')->text =~ /name="csrf_token" value="([^"]+)"/;
die 'no token on the page' unless $token;
my $boundary = 'XyZ';
my %multipart = ('Content-Type' => "multipart/form-data; boundary=$boundary");
sub part {
    my ($name, $content, $is_file) = @_;
    return ("--$boundary",
        qq{Content-Disposition: form-data; name="$name"} . ($is_file ? q{; filename="a.bin"} : ''),
        ($is_file ? ('Content-Type: application/octet-stream') : ()), '', $content);
}
sub multipart_body { join "\r\n", @_, "--$boundary--", '' }
my $file = 'x' x 5000;
my @cases = (
    ['script, right header, file first', 200,
        multipart_body(part(file => $file, 1)), { %multipart, 'X-CSRF-Token' => $token }],
    ['script, wrong header, file first', 403,
        multipart_body(part(file => $file, 1)), { %multipart, 'X-CSRF-Token' => 'forged' }],
    ['form, token first', 200,
        multipart_body(part(csrf_token => $token), part(file => $file, 1)), \%multipart],
    ['form, token after the file', 403,
        multipart_body(part(file => $file, 1), part(csrf_token => $token)), \%multipart],
    ['form, no token', 403,
        multipart_body(part(file => $file, 1)), \%multipart],
    ['form, token first, cross-site', 403,
        multipart_body(part(csrf_token => $token), part(file => $file, 1)), { %multipart, 'Sec-Fetch-Site' => 'cross-site' }],
    ['wrong header, right token field first', 403,
        multipart_body(part(csrf_token => $token), part(file => $file, 1)), { %multipart, 'X-CSRF-Token' => 'forged' }],
);
for my $case (@cases) {
    my ($label, $want, $body, $headers) = @$case;
    my $res = $client->post('/upload', body => $body, headers => $headers);
    die "$label: expected $want, got " . $res->status . ' ' . $res->text . "\n" unless $res->status == $want;
    die "$label: expected the stored size\n" if $want == 200 && $res->text ne 'Stored 5000 bytes';
}
PERL
    perl_script_runs('CSRF on a streamed upload recipe', $recipe . $checks);
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

subtest 'Company Collection recipe builds its class by name' => sub {
    my $heading = '=head2 Company Collection JSON Response';
    my $class_source = first_code_block($cookbook, $heading);
    my $usage = code_block_containing($cookbook, $heading, 'sub list_people');
    unlike $class_source, qr/Exporter|EXPORT_OK|collection_response/,
        'the Response class exports no factory of its own';
    like $usage, qr/response\('\+MyCompany::Response::Collection',/,
        'the route builds it with response() and a leading +';

    SKIP: {
        my $needed = perl_needed($class_source . $usage);
        skip "the recipe is written for Perl $needed", 4 if $needed;

        require PAGI::Test::Client;
        my $lib = tempdir(CLEANUP => 1);
        mkdir "$lib/MyCompany";
        mkdir "$lib/MyCompany/Response";
        open my $out, '>', "$lib/MyCompany/Response/Collection.pm" or die $!;
        print {$out} $class_source;
        close $out;
        local @INC = ($lib, @INC);

        my $routing = eval "package CollectionRecipe; sub load_people { [{ name => 'Ada' }] }\n$usage\n\$routing";
        ok $routing, 'the recipe runs as published' or diag $@;
        my $res = PAGI::Test::Client->new(app => $routing)->get('/people');
        is $res->status, 200, 'the route answers';
        is $res->json, { data => [{ name => 'Ada' }], meta => { total => 1, page => 1, count => 1 },
            links => { self => '/people' } }, 'with the company envelope';
        is $res->header('X-Collection-Version'), '1', 'and its header';
    }
};

unlike $cookbook,
    qr/PAGI::(?:App|Endpoint)::Router|\b(?:App|Endpoint) Router\b|->to_router|middleware_as|app_as/,
    'Cookbook contains no removed frontend syntax';

done_testing;
