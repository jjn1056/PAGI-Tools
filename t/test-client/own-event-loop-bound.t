use strict;
use warnings;
use Test2::V0;

# The application owns its loop, so the test binds Future::IO to it, as
# PAGI::Test::Client's "TESTING AN APPLICATION THAT COMMITS TO AN EVENT LOOP"
# says; then the client runs that loop on every path.
use Future::IO::Impl::IOAsync;

use lib 't/lib';
use PAGI::Test::Client;
use PAGITest::OwnLoopApp qw(own_loop_app);

my $client = PAGI::Test::Client->new(app => own_loop_app());

subtest 'an HTTP request' => sub {
    is($client->get('/')->content, 'late', 'completes');
};

subtest 'lifespan startup' => sub {
    my $lifespan = PAGI::Test::Client->new(app => own_loop_app(), lifespan => 1);
    ok(lives { $lifespan->start; $lifespan->stop }, 'completes');
};

subtest 'a WebSocket handshake and receive' => sub {
    my $ws = $client->websocket('/late-accept');
    is($ws->receive_text, 'late', 'completes');
    $ws->close;
};

subtest 'an SSE start and receive' => sub {
    my $sse = $client->sse('/late-start');
    is($sse->receive_event->{data}, 'late', 'completes');
    $sse->close;
};

subtest 'a request that never answers still times out, without the hint' => sub {
    local $PAGI::Test::_Drive::TIMEOUT = 0.3;
    my @warnings;
    my $error = do { local $SIG{__WARN__} = sub { push @warnings, @_ }; dies { $client->get('/stuck') } };
    like($error, qr/PAGI request did not complete within 0\.3 seconds/, 'times out');
    unlike($error, qr/bind Future::IO/, 'Future::IO runs on a real loop, so no hint');
    # Cancelling the timed-out IO::Async::Future trips Future::XS's
    # "lost a sequence" warning (RT #181389); nothing else may warn.
    is([grep { !/lost a sequence Future/ } @warnings], [], 'no other warning');
};

done_testing;
