use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Socket::INET;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../lib";
use PAGITest::CurrentServer qw(current_server_unavailable);

use PAGI::Auth qw(unauth_result requires);
use PAGI::Compose qw(compose);
use PAGI::Response qw(response);
use PAGI::Routing qw(middleware mount route);

# requires' redirect puts the requested path in next. Inside a mount the
# routed path has lost the mount prefix, so next must come from the path the
# client sent -- which only the server's scope shows for certain.

eval { require Future::IO::Impl::IOAsync; 1 }
    or plan skip_all => 'Future::IO::Impl::IOAsync required';
my $server_unavailable = current_server_unavailable();
plan skip_all => $server_unavailable if $server_unavailable;
plan skip_all => 'Server integration tests not supported on Windows' if $^O eq 'MSWin32';

my $loop = IO::Async::Loop->new;

my $app = compose(
    middleware => [middleware('Authentication', backend => sub { unauth_result() })],
    routes => [
        mount('/admin', routes => [
            route('/reports' => requires([], sub { response('JSON', {}) }, redirect => ['admin_login'])),
            route('/login' => sub { response('JSON', {}) }, name => 'admin_login'),
        ]),
    ],
);

my $server = PAGI::Server->new(
    app => $app, host => '127.0.0.1', port => 0, quiet => 1,
    shutdown_timeout => 1, access_log => undef,
);
$loop->add($server);
$server->listen->get;

sub response_head {
    my ($target) = @_;
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1', PeerPort => $server->port, Proto => 'tcp', Timeout => 5,
    ) or die "connect: $!";
    print $sock "GET $target HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
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
    return $wire;
}

my $wire = response_head('/admin/reports?x=1');
like($wire, qr{\AHTTP/1\.1 303 }, 'a guest is redirected');
like($wire, qr{^location: /admin/login\?next=%2Fadmin%2Freports%3Fx%3D1\r$}mi,
    'to the mounted login route, with the whole requested path in next');

$server->shutdown->get;

done_testing;
