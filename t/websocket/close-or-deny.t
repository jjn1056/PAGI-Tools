use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use PAGI::Response::Text;
use lib 't/lib';
use PAGITest::RefusalHarness;

# close_or_deny ends a WebSocket however its state allows: an HTTP refusal
# before accept, a Close frame after it, and nothing once the connection is
# gone -- a client that hung up must not turn into an application error.

subtest 'before accept it denies with a 403 carrying the reason' => sub {
    my $h = PAGITest::RefusalHarness->new('websocket');
    $h->{helper}->close_or_deny(4004, 'Not Found')->get;
    is $h->{events}[0]{type}, 'http.response.start', 'an HTTP refusal';
    is $h->{events}[0]{status}, 403, 'status 403 by default';
    is $h->{events}[1]{body}, 'Not Found', 'the reason is the body';
    ok $h->{helper}->is_closed, 'the connection is closed';
};

subtest 'before accept, with no reason, the body is the status reason' => sub {
    my $h = PAGITest::RefusalHarness->new('websocket');
    $h->{helper}->close_or_deny(1008)->get;
    is $h->{events}[1]{body}, 'Forbidden', 'Forbidden';
};

subtest 'before accept, a given Response answers instead' => sub {
    my $h = PAGITest::RefusalHarness->new('websocket');
    $h->{helper}->close_or_deny(4004, 'Not Found',
        PAGI::Response::Text->new('No such socket', status => 404))->get;
    is $h->{events}[0]{status}, 404, 'its status';
    is $h->{events}[1]{body}, 'No such socket', 'its body';
};

subtest 'after accept it closes with the code and reason' => sub {
    my $h = PAGITest::RefusalHarness->new('websocket');
    my $ws = $h->{helper};
    $ws->accept->get;
    $ws->close_or_deny(1011, 'Internal Server Error',
        PAGI::Response::Text->new('unused', status => 500))->get;
    is [map { $_->{type} } @{ $h->{events} }], ['websocket.accept', 'websocket.close'],
        'a Close frame, no HTTP response';
    is [@{ $h->{events}[1] }{qw(code reason)}], [1011, 'Internal Server Error'], 'code and reason';
};

subtest 'a client that hung up before accept: nothing is sent, nothing dies' => sub {
    my $h = PAGITest::RefusalHarness->new('websocket');
    $h->{connection}->_mark_disconnected('client_closed');
    ok lives { $h->{helper}->close_or_deny(4004, 'Not Found')->get }, 'lives';
    is $h->{events}, [], 'sends nothing';
};

subtest 'a client that hung up after accept: nothing is sent, nothing dies' => sub {
    my $h = PAGITest::RefusalHarness->new('websocket');
    my $ws = $h->{helper};
    $ws->accept->get;
    $h->{connection}->_mark_disconnected('client_closed');
    ok lives { $ws->close_or_deny(1011, 'Internal Server Error')->get }, 'lives';
    is [map { $_->{type} } @{ $h->{events} }], ['websocket.accept'], 'sends nothing more';
};

subtest 'a second call after closing sends nothing more' => sub {
    my $h = PAGITest::RefusalHarness->new('websocket');
    my $ws = $h->{helper};
    $ws->accept->get;
    $ws->close_or_deny(1000)->get;
    $ws->close_or_deny(1000)->get;
    is scalar(grep { $_->{type} eq 'websocket.close' } @{ $h->{events} }), 1, 'one Close frame';
};

done_testing;
