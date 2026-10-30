use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use lib 't/lib';
use PAGI::SSE;
use PAGI::Response::Text;
use PAGITest::Connected qw(sse_scope send_to);

# The second-helper table (the spec's section 3) for SSE, where sse.start is
# the accept: a helper drives only what it answered. Two rows fail locally --
# "another answered, connection open" (RV2, D4) and "this helper is refusing"
# (D7) -- and in every cell that fails locally the helper sends no event and
# reads no receive.

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
            if $event->{type} =~ /^(?:sse\.start|http\.response\.start)$/;
        return $hold{ $event->{type} } // Future->done;
    };
    my $receive = sub {
        $seen{received}++;
        return Future->new;
    };
    my $sse = PAGI::SSE->new($scope, $receive, $send);
    $sse->on_error(sub { $seen{errors}++ });
    return ($sse, \%seen);
}

# Every operation in the table's columns, each run to its result.
my %operation = (
    start            => sub { $_[0]->start->get },
    decline          => sub { $_[0]->decline(PAGI::Response::Text->new('no', status => 403))->get },
    send             => sub { $_[0]->send('x')->get },
    send_json        => sub { $_[0]->send_json({})->get },
    send_event       => sub { $_[0]->send_event(data => 'x')->get },
    send_comment     => sub { $_[0]->send_comment('x')->get },
    try_send         => sub { $_[0]->try_send('x')->get },
    try_send_json    => sub { $_[0]->try_send_json({})->get },
    try_send_event   => sub { $_[0]->try_send_event(data => 'x')->get },
    try_send_comment => sub { $_[0]->try_send_comment('x')->get },
    each             => sub { $_[0]->each([1], sub { Future->done })->get },
    run              => sub { $_[0]->run->get },
    every            => sub { $_[0]->every(1, sub { Future->done })->get },
    close            => sub { $_[0]->close->get },
    keepalive        => sub { $_[0]->keepalive(10)->get },
);

my @fails = qw(start decline send send_json send_event send_comment each run every);
my @try = qw(try_send try_send_json try_send_event try_send_comment);

subtest 'another answered, connection open: every operation fails locally' => sub {
    for my $name (@fails, qw(close keepalive)) {
        my $scope = sse_scope(path => '/events');
        my @first;
        PAGI::SSE->new($scope, sub { Future->new }, send_to($scope, \@first))->start->get;
        my ($sse, $seen) = recording_helper($scope);

        like dies { $operation{$name}->($sse) }, $ANOTHER, "$name croaks the ownership message";
        is $seen->{sent}, [], "$name sends nothing";
        is $seen->{received}, 0, "$name reads no receive";
        is [map { $_->{type} } @first], ['sse.start'], "$name leaves the answering helper alone";
    }
};

subtest 'another answered, connection open: try_send* return 0' => sub {
    for my $name (@try) {
        my $scope = sse_scope(path => '/events');
        PAGI::SSE->new($scope, sub { Future->new }, send_to($scope, []))->start->get;
        my ($sse, $seen) = recording_helper($scope);

        is $operation{$name}->($sse), 0, "$name returns 0";
        is $seen->{sent}, [], "$name sends nothing";
        is $seen->{received}, 0, "$name reads no receive";
        is $seen->{errors}, 0, "$name reports no error";
    }
};

# The helper's own refusal is in progress: its http.response.start is sent and
# held, so the connection is open and the response started.
sub refusing_helper {
    my $hold = Future->new;
    my ($sse, $seen) = recording_helper(sse_scope(path => '/events'), 'http.response.start' => $hold);
    my $refusal = $sse->decline(PAGI::Response::Text->new('no', status => 403));
    return ($sse, $seen, $refusal, $hold);
}

subtest 'this helper is refusing: data operations fail locally' => sub {
    for my $name (@fails) {
        my ($sse, $seen, $refusal, $hold) = refusing_helper();

        like dies { $operation{$name}->($sse) }, $REFUSING, "$name croaks the refusing message";
        is [map { $_->{type} } @{ $seen->{sent} }], ['http.response.start'],
            "$name sends nothing of its own";
        is $seen->{received}, 0, "$name reads no receive";

        $hold->done;
        $refusal->get;
        is [map { $_->{type} } @{ $seen->{sent} }], ['http.response.start', 'http.response.body'],
            "the refusal still completes after $name";
    }
};

subtest 'this helper is refusing: try_send* return 0' => sub {
    for my $name (@try) {
        my ($sse, $seen, $refusal, $hold) = refusing_helper();

        is $operation{$name}->($sse), 0, "$name returns 0";
        is [map { $_->{type} } @{ $seen->{sent} }], ['http.response.start'], "$name sends nothing";
        is $seen->{received}, 0, "$name reads no receive";
        $hold->done;
        $refusal->get;
    }
};

subtest 'this helper is refusing: close and keepalive return quietly' => sub {
    for my $name (qw(close keepalive)) {
        my ($sse, $seen, $refusal, $hold) = refusing_helper();

        ok lives { $operation{$name}->($sse) }, "$name lives";
        is [map { $_->{type} } @{ $seen->{sent} }], ['http.response.start'], "$name sends nothing";
        is $seen->{received}, 0, "$name reads no receive";
        $hold->done;
        $refusal->get;
    }
};

# A refusal that settles with no response started answered nothing: the helper
# holds no claim, so once another helper answers, it is told so.
subtest 'a refusal that started nothing leaves no claim behind' => sub {
    my $scope = sse_scope(path => '/events');
    my ($sse, $seen) = recording_helper($scope);
    like dies { $sse->decline(sub { die "handler failed\n" })->get }, qr/^handler failed$/,
        'the refusal fails before its response start';
    PAGI::SSE->new($scope, sub { Future->new }, send_to($scope, []))->start->get;

    like dies { $sse->send_event(data => 'x')->get }, $ANOTHER, 'send_event croaks the ownership message';
    is $seen->{sent}, [], 'sends nothing';
};

done_testing;
