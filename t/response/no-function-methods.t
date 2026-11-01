use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Request ();
use PAGI::Response::JSON ();

# A class's exported functions are imported, not inherited: its objects
# answer none of them as methods.

ok(!PAGI::Response::JSON->can('response'), 'a Response subclass has no response method');
ok(!PAGI::Request->can('http_connection'), 'a Request has no http_connection method');

done_testing;
