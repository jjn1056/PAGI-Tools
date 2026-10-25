use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use lib 'lib';
use PAGI::Request;
use PAGI::Test::Client;
use PAGI::Tools qw(compose response route);

# A receive after the whole request body has been delivered waits, as it
# does on a real server, until the response is complete; then it reports
# the disconnect. So an application that reads a consumed body again -- a
# second Request over the same receive -- fails in a test the way it hangs
# on a server, instead of reading an empty body.

local $PAGI::Test::_Drive::TIMEOUT = 1;

subtest 'a second read of a consumed body fails, naming it' => sub {
    my $app = compose(routes => [route('/' => async sub {
        my ($request) = @_;
        my $first = await $request->body;
        my $second = await PAGI::Request->new($request->scope, $request->{receive})->body;
        return response('Text', "first=$first second=[$second]");
    }, methods => ['POST'])]);
    like dies { PAGI::Test::Client->new(app => $app)->post('/', body => 'hello') },
        qr/\APAGI request did not complete within 1 seconds: the application waited for more of the request body after receiving all of it/,
        'the client says what the application waited for';
};

subtest 'after the response, a receive reports the disconnect' => sub {
    my $after;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->();
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'ok', more => 0 });
        $after = await $receive->();
    };
    my $res = PAGI::Test::Client->new(app => $app)->post('/', body => 'x');
    is [$res->status, $after->{type}], [200, 'http.disconnect'], 'the app is told the client went';
};

subtest 'a receive already waiting when the response completes reports the disconnect' => sub {
    my $watched;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->();
        my $watch = $receive->()->on_done(sub { $watched = $_[0]{type} });
        await $send->({ type => 'http.response.start', status => 204, headers => [] });
        await $send->({ type => 'http.response.body', body => '', more => 0 });
        await $watch;
    };
    is(PAGI::Test::Client->new(app => $app)->post('/', body => 'x')->status, 204);
    is $watched, 'http.disconnect', 'the pending receive resolved when the response ended';
};

subtest 'reading the body once, the ordinary way, is unchanged' => sub {
    my $app = compose(routes => [route('/' => async sub {
        my ($request) = @_;
        return response('Text', 'got ' . await $request->body);
    }, methods => ['POST'])]);
    is(PAGI::Test::Client->new(app => $app)->post('/', body => 'hello')->text, 'got hello');
};

done_testing;
