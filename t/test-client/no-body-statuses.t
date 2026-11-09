use v5.24;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use PAGI::Test::Client;

# PAGI::Spec::Www, "Statuses Without Content": on a 204 or 304 response
# the server writes no body bytes, opens no file or fh, and accepts and
# discards trailers, as it does for HEAD. The client does what a server does.

# An application that answers with $status and whatever body events it's given.
sub answering {
    my ($status, %start) = @_;
    my @events = @{ delete $start{events} // [{ type => 'http.response.body', body => 'abc', more => 0 }] };
    return async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => $status, headers => [], %start });
        for my $event (@events) { await $send->($event) }
    };
}

sub get { PAGI::Test::Client->new(app => $_[0])->get('/') }

subtest 'the body is suppressed' => sub {
    for my $status (204, 304) {
        my $res = get(answering($status));
        is $res->status, $status, "$status served";
        is $res->content, '', "$status: no body";
        ok !$res->exception, "$status: the request completes";
    }
};

subtest 'other statuses keep their body' => sub {
    is get(answering(200))->content, 'abc', '200';
    is get(answering(205))->content, 'abc', '205 is framed like any other: the application keeps its rule';
};

subtest 'headers are sent as given' => sub {
    my $res = get(answering(304, headers => [['content-length', 1234], ['etag', '"v1"']]));
    is $res->header('content-length'), 1234, 'a 304 keeps the length its 200 would have had';
    is $res->header('etag'), '"v1"', 'and its other headers';
};

subtest 'a file or fh body is not opened' => sub {
    my $res;
    my $warnings = warnings { $res = get(answering(204, events => [{ type => 'http.response.body', file => '/no/such/file' }])) };
    is $res->content, '', 'file: nothing read';
    is $warnings, [], 'never opened: a missing file is no error';
};

subtest 'trailers are accepted and discarded' => sub {
    my $trailers = [
        { type => 'http.response.body', body => 'abc', more => 0 },
        { type => 'http.response.trailers', headers => [['x-checksum', 'sha256=1']] },
    ];
    my $res = get(answering(304, trailers => 1, events => $trailers));
    is $res->trailer_pairs, [], '304: discarded';
    ok !$res->exception, '304: the request completes';
    my $head = PAGI::Test::Client->new(app => answering(200, trailers => 1, events => $trailers))->head('/');
    is $head->trailer_pairs, [], 'HEAD: discarded too';
};

done_testing;
