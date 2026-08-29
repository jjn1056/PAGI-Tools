use strict;
use warnings;
use Test2::V0;
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use Future;
use Cwd ();

use lib 'lib';
use lib "$Bin/app-file-fixtures/one/lib";
use lib "$Bin/app-file-fixtures/two/lib";
use PAGI::App::File;
use PAGI::Test::Client;
use TestApps::AppFile::One ();
use TestApps::AppFile::Two ();

{
    package Local::AppFileSubclass;
    use parent 'PAGI::App::File';
}

sub fetched_text {
    my ($component, $path) = @_;
    local $ENV{PAGI_ENV} = 'production';
    return PAGI::Test::Client->new(app => $component)->get($path)->text;
}

sub capture_output {
    my ($code) = @_;
    my ($stdout, $stderr) = ('', '');
    my $value;
    {
        local *STDOUT;
        local *STDERR;
        open STDOUT, '>', \$stdout or die "cannot capture STDOUT: $!";
        open STDERR, '>', \$stderr or die "cannot capture STDERR: $!";
        $value = $code->();
    }
    return ($value, $stdout, $stderr);
}

sub run_native {
    my ($component, $method, $path, $headers) = @_;
    my @events;
    $component->to_app->(
        {
            type => 'http', method => $method, path => $path,
            raw_path => $path, root_path => '', headers => $headers // [],
            path_params => {},
        },
        sub { return Future->done({ type => 'http.disconnect' }) },
        sub { push @events, $_[0]; return Future->done },
    )->get;
    return \@events;
}

