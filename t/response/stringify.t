use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::Test::Client;
use PAGI::Tools qw(compose response route);

# A Response says what it is when it is turned into a string -- its class
# and status -- so a thrown page re-raised to the server is logged as a page
# with a status, not as a hash address. The body is not included: it may be
# large, binary, or not the log's to hold.

subtest 'a Response stringifies to its class and status' => sub {
    is '' . response('Text', 'down for maintenance', status => 503), 'PAGI::Response::Text (status 503)';
    is '' . response('JSON', { ok => 1 }), 'PAGI::Response::JSON (status 200)';
    is '' . response('Redirect', '/login'), 'PAGI::Response::Redirect (status 302)';
};

subtest 'and is still itself: true, and equal only to itself' => sub {
    my $one = response('Text', 'a', status => 503);
    my $two = response('Text', 'a', status => 503);
    ok $one, 'true';
    ok $one == $one, 'equal to itself';
    ok !($one == $two), 'not equal to another response of the same class and status';
    is 0 + $one, refaddr($one), 'its number is its address';
};

subtest 'a re-raised thrown page is logged by its class and status' => sub {
    my $app = compose(routes => [route('/' => sub { die response('Text', 'down for maintenance', status => 503) })]);
    my $res;
    my $warnings = warnings { $res = PAGI::Test::Client->new(app => $app)->get('/') };
    is $res->status, 503;
    like $warnings, [qr/\Aexception after response completed: PAGI::Response::Text \(status 503\) at /],
        'the server-side line names the page, not a hash address';
};

done_testing;
