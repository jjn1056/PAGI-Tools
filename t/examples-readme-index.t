use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);

# examples/README.md indexes every example directory exactly once, so a
# rename or a new example cannot leave the index stale.

my $examples = "$Bin/../examples";
my $readme = do {
    open my $fh, '<', "$examples/README.md" or die "README: $!";
    local $/; <$fh>;
};

opendir my $dh, $examples or die "$examples: $!";
my @dirs = sort grep { !/^\./ && -d "$examples/$_" } readdir $dh;

my %listed;
$listed{$_}++ for grep { defined } $readme =~ /^- (?:`([a-z0-9-]+)`|\[([a-z0-9-]+)\])/mg;

is([sort keys %listed], \@dirs, 'the index lists exactly the example directories');
is([grep { $listed{$_} > 1 } sort keys %listed], [], 'each one once');

done_testing;
