use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Socket::INET;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../lib";
use PAGITest::CurrentServer qw(current_server_unavailable);

# full-demo counts requests in lifespan state. PAGI::Spec::Lifespan gives
# each request a shallow copy of state, so a count kept in a top-level key
# never leaves the request that bumped it; PAGI::Test::Client shares one hash
# and cannot show the difference. Run the example under the real server.

eval { require Future::IO::Impl::IOAsync; 1 }
    or plan skip_all => 'Future::IO::Impl::IOAsync required';
my $server_unavailable = current_server_unavailable();
plan skip_all => $server_unavailable if $server_unavailable;
plan skip_all => 'Server integration tests not supported on Windows' if $^O eq 'MSWin32';

my $loop = IO::Async::Loop->new;

my $stderr = '';
my $app = do {
    local *STDERR;
    open STDERR, '>', \$stderr or die $!;
    do "$FindBin::Bin/../../examples/full-demo/app.pl";
};
is($@, '', 'the example loads');

my $server = PAGI::Server->new(
    app => $app, host => '127.0.0.1', port => 0, quiet => 1,
    shutdown_timeout => 1, access_log => undef,
);
$loop->add($server);
{
    local *STDERR;
    open STDERR, '>>', \$stderr or die $!;
    $server->listen->get;
}

sub first_chunk_line {
    my ($path) = @_;
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1', PeerPort => $server->port, Proto => 'tcp', Timeout => 5,
    ) or die "connect: $!";
    print $sock "GET $path HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    $sock->blocking(0);
    my $wire = '';
    my $deadline = time + 10;
    while (time < $deadline) {
        my $n = sysread($sock, my $buf, 4096);
        if (defined $n && $n > 0) { $wire .= $buf }
        elsif (defined $n) { last }
        $loop->loop_once(0.05);
    }
    close $sock;
    return $wire =~ /(Stream started \(request #\d+\))/ ? $1 : $wire;
}

{
    local *STDERR;
    open STDERR, '>>', \$stderr or die $!;
    is(first_chunk_line('/stream'), 'Stream started (request #0)', 'the first request is #0');
    is(first_chunk_line('/stream'), 'Stream started (request #1)', 'the second sees the shared count');
    $server->shutdown->get;
}
like($stderr, qr/handled 2 requests/, 'and shutdown reports both');

done_testing;
