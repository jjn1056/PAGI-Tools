use strict; use warnings; use Test::More; use Future::AsyncAwait;
use PAGI::Test::Client;

# ---------------------------------------------------------------------------
# B1: Test::Client's http $send is strict -- illegal events fail the send
# Future (server-shaped message), never get appended to the assembled
# response, and never advance state.
# ---------------------------------------------------------------------------

# helper: await a send, trapping a failure without dying the app
async sub try_send {
    my ($send, $event) = @_;
    my $err;
    eval { await $send->($event); 1 } or do { $err = $@ };
    return $err;
}

subtest 'B1: malformed (missing type) fails the send Future' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $err = await try_send($send, { body => 'oops' }); # no 'type' at all
        ok $err, 'send Future failed';
        like $err, qr/type/i, 'error names the missing type';

        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'ok', more => 0 });
    };
    my $res = PAGI::Test::Client->new(app => $app)->get('/');
    is $res->status, 200, 'assembled response unaffected';
    is $res->content, 'ok', 'assembled body unaffected';
};

subtest 'B1: unknown_type fails the send Future' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $err = await try_send($send, { type => 'http.made.up', status => 200 });
        ok $err, 'send Future failed';
        like $err, qr/unrecognized|unknown/i, 'error names the unrecognized type';

        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'ok', more => 0 });
    };
    my $res = PAGI::Test::Client->new(app => $app)->get('/');
    is $res->status, 200, 'assembled response unaffected';
    is $res->content, 'ok', 'assembled body unaffected';
};

subtest 'B1: duplicate http.response.start fails the send Future' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 201, headers => [] });

        my $err = await try_send($send, { type => 'http.response.start', status => 999, headers => [] });
        ok $err, 'send Future failed';
        like $err, qr/duplicate/i, 'error names the duplicate start';

        await $send->({ type => 'http.response.body', body => 'ok', more => 0 });
    };
    my $res = PAGI::Test::Client->new(app => $app)->get('/');
    is $res->status, 201, 'assembled response unaffected by the rejected duplicate start';
    is $res->content, 'ok', 'assembled body unaffected';
};

subtest 'B1: body before start fails the send Future' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $err = await try_send($send, { type => 'http.response.body', body => 'early', more => 0 });
        ok $err, 'send Future failed';
        like $err, qr/before/i, 'error names the out-of-order body';

        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'ok', more => 0 });
    };
    my $res = PAGI::Test::Client->new(app => $app)->get('/');
    is $res->status, 200, 'assembled response unaffected';
    is $res->content, 'ok', 'assembled body unaffected -- the early body never landed';
};

subtest 'B1: undeclared trailers fails the send Future' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] }); # no trailers => 1
        await $send->({ type => 'http.response.body', body => 'ok', more => 0 });

        my $err = await try_send($send, { type => 'http.response.trailers', headers => [['x-t', '1']] });
        ok $err, 'send Future failed';
        like $err, qr/trailers/i, 'error names the undeclared trailers';
    };
    my $res = PAGI::Test::Client->new(app => $app)->get('/');
    is $res->status, 200, 'assembled response unaffected';
    is $res->content, 'ok', 'assembled body unaffected';
};

# ---------------------------------------------------------------------------
# B2: an incomplete response (app returns without reaching a legal terminal
# state) is a server-shaped abnormal disconnect, not a clean completion.
# ---------------------------------------------------------------------------

subtest 'B2: more=>1 body, never terminated' => sub {
    my (@events);
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $conn = $scope->{'pagi.connection'};
        $conn->on_complete(sub { push @events, 'complete' });
        $conn->on_disconnect(sub { push @events, "disc:$_[0]" });
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'partial', more => 1 });
        # returns without ever sending the terminal chunk
    };

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    PAGI::Test::Client->new(app => $app)->get('/');

    is_deeply \@events, ['disc:server_error'], 'on_disconnect(server_error) fires; on_complete does not';
    is scalar(@warnings), 1, 'exactly one warning';
    like $warnings[0], qr/incomplete/i, 'warning documents the incomplete response';
};

subtest 'B2: trailers declared, never sent' => sub {
    my (@events);
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $conn = $scope->{'pagi.connection'};
        $conn->on_complete(sub { push @events, 'complete' });
        $conn->on_disconnect(sub { push @events, "disc:$_[0]" });
        await $send->({ type => 'http.response.start', status => 200, headers => [], trailers => 1 });
        await $send->({ type => 'http.response.body', body => 'ok', more => 0 });
        # returns without ever sending the declared trailers
    };

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    PAGI::Test::Client->new(app => $app)->get('/');

    is_deeply \@events, ['disc:server_error'], 'on_disconnect(server_error) fires; on_complete does not';
    is scalar(@warnings), 1, 'exactly one warning';
    like $warnings[0], qr/incomplete/i, 'warning documents the incomplete response';
};

