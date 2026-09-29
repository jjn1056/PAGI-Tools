use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use lib 't/lib';
use PAGI::SSE;
use PAGI::WebSocket;
use PAGITest::Connected qw(ws_scope sse_scope send_to);

# When the connection ends, each helper starts its on_close hooks from the
# connection's on_end. A hook that is still suspended at that point finishes
# later, and the Future tracking that cleanup must be kept, not dropped. A
# Future implementation that tracks dropped Futures warns "lost a sequence
# Future" when one completes; any warning here fails the test.

for my $kind (qw(sse websocket)) {
    subtest "$kind: an on_close hook suspended past connection end completes quietly" => sub {
        my $scope = $kind eq 'sse' ? sse_scope() : ws_scope();
        my $class = $kind eq 'sse' ? 'PAGI::SSE' : 'PAGI::WebSocket';
        my @sent;
        my $helper = $class->new($scope, sub { Future->new }, send_to($scope, \@sent));
        ($kind eq 'sse' ? $helper->start : $helper->accept)->get;

        my $gate = Future->new;
        my $cleaned = 0;
        $helper->on_close(async sub { await $gate; $cleaned = 1 });

        my @warnings;
        {
            local $SIG{__WARN__} = sub { push @warnings, @_ };
            $scope->{'pagi.connection'}->_mark_disconnected('client_closed');
            ok(!$cleaned, 'the hook is still suspended when the connection ends');
            $gate->done;
        }

        ok($cleaned, 'the hook finishes once it resumes');
        is(\@warnings, [], 'no Future was dropped along the way');
    };
}

done_testing;
