#!/usr/bin/env perl
# Files from disk with PAGI::Response::File: this example serves its own
# source, shown in the browser and as a download. Ranges and If-Range work,
# as a download manager or a video player uses them.
#
#   pagi-server --app examples/response/file.pl --port 5000
#   curl -i http://localhost:5000/                  # 200, ETag, Last-Modified
#   curl -i -r 0-99 http://localhost:5000/          # the first 100 bytes: 206
#   curl -i -r 999999- http://localhost:5000/       # past the end: 416
#   curl -OJ http://localhost:5000/download         # saved as file-example.pl

use v5.40;
use Future::AsyncAwait;
use File::Spec;
use PAGI::Response::File;
use PAGI::Response::Text;

# File needs an absolute path: the server opens it, not this process's
# working directory.
my $source = File::Spec->rel2abs(__FILE__);

my $app = async sub ($scope, $receive, $send) {
    die "unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';

    my $response =
        $scope->{path} eq '/'         ? PAGI::Response::File->new(path => $source, content_type => 'text/plain; charset=utf-8')
      : $scope->{path} eq '/download' ? PAGI::Response::File->new(path => $source, filename => 'file-example.pl')
      :                                 PAGI::Response::Text->new(status => 404, content => "Not Found\n");

    await $response->call($scope, $receive, $send);
};

$app;
