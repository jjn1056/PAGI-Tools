use strict;
use warnings;
use Test2::V0;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../lib";

BEGIN { plan skip_all => 'examples/signed-requests requires Perl 5.40' if $] < 5.040 }

# The app keeps its artifacts in a temporary directory: make it one this
# test can look in.
use File::Temp qw(tempdir);
my $tmp;
BEGIN { $tmp = tempdir(CLEANUP => 1); $ENV{TMPDIR} = $tmp }

use Digest::SHA qw(hmac_sha256_hex sha256_hex);
use File::Find qw(find);
use IO::Async::Loop;
use IO::Socket::INET;
use PAGITest::CurrentServer qw(current_server_unavailable);

# signed-requests checks the signature as the route reads the body, and
# fails the read of the last chunk. PAGI::Test::Client delivers a body as
# one event, so the first chunk is the last and nothing is written before
# the verdict; a real server delivers a large body in many, and a forged
# artifact must still leave nothing on disk.

eval { require Future::IO::Impl::IOAsync; 1 }
    or plan skip_all => 'Future::IO::Impl::IOAsync required';
my $server_unavailable = current_server_unavailable();
plan skip_all => $server_unavailable if $server_unavailable;
plan skip_all => 'Server integration tests not supported on Windows' if $^O eq 'MSWin32';

my $loop = IO::Async::Loop->new;
local $ENV{SIGNING_SECRET} = 'test-secret';
my $app = do "$FindBin::Bin/../../examples/signed-requests/app.pl" or die $@ || $!;
my $server = PAGI::Server->new(
    app => $app, host => '127.0.0.1', port => 0, quiet => 1,
    shutdown_timeout => 1, access_log => undef,
);
$loop->add($server);
$server->listen->get;

# POSTs $body in 64KB writes and returns the response's status line and body.
sub post_in_chunks {
    my ($path, $body, $signature) = @_;
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1', PeerPort => $server->port, Proto => 'tcp', Timeout => 5,
    ) or die "connect: $!";
    $sock->blocking(0);
    my $out = "POST $path HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        . "X-Signature: $signature\r\nContent-Length: " . length($body) . "\r\n\r\n" . $body;
    my ($wire, $deadline) = ('', time + 20);
    while (time < $deadline) {
        if (length $out) {
            my $n = syswrite($sock, $out, 65536);
            substr($out, 0, $n, '') if defined $n && $n > 0;
        }
        my $n = sysread($sock, my $buf, 65536);
        if (defined $n && $n > 0) { $wire .= $buf }
        elsif (defined $n) { last }
        $loop->loop_once(0.01);
    }
    close $sock;
    my ($status) = $wire =~ m{\AHTTP/1\.1 (\d{3})};
    my ($content) = $wire =~ /\r\n\r\n(.*)\z/s;
    return ($status, $content);
}

sub stored {
    my @files;
    find(sub { push @files, $_ if -f }, $tmp);
    return [sort @files];
}

my $bytes = join '', map { chr($_ % 256) } 0 .. 2_000_000;
my $good = 'sha256=' . hmac_sha256_hex(sha256_hex($bytes), 'test-secret');

my ($status, $content) = post_in_chunks('/signed/artifacts/evil.tar', $bytes, 'sha256=forged');
is [$status, $content], [401, '{"error":"bad signature"}'], 'a forged 2MB artifact, sent in chunks, is refused';
is stored(), [], 'and nothing of it is kept';

($status, $content) = post_in_chunks('/signed/artifacts/build.tar', $bytes, $good);
is $status, 201, 'a signed one is stored';
is stored(), ['build.tar'], 'under its name';

$server->shutdown->get;
done_testing;
