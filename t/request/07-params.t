#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Request;

subtest 'params from scope' => sub {
    my $scope = {
        type    => 'http',
        method  => 'GET',
        path    => '/users/42/posts/100',
        headers => [],
        # Router sets params in pagi.router
        'pagi.router' => {
            params => { user_id => '42', post_id => '100' },
            route  => '/users/:user_id/posts/:post_id',
        },
    };

    my $req = PAGI::Request->new($scope);

    is($req->params, { user_id => '42', post_id => '100' }, 'params returns hashref');
    is($req->param('user_id'), '42', 'param() gets single value');
    is($req->param('post_id'), '100', 'param() another value');
    is($req->param('missing'), undef, 'missing param is undef');
};

subtest 'params set via scope' => sub {
    # Simulating how router sets params in scope before handler is called
    my $scope = {
        type => 'http',
        method => 'GET',
        headers => [],
        'pagi.router' => {
            params => { id => '123', slug => 'hello-world' },
        },
    };
    my $req = PAGI::Request->new($scope);

    is($req->param('id'), '123', 'param from scope');
    is($req->param('slug'), 'hello-world', 'another param');
};

subtest 'no params' => sub {
    my $scope = { type => 'http', method => 'GET', headers => [] };
    my $req = PAGI::Request->new($scope);

    is($req->params, {}, 'empty params by default');
    is($req->param('anything'), undef, 'missing returns undef');
};

subtest 'param falls back to query params' => sub {
    my $scope = {
        type => 'http',
        method => 'GET',
        headers => [],
        query_string => 'foo=bar&baz=qux',
        'pagi.router' => {
            params => { id => '42' },
        },
    };
    my $req = PAGI::Request->new($scope);

    # Route param takes precedence
    is($req->param('id'), '42', 'route param exists');
    # Falls back to query param when route param not found
    is($req->param('foo'), 'bar', 'falls back to query param');
    is($req->param('baz'), 'qux', 'another query param');
};

done_testing;
