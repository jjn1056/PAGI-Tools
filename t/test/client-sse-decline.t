use strict; use warnings; use Test2::V0; use Future::AsyncAwait;
use PAGI::Test::Client;

# ---------------------------------------------------------------------------
# B7: PAGI::Test::SSE recognizes a decline (sse.http.response.start/.body),
# mirroring the server: the client API gets back a PAGI::Test::Response with
# that status/body, never a croak, and no sse.disconnect is ever delivered
# (the stream never started, so there is nothing to disconnect from).
# ---------------------------------------------------------------------------

subtest 'B7(a): sse decline returns a Test::Response, no croak, no sse.disconnect' => sub {
    my $pending_future;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'sse.http.response.start',
            status  => 404,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({ type => 'sse.http.response.body', body => 'Not Found', more => 0 });
        $pending_future = $receive->(); # must NOT be awaited: would hang forever
    };

    my $client = PAGI::Test::Client->new(app => $app);
    my $res;
    ok lives { $res = $client->sse('/events') }, 'no croak for a decline'
        or note $@;
    isa_ok $res, ['PAGI::Test::Response'];
    is $res->status, 404, 'decline status';
    is $res->content, 'Not Found', 'decline body';

    ok defined $pending_future, 'app captured a receive Future';
    ok !$pending_future->is_ready, 'receive stays pending: no sse.disconnect delivered on a decline';
};

# ---------------------------------------------------------------------------
# B7(b): sse.close is honored: closed state is set, and exactly one
# reason-carrying sse.disconnect is delivered (default reason client_closed
# when the test does not supply one), never repeated.
# ---------------------------------------------------------------------------

subtest 'B7(b): sse.close honored -- closed state, one reason-carrying sse.disconnect' => sub {
    my (@received, $pending_future);
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'sse.start', status => 200, headers => [] });
        push @received, await $receive->();
        $pending_future = $receive->(); # must NOT be awaited: would hang forever
    };

    my $client = PAGI::Test::Client->new(app => $app);
    my $sse = $client->sse('/events');
    $sse->close;

    ok $sse->is_closed, 'closed state set';
    is scalar(@received), 1, 'exactly one disconnect delivered';
    is $received[0]{type}, 'sse.disconnect', 'disconnect event type';
    is $received[0]{reason}, 'client_closed', 'default reason is client_closed';
    ok !$pending_future->is_ready, 'further receive stays pending';
};

subtest 'B7(b): sse.close with an explicit reason is threaded through' => sub {
    my @received;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'sse.start', status => 200, headers => [] });
        push @received, await $receive->();
    };

    my $client = PAGI::Test::Client->new(app => $app);
    my $sse = $client->sse('/events');
    $sse->close('idle_timeout');

    is $received[0]{reason}, 'idle_timeout', 'explicit reason is threaded through';
};

subtest 'B7(b): repeated close is idempotent, no repeat sse.disconnect' => sub {
    my @received;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'sse.start', status => 200, headers => [] });
        push @received, await $receive->();
    };

    my $client = PAGI::Test::Client->new(app => $app);
    my $sse = $client->sse('/events');
    $sse->close;
    $sse->close; # idempotent: must not deliver a second disconnect or die

    is scalar(@received), 1, 'still exactly one disconnect after a repeated close call';
};

done_testing;
