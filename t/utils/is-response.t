use strict;
use warnings;
use Test2::V0;
use PAGI::Utils qw(is_response);
use PAGI::Response;

ok is_response(PAGI::Response->new('body')), 'complete base value is a response';
ok !is_response(undef), 'undef is not a response';
done_testing;