subtest 'B2: response never started at all (mirrors the server no-response backstop)' => sub {
    my (@events);
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $conn = $scope->{'pagi.connection'};
        $conn->on_complete(sub { push @events, 'complete' });
        $conn->on_disconnect(sub { push @events, "disc:$_[0]" });
        # returns having never sent anything at all
    };

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    my $res = PAGI::Test::Client->new(app => $app)->get('/');

    is $res->status, 500, 'synthesized 500, same as the server\'s no-response backstop';
    is_deeply \@events, ['disc:server_error'], 'on_disconnect(server_error) fires; on_complete does not';
    is scalar(@warnings), 1, 'exactly one warning';
    like $warnings[0], qr/incomplete/i, 'warning documents the incomplete response';
};

# ---------------------------------------------------------------------------
# B3: an exception after the response is fully complete stands the real
# response and fires on_complete; an exception before completion keeps the
# existing 500 + server_error path.
# ---------------------------------------------------------------------------

subtest 'B3: exception after response completed' => sub {
    my (@events, $conn);
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $conn = $scope->{'pagi.connection'};
        $conn->on_complete(sub { push @events, 'complete' });
        $conn->on_disconnect(sub { push @events, "disc:$_[0]" });
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'ok', more => 0 });
        die "kaboom after completion\n";
    };

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    my $res = PAGI::Test::Client->new(app => $app)->get('/');

    is $res->status, 200, 'the real response stands';
    is $res->content, 'ok', 'the real body stands';
    is_deeply \@events, ['complete'], 'on_complete fires; on_disconnect does not';
    is $conn->disconnect_reason, undef, 'disconnect_reason is undef';
    is scalar(@warnings), 1, 'exactly one warning';
    like $warnings[0], qr/after .* complet/i, 'warning documents the post-completion exception';
};

subtest 'B3: exception before any send still 500s (regression)' => sub {
    my (@events, $conn);
    my $app = async sub {
        my ($scope) = @_;
        $conn = $scope->{'pagi.connection'};
        $conn->on_complete(sub { push @events, 'complete' });
        $conn->on_disconnect(sub { push @events, "disc:$_[0]" });
        die "boom before send\n";
    };
    my $res = PAGI::Test::Client->new(app => $app)->get('/');
    is $res->status, 500, 'still the synthetic 500';
    is_deeply \@events, ['disc:server_error'], 'still an abnormal disconnect, not on_complete';
};

# ---------------------------------------------------------------------------
# B4: every scope type advertises pagi 0.4 / spec_version 0.3.
# ---------------------------------------------------------------------------

subtest 'B4: scopes advertise pagi.version 0.4 / spec_version 0.3' => sub {
    my $seen;

    my $http_app = async sub {
        my ($scope, $receive, $send) = @_;
        $seen = $scope->{pagi};
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => '', more => 0 });
    };
    PAGI::Test::Client->new(app => $http_app)->get('/');
    is_deeply $seen, { version => '0.4', spec_version => '0.3' }, 'http scope';

    undef $seen;
    my $ws_app = async sub {
        my ($scope, $receive, $send) = @_;
        $seen = $scope->{pagi};
        await $receive->(); # websocket.connect
        await $send->({ type => 'websocket.accept' });
    };
    PAGI::Test::Client->new(app => $ws_app)->websocket('/');
    is_deeply $seen, { version => '0.4', spec_version => '0.3' }, 'websocket scope';

    undef $seen;
    my $sse_app = async sub {
        my ($scope, $receive, $send) = @_;
        $seen = $scope->{pagi};
        await $send->({ type => 'sse.start', status => 200, headers => [] });
    };
    PAGI::Test::Client->new(app => $sse_app)->sse('/');
    is_deeply $seen, { version => '0.4', spec_version => '0.3' }, 'sse scope';

    undef $seen;
    my $lifespan_app = async sub {
        my ($scope, $receive, $send) = @_;
        $seen = $scope->{pagi};
        await $receive->(); # lifespan.startup
        await $send->({ type => 'lifespan.startup.complete' });
        await $receive->(); # suspends awaiting shutdown
    };
    PAGI::Test::Client->new(app => $lifespan_app, lifespan => 1)->start;
    is_deeply $seen, { version => '0.4', spec_version => '0.3' }, 'lifespan scope';
};

done_testing;
