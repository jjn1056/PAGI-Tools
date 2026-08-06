#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Scalar::Util qw(refaddr);
use PAGI::Routing::HeadBoundary;

sub capture_send {
    my @events;
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    return ($send, \@events);
}

subtest 'non-HEAD is an identity pass-through' => sub {
    my $scope = { type => 'http', method => 'GET' };
    my ($send) = capture_send();
    my ($inner_scope, $inner_send)
        = PAGI::Routing::HeadBoundary->prepare($scope, $send);
    is(refaddr($inner_scope), refaddr($scope), 'scope identity is retained');
    is(refaddr($inner_send), refaddr($send), 'send identity is retained');
};

subtest 'the first HEAD owner clones once and nested preparation is idempotent' => sub {
    my $scope = { type => 'http', method => 'HEAD', path => '/' };
    my ($send) = capture_send();
    my ($owned_scope, $wire_send)
        = PAGI::Routing::HeadBoundary->prepare($scope, $send);
    isnt(refaddr($owned_scope), refaddr($scope), 'owner receives a shallow clone');
    is($scope, { type => 'http', method => 'HEAD', path => '/' }, 'input is untouched');

    my ($nested_scope, $nested_send)
        = PAGI::Routing::HeadBoundary->prepare($owned_scope, $wire_send);
    is(refaddr($nested_scope), refaddr($owned_scope), 'nested owner reuses scope');
    is(refaddr($nested_send), refaddr($wire_send), 'nested owner does not wrap again');
};

subtest 'HEAD forwards metadata and emits one empty terminal body' => sub {
    my ($transport, $events) = capture_send();
    my (undef, $send) = PAGI::Routing::HeadBoundary->prepare(
        { type => 'http', method => 'HEAD' }, $transport,
    );
    my $start = { type => 'http.response.start', status => 200, headers => [] };
    my $other = { type => 'http.response.diagnostic', detail => 'kept' };
    $send->($start)->get;
    $send->({ type => 'http.response.body', body => 'one', more => 1 })->get;
    $send->({ type => 'http.response.body', file => 'never-open', length => 9 })->get;
    $send->({ type => 'http.response.trailers', headers => [['x-end', 'drop']] })->get;
    $send->($other)->get;
    $send->({ type => 'http.response.body', body => 'late', more => 0 })->get;

    is($events, [
        $start,
        { type => 'http.response.body', body => '', more => 0 },
        $other,
    ], 'nonterminal/file bytes, trailers, and late bodies never reach transport');
};

like(
    dies { PAGI::Routing::HeadBoundary->prepare([], sub { Future->done }) },
    qr/HEAD boundary scope must be a hashref/,
    'invalid scope fails synchronously',
);
like(
    dies { PAGI::Routing::HeadBoundary->prepare({}, []) },
    qr/HEAD boundary send must be a coderef/,
    'invalid send fails synchronously',
);

done_testing;
