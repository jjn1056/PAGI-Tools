use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use lib 't/lib';
use PAGI::SSE;
use PAGI::Response::Text;
use PAGITest::Connected qw(sse_scope);

# A helper owns the connection from the moment it issues its sse.start or its
# refusal's http.response.start, not from when that send completes. Here the
# server has marked the response started and holds the send's Future, as it
# does under backpressure, while another branch of the same handler sends.

# A helper whose send records each event, marks the response started as a
# server does, and returns $reply->($event) (default: done).
sub helper_with_send {
    my ($reply) = @_;
    my $scope = sse_scope(path => '/events');
    my $connection = $scope->{'pagi.connection'};
    my @sent;
    my $send = sub {
        my ($event) = @_;
        push @sent, $event;
        my $result = $reply ? $reply->($event) : Future->done;
        $connection->_mark_response_started
            if $event->{type} =~ /^(?:sse\.start|http\.response\.start)$/;
        return $result;
    };
    return (PAGI::SSE->new($scope, sub { Future->new }, $send), \@sent);
}

subtest 'during its own pending start a concurrent send_event is sent' => sub {
    my $hold = Future->new;
    my ($sse, $sent) = helper_with_send(sub { $_[0]{type} eq 'sse.start' ? $hold : Future->done });

    my $start = $sse->start;
    ok !$start->is_ready, 'the start is still pending';

    my $event = $sse->send_event(data => 'hello');
    $hold->done;
    $start->get;
    ok lives { $event->get }, 'send_event completes';
    is [map { $_->{type} } @$sent], ['sse.start', 'sse.send'], 'the event follows the start';
    is $sent->[1]{data}, 'hello', 'with its data';
};

# With its start issued the helper is in the "this helper answered" row:
# close behaves as it does after the start, in call order, and the start's
# completion does not reopen the stream or arm a saved keepalive after it.
subtest 'during its own pending start a concurrent close is sent' => sub {
    my $hold = Future->new;
    my ($sse, $sent) = helper_with_send(sub { $_[0]{type} eq 'sse.start' ? $hold : Future->done });
    $sse->keepalive(10)->get;

    my $start = $sse->start;
    my $close;
    ok lives { $close = $sse->close }, 'close lives';
    is [map { $_->{type} } @$sent], ['sse.start', 'sse.close'], 'the close follows the start';

    $hold->done;
    $start->get;
    is [map { $_->{type} } @$sent], ['sse.start', 'sse.close'], 'no keepalive is armed after the close';
    is $sse->connection_state, 'closing', 'the completed start does not undo the close';
    $sse->scope->{'pagi.connection'}->_mark_complete;
    ok lives { $close->get }, 'close completes';
};

subtest 'during its own pending refusal a concurrent send_event fails as refusing' => sub {
    my $hold = Future->new;
    my ($sse, $sent) = helper_with_send(sub { $_[0]{type} eq 'http.response.start' ? $hold : Future->done });

    my $refusal = $sse->decline(PAGI::Response::Text->new('no', status => 403));
    like dies { $sse->send_event(data => 'hello')->get }, qr/^this helper is refusing the connection /,
        'send_event croaks the refusing message, not the ownership one';
    is [map { $_->{type} } @$sent], ['http.response.start'], 'nothing more is sent';

    $hold->done;
    $refusal->get;
    is [map { $_->{type} } @$sent], ['http.response.start', 'http.response.body'],
        'the refusal completes';
};

# D6: a rejected own start raises at its await. The helper keeps the claim it
# recorded when it sent the start and is still treated as the answerer:
# every operation behaves as on a started stream, its sends reach the
# server, and no second sse.start is sent. Rejected before the server
# marked the response started (the send dies) and after it (the send's
# Future fails).
for my $case (
    [dies  => sub { die "start rejected\n" }],
    [fails => sub { Future->fail("start rejected\n") }],
) {
    my ($how, $reject) = @$case;
    subtest "a start whose send $how: it raises, and the helper acts as started" => sub {
        my ($sse, $sent) = helper_with_send(sub { $_[0]{type} eq 'sse.start' ? $reject->() : Future->done });

        like dies { $sse->start->get }, qr/^start rejected$/, 'the start raises the error';
        is $sse->connection_state, 'pending', 'no special state';
        is $sse->scope->{'pagi.connection'}->response_started, ($how eq 'fails' ? 1 : 0),
            'the server marked the response started ' . ($how eq 'fails' ? 'before' : 'never');

        $sse->send('a')->get;
        is $sse->try_send('b')->get, 1, 'try_send sends';
        $sse->keepalive(5)->get;
        $sse->start->get;
        my $close = $sse->close;
        is [map { $_->{type} } @$sent], ['sse.start', 'sse.send', 'sse.send', 'sse.keepalive', 'sse.close'],
            'send, try_send, keepalive and close reach the server; no second sse.start';
        $sse->scope->{'pagi.connection'}->_mark_complete;
        ok lives { $close->get }, 'close completes';
    };
}

done_testing;
