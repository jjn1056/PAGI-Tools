#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';

# PAGI::Tools::Extending links to the rules instead of restating them, so its
# links must land on real sections, and its one worked example must do what
# the guide says it does.

my $guide_file = 'lib/PAGI/Tools/Extending.pod';
my $guide = do { open my $fh, '<', $guide_file or die "$guide_file: $!"; local $/; <$fh> };

# The verbatim blocks, in order: runs of indented lines (blank lines inside a
# run kept), with the four-space indent removed.
sub verbatim_blocks {
    my ($pod) = @_;
    my (@blocks, @run, $blank);
    for my $line (split /\n/, $pod) {
        if ($line =~ /^    /) {
            push @run, ('') x $blank if @run && $blank;
            push @run, substr($line, 4);
            $blank = 0;
        }
        elsif ($line eq '') {
            $blank++ if @run;
        }
        else {
            push @blocks, join("\n", @run) . "\n" if @run;
            @run = ();
            $blank = 0;
        }
    }
    push @blocks, join("\n", @run) . "\n" if @run;
    return @blocks;
}

# Modules outside this distribution the guide may link to; any other target
# must be a file under lib/.
my %external = map { $_ => 1 } qw(PAGI::Building PAGI::Spec::Www Future::IO);

subtest 'every link to this distribution names a section it has' => sub {
    my @links = $guide =~ /L<([^<>|]+)>/g;
    ok(@links > 20, 'the guide links to the rules (' . scalar(@links) . ' links)');
    for my $link (@links) {
        my ($module, $section) = split m{/}, $link, 2;
        if ($external{$module}) {
            pass("$link: outside this distribution");
            next;
        }
        (my $path = $module) =~ s{::}{/}g;
        my ($file) = grep { -f } map { "lib/$path.$_" } qw(pm pod);
        ok($file, "$link: $module is in lib/") or next;
        next unless defined $section;
        $section =~ s/\A"(.*)"\z/$1/;
        my $source = do { open my $fh, '<', $file or die "$file: $!"; local $/; <$fh> };
        like($source, qr/^=head\d \Q$section\E$/m, "$link: the section exists");
    }
};

my @blocks = verbatim_blocks($guide);
is(scalar @blocks, 2, 'two code blocks: the constructor call and the wrapping example');

subtest 'the constructor call compiles' => sub {
    my ($name, $content, $code, $headers, $type);
    ok(eval "use PAGI::Response qw(response); my \$call = sub { $blocks[0] }; 1", 'compiles') or diag $@;
};

subtest 'the wrapping example works as the guide says' => sub {
    my $example = $blocks[1];
    like($example, qr/^package My::Framework::Response;/, 'the block is the example');
    ok(eval "$example; 1", 'it compiles and loads') or diag($@), return;

    my $res = My::Framework::Response->new;
    isa_ok($res->status(201), ['My::Framework::Response'], 'a delegated setter returns the framework response');
    isa_ok($res->header('X-Staged' => 'yes'), ['My::Framework::Response'], 'and so does header');
    is($res->status, 201, 'a getter still returns its value');

    my $value = $res->finalize('Text', 'hello');
    isa_ok($value, ['PAGI::Response::Text'], 'finalize builds the chosen class');
    is($value->status, 201, 'with the staged status');
    is($value->header('X-Staged'), 'yes', 'and the staged headers');

    my $plain = My::Framework::Response->new->finalize(undef, 'bytes');
    isa_ok($plain, ['PAGI::Response'], 'no class is the base class');
    is($plain->status, 200, 'nothing staged: 200');

    my $line = __LINE__ + 1;
    my $error = dies { My::Framework::Response->new->finalize('Text', undef) };
    like($error, qr/^Text response body must be a defined Unicode scalar at \Q${\__FILE__}\E line $line\.$/,
        "a refusal names the framework user's line, not the framework's");
};

done_testing;
