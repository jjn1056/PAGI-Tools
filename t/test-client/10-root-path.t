use strict;
use warnings;
use utf8;
use Test2::V0;
use Future::AsyncAwait;
use lib 'lib';
use PAGI::Test::Client;

# With root_path, the client serves the app as a server configured with that
# root path would behind a proxy that strips it: requests take the browser's
# URL, the app stays the root (so its lifespan runs), and the scope has
# root_path, path below it, and the full raw_path.

my @scopes;
my $app = async sub {
    my ($scope, $receive, $send) = @_;
    push @scopes, { map { $_ => $scope->{$_} } qw(type root_path path raw_path query_string) };
    if ($scope->{type} eq 'http') {
        await $send->({ type => 'http.response.start', status => 204, headers => [] });
        await $send->({ type => 'http.response.body', body => '' });
    }
    elsif ($scope->{type} eq 'websocket') {
        await $receive->();
        await $send->({ type => 'websocket.accept' });
        await $send->({ type => 'websocket.close', code => 1000 });
    }
    elsif ($scope->{type} eq 'sse') {
        await $send->({ type => 'sse.start', status => 200, headers => [] });
    }
};

subtest 'requests take the browser URL; the scope is below root_path' => sub {
    my $client = PAGI::Test::Client->new(app => $app, root_path => '/app');
    $client->get('/app/reports?x=1');
    is($scopes[-1], { type => 'http', root_path => '/app', path => '/reports',
        raw_path => '/app/reports', query_string => 'x=1' }, 'http');
    $client->get('/app');
    is([@{ $scopes[-1] }{qw(path raw_path)}], ['/', '/app'], 'the root path itself');
    $client->websocket('/app/ws');
    is([@{ $scopes[-1] }{qw(type root_path path raw_path)}], ['websocket', '/app', '/ws', '/app/ws'], 'websocket');
    $client->sse('/app/events');
    is([@{ $scopes[-1] }{qw(type root_path path raw_path)}], ['sse', '/app', '/events', '/app/events'], 'sse');
};

subtest 'non-ASCII root path' => sub {
    my $client = PAGI::Test::Client->new(app => $app, root_path => '/café');
    $client->get('/caf%C3%A9/menu');
    is([@{ $scopes[-1] }{qw(root_path path raw_path)}], ['/café', '/menu', '/caf%C3%A9/menu']);
};

subtest 'a URL outside the root path is a test error' => sub {
    my $client = PAGI::Test::Client->new(app => $app, root_path => '/app');
    like(dies { $client->get('/application') }, qr{'/application' is not under root_path '/app'}, 'not a prefix match');
    like(dies { $client->get('/other') }, qr{is not under root_path}, 'another path');
};

subtest 'root_path must have the spec shape' => sub {
    for my $bad ('app', '/app/', '//app', '/a/../b') {
        like(dies { PAGI::Test::Client->new(app => $app, root_path => $bad) },
            qr{root_path must be ''? or /segment}, "rejects '$bad'");
    }
    ok(PAGI::Test::Client->new(app => $app, root_path => ''), "'' is the root");
};

done_testing;
