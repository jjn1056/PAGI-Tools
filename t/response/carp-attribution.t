use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Response ();

# A framework that calls PAGI-Tools on its users' behalf marks its own
# packages with $Carp::Internal (PAGI::Response, ERRORS FROM A FRAMEWORK), so
# a croak from Tools names its user's line, not the framework's.

{
    package Local::Framework::Response;
    our $LINE = __LINE__; sub build { PAGI::Response->new([]) }
    package Local::Marked::Response;
    $Carp::Internal{'Local::Marked::Response'}++;
    sub build { PAGI::Response->new([]) }
}

my $unmarked = dies { Local::Framework::Response::build() };
my $marked_line = __LINE__ + 1;
my $marked = dies { Local::Marked::Response::build() };

like($unmarked, qr/at \Q${\ __FILE__}\E line $Local::Framework::Response::LINE\.$/m,
    'unmarked: the framework line is named');
like($marked, qr/at \Q${\ __FILE__}\E line $marked_line\.$/m, "marked: its user's line is named");

done_testing;
