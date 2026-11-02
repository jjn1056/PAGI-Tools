# WebSocket first-frame authentication

A browser's `WebSocket` cannot set an `Authorization` header, so the usual
pattern is: accept the connection, read a token from the client's first
message, and close with code 4401 if it is wrong. This example does that in
a middleware that protects every WebSocket route, in front of a route whose
handler uses its own `PAGI::WebSocket` as usual (accept, then echo) and
never sees the token.

```
pagi-server --app examples/websocket-first-frame-auth/app.pl --port 5000
websocat ws://localhost:5000/
```

Type `let-me-in` first; after that every message is echoed. Any other first
message gets a Close with code 4401 and reason `unauthorized`, and nothing
else.

## The middleware builds no helper

A connection has one helper, and the route builds it (`PAGI::WebSocket`,
"WHICH HELPER ANSWERS"). A middleware that built its own `PAGI::WebSocket`
to accept and read the token would leave the route's handler with a second
one, whose every operation but `try_send_*` croaks "this connection was
answered by another helper; use that one". So the middleware wraps the raw `$send` and
`$receive` instead, and four rules make that work.

**1. Hold the handler's accept until the token is checked.** The handler's
`websocket.accept` goes to the server at once (the client cannot send a
token before the handshake completes), but the wrapped `$send` returns only
after the first message is read and checked. Anything the handler sends
after `accept`, a greeting say, then reaches only a client that showed a
good token.

**2. Read the token from the raw receive, skipping `websocket.connect`.**
`PAGI::WebSocket` never reads the handshake event, so the raw receive's
first event is still `websocket.connect`. A middleware that took the first
event as the token would reject every client.

**3. After the 4401 close, drop the handler's sends.** The handler's
`accept` returns into a connection the middleware has closed. A send the
application issues after its own `websocket.close` fails (PAGI::Server
answers "cannot send 'websocket.send' after websocket.close"), and the
handler dies with it. The middleware closed, so it swallows those sends.

**4. After the 4401 close, hand the handler's receive the disconnect.** A
client may send more frames before the Close reaches it, and the server
still delivers them. The handler's receive gets the
`websocket.disconnect` the close stands for instead, so those frames never
reach it and it ends as it does when any client leaves.

```perl
my $checked_send = async sub {
    my ($event) = @_;
    return if $ended;                                   # rule 3
    await $send->($event);
    return unless $event->{type} eq 'websocket.accept';
    my $first = await $receive->();                     # rule 1
    $first = await $receive->() while $first->{type} eq 'websocket.connect';   # rule 2
    if ($first->{type} eq 'websocket.disconnect') {     # the client left
        $ended = $first;
        return;
    }
    return if defined $first->{text} && $VALID_TOKEN{ $first->{text} };
    await $send->({ type => 'websocket.close', code => 4401, reason => 'unauthorized' });
    $ended = { type => 'websocket.disconnect', code => 4401, reason => 'unauthorized' };
    return;
};
my $checked_receive = async sub {
    return {%$ended} if $ended;                         # rule 4
    return await $receive->();
};
```

## Traps

- **A handler that sends before it receives.** Rule 3 covers sends made
  while the client has not yet answered the Close, which is when a handler
  that sends straight after `accept` makes them. Once the connection has
  ended -- the client answered the Close, or left without sending a token --
  the handler's `PAGI::WebSocket` sees that itself, and its `send_text`
  croaks "Cannot send on closed WebSocket", as on any socket whose client
  has gone; no middleware can change that. A handler that sends first,
  after awaiting something, sends with `try_send_text`, which returns 0
  there, or checks `is_connected`. This example's handler receives first,
  so it ends cleanly either way.
- **The wait for the token is unbounded.** A client that connects and
  sends nothing holds the connection open. PAGI::Server's
  `--ws-idle-timeout` bounds it, and is off by default; or bound the
  middleware's first `$receive` with a timer of your own.

## Testing it

`t/example-websocket-first-frame-auth.t` drives it with
`PAGI::Test::Client`. Its default close mode answers an application's
Close at once, inside the send, which a real client cannot do; the tests of
rules 3 and 4 use `close_mode => 'manual'`, so the Close is answered after
the handler's next step, as it is on a real server, and the test client can
still send a frame the Close has not yet reached.
