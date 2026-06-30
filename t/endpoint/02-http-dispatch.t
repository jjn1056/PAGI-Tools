#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Endpoint::HTTP;
use PAGI::Context;

package TestEndpoint {
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;

    async sub get {
        my ($self, $ctx) = @_;
        return $ctx->response->text("GET response");
    }

    async sub post {
        my ($self, $ctx) = @_;
        return $ctx->response->text("POST response");
    }
}

my $make_ctx = sub {
    my ($method) = @_;
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'http.request', body => '' }) };
    my $scope = {
        type    => 'http',
        method  => $method,
        path    => '/test',
        headers => [],
    };
    my $ctx = PAGI::Context->new($scope, $receive, $send);
    return ($ctx, \@sent);
};

subtest 'dispatches GET to get method' => sub {
    my ($ctx, $sent) = $make_ctx->('GET');
    my $endpoint = TestEndpoint->new;

    $endpoint->dispatch($ctx)->get;

    is($sent->[1]{body}, 'GET response', 'GET dispatched correctly');
};

subtest 'dispatches POST to post method' => sub {
    my ($ctx, $sent) = $make_ctx->('POST');
    my $endpoint = TestEndpoint->new;

    $endpoint->dispatch($ctx)->get;

    is($sent->[1]{body}, 'POST response', 'POST dispatched correctly');
};

subtest 'returns 405 for unimplemented method' => sub {
    my ($ctx, $sent) = $make_ctx->('PUT');
    my $endpoint = TestEndpoint->new;

    $endpoint->dispatch($ctx)->get;

    is($sent->[0]{status}, 405, '405 status for unimplemented');
};

subtest 'HEAD dispatches to get but ships no body' => sub {
    my ($ctx, $sent) = $make_ctx->('HEAD');
    my $endpoint = TestEndpoint->new;

    $endpoint->dispatch($ctx)->get;

    # HEAD routes to the GET handler (so Content-Length reflects the GET body)
    # but the body itself is suppressed.
    my %h = map { lc($_->[0]) => $_->[1] } @{ $sent->[0]{headers} // [] };
    is($h{'content-length'}, length('GET response'), 'Content-Length from the GET body');
    is($sent->[1]{body}, '', 'HEAD response carries no body');
};

done_testing;