sub event_header {
    my ($event, $name) = @_;
    for my $header (@{$event->{headers} // []}) {
        return $header->[1] if lc($header->[0]) eq lc($name);
    }
    return;
}

sub assert_head_parity {
    my ($component, $path, $headers, $label) = @_;
    my $get = run_native($component, 'GET', $path, $headers);
    my $head = run_native($component, 'HEAD', $path, $headers);

    is($head->[0], $get->[0], "$label HEAD preserves GET status and headers");
    is($head->[1], {
        type => 'http.response.body', body => '', more => 0,
    }, "$label HEAD emits one terminal empty body event");
    is(scalar(@$head), 2, "$label HEAD emits no body or file bytes");
    return;
}

subtest 'stock file errors negotiate through Pages without changing file outcomes' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $file = File::Spec->catfile($root, 'sample.txt');
    open my $fh, '>', $file or die "cannot create $file: $!";
    print {$fh} '0123456789';
    close $fh or die "cannot close $file: $!";

    my $empty_dir = File::Spec->catdir($root, 'empty');
    mkdir $empty_dir or die "cannot create $empty_dir: $!";

    my $component = PAGI::App::File->new(root => $root);
    my $client = PAGI::Test::Client->new(
        app => $component,
        raise_app_exceptions => 1,
    );

    my $missing = $client->get('/private/missing.txt',
        headers => { Accept => 'application/problem+json' });
    is($missing->status, 404, 'missing file keeps its status');
    is($missing->content_type, 'application/problem+json',
        'missing file negotiates a problem response');
    is($missing->json, {
        type   => 'about:blank',
        title  => 'Not Found',
        status => 404,
        detail => 'The requested resource was not found.',
    }, 'missing file uses the safe stock problem body');
    unlike($missing->content, qr/private|missing\.txt|\Q$root\E/,
        'missing response does not disclose the request or filesystem path');
    is($missing->header('Cache-Control'), 'no-store',
        'missing response is not stored');
    is($missing->header('Vary'), 'Accept',
        'missing response records negotiation');

    my $method = $client->post('/sample.txt',
        headers => { Accept => 'application/problem+json' });
    is($method->status, 405, 'unsupported method keeps its status');
    is($method->header('Allow'), 'GET, HEAD',
        'unsupported method advertises the exact supported methods');

    my $range = $client->get('/sample.txt', headers => {
        Accept => 'application/problem+json', Range => 'bytes=20-30',
    });
    is($range->status, 416, 'invalid range keeps its status');
    is($range->header('Content-Range'), 'bytes */10',
        'invalid range reports the known representation length');

    my $bad = $client->get("/bad\0name",
        headers => { Accept => 'text/plain' });
    is($bad->status, 403, 'null byte is forbidden by request-path policy');
    is($bad->content_type, 'text/plain; charset=utf-8',
        'null-byte rejection can negotiate stock text');
    like($bad->text, qr/^403 Forbidden\n/,
        'text response identifies the stock status safely');
    unlike($bad->text, qr/bad|name|\Q$root\E/,
        'null-byte response does not disclose request or filesystem paths');

    my $forbidden = $client->get('/.secret',
        headers => { Accept => 'text/html' });
    is($forbidden->status, 403, 'hidden component keeps its forbidden status');
    is($forbidden->content_type, 'text/html; charset=utf-8',
        'forbidden response can negotiate stock HTML');
    like($forbidden->text, qr/<title>403 Forbidden<\/title>/,
        'HTML response identifies the stock status');
    unlike($forbidden->text, qr/\.secret|\Q$root\E/,
        'HTML response does not disclose the hidden or filesystem path');

    my $full = $client->get('/sample.txt');
    is($full->status, 200, 'full file request still succeeds');
    is($full->content, '0123456789', 'full file bytes are unchanged');
    is($full->content_length, 10, 'full file length is unchanged');

    my $head = $client->head('/sample.txt');
    is($head->status, 200, 'HEAD still succeeds');
    is($head->content, '', 'HEAD still has no body');
    is($head->content_length, 10, 'HEAD retains representation length');

    my $partial = $client->get('/sample.txt',
        headers => { Range => 'bytes=2-5' });
    is($partial->status, 206, 'valid range still succeeds');
    is($partial->content, '2345', 'valid range bytes are unchanged');
    is($partial->header('Content-Range'), 'bytes 2-5/10',
        'valid range metadata is unchanged');

    my $cached = $client->get('/sample.txt',
        headers => { 'If-None-Match' => $full->header('ETag') });
    is($cached->status, 304, 'matching ETag still produces 304');
    is($cached->content, '', '304 remains bodyless');

    assert_head_parity($component, '/sample.txt', [], 'full file');
    assert_head_parity($component, '/private/missing.txt', [
        ['accept', 'application/problem+json'],
    ], 'missing file');
    assert_head_parity($component, '/empty', [], 'indexless directory');
    assert_head_parity($component, '/.secret', [
        ['accept', 'text/html'],
    ], 'forbidden path');
    assert_head_parity($component, '/sample.txt', [
        ['accept', 'application/problem+json'], ['range', 'bytes=20-30'],
    ], 'invalid range');
    assert_head_parity($component, '/sample.txt', [
        ['range', 'bytes=2-5'],
    ], 'partial file');
    assert_head_parity($component, '/sample.txt', [
        ['if-none-match', $full->header('ETag')],
    ], 'not-modified file');
};

