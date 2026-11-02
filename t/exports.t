use strict;
use warnings;
use Test2::V0;
use B ();
use Cwd qw(getcwd);
use File::Find ();
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

use lib 'lib';
use PAGI::Utils qw(app_path);

# Every module that exports through PAGI::Utils::_Exporter is found by
# searching lib for its call, so a newly converted module is covered without
# editing this list.

# Function modules: each exported name stays callable by its full name in
# its own package; PAGI::Tools keeps a full name only for the names it
# re-exports from the other function modules.
my @FUNCTION_MODULES = qw(
    PAGI::Utils
    PAGI::Utils::Headers
    PAGI::Utils::Middleware
    PAGI::Utils::SecureCompare
    PAGI::Utils::Random
    PAGI::Routing
    PAGI::Middleware::BufferedResponse
    PAGI::Tools
);
my %IS_FUNCTION_MODULE = map { $_ => 1 } @FUNCTION_MODULES;

# Classes whose exported names are also documented methods. PAGI::Pages keeps
# every name it exports.
my %KEPT_METHODS = (
    'PAGI::ContentNegotiation' => [qw(respond_to)],
    'PAGI::Auth'               => [qw(auth auth_result unauth_result www_authenticate)],
    'PAGI::Routing::URL'       => [qw(path_for url_for)],
);
my %KEEPS_EVERY_NAME = ('PAGI::Pages' => 1);

# The names a bare `use` installs, where there are any.
my %DEFAULTS = (
    'PAGI::Middleware::Builder' => [qw(builder enable enable_if mount)],
);

my $lib = File::Spec->catdir($Bin, File::Spec->updir, 'lib');
my $server_lib = File::Spec->catdir($Bin, File::Spec->updir, File::Spec->updir,
    'PAGI-Server', 'lib');

sub lib_modules {
    my @modules;
    File::Find::find({ no_chdir => 1, wanted => sub {
        return unless /\.pm\z/;
        my $relative = File::Spec->abs2rel($File::Find::name, $lib);
        $relative =~ s/\.pm\z//;
        push @modules, [join('::', File::Spec->splitdir($relative)), $File::Find::name];
    } }, $lib);
    return sort { $a->[0] cmp $b->[0] } @modules;
}

# A module's code, without its POD, so a module that only documents the
# installer's call is not counted as calling it.
sub code_of {
    my ($file) = @_;
    open my $fh, '<', $file or die "cannot read $file: $!";
    my $source = do { local $/; <$fh> };
    $source =~ s/^__END__\b.*//ms;
    $source =~ s/^=[a-zA-Z].*?(?:^=cut\b[^\n]*\n|\z)//msg;
    return $source;
}

my @LIB_MODULES = lib_modules();
my @MODULES = map { $_->[0] }
    grep { $_->[0] ne 'PAGI::Utils::_Exporter'
        && index(code_of($_->[1]), 'PAGI::Utils::_Exporter::export(') >= 0 }
    @LIB_MODULES;
die "no exporting modules found\n" unless @MODULES;
my %IS_EXPORTING = map { $_ => 1 } @MODULES;

my @load_failures;
for my $module (map { $_->[0] } @LIB_MODULES) {
    eval "require $module; 1" or push @load_failures, "$module: $@";
}
is(\@load_failures, [], 'every lib module loads');

# Every package under PAGI::, loaded or declared inline.
sub packages_under {
    my ($prefix) = @_;
    no strict 'refs';
    my @packages;
    for my $key (keys %{"${prefix}::"}) {
        next unless $key =~ /\A(\w+)::\z/;
        my $package = "${prefix}::$1";
        push @packages, $package, packages_under($package);
    }
    return @packages;
}
my @PAGI_PACKAGES = sort(packages_under('PAGI'));

# The subclasses that inherit the module's own import.
sub subclasses_of {
    my ($module) = @_;
    my $import = $module->can('import');
    return grep {
        $_ ne $module && $_->isa($module)
            && ($_->can('import') || 0) == $import
    } @PAGI_PACKAGES;
}

sub installed {
    my ($package) = @_;
    no strict 'refs';
    return [sort grep { defined &{"${package}::$_"} } keys %{"${package}::"}];
}

my $packages = 0;
sub fresh_package { return 'Local::Exports::T' . ++$packages }

sub kept_methods {
    my ($module) = @_;
    return [sort keys %{ $module->_exports }] if $KEEPS_EVERY_NAME{$module};
    return $KEPT_METHODS{$module} || [];
}

subtest 'no lib module uses Exporter' => sub {
    my @users;
    for my $module (@LIB_MODULES) {
        push @users, $module->[0]
            if code_of($module->[1]) =~ /\b(?:use|require)\s+Exporter\b|\@EXPORT/;
    }
    is(\@users, [], 'none does');
};

subtest 'the function modules export through the installer' => sub {
    ok($IS_EXPORTING{$_}, "$_ is found") for @FUNCTION_MODULES;
};

