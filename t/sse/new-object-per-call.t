use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);
use lib 't/lib';
use PAGI::SSE;
use PAGITest::Connected qw(sse_scope);

# PAGI::SSE->new builds a new object on every call and writes nothing to the
# scope (RV1): there is no object cache to return the first one from. A
# handler keeps the object it was given and passes it on.

subtest 'a second new over one scope builds a second object' => sub {
    my $scope = sse_scope(path => '/events');
    my $send  = sub { Future->done };
    my $recv  = sub { Future->new };

    my $sse = PAGI::SSE->new($scope, $recv, $send);
    $sse->start->get;

    my $again = PAGI::SSE->new($scope, $recv, $send);
    isnt refaddr($again), refaddr($sse), 'new builds a new object';
    ok $sse->is_started, 'the first keeps its own state (is_started)';
    ok !exists $scope->{'pagi.sse'}, 'nothing is cached in the scope';
};

done_testing;
