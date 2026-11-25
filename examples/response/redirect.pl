#!/usr/bin/env perl
# Redirects with PAGI::Response::Redirect: a status and a Location, with the
# URL percent-encoded as UTF-8 for you.
#
#   pagi-server --app examples/response/redirect.pl --port 5000
#   curl -i http://localhost:5000/old                     # 308 Permanent Redirect to /new
#   curl -i -X POST 'http://localhost:5000/search?q=Grüße'   # 303 to /results?q=Gr%C3%BC%C3%9Fe
#   curl -i -X POST http://localhost:5000/login          # 303 to /, with a session cookie
#   curl -iL http://localhost:5000/old                    # follow it to /new

use v5.40;
use utf8;
use Future::AsyncAwait;
use Encode ();
use PAGI::Response::Redirect;
use PAGI::Response::Text;

# A value for a query or a path segment: UTF-8, then everything but the
# unreserved characters percent-encoded (RFC 3986). Redirect leaves these
# escapes alone, and only it can't tell your & from a value's.
sub escape_value ($value) {
    my $bytes = Encode::encode('UTF-8', $value);
    $bytes =~ s/([^A-Za-z0-9\-._~])/sprintf '%%%02X', ord $1/ge;
    return $bytes;
}

# The query string's q, unescaped and decoded from UTF-8: characters.
sub query_q ($query) {
    my ($value) = ($query // '') =~ /(?:\A|&)q=([^&]*)/;
    return '' unless defined $value;
    $value =~ tr/+/ /;
    $value =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
    return Encode::decode('UTF-8', $value);
}

my $app = async sub ($scope, $receive, $send) {
    die "unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';
    my ($method, $path) = @$scope{qw(method path)};

    my $response;
    if ($path eq '/old') {
        # Moved for good, and the method kept: 308.
        $response = PAGI::Response::Redirect->new(url => '/new', status => 308);
    }
    elsif ($path eq '/search' && $method eq 'POST') {
        # After a POST, See Other: the browser GETs the results. The value
        # goes in the URL encoded, so an & or # in it stays part of it.
        my $q = escape_value(query_q($scope->{query_string}));
        $response = PAGI::Response::Redirect->new(url => "/results?q=$q", status => 303);
    }
    elsif ($path eq '/login' && $method eq 'POST') {
        $response = PAGI::Response::Redirect->new(url => '/', status => 303)
            ->set_cookie(session => 'abc123', httponly => 1, samesite => 'lax');
    }
    elsif ($path eq '/new' || $path eq '/' || $path eq '/results') {
        $response = PAGI::Response::Text->new(content => "You are at $path\n");
    }
    else {
        $response = PAGI::Response::Text->new(status => 404, content => "Not Found\n");
    }

    await $response->call($scope, $receive, $send);
};

$app;
