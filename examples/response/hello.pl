#!/usr/bin/env perl
# Hello, World with PAGI::Response::Text: give it characters, and it sends
# them as UTF-8, with the type and the length. Anything but / is a 404.
#
#   pagi-server --app examples/response/hello.pl --port 5000
#   curl -i http://localhost:5000/
#   curl -i http://localhost:5000/nope

use v5.40;
use utf8;
use Future::AsyncAwait;
use PAGI::Response::Text;

my $app = async sub ($scope, $receive, $send) {
    die "unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';

    my $response = $scope->{path} eq '/'
        ? PAGI::Response::Text->new(content => "Hello, 🌍!\n")
        : PAGI::Response::Text->new(status => 404, content => "Not Found\n");

    await $response->call($scope, $receive, $send);
};

$app;
