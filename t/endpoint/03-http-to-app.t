#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Endpoint::HTTP;
use PAGI::Response;
use PAGI::Response::Empty ();
use PAGI::Response::Text ();

package HelloEndpoint {
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;

    sub get {
        my ($self, $request) = @_;
        my $name = $request->query_param('name') // 'World';
        return PAGI::Response::Text->new("Hello, $name");
    }
}

package ScopeValidationEndpoint {
    use parent 'PAGI::Endpoint::HTTP';
    our $calls = 0;

    sub get {
        ++$calls;
        return PAGI::Response::Empty->new;
    }
}

subtest 'to_app returns PAGI-compatible coderef' => sub {
    my $app = HelloEndpoint->to_app;

    ref_ok($app, 'CODE', 'to_app returns coderef');
};

subtest 'app handles full request cycle' => sub {
    my $app = HelloEndpoint->to_app;

    my @sent;
    my $scope = {
        type => 'http',
        method => 'GET',
        path => '/hello',
        query_string => 'name=PAGI',
        headers => [],
    };
    my $receive = sub { Future->done({ type => 'http.request' }) };
    my $send = sub { push @sent, $_[0]; Future->done };

    $app->($scope, $receive, $send)->get;

    is(scalar @sent, 2, 'emits exactly a start and terminal body event');
    is($sent[0]{type}, 'http.response.start', 'starts with response.start');
    is($sent[1]{type}, 'http.response.body', 'finishes with response.body');
    is($sent[1]{more}, 0, 'body is terminal');
    is($sent[1]{body}, 'Hello, PAGI', 'Request query reaches handler');
};

subtest 'invalid scopes fail before a handler runs' => sub {
    my $app = ScopeValidationEndpoint->to_app;
    $ScopeValidationEndpoint::calls = 0;

    like(dies {
        $app->({}, sub { Future->done }, sub { Future->done })->get;
    }, qr/PAGI::Request scope type is required/, 'missing type is rejected');
    is($ScopeValidationEndpoint::calls, 0, 'missing type does not call the handler');

    like(dies {
        $app->({ type => 'websocket' }, sub { Future->done }, sub { Future->done })->get;
    }, qr/PAGI::Request requires HTTP scope/, 'non-HTTP type is rejected');
    is($ScopeValidationEndpoint::calls, 0, 'non-HTTP type does not call the handler');
};

done_testing;
