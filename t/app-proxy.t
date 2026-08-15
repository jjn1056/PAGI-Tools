#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use JSON::MaybeXS ();

use lib 'lib';

use PAGI::App::Proxy;

{
    package TestProxyConnectFailure;
    use parent 'PAGI::App::Proxy';

    our @CONNECT_ARGS;

    sub _connect_backend {
        my ($self, @args) = @_;
        @CONNECT_ARGS = @args;
        return;
    }
}

subtest 'backend connection failure negotiates a Pages 502' => sub {
    @TestProxyConnectFailure::CONNECT_ARGS = ();

    my $app = TestProxyConnectFailure->new(
        backend => 'http://127.0.0.1:0',
        timeout => 7,
    )->to_app;

    my @events;
    my $receive = sub {
        Future->done({ type => 'http.request', body => '', more => 0 });
    };
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };

    $app->({
        type         => 'http',
        method       => 'GET',
        path         => '/',
        query_string => '',
        headers      => [['Accept', 'application/json']],
    }, $receive, $send)->get;

    is \@TestProxyConnectFailure::CONNECT_ARGS, ['127.0.0.1', 0, 7],
        'the overridable connector receives the configured backend';
    is [map { $_->{type} } @events],
        ['http.response.start', 'http.response.body'],
        'connection failure emits one complete HTTP response';
    is $events[0]{status}, 502, 'connection failure remains 502';

    my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
    is $headers{'content-type'}, 'application/problem+json',
        'Accept negotiation selects problem JSON';
    is $headers{'cache-control'}, 'no-store',
        'the generic backend failure is not stored';
    is $headers{vary}, 'Accept', 'negotiation retains Vary: Accept';

    my $problem = JSON::MaybeXS::decode_json($events[1]{body});
    is $problem->{status}, 502, 'problem document status matches the wire status';
    is $problem->{title}, 'Bad Gateway', 'problem document uses the stock title';
};

done_testing;
