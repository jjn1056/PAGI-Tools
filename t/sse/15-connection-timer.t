use strict;
use warnings;
use Test2::V0;
use Future;
use PAGI::SSE;
use PAGI::Test::ConnectionState;

subtest 'every observes end after multiple timer wins without consuming receive' => sub {
    eval { require Future::IO::Impl::IOAsync; 1 } or skip_all('Future::IO::Impl::IOAsync unavailable');
    my @timers;
    no warnings qw(redefine once);
    local *Future::IO::sleep = sub { my $f = Future->new; push @timers, $f; return $f };
    my $conn = PAGI::Test::ConnectionState->new;
    my $sse = PAGI::SSE->new({type => 'sse', 'pagi.connection' => $conn}, sub {die 'competing receive'}, sub {Future->done});
    my ($ticks, $cleaned) = (0, 0);
    $sse->on_close(sub { ++$cleaned });
    my $every = $sse->every(1, sub { ++$ticks; Future->done });
    is($ticks, 1, 'first callback executes');
    $timers[0]->done;
    is($ticks, 2, 'second tick survives cancelled end observer');
    $timers[1]->done;
    is($ticks, 3, 'fresh end observer for every race');
    $conn->_mark_complete;
    ok($every->is_ready && !$every->is_failed, 'clean completion exits periodic loop');
    is($cleaned, 1, 'one cleanup');
    ok($timers[2]->is_cancelled, 'owned losing timer cancelled');
};

subtest 'SSE send errors do not publish connection terminal facts' => sub {
    my $conn = PAGI::Test::ConnectionState->new;
    my $sse = PAGI::SSE->new({type => 'sse', 'pagi.connection' => $conn}, sub {die 'receive'}, sub {
        $_[0]{type} eq 'sse.start' ? Future->done : Future->fail("resource error\n");
    });
    my ($errors, $cleanup) = (0, 0);
    $sse->on_error(sub {++$errors});
    $sse->on_close(sub {++$cleanup});
    is($sse->try_send('data')->get, 0, 'try_send preserves false result');
    is($errors, 1, 'error callback reports resource error');
    ok($sse->is_connected, 'send failure leaves terminal decision to server');
    is($cleanup, 0, 'send failure is not cleanup');
    $conn->_mark_disconnected('server_error', 'send failed');
    is($cleanup, 1, 'server outcome runs cleanup');
};

subtest 'SSE local close prevents data and keepalive while terminal is pending' => sub {
    my $conn = PAGI::Test::ConnectionState->new;
    my @sent;
    my $sse = PAGI::SSE->new({type => 'sse', 'pagi.connection' => $conn}, sub {die 'receive'}, sub {push @sent, $_[0]{type}; Future->done});
    $sse->start->get;
    my $close = $sse->close;
    for my $method (qw(send send_json send_comment)) {
        like(dies {$sse->$method('data')->get}, qr/Cannot send/, "$method rejects local closing");
    }
    like(dies {$sse->send_event(data => 'event')->get}, qr/Cannot send/, 'send_event rejects local closing');
    is($sse->try_send('data')->get, 0, 'try_send rejects local closing');
    is($sse->try_send_json('data')->get, 0, 'try_send_json rejects local closing');
    is($sse->try_send_comment('data')->get, 0, 'try_send_comment rejects local closing');
    is($sse->try_send_event(data => 'event')->get, 0, 'try_send_event rejects local closing');
    $sse->keepalive(10)->get;
    is(\@sent, [qw(sse.start sse.close)], 'no data or start or keepalive follows close');
    $conn->_mark_complete;
    ok($close->is_ready, 'first close finishes');
};
done_testing;
