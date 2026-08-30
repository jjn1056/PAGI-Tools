use strict;
use warnings;
use Test2::V0;
use Future;
use PAGI::Response;

my $res = PAGI::Response->new("a\x00b");
my @events;
$res->to_app->(
    { type => 'http', method => 'GET' },
    sub { Future->done },
    sub { push @events, $_[0]; Future->done },
)->get;
is $events[1]{body}, "a\x00b", 'byte body survives emission exactly';
is $events[1]{more}, 0, 'base response is terminal';
done_testing;
