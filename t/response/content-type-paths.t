use strict;
use warnings;
use Test2::V0;

use lib 't/lib';
use PAGI::Response qw(response);
use PAGI::Response::Empty ();

# However a Content-Type arrives -- the content_type option, a Content-Type
# pair in the headers option, or header() after construction -- it goes
# through the class's own content_type rule: Text and HTML keep their charset,
# Empty refuses one, and the base class stores it as given.

my %path = (
    'content_type option' => sub { my ($name, $body, $type) = @_; response($name, $body, content_type => $type) },
    'headers option'      => sub { my ($name, $body, $type) = @_; response($name, $body, headers => ['Content-Type' => $type]) },
    'header() after new'  => sub { my ($name, $body, $type) = @_; response($name, $body)->header('Content-Type' => $type) },
    'lower-case header()' => sub { my ($name, $body, $type) = @_; response($name, $body)->header('content-type' => $type) },
);

for my $way (sort keys %path) {
    for my $class ('Text', 'HTML') {
        my $r = $path{$way}->($class, 'x', 'text/csv');
        is($r->content_type, 'text/csv; charset=utf-8', "$class, $way: the charset is kept");
        is(scalar @{ $r->header_all('Content-Type') }, 1, "$class, $way: one Content-Type");
    }
    my $base = $path{$way}->('+PAGI::Response', 'x', 'image/png');
    is($base->content_type, 'image/png', "base class, $way: stored as given");

    like(dies {
        my $empty = PAGI::Response::Empty->new;
        $way eq 'header() after new' || $way eq 'lower-case header()'
            ? $empty->header('Content-Type' => 'text/plain')
            : $way eq 'headers option'
                ? PAGI::Response::Empty->new(headers => ['Content-Type' => 'text/plain'])
                : PAGI::Response::Empty->new(content_type => 'text/plain');
    }, qr/Empty response does not permit Content-Type/, "Empty, $way: refused");
}

is(response('Text', 'x', headers => ['Content-Type' => 'text/csv'], content_type => 'text/tab-separated-values')
    ->content_type, 'text/tab-separated-values; charset=utf-8', 'given both ways, the option wins');

like(dies { response('Text', 'x')->header('Content-Type' => undef) }, qr/Header value is required/,
    'an undef value through header() is still refused');

done_testing;
