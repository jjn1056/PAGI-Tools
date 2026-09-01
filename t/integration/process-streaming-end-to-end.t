use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Socket::INET;
use Scalar::Util ();
use FindBin;
use lib "$FindBin::Bin/../../lib";

# Cross-repo end-to-end test for examples/process-streaming: a child process's
# stdout must reach the client byte-exactly through PAGI::Response::Stream's
# writer, and a client that disconnects mid-stream must not disturb the server.
#
# The example deliberately names no event loop -- it spawns with core Perl,
# reads with Future::IO->read, and reaps with Future::IO->waitpid -- so this
# test also proves the loop-agnostic source adapter works against the real
# server rather than only against a mock.
#
# Skips unless PAGI::Server is on @INC, so PAGI-Tools' standalone suite stays
# independent. Run it with:
#   prove -I <PAGI-Server>/lib -lr t/integration/process-streaming-end-to-end.t

plan skip_all => 'example forks via open "-|", unsupported on Windows'
    if $^O eq 'MSWin32';
eval { require Future::IO::Impl::IOAsync; 1 }
    or plan skip_all => 'Future::IO::Impl::IOAsync required';
eval { require PAGI::Server; 1 }
    or plan skip_all => 'PAGI::Server not on @INC; run with -I <PAGI-Server>/lib';

my $app_file = "$FindBin::Bin/../../examples/process-streaming/app.pl";
plan skip_all => "example not found: $app_file" unless -f $app_file;

my $source = do {
    open my $fh, '<', $app_file or die "cannot open $app_file: $!\n";
    local $/;
    <$fh>;
};
unlike($source, qr/compose\s*\(\s*app\s*=>/s,
    'process-streaming does not use retired Compose app mode');
like($source, qr/compose\s*\(\s*routes\s*=>/s,
    'process-streaming declares its direct root with routes');

my $app = do $app_file;
die "cannot load $app_file: " . ($@ || $!) unless defined $app;
# The example ends in compose(...), which yields an application-provider
# object; PAGI::Server accepts a coderef or an instantiated to_app object.
die "unexpected application value from $app_file"
    unless ref($app) eq 'CODE'
        || (Scalar::Util::blessed($app) && $app->can('to_app'));

my $loop   = IO::Async::Loop->new;
my $server = PAGI::Server->new(
    app        => $app,
    host       => '127.0.0.1',
    port       => 0,
    quiet      => 1,
    access_log => undef,
);
$loop->add($server);
$server->listen->get;
my $port = $server->port;

sub connect_client {
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1', PeerPort => $port,
        Proto    => 'tcp',       Timeout  => 5,
    ) or die "cannot connect: $!";
    $sock->blocking(0);
    return $sock;
}

# Drive the loop until $cond is true or $timeout expires.
sub pump_until {
    my ($cond, $timeout) = @_;
    $timeout //= 30;
    my $deadline = time + $timeout;
    while (time < $deadline) {
        return 1 if $cond->();
        $loop->loop_once(0.05);
    }
    return $cond->() ? 1 : 0;
}

# Issue one request and read until the server closes or $done_when says stop.
sub fetch {
    my ($path, %opts) = @_;
    my $sock = connect_client();
    syswrite($sock, "GET $path HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

    my $buffer = '';
    my $closed = 0;
    pump_until(sub {
        my $chunk;
        my $bytes = sysread($sock, $chunk, 65536);
        if (defined $bytes) {
            return $closed = 1 if $bytes == 0;   # server closed: response done
            $buffer .= $chunk;
        }
        return $opts{done_when} ? $opts{done_when}->($buffer) : 0;
    }, $opts{timeout} // 30);

    return ($sock, $buffer, $closed);
}

sub split_response {
    my ($raw) = @_;
    my ($head, $body) = split /\r\n\r\n/, $raw, 2;
    return ($head // '', $body // '');
}

subtest 'index lists the available reports' => sub {
    my (undef, $raw) = fetch('/');
    my ($head, $body) = split_response($raw);
    like($head, qr{^HTTP/1\.1 200}, 'index responds 200');
    like($body, qr{/reports/ticker}, 'ticker report is listed');
    like($body, qr{/reports/bulk},   'bulk report is listed');
};

subtest 'a bulk report streams the child output byte-exactly' => sub {
    my (undef, $raw, $closed) = fetch('/reports/bulk', timeout => 60);
    my ($head, $body) = split_response($raw);
    like($head, qr{^HTTP/1\.1 200}, 'bulk responds 200');
    ok($closed, 'server closed the connection after the terminal event');

    # The example's bulk report emits 80 chunks of 65536 bytes.
    my $expected = 80 * 65536;
    my $decoded  = $head =~ /chunked/i ? dechunk($body) : $body;
    is(length($decoded), $expected, "streamed exactly $expected bytes");
    like($decoded, qr/\Ax+\z/, 'payload survived the pipe unmodified');
};

subtest 'an unknown report is a 404 from the handler-returned Pages app' => sub {
    my (undef, $raw) = fetch('/reports/does-not-exist');
    my ($head) = split_response($raw);
    like($head, qr{^HTTP/1\.1 404}, 'unknown report responds 404');
};

subtest 'a client that disconnects mid-stream does not disturb the server' => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, join '', @_ };

    my $sock = connect_client();
    syswrite($sock, "GET /reports/ticker HTTP/1.1\r\nHost: localhost\r\n\r\n");

    my $received = '';
    ok(pump_until(sub {
        my $chunk;
        my $bytes = sysread($sock, $chunk, 65536);
        $received .= $chunk if defined $bytes && $bytes > 0;
        return $received =~ /tick 3\b/;
    }, 20), 'ticker streamed progressively while connected');

    close($sock);                       # client vanishes mid-stream
    $loop->loop_once(0.05) for 1 .. 20;  # let the server observe it

    # The server must still be healthy: the disconnect is an ordinary end,
    # not an error, and the example's on_close cleanup must not break it.
    my (undef, $raw) = fetch('/');
    my ($head) = split_response($raw);
    like($head, qr{^HTTP/1\.1 200},
        'server serves a later request normally after the abandoned stream');

    # A stream that stops because its client vanished is an abnormal end, not
    # an application fault: Stream omits the terminal event by design and
    # PAGI::Spec::Www exempts the case, so Compose's guard must stay quiet.
    is(scalar(grep { /application error/i } @warnings), 0,
        'no application error is logged for a client that disconnected mid-stream')
        or diag("unexpected warnings:\n" . join("\n", @warnings));
};

sub dechunk {
    my ($body) = @_;
    my $out = '';
    while ($body =~ /\G([0-9a-fA-F]+)\r\n/gc) {
        my $len = hex $1;
        last if $len == 0;
        $out .= substr($body, pos($body), $len);
        pos($body) = pos($body) + $len + 2;   # skip the chunk's trailing CRLF
    }
    return $out;
}

$server->shutdown->get;
eval { $loop->remove($server) };

done_testing;
