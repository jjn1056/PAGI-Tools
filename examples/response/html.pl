#!/usr/bin/env perl
# HTML with PAGI::Response::HTML: characters in, UTF-8 HTML out. HTML sends
# the markup you give it as it is, so a value from the request is escaped
# before it goes in.
#
#   pagi-server --app examples/response/html.pl --port 5000
#   curl -i http://localhost:5000/
#   curl -i 'http://localhost:5000/hello?name=Ada'
#   curl -i 'http://localhost:5000/hello?name=%3Cscript%3E'     # sent as &lt;script&gt;

use v5.40;
use utf8;
use Future::AsyncAwait;
use Encode ();
use PAGI::Response::HTML;

# A value for the markup: the five characters HTML gives meaning, escaped.
sub escape ($text) {
    my %entity = ('&' => '&amp;', '<' => '&lt;', '>' => '&gt;', '"' => '&quot;', "'" => '&#39;');
    return $text =~ s/([&<>"'])/$entity{$1}/gr;
}

# One query parameter, unescaped and decoded from UTF-8.
sub param ($query, $name) {
    for my $pair (split /&/, $query // '') {
        my ($key, $value) = split /=/, $pair, 2;
        next unless defined $key && $key eq $name;
        $value = ($value // '') =~ tr/+/ /r;
        $value =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
        return Encode::decode('UTF-8', $value);
    }
    return undef;
}

sub page ($title, $body) {
    return PAGI::Response::HTML->new(content => <<~HTML);
        <!doctype html>
        <html><head><meta charset="utf-8"><title>$title</title></head>
        <body>$body</body></html>
        HTML
}

my $app = async sub ($scope, $receive, $send) {
    die "unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';

    my $response;
    if ($scope->{path} eq '/') {
        $response = page('Hello', '<p>Grüße 🌍 — try <a href="/hello?name=Ada">/hello?name=Ada</a></p>');
    }
    elsif ($scope->{path} eq '/hello') {
        my $name = escape(param($scope->{query_string}, 'name') // 'stranger');
        $response = page("Hello, $name", "<p>Hello, $name!</p>");
    }
    else {
        $response = PAGI::Response::HTML->new(status => 404, content => "<p>Not Found</p>\n");
    }

    await $response->call($scope, $receive, $send);
};

$app;
