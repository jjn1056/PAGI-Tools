use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Socket::INET;
use Future::AsyncAwait;
use Time::HiRes ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../lib";
use PAGITest::CurrentServer qw(current_server_unavailable);

# A routed helper's on_close cleanup is part of its application call, so a
# shutting-down PAGI::Server waits for it before lifespan.shutdown.

eval { require Future::IO::Impl::IOAsync; 1 }
    or plan skip_all => 'Future::IO::Impl::IOAsync required';
my $server_unavailable = current_server_unavailable();
plan skip_all => $server_unavailable if $server_unavailable;
plan skip_all => 'Server integration tests not supported on Windows' if $^O eq 'MSWin32';

use Future::IO;
use PAGI::Compose qw(compose);
use PAGI::Routing qw(websocket sse);

my $loop = IO::Async::Loop->new;
my @order;

my $app = compose(
    routes => [
        websocket('/ws' => async sub {
            my ($ws) = @_;
            $ws->on_close(async sub {
                push @order, 'ws ended: ' . ($ws->disconnect_reason // 'none');
                # Longer than the SSE cleanup, whose own close already holds
                # the shutdown for its 0.3s: this one must be waited for.
                await Future::IO->sleep(0.8);
                push @order, 'ws cleanup finished';
            });
            await $ws->accept;
            push @order, 'ws accepted';
            await $ws->each_text(async sub { });
        }),
        sse('/events' => async sub {
            my ($sse) = @_;
            $sse->on_close(async sub {
                push @order, 'sse ended: ' . ($sse->disconnect_reason // 'none');
                await Future::IO->sleep(0.3);
                push @order, 'sse cleanup finished';
            });
            await $sse->start;
            push @order, 'sse started';
            await $sse->run;
        }),
    ],
    lifespan => { shutdown => async sub { push @order, 'lifespan.shutdown' } },
)->to_app;

sub pump_until {
    my ($cond, $timeout) = @_;
    my $deadline = Time::HiRes::time() + $timeout;
    while (Time::HiRes::time() < $deadline) {
        return 1 if $cond->();
        $loop->loop_once(0.02);
    }
    return $cond->() ? 1 : 0;
}

sub connect_with {
    my ($port, $request) = @_;
    my $sock = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp')
        or die "connect: $!";
    $sock->blocking(0);
    syswrite($sock, $request);
    return $sock;
}

my $server = PAGI::Server->new(
    app => $app, host => '127.0.0.1', port => 0, access_log => undef,
    quiet => 1, shutdown_timeout => 5,
);
$loop->add($server);
$server->listen->get;

my @socks = (
    connect_with($server->port, "GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
        . "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        . "Sec-WebSocket-Version: 13\r\n\r\n"),
    connect_with($server->port, "GET /events HTTP/1.1\r\nHost: localhost\r\nAccept: text/event-stream\r\n\r\n"),
);
ok(pump_until(sub { (grep { /accepted|started/ } @order) == 2 }, 5), 'both connected');

my $done = $server->shutdown;
pump_until(sub { sysread($_, my $buf, 65536) for @socks; $done->is_ready }, 10);
eval { $loop->remove($server) };

my %at = map { $order[$_] => $_ } 0 .. $#order;
ok($done->is_ready, 'shutdown completed');
ok(defined $at{'ws ended: server_shutdown'}, 'the WebSocket ended by server shutdown');
ok(defined $at{'sse ended: server_shutdown'}, 'the SSE stream ended by server shutdown');
ok(defined $at{'ws cleanup finished'} && defined $at{'sse cleanup finished'}, 'both cleanups finished');
ok(defined $at{'lifespan.shutdown'}
    && $at{'lifespan.shutdown'} > ($at{'ws cleanup finished'} // 1e9)
    && $at{'lifespan.shutdown'} > ($at{'sse cleanup finished'} // 1e9),
    'before lifespan.shutdown') or note(join "\n", @order);

done_testing;
