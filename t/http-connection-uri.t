use strict;
use warnings;
use utf8;
use Test2::V0;
use Scalar::Util qw(refaddr);
use lib 'lib';
use lib 't/lib';
use PAGITest::Connected qw(ws_scope sse_scope);
use PAGI::HTTPConnection;
use PAGI::WebSocket;
use PAGI::SSE;

# $conn->uri is the request's URL as a PAGI::Utils::URI, and $conn->base_uri
# the application's root: both kept on the connection, never in the scope.

sub scope_of {
    my ($type, %fields) = @_;
    return {
        type         => $type,
        scheme       => 'https',
        root_path    => '/app',
        path         => '/items/42',
        raw_path     => '/app/items/42',
        query_string => 'x=1',
        headers      => [['host', 'example.com']],
        server       => ['10.0.0.5', 443],
        %fields,
    };
}

# A deep copy of a scope's plain data, to show the scope is untouched.
sub snapshot {
    my ($scope) = @_;
    return { map { $_ => (ref $scope->{$_} eq 'ARRAY' ? [map { ref $_ ? [@$_] : $_ } @{$scope->{$_}}] : $scope->{$_}) } keys %$scope };
}

subtest 'uri' => sub {
    my $scope = scope_of('http');
    my $before = snapshot($scope);
    my $conn = PAGI::HTTPConnection->new($scope);

    my $uri = $conn->uri;
    isa_ok($uri, 'PAGI::Utils::URI');
    is("$uri", 'https://example.com/app/items/42?x=1', 'the request URL');
    is($uri->path, '/app/items/42', 'its path has the root path');
    is(refaddr($conn->uri), refaddr($uri), 'the same object twice');

    my $base = $conn->base_uri;
    is(refaddr($conn->base_uri), refaddr($base), 'base_uri: the same object twice');

    is($scope, $before, 'the scope has no new keys and no changed values');
};

subtest 'uri keeps a leading // in the request path' => sub {
    my $conn = PAGI::HTTPConnection->new(scope_of('http',
        scheme => 'http', root_path => '', path => '//evil/x', raw_path => '//evil/x',
        query_string => 'a=1', headers => [['host', 'h']]));
    my $uri = $conn->uri;
    is("$uri", 'http://h//evil/x?a=1', 'the request URL as sent');
    is($uri->path, '//evil/x', 'path');
    is($uri->raw_path, '//evil/x', 'raw_path agrees');
    is($uri->path_query, '/evil/x?a=1', 'path_query is held to one /');
    is($conn->request_uri, '/evil/x?a=1', 'request_uri is too');
    is("" . $conn->base_uri, 'http://h/', 'base_uri is the root, whatever the path');
    is("" . $uri->join_path('y'), 'http://h//evil/x/y?a=1', 'join_path keeps the //');
    is($uri->join_path('y')->path_query, '/evil/x/y?a=1', 'and path_query has one /');
};

subtest 'base_uri' => sub {
    my $base = PAGI::HTTPConnection->new(scope_of('http'))->base_uri;
    isa_ok($base, 'PAGI::Utils::URI');
    is("$base", 'https://example.com/app/', 'scheme://authority + the root path + /');
    is($base->query_string, '', 'no query');
    is($base->fragment, '', 'no fragment');
    is($base->path, '/app/', 'path');

    is("" . PAGI::HTTPConnection->new(scope_of('http', root_path => ''))->base_uri,
        'https://example.com/', 'no root path');
    is("" . PAGI::HTTPConnection->new(scope_of('http', root_path => '/app/'))->base_uri,
        'https://example.com/app/', 'a root path ending in / gains no second one');
    is("" . PAGI::HTTPConnection->new(scope_of('http', root_path => '/café', path => '/'))->base_uri,
        'https://example.com/caf%C3%A9/', 'the root path is encoded');
    is("" . PAGI::HTTPConnection->new(scope_of('http', headers => [['host', 'evil.com/x?']]))->base_uri,
        'https://evil.com%2Fx%3F/app/', 'the same lenient, escaped authority as uri');
};

subtest 'every connection has it' => sub {
    my $noop = sub { };

    my $ws = PAGI::WebSocket->new(
        ws_scope(%{ scope_of('websocket', scheme => 'wss', path => '/chat', raw_path => '/app/chat', query_string => '') }),
        $noop, $noop);
    is("" . $ws->uri, 'wss://example.com/app/chat', 'a websocket scope with scheme wss');
    is("" . $ws->base_uri, 'wss://example.com/app/', 'and its base');

    my $sse = PAGI::SSE->new(sse_scope(%{ scope_of('sse') }), $noop, $noop);
    is("" . $sse->uri, 'https://example.com/app/items/42?x=1', 'an sse scope');
};

subtest 'base_uri is built once, whatever the value stringifies to' => sub {
    my $conn = PAGI::HTTPConnection->new(scope_of('http'));
    my $base = $conn->base_uri;
    no warnings 'redefine';
    local *PAGI::Utils::URI::to_string = sub { '' };
    is(refaddr($conn->base_uri), refaddr($base), 'a value whose string form is false is still kept');
};

subtest 'a scope with no path' => sub {
    my $conn = PAGI::HTTPConnection->new({ type => 'http', headers => [['host', 'example.com']] });
    like(dies { $conn->uri }, qr/\Athis scope has no path at .*http-connection-uri\.t line /,
        'uri dies where it is read, naming the caller');
    like(dies { $conn->base_uri }, qr/\Athis scope has no path at .*http-connection-uri\.t line /,
        'and so does base_uri');

    $conn = PAGI::HTTPConnection->new({ type => 'http', path => '/' });
    like(dies { $conn->uri }, qr/\Ano Host header, and the scope server cannot provide an authority at .*http-connection-uri\.t line /,
        'neither a Host nor a server address: uri dies naming the caller');
};

done_testing;
