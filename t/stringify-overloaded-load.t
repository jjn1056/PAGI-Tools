use strict;
use warnings;
use Test2::V0;

use lib 't/lib';
use PAGITest::Stringy;
use PAGI::Response;

# PAGI::Response used by class alone, without response() having loaded
# anything else first, stringifies an overloading body too.

is(PAGITest::Stringy::body_of(PAGI::Response->new(PAGITest::Stringy::Overloaded->new('ok'))), 'ok',
    'PAGI::Response->new stringifies without response() having been called');

done_testing;
