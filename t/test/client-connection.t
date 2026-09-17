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

done_testing;
