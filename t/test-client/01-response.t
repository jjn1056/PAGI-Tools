#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Test::Response;

subtest 'basic response accessors' => sub {
    my $res = PAGI::Test::Response->new(
        status  => 200,
        headers => [
            ['content-type', 'text/plain'],
            ['x-custom', 'value'],
        ],
        body => 'Hello World',
    );

    is $res->status, 200, 'status';
    is $res->content, 'Hello World', 'content';
    is $res->text, 'Hello World', 'text';
    is $res->header('content-type'), 'text/plain', 'header lookup';
    is $res->header('X-Custom'), 'value', 'header case-insensitive';
    ok $res->is_success, 'is_success for 2xx';
};

subtest 'status helpers' => sub {
    ok( PAGI::Test::Response->new(status => 200)->is_success, '200 is success' );
    ok( PAGI::Test::Response->new(status => 201)->is_success, '201 is success' );
    ok( PAGI::Test::Response->new(status => 301)->is_redirect, '301 is redirect' );
    ok( PAGI::Test::Response->new(status => 404)->is_error, '404 is error' );
    ok( PAGI::Test::Response->new(status => 500)->is_error, '500 is error' );
};

done_testing;
