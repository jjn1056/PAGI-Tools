use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw(isweak);

use lib 'lib';
use lib 't/lib';
use PAGI::WebSocket;
use PAGITest::Connected qw(ws_scope receive_from send_to);

# The SUBCLASSING contract in PAGI::WebSocket: a subclass adds fields under
# names other than scope, receive, send and _-prefixed ones, and one object
# is built per connection, after the final route match.

{
    package Local::Socket;
    our @ISA = ('PAGI::WebSocket');
    sub new {
        my ($class, @args) = @_;
        my $self = $class->SUPER::new(@args);
        $self->{room} = $self->scope->{path_params}{room};
        return $self;
    }
    sub room { $_[0]{room} }
}

subtest 'one object, built after matching, drives the connection' => sub {
    my $scope = ws_scope(path => '/rooms/lobby');
    $scope->{path_params} = { room => 'lobby' };    # the router's match, in place
    my @sent;
    my $ws = Local::Socket->new($scope,
        receive_from($scope, { type => 'websocket.connect' }), send_to($scope, \@sent));

    $ws->accept->get;
    $ws->send_text('hello ' . $ws->room)->get;
    $ws->close->get;

    is([ map { $_->{type} } @sent ], [ 'websocket.accept', 'websocket.send', 'websocket.close' ],
        'accept, send, close');
    is($sent[1]{text}, 'hello lobby', 'the path parameter reached it through the scope');
    ok($ws->is_closed, 'closed');
    is($ws->room, 'lobby', "the subclass's own field survives the lifecycle");
};

subtest 'a copy of the scope carries the object, so building again over it returns the first' => sub {
    # Why the object is built where the channels are final rather than rebuilt
    # over a middleware's copy of the scope, as a Request is (SUBCLASSING).
    my $scope = ws_scope();
    my $first = PAGI::WebSocket->new($scope, receive_from($scope), send_to($scope, []));
    my $copy  = { %$scope, 'my.addition' => 1 };    # what modify_scope makes
    my @sent;
    my $again = PAGI::WebSocket->new($copy, receive_from($copy), send_to($copy, \@sent));
    is($again, exact_ref($first), 'new over the copy returns the object built first');
    is($again->scope, exact_ref($scope), 'still bound to the first scope');
    ok(isweak($scope->{'pagi.websocket'}), 'the original scope holds it weakly');
    ok(!isweak($copy->{'pagi.websocket'}), 'the copy holds it strongly');
};

done_testing;
