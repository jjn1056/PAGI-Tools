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
my $file_component = TestApps::AppFile::One->files;
my $client = PAGI::Test::Client->new(app => $file_component);

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

subtest 'only exact request-time development mode logs' => sub {
    for my $mode (undef, '', 'production', 'none', 'Development') {
        local $ENV{PAGI_ENV};
        defined $mode ? ($ENV{PAGI_ENV} = $mode) : delete $ENV{PAGI_ENV};
        my ($response, $stdout, $stderr) = capture_output(sub {
            return $client->get('/marker.txt');
        });
        is($response->status, 200, "request succeeds for mode " . ($mode // 'unset'));
        is($stdout, '', "STDOUT is silent for mode " . ($mode // 'unset'));
        is($stderr, '', "STDERR is silent for mode " . ($mode // 'unset'));
    }
};

subtest 'requests rejected before filesystem service stay silent' => sub {
    local $ENV{PAGI_ENV} = 'development';
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
        is($events->[0]{status}, $status, "$label keeps its response status");
        is($stdout, '', "$label produces no file-attempt output");
    }
};

subtest 'diagnostic escapes controls without changing the native candidate' => sub {
    local $ENV{PAGI_ENV} = 'development';
    my $path = "/bad\nname";
    my ($events, $stdout, $stderr) = capture_output(sub {
        return run_native($file_component, 'GET', $path);
    });

    is($events->[0]{status}, 404, 'control-bearing missing path stays a 404');
    is($stdout, 'PAGI::App::File: attempting '
        . File::Spec->catfile($one_static, 'bad') . '\\x0Aname' . "\n",
        'newline is visible text inside one physical record');
    is($stderr, '', 'escaped diagnostic remains STDOUT-only');
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
