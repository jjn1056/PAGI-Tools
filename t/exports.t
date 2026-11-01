use strict;
use warnings;
use Test2::V0;
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

# Function modules: each exported name stays callable by its full name.
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

subtest 'the function modules export through the installer' => sub {
    ok($IS_EXPORTING{$_}, "$_ is found") for @FUNCTION_MODULES;
};

# A class's export is a function, not a method anywhere: no PAGI package
# but a function module holds one in its stash, as an import would put it.
subtest 'no PAGI package holds a class export as a sub' => sub {
    my %class_export;
    for my $module (grep { !$IS_FUNCTION_MODULE{$_} } @MODULES) {
        my %kept = map { $_ => 1 } @{ kept_methods($module) };
        my $exports = $module->_exports;
        $class_export{ 0 + $exports->{$_} } = "${module}'s $_"
            for grep { !$kept{$_} } keys %$exports;
    }
    ok(scalar(keys %class_export), 'there are class exports to look for');

    my @held;
    no strict 'refs';
    for my $package (grep { !$IS_FUNCTION_MODULE{$_} } @PAGI_PACKAGES) {
        for my $name (sort keys %{"${package}::"}) {
            next unless defined &{"${package}::$name"};
            my $export = $class_export{ 0 + \&{"${package}::$name"} } or next;
            push @held, "${package}::$name is $export";
        }
    }
    is(\@held, [], 'none is held');
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
