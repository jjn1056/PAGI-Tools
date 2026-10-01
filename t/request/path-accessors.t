use strict;
use warnings;
use Test2::V0;
use Future;
use lib 'lib';
use PAGI::Request;
use PAGI::WebSocket;
use PAGI::SSE;
use PAGI::Test::ConnectionState;

# Every connection object exposes the scope helpers, and without a
# raw_path in the scope raw_path is the full path (root_path and path,
# encoded), not the mount-relative path.

my $receive = sub { Future->done({ type => 'http.disconnect' }) };
my $send    = sub { Future->done };
my %base = (path => '/users', root_path => '/admin', query_string => 'x=1', headers => [],
    pagi => { version => '0.5', spec_version => '0.6' });

my @objects = (
    [ Request   => PAGI::Request->new({ %base, type => 'http', method => 'GET' }, $receive) ],
    [ WebSocket => PAGI::WebSocket->new({ %base, type => 'websocket',
        'pagi.connection' => PAGI::Test::ConnectionState->new(websocket => 1) }, $receive, $send) ],
    [ SSE       => PAGI::SSE->new({ %base, type => 'sse', method => 'GET',
        'pagi.connection' => PAGI::Test::ConnectionState->new }, $receive, $send) ],
);
for my $row (@objects) {
    my ($name, $obj) = @$row;
    is($obj->raw_path, '/admin/users', "$name raw_path without a scope raw_path");
    is($obj->request_uri, '/admin/users?x=1', "$name request_uri");
    is($obj->raw_path_info, '/users', "$name raw_path_info");
}

my $with_raw = PAGI::Request->new({ %base, type => 'http', method => 'GET',
    raw_path => '/%61dmin/users' }, $receive);
is([$with_raw->raw_path, $with_raw->request_uri, $with_raw->raw_path_info],
   ['/%61dmin/users', '/%61dmin/users?x=1', '/users'], 'a scope raw_path is used as sent');

done_testing;