subtest 'single byte ranges have strict grammar and exact suffix semantics' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $file = File::Spec->catfile($root, 'sample.txt');
    open my $fh, '>', $file or die "cannot create $file: $!";
    print {$fh} '0123456789';
    close $fh or die "cannot close $file: $!";

    my $component = PAGI::App::File->new(root => $root);
    my $client = PAGI::Test::Client->new(
        app => $component, raise_app_exceptions => 1,
    );

    for my $case (
        ['bytes=-5',  '56789',      'bytes 5-9/10', 5],
        ['bytes=-99', '0123456789', 'bytes 0-9/10', 10],
        ['bytes=3-',  '3456789',    'bytes 3-9/10', 7],
        ['bytes=3-99','3456789',    'bytes 3-9/10', 7],
    ) {
        my ($range, $content, $content_range, $length) = @$case;
        my $response = $client->get('/sample.txt', headers => {
            Range => $range,
        });
        is($response->status, 206, "$range is one satisfiable byte range");
        is($response->content, $content, "$range selects the exact bytes");
        is($response->header('Content-Range'), $content_range,
            "$range reports the exact normalized interval");
        is($response->content_length, $length,
            "$range reports the exact selected length");
    }

    my $suffix_events = run_native(
        $component, 'GET', '/sample.txt', [['range', 'bytes=-5']],
    );
    is($suffix_events->[1]{offset}, 5,
        'suffix range delegates the exact server file offset');
    is($suffix_events->[1]{length}, 5,
        'suffix range delegates the exact server file length');

    for my $range (
        'bytes=-0', 'bytes=-', 'bytes=', 'bytes=0-1,8-9',
        'junkbytes=0-1', 'bytes=7-3', 'bytes=10-', 'bytes= 0-1',
    ) {
        my $response = $client->get('/sample.txt', headers => {
            Range => $range,
        });
        is($response->status, 416, "$range is rejected rather than guessed");
        is($response->header('Content-Range'), 'bytes */10',
            "$range rejection reports the representation length");
    }

    for my $case (
        ['empty Range field', [['range', '']]],
        ['Unicode digits', [['range', "bytes=\x{0661}-\x{0662}"]]],
        ['repeated Range fields', [
            ['range', 'bytes=0-1'], ['range', 'bytes=8-9'],
        ]],
    ) {
        my ($label, $headers) = @$case;
        my $events = run_native($component, 'GET', '/sample.txt', $headers);
        is($events->[0]{status}, 416, "$label is rejected as malformed");
        is(
            event_header($events->[0], 'content-range'),
            'bytes */10',
            "$label rejection reports the representation length",
        );
        assert_head_parity($component, '/sample.txt', $headers, $label);
    }
};

subtest 'File preserves the complete shared MIME table' => sub {
    my $root = tempdir(CLEANUP => 1);
    my %types = (
        csv => 'text/csv',
        gz  => 'application/gzip',
        tar => 'application/x-tar',
        eot => 'application/vnd.ms-fontobject',
        otf => 'font/otf',
        ogg => 'audio/ogg',
        wav => 'audio/wav',
    );
    for my $extension (keys %types) {
        my $path = File::Spec->catfile($root, "sample.$extension");
        open my $fh, '>', $path or die "cannot create $path: $!";
        print {$fh} $extension;
        close $fh or die "cannot close $path: $!";
    }
    my $unknown = File::Spec->catfile($root, 'sample.unknown');
    open my $unknown_fh, '>', $unknown or die "cannot create $unknown: $!";
    print {$unknown_fh} 'unknown';
    close $unknown_fh or die "cannot close $unknown: $!";

    my $client = PAGI::Test::Client->new(
        app => PAGI::App::File->new(root => $root),
        raise_app_exceptions => 1,
    );
    for my $extension (sort keys %types) {
        is($client->get("/sample.$extension")->content_type,
            $types{$extension}, ".$extension retains its shared MIME type");
    }

    my $custom = PAGI::Test::Client->new(
        app => PAGI::App::File->new(
            root => $root, default_type => 'application/x-example',
        ),
        raise_app_exceptions => 1,
    );
    is($custom->get('/sample.unknown')->content_type,
        'application/x-example',
        'App::File retains its configured unknown-suffix MIME fallback');
};

subtest 'from_app_path returns a serving component and preserves subclasses' => sub {
    my $home = File::Spec->catdir($Bin, 'app-file-fixtures', 'one');
    local $ENV{PAGI_HOME} = $home;

    my $files = PAGI::App::File->from_app_path('static');
    isa_ok($files, 'PAGI::App::File');
    is(fetched_text($files, '/marker.txt'), "caller one\n",
        'one path component resolves into a serving file root');

    my $nested = PAGI::App::File->from_app_path('static', 'nested');
    is(fetched_text($nested, '/marker.txt'), "caller one nested\n",
        'multiple path components resolve into a serving file root');

    my $whole_home = PAGI::App::File->from_app_path();
    is(fetched_text($whole_home, '/static/marker.txt'), "caller one\n",
        'no path components serve application home');

    my $subclass = Local::AppFileSubclass->from_app_path('static');
    isa_ok($subclass, 'Local::AppFileSubclass');

    like(dies { PAGI::App::File::from_app_path($files, 'other') },
        qr/from_app_path.*class constructor/i,
        'object invocation is rejected before path resolution');
    like(dies { PAGI::App::File::from_app_path([], 'other') },
        qr/from_app_path.*class constructor/i,
        'unblessed reference invocation is rejected');
    ok(!PAGI::App::File->can('app_path'),
        'the unreleased ambiguous class constructor has no alias');
    is(PAGI::Utils::app_path('static'),
        File::Spec->canonpath(File::Spec->catfile($home, 'static')),
        'the Utils app_path function remains a path-string utility');
};

