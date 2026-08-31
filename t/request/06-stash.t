#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Request;
use PAGI::Stash;

my $no_body = sub { die 'body unavailable' };
my $stash_factory = PAGI::Stash->can('stash') ? \&PAGI::Stash::stash : undef;

subtest 'scope accessor returns scope hashref' => sub {
    my $scope = { type => 'http', method => 'GET', headers => [] };
    my $req = PAGI::Request->new($scope, $no_body);
    ok($req->scope == $scope, 'scope returns same hashref');
};

subtest 'stash basic usage' => sub {
    my $scope = { type => 'http', method => 'GET', headers => [] };
    my $req = PAGI::Request->new($scope, $no_body);
    ok($stash_factory, 'stash factory is available') or return;
    my $stash = $stash_factory->($req);

    # Starts empty
    is($stash->data, {}, 'stash starts empty');

    # Can set values
    $stash->set(user => { id => 42, name => 'John' }, authenticated => 1);

    # Can read values
    is($stash->get('user')->{id}, 42, 'read nested value');
    is($stash->get('authenticated'), 1, 'read simple value');
};

subtest 'stash persists on same request' => sub {
    my $scope = { type => 'http', method => 'GET', headers => [] };
    my $req = PAGI::Request->new($scope, $no_body);
    ok($stash_factory, 'stash factory is available') or return;
    my $stash = $stash_factory->($req);

    $stash->set(counter => 1);
    $stash->data->{counter}++;
    $stash->data->{counter}++;

    is($stash->get('counter'), 3, 'modifications persist');
};

subtest 'stash lives in scope' => sub {
    my $scope = { type => 'http', method => 'GET', headers => [] };
    my $req = PAGI::Request->new($scope, $no_body);
    ok($stash_factory, 'stash factory is available') or return;
    my $stash = $stash_factory->($req);

    $stash->set(user => 'alice');

    is($stash->get('user'), 'alice', 'stash persists');
    is($scope->{'pagi.stash'}{user}, 'alice', 'stash lives in scope');
};

subtest 'stash shared via scope' => sub {
    # Same scope = same stash (important for middleware flow)
    my $scope = { type => 'http', method => 'GET', headers => [] };
    ok($stash_factory, 'stash factory is available') or return;
    my $stash1 = $stash_factory->($scope);
    my $stash2 = $stash_factory->($scope);

    $stash1->set(foo => 'bar');

    is($stash2->get('foo'), 'bar', 'same scope = same stash');
};

subtest 'stash isolated with different scopes' => sub {
    # Different scopes = different stashes
    my $scope1 = { type => 'http', method => 'GET', headers => [] };
    my $scope2 = { type => 'http', method => 'GET', headers => [] };
    ok($stash_factory, 'stash factory is available') or return;
    my $stash1 = $stash_factory->($scope1);
    my $stash2 = $stash_factory->($scope2);

    $stash1->set(value => 'first');
    $stash2->set(value => 'second');

    is($stash1->get('value'), 'first', 'req1 has its own stash');
    is($stash2->get('value'), 'second', 'req2 has its own stash');
};

done_testing;
