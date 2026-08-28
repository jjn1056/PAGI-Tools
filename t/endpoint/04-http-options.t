#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Endpoint::HTTP;
use PAGI::Request;
use PAGI::Response;

package CRUDEndpoint {
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;

    sub get {
        my ($self, $request) = @_;
        return PAGI::Response->empty;
    }
    sub post {
        my ($self, $request) = @_;
        return PAGI::Response->empty;
    }
    sub delete {
        my ($self, $request) = @_;
        return PAGI::Response->empty;
    }
}

my $make_request = sub {
    my ($method) = @_;
    my $receive = sub { Future->done({ type => 'http.request', body => '' }) };
    my $scope = {
        type    => 'http',
        method  => $method,
        path    => '/test',
        headers => [],
    };
    return PAGI::Request->new($scope, $receive);
};

subtest 'OPTIONS returns allowed methods' => sub {
    my $request = $make_request->('OPTIONS');
    my $endpoint = CRUDEndpoint->new;

    my $response = $endpoint->dispatch($request)->get;

    my $allow = $response->header('Allow');
    is($allow, 'DELETE, GET, HEAD, OPTIONS, POST',
        'Allow is complete and sorted, including implicit HEAD');
};

subtest '405 response includes Allow header' => sub {
    my $request = $make_request->('PATCH');
    my $endpoint = CRUDEndpoint->new;

    my $response = $endpoint->dispatch($request)->get;

    is($response->status, 405, '405 status for unimplemented method');
    my $allow = $response->header('Allow');
    ok(defined $allow, 'Allow header set on 405');
};

done_testing;
