use strict;
use warnings;
use Test2::V0;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../lib";

use Digest::SHA qw(sha256_hex);
use File::Temp qw(tempdir);
use Future::AsyncAwait;
use IO::Async::Loop;
use IO::Socket::INET;
use PAGITest::CurrentServer qw(current_server_unavailable);

# CSRF reads a multipart form only as far as its token part, and hands the
# route the whole body: on a real server, which delivers a large body in many
# events, an upload after the token still streams to the route as it
# arrives. A file before the token, or a wrong token, is refused, and the
# route never runs.

eval { require Future::IO::Impl::IOAsync; 1 }
    or plan skip_all => 'Future::IO::Impl::IOAsync required';
my $server_unavailable = current_server_unavailable();
plan skip_all => $server_unavailable if $server_unavailable;
plan skip_all => 'Server integration tests not supported on Windows' if $^O eq 'MSWin32';

require PAGI::Tools;
PAGI::Tools->import(qw(compose middleware response route));

my $dir = tempdir(CLEANUP => 1);
my $stored = 0;
my $first_chunk_seen = 0;    # set by the route when the upload's first chunk arrives
my $app = compose(
    routes => [route('/upload' => async sub {
        my ($request) = @_;
        my $stream = $request->multipart_stream;
        my ($bytes, $chunks, $sha) = (0, 0, Digest::SHA->new(256));
        while (defined(my $part = await $stream->next)) {
            next unless $part->is_file;
            open my $fh, '>', "$dir/upload-" . ++$stored or die $!;
            while (defined(my $chunk = await $part->next_chunk)) {
                $first_chunk_seen = 1;
                print {$fh} $chunk;
                $sha->add($chunk);
                $bytes += length $chunk;
                $chunks++;
            }
            close $fh;
        }
        return response('Text', join(' ', "bytes=$bytes", 'sha256=' . $sha->hexdigest, "chunks=$chunks"), status => 201);
    }, methods => ['POST'])],
    middleware => [middleware('CSRF', form_field => 'csrf_token')],
);

my $loop = IO::Async::Loop->new;
my $server = PAGI::Server->new(
    app => $app, host => '127.0.0.1', port => 0, quiet => 1,
    shutdown_timeout => 1, access_log => undef,
);
$loop->add($server);
$server->listen->get;

my $token = 'cd' x 32;
my $boundary = 'XyZ';
sub text_part { "--$boundary\r\nContent-Disposition: form-data; name=\"$_[0]\"\r\n\r\n$_[1]\r\n" }
sub file_part { "--$boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"build.tar\"\r\n"
            . "Content-Type: application/octet-stream\r\n\r\n$_[0]\r\n" }

# POSTs $body in 64KB writes and returns the response's status and body.
# With $hold, it stops after $hold bytes of the body until the route has seen
# the upload's first chunk -- which a middleware that read the whole body
# before the route would never allow -- and dies if that does not happen.
sub post_in_chunks {
    my ($body, $hold) = @_;
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1', PeerPort => $server->port, Proto => 'tcp', Timeout => 5,
    ) or die "connect: $!";
    $sock->blocking(0);
    my $out = "POST /upload HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        . "Cookie: csrf_token=$token\r\nContent-Type: multipart/form-data; boundary=$boundary\r\n"
        . 'Content-Length: ' . length($body) . "\r\n\r\n" . $body;
    my $held_at = defined $hold ? length($out) - length($body) + $hold : undef;
    my ($wire, $deadline, $sent) = ('', time + 20, 0);
    while (time < $deadline) {
        my $may_send = defined($held_at) && !$first_chunk_seen ? $held_at - $sent : length $out;
        if (length($out) && $may_send > 0) {
            my $n = syswrite($sock, $out, $may_send < 65536 ? $may_send : 65536);
            $sent += $n if defined $n && $n > 0;
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

my $bytes = join '', map { chr($_ % 256) } 0 .. 2_000_000;

my $head = text_part(csrf_token => $token);
my ($status, $content) = post_in_chunks($head . file_part($bytes) . "--$boundary--\r\n", length($head) + 300_000);
ok $first_chunk_seen, 'the route had the upload while most of it was still unsent';
is $status, 201, 'the token first: a 2MB upload is accepted';
my ($got_bytes, $got_sha, $chunks) = ($content // '') =~ /\Abytes=(\d+) sha256=(\w+) chunks=(\d+)\z/;
is [$got_bytes, $got_sha], [length $bytes, sha256_hex($bytes)], 'the route streamed all of it, intact';

my $before = $stored;
($status, $content) = post_in_chunks(file_part($bytes) . text_part(csrf_token => $token) . "--$boundary--\r\n");
is [$status, $content], [403, 'CSRF token validation failed'], 'a file before the token is refused';
($status) = post_in_chunks(text_part(csrf_token => 'forged') . file_part($bytes) . "--$boundary--\r\n");
is $status, 403, 'a wrong token is refused';
is $stored, $before, 'and the route never ran for either';

$server->shutdown->get;
done_testing;
