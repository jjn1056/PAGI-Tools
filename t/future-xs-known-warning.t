use strict;
use warnings;
use Test2::V0;
use lib 't/lib';

use PAGITest::FutureXS qw(known_future_xs_warning);

ok(!$INC{'Future.pm'}, 'loading the predicate does not load Future');

my $lost = 'Future=SCALAR(0x1) lost a sequence Future at x line 1.';
my $uninit = 'Use of uninitialized value in subroutine entry at x line 1.';

{
    local $INC{'Future/XS.pm'};
    ok(!known_future_xs_warning($lost), 'Future::XS not loaded: not known');
}
{
    local $INC{'Future/XS.pm'} = 'Future/XS.pm';
    no warnings 'once';
    local $Future::XS::VERSION = '0.15';
    ok(known_future_xs_warning($lost),    'Future::XS 0.15: the lost-sequence warning is known');
    ok(known_future_xs_warning($uninit),  'and its companion line');
    ok(!known_future_xs_warning('Something else at x line 1.'), 'and nothing else');
    local $Future::XS::VERSION = '0.15_001';
    ok(known_future_xs_warning($lost),    'a 0.15 dev release: known');
    ok(no_warnings { known_future_xs_warning($lost) }, 'and its version compares without a warning');
    local $Future::XS::VERSION = '0.16';
    ok(!known_future_xs_warning($lost),   'Future::XS 0.16: not known');
    ok(!known_future_xs_warning($uninit), 'nor its companion line');
}

done_testing;
