use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw(isweak);

use lib 'lib';
use lib 't/lib';
use PAGI::SSE;
use PAGITest::Connected qw(sse_scope receive_from send_to);

# The SUBCLASSING contract in PAGI::SSE: a subclass adds fields under names
# other than scope, receive, send and _-prefixed ones, and one object is
# built per connection, after the final route match.

{
    package Local::Feed;
    our @ISA = ('PAGI::SSE');
    sub new {
        my ($class, @args) = @_;
        my $self = $class->SUPER::new(@args);
        $self->{topic} = $self->scope->{path_params}{topic};
        return $self;
    }
    sub topic { $_[0]{topic} }
}

subtest 'one object, built after matching, drives the stream' => sub {
    my $scope = sse_scope(path => '/feeds/prices');
    $scope->{path_params} = { topic => 'prices' };    # the router's match, in place
    my @sent;
    my $sse = Local::Feed->new($scope, receive_from($scope), send_to($scope, \@sent));

    $sse->start->get;
    $sse->send('update on ' . $sse->topic)->get;
    $sse->close->get;

    is([ map { $_->{type} } @sent ], [ 'sse.start', 'sse.send', 'sse.close' ],
        'start, send, close');
    is($sent[1]{data}, 'update on prices', 'the path parameter reached it through the scope');
    ok($sse->is_closed, 'closed');
    is($sse->topic, 'prices', "the subclass's own field survives the lifecycle");
};

subtest 'a copy of the scope carries the object, so building again over it returns the first' => sub {
    # Why the object is built where the channels are final rather than rebuilt
    # over a middleware's copy of the scope, as a Request is (SUBCLASSING).
    my $scope = sse_scope();
    my $first = PAGI::SSE->new($scope, receive_from($scope), send_to($scope, []));
    my $copy  = { %$scope, 'my.addition' => 1 };    # what modify_scope makes
    my @sent;
    my $again = PAGI::SSE->new($copy, receive_from($copy), send_to($copy, \@sent));
    is($again, exact_ref($first), 'new over the copy returns the object built first');
    is($again->scope, exact_ref($scope), 'still bound to the first scope');
    ok(isweak($scope->{'pagi.sse'}), 'the original scope holds it weakly');
    ok(!isweak($copy->{'pagi.sse'}), 'the copy holds it strongly');
};

done_testing;
