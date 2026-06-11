use strict;
use warnings;
use Test2::V0;

use PAGI::Request;
use PAGI::WebSocket;
use PAGI::SSE;
use PAGI::Context;

# The high-level helpers expose buffered_amount / high_water_mark /
# low_water_mark by delegating to the server-provided pagi.transport handle,
# and degrade gracefully (0 / undef) when it is absent.

# Duck-typed pagi.transport handle.
{
    package MockTransport;
    sub new { bless { buf => $_[1], high => $_[2], low => $_[3] }, $_[0] }
    sub buffered_amount { $_[0]{buf} }
    sub high_water_mark { $_[0]{high} }
    sub low_water_mark  { $_[0]{low} }
}

my $recv = sub { };
my $send = sub { };

sub mk_request {
    my ($t) = @_;
    my $scope = { type => 'http', method => 'GET', headers => [] };
    $scope->{'pagi.transport'} = $t if $t;
    return PAGI::Request->new($scope);
}
sub mk_ws {
    my ($t) = @_;
    my $scope = { type => 'websocket', headers => [] };
    $scope->{'pagi.transport'} = $t if $t;
    return PAGI::WebSocket->new($scope, $recv, $send);
}
sub mk_sse {
    my ($t) = @_;
    my $scope = { type => 'sse', headers => [] };
    $scope->{'pagi.transport'} = $t if $t;
    return PAGI::SSE->new($scope, $recv, $send);
}
sub mk_ctx {
    my ($t) = @_;
    my $scope = { type => 'http', method => 'GET', headers => [] };
    $scope->{'pagi.transport'} = $t if $t;
    return PAGI::Context->new($scope, $recv, $send);
}

my @cases = (
    ['PAGI::Request',   \&mk_request],
    ['PAGI::WebSocket', \&mk_ws],
    ['PAGI::SSE',       \&mk_sse],
    ['PAGI::Context',   \&mk_ctx],
);

for my $case (@cases) {
    my ($name, $mk) = @$case;

    subtest "$name delegates to pagi.transport" => sub {
        my $obj = $mk->(MockTransport->new(4096, 65536, 16384));
        is($obj->buffered_amount, 4096,  'buffered_amount delegates');
        is($obj->high_water_mark, 65536, 'high_water_mark delegates');
        is($obj->low_water_mark,  16384, 'low_water_mark delegates');
    };

    subtest "$name graceful without pagi.transport" => sub {
        my $obj = $mk->(undef);
        is($obj->buffered_amount, 0,     'buffered_amount is 0 when handle absent');
        is($obj->high_water_mark, undef, 'high_water_mark undef when handle absent');
        is($obj->low_water_mark,  undef, 'low_water_mark undef when handle absent');
    };
}

done_testing;
