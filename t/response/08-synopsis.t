use strict;
use warnings;
use Test2::V0;

# Each Response class's SYNOPSIS runs as written, in a fresh perl that has
# loaded nothing else: a SYNOPSIS that calls a class it never loads dies for
# the reader who copies it.
# NDJSON's SYNOPSIS is a handler body (it returns, and reads $cursor), so
# it is not a standalone program.
for my $name (qw(Text HTML JSON Problem Redirect Empty File Stream)) {
    my $file = "lib/PAGI/Response/$name.pm";
    open my $fh, '<', $file or die "$file: $!";
    my $pod = do { local $/; <$fh> };
    my ($synopsis) = $pod =~ /^=head1 SYNOPSIS\n(.*?)^=head1/ms;
    ok(defined $synopsis, "$name has a SYNOPSIS") or next;

    my $program = "use strict; use warnings;\n$synopsis\nprint qq{ran\\n};\n";
    my $output = do {
        open my $run, '-|', $^X, '-Ilib', '-e', $program
            or die "cannot run perl: $!";
        local $/;
        <$run>;
    };
    is($output, "ran\n", "$name SYNOPSIS runs as written");
}

done_testing;
