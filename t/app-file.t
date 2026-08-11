use strict;
use warnings;
use Test2::V0;
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

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

done_testing;
