use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use lib 't/lib';
use PAGI::Endpoint::WebSocket;
use PAGI::Endpoint::SSE;
use PAGI::WebSocket;
use PAGI::SSE;
use PAGI::Response::Text;
use PAGITest::Connected qw(ws_scope sse_scope);

# An endpoint whose on_connect refuses the connection (deny / decline) is
# done once the refusal returns. A server may still report the connection
# open then (PAGI-Server's HTTP/2 path marks completion only after the final
# send), and a refusing helper's receive and run fail locally (D7), so the
# endpoint must not go on to read messages or wait in run.

package Local::DenyingWS {
    use parent 'PAGI::Endpoint::WebSocket';
    use Future::AsyncAwait;
    our $received = 0;
    async sub on_connect {
        my ($self, $ws) = @_;
        await $ws->deny(PAGI::Response::Text->new('go away', status => 403));
    }
    async sub on_receive { $received++ }
}

package Local::DecliningSSE {
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;
    async sub on_connect {
        my ($self, $sse) = @_;
        await $sse->decline(PAGI::Response::Text->new('no stream', status => 403));
    }
}

package main;

# A send that records each event and marks the response started, and never
# marks the connection ended.
sub open_send {
    my ($scope, $sent) = @_;
    my $connection = $scope->{'pagi.connection'};
    return sub {
        push @$sent, $_[0];
        $connection->_mark_response_started if $_[0]{type} eq 'http.response.start';
        return Future->done;
    };
}

subtest 'a WebSocket endpoint that denies in on_connect reads no message' => sub {
    my $scope = ws_scope(path => '/ws');
    my (@sent, $reads);
    my $ws = PAGI::WebSocket->new($scope, sub { $reads++; Future->new }, open_send($scope, \@sent));

    ok lives { Local::DenyingWS->new->handle($ws)->get }, 'handle returns after the refusal';
    ok $scope->{'pagi.connection'}->is_connected, 'the connection is still open';
    is [map { $_->{type} } @sent], ['http.response.start', 'http.response.body'], 'the refusal was sent';
    is $reads, undef, 'receive was never read';
    is $Local::DenyingWS::received, 0, 'on_receive never ran';
};

subtest 'an SSE endpoint that declines in on_connect does not wait in run' => sub {
    my $scope = sse_scope(path => '/events');
    my @sent;
    my $sse = PAGI::SSE->new($scope, sub { Future->new }, open_send($scope, \@sent));

    my $handled = Local::DecliningSSE->new->handle($sse);
    ok $handled->is_ready, 'handle returns after the refusal';
    ok lives { $handled->get }, 'without an error';
    ok $scope->{'pagi.connection'}->is_connected, 'the connection is still open';
    is [map { $_->{type} } @sent], ['http.response.start', 'http.response.body'], 'the refusal was sent';
};

done_testing;
