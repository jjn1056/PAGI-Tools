use strict;
use warnings;
use Test2::V0;
use Cwd qw(getcwd);
use Errno qw(EACCES EIO ENOENT ENOTDIR EPERM);
use Fcntl qw(S_IFDIR S_IFREG);
use File::Spec;
use File::Temp qw(tempdir);
use Future;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::App::File;
use PAGI::App::File::Result;

sub write_file {
    my ($path, $contents) = @_;
    open my $file, '>', $path or die "cannot create $path: $!";
    print {$file} $contents;
    close $file or die "cannot close $path: $!";
    return;
}

sub stat_snapshot {
    my ($mode, $size, $mtime, $readable) = @_;
    my @stat = (0) x 13;
    $stat[2] = $mode;
    $stat[7] = $size;
    $stat[9] = $mtime;
    return { stat => \@stat, readable => $readable ? 1 : 0 };
}

{
    package Local::ProbeFile;
    use parent 'PAGI::App::File';

    sub new {
        my ($class, %args) = @_;
        my $probes = delete $args{probes};
        my $self = $class->SUPER::new(%args);
        $self->{_test_probes} = $probes;
        $self->{_test_probe_calls} = [];
        return $self;
    }

    sub _probe_path {
        my ($self, $path) = @_;
        push @{$self->{_test_probe_calls}}, $path;
        die "no simulated probe for $path"
            unless exists $self->{_test_probes}{$path};
        return $self->{_test_probes}{$path};
    }

    sub probe_calls {
        my ($self) = @_;
        return [@{$self->{_test_probe_calls}}];
    }

    sub probe_count {
        my ($self) = @_;
        return scalar @{$self->{_test_probe_calls}};
    }
}

{
    package Local::NotFileResult;
    sub new { return bless {}, shift }
}

sub http_scope {
    my (%overrides) = @_;
    return {
        type => 'http', method => 'GET', path => '/', headers => [],
        %overrides,
    };
}

