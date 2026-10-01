use strict;
use warnings;
use Test2::V0;
use File::Temp qw(tempfile);
use lib 'lib';
use PAGI::Test::Client;

# UPGRADING.md's worked port is the upgrade guide's main teaching example:
# its After must run as published and answer like the 0.002002 Before did
# (checked by hand against the v0.002002 library when it was written), and
# every link from the summary table must reach a heading in the reference.

plan skip_all => 'the worked port uses Perl 5.40 syntax' if $] < 5.040;

sub slurp {
    my ($file) = @_;
    open my $fh, '<', $file or die "Cannot read $file: $!";
    local $/;
    return scalar <$fh>;
}

my $guide = slurp('UPGRADING.md');
my ($port) = $guide =~ /^## A worked port\n(.*)\z/ms;
ok(defined $port, 'the guide has a worked port');
my ($before, $after) = $port =~ /```perl\n(.*?)```.*?```perl\n(.*?)```/s;
like($before, qr/use parent 'PAGI::Endpoint::Router'/, 'the Before is 0.002002 code');

subtest 'the After runs as published' => sub {
    my ($fh, $file) = tempfile(SUFFIX => '.pl', UNLINK => 1);
    print {$fh} $after;
    close $fh;
    my $app = do $file;
    ok($app, 'the After loads') or diag($@ || $!);

    my $client = PAGI::Test::Client->new(app => $app, lifespan => 1);
    $client->start;
    my @seen = map { [$_->[0], $client->${\ $_->[1]}($_->[2], @{ $_->[3] })->status] } (
        ['home',           'get',  '/',        []],
        ['missing note',   'get',  '/notes/1', []],
        ['anonymous post', 'post', '/notes',   [json => { text => 'hi' }]],
        ['login',          'post', '/login',   []],
        ['create',         'post', '/notes',   [json => { text => 'hi' }]],
        ['read back',      'get',  '/notes/1', []],
    );
    $client->stop;
    is(\@seen, [
        ['home', 200], ['missing note', 404], ['anonymous post', 401],
        ['login', 200], ['create', 201], ['read back', 200],
    ], 'the same answers as the 0.002002 Before');
};

subtest 'every link into the reference reaches a heading' => sub {
    my $reference = slurp('UPGRADING-REFERENCE.md');
    my (%anchor, $fence);
    for my $line (split /\n/, $reference) {
        $fence = !$fence, next if $line =~ /\A```/;
        next if $fence || $line !~ /\A#+ (.+)/;
        (my $slug = lc $1) =~ s/[^\w\- ]//g;
        $slug =~ tr/ /-/;
        $anchor{$slug} = 1;
    }
    my @links = $guide =~ /\(UPGRADING-REFERENCE\.md#([^)]+)\)/g;
    ok(scalar @links, 'the table links into the reference');
    ok($anchor{$_}, "#$_ exists") for @links;
};

done_testing;