subtest 'component validation is the shared Utils contract' => sub {
    local $ENV{PAGI_HOME} = File::Spec->catdir($Bin, 'app-file-fixtures', 'one');
    like(dies { PAGI::App::File->from_app_path({}) },
        qr/app_path.*component 1.*relative/i,
        'a reference-valued component retains the shared positional diagnostic');
    like(dies { PAGI::App::File->from_app_path('static', '') },
        qr/app_path.*component 2.*relative/i,
        'a later invalid component reports its shared position');
};

subtest 'ordinary use sites retain independent caller origins' => sub {
    local $ENV{PAGI_HOME};
    delete $ENV{PAGI_HOME};

    is(fetched_text(TestApps::AppFile::One->files, '/marker.txt'), "caller one\n",
        'first caller serves its own application root');
    is(fetched_text(TestApps::AppFile::Two->files, '/marker.txt'), "caller two\n",
        'second caller serves its own application root');
};

subtest 'root-level test script uses script fallback' => sub {
    local $ENV{PAGI_HOME};
    delete $ENV{PAGI_HOME};
    my $files = PAGI::App::File->from_app_path('app-file-script-static');
    is(fetched_text($files, '/marker.txt'), "script caller\n",
        'main package call resolves beside the test script');
};

subtest 'relative caller source is fixed before a later chdir' => sub {
    my $other = tempdir(CLEANUP => 1);
    local $ENV{PAGI_HOME};
    delete $ENV{PAGI_HOME};
    local $ENV{PAGI_ENV} = 'production';
    open my $child, '-|', $^X,
        '-Ilib', '-It/app-file-fixtures/one/lib',
        '-MTestApps::AppFile::One', '-MPAGI::Test::Client', '-e',
        'chdir shift @ARGV or die $!; '
            . 'my $r = PAGI::Test::Client->new('
            . 'app => TestApps::AppFile::One->files)->get("/marker.txt"); '
            . 'print $r->text',
        $other
        or die "cannot start child perl: $!";
    my $output = do { local $/; <$child> };
    close $child;

    is($?, 0, 'child process completed');
    is($output, "caller one\n",
        'relative module source remains anchored at use time');
};

{
    package Local::IgnoredAppFileImport;
    PAGI::App::File->import('imaginary_export');
}
ok(!Local::IgnoredAppFileImport->can('imaginary_export'),
    'App::File import remains a no-export hook and ignores arguments');

my $one_static = Cwd::realpath(File::Spec->catdir(
    $Bin, 'app-file-fixtures', 'one', 'static',
));
my ($file_component, $client);
{
    local $ENV{PAGI_HOME};
    delete $ENV{PAGI_HOME};
    $file_component = TestApps::AppFile::One->files;
    $client = PAGI::Test::Client->new(
        app => $file_component,
        raise_app_exceptions => 1,
    );
}

