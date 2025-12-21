#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Request;

subtest 'constructor and basic properties' => sub {
    my $scope = {
        type         => 'http',
        method       => 'GET',
        path         => '/users/42',
        raw_path     => '/users/42',
        query_string => 'foo=bar&baz=qux',
        scheme       => 'https',
        http_version => '1.1',
        headers      => [
            ['host', 'example.com'],
            ['content-type', 'application/json'],
            ['accept', 'text/html'],
            ['accept', 'application/json'],
        ],
        client => ['127.0.0.1', 54321],
    };

    my $req = PAGI::Request->new($scope);

    is($req->method, 'GET', 'method');
    is($req->path, '/users/42', 'path');
    is($req->raw_path, '/users/42', 'raw_path');
    is($req->query_string, 'foo=bar&baz=qux', 'query_string');
    is($req->scheme, 'https', 'scheme');
    is($req->host, 'example.com', 'host from headers');
    is($req->content_type, 'application/json', 'content_type');
    is($req->client, ['127.0.0.1', 54321], 'client');
};

subtest 'predicate methods' => sub {
    my $get_scope = { type => 'http', method => 'GET', headers => [] };
    my $post_scope = { type => 'http', method => 'POST', headers => [] };

    my $get_req = PAGI::Request->new($get_scope);
    my $post_req = PAGI::Request->new($post_scope);

    ok($get_req->is_get, 'is_get true for GET');
    ok(!$get_req->is_post, 'is_post false for GET');
    ok($post_req->is_post, 'is_post true for POST');
    ok(!$post_req->is_get, 'is_get false for POST');
};

done_testing;
