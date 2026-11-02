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

**1. Every send and receive of the handler's waits for the token check.**
The handler's `websocket.accept` goes to the server at once (the client
cannot send a token before the handshake completes) and starts the check.
A helper owns the connection from the moment it issues its accept, so the
handler may send or receive while that accept is still pending. Its sends
wait for the check, so nothing reaches a client that has not shown a good
token; its receives wait too, or one could take the token itself.

**2. Read the token from the raw receive, skipping `websocket.connect`.**
`PAGI::WebSocket` never reads the handshake event, so the raw receive's
first event is still `websocket.connect`. A middleware that took the first
event as the token would reject every client.

**3. After the 4401 close, drop the handler's sends.** The handler's
`accept` returns into a connection the middleware has closed. A send the
application issues after its own `websocket.close` fails (PAGI::Server
answers "cannot send 'websocket.send' after websocket.close"), and the
handler dies with it. The middleware closed, so it swallows those sends.

**4. After the 4401 close, the handler's receive skips the client's
remaining frames and gets the server's disconnect.** A client may send
more frames before the Close reaches it, and the server still delivers
them. The middleware reads past them to the `websocket.disconnect` the
server delivers once the client has answered the Close, and hands that on.
The handler then sees what its connection reports: `is_connected` false,
`close_code` the client's 4401. It waits for the client's answer, which
the server bounds with its close timeout.

```perl
my $check = async sub {
    my ($accept) = @_;
    await $send->($accept);
    my $first = await $receive->();
    $first = await $receive->() while $first->{type} eq 'websocket.connect';   # rule 2
    if ($first->{type} eq 'websocket.disconnect') {     # the client left
        $ended = $first;
        return;
    }
    return if defined $first->{text} && $VALID_TOKEN{ $first->{text} };
    await $send->({ type => 'websocket.close', code => 4401, reason => 'unauthorized' });
    $closed = 1;
    return;
};
my $checked_send = async sub {
    my ($event) = @_;
    if ($event->{type} eq 'websocket.accept') {
        $checked = $check->($event);
        return await $checked;
    }
    await $checked if $checked;                         # rule 1
    return if $closed || $ended;                        # rule 3
    await $send->($event);
};
my $checked_receive = async sub {
    await $checked if $checked;                         # rule 1
    while ($closed && !$ended) {                        # rule 4
        my $event = await $receive->();
        $ended = $event if $event->{type} eq 'websocket.disconnect';
    }
    return {%$ended} if $ended;
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
still send a frame the Close has not yet reached. Rule 1's tests send and
receive while the handler's accept is pending, one of them with an accept
whose send the test settles late, as a server may.
