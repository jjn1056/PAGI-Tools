use strict;
use warnings;
use Test2::V0;
use Encode ();

use lib 't/lib';
use PAGITest::Stringy;
use PAGI::Utils;

# One rule for every header value Tools sends (items 1 and 2), and one
# headers argument in three shapes at every site that takes one.

subtest 'the one header value rule' => sub {
    my $check = \&PAGI::Utils::_sendable_header_value;
    is([ $check->(PAGITest::Stringy::Overloaded->new('ok')) ], ['ok'], 'an overloading object gives its string');
    my ($bytes) = $check->(Encode::decode('UTF-8', 'plain'));
    is($bytes, 'plain', 'flagged ASCII is bytes');
    ok(!utf8::is_utf8($bytes), 'given back as plain bytes');
    is([ $check->(PAGITest::Stringy::Plain->new) ], [undef, 'not a string'], 'a plain object is not a string');
    is([ $check->([1]) ],                           [undef, 'not a string'], 'nor is a reference');
    is([ $check->(undef) ],                         [undef, 'not a string'], 'nor undef');
    is([ $check->("smile \x{263a}") ],              [undef, 'wide'],         'a wide character is not bytes');
};

done_testing;
