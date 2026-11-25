#!/usr/bin/env perl
# Hello, World as text, HTML and JSON: give Text and HTML characters and JSON
# data, and each sends UTF-8, with the type and the length. Anything else is
# a 404.
#
#   pagi-server --app examples/response/hello.pl --port 5000
#   curl -i http://localhost:5000/
#   curl -i http://localhost:5000/html
#   curl -i http://localhost:5000/json
#   curl -i http://localhost:5000/nope

use v5.40;
use utf8;
use Future::AsyncAwait;
use PAGI::Response::Text;
use PAGI::Response::HTML;
use PAGI::Response::JSON;

my $app = async sub ($scope, $receive, $send) {
    die "unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';

    my $response = $scope->{path} eq '/'     ? PAGI::Response::Text->new(content => "Hello, 🌍!\n")
                 : $scope->{path} eq '/html' ? PAGI::Response::HTML->new(content => "<p>Hello, 🌍!</p>\n")
                 : $scope->{path} eq '/json' ? PAGI::Response::JSON->new(content => { hello => '🌍' })
                 :                             PAGI::Response::Text->new(status => 404, content => "Not Found\n");

    await $response->call($scope, $receive, $send);
};

$app;
