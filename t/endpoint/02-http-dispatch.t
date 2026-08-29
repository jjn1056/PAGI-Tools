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
    my $request = $make_request->(
        'PUT',
        [['Accept', 'application/json']],
    );
    my $endpoint = TestEndpoint->new;

    my $response = $endpoint->dispatch($request)->get;

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

done_testing;
