use strict;
use warnings;
use Test2::V0;
use lib 'lib';
use lib 't/lib';
use PAGITest::Connected qw(ws_scope sse_scope);
use PAGI::HTTPConnection;
use PAGI::WebSocket;
use PAGI::SSE;

# $conn->host is the uri's host: the Host as sent, without its port, never
# validated.

my $receive = sub { };
my $send    = sub { };

my @connections = (
    ['HTTPConnection', sub { PAGI::HTTPConnection->new($_[0]) },  sub { { type => 'http' } }],
    ['WebSocket',      sub { PAGI::WebSocket->new($_[0], $receive, $send) }, \&ws_scope],
    ['SSE',            sub { PAGI::SSE->new($_[0], $receive, $send) },       \&sse_scope],
);

for my $case (@connections) {
    my ($name, $build, $scope_for) = @$case;
    my $host_of = sub {
        my ($headers, %fields) = @_;
        my $scope = { %{ $scope_for->() }, path => '/', raw_path => '/',
            headers => $headers, server => ['10.0.0.5', 80], %fields };
        return $build->($scope)->host;
    };

    subtest $name => sub {
        is($host_of->([['Host', 'example.com:8080']]), 'example.com', 'the port is left off');
        is($host_of->([['Host', '[::1]:8080']]), '[::1]', 'an IPv6 host keeps its brackets');
        is($host_of->([['Host', 'exa mple.com']]), 'exa mple.com', 'a malformed Host is read as sent');
        is($host_of->([]), '10.0.0.5', 'the server address answers without a Host');
    };
}

done_testing;
