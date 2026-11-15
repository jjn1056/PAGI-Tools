use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use PAGI::Test::Client;

# lowercase_headers (off by default): a response header name with an
# uppercase letter fails the send. PAGI Www.pod: names an application sends
# SHOULD be lowercase.

my $uppercase = "http.response.start header 0: name 'Set-Cookie' has uppercase letters (lowercase_headers is on)\n";

my $http_app = async sub {
    my ($scope, $receive, $send) = @_;
    await $send->({ type => 'http.response.start', status => 200, headers => [['Set-Cookie', 'a=1']] });
    await $send->({ type => 'http.response.body', body => 'ok' });
};

subtest 'http' => sub {
    my $res = PAGI::Test::Client->new(app => $http_app, lowercase_headers => 1)->get('/');
    is $res->status, 500, 'on: an uppercase name fails the send';
    is $res->exception, $uppercase, 'and says why';

    $res = PAGI::Test::Client->new(app => $http_app)->get('/');
    is $res->status, 200, 'off by default: it is sent';
    is $res->header('set-cookie'), 'a=1', 'as given';

    my $trailers = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, trailers => 1, headers => [] });
        await $send->({ type => 'http.response.body', body => 'ok' });
        await $send->({ type => 'http.response.trailers', headers => [['x-ok', 1], ['X-Sum', 3]] });
    };
    is(PAGI::Test::Client->new(app => $trailers, lowercase_headers => 1)->get('/')->exception,
        "http.response.trailers header 1: name 'X-Sum' has uppercase letters (lowercase_headers is on)\n",
        'trailers too');
};

subtest 'websocket accept' => sub {
    my $err;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->();
        $err = eval { await $send->({ type => 'websocket.accept', headers => [['X-Id', 1]] }); '' } // $@;
        await $send->({ type => 'websocket.accept' }) if $err;
        await $send->({ type => 'websocket.close' });
    };
    PAGI::Test::Client->new(app => $app, lowercase_headers => 1)->websocket('/', sub { });
    is $err, "websocket.accept header 0: name 'X-Id' has uppercase letters (lowercase_headers is on)\n", 'on';
    PAGI::Test::Client->new(app => $app)->websocket('/', sub { });
    is $err, '', 'off';
};

subtest 'sse.start' => sub {
    my $err;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $err = eval { await $send->({ type => 'sse.start', headers => [['X-Id', 1]] }); '' } // $@;
        await $send->({ type => 'sse.start' }) if $err;
        await $send->({ type => 'sse.close' });
    };
    PAGI::Test::Client->new(app => $app, lowercase_headers => 1)->sse('/', sub { });
    is $err, "sse.start header 0: name 'X-Id' has uppercase letters (lowercase_headers is on)\n", 'on';
    PAGI::Test::Client->new(app => $app)->sse('/', sub { });
    is $err, '', 'off';
};

subtest 'only response headers: what the client sends is its own' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [['x-ok', 1]] });
        await $send->({ type => 'http.response.body', body => 'ok' });
    };
    is(PAGI::Test::Client->new(app => $app, lowercase_headers => 1)->get('/', headers => { 'X-Request' => 1 })->status,
        200, 'a request header given in any case');
};

done_testing;
