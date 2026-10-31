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
    is($sse->path, '/feeds/prices', 'a subclass whose new calls SUPER::new answers path');
};

subtest 'a copy of the scope gets its own object, bound to the copy' => sub {
    # One object per scope (SUBCLASSING): new never returns an object built
    # earlier, so a middleware's copy of the scope gets a new one.
    my $scope = sse_scope();
    my $first = PAGI::SSE->new($scope, receive_from($scope), send_to($scope, []));
    my $copy  = { %$scope, 'my.addition' => 1 };    # what modify_scope makes
    my $again = PAGI::SSE->new($copy, receive_from($copy), send_to($copy, []));
    isnt($again, exact_ref($first), 'new over the copy builds a new object');
    is($again->scope, exact_ref($copy), 'bound to the copy');
    is($first->scope, exact_ref($scope), 'the first still bound to the first scope');
    ok(!exists $scope->{'pagi.sse'}, 'the scope does not hold the object');
    ok(!exists $copy->{'pagi.sse'}, 'nor does the copy');
};

{
    # A framework constructor that takes named arguments and blesses the
    # fields itself, calling nothing in PAGI::SSE->new. Thunderhorse's Mooish
    # constructor does call it, through FOREIGNBUILDARGS; this is the other
    # shape a framework may take.
    package Local::MooishFeed;
    our @ISA = ('PAGI::SSE');
    sub new {
        my ($class, %args) = @_;
        return bless { map { $_ => $args{$_} } qw(scope receive send) }, $class;
    }
}

subtest 'a subclass with a hash-args constructor answers from the scope' => sub {
    my $scope = sse_scope(
        path         => '/feeds/prices',
        path_params  => { topic => 'prices' },
        query_string => 'page=2',
        headers      => [ ['Cookie', 'theme=dark'] ],
    );
    my $object = Local::MooishFeed->new(
        scope => $scope, receive => receive_from($scope), send => send_to($scope, []),
    );
    is($object->path, '/feeds/prices', 'path');
    is($object->path_param('topic'), 'prices', 'path_param');
    is($object->query_param('page'), '2', 'query_param');
    is($object->cookie('theme'), 'dark', 'cookie');
};

done_testing;
