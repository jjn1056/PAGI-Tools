use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw(refaddr);

use lib 'lib';
use lib 't/lib';
use PAGI::WebSocket;
use PAGI::SSE;
use PAGITest::Connected qw(ws_scope sse_scope receive_from send_to);

# PAGI::WebSocket and PAGI::SSE are PAGI::HTTPConnections: what they read from
# the scope comes from the base, parsed once per object, and nothing is written
# to the scope -- not the object, not its query, not its headers. Each new
# builds a new object (RV1), as Starlette builds one WebSocket per connection.

my %class_for  = (websocket => 'PAGI::WebSocket', sse => 'PAGI::SSE');
my %scope_for  = (websocket => \&ws_scope, sse => \&sse_scope);
my %events_for = (
    websocket => [ { type => 'websocket.connect' } ],
    sse       => [],
);

sub build {
    my ($type, %scope) = @_;
    my $scope = $scope_for{$type}->(%scope);
    my @sent;
    my $object = $class_for{$type}->new($scope,
        receive_from($scope, @{ $events_for{$type} }), send_to($scope, \@sent));
    return ($object, $scope, \@sent);
}

for my $type (qw(websocket sse)) {
    my $class = $class_for{$type};

    subtest "$class is a PAGI::HTTPConnection" => sub {
        my ($object) = build($type, path => '/x');
        isa_ok($object, ['PAGI::HTTPConnection'], $class);
        ok(!defined &{"${class}::path"}, "$class has no path of its own");
        ok(!defined &{"${class}::_url_decode"}, "$class has no _url_decode of its own");
        ok(!defined &{"${class}::_decode_utf8"}, "$class has no _decode_utf8 of its own");
    };

    subtest "$class: two new calls over one scope build two objects (RV1)" => sub {
        my $scope = $scope_for{$type}->(path => '/x');
        my $first  = $class->new($scope, receive_from($scope), send_to($scope, []));
        my $second = $class->new($scope, receive_from($scope), send_to($scope, []));
        isnt(refaddr($second), refaddr($first), 'a second object');
        is(refaddr($second->scope), refaddr($scope), 'over the same scope');
    };

    subtest "$class: nothing is written to the scope" => sub {
        my ($object, $scope, $sent) = build($type,
            path         => '/x',
            query_string => 'a=1&b=%FF',
            headers      => [ ['X-Trace', 'one'], ['Cookie', 'c=3'] ],
        );
        my @keys = sort keys %$scope;

        my $query = $object->query_params;
        $object->query_params(strict => 0);
        $object->raw_query_params;
        my $headers = $object->headers;
        $object->header('x-trace');
        $object->cookies;
        if ($type eq 'websocket') {
            $object->accept->get;
            $object->send_text('hi')->get;
        }
        else {
            $object->start->get;
            $object->send('hi')->get;
        }
        $object->close->get;

        is([sort keys %$scope], \@keys, 'the scope has the keys it was built with');
        is([grep { /^pagi\.(?:websocket|sse|request\.headers)/ } keys %$scope], [],
            'no object, query or header cache in the scope');
        is(refaddr($object->query_params), refaddr($query), 'the query parse is kept on the object');
        is(refaddr($object->headers), refaddr($headers), 'the header parse is kept on the object');
    };

    subtest "$class has cookies and cookie" => sub {
        my ($object) = build($type, path => '/x',
            headers => [ ['Cookie', 'a=1; b="two"'], ['Cookie', 'a=3'] ]);
        is($object->cookies, { a => '3', b => 'two' }, 'every Cookie field, the last a wins');
        is($object->cookie('b'), 'two', 'one cookie');
    };

    subtest "$class: path_param is strict (D3)" => sub {
        my ($object) = build($type, path => '/r/lobby', path_params => { room_id => 'lobby' });
        is($object->path_param('room_id'), 'lobby', 'a known name');
        like(dies { $object->path_param('room') },
            qr/path_param 'room' not found\. Available: room_id/,
            'an unknown name dies naming the available ones');
        is($object->path_param('room', strict => 0), undef, 'strict => 0 gives undef');
    };

    subtest "$class: a scope with no path dies where the path is read (D2)" => sub {
        my ($object) = build($type);
        like(dies { $object->path }, qr/this scope has no path/, 'path dies');
    };
}

done_testing;
