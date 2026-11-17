#!/usr/bin/env perl
# Cookies on a response: / greets you by the username cookie, then sets it
# to Zoë 🌍 for an hour; /clear deletes it. A cookie carries only some
# bytes, so the name goes in encoded and comes out decoded.
#
#   pagi-server --app examples/response/cookie.pl --port 5000
#   curl -i http://localhost:5000/
#   curl -i -b 'username=Zo%C3%AB%20%F0%9F%8C%8D' http://localhost:5000/
#   curl -i http://localhost:5000/clear

use v5.40;
use utf8;
use Future::AsyncAwait;
use Encode ();
use URI::Escape qw(uri_escape_utf8 uri_unescape);
use PAGI::Response::Text;

# The request's cookies, raw as sent: name=value pairs, '; ' between
# (RFC 6265 4.2). The first of a name wins.
sub request_cookies ($scope) {
    my %cookies;
    for my $header (grep { $_->[0] eq 'cookie' } $scope->{headers}->@*) {
        for my $pair (split /;\s*/, $header->[1]) {
            my ($name, $value) = split /=/, $pair, 2;
            $cookies{$name} //= $value if defined $value;
        }
    }
    return \%cookies;
}

my $app = async sub ($scope, $receive, $send) {
    die "unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';

    # A cookie value is bytes, and only cookie-octets (RFC 6265): text goes
    # in as UTF-8, percent-escaped, and comes out unescaped and decoded.
    my $username = Encode::decode('UTF-8', uri_unescape(request_cookies($scope)->{username} // 'guest'));

    my $response = $scope->{path} eq '/clear'
        ? PAGI::Response::Text->new(content => "Cookie cleared.\n")
            ->delete_cookie('username')
        : PAGI::Response::Text->new(content => "Hello, $username! Cookie set.\n")
            ->set_cookie(username => uri_escape_utf8('Zoë 🌍'), max_age => 3600, httponly => 1, samesite => 'lax');

    await $response->call($scope, $receive, $send);
};

$app;
