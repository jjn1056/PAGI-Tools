package PAGITest::CurrentServer;

use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(current_server_unavailable);

# Real-server tests exercise the PAGI::Server release line this PAGI-Tools
# cycle ships with. An older installed server implements a connection contract
# Tools no longer targets, so those tests skip rather than report its gaps.
our $SERVER_VERSION = '0.002014';

# Returns a skip reason, or nothing when the current PAGI::Server is loadable.
sub current_server_unavailable {
    my $hint = 'run with -I <PAGI-Server checkout>/lib';
    return "PAGI::Server not on \@INC; $hint"
        unless eval { require PAGI::Server; 1 };
    return 'PAGI::Server ' . PAGI::Server->VERSION
        . " is older than $SERVER_VERSION; $hint"
        unless eval { PAGI::Server->VERSION($SERVER_VERSION); 1 };
    return;
}

1;
