use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Utils::_Exporter ();

# A module that exports through the installer. Every export is an anonymous
# sub, so the module answers none of them as a method.
{
    package Local::Lib;

    my %EXPORTS = (
        alpha => sub { 'alpha' },
        beta  => sub :prototype(&) { $_[0]->() },
        who   => sub { scalar caller },
    );
    my %TAGS = (
        all   => [sort keys %EXPORTS],
        greek => [qw(alpha beta)],
    );
    my @DEFAULTS = qw(alpha);

    sub import {
        my $invocant = shift;
        PAGI::Utils::_Exporter::export(
            __PACKAGE__, \%EXPORTS, \%TAGS, \@DEFAULTS,
            scalar caller, $invocant, @_,
        );
    }

    $INC{'Local/Lib.pm'} = __FILE__;
}

{
    package Local::Lib::Sub;
    our @ISA = ('Local::Lib');
    $INC{'Local/Lib/Sub.pm'} = __FILE__;
}

# Compiles $code in a package no other test has used, so each import starts
# from an empty symbol table. Returns the package, the code's value and the
# error it died with.
my $packages = 0;
sub in_fresh_package {
    my ($code) = @_;
    my $package = 'T' . ++$packages;
    my $value = eval "package $package; $code";
    return ($package, $value, $@);
}

sub installed {
    my ($package) = @_;
    no strict 'refs';
    return [sort grep { defined &{"${package}::$_"} } keys %{"${package}::"}];
}

subtest 'a bare use installs the defaults' => sub {
    my ($package, $ok, $error) = in_fresh_package('use Local::Lib; 1');
    ok($ok, 'imports') or diag($error);
    is(installed($package), ['alpha'], 'exactly alpha');
};

subtest 'a named import installs that name with its prototype' => sub {
    my ($package, $value, $error) = in_fresh_package(
        'use Local::Lib qw(beta); beta { 42 }');
    is($value, 42, 'beta { 42 } compiles as a block call') or diag($error);
    is(installed($package), ['beta'], 'exactly beta');
    is(prototype("${package}::beta"), '&', 'the prototype is kept');
};

subtest 'tags expand to their names' => sub {
    my ($greek, $greek_ok, $greek_error) = in_fresh_package('use Local::Lib qw(:greek); 1');
    ok($greek_ok, ':greek imports') or diag($greek_error);
    is(installed($greek), [qw(alpha beta)], ':greek installs alpha and beta');

    my ($all, $all_ok, $all_error) = in_fresh_package('use Local::Lib qw(:all); 1');
    ok($all_ok, ':all imports') or diag($all_error);
    is(installed($all), [qw(alpha beta who)], ':all installs every name');
};

subtest 'the coderef is installed with no wrapper' => sub {
    my ($package, $value, $error) = in_fresh_package('use Local::Lib qw(who); who()');
    is($value, $package, 'caller inside it is the importing package') or diag($error);
};

subtest 'an unknown name or tag croaks at the use line' => sub {
    my ($name_package, $name_ok, $name_error) = in_fresh_package('use Local::Lib qw(nope); 1');
    ok(!$name_ok, 'an unknown name dies');
    like($name_error,
        qr/\A"nope" is not exported by Local::Lib at \(eval \d+\) line 1\.\n/,
        'naming the name and the use line');

    my ($tag_package, $tag_ok, $tag_error) = in_fresh_package('use Local::Lib qw(:nope); 1');
    ok(!$tag_ok, 'an unknown tag dies');
    like($tag_error,
        qr/\A":nope" is not exported by Local::Lib at \(eval \d+\) line 1\.\n/,
        'naming the tag and the use line');
};

# Called at run time on the code's second line, import has no BEGIN frame on
# the same line above it, so only the frame that called import names line 2.
subtest 'an error names the line that called import' => sub {
    my (undef, $name_ok, $name_error) = in_fresh_package("1;\nLocal::Lib->import('nope'); 1");
    ok(!$name_ok, 'an unknown name dies');
    like($name_error,
        qr/\A"nope" is not exported by Local::Lib at \(eval \d+\) line 2\.\n\z/,
        'naming the calling line');

    my (undef, $sub_ok, $sub_error) = in_fresh_package("1;\nLocal::Lib::Sub->import('alpha'); 1");
    ok(!$sub_ok, 'a subclass import dies');
    like($sub_error,
        qr/\ALocal::Lib::Sub exports nothing; import from Local::Lib at \(eval \d+\) line 2\.\n\z/,
        'naming the calling line');
};

subtest 'a subclass exports nothing' => sub {
    my ($bare, $bare_ok, $bare_error) = in_fresh_package('use Local::Lib::Sub; 1');
    ok($bare_ok, 'a bare use succeeds') or diag($bare_error);
    is(installed($bare), [], 'and installs nothing');

    my ($named, $named_ok, $named_error) = in_fresh_package('use Local::Lib::Sub qw(alpha); 1');
    ok(!$named_ok, 'a named import dies');
    like($named_error,
        qr/\ALocal::Lib::Sub exports nothing; import from Local::Lib at \(eval \d+\) line 1\.\n/,
        'pointing at the declaring module and the use line');
    is(installed($named), [], 'and installs nothing');
};

subtest 'importing the same name twice is silent' => sub {
    my ($package, $ok, $error);
    my $warnings = warnings {
        ($package, $ok, $error) = in_fresh_package(
            'use Local::Lib qw(alpha); use Local::Lib qw(alpha); 1');
    };
    ok($ok, 'both imports succeed') or diag($error);
    is($warnings, [], 'no warning');
    is(installed($package), ['alpha'], 'alpha is installed');
};

subtest 'the declaring module does not answer its exports as methods' => sub {
    ok(!Local::Lib->can($_), "Local::Lib cannot $_") for qw(alpha beta who);
};

done_testing;
