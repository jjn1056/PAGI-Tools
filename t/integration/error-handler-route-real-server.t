use strict;
use warnings;
use Test2::V0;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../lib";
use Future::AsyncAwait;
use IO::Async::Loop;
use IO::Socket::INET;
use PAGITest::CurrentServer qw(current_server_unavailable);

# A catch entry re-reads the form the route already read. At the route it has
# the route's own Request, so the form is there. PAGI::Test::Client answers a
# second Request's read with a disconnect at once; a real server waits for a
# body that never comes, so only a real server shows the difference.

eval { require Future::IO::Impl::IOAsync; 1 }
    or plan skip_all => 'Future::IO::Impl::IOAsync required';
my $server_unavailable = current_server_unavailable();
plan skip_all => $server_unavailable if $server_unavailable;
plan skip_all => 'Server integration tests not supported on Windows' if $^O eq 'MSWin32';

require PAGI::Tools;
PAGI::Tools->import(qw(compose middleware response route));

{ package Local::Conflict; sub new { bless {}, shift } }

my $app = compose(
    routes => [route('/notes' => async sub {
        my ($request) = @_;
        await $request->form_params;
        die Local::Conflict->new;
    }, methods => ['POST'])],
    middleware => [middleware('ErrorHandler', catch => { 'Local::Conflict' => async sub {
        my ($request) = @_;
        my $form = await $request->form_params;
        return response('Text', 'taken: ' . $form->get('title'), status => 409);
    } })],
);

my $loop = IO::Async::Loop->new;
my $server = PAGI::Server->new(
    app => $app, host => '127.0.0.1', port => 0, quiet => 1,
    shutdown_timeout => 1, access_log => undef,
);
$loop->add($server);
$server->listen->get;

my $body = 'title=Rotate+the+key';
my $sock = IO::Socket::INET->new(
    PeerAddr => '127.0.0.1', PeerPort => $server->port, Proto => 'tcp', Timeout => 5,
) or die "connect: $!";
print $sock "POST /notes HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
    . "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: " . length($body) . "\r\n\r\n$body";
$sock->blocking(0);
my ($wire, $deadline) = ('', time + 2);
while (time < $deadline) {
    my $n = sysread($sock, my $buf, 4096);
    if (defined $n && $n > 0) { $wire .= $buf }
    elsif (defined $n) { last }
    $loop->loop_once(0.05);
}
close $sock;

like $wire, qr{\AHTTP/1\.1 409}, 'answered within 2s, no hang';
like $wire, qr/taken: Rotate the key\z/, 'with the form the route had read';

$server->shutdown->get;
done_testing;
