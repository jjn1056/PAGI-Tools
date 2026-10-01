use strict;
use warnings;
use utf8;
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Test::Client;

# Test::Client builds path, raw_path and query_string as PAGI::Server does
# from the request target: raw_path is the path as sent (percent-encoded
# bytes), path its decoded form. A mount rewrites path but not raw_path,
# so an app that rebuilds the requested URL from raw_path must see it here
# as it would under the server.

my @scopes;
my $app = async sub {
    my ($scope, $receive, $send) = @_;
    push @scopes, { map { $_ => $scope->{$_} } qw(type path raw_path query_string) };
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
my $client = PAGI::Test::Client->new(app => $app);

sub last_scope { return $scopes[-1] }

subtest 'every scope type carries raw_path, as the server sends it' => sub {
    $client->get('/reports?x=1');
    is(last_scope(), { type => 'http', path => '/reports', raw_path => '/reports', query_string => 'x=1' },
        'http');
    $client->websocket('/ws?room=1');
    is(last_scope(), { type => 'websocket', path => '/ws', raw_path => '/ws', query_string => 'room=1' },
        'websocket');
    $client->sse('/events?since=5');
    is(last_scope(), { type => 'sse', path => '/events', raw_path => '/events', query_string => 'since=5' },
        'sse');
};

subtest 'a percent-encoded path: raw_path as sent, path decoded' => sub {
    $client->get('/files/caf%C3%A9%20menu');
    is([@{ last_scope() }{qw(raw_path path)}], ['/files/caf%C3%A9%20menu', '/files/café menu'],
        'UTF-8 percent-encoding is decoded into characters');
    $client->get('/bad/%FF');
    is([@{ last_scope() }{qw(raw_path path)}], ['/bad/%FF', "/bad/\xFF"],
        'bytes that are not UTF-8 stay bytes, as the server does');
};

subtest 'a path given as characters is sent percent-encoded, as a browser would' => sub {
    $client->get('/files/café');
    is([@{ last_scope() }{qw(raw_path path)}], ['/files/caf%C3%A9', '/files/café']);
};

done_testing;
