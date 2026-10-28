use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Test::Client;

# PAGI::Test::Client advertises Www 0.7, so it keeps "Sends Are Sequential":
# sends an application issues before earlier ones resolve are processed in
# the order they were called, and a send issued after the application's own
# close fails.

subtest 'WebSocket: overlapping sends arrive in call order' => sub {
    my ($late, $version);
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $version = $scope->{pagi}{spec_version};
        await $receive->();
        await $send->({ type => 'websocket.accept' });
        my @sent = map { $send->({ type => 'websocket.send', text => $_ }) } qw(one two three);
        my $close = $send->({ type => 'websocket.close', code => 1000 });
        $late = $send->({ type => 'websocket.send', text => 'late' });
        await Future->needs_all(@sent, $close);
    };
    my $ws = PAGI::Test::Client->new(app => $app)->websocket('/');
    is([map { $ws->receive_text } 1 .. 3], ['one', 'two', 'three'], 'in the order they were called');
    is($version, '0.7', 'on a 0.7 scope');
    ok($late->is_failed, "a send issued after the application's own close fails");
};

subtest 'SSE: overlapping sends arrive in call order' => sub {
    my ($late, $version);
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $version = $scope->{pagi}{spec_version};
        my @sent = ($send->({ type => 'sse.start', status => 200 }),
            map { $send->({ type => 'sse.send', data => $_ }) } qw(one two three));
        my $close = $send->({ type => 'sse.close' });
        $late = $send->({ type => 'sse.send', data => 'late' });
        await Future->needs_all(@sent, $close);
    };
    my $sse = PAGI::Test::Client->new(app => $app)->sse('/');
    is([map { $sse->receive_event->{data} } 1 .. 3], ['one', 'two', 'three'], 'in the order they were called');
    is($version, '0.7', 'on a 0.7 scope');
    ok($late->is_failed, "a send issued after the application's own close fails");
};

subtest 'HTTP: an overlapping body arrives in call order' => sub {
    my $version;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $version = $scope->{pagi}{spec_version};
        my @sent = ($send->({ type => 'http.response.start', status => 200, headers => [] }),
            (map { $send->({ type => 'http.response.body', body => $_, more => 1 }) } qw(one- two- three)),
            $send->({ type => 'http.response.body', body => '', more => 0 }));
        await Future->needs_all(@sent);
    };
    is(PAGI::Test::Client->new(app => $app)->get('/')->text, 'one-two-three', 'in the order they were called');
    is($version, '0.7', 'on a 0.7 scope');
};

done_testing;