sub event_header {
    my ($event, $name) = @_;
    for my $header (@{$event->{headers} // []}) {
        return $header->[1] if lc($header->[0]) eq lc($name);
    }
    return;
}

subtest 'Result is a validated read-only request value' => sub {
    my $result = PAGI::App::File::Result->new(
        kind => 'file', path => '/tmp/a', size => 10, mtime => 20,
    );

    is($result->kind, 'file', 'kind is retained');
    is($result->path, '/tmp/a', 'path is retained');
    is($result->size, 10, 'size is retained');
    is($result->mtime, 20, 'mtime is retained');
    ok($result->is_file, 'file predicate identifies the result');
    ok(!$result->is_directory, 'directory predicate rejects a file');
    ok(!$result->is_missing, 'missing predicate rejects a file');
    ok(!$result->is_forbidden, 'forbidden predicate rejects a file');

    for my $kind (qw(directory missing forbidden)) {
        my $other = PAGI::App::File::Result->new(
            kind => $kind, path => '/tmp/b',
        );
        ok($other->can("is_$kind")->($other), "$kind predicate is true");
        ok(!$other->is_file, "$kind result is not a file");
        ok(!defined $other->size, "$kind result has no file size");
        ok(!defined $other->mtime, "$kind result has no file mtime");
    }

    my $unsafe = PAGI::App::File::Result->new(
        kind => 'forbidden', path => undef,
    );
    ok(!defined $unsafe->path,
        'a forbidden result may have no constructible safe path');

    like(dies { PAGI::App::File::Result->new(kind => 'other') },
        qr/result kind.*file.*directory.*missing.*forbidden/i,
        'unknown result kind is rejected');
    like(dies { PAGI::App::File::Result->new() },
        qr/result kind/i, 'missing result kind is rejected');
    like(dies {
        PAGI::App::File::Result->new(
            kind => 'file', path => '/tmp/a', size => 10,
        );
    }, qr/file result.*mtime/i, 'file metadata must be complete');
    like(dies {
        PAGI::App::File::Result->new(
            kind => 'missing', path => [],
        );
    }, qr/result path.*string/i, 'reference paths are rejected');
    like(dies {
        PAGI::App::File::Result->new(
            kind => 'directory', path => '/tmp/a', size => 10,
        );
    }, qr/non-file result.*size.*mtime/i,
        'a non-file result rejects file size metadata');
    like(dies {
        PAGI::App::File::Result->new(
            kind => 'missing', path => '/tmp/a', mtime => 20,
        );
    }, qr/non-file result.*size.*mtime/i,
        'a non-file result rejects file mtime metadata');
    like(dies {
        PAGI::App::File::Result->new(kind => 'missing', extra => 1);
    }, qr/unknown result.*extra/i, 'unknown constructor keys are rejected');

    ok(!$result->can('set_kind'), 'no kind mutator is exposed');
    ok(!$result->can('set_path'), 'no path mutator is exposed');
    like(dies { $result->kind('missing') }, qr/read-only/i,
        'an accessor cannot be used as a mutator');
    is($result->kind, 'file', 'failed mutation leaves the value unchanged');
};

subtest 'File constructor validates and caches location configuration' => sub {
    like(dies { PAGI::App::File->new(root => undef) },
        qr/File root.*defined.*nonempty.*non-reference string/i,
        'an explicitly undefined root is rejected');
    like(dies { PAGI::App::File->new(root => '') },
        qr/File root.*defined.*nonempty.*non-reference string/i,
        'an empty root is rejected');
    like(dies { PAGI::App::File->new(root => []) },
        qr/File root.*defined.*nonempty.*non-reference string/i,
        'a reference root is rejected');
    like(dies { PAGI::App::File->new(index => 'index.html') },
        qr/File index.*array reference/i,
        'index configuration must be an array reference');
    like(dies { PAGI::App::File->new(index => [undef]) },
        qr/File index.*defined.*non-reference string/i,
        'undefined index names are rejected');
    like(dies { PAGI::App::File->new(index => [[]]) },
        qr/File index.*defined.*non-reference string/i,
        'reference index names are rejected');

    my $sandbox = tempdir(CLEANUP => 1);
    my $root = File::Spec->catdir($sandbox, 'relative-root');
    mkdir $root or die "cannot create $root: $!";
    write_file(File::Spec->catfile($root, 'cached.txt'), 'cache');
    my $elsewhere = tempdir(CLEANUP => 1);
    my $original = getcwd();
    my ($found, $expected_root, $error);

    eval {
        chdir $sandbox or die "cannot chdir to $sandbox: $!";
        $expected_root = File::Spec->canonpath(
            File::Spec->rel2abs('relative-root'),
        );
        my $files = PAGI::App::File->new(root => 'relative-root');
        chdir $elsewhere or die "cannot chdir to $elsewhere: $!";
        $found = $files->locate('/cached.txt');
        1;
    } or $error = $@;
    chdir $original or die "cannot restore working directory $original: $!";
    die $error if defined $error && length $error;

    ok($found->is_file, 'relative root still locates after a later chdir');
    is($found->path, File::Spec->catfile($expected_root, 'cached.txt'),
        'relative root is cached as a lexical absolute path');

    my $absent_root = File::Spec->catdir($sandbox, 'not-created');
    my $absent = PAGI::App::File->new(root => $absent_root);
    ok($absent->locate('/anything')->is_missing,
        'construction does not require the root to exist');
};

my $root = tempdir(CLEANUP => 1);
my $root_abs = File::Spec->canonpath(File::Spec->rel2abs($root));
write_file(File::Spec->catfile($root, 'plain.txt'), 'hello');
write_file(File::Spec->catfile($root, '.secret'), 'hidden');

my $empty_dir = File::Spec->catdir($root, 'empty-dir');
mkdir $empty_dir or die "cannot create $empty_dir: $!";

my $ordered_dir = File::Spec->catdir($root, 'ordered');
mkdir $ordered_dir or die "cannot create $ordered_dir: $!";
write_file(File::Spec->catfile($ordered_dir, 'first.htm'), 'first');
write_file(File::Spec->catfile($ordered_dir, 'second.htm'), 'second');

my $hidden_dir = File::Spec->catdir($root, 'hidden-index');
mkdir $hidden_dir or die "cannot create $hidden_dir: $!";
write_file(File::Spec->catfile($hidden_dir, '.index.html'), 'hidden index');
write_file(File::Spec->catfile($hidden_dir, 'visible.html'), 'visible index');

subtest 'locate classifies real files, directories, and request policy' => sub {
    my $files = PAGI::App::File->new(root => $root);
    my $found = $files->locate('/plain.txt');

    ok($found->is_file, 'a regular readable file is located');
    is($found->path, File::Spec->catfile($root_abs, 'plain.txt'),
        'located path remains lexical and rooted');
    is($found->size, 5, 'located file carries its probed size');
    ok(defined $found->mtime, 'located file carries its probed mtime');
    ok($files->locate('/missing.txt')->is_missing,
        'a missing name is classified missing');
    my $directory = $files->locate('/empty-dir');
    ok($directory->is_directory,
        'an indexless directory is classified directory');
    is($directory->path, $empty_dir,
        'directory result retains the original candidate');
    ok($files->locate('/plain.txt/')->is_missing,
        'directory intent does not resolve a regular file');
    ok($files->locate('/../secret')->is_forbidden,
        'unsafe traversal is forbidden');
    ok($files->locate("/bad\0name")->is_forbidden,
        'unsafe NUL input is forbidden');
    ok($files->locate('/.secret')->is_forbidden,
        'hidden files are forbidden by default');

    my $hidden = PAGI::App::File->new(root => $root, allow_hidden => 1);
    ok($hidden->locate('/.secret')->is_file,
        'allow_hidden permits a hidden request component');

    my $first = $files->locate('/plain.txt');
    my $second = $files->locate('/missing.txt');
    isnt(refaddr($first), refaddr($second),
        'each request receives an independent Result reference');
    ok($first->is_file, 'retained first result keeps its own kind');
    is($first->path, File::Spec->catfile($root_abs, 'plain.txt'),
        'retained first result keeps its own path');
    ok($second->is_missing, 'retained second result keeps its own kind');

    local $ENV{PAGI_ENV} = 'invalid-for-silent-policy-test';
    ok($files->locate('/../silent')->is_forbidden,
        'traversal rejection does not consult development diagnostics');
    ok($files->locate("/silent\0name")->is_forbidden,
        'NUL rejection does not consult development diagnostics');
    ok($files->locate('/.silent')->is_forbidden,
        'hidden rejection does not consult development diagnostics');
};

subtest 'indexes are selected in declaration order under hidden policy' => sub {
    my $ordered = PAGI::App::File->new(
        root => $root, index => ['second.htm', 'first.htm'],
    )->locate('/ordered');
    ok($ordered->is_file, 'an index candidate resolves the directory');
    is($ordered->path, File::Spec->catfile($ordered_dir, 'second.htm'),
        'the first declared regular index is selected');

    my $hidden_blocked = PAGI::App::File->new(
        root => $root, index => ['.index.html', 'visible.html'],
    )->locate('/hidden-index');
    is($hidden_blocked->path,
        File::Spec->catfile($hidden_dir, 'visible.html'),
        'a hidden index is skipped when hidden paths are disabled');

    my $hidden_allowed = PAGI::App::File->new(
        root => $root, allow_hidden => 1,
        index => ['.index.html', 'visible.html'],
    )->locate('/hidden-index');
    is($hidden_allowed->path,
        File::Spec->catfile($hidden_dir, '.index.html'),
        'allow_hidden makes the earlier hidden index eligible');

    my $hidden_only = PAGI::App::File->new(
        root => $root, index => ['.index.html'],
    )->locate('/hidden-index');
    ok($hidden_only->is_directory,
        'a directory remains a directory when only hidden indexes exist');
};

subtest 'non-regular filesystem objects are missing where supported' => sub {
    my $fifo = File::Spec->catfile($root, 'named-pipe');
    my $created = eval {
        require POSIX;
        POSIX::mkfifo($fifo, 0600) or die "mkfifo returned false: $!";
        1;
    };
    unless ($created) {
        my $reason = $@ || $! || 'mkfifo unavailable';
        plan skip_all => "cannot create a non-regular object: $reason";
    }
    ok(PAGI::App::File->new(root => $root)->locate('/named-pipe')->is_missing,
        'a non-regular non-directory object is classified missing');
};

subtest 'a genuinely unreadable regular file is forbidden where supported' => sub {
    my $path = File::Spec->catfile($root, 'unreadable.txt');
    write_file($path, 'private');
    unless (chmod 0000, $path) {
        plan skip_all => "cannot remove read permission from test file: $!";
    }
    my $result = PAGI::App::File->new(root => $root)->locate('/unreadable.txt');
    chmod 0600, $path
        or die "cannot restore read permission on $path: $!";
    if ($result->is_file) {
        plan skip_all => 'effective user can still read a mode-000 file';
    }
    ok($result->is_forbidden,
        'a regular file that is not readable is classified forbidden');
};

subtest 'probe snapshots deterministically drive metadata and errno policy' => sub {
    my $file_path = File::Spec->catfile($root_abs, 'snapshot.txt');
    my $file_snapshot = stat_snapshot(S_IFREG() | 0644, 123, 456, 1);
    my $file_snapshot_copy = {
        stat => [@{$file_snapshot->{stat}}], readable => 1,
    };
    my %error_cases = (
        'gone.txt'       => [ENOENT,  'missing'],
        'not-a-dir/file' => [ENOTDIR, 'missing'],
        'denied.txt'     => [EACCES,  'forbidden'],
        'blocked.txt'    => [EPERM,   'forbidden'],
    );
    my %probes = ($file_path => $file_snapshot);
    for my $name (keys %error_cases) {
        my $path = File::Spec->catfile($root_abs, split m{/}, $name);
        my ($errno, $kind) = @{$error_cases{$name}};
        $probes{$path} = { errno => $errno, error => "simulated $kind" };
    }
    my $failure_path = File::Spec->catfile($root_abs, 'failure.txt');
    $probes{$failure_path} = {
        errno => EIO, error => 'simulated probe failure',
    };

    my $files = Local::ProbeFile->new(root => $root, probes => \%probes);
    my $located = $files->locate('/snapshot.txt');
    ok($located->is_file, 'a regular readable snapshot becomes a file');
    is($located->size, 123, 'size comes from the one probe snapshot');
    is($located->mtime, 456, 'mtime comes from the one probe snapshot');
    is($files->probe_calls, [$file_path],
        'the selected file is probed exactly once');
    is($file_snapshot, $file_snapshot_copy,
        'locate does not mutate the supplied probe snapshot');

    for my $name (sort keys %error_cases) {
        my ($errno, $kind) = @{$error_cases{$name}};
        my $result = $files->locate("/$name");
        ok($result->can("is_$kind")->($result),
            "$errno snapshot is classified $kind");
    }
    like(dies { $files->locate('/failure.txt') },
        qr/Cannot inspect file candidate.*failure\.txt.*simulated probe failure/i,
        'an unexpected inspection error propagates its captured message');
};

subtest 'serve consumes every Result kind and reuses located file metadata' => sub {
    my $file_path = File::Spec->catfile($root_abs, 'served.txt');
    my $files = Local::ProbeFile->new(root => $root, probes => {
        $file_path => stat_snapshot(S_IFREG() | 0644, 17, 1234, 1),
    });
    my $result = $files->locate('/served.txt');
    my $after_locate = $files->probe_count;
    my @events;

    $files->serve(http_scope(path => '/served.txt'), sub {
        push @events, $_[0];
        return Future->done;
    }, $result)->get;

    is($files->probe_count, $after_locate,
        'serve reuses located metadata without another stat');
    is($events[0]{status}, 200, 'a file Result receives a successful response');
    is(event_header($events[0], 'content-length'), 17,
        'response length comes from the Result metadata');
    is($events[1]{file}, $result->path,
        'GET delegates opening to the server');
    ok(!exists $events[1]{fh}, 'application does not open a filehandle');

    for my $case (
        [missing   => 404],
        [directory => 404],
        [forbidden => 403],
    ) {
        my ($kind, $status) = @$case;
        my $other = PAGI::App::File::Result->new(
            kind => $kind, path => "/not-disclosed/$kind",
        );
        my @other_events;
        $files->serve(http_scope(path => "/$kind"), sub {
            push @other_events, $_[0];
            return Future->done;
        }, $other)->get;
        is($other_events[0]{status}, $status,
            "$kind Result receives its owned Pages status");
        unlike($other_events[1]{body}, qr/\Q$kind\E|not-disclosed/,
            "$kind response does not disclose Result metadata");
    }
};

subtest 'serve and to_app reject invalid scopes and Result objects before events' => sub {
    my $files = Local::ProbeFile->new(root => $root, probes => {});
    my $result = PAGI::App::File::Result->new(
        kind => 'missing', path => '/not-disclosed/missing',
    );
    my $receive = sub { return Future->done({ type => 'http.disconnect' }) };

    for my $case (
        [missing => { method => 'GET', path => '/', headers => [] },
            qr/scope type.*required/i],
        [extension => http_scope(type => 'example.custom'),
            qr/requires HTTP scope.*example\.custom/i],
    ) {
        my ($label, $scope, $error) = @$case;
        my @serve_events;
        like(dies {
            $files->serve($scope, sub {
                push @serve_events, $_[0];
                return Future->done;
            }, $result)->get;
        }, $error, "serve rejects $label scope type");
        is(\@serve_events, [],
            "serve rejects $label scope before emitting events");

        my @app_events;
        like(dies {
            $files->to_app->($scope, $receive, sub {
                push @app_events, $_[0];
                return Future->done;
            })->get;
        }, $error, "to_app rejects $label scope type");
        is(\@app_events, [],
            "to_app rejects $label scope before emitting events");
    }

    for my $case (
        [undefined => undef],
        [unblessed => {}],
        [wrong_class => Local::NotFileResult->new],
    ) {
        my ($label, $wrong) = @$case;
        my @events;
        like(dies {
            $files->serve(http_scope(), sub {
                push @events, $_[0];
                return Future->done;
            }, $wrong)->get;
        }, qr/Result.*PAGI::App::File::Result/i,
            "$label Result object is rejected");
        is(\@events, [], "$label Result is rejected before events");
    }
};

subtest 'unsupported methods avoid location and receive the shared 405' => sub {
    my $files = Local::ProbeFile->new(root => $root, probes => {});
    my @events;
    $files->to_app->(
        http_scope(method => 'POST', path => '/must-not-probe'),
        sub { return Future->done({ type => 'http.disconnect' }) },
        sub { push @events, $_[0]; return Future->done },
    )->get;
    is($files->probe_count, 0,
        'to_app does not locate a path for an unsupported owned method');
    is($events[0]{status}, 405, 'unsupported owned method receives 405');
    is(event_header($events[0], 'allow'), 'GET, HEAD',
        '405 advertises the exact supported methods');

    my $result = PAGI::App::File::Result->new(
        kind => 'missing', path => '/must-not-disclose',
    );
    my @direct_events;
    $files->serve(http_scope(method => 'POST'), sub {
        push @direct_events, $_[0];
        return Future->done;
    }, $result)->get;
    is($direct_events[0]{status}, 405,
        'direct serve enforces its owned method boundary');
    is(event_header($direct_events[0], 'allow'), 'GET, HEAD',
        'direct serve uses the same exact Allow field');
};

subtest 'interleaved serve Futures retain request-local Result metadata' => sub {
    my $files = PAGI::App::File->new(root => $root);
    my $first = PAGI::App::File::Result->new(
        kind => 'file', path => '/virtual/first.txt', size => 11, mtime => 101,
    );
    my $second = PAGI::App::File::Result->new(
        kind => 'file', path => '/virtual/second.json', size => 22, mtime => 202,
    );
    my ($first_gate, $second_gate) = (Future->new, Future->new);
    my (@first_events, @second_events);

    my $first_future = $files->serve(http_scope(path => '/first.txt'), sub {
        push @first_events, $_[0];
        return @first_events == 1 ? $first_gate : Future->done;
    }, $first);
    my $second_future = $files->serve(http_scope(
        path => '/second.json', headers => [['range', 'bytes=2-5']],
    ), sub {
        push @second_events, $_[0];
        return @second_events == 1 ? $second_gate : Future->done;
    }, $second);

    ok(!$first_future->is_ready && !$second_future->is_ready,
        'both requests suspend independently after response start');
    is(event_header($first_events[0], 'content-length'), 11,
        'first suspended response retains the first Result size');
    is($second_events[0]{status}, 206,
        'second suspended response retains its own range outcome');
    is(event_header($second_events[0], 'content-range'), 'bytes 2-5/22',
        'second suspended response retains the second Result size');

    $second_gate->done;
    $second_future->get;
    ok(!$first_future->is_ready,
        'completing the second request does not complete the first');
    is($second_events[1]{file}, '/virtual/second.json',
        'second body retains the second Result path');
    is($second_events[1]{offset}, 2,
        'second body retains its request-local range offset');
    is($second_events[1]{length}, 4,
        'second body retains its request-local range length');

    $first_gate->done;
    $first_future->get;
    is($first_events[1]{file}, '/virtual/first.txt',
        'first body retains the first Result path after interleaving');
    ok(!exists $first_events[1]{offset} && !exists $first_events[1]{length},
        'first full body does not inherit the second request range');
};

subtest 'index probing skips ineligible candidates and stops at forbidden' => sub {
    my $directory = File::Spec->catdir($root_abs, 'simulated-index');
    my $nonregular = File::Spec->catfile($directory, 'socket-index');
    my $regular = File::Spec->catfile($directory, 'regular-index');
    my $skip_files = Local::ProbeFile->new(root => $root, probes => {
        $directory  => stat_snapshot(S_IFDIR() | 0755, 0, 1, 1),
        $nonregular => stat_snapshot(0, 0, 2, 1),
        $regular    => stat_snapshot(S_IFREG() | 0644, 8, 3, 1),
    }, index => ['socket-index', 'regular-index']);
    my $selected = $skip_files->locate('/simulated-index');
    ok($selected->is_file, 'later regular index is selected');
    is($selected->path, $regular,
        'a non-regular index does not end ordered selection');
    is($skip_files->probe_calls, [$directory, $nonregular, $regular],
        'index candidates are probed in declared order');

    my $unreadable = File::Spec->catfile($directory, 'unreadable-index');
    my $later = File::Spec->catfile($directory, 'later-index');
    my $stop_files = Local::ProbeFile->new(root => $root, probes => {
        $directory  => stat_snapshot(S_IFDIR() | 0755, 0, 4, 1),
        $unreadable => stat_snapshot(S_IFREG() | 0644, 9, 5, 0),
        $later      => stat_snapshot(S_IFREG() | 0644, 10, 6, 1),
    }, index => ['unreadable-index', 'later-index']);
    my $blocked = $stop_files->locate('/simulated-index');
    ok($blocked->is_forbidden,
        'the first regular unreadable index is forbidden');
    is($blocked->path, $unreadable,
        'forbidden index result retains the first regular candidate');
    is($stop_files->probe_calls, [$directory, $unreadable],
        'a later index cannot bypass an earlier forbidden regular file');
};

subtest 'outward symlinks are trusted by lexical location' => sub {
    my $outside_root = tempdir(CLEANUP => 1);
    my $outside = File::Spec->catfile($outside_root, 'shared-source.txt');
    write_file($outside, 'outside data');
    my $link = File::Spec->catfile($root, 'shared.txt');
    my $linked = eval { symlink($outside, $link) };
    unless ($linked) {
        my $reason = $@ || $! || 'symlink creation returned false';
        plan skip_all => "symlink creation unavailable: $reason";
    }

    my $located = PAGI::App::File->new(root => $root)->locate('/shared.txt');
    ok($located->is_file, 'an outward symlink locates as a regular file');
    is($located->path, File::Spec->catfile($root_abs, 'shared.txt'),
        'the result retains the lexical in-root symlink path');
    is($located->size, 12, 'metadata describes the trusted symlink target');
};

done_testing;
