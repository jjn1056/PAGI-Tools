use strict;
use warnings;
use Test2::V0;
use lib 't/lib';

use PAGITest::FutureXS qw(old_future_xs);

ok(!$INC{'Future.pm'}, 'loading the helper does not load Future');

{
    local $INC{'Future/XS.pm'};
    ok(!old_future_xs(), 'Future::XS not loaded: not old');
}
{
    local $INC{'Future/XS.pm'} = 'Future/XS.pm';
    no warnings 'once';
    local $Future::XS::VERSION = '0.15';
    ok(old_future_xs(), 'Future::XS 0.15: old');
    local $Future::XS::VERSION = '0.15_001';
    ok(old_future_xs(), 'a 0.15 dev release: old');
    ok(no_warnings { old_future_xs() }, 'and its version compares without a warning');
    local $Future::XS::VERSION = '0.16';
    ok(!old_future_xs(), 'Future::XS 0.16: not old');
    local $Future::XS::VERSION = '0.2';
    ok(!old_future_xs(), 'a later Future::XS: not old');
}

done_testing;