# An imported function is a sub in the importer's stash, so a class that
# imports one answers it as a method, and so does every subclass. A lib
# class (a package declared in lib that answers new) holds no sub defined
# in another package; overload's entries, whose names start with "(", are
# not methods.
sub imported_subs {
    my ($package) = @_;
    my @imported;
    no strict 'refs';
    for my $name (sort keys %{"${package}::"}) {
        next if $name =~ /\A\(/;
        my $code = *{"${package}::$name"}{CODE} or next;
        my $gv = B::svref_2object($code)->GV;
        next if $gv->isa('B::SPECIAL');
        my $home = $gv->STASH->NAME;
        push @imported, "$name from $home" unless $home eq $package;
    }
    return @imported;
}

subtest 'no lib class holds an imported sub' => sub {
    {
        package Local::Exports::Imports;
        use Carp qw(croak);
        use overload '""' => sub { 'imports' };
        sub new { return bless {}, shift }
    }
    is([imported_subs('Local::Exports::Imports')], ['croak from Carp'],
        'an import is found; a sub of its own and overload are not');

    my %declared;
    for my $module (@LIB_MODULES) {
        my $code = code_of($module->[1]);
        $declared{$1} = 1 while $code =~ /^\s*package\s+([\w:]+)/mg;
    }
    my @classes = grep { $declared{$_} && $_->can('new') } @PAGI_PACKAGES;
    ok(scalar(@classes), 'there are lib classes to look at');

    my @held = map { my $class = $_; map { "$class holds $_" } imported_subs($class) } @classes;
    is(\@held, [], 'none does');
};

# Loaded first in its own process, so no other test or module has loaded
# anything before it, each name imports into a fresh package and is defined
# there. The child prints each failure and each warning; none is expected.
my $CHILD = <<'PERL';
use strict;
use warnings;
BEGIN { $SIG{__WARN__} = sub { print "warning: $_[0]" } }
my ($module) = @ARGV;
eval "require $module; 1" or do { print "load: $@"; exit };
my $n = 0;
for my $name (sort keys %{ $module->_exports }) {
    $n++;
    my $ok = eval "package T$n; use $module qw($name); 1";
    no strict 'refs';
    print "$name: ", ($ok ? "not defined\n" : $@)
        unless $ok && defined &{"T${n}::$name"};
}
PERL

for my $module (@MODULES) {
    subtest $module => sub {
        my $exports = $module->_exports;
        my @names = sort keys %$exports;
        ok(scalar(@names), 'exports at least one name');

        open my $child, '-|', $^X, "-I$lib", "-I$server_lib", '-e', $CHILD, $module
            or die "cannot start child perl: $!";
        my $output = do { local $/; <$child> };
        close $child;
        is($?, 0, 'a fresh process imports each name');
        is($output, '', 'and each is defined in its importing package');

        my $all = fresh_package();
        ok(eval "package $all; use $module qw(:all); 1", ':all imports') or diag($@);
        is(installed($all), \@names, ':all installs every name');

        my $bare = fresh_package();
        ok(eval "package $bare; use $module; 1", 'a bare use imports') or diag($@);
        is(installed($bare), [sort @{ $DEFAULTS{$module} || [] }],
            'a bare use installs exactly the defaults');

        my $unknown = fresh_package();
        ok(!eval "package $unknown;\nuse $module qw(no_such_name);\n1", 'an unknown name dies');
        like($@, qr/\A"no_such_name" is not exported by \Q$module\E at \(eval \d+\) line 2\.\n/,
            "naming the importer's line");

        if ($module eq 'PAGI::Tools') {
            # A name re-exported from a function module keeps its full-name
            # spelling here as well; a name from a class has none.
            my @function_sources = grep { $_ ne 'PAGI::Tools' } @FUNCTION_MODULES;
            my %from_function_module = map {
                my $name = $_;
                ($name => scalar grep {
                    my $source = $_->_exports->{$name};
                    $source && $source == $exports->{$name};
                } @function_sources);
            } @names;
            ok((grep { $from_function_module{$_} } @names), 'some names come from function modules');
            ok((grep { !$from_function_module{$_} } @names), 'some names come from classes');
            no strict 'refs';
            for my $name (@names) {
                if ($from_function_module{$name}) {
                    ok(defined &{"PAGI::Tools::$name"} && \&{"PAGI::Tools::$name"} == $exports->{$name},
                        "PAGI::Tools::$name is the exported sub");
                }
                else {
                    ok(!defined &{"PAGI::Tools::$name"}, "PAGI::Tools has no $name sub of its own");
                }
            }
        }
        elsif ($IS_FUNCTION_MODULE{$module}) {
            for my $name (@names) {
                no strict 'refs';
                ok(defined &{"${module}::$name"} && \&{"${module}::$name"} == $exports->{$name},
                    "${module}::$name is the exported sub");
            }
        }
        else {
            my %kept = map { $_ => 1 } @{ kept_methods($module) };
            for my $class ($module, grep { $_ ne $module && $_->isa($module) } @PAGI_PACKAGES) {
                for my $name (@names) {
                    if ($kept{$name}) {
                        ok($class->can($name), "$class can $name");
                    }
                    else {
                        ok(!$class->can($name), "$class cannot $name");
                    }
                }
            }
        }

        for my $subclass (subclasses_of($module)) {
            my $quiet = fresh_package();
            ok(eval "package $quiet; BEGIN { $subclass->import } 1",
                "$subclass imports with no list") or diag($@);
            is(installed($quiet), [], 'and installs nothing');

            my $named = fresh_package();
            ok(!eval "package $named; BEGIN { $subclass->import('$names[0]') } 1",
                "$subclass dies on a named import");
            like($@, qr/\A\Q$subclass\E exports nothing; import from \Q$module\E at \(eval \d+\) line 1\.\n/,
                'pointing at the declaring module');
        }
    };
}

# A module's imports are installed when its `use` line runs, so two modules
# that load each other leave the name undefined in whichever one loads second.
# Perl does not always warn about it (before 5.40 a missing import method is
# silent), so this checks the result: the module under test is loaded first,
# then every other lib module, and each name a lib module imports from PAGI
# must be defined in the importing package, with nothing printed to stderr.
sub lib_imports {
    my @imports;
    for my $module (lib_modules()) {
        open my $fh, '<', $module->[1] or die "cannot read $module->[1]: $!";
        my $source = do { local $/; <$fh> };
        close $fh;
        $source =~ s/\A(.*?)^__(?:END|DATA)__\n.*\z/$1/ms;
        $source =~ s/^=[a-zA-Z]\w*.*?^=cut\b[^\n]*$//msg;
        my $package = 'main';
        while ($source =~ /^[ \t]*(?:package\s+([\w:]+)|use\s+PAGI::[\w:]+\s+(?:qw\s*\(([^)]*)\)|'([^']*)'))/mg) {
            if (defined $1) { $package = $1; next }
            push @imports, [$package, $_] for grep { !/^[:!]/ } split ' ', $2 // $3;
        }
    }
    return @imports;
}

