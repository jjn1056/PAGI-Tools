use strict; use warnings; use Test::More; use Future::AsyncAwait;
use PAGI::Test::Client;

my ($seen, $completed);
my $http_scope;
my $app = async sub {
    my ($scope, $receive, $send) = @_;
    $http_scope = $scope;
    $seen = $scope->{'pagi.connection'};
    ok $seen, 'scope carries pagi.connection';
    is $seen->is_connected, 1, 'connected during the request';
    is $seen->response_started, 0, 'not started before send';
    $seen->on_complete(sub { $completed = 1 });
    await $send->({ type => 'http.response.start', status => 200, headers => [] });
    is $seen->response_started, 1, 'started after http.response.start';
    await $send->({ type => 'http.response.body', body => 'hi', more => 0 });
    is $seen->response_complete, 1, 'terminal HTTP send marks complete before returning';
    is $seen->is_connected, 0, 'terminal HTTP send ends the scope before returning';
};
PAGI::Test::Client->new(app => $app)->get('/');
is_deeply $http_scope->{pagi}, { version => '0.5', spec_version => '0.6' },
    'HTTP scope advertises core 0.5 and WWW 0.6';
is $completed, 1, 'on_complete fired once the request completed';
is $seen->is_connected, 0, 'request ended after completion';

# Clean completion: on_complete fires (after the app returns), on_disconnect does not.
{
    my ($conn, @ev);
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $conn = $scope->{'pagi.connection'};
        $conn->on_complete(sub { push @ev, 'complete' });
        $conn->on_disconnect(sub { push @ev, 'disconnect' });
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        is_deeply \@ev, [], 'not complete before the terminal send';
        await $send->({ type => 'http.response.body', body => 'ok', more => 0 });
        is_deeply \@ev, [], 'on_complete is deferred beyond the terminal send';
    };
    PAGI::Test::Client->new(app => $app)->get('/');
    is_deeply \@ev, ['complete'], 'on_complete fires after the app returns; on_disconnect does not';
}

subtest 'websocket and SSE scopes advertise core 0.5 and WWW 0.6' => sub {
    my ($ws_scope, $sse_scope);

    my $ws_app = async sub {
        my ($scope, $receive, $send) = @_;
        $ws_scope = $scope;
        await $receive->();
        await $send->({ type => 'websocket.accept' });
        await $send->({ type => 'websocket.close', code => 1000 });
    };
    PAGI::Test::Client->new(app => $ws_app)->websocket('/ws');

    my $sse_app = async sub {
        my ($scope, $receive, $send) = @_;
        $sse_scope = $scope;
        await $send->({ type => 'sse.start', status => 200, headers => [] });
        await $send->({ type => 'sse.close' });
    };
    PAGI::Test::Client->new(app => $sse_app)->sse('/events');

    is_deeply $ws_scope->{pagi}, { version => '0.5', spec_version => '0.6' },
        'WebSocket scope version';
    is_deeply $sse_scope->{pagi}, { version => '0.5', spec_version => '0.6' },
        'SSE scope version';
};

# App exception => synthetic 500 => abnormal server_error disconnect.
{
    my ($conn, @ev);
    my $boom = async sub {
        my ($scope) = @_;
        $conn = $scope->{'pagi.connection'};
        $conn->on_complete(sub { push @ev, 'complete' });
        $conn->on_disconnect(sub { push @ev, "disc:$_[0]" });
        die "boom\n";
    };
    my $resp = PAGI::Test::Client->new(app => $boom, raise_app_exceptions => 0)->get('/');
    is $resp->status, 500, 'synthetic 500 on app exception';
    is $conn->response_started, 1, 'response_started true for the synthesized 500';
    is_deeply \@ev, ['disc:server_error'], 'on_disconnect(server_error) fires, on_complete does not';
}