subtest 'development logs final existing, missing, index, and HEAD candidates' => sub {
    local $ENV{PAGI_ENV} = 'development';

    my ($existing, $existing_out, $existing_err) = capture_output(sub {
        return $client->get('/marker.txt');
    });
    is($existing->status, 200, 'existing file still responds');
    is($existing->text, "caller one\n", 'existing body is unchanged');
    is($existing_out, 'PAGI::App::File: attempting '
        . File::Spec->catfile($one_static, 'marker.txt') . "\n",
        'existing file emits one exact STDOUT record');
    is($existing_err, '', 'diagnostic does not use STDERR');

    my ($missing, $missing_out) = capture_output(sub {
        return $client->get('/missing.txt');
    });
    is($missing->status, 404, 'missing response is unchanged');
    is($missing_out, 'PAGI::App::File: attempting '
        . File::Spec->catfile($one_static, 'missing.txt') . "\n",
        'missing candidate is visible');

    my ($index, $index_out) = capture_output(sub { return $client->get('/') });
    is($index->status, 200, 'index still responds');
    is($index_out, 'PAGI::App::File: attempting '
        . File::Spec->catfile($one_static, 'index.html') . "\n",
        'directory request logs selected index');

    my ($empty, $empty_out) = capture_output(sub {
        return $client->get('/empty-dir');
    });
    is($empty->status, 404, 'directory without an index remains 404');
    is($empty_out, 'PAGI::App::File: attempting '
        . File::Spec->catdir($one_static, 'empty-dir') . "\n",
        'index-free directory logs its directory candidate');

    my ($head, $head_out) = capture_output(sub {
        return $client->head('/marker.txt');
    });
    is($head->status, 200, 'HEAD still responds');
    is($head_out, $existing_out, 'HEAD uses the same candidate diagnostic');
};

subtest 'supported nondevelopment modes stay silent at request time' => sub {
    for my $mode (undef, '', 'test', 'staging', 'production') {
        local $ENV{PAGI_ENV};
        defined $mode ? ($ENV{PAGI_ENV} = $mode) : delete $ENV{PAGI_ENV};
        my ($response, $stdout, $stderr) = capture_output(sub {
            return $client->get('/marker.txt');
        });
        my $label = defined $mode && length $mode ? $mode
            : defined $mode ? 'empty' : 'unset';
        is($response->status, 200, "request succeeds for $label");
        is($stdout, '', "STDOUT is silent for $label");
        is($stderr, '', "STDERR is silent for $label");
    }
};

subtest 'invalid environments fail when diagnostics are consulted' => sub {
    for my $mode ('Development', 'none') {
        local $ENV{PAGI_ENV} = $mode;
        like(
            dies { capture_output(sub { $client->get('/marker.txt') }) },
            qr/Invalid PAGI_ENV '\Q$mode\E'; expected one of: development, test, staging, production/,
            "invalid [$mode] fails loudly",
        );
    }
};

subtest 'requests rejected before filesystem service stay silent' => sub {
    for my $mode ('development', 'Development') {
        local $ENV{PAGI_ENV} = $mode;
        for my $case (
            ['POST', '/marker.txt', 405, 'unsupported method'],
            ['GET', "/bad\0name", 403, 'null byte'],
            ['GET', '/../secret', 403, 'traversal component'],
            ['GET', '/.env', 403, 'hidden component'],
        ) {
            my ($method, $path, $status, $label) = @$case;
            my ($events, $stdout) = capture_output(sub {
                return run_native($file_component, $method, $path);
            });
            is($events->[0]{status}, $status,
                "$label keeps its response status for $mode");
            is($stdout, '', "$label produces no file-attempt output for $mode");
        }
    }
};

subtest 'development diagnostics use the shared environment predicate' => sub {
    open my $source, '<', 'lib/PAGI/App/File.pm'
        or die "cannot read App::File source: $!";
    my $contents = do { local $/; <$source> };
    close $source or die "cannot close App::File source: $!";

    like($contents, qr/PAGI::Utils::is_development\(\)/,
        'uses the fully-qualified development predicate');
    unlike($contents, qr/\$ENV\{PAGI_ENV\}/,
        'does not read PAGI_ENV directly');
};