# namespace::autoclean removes a class's imports once the class is compiled,
# so the child loads the modules with it doing nothing, leaving each import
# where the check can see it.
my $load_check = <<'CHECK';
$INC{'namespace/autoclean.pm'} = __FILE__;
sub namespace::autoclean::import { }
open STDERR, '>&', \*STDOUT or die "cannot dup stderr: $!";
my ($first, @pairs) = @ARGV;
my @modules = split /,/, shift @pairs;
for my $module ($first, grep { $_ ne $first } @modules) {
    (my $file = "$module.pm") =~ s{::}{/}g;
    eval { require $file; 1 } or print "LOAD FAILED $module: $@";
}
for my $pair (@pairs) {
    my ($package, $name) = split /\t/, $pair;
    no strict 'refs';
    print "MISSING ${package}::$name\n" unless defined &{"${package}::$name"};
}
CHECK

subtest 'no lib module load order leaves an import undefined' => sub {
    plan skip_all => 'set RELEASE_TESTING to run one process per lib module'
        unless $ENV{RELEASE_TESTING};

    my @modules = map { $_->[0] } lib_modules();
    my @pairs = map { "$_->[0]\t$_->[1]" } lib_imports();
    ok(scalar @pairs, 'lib imports from PAGI modules');
    for my $first (@modules) {
        open my $child, '-|', $^X, "-I$lib", "-I$server_lib", '-we', $load_check,
            $first, join(',', @modules), @pairs
            or die "cannot start child perl: $!";
        my $output = do { local $/; <$child> };
        close $child;
        is($output, '', "$first loaded first: every import defined, no output");
    }
};

subtest 'route and mount resolve &Name in the importing package' => sub {
    for my $source (qw(PAGI::Tools PAGI::Routing)) {
        my $package = fresh_package();
        my $built = eval qq{
            package $package;
            use $source qw(mount route);
            our \$CALLS = 0;
            sub Owned { \$CALLS++; return qr/\\A[0-9]+\\z/ }
            route('/notes/{id:&Owned}' => sub { });
            mount('/notes/{id:&Owned}', routes => []);
            1;
        };
        ok($built, "through $source") or diag($@);
        no strict 'refs';
        is(${"${package}::CALLS"}, 2, "each found ${package}::Owned");
    }
};

subtest 'app_path resolves against the importing file after a chdir' => sub {
    local $ENV{PAGI_HOME};
    delete $ENV{PAGI_HOME};
    my $original = getcwd();
    my $elsewhere = tempdir(CLEANUP => 1);
    chdir $elsewhere or die "cannot chdir to $elsewhere: $!";
    my $home = app_path();
    chdir $original or die "cannot chdir back to $original: $!";
    is($home, File::Spec->canonpath(File::Spec->rel2abs($Bin)), "this file's directory");
};

done_testing;
