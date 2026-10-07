use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Test::Client;
use PAGI::Compose qw(compose);
use PAGI::Routing qw(websocket sse);

# The test client stands in for the server: an application that fails after
# accepting a WebSocket or starting an SSE stream fails the test, as an HTTP
# application's failure does, instead of passing silently.

my $app = compose(routes => [
    websocket('/ws/cleanup' => async sub {
        my ($ws) = @_;
        $ws->on_close(sub { die "ws cleanup broke\n" });
        await $ws->accept;
        await $ws->each_text(async sub { });
    }),
    websocket('/ws/handler' => async sub {
        my ($ws) = @_;
        await $ws->accept;
        die "ws handler broke\n";
    }),
    websocket('/ws/self-close' => async sub {
        my ($ws) = @_;
        $ws->on_close(sub { die "ws self-close cleanup broke\n" });
        await $ws->accept;
        await $ws->close;
    }),
    websocket('/ws/fine' => async sub {
        my ($ws) = @_;
        $ws->on_close(sub { return });
        await $ws->accept;
        await $ws->each_text(async sub { });
    }),
    sse('/sse/cleanup' => async sub {
        my ($sse) = @_;
        $sse->on_close(sub { die "sse cleanup broke\n" });
        await $sse->start;
        await $sse->run;
    }),
])->to_app;
my $client = PAGI::Test::Client->new(app => $app);

like(dies { $client->websocket('/ws/cleanup', sub { $_[0]->send_text('hi') }) },
    qr/ws cleanup broke/, 'WebSocket callback form: a failing on_close fails the test');
like(dies { $client->websocket('/ws/cleanup')->close },
    qr/ws cleanup broke/, 'WebSocket object form: closing reports it');
like(dies { $client->websocket('/ws/handler', sub { }) },
    qr/ws handler broke/, 'a handler that dies after accept fails the test');
like(dies { $client->sse('/sse/cleanup', sub { }) },
    qr/sse cleanup broke/, 'SSE callback form: a failing on_close fails the test');
like(dies { $client->sse('/sse/cleanup')->close },
    qr/sse cleanup broke/, 'SSE object form: closing reports it');
like(dies { $client->websocket('/ws/self-close') },
    qr/ws self-close cleanup broke/, 'object form: an application that already failed fails the call');
ok(lives { $client->websocket('/ws/fine', sub { $_[0]->send_text('hi') }) },
    'an application that ends well still passes');

done_testing;