subtest 'diagnostic escapes every accepted ASCII control byte' => sub {
    local $ENV{PAGI_ENV} = 'development';
    my @cases = (
        [0x01, '\\x01'], [0x02, '\\x02'], [0x03, '\\x03'],
        [0x04, '\\x04'], [0x05, '\\x05'], [0x06, '\\x06'],
        [0x07, '\\x07'], [0x08, '\\x08'], [0x09, '\\x09'],
        [0x0a, '\\x0A'], [0x0b, '\\x0B'], [0x0c, '\\x0C'],
        [0x0d, '\\x0D'], [0x0e, '\\x0E'], [0x0f, '\\x0F'],
        [0x10, '\\x10'], [0x11, '\\x11'], [0x12, '\\x12'],
        [0x13, '\\x13'], [0x14, '\\x14'], [0x15, '\\x15'],
        [0x16, '\\x16'], [0x17, '\\x17'], [0x18, '\\x18'],
        [0x19, '\\x19'], [0x1a, '\\x1A'], [0x1b, '\\x1B'],
        [0x1c, '\\x1C'], [0x1d, '\\x1D'], [0x1e, '\\x1E'],
        [0x1f, '\\x1F'], [0x7f, '\\x7F'],
    );

    for my $case (@cases) {
        my ($ordinal, $escaped) = @$case;
        my $path = '/bad' . chr($ordinal) . 'name';
        my ($events, $stdout, $stderr) = capture_output(sub {
            return run_native($file_component, 'GET', $path);
        });

        is($events->[0]{status}, 404,
            sprintf('0x%02X-bearing missing path stays a 404', $ordinal));
        is($stdout, 'PAGI::App::File: attempting '
            . File::Spec->catfile($one_static, 'bad') . $escaped . "name\n",
            sprintf('0x%02X is escaped inside one physical record', $ordinal));
        is($stderr, '', sprintf('0x%02X diagnostic remains STDOUT-only', $ordinal));
    }
};

subtest 'trusted outward symlink serves through its in-root lexical candidate' => sub {
    my $sandbox = tempdir(CLEANUP => 1);
    my $root = File::Spec->catdir($sandbox, 'root');
    mkdir $root or die "cannot create test root $root: $!";

    my $outside = File::Spec->catfile($sandbox, 'external-secret.txt');
    open my $external_file, '>', $outside
        or die "cannot create external target $outside: $!";
    print {$external_file} "external secret\n";
    close $external_file or die "cannot close external target $outside: $!";

    my $link = File::Spec->catfile($root, 'escape.txt');
    my $linked = eval { symlink($outside, $link) };
    unless ($linked) {
        my $reason = $@ || $! || 'symlink creation returned false';
        plan skip_all => "symlink creation unavailable: $reason";
    }

    my $component = PAGI::App::File->new(root => $root);
    local $ENV{PAGI_ENV} = 'development';
    my $client = PAGI::Test::Client->new(
        app => $component, raise_app_exceptions => 1,
    );
    my ($response, $stdout, $stderr) = capture_output(sub {
        return $client->get('/escape.txt');
    });
    my $lexical = File::Spec->catfile(
        File::Spec->canonpath(File::Spec->rel2abs($root)), 'escape.txt',
    );

    is($response->status, 200, 'trusted outward symlink is served');
    is($response->content, "external secret\n",
        'server opens and reads the trusted symlink target');
    is($stdout, "PAGI::App::File: attempting $lexical\n",
        'one record names the in-root lexical candidate');
    unlike($stdout, qr/\Q$outside\E/,
        'diagnostic does not disclose the resolved external target');
    is($stderr, '', 'symlink diagnostic remains STDOUT-only');
};

subtest 'development output does not rewrite a served file event' => sub {
    local $ENV{PAGI_ENV} = 'development';
    my ($events, $stdout) = capture_output(sub {
        return run_native($file_component, 'GET', '/marker.txt');
    });
    is($events->[1]{file}, File::Spec->catfile($one_static, 'marker.txt'),
        'server receives the original lexical candidate');
    is($stdout, 'PAGI::App::File: attempting '
        . File::Spec->catfile($one_static, 'marker.txt') . "\n",
        'native request emits the same one-line diagnostic');
};

done_testing;
