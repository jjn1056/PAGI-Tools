use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use PAGI::Request;

my $scope = {
    type         => 'http',
    method       => 'GET',
    path         => '/test',
    query_string => '',
    headers      => [],
};

my $receive = sub { Future->done({ type => 'http.request', body => '' }) };

subtest 'stash accessor' => sub {
    my $req = PAGI::Request->new($scope, $receive);

    # Default stash is empty hashref
    is($req->stash, {}, 'stash returns empty hashref by default');

    # Can set values
    $req->stash->{user} = { id => 1, name => 'test' };
    is($req->stash->{user}{id}, 1, 'stash values persist');
};

subtest 'set_stash replaces entire stash' => sub {
    my $req = PAGI::Request->new($scope, $receive);

    $req->set_stash({ db => 'connection', config => { debug => 1 } });
    is($req->stash->{db}, 'connection', 'set_stash sets values');
    is($req->stash->{config}{debug}, 1, 'nested values work');
};

subtest 'set and get for request-scoped data' => sub {
    my $req = PAGI::Request->new($scope, $receive);

    # Set a value
    $req->set('user', { id => 42, role => 'admin' });

    # Get it back
    my $user = $req->get('user');
    is($user->{id}, 42, 'get returns set value');
    is($user->{role}, 'admin', 'get returns full structure');

    # Get missing key
    is($req->get('missing'), undef, 'get returns undef for missing');
};

subtest 'param returns route parameters from scope' => sub {
    my $scope_with_route_params = {
        type         => 'http',
        method       => 'GET',
        path         => '/test',
        query_string => '',
        headers      => [],
        'pagi.router' => { params => { id => '123', action => 'edit' } },
    };

    my $req = PAGI::Request->new($scope_with_route_params, $receive);

    is($req->param('id'), '123', 'param returns route param from scope');
    is($req->param('action'), 'edit', 'param returns another param');
    is($req->param('missing'), undef, 'param returns undef for missing');
};

subtest 'param falls back to query params' => sub {
    my $scope_with_query = {
        type         => 'http',
        method       => 'GET',
        path         => '/test',
        query_string => 'foo=bar&baz=qux',
        headers      => [],
    };

    my $req = PAGI::Request->new($scope_with_query, $receive);

    # No route params in scope, should fall back to query
    is($req->param('foo'), 'bar', 'param falls back to query param');

    # With route params in scope, route param takes precedence
    $scope_with_query->{'pagi.router'}{params} = { foo => 'route_value' };
    is($req->param('foo'), 'route_value', 'route param takes precedence');
    is($req->param('baz'), 'qux', 'other query params still accessible');
};

done_testing;
