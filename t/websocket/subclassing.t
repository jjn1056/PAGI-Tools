use strict;
use warnings;
use Test2::V0;

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

done_testing;