subtest 'HTTP completion wakes a suspended application outside send' => sub {
    for my $case (
        ['get', 0, 0, 0], # observer requested after the terminal body
        ['get', 1, 1, 0], # observer requested before sending
        ['get', 1, 0, 1], # declared trailers delay completion
        ['head', 1, 0, 0],
    ) {
        my ($method, $raise, $early, $trailers) = @$case;
        my (@events, @warnings);
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $app = async sub {
            my ($scope, $receive, $send) = @_;
            my $conn = $scope->{'pagi.connection'};
            my $cancelled = $conn->end_future;
            $cancelled->cancel;
            my $end = $early ? $conn->end_future : undef;
            $conn->on_complete(sub { push @events, 'complete' });
            $conn->on_end(sub { push @events, 'end' });
            await $send->({ type => 'http.response.start', status => 200,
                headers => [], trailers => $trailers });
            await $send->({ type => 'http.response.body', body => 'ok', more => 0 });
            if ($trailers) {
                ok !$conn->response_complete, 'body does not finish declared trailers';
                await $send->({ type => 'http.response.trailers', headers => [], more => 0 });
            }
            ok $conn->response_complete, 'completion fact is synchronous';
            is_deeply \@events, [], 'callbacks are still deferred after terminal send';
            push @events, 'sent';
            my $reason = await ($end || $conn->end_future);
            is $reason, undef, 'clean end carries no abnormal reason';
            push @events, 'resumed';
        };
        my $client = PAGI::Test::Client->new(app => $app, raise_app_exceptions => $raise);
        my $response = eval { $client->$method('/') };
        is $@, '', "$method completion wait succeeds (early=$early, trailers=$trailers)";
        is $response && $response->status, 200, 'response preserved';
        is_deeply \@events, [qw(sent complete end resumed)],
            'callbacks and application finish exactly once';
        is_deeply \@warnings, [], 'no lost Future or spurious application exception';
    }
};

subtest 'errors after the terminal send preserve completion and exception policy' => sub {
    for my $await_end (0, 1) {
        for my $raise (0, 1) {
            my (@warnings, $completed);
            local $SIG{__WARN__} = sub { push @warnings, @_ };
            my $app = async sub {
                my ($scope, $receive, $send) = @_;
                my $conn = $scope->{'pagi.connection'};
                $conn->on_complete(sub { ++$completed });
                await $send->({ type => 'http.response.start', status => 200, headers => [] });
                await $send->({ type => 'http.response.body', body => 'ok', more => 0 });
                await $conn->end_future if $await_end;
                die "application cleanup failed\n";
            };
            my $client = PAGI::Test::Client->new(app => $app, raise_app_exceptions => $raise);
            my $response = eval { $client->get('/') };
            my $error = $@;
            is $completed, 1, 'clean completion notification survives application failure';
            if ($raise) {
                is $error, "application cleanup failed\n", 'original application error propagates';
                is_deeply \@warnings, [], 'no spurious Future warnings';
            } else {
                is $error, '', 'default exception policy returns response';
                is $response && $response->status, 200, 'completed response is not replaced';
                is scalar @warnings, 1, 'only the application exception is warned';
                like $warnings[0], qr/exception after response completed: application cleanup failed/,
                    'warning reports the actual application failure';
            }
        }
    }
};

subtest 'a failing completion callback cannot strand the awaiting application' => sub {
    my (@events, @warnings);
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $client = PAGI::Test::Client->new(raise_app_exceptions => 1, app => async sub {
        my ($scope, $receive, $send) = @_;
        my $conn = $scope->{'pagi.connection'};
        $conn->on_complete(sub { die "callback failed\n" });
        $conn->on_end(sub { push @events, 'end' });
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'ok', more => 0 });
        await $conn->end_future;
        push @events, 'resumed';
    });
    my $response = eval { $client->get('/') };
    is $@, '', 'callback failure is isolated from application';
    is $response && $response->status, 200, 'response remains successful';
    is_deeply \@events, [qw(end resumed)], 'other notifications and application proceed';
    is scalar @warnings, 1, 'only callback error is warned';
    like $warnings[0], qr/pagi.connection callback error: callback failed/, 'callback warning preserved';
};

done_testing;
