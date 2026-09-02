use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use FindBin;
use lib "$FindBin::Bin/../../lib";

# Cross-repo smoke test: a PAGI-Tools SSE route must drive the real PAGI::Server
# to return one concrete Response through PAGI::SSE->decline, instead of
# starting an event stream. Each repo is unit-tested in isolation; this proves
# the whole chain (Response emits HTTP events -> SSE maps decline events ->
# server returns a real HTTP response -> client reads a 404).
#
# Skips unless PAGI::Server is on @INC, so PAGI-Tools' standalone suite stays
# independent. Run it with:
#   prove -I <PAGI-Server>/lib -lr t/integration/sse-decline-end-to-end.t
#
# Requires PAGI::Server >= 0.002005: that release added the sse.http.response.*
# decline protocol this test exercises (PAGI-Server Changes, "0.002005 -
# 2026-06-30" / Features). Older servers don't recognize
# 'sse.http.response.start' and crash the connection with a 500 instead of
# returning 404 (CPAN Testers FAIL against 0.001012, PAGI-Tools 0.002001).
use constant MIN_SSE_DECLINE_SERVER_VERSION => '0.002005';

eval { require Future::IO::Impl::IOAsync; 1 }
    or plan skip_all => 'Future::IO::Impl::IOAsync required for SSE tests';
eval { require PAGI::Server; 1 }
    or plan skip_all => 'PAGI::Server not on @INC; run with -I <PAGI-Server>/lib';
plan skip_all => "PAGI::Server $PAGI::Server::VERSION does not support the sse.http.response.* "
                . "decline protocol; need >= " . MIN_SSE_DECLINE_SERVER_VERSION
    unless eval { PAGI::Server->VERSION(MIN_SSE_DECLINE_SERVER_VERSION); 1 };

plan skip_all => "Server integration tests not supported on Windows" if $^O eq 'MSWin32';

use PAGI::Endpoint::SSE;
use PAGI::Response::Text;
use PAGI::Routing qw(router sse);
use IO::Socket::INET;

{
    package Local::DecliningSSEEndpoint;
    use parent 'PAGI::Endpoint::SSE';

    sub on_connect {
        my ($self, $sse) = @_;
        ++$self->{connections};
        $self->{protocol_class} = ref($sse);
        return $sse->decline(
            PAGI::Response::Text->new('Not Found', status => 404),
        );
    }
}

my $loop = IO::Async::Loop->new;

sub create_server {
    my ($app) = @_;
    my $server = PAGI::Server->new(
        app => $app, host => '127.0.0.1', port => 0, quiet => 1, shutdown_timeout => 1,
    );
    $loop->add($server);
    $server->listen->get;
    return $server;
}

sub sse_get {
    my ($port, $path) = @_;
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp', Timeout => 5,
    ) or return ('', 0);
    print $sock "GET $path HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nAccept: text/event-stream\r\n\r\n";
    $sock->blocking(0);
    my $wire = '';
    my $eof  = 0;
    my $deadline = time + 5;
    while (time < $deadline) {
        my $buf;
        my $n = sysread($sock, $buf, 4096);
        if (defined $n && $n > 0) { $wire .= $buf }
        elsif (defined $n && $n == 0) { $eof = 1; last }
        $loop->loop_once(0.05);
    }
    close $sock;
    $loop->loop_once(0.05) for 1 .. 20;
    return ($wire, $eof);
}

subtest 'concrete SSE decline Response returns a real HTTP 404 over the real server' => sub {
    my $endpoint = Local::DecliningSSEEndpoint->new;
    my $routing = router(routes => [
        sse('/events' => $endpoint),
    ]);

    my $server = create_server($routing->to_app);
    my ($wire, $eof) = sse_get($server->port, '/events');

    like($wire, qr{HTTP/1\.1 404},        'concrete decline Response -> 404, not a crash');
    like($wire, qr/Not Found/,             'decline body delivered');
    unlike($wire, qr{text/event-stream},   'NOT an event stream');
    ok($eof, 'connection closed');
    is([$endpoint->{connections}, $endpoint->{protocol_class}],
        [1, 'PAGI::SSE'],
        'declarative dispatch retains the configured endpoint and direct protocol object');

    $server->shutdown->get;
};

done_testing;
