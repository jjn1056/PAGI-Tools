#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Request;
use PAGI::Response;

subtest 'can create endpoint subclass' => sub {
    require PAGI::Endpoint::HTTP;

    package MyEndpoint {
        use parent 'PAGI::Endpoint::HTTP';
        use Future::AsyncAwait;

        async sub get {
            my ($self, $request) = @_;
            return PAGI::Response->text("Hello");
        }
    }

    my $endpoint = MyEndpoint->new;
    isa_ok($endpoint, 'PAGI::Endpoint::HTTP');
    isa_ok($endpoint, 'MyEndpoint');
};

subtest 'HTTP handlers are Request-first' => sub {
    require PAGI::Endpoint::HTTP;

    my $request = PAGI::Request->new({
        type => 'http', method => 'GET', path => '/', headers => [],
    }, sub { Future->done({ type => 'http.request' }) });
    my $response = MyEndpoint->new->dispatch($request)->get;

    isa_ok($request, ['PAGI::Request']);
    isa_ok($response, ['PAGI::Response']);
};

subtest 'context_class is not an extension hook' => sub {
    ok(!PAGI::Endpoint::HTTP->can('context_class'),
        'base endpoint has no context_class');

    package CustomEndpoint {
        use parent 'PAGI::Endpoint::HTTP';
    }

    ok(!CustomEndpoint->can('context_class'),
        'subclass inherits no context_class');
};

done_testing;
