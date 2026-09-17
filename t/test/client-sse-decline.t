use strict; use warnings; use Test2::V0; use Future::AsyncAwait;
use PAGI::Test::Client;

subtest 'ordinary HTTP refusal returns Test::Response and reasonless end events' => sub {
    my ($conn, @received);
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $conn = $scope->{'pagi.connection'} or die 'no connection object';
        await $send->({
            type => 'http.response.start',
            status => 404,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({ type => 'http.response.body', body => 'Not Found', more => 0 });
        die 'terminal refusal send did not complete scope' unless $conn->response_complete;

        # Explicit finite tripwire for repeated end delivery.
        for my $attempt (1 .. 2) {
            push @received, await $receive->();
        }
    };

    my $res = PAGI::Test::Client->new(app => $app)->sse('/events');

    isa_ok $res, ['PAGI::Test::Response'];
    is $res->status, 404, 'refusal status';
    is $res->content, 'Not Found', 'refusal body';
    is \@received, [
        { type => 'sse.disconnect' },
        { type => 'sse.disconnect' },
    ], 'completed refusal reports a clean, reasonless SSE end';
};

subtest 'refusal response uses the captured response decoder for file bodies' => sub {
    my $path = __FILE__;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 403, headers => [] });
        await $send->({
            type => 'http.response.body', file => $path, offset => 0, length => 3,
        });
    };

    my $res = PAGI::Test::Client->new(app => $app)->sse('/events');
    is $res->content, 'use', 'file window decoded by Test::Response';
};

subtest 'peer close is abnormal and repeats its end event' => sub {
    my ($conn, @order, @received);
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $conn = $scope->{'pagi.connection'};
        $conn->on_disconnect(sub { push @order, "callback:$_[0]" });
        await $send->({ type => 'sse.start', status => 200, headers => [] });
        for my $attempt (1 .. 2) {
            push @received, await $receive->();
            push @order, 'receive:' . ($conn->disconnect_reason // 'none');
        }
    };

    my $sse = PAGI::Test::Client->new(app => $app)->sse('/events');
    $sse->close;

    is \@order, [
        'callback:client_closed',
        'receive:client_closed',
        'receive:client_closed',
    ], 'state transition and callback precede receive wakes';
    is $received[0], { type => 'sse.disconnect', reason => 'client_closed' },
        'peer close event';
    is $received[1], $received[0], 'peer close event repeats';
    is $conn->response_complete, 0, 'peer disconnect is abnormal';
};

subtest 'sse.close is clean before send returns and wakes with reasonless end' => sub {
    my ($conn, @received);
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $conn = $scope->{'pagi.connection'};
        await $send->({ type => 'sse.start', status => 200, headers => [] });
        await $send->({ type => 'sse.close' });
        die 'sse.close did not complete scope' unless $conn->response_complete;
        for my $attempt (1 .. 2) {
            push @received, await $receive->();
        }
    };

    my $sse = PAGI::Test::Client->new(app => $app)->sse('/events');
    ok $sse->is_closed, 'stream closed';
    is \@received, [
        { type => 'sse.disconnect' },
        { type => 'sse.disconnect' },
    ], 'clean stream end is reasonless and repeatable';
    is $conn->disconnect_reason, undef, 'clean stream end has no abnormal reason';
};

subtest 'abort closes transport and wakes pending and later receives' => sub {
    my ($conn, @received);
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $conn = $scope->{'pagi.connection'};
        await $send->({ type => 'sse.start', status => 200, headers => [] });
        for my $attempt (1 .. 2) {
            push @received, await $receive->();
        }
    };

    my $sse = PAGI::Test::Client->new(app => $app)->sse('/events');
    $conn->abort('cancelled subscription');

    ok $sse->is_closed, 'abort closes SSE transport';
    is $conn->disconnect_reason, 'app_abort', 'abort reason';
    is $conn->disconnect_detail, 'cancelled subscription', 'abort detail';
    is $received[0], { type => 'sse.disconnect', reason => 'app_abort' },
        'pending receive gets app_abort';
    is $received[1], $received[0], 'later receive repeats app_abort';
};

done_testing;
