use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use PAGI::WebSocket;
use PAGI::Response::Text;
use lib 't/lib';
use PAGITest::RefusalHarness;

# An ordinary HTTP denial sends a response, not a WebSocket
# close frame, so there is no RFC6455 close code — close_code must be undef
# after deny(). Before accept, close() must direct callers to deny().

sub recorder { my @e; my $s = sub { push @e, $_[0]; Future->done }; return ($s, \@e) }

subtest 'deny() with denial-response support: closed, but no close code' => sub {
    my $h = PAGITest::RefusalHarness->new('websocket');
    my $ws = $h->{helper};
    my $sent = $h->{events};

    $ws->deny(PAGI::Response::Text->new('Unauthorized', status => 401))->get;

    ok $ws->is_closed, 'connection is closed after deny';
    is $ws->close_code, undef, 'no RFC6455 close code for an HTTP denial (not 401)';
    is $sent->[0]{type}, 'http.response.start', 'ordinary HTTP denial response emitted';
    is $sent->[0]{status}, 401, 'the 401 still goes out as the HTTP status';
};

subtest 'close() before accept croaks and sends nothing' => sub {
    my ($send, $sent) = recorder();
    my $scope = { type => 'websocket', path => '/ws', headers => [] };   # no extension
    my $ws = PAGI::WebSocket->new($scope, sub { Future->done }, $send);

    like dies { $ws->close(1008, 'policy')->get },
        qr/WebSocket close is only valid after accept; use deny/,
        'pre-accept close gives denial guidance';
    is $sent, [], 'pre-accept close sends nothing';
};

done_testing;
