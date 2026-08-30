#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use JSON::MaybeXS ();

use lib 'lib';
use PAGI::Endpoint::HTTP;
use PAGI::Request;
use PAGI::Response;
use PAGI::Response::Empty ();
use PAGI::Response::Text ();
use PAGI::Routing::Mount ();
use PAGI::Routing::Route ();
use PAGI::Routing::Router ();
use PAGI::Test::Client ();

package TestEndpoint {
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;

    sub get {
        my ($self, $request) = @_;
        $self->{get_request} = $request;
        return PAGI::Response::Text->new("GET response");
    }

    sub post {
        my ($self, $request) = @_;
        $self->{post_request} = $request;
        return Future->done(PAGI::Response::Text->new("POST response", status => 201));
    }
}

package ExplicitHeadEndpoint {
    use parent 'PAGI::Endpoint::HTTP';

    sub get  { PAGI::Response::Text->new('GET response') }
    sub head { PAGI::Response::Empty->new(status => 202) }
}

my $make_request = sub {
    my ($method, $headers) = @_;
    my $receive = sub { Future->done({ type => 'http.request', body => '' }) };
    my $scope = {
        type    => 'http',
        method  => $method,
        path    => '/test',
        headers => $headers // [],
    };
    return PAGI::Request->new($scope, $receive);
};

subtest 'dispatches synchronous GET with a Request and does not emit' => sub {
    my $request = $make_request->('GET');
    my @events;
    my $endpoint = TestEndpoint->new;

    my $response = $endpoint->dispatch($request)->get;

    isa_ok($endpoint->{get_request}, ['PAGI::Request'],
        'GET receives the direct Request');
    isa_ok($response, ['PAGI::Response'], 'dispatch returns a Response');
    is(\@events, [], 'dispatch returns without sending');
};

subtest 'dispatches Future-backed POST with a Request' => sub {
    my $request = $make_request->('POST');
    my $endpoint = TestEndpoint->new;

    my $response = $endpoint->dispatch($request)->get;

    isa_ok($endpoint->{post_request}, ['PAGI::Request'],
        'POST receives the direct Request');
    isa_ok($response, ['PAGI::Response'], 'Future resolves to a Response');
    is($response->status, 201, 'Future-backed handler response is retained');
};

subtest 'returns 405 for unimplemented method' => sub {
    my $endpoint = TestEndpoint->new;
    my $response = PAGI::Test::Client->new(app => $endpoint->to_app)->put(
        '/test', headers => { Accept => 'application/json' },
    );

    is($response->status, 405, '405 status for unimplemented');
    is $response->header_all('Allow'), ['GET, HEAD, OPTIONS, POST'],
        '405 retains one sorted complete Allow field';
};

subtest 'HEAD dispatches to GET only without an explicit head method' => sub {
    my $request = $make_request->('HEAD');
    my $endpoint = TestEndpoint->new;

    my $implicit = $endpoint->dispatch($request)->get;
    is($implicit->status, 200, 'HEAD falls back to GET');

    my $explicit = ExplicitHeadEndpoint->new->dispatch($request)->get;
    is($explicit->status, 202, 'explicit HEAD handler wins');
};

subtest 'Route owns 405 only for its snapshotted method set' => sub {
    my $endpoint = TestEndpoint->new;
    my $route = PAGI::Routing::Route->new(
        path => '/direct', endpoint => $endpoint,
    );
    is($route->methods, ['GET', 'HEAD', 'OPTIONS', 'POST'],
        'Route snapshots the endpoint capability, including HEAD and OPTIONS');

    my $routed = PAGI::Test::Client->new(app => $route->to_app);
    my $router_405 = $routed->put('/direct');
    is($router_405->status, 405, 'unsupported method receives a Router-owned 405');
    is($router_405->header('Allow'), 'GET, HEAD, OPTIONS, POST',
        'Router-owned 405 exposes the immutable Route snapshot');

    my $broader = PAGI::Routing::Route->new(
        path => '/broad', endpoint => $endpoint, methods => '*',
    );
    my $endpoint_405 = PAGI::Test::Client->new(app => $broader->to_app)->put('/broad');
    is($endpoint_405->status, 405,
        'a broader Route delegates unsupported methods to the endpoint');
    is($endpoint_405->header('Allow'), 'GET, HEAD, OPTIONS, POST',
        'the standalone endpoint retains its own 405 Allow response');

    my $mounted = PAGI::Routing::Router->new(routes => [
        PAGI::Routing::Mount->new('/mounted', app => $endpoint),
    ]);
    my $mounted_405 = PAGI::Test::Client->new(app => $mounted->to_app)->put('/mounted');
    is($mounted_405->status, 405,
        'an opaque mounted endpoint retains its own method handling');
};

done_testing;
