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
    is($ws->path, '/rooms/lobby', 'a subclass whose new calls SUPER::new answers path');
};

subtest 'a copy of the scope gets its own object, bound to the copy' => sub {
    # One object per scope (SUBCLASSING): new never returns an object built
    # earlier, so a middleware's copy of the scope gets a new one.
    my $scope = ws_scope();
    my $first = PAGI::WebSocket->new($scope, receive_from($scope), send_to($scope, []));
    my $copy  = { %$scope, 'my.addition' => 1 };    # what modify_scope makes
    my $again = PAGI::WebSocket->new($copy, receive_from($copy), send_to($copy, []));
    isnt($again, exact_ref($first), 'new over the copy builds a new object');
    is($again->scope, exact_ref($copy), 'bound to the copy');
    is($first->scope, exact_ref($scope), 'the first still bound to the first scope');
    ok(!exists $scope->{'pagi.websocket'}, 'the scope does not hold the object');
    ok(!exists $copy->{'pagi.websocket'}, 'nor does the copy');
};

{
    # A framework constructor that takes named arguments and blesses the
    # fields itself, calling nothing in PAGI::WebSocket->new. Thunderhorse's Mooish
    # constructor does call it, through FOREIGNBUILDARGS; this is the other
    # shape a framework may take.
    package Local::MooishSocket;
    our @ISA = ('PAGI::WebSocket');
    sub new {
        my ($class, %args) = @_;
        return bless { map { $_ => $args{$_} } qw(scope receive send) }, $class;
    }
}

subtest 'a subclass with a hash-args constructor answers from the scope' => sub {
    my $scope = ws_scope(
        path         => '/rooms/lobby',
        path_params  => { room => 'lobby' },
        query_string => 'page=2',
        headers      => [ ['Cookie', 'theme=dark'] ],
    );
    my $object = Local::MooishSocket->new(
        scope => $scope, receive => receive_from($scope), send => send_to($scope, []),
    );
    is($object->path, '/rooms/lobby', 'path');
    is($object->path_param('room'), 'lobby', 'path_param');
    is($object->query_param('page'), '2', 'query_param');
    is($object->cookie('theme'), 'dark', 'cookie');
};

done_testing;
