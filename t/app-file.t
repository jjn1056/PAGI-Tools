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
    my ($component, $method, $path) = @_;
    my @events;
    $component->to_app->(
        {
            type => 'http', method => $method, path => $path,
            raw_path => $path, root_path => '', headers => [],
            path_params => {},
        },
        sub { return Future->done({ type => 'http.disconnect' }) },
        sub { push @events, $_[0]; return Future->done },
    )->get;
    return \@events;
}

subtest 'class constructor returns a serving component and preserves subclasses' => sub {
    my $home = File::Spec->catdir($Bin, 'app-file-fixtures', 'one');
    local $ENV{PAGI_HOME} = $home;

    my $files = PAGI::App::File->app_path('static');
    isa_ok($files, 'PAGI::App::File');
    is(fetched_text($files, '/marker.txt'), "caller one\n",
        'one path component resolves into a serving file root');

    my $nested = PAGI::App::File->app_path('static', 'nested');
    is(fetched_text($nested, '/marker.txt'), "caller one nested\n",
        'multiple path components resolve into a serving file root');

    my $whole_home = PAGI::App::File->app_path();
    is(fetched_text($whole_home, '/static/marker.txt'), "caller one\n",
        'no path components serve application home');

    my $subclass = Local::AppFileSubclass->app_path('static');
    isa_ok($subclass, 'Local::AppFileSubclass');

    like(dies { PAGI::App::File::app_path($files, 'other') },
        qr/app_path.*class constructor/i,
        'object invocation is rejected before path resolution');
    like(dies { PAGI::App::File::app_path([], 'other') },
        qr/app_path.*class constructor/i,
        'unblessed reference invocation is rejected');
};

subtest 'component validation is the shared Utils contract' => sub {
    local $ENV{PAGI_HOME} = File::Spec->catdir($Bin, 'app-file-fixtures', 'one');
    like(dies { PAGI::App::File->app_path({}) },
        qr/app_path.*component 1.*relative/i,
        'a reference-valued component retains the shared positional diagnostic');
    like(dies { PAGI::App::File->app_path('static', '') },
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
    my $files = PAGI::App::File->app_path('app-file-script-static');
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
            ['GET', "/bad\0name", 400, 'null byte'],
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

subtest 'symlink rejection logs only the in-root lexical candidate' => sub {
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
    my ($events, $stdout, $stderr) = capture_output(sub {
        return run_native($component, 'GET', '/escape.txt');
    });
    my $lexical = File::Spec->catfile(Cwd::realpath($root), 'escape.txt');

    is($events->[0]{status}, 403, 'escaping symlink is rejected');
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
