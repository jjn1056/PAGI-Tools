use strict;
use warnings;
use Test2::V0;

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

done_testing;
