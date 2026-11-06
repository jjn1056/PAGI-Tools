use v5.24;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::Lib;
use IPC::Open3 qw(open3);
use Symbol qw(gensym);

# Runs perl with the library and the test fixtures on @INC, returning its exit
# status, STDOUT and STDERR.
sub run_perl {
    my (@args) = @_;
    my $pid = open3(my $in, my $out, my $err = gensym, $^X, "-I$Bin/../lib", "-I$Bin/lib", @args);
    close $in;
    my $stdout = do { local $/; <$out> } // '';
    my $stderr = do { local $/; <$err> } // '';
    waitpid $pid, 0;
    return ($? >> 8, $stdout, $stderr);
}

# Runs a module file as the program.
sub run_file {
    my ($file, @args) = @_;
    return run_perl("$Bin/lib/$file", @args);
}

subtest 'loaded by its path, the module is the application' => sub {
    local $ENV{GREETING} = 'Hi';
    my $app = do "$Bin/lib/TestApps/Greeter.pm";
    isa_ok($app, ['TestApps::Greeter', 'PAGI::App'], 'the object');
    is($app->to_app->(), 'Hi', 'built with no arguments; its settings come from defaults');
};

subtest 'a later use of the module does not compile it again' => sub {
    ok(no_warnings { require TestApps::Greeter }, 'no redefinition warnings');
    is(do { no warnings 'once'; $TestApps::Greeter::COMPILED }, 1, 'compiled once');
};

subtest 'run as the program, it says how to serve it' => sub {
    my ($status, $stdout, $stderr) = run_file('TestApps/Greeter.pm');
    isnt($status, 0, 'a non-zero exit');
    like($stderr, qr/is a PAGI application; serve it with:\n  pagi-server -Ilib --app /, 'how to serve it, on STDERR');
};

subtest 'a setting checked in BUILD: the server refuses to load without it' => sub {
    local $ENV{VALIDATED_DSN}; delete $ENV{VALIDATED_DSN};
    my ($status, $stdout) = run_perl('-e', 'do $ARGV[0]; print $@', "$Bin/lib/TestApps/Validated.pm");
    is($stdout, "TestApps::Validated needs a database: set VALIDATED_DSN\n", 'the BUILD message');
};

subtest 'a test sets the setting in BEGIN, before use' => sub {
    local $ENV{VALIDATED_DSN}; delete $ENV{VALIDATED_DSN};
    my ($status, $stdout) = run_perl('-e',
        'BEGIN { $ENV{VALIDATED_DSN} = "dbi:test" } use TestApps::Validated; print TestApps::Validated->new->dsn');
    is([$status, $stdout], [0, 'dbi:test'], 'use succeeds, and new reads the environment');
};

subtest 'without it, use stops too' => sub {
    local $ENV{VALIDATED_DSN}; delete $ENV{VALIDATED_DSN};
    my ($status, undef, $stderr) = run_perl('-e', 'use TestApps::Validated;');
    isnt($status, 0, 'a non-zero exit');
    like($stderr, qr/\ATestApps::Validated needs a database: set VALIDATED_DSN\n/, 'the BUILD message');
};

subtest 'run as the program, it builds nothing' => sub {
    local $ENV{VALIDATED_DSN}; delete $ENV{VALIDATED_DSN};
    my ($status, $stdout, $stderr) = run_file('TestApps/Validated.pm');
    like($stderr, qr/\A\S+Validated\.pm is a PAGI application; serve it with:/, 'the hint, not the BUILD message');
};

done_testing;
