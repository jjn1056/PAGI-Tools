use strict; use warnings; use Test::More; use Future::AsyncAwait;
use PAGI::Test::Client;

# helper: await a send, trapping a failure without dying the app
async sub try_send {
    my ($send, $event) = @_;
    my $err;
    eval { await $send->($event); 1 } or do { $err = $@ };
    return $err;
}

# ---------------------------------------------------------------------------
# B9: this mock is H1-flavored -- it mirrors PAGI::Server::Connection's H1
# rule (transfer-encoding + connection stripped, warned once per occurrence),
# NOT the H2 six-name strip, and supplies Date only when the app didn't.
# ---------------------------------------------------------------------------

subtest 'B9: transfer-encoding and connection are stripped, warned once each' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [
                ['transfer-encoding', 'gzip'],
                ['connection',        'keep-alive'],
                ['content-type',      'text/plain'],
            ],
        });
        await $send->({ type => 'http.response.body', body => 'ok', more => 0 });
    };

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    my $res = PAGI::Test::Client->new(app => $app)->get('/');

    is $res->header('transfer-encoding'), undef, 'transfer-encoding stripped';
    is $res->header('connection'), undef, 'connection stripped';
    is $res->header('content-type'), 'text/plain', 'other headers survive';
    is scalar(@warnings), 2, 'exactly one warning per stripped header occurrence';
    like $warnings[0], qr/transfer-encoding/i, 'first warning names transfer-encoding';
    like $warnings[1], qr/connection/i, 'second warning names connection';
};

subtest 'B9: two connection headers warn twice (not deduplicated by name)' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [
                ['connection', 'keep-alive'],
                ['connection', 'close'],
            ],
        });
        await $send->({ type => 'http.response.body', body => '', more => 0 });
    };

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    PAGI::Test::Client->new(app => $app)->get('/');

    is scalar(@warnings), 2, 'each occurrence warns separately';
};

subtest 'B9: upgrade/te/keep-alive survive -- narrower than the H2 six-name strip' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [
                ['upgrade',     'h2c'],
                ['te',          'trailers'],
                ['keep-alive',  'timeout=5'],
            ],
        });
        await $send->({ type => 'http.response.body', body => '', more => 0 });
    };

    my $res = PAGI::Test::Client->new(app => $app)->get('/');

    is $res->header('upgrade'), 'h2c', 'upgrade survives (h1 has no such prohibition)';
    is $res->header('te'), 'trailers', 'te survives';
    is $res->header('keep-alive'), 'timeout=5', 'keep-alive survives';
};

subtest 'B9: server supplies Date when the app did not' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => '', more => 0 });
    };

    my $res = PAGI::Test::Client->new(app => $app)->get('/');
    my $date = $res->header('date');

    ok defined $date, 'Date header present';
    like $date, qr/^\w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} GMT$/,
        'RFC 7231 IMF-fixdate shape';
};

subtest "B9: the app's own Date header is preserved, not overwritten" => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['date', 'Sun, 06 Nov 1994 08:49:37 GMT']],
        });
        await $send->({ type => 'http.response.body', body => '', more => 0 });
    };

    my $res = PAGI::Test::Client->new(app => $app)->get('/');

    # header() returns the LAST matching value -- if the mock wrongly
    # appended a second, freshly-generated Date after the app's own, this
    # would return that fresh value instead of the fixed string below.
    is $res->header('date'), 'Sun, 06 Nov 1994 08:49:37 GMT',
        "app-supplied Date preserved verbatim, not superseded by a synthesized one";
};

# ---------------------------------------------------------------------------
# B10: each scope advertises exactly the extension set this mock implements.
# ---------------------------------------------------------------------------

subtest 'B10: http scope advertises no extensions' => sub {
    my $scope;
    my $app = async sub {
        my ($s, $receive, $send) = @_;
        $scope = $s;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => '', more => 0 });
    };
    PAGI::Test::Client->new(app => $app)->get('/');

    ok exists $scope->{extensions}, 'extensions key exists on the http scope';
    is_deeply $scope->{extensions}, {}, 'http advertises no extensions';
};

subtest 'B10: an unadvertised http extension fails its send' => sub {
    my $err;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        $err = await try_send($send, { type => 'http.fullflush' });
        await $send->({ type => 'http.response.body', body => '', more => 0 });
    };
    my $res = PAGI::Test::Client->new(app => $app)->get('/');

    ok $err, 'http.fullflush fails the send';
    like $err, qr/fullflush/i, 'error names the unadvertised extension';
    is $res->status, 200, 'assembled response unaffected by the rejected fullflush';
};

subtest 'B10: websocket scope advertises exactly websocket.http.response' => sub {
    my $scope;
    my $app = async sub {
        my ($s, $receive, $send) = @_;
        $scope = $s;
        await $receive->(); # websocket.connect
        await $send->({ type => 'websocket.accept' });
    };
    PAGI::Test::Client->new(app => $app)->websocket('/');

    is_deeply $scope->{extensions}, { 'websocket.http.response' => {} },
        'websocket advertises exactly websocket.http.response -- the mock genuinely implements the denial path';
};

subtest 'B10: sse scope advertises no extensions' => sub {
    my $scope;
    my $app = async sub {
        my ($s, $receive, $send) = @_;
        $scope = $s;
        await $send->({ type => 'sse.start', status => 200, headers => [] });
    };
    PAGI::Test::Client->new(app => $app)->sse('/');

    ok exists $scope->{extensions}, 'extensions key exists on the sse scope';
    is_deeply $scope->{extensions}, {}, 'sse advertises no extensions';
};

done_testing;
