use strict;
use warnings;

use Test2::V0;

{
    package Local::CPANFileContract;

    our $PHASE = 'runtime';
    our %PREREQUISITES;

    sub requires {
        my ($module, $minimum) = @_;
        $PREREQUISITES{$PHASE}{requires}{$module}
            = defined $minimum ? "$minimum" : '0';
    }

    sub recommends {
        my ($module, $minimum) = @_;
        $PREREQUISITES{$PHASE}{recommends}{$module}
            = defined $minimum ? "$minimum" : '0';
    }

    sub on {
        my ($phase, $declarations) = @_;
        local $PHASE = $phase;
        return $declarations->();
    }

    sub load {
        my ($path) = @_;
        return do $path;
    }
}

my $loaded = Local::CPANFileContract::load('./cpanfile');
ok(defined $loaded, 'cpanfile executes as a prerequisite contract')
    or diag("cpanfile load failed: $@ $!");

# Tools targets the PAGI spec, not a server. The real-server tests run against
# a PAGI-Server checkout on -I and skip otherwise, so no phase declares one.
my @server_declarations = grep {
    exists $_->{'PAGI::Server'}
} map { values %$_ } values %Local::CPANFileContract::PREREQUISITES;
is(scalar @server_declarations, 0, 'no prerequisite phase declares PAGI::Server');

done_testing;
