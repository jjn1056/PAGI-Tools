#!/usr/bin/env perl
# Plain text with PAGI::Response::Text: you give it characters, and it sends
# UTF-8, with the charset in the Content-Type. `use utf8` makes the strings
# in this file characters; the request path arrives as characters already.
#
#   pagi-server --app examples/response/text.pl --port 5000
#   curl -i http://localhost:5000/                     # Grüße, 世界 🌍 (UTF-8 bytes on the wire)
#   curl -i http://localhost:5000/hello/Zoë            # Hello, Zoë! (curl sends Zo%C3%AB)
#   curl -i http://localhost:5000/count/naïve          # naïve: 5 characters, 6 bytes
#   curl -i http://localhost:5000/empty                # no content: an empty body
#   curl -i http://localhost:5000/name                 # an object that stringifies: its string

use v5.40;
use utf8;
use Future::AsyncAwait;
use Encode ();
use PAGI::Response::Text;

# An object that stringifies is sent as its string.
package Greeting {
    use overload '""' => sub ($self, @) { "Bonjour, $self->{name}!\n" }, fallback => 1;
    sub new ($class, $name) { bless { name => $name }, $class }
}

my $app = async sub ($scope, $receive, $send) {
    die "unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';
    my $path = $scope->{path};    # percent-decoded, then decoded from UTF-8: characters

    my $response;
    if ($path eq '/') {
        $response = PAGI::Response::Text->new(content => "Grüße, 世界 🌍\n");
    }
    elsif ($path =~ m{\A/hello/(.+)\z}) {
        $response = PAGI::Response::Text->new(content => "Hello, $1!\n");
    }
    elsif ($path =~ m{\A/count/(.+)\z}) {
        my $word = $1;
        my $bytes = length Encode::encode('UTF-8', $word);
        $response = PAGI::Response::Text->new(content => "$word: " . length($word) . " characters, $bytes bytes\n");
    }
    elsif ($path eq '/empty') {
        $response = PAGI::Response::Text->new;
    }
    elsif ($path eq '/name') {
        $response = PAGI::Response::Text->new(content => Greeting->new('Chloé'));
    }
    else {
        $response = PAGI::Response::Text->new(status => 404, content => "Not Found\n");
    }
    await $response->call($scope, $receive, $send);
};

$app;
