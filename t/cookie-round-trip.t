use strict; use warnings;
use Test2::V0;
use Future::AsyncAwait;
use File::Temp ();
use lib 't/lib';
use PAGITest::CurrentServer qw(current_server_unavailable);

plan skip_all => 'set RELEASE_TESTING=1 to run the live cookie round trip'
    unless $ENV{RELEASE_TESTING};
my $curl = do { my ($found) = grep { -x "$_/curl" } split /:/, $ENV{PATH} // ''; $found && "$found/curl" };
plan skip_all => 'curl is not installed' unless $curl;
my $server_unavailable = current_server_unavailable();
plan skip_all => $server_unavailable if $server_unavailable;
plan skip_all => "full-stack deps unavailable: $@"
    unless eval { require IO::Async::Loop; require JSON::MaybeXS; 1 };

use PAGI::HTTPConnection;
use PAGI::Response;
use PAGI::Middleware::Cookie;

# D5a: whatever the writers send, a client sends back unchanged, and
# PAGI::HTTPConnection reads it as written. Every value is made of RFC 6265
# cookie-octets; curl's cookie jar stands in for the browser.
my @values = (
    'plain123', 'x/y', 'x%y', 'a+b', 'x=y', 'a:b', 'x%2Fy',
    q{~!@#$%^&*()_-+={}[]|:'<>.?/},
    join('', map chr, 0x21, 0x23 .. 0x2B, 0x2D .. 0x3A, 0x3C .. 0x5B, 0x5D .. 0x7E),
);

# /set: the first half of the values through Response->cookie, the second
# through the Cookie middleware jar. /echo: what the request carried.
my $set = async sub {
    my ($scope, $receive, $send) = @_;
    my $jar = $scope->{'pagi.cookie_jar'};
    my $res = PAGI::Response->new('set');
    for my $i (0 .. $#values) {
        $i % 2 ? $jar->set("j$i", $values[$i]) : $res->cookie("r$i", $values[$i]);
    }
    await $res->to_app->($scope, $receive, $send);
};
my $echo = async sub {
    my ($scope, $receive, $send) = @_;
    my $cookies = PAGI::HTTPConnection->new($scope)->cookies;
    await $send->({ type => 'http.response.start', status => 200,
                    headers => [['content-type', 'application/json']] });
    await $send->({ type => 'http.response.body', more => 0,
                    body => JSON::MaybeXS->new(canonical => 1)->encode($cookies) });
};
my $app = PAGI::Middleware::Cookie->new->wrap(async sub {
    my ($scope, $receive, $send) = @_;
    return if $scope->{type} ne 'http';   # lifespan: nothing to do
    my $handler =$scope->{path} eq '/set' ? $set : $echo;
    await $handler->($scope, $receive, $send);
});

my $loop = IO::Async::Loop->new;
my $server = PAGI::Server->new(app => $app, host => '127.0.0.1', port => 0,
    quiet => 1, access_log => undef);
$loop->add($server);
$server->listen->get;
my $port = $server->port;

my $dir = File::Temp->newdir;
my $jar = "$dir/jar";
sub curl_body {
    my ($path) = @_;
    my ($exit, $stdout) = $loop->run_process(
        command => [$curl, '-sS', '-c', $jar, '-b', $jar, "http://127.0.0.1:$port$path"],
        capture => [qw(exitcode stdout)],
    )->get;
    is $exit, 0, "curl $path exits 0";
    return $stdout;
}

curl_body('/set');
my $seen = JSON::MaybeXS::decode_json(curl_body('/echo'));
$server->shutdown->get;
$loop->remove($server);

for my $i (0 .. $#values) {
    my $name = ($i % 2 ? 'j' : 'r') . $i;
    is $seen->{$name}, $values[$i], "$name read back unchanged";
}
is scalar(keys %$seen), scalar(@values), 'no other cookie came back';

done_testing;
