use strict;
use warnings;
use Test2::V0;
use Cwd qw(getcwd);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

use lib 'lib';
use lib "$Bin/lib";
use lib "$Bin/app-path-fixtures/blib/lib";
use PAGI::Utils qw(app_path);
use TestApps::AppPath::Root ();
use TestApps::AppPath::BlibRoot ();

sub canonical {
    return File::Spec->canonpath(File::Spec->rel2abs($_[0]));
}

{
    package Local::ScriptStylePath;
    sub home  { return PAGI::Utils::app_path() }
    sub child { shift; return PAGI::Utils::app_path(@_) }
}

subtest 'PAGI_HOME has first precedence and may be relative' => sub {
    my $absolute = tempdir(CLEANUP => 1);
    {
        local $ENV{PAGI_HOME} = $absolute;
        is(app_path(), canonical($absolute), 'absolute override is canonical');
        is(app_path('static', 'app.css'),
            File::Spec->canonpath(File::Spec->catfile(
                canonical($absolute), 'static', 'app.css')),
            'override uses platform-aware component joining');
    }

    {
        local $ENV{PAGI_HOME} = File::Spec->catdir('relative', 'application');
        is(app_path(), canonical(File::Spec->catdir('relative', 'application')),
            'relative override is anchored at the current working directory');
    }
};

subtest 'module and script conventions select the intended home' => sub {
    local $ENV{PAGI_HOME};
    delete $ENV{PAGI_HOME};

    is(TestApps::AppPath::Root->home, canonical($Bin),
        't/lib package strips its complete package suffix and lib');
    is(TestApps::AppPath::BlibRoot->home,
        canonical(File::Spec->catdir($Bin, 'app-path-fixtures')),
        'blib/lib package strips lib and then blib');
    is(Local::ScriptStylePath->home, canonical($Bin),
        'nonmatching script package falls back to the source directory');

    local $ENV{PAGI_HOME} = '';
    is(Local::ScriptStylePath->home, canonical($Bin),
        'empty PAGI_HOME is treated as unset');
};

subtest 'relative module sources retain their load-time origin after chdir' => sub {
    my $other_directory = tempdir(CLEANUP => 1);
    open my $child, '-|', $^X, '-Ilib', '-It/lib',
        '-MTestApps::AppPath::Root', '-e',
        'chdir shift @ARGV or die $!; print TestApps::AppPath::Root->home',
        $other_directory
        or die "cannot start child perl: $!";
    my $home = do { local $/; <$child> };
    close $child;

    is($?, 0, 'child process completed successfully');
    is($home, canonical($Bin),
        'conventional module home does not move with the current directory');
};

subtest 'no arguments and child components return plain absolute strings' => sub {
    local $ENV{PAGI_HOME};
    delete $ENV{PAGI_HOME};

    my $home = Local::ScriptStylePath->home;
    ok(!ref($home), 'home is an ordinary string');
    ok(File::Spec->file_name_is_absolute($home), 'home is absolute');
    is(Local::ScriptStylePath->child('static', 'images', 'logo.svg'),
        File::Spec->canonpath(File::Spec->catfile(
            canonical($Bin), 'static', 'images', 'logo.svg')),
        'logical components use the native File::Spec representation');
    is(Local::ScriptStylePath->child('static', '..', 'templates'),
        File::Spec->canonpath(File::Spec->catfile(
            canonical($Bin), 'static', '..', 'templates')),
        '.. is accepted and follows native canonpath behavior');
};

subtest 'invalid child components croak at the public boundary' => sub {
    local $ENV{PAGI_HOME} = tempdir(CLEANUP => 1);
    my $absolute = File::Spec->catfile(File::Spec->rootdir, 'outside');

    for my $case (
        [undef, 'undefined'],
        ['', 'empty'],
        [{}, 'reference-valued'],
        [$absolute, 'absolute'],
    ) {
        my ($value, $label) = @$case;
        like(dies { app_path($value) }, qr/app_path.*component 1.*relative/i,
            "$label component is rejected clearly");
    }

    my $volume_candidate = File::Spec->catpath('X:', '', 'child');
    my ($volume) = File::Spec->splitpath($volume_candidate);
    if (length $volume) {
        like(dies { app_path($volume_candidate) },
            qr/app_path.*component 1.*volume/i,
            'a separately volumed component is rejected');
    } else {
        pass('native path grammar has no separate volume for the test candidate');
    }
};

subtest 'nonexistent paths are returned without side effects' => sub {
    my $home = tempdir(CLEANUP => 1);
    local $ENV{PAGI_HOME} = $home;
    my $missing = app_path('not-created', 'child');
    ok(!-e $missing, 'helper neither requires nor creates the child path');
};

subtest 'an unusable origin requires the explicit override' => sub {
    local $ENV{PAGI_HOME};
    delete $ENV{PAGI_HOME};
    like(dies {
        PAGI::Utils::_app_path_from_origin('Local::NoSource', undef)
    }, qr/app_path.*determine.*set PAGI_HOME/i,
        'missing source information gives explicit override guidance');

    local $ENV{PAGI_HOME} = tempdir(CLEANUP => 1);
    ok(File::Spec->file_name_is_absolute(
        PAGI::Utils::_app_path_from_origin('Local::NoSource', undef)
    ), 'PAGI_HOME takes precedence even when origin information is unusable');
};

subtest 'export surface is explicit and bundled' => sub {
    {
        package Local::DefaultPathImport;
        PAGI::Utils->import();
    }
    {
        package Local::AllPathImport;
        PAGI::Utils->import(':all');
    }
    ok(!Local::DefaultPathImport->can('app_path'), 'app_path is not default-exported');
    ok(Local::AllPathImport->can('app_path'), 'app_path is in the all bundle');
};

done_testing;
