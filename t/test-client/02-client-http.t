#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Test::Client;

# Simple test app
my $app = async sub {
    my ($scope, $receive, $send) = @_;

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'text/plain']],
    });

    await $send->({
        type => 'http.response.body',
        body => 'Hello World',
        more => 0,
    });
};

subtest 'basic GET request' => sub {
    my $client = PAGI::Test::Client->new(app => $app);
    my $res = $client->get('/');

    is $res->status, 200, 'status 200';
    is $res->text, 'Hello World', 'body';
    is $res->header('content-type'), 'text/plain', 'content-type';
};

subtest 'GET with path' => sub {
    my $path_app = async sub {
        my ($scope, $receive, $send) = @_;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => "Path: $scope->{path}",
            more => 0,
        });
    };

    my $client = PAGI::Test::Client->new(app => $path_app);
    my $res = $client->get('/users/123');

    is $res->text, 'Path: /users/123', 'path passed to app';
};

done_testing;
