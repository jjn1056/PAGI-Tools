use strict;
use warnings;
use Test2::V0;
use Future;

use lib 't/lib';
use PAGITest::Connected qw(ws_scope sse_scope);
use PAGI::WebSocket;
use PAGI::SSE;

# try_send_* are the best-effort sends for broadcast loops: they never throw,
# so a caller may make one and drop the returned Future. The send must still
# go out, and nothing may complain, even when it has to wait its turn behind
# a send already in flight.

sub controlled_send {
    my @issued;
    my $send = sub {
        push @issued, { event => $_[0], future => Future->new };
        return $issued[-1]{future};
    };
    return ($send, \@issued);
}

sub settle_all {
    my ($issued) = @_;
    while (my ($pending) = grep { !$_->{future}->is_ready } @$issued) {
        $pending->{future}->done;
    }
}

my @cases = (
    [ 'PAGI::WebSocket', try_send_text  => ['hi'] ],
    [ 'PAGI::WebSocket', try_send_bytes => ['hi'] ],
    [ 'PAGI::WebSocket', try_send_json  => [{ n => 1 }] ],
    [ 'PAGI::SSE',       try_send         => ['hi'] ],
    [ 'PAGI::SSE',       try_send_json    => [{ n => 1 }] ],
    [ 'PAGI::SSE',       try_send_comment => ['hi'] ],
    [ 'PAGI::SSE',       try_send_event   => [data => 'hi'] ],
);

for my $case (@cases) {
    my ($class, $method, $args) = @$case;
    subtest "$class->$method, its Future dropped" => sub {
        my ($send, $issued) = controlled_send();
        my $conn;
        if ($class eq 'PAGI::WebSocket') {
            $conn = PAGI::WebSocket->new(ws_scope(), sub { Future->new }, $send);
            my $accepting = $conn->accept;
            settle_all($issued);
            $accepting->get;
        }
        else {
            $conn = PAGI::SSE->new(sse_scope(), sub { Future->new }, $send);
            my $starting = $conn->start;
            settle_all($issued);
            $starting->get;
        }

        my $in_flight = $class eq 'PAGI::WebSocket'
            ? $conn->send_text('first') : $conn->send_event(data => 'first');
        my $before = @$issued;

        my @warnings;
        {
            local $SIG{__WARN__} = sub { push @warnings, @_ };
            $conn->$method(@$args);    # fire and forget
            settle_all($issued);
        }

        is(scalar(@$issued), $before + 1, 'the send still goes out, after the one in flight');
        ok($in_flight->is_done, 'which completed first');
        is(\@warnings, [], 'and nothing complains');
    };
}

done_testing;
