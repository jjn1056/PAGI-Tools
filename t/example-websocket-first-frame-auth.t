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
    # Rule 1's guard: the greeting is sent once accept returns.
    is($ws->receive_text, undef, 'rule 1: no greeting or echo reaches a client with a bad token');
}
is(\@seen, [], 'the frame sent after a bad token never reaches the handler');
ok($ended, 'which ends cleanly');

# A helper owns the connection from the moment it issues its accept, so a
# handler may send and receive while its accept is still pending. The check
# gates those too.
sub guarded {
    my ($handler) = @_;
    return compose(
        routes => [websocket('/' => $handler)],
        middleware => [middleware(\&main::first_frame_auth)],
    );
}

{
    my $ws = PAGI::Test::Client->new(app => guarded(async sub {
        my ($ws) = @_;
        my $accepted = $ws->accept;
        await $ws->send_text('early');
        await $accepted;
    }))->websocket('/');
    $ws->close;
    is($ws->receive_text, undef, 'a send made while the accept is pending never reaches a client without a token');
}

@seen = ();
{
    my $ws = PAGI::Test::Client->new(app => guarded(async sub {
        my ($ws) = @_;
        my $accepted = $ws->accept;
        my $first = $ws->receive_text;
        await $accepted;
        push @seen, await $first;
    }))->websocket('/', close_mode => 'manual');
    $ws->send_text('wrong');
    $ws->send_text('late frame');
    $ws->close(4401, 'unauthorized');
    $ws->complete_close;
}
is(\@seen, [undef], 'a receive made while the accept is pending gets no frame sent after a bad token');

# A server may settle the accept's send on a later turn of the loop; here
# the test settles it by hand, after the client has sent its token.
@seen = ();
{
    my $release;
    my $inner = guarded(async sub {
        my ($ws) = @_;
        my $accepted = $ws->accept;
        my $first = $ws->receive_text;
        await $accepted;
        push @seen, await $first;
    })->to_app;
    my $settle_accept_later = sub {
        my ($scope, $receive, $send) = @_;
        return $inner->($scope, $receive, sub {
            my ($event) = @_;
            my $sent = $send->($event);
            return $sent unless $event->{type} eq 'websocket.accept';
            $release = Future->new;
            return $sent->then(sub { $release });
        });
    };
    my $ws = PAGI::Test::Client->new(app => $settle_accept_later)->websocket('/');
    $ws->send_text('let-me-in');
    $release->done;
    $ws->send_text('second');
    is(\@seen, ['second'], 'with a late accept the token still goes to the check, not the handler');
    is($ws->close_code, 1000, 'and the good client is not refused: the handler returned, so its route closed with 1000');
    $ws->close;
}

# After the 4401 close the handler's helper learns the connection's real
# end from the server: an is_connected loop stops when the client answers.
{
    my ($iterations, @state) = (0);
    my $ws = PAGI::Test::Client->new(app => guarded(async sub {
        my ($ws) = @_;
        await $ws->accept;
        while ($ws->is_connected && $iterations < 50) {
            $iterations++;
            await $ws->receive_text;
        }
        @state = ($ws->is_connected ? 1 : 0, $ws->close_code);
    }))->websocket('/', close_mode => 'manual');
    $ws->send_text('wrong');
    $ws->close(4401, 'unauthorized');
    $ws->complete_close;
    is($iterations, 1, 'an is_connected receive loop does not spin after a bad token');
    is(\@state, [0, 4401], 'and ends with the helper disconnected, holding the client\'s close code');
}

done_testing;
