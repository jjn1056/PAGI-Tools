use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Response qw(status_forbids_body);

# RFC 9110 forbids content on informational, 204, 205 and 304 responses.

ok(status_forbids_body($_), "$_ forbids a body") for 100, 101, 103, 199, 204, 205, 304;
ok(!status_forbids_body($_), "$_ allows a body")
    for 200, 201, 203, 206, 300, 301, 302, 303, 305, 307, 308, 400, 404, 500, 503;

ok(PAGI::Response->can('status_forbids_body'), 'callable by its full name too');
ok(lives { PAGI::Response->import(':all') }, 'part of :all');

done_testing;
