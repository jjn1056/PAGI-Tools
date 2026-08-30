use strict;
use warnings;

use Test2::V0;
use IO::Async::Loop;
use PAGI::Server;
use PAGI::Test::Client;

use PAGI::Pages;

# A bare Pages application is intentionally HTTP-only. PAGI::Server's default
# automatic lifespan mode interprets its lifespan exception as a conforming
# decline and continues startup. Operator-selected lifespan_mode => 'on' is
# strict and rejects the same root because Pages does not claim lifecycle
# ownership; applications that require lifecycle hooks use PAGI::Compose.
sub lifespan_probe {
    my ($mode) = @_;
    my $loop = IO::Async::Loop->new;
    my $server = PAGI::Server->new(
        app => PAGI::Pages->welcome,
        host => '127.0.0.1', port => 0, quiet => 1,
        lifespan_mode => $mode,
        lifespan_startup_timeout => 1,
    );
    $loop->add($server);
    my $result = $server->_run_lifespan_startup->get;
    $loop->remove($server);
    return $result;
}

my $automatic = lifespan_probe('auto');
is($automatic->{success}, 1,
    'bare Pages root starts when the server uses automatic lifespan mode');
is($automatic->{lifespan_supported}, 0,
    'automatic mode records the Pages exception as a lifespan decline');

my $strict = lifespan_probe('on');
is($strict->{success}, 0,
    'bare Pages root is rejected when the operator requires lifespan');
like($strict->{message}, qr/lifespan_mode.*on.*application raised.*Pages.*HTTP/is,
    'strict mode preserves the HTTP-only decline as its startup diagnostic');

my $client = PAGI::Test::Client->new(app => PAGI::Pages->welcome);
my $html = $client->get('/', headers => { Accept => 'text/html' });
is($html->status, 200, 'the bare application still serves HTTP after no factory I/O');
is($html->content_type, 'text/html; charset=utf-8',
    'the root application negotiates HTML per HTTP invocation');
like($html->text, qr/<title>200 Welcome to PAGI<\/title>/,
    'the root invocation renders the stock Pages document');

done_testing;
