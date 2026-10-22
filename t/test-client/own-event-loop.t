use strict;
use warnings;
use Test2::V0;

use lib 't/lib';
use PAGITest::FutureXS qw(known_future_xs_warning);
use PAGI::Test::Client;
use PAGITest::OwnLoopApp qw(own_loop_app);

# An application waiting on a loop of its own, with Future::IO bound to no
# loop: nothing runs that loop, so every wait times out, and each timeout says
# what to do. t/test-client/own-event-loop-bound.t is the same application
# with the binding.

my $hint = qr/If the application waits on an event loop of its own, bind Future::IO to that loop in the test/;
local $PAGI::Test::_Drive::TIMEOUT = 0.3;
my $client = PAGI::Test::Client->new(app => own_loop_app());

subtest 'an HTTP request' => sub {
    my @warnings;
    my $error = do { local $SIG{__WARN__} = sub { push @warnings, @_ }; dies { $client->get('/') } };
    like($error, qr/PAGI request did not complete within 0\.3 seconds/, 'times out');
    like($error, $hint, 'and says what to do');
    # Cancelling the timed-out IO::Async::Future trips the lost-sequence
    # warning of Future::XS before 0.16 (RT #181389); nothing else may warn.
    is([grep { !known_future_xs_warning($_) } @warnings], [], 'no other warning');
};

subtest 'lifespan startup' => sub {
    my $error = dies { PAGI::Test::Client->new(app => own_loop_app(), lifespan => 1)->start };
    like($error, qr/PAGI lifespan startup did not complete within 0\.3 seconds/, 'times out');
    like($error, $hint, 'and says what to do');
};

subtest 'a WebSocket handshake' => sub {
    my $error = dies { $client->websocket('/late-accept') };
    like($error, qr/WebSocket handshake did not complete within 0\.3 seconds/, 'times out');
    like($error, $hint, 'and says what to do');
};

subtest 'a WebSocket receive' => sub {
    my $ws = $client->websocket('/late-send');
    my $error = dies { $ws->receive_text(0.3) };
    like($error, qr/Timeout waiting for WebSocket text message/, 'times out');
    like($error, $hint, 'and says what to do');
    $ws->close;
};

subtest 'an SSE start' => sub {
    my $error = dies { $client->sse('/late-start') };
    like($error, qr/SSE stream did not start within 0\.3 seconds/, 'times out');
    like($error, $hint, 'and says what to do');
};

subtest 'an SSE receive' => sub {
    my $sse = $client->sse('/late-send');
    my $error = dies { $sse->receive_event(timeout => 0.3) };
    like($error, qr/Timeout waiting for SSE event/, 'times out');
    like($error, $hint, 'and says what to do');
    $sse->close;
};

done_testing;
