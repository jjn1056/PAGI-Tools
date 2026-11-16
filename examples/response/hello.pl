#!/usr/bin/env perl
# Hello, World with PAGI::Response: give it the content and its type, and it
# works out the length. Anything but / is a 404.
#
#   pagi-server --app examples/response/hello.pl --port 5000
#   curl -i http://localhost:5000/
#   curl -i http://localhost:5000/nope

use v5.40;
use Future::AsyncAwait;
use PAGI::Response;

my $app = async sub ($scope, $receive, $send) {
    die "unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';

    my $response = $scope->{path} eq '/'
        ? PAGI::Response->new(content => "Hello, World!\n", content_type => 'text/plain; charset=utf-8')
        : PAGI::Response->new(status => 404, content => "Not Found\n", content_type => 'text/plain; charset=utf-8');

    await $response->call($scope, $receive, $send);
};

$app;
