#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use JSON::MaybeXS ();

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
    my ($method, $headers) = @_;
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'http.request', body => '' }) };
    my $scope = {
        type    => 'http',
        method  => $method,
        path    => '/test',
        headers => $headers // [],
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
    my ($ctx, $sent) = $make_ctx->(
        'PUT',
        [['Accept', 'application/json']],
    );
    my $endpoint = TestEndpoint->new;

    $endpoint->dispatch($ctx)->get;

    is($sent->[0]{status}, 405, '405 status for unimplemented');
    my @allow = map { $_->[1] }
        grep { lc($_->[0]) eq 'allow' } @{$sent->[0]{headers}};
    is \@allow, ['GET, HEAD, OPTIONS, POST'],
        '405 retains one sorted complete Allow field';

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent->[0]{headers}};
    is $headers{'content-type'}, 'application/problem+json',
        'automatic 405 negotiates problem JSON';
    is $headers{'cache-control'}, 'no-store', 'automatic 405 is not stored';
    my $problem = JSON::MaybeXS::decode_json($sent->[1]{body});
    is $problem->{status}, 405, 'problem status matches the wire status';
    is $problem->{title}, 'Method Not Allowed', 'problem uses the stock title';
};

subtest 'HEAD dispatches to get if no head method' => sub {
    my ($ctx, $sent) = $make_ctx->('HEAD');
    my $endpoint = TestEndpoint->new;

    $endpoint->dispatch($ctx)->get;

    is($sent->[1]{body}, 'GET response', 'HEAD falls back to GET');
};

done_testing;
