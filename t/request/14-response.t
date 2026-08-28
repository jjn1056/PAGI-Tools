use strict;
use warnings;
use Test2::V0;
use PAGI::Request;

my $request = PAGI::Request->new(
    { type => 'http', method => 'GET', headers => [], path => '/' },
    sub { die 'body unavailable' },
);
ok !$request->can('response'), 'Request no longer vends an outgoing Response';
done_testing;
