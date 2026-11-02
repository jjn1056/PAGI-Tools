use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Future::AsyncAwait;
use PAGI::Test::Client;
use PAGI::Tools qw(compose middleware websocket);

# First-frame authentication as a middleware: the client sends its token as
# the first message, the middleware checks it and closes with 4401 if it is
# wrong. It builds no PAGI::WebSocket of its own; it wraps the raw receive
# and send, so the route's handler uses its own helper as usual.

my $file = "$Bin/../examples/websocket-first-frame-auth/app.pl";
my $source = do { open my $fh, '<', $file or die "$file: $!"; local $/; <$fh> };

unlike($source, qr/PAGI::WebSocket->new/, 'the middleware builds no helper');
like($source, qr/websocket\('\/'\s*=>\s*\\&echo\)/, 'a WebSocket route takes the one-$ws handler');

my $app = do $file;
is($@, '', 'the example loads');
isa_ok($app, 'PAGI::Compose');

my $client = PAGI::Test::Client->new(app => $app);

$client->websocket('/', sub {
    my ($ws) = @_;
    $ws->send_text('let-me-in');
    $ws->send_text('hi');
    is($ws->receive_text, 'echo: hi', 'a good token: the handler accepts, then echoes');
});

{
    my $ws = $client->websocket('/');
    $ws->send_text('wrong');
    is($ws->receive_text, undef, 'a bad token: the client gets no message');
    is([$ws->close_code, $ws->close_reason], [4401, 'unauthorized'], 'only the 4401 close');
    ok(lives { $ws->close }, 'and the handler ends cleanly') or note $@;
}

ok(lives { $client->websocket('/')->close }, 'a client gone before its token: the handler ends cleanly')
    or note $@;

# The middleware in front of a handler that greets the client as soon as it
# has accepted, and records every frame it receives.
my (@seen, $ended);
my $probe = PAGI::Test::Client->new(app => compose(
    routes => [websocket('/' => async sub {
        my ($ws) = @_;
        await $ws->accept;
        await $ws->send_text('welcome');
        await $ws->each_text(async sub {
            my ($text) = @_;
            push @seen, $text;
            await $ws->send_text("echo: $text");
        });
        $ended = 1;
    })],
    middleware => [middleware(\&main::first_frame_auth)],
));

$probe->websocket('/', sub {
    my ($ws) = @_;
    $ws->send_text('let-me-in');
    is($ws->receive_text, 'welcome', 'a good token: the greeting follows the check');
    $ws->send_text('hi');
    is($ws->receive_text, 'echo: hi', 'then the echo');
});
is(\@seen, ['hi'], 'the handler never sees the token');
ok($ended, 'and ends when the client closes');

# A bad token, then a frame the client sent before the 4401 close reached
# it. In manual close mode the test peer answers the close only when told,
# as a real client's answer arrives after the handler's next step: the
# handler's greeting goes out while the connection is still open.
(@seen, $ended) = ();
{
    my $ws = $probe->websocket('/', close_mode => 'manual');
    $ws->send_text('wrong');
    $ws->send_text('sent before the close arrived');
    is($ws->close_code, 4401, 'a bad token: the middleware closes with 4401');
    ok(lives { $ws->close(4401, 'unauthorized'); $ws->complete_close },
        'the greeting after the close does not kill the handler') or note $@;
    is($ws->receive_text, undef, 'the client got neither greeting nor echo');
}
is(\@seen, [], 'the frame sent after a bad token never reaches the handler');
ok($ended, 'which ends cleanly');

done_testing;
