use strict;
use warnings;
use Test2::V0;
use Cwd qw(getcwd);
use File::Spec;
use File::Temp qw(tempdir);

use lib 'lib';
use PAGI::Utils qw(path_from_root replace_path_prefix);

{
    package Local::PathTagImport;
    PAGI::Utils->import(':path');
}

sub canonical {
    return File::Spec->canonpath(File::Spec->rel2abs($_[0]));
}

my $root = tempdir(CLEANUP => 1);
my $absolute_root = canonical($root);

subtest 'path_from_root validates request components and preserves intent' => sub {
    is(
        path_from_root($root, '/css/app.css'),
        File::Spec->catfile($absolute_root, 'css', 'app.css'),
        'ordinary request components are rooted with File::Spec',
    );

    is(
        path_from_root($root, ''),
        $absolute_root,
        'an empty request path names the root',
    );
    is(
        path_from_root($root, '/css//images\\logo.svg'),
        File::Spec->catfile($absolute_root, 'css', 'images', 'logo.svg'),
        'leading, repeated, and mixed separators are component separators',
    );
    is(
        path_from_root($root, '/css/./app.css'),
        File::Spec->catfile($absolute_root, 'css', 'app.css'),
        'current-directory components are ignored',
    );
    is(
        path_from_root($root, '/css/'),
        File::Spec->catfile(
            File::Spec->catfile($absolute_root, 'css'), File::Spec->curdir,
        ),
        'a final separator retains directory intent',
    );
    is(
        path_from_root($root, '/css/.'),
        File::Spec->catfile(
            File::Spec->catfile($absolute_root, 'css'), File::Spec->curdir,
        ),
        'a final current-directory component retains directory intent',
    );

    ok(!defined path_from_root($root, '/../secret'),
        'parent traversal is unsafe');
    ok(!defined path_from_root($root, '/a\\..\\secret'),
        'backslash traversal is unsafe on every platform');
    ok(!defined path_from_root($root, '/.../secret'),
        'longer all-dot components are unsafe');
    ok(!defined path_from_root($root, "/bad\0name"), 'NUL is unsafe');

    ok(defined path_from_root($root, '/.well-known/security.txt'),
        'the pure utility does not impose hidden-file policy');
};

subtest 'path_from_root rejects invalid programmer arguments' => sub {
    for my $case (
        [undef, 'undefined'],
        ['', 'empty'],
        [{}, 'reference-valued'],
    ) {
        my ($value, $label) = @$case;
        like(dies { path_from_root($value, '/child') },
            qr/path_from_root root.*defined.*nonempty.*string/i,
            "$label root croaks clearly");
    }

    for my $case (
        [undef, 'undefined'],
        [{}, 'reference-valued'],
    ) {
        my ($value, $label) = @$case;
        like(dies { path_from_root($root, $value) },
            qr/path_from_root request path.*defined.*string/i,
            "$label request path croaks clearly");
    }
};

subtest 'path_from_root keeps relative roots tied to the current directory' => sub {
    my $original = getcwd;
    my $other_directory = tempdir(CLEANUP => 1);
    my $relative_root = File::Spec->catdir('relative', 'root');

    is(
        path_from_root($relative_root, '/before.txt'),
        File::Spec->catfile(canonical($relative_root), 'before.txt'),
        'a relative root is made absolute from the original directory',
    );

    chdir $other_directory or die "cannot chdir to $other_directory: $!";
    is(
        path_from_root($relative_root, '/after.txt'),
        File::Spec->catfile(canonical($relative_root), 'after.txt'),
        'a relative root is made absolute from the changed directory',
    );
    chdir $original or die "cannot restore $original: $!";
};

subtest 'path_from_root never lets a platform-specific component reset the root' => sub {
    my $volume_component = 'C:';
    my ($volume) = File::Spec->splitpath($volume_component);
    if (defined $volume && length $volume) {
        ok(!defined path_from_root($root, "/$volume_component/child"),
            'a current-platform volume component is unsafe');
    } else {
        is(
            path_from_root($root, "/$volume_component/child"),
            File::Spec->catfile($absolute_root, $volume_component, 'child'),
            'a non-volume literal component remains beneath the root',
        );
    }

    my $absolute_component = File::Spec->catfile(File::Spec->rootdir, 'outside');
    if ($absolute_component !~ m{[\\/]}) {
        ok(!defined path_from_root($root, $absolute_component),
            'an unsplit current-platform absolute component is unsafe');
    } else {
        my @parts = grep { length } split m{[\\/]}, $absolute_component;
        if (defined $volume && length $volume) {
            pass('the platform volume row already proves reset prevention');
        } else {
            is(
                path_from_root($root, $absolute_component),
                File::Spec->catfile($absolute_root, @parts),
                'split absolute syntax remains beneath the root',
            );
        }
    }
};

subtest 'path exports are explicit and bundled' => sub {
    ok(Local::PathTagImport->can('app_path'), ':path exports app_path');
    ok(Local::PathTagImport->can('path_from_root'), ':path exports path_from_root');
    ok(Local::PathTagImport->can('replace_path_prefix'),
        ':path exports replace_path_prefix');
};

subtest 'replace_path_prefix maps only component-aware descendants' => sub {
    is(
        replace_path_prefix('/var/www/files/report.pdf',
            '/var/www/files', '/protected'),
        '/protected/report.pdf',
        'descendant suffix is appended in the replacement namespace',
    );
    is(
        replace_path_prefix('/var/www/files', '/var/www/files', '/protected'),
        '/protected',
        'exact prefix maps without a synthetic trailing component',
    );
    ok(!defined replace_path_prefix('/var/www/files-old/report.pdf',
        '/var/www/files', '/protected'),
        'a textual prefix outside a component boundary does not match');
    is(
        replace_path_prefix('relative/path', 'relative', '/protected'),
        '/protected/path',
        'relative path and source are compared from the same current directory',
    );
    is(
        replace_path_prefix('/var/www/files/report.pdf',
            '/var/www/files', '/protected/'),
        '/protected/report.pdf',
        'a trailing replacement separator does not double the join',
    );

    my $case_result = replace_path_prefix('/VAR/WWW/FILES/report.pdf',
        '/var/www/files', '/protected');
    if (File::Spec->case_tolerant) {
        is($case_result, '/protected/report.pdf',
            'case-tolerant platforms compare source components case-insensitively');
    } else {
        ok(!defined $case_result,
            'case-sensitive platforms do not match differently cased components');
    }
};

subtest 'replace_path_prefix rejects invalid programmer arguments' => sub {
    for my $argument (
        [0, undef, 'undefined'],
        [1, '', 'empty'],
        [2, {}, 'reference-valued'],
    ) {
        my ($index, $value, $label) = @$argument;
        my @arguments = ('/var/www/files/report.pdf', '/var/www/files', '/protected');
        $arguments[$index] = $value;
        like(dies { replace_path_prefix(@arguments) },
            qr/replace_path_prefix.*defined.*nonempty.*string/i,
            "$label argument croaks clearly");
    }
};

done_testing;
