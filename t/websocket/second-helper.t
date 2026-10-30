use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use lib 't/lib';
use PAGI::WebSocket;
use PAGI::Response::Text;
use PAGITest::Connected qw(ws_scope send_to);

# The second-helper table (the spec's section 3): a helper drives only what
# it answered. Two rows fail locally -- "another answered, connection open"
# (RV2, D4) and "this helper is refusing" (D7) -- and in every cell that
# fails locally the helper sends no event and reads no receive.

my $ANOTHER  = qr/^this connection was answered by another helper; use that one /;
my $REFUSING = qr/^this helper is refusing the connection /;

# A helper whose send records each event and marks the response started as a
# server does, holding the send of any event type given in %hold until that
# Future is done; and whose receive counts its calls.
sub recording_helper {
    my ($scope, %hold) = @_;
    my $connection = $scope->{'pagi.connection'};
    my %seen = (sent => [], received => 0, errors => 0);
    my $send = sub {
        my ($event) = @_;
        push @{ $seen{sent} }, $event;
        $connection->_mark_response_started
            if $event->{type} =~ /^(?:websocket\.accept|http\.response\.start)$/;
        return $hold{ $event->{type} } // Future->done;
    };
    my $receive = sub {
        $seen{received}++;
        return Future->done({ type => 'websocket.receive', text => '{}' });
    };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->on_error(sub { $seen{errors}++ });
    return ($ws, \%seen);
}

# Every operation in the table's columns, each run to its result.
my %operation = (
    accept         => sub { $_[0]->accept->get },
    deny           => sub { $_[0]->deny(PAGI::Response::Text->new('no', status => 403))->get },
    send_text      => sub { $_[0]->send_text('x')->get },
    send_bytes     => sub { $_[0]->send_bytes('x')->get },
    send_json      => sub { $_[0]->send_json({})->get },
    try_send_text  => sub { $_[0]->try_send_text('x')->get },
    try_send_bytes => sub { $_[0]->try_send_bytes('x')->get },
    try_send_json  => sub { $_[0]->try_send_json({})->get },
    receive        => sub { $_[0]->receive->get },
    receive_text   => sub { $_[0]->receive_text->get },
    receive_bytes  => sub { $_[0]->receive_bytes->get },
    receive_json   => sub { $_[0]->receive_json->get },
    each_message   => sub { $_[0]->each_message(sub { Future->done })->get },
    each_text      => sub { $_[0]->each_text(sub { Future->done })->get },
    each_bytes     => sub { $_[0]->each_bytes(sub { Future->done })->get },
    each_json      => sub { $_[0]->each_json(sub { Future->done })->get },
    run            => sub { $_[0]->run->get },
    close          => sub { $_[0]->close(1000, 'bye')->get },
    close_or_deny  => sub { $_[0]->close_or_deny(1000, 'bye')->get },
    keepalive      => sub { $_[0]->keepalive(10)->get },
);

my @fails = qw(accept deny send_text send_bytes send_json receive receive_text
    receive_bytes receive_json each_message each_text each_bytes each_json run);
my @try = qw(try_send_text try_send_bytes try_send_json);

subtest 'another answered, connection open: every operation fails locally' => sub {
    for my $name (@fails, qw(close close_or_deny keepalive)) {
        my $scope = ws_scope(path => '/ws');
        my @first;
        PAGI::WebSocket->new($scope, sub { Future->new }, send_to($scope, \@first))
            ->accept->get;
        my ($ws, $seen) = recording_helper($scope);

        like dies { $operation{$name}->($ws) }, $ANOTHER, "$name croaks the ownership message";
        is $seen->{sent}, [], "$name sends nothing";
        is $seen->{received}, 0, "$name reads no receive";
        is \@first, [{ type => 'websocket.accept' }], "$name leaves the answering helper alone";
    }
};

subtest 'another answered, connection open: try_send_* return 0' => sub {
    for my $name (@try) {
        my $scope = ws_scope(path => '/ws');
        PAGI::WebSocket->new($scope, sub { Future->new }, send_to($scope, []))->accept->get;
        my ($ws, $seen) = recording_helper($scope);

        is $operation{$name}->($ws), 0, "$name returns 0";
        is $seen->{sent}, [], "$name sends nothing";
        is $seen->{received}, 0, "$name reads no receive";
        is $seen->{errors}, 0, "$name reports no error";
    }
};

# The helper's own refusal is in progress: its http.response.start is sent and
# held, so the connection is open and the response started.
sub refusing_helper {
    my $hold = Future->new;
    my ($ws, $seen) = recording_helper(ws_scope(path => '/ws'), 'http.response.start' => $hold);
    my $refusal = $ws->deny(PAGI::Response::Text->new('no', status => 403));
    return ($ws, $seen, $refusal, $hold);
}

subtest 'this helper is refusing: data operations fail locally' => sub {
    for my $name (@fails) {
        my ($ws, $seen, $refusal, $hold) = refusing_helper();

        like dies { $operation{$name}->($ws) }, $REFUSING, "$name croaks the refusing message";
        is [map { $_->{type} } @{ $seen->{sent} }], ['http.response.start'],
            "$name sends nothing of its own";
        is $seen->{received}, 0, "$name reads no receive";

        $hold->done;
        $refusal->get;
        is [map { $_->{type} } @{ $seen->{sent} }], ['http.response.start', 'http.response.body'],
            "the refusal still completes after $name";
    }
};

subtest 'this helper is refusing: try_send_* return 0' => sub {
    for my $name (@try) {
        my ($ws, $seen, $refusal, $hold) = refusing_helper();

        is $operation{$name}->($ws), 0, "$name returns 0";
        is [map { $_->{type} } @{ $seen->{sent} }], ['http.response.start'], "$name sends nothing";
        is $seen->{received}, 0, "$name reads no receive";
        $hold->done;
        $refusal->get;
    }
};

subtest 'this helper is refusing: close, close_or_deny, keepalive return quietly' => sub {
    for my $name (qw(close close_or_deny keepalive)) {
        my ($ws, $seen, $refusal, $hold) = refusing_helper();

        ok lives { $operation{$name}->($ws) }, "$name lives";
        is [map { $_->{type} } @{ $seen->{sent} }], ['http.response.start'], "$name sends nothing";
        is $seen->{received}, 0, "$name reads no receive";
        $hold->done;
        $refusal->get;
    }
};

# A refusal that settles with no response started answered nothing: the helper
# holds no claim, so once another helper answers, it is told so.
subtest 'a refusal that started nothing leaves no claim behind' => sub {
    my $scope = ws_scope(path => '/ws');
    my ($ws, $seen) = recording_helper($scope);
    like dies { $ws->deny(sub { die "handler failed\n" })->get }, qr/^handler failed$/,
        'the refusal fails before its response start';
    PAGI::WebSocket->new($scope, sub { Future->new }, send_to($scope, []))->accept->get;

    like dies { $ws->send_text('x')->get }, $ANOTHER, 'send_text croaks the ownership message';
    is $seen->{sent}, [], 'sends nothing';
};

done_testing;
