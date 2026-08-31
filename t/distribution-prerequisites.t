use strict;
use warnings;

use Test2::V0;
use version ();

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

my $server_minimum
    = $Local::CPANFileContract::PREREQUISITES{develop}{requires}{'PAGI::Server'};
ok(
    defined($server_minimum)
        && version->parse($server_minimum) >= version->parse('0.002011'),
    'develop prerequisites require cancellation-isolated PAGI::Server 0.002011 or newer',
);

ok(
    !exists $Local::CPANFileContract::PREREQUISITES{runtime}{requires}{'PAGI::Server'}
        && !exists $Local::CPANFileContract::PREREQUISITES{runtime}{recommends}{'PAGI::Server'},
    'PAGI::Server remains outside runtime prerequisites',
);

done_testing;
