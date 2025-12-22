#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Endpoint::HTTP;

package MockResponse {
    use v5.32;
    use feature 'signatures';
    no warnings 'experimental::signatures';
    use Future::AsyncAwait;

    sub new ($class) { bless { status => 200, headers => [] }, $class }
    sub status ($self, $s = undef) {
        $self->{status} = $s if defined $s;
        return $self;
    }
    sub header ($self, $name, $value) {
        push @{$self->{headers}}, [$name, $value];
        return $self;
    }
    async sub empty ($self) { return $self }
    async sub text ($self, $body, %opts) {
        $self->{status} = $opts{status} if $opts{status};
        return $self;
    }
    sub get_header ($self, $name) {
        for (@{$self->{headers}}) {
            return $_->[1] if lc($_->[0]) eq lc($name);
        }
        return undef;
    }
}

package MockRequest {
    use v5.32;
    use feature 'signatures';
    no warnings 'experimental::signatures';
    sub new ($class, $method) { bless { method => $method }, $class }
    sub method ($self) { $self->{method} }
}

package CRUDEndpoint {
    use parent 'PAGI::Endpoint::HTTP';
    use v5.32;
    use feature 'signatures';
    no warnings 'experimental::signatures';
    use Future::AsyncAwait;

    async sub get ($self, $req, $res) { await $res->empty }
    async sub post ($self, $req, $res) { await $res->empty }
    async sub delete ($self, $req, $res) { await $res->empty }
}

subtest 'OPTIONS returns allowed methods' => sub {
    my $endpoint = CRUDEndpoint->new;
    my $req = MockRequest->new('OPTIONS');
    my $res = MockResponse->new;

    $endpoint->dispatch($req, $res)->get;

    my $allow = $res->get_header('Allow');
    ok(defined $allow, 'Allow header set');
    like($allow, qr/GET/, 'includes GET');
    like($allow, qr/POST/, 'includes POST');
    like($allow, qr/DELETE/, 'includes DELETE');
    like($allow, qr/HEAD/, 'includes HEAD (implicit from GET)');
    like($allow, qr/OPTIONS/, 'includes OPTIONS');
};

subtest '405 response includes Allow header' => sub {
    my $endpoint = CRUDEndpoint->new;
    my $req = MockRequest->new('PATCH');  # Not implemented
    my $res = MockResponse->new;

    $endpoint->dispatch($req, $res)->get;

    my $allow = $res->get_header('Allow');
    ok(defined $allow, 'Allow header set on 405');
};

done_testing;
