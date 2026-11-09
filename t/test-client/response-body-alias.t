use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use PAGI::Test::Client;

# A request's body is $request->body; the test response says the same.
my $app = async sub {
    my ($scope, $receive, $send) = @_;
    await $send->({ type => 'http.response.start', status => 200, headers => [['content-type', 'application/octet-stream']] });
    await $send->({ type => 'http.response.body', body => "\x00\xFFbytes" });
};
my $res = PAGI::Test::Client->new(app => $app)->get('/');
is $res->body, "\x00\xFFbytes", 'body returns the raw response bytes';
is $res->body, $res->content, 'body and content are the same';

done_testing;
