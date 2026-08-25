# websocket-bidirectional — full-duplex WebSocket with PAGI::Context

Send **and** receive at the same time. After accepting, the handler runs two
concurrent branches on one connection:

- **incoming** — echo each client message back, uppercased.
- **outgoing** — push an unsolicited server `tick` every second.

You see the server's ticks interleaved with echoes of whatever you type — both
directions live at once.

This is the same demo as the raw-protocol
[`examples/18-bidirectional-websocket`](../../../PAGI/examples/18-bidirectional-websocket)
in the `PAGI` distribution, rewritten with **`PAGI::Context`** to show how much it
folds away.

## What PAGI::Context gives you here

One object (`$ctx`) wraps `$scope`/`$receive`/`$send` and hands you exactly the
pieces a bidirectional handler needs:

| `PAGI::Context` | does |
|---|---|
| `$ctx->each_text(sub {...})` | the **receive-loop**, returned as a Future that completes when the client disconnects — no manual `websocket.connect`/`receive`/`disconnect` handling |
| `$ctx->send_text_if_connected(...)` | a send that becomes a **no-op once the socket is closing**, so the concurrent send-loop never races the teardown (no `eval`, no guards) |
| `$ctx->is_connected` | a clean loop guard |
| `$ctx->accept` | the handshake |

Compare with the raw version, which spells out the `websocket.connect` →
`websocket.accept` handshake, the `websocket.receive`/`websocket.disconnect`
dispatch, and its own helper to race without cancelling `$receive`.

The two branches are joined with `Future->wait_any`: a client disconnect ends
`incoming`, and `wait_any` then cancels the idle `outgoing` tick-loop. (That
cancel is the right call here because the losers are *our own branches* — unlike
a receive-multiplex, where the raced future is the live `$receive` that must not
be cancelled.)

## The queue: THE rule for more than one send-producer

`incoming` and `outgoing` are two independent producers writing to the
**same socket** at once. PAGI leaves overlapping in-flight sends
unspecified — issuing a second send before the first has been awaited is
exactly what the development `Lint` middleware's overlap check warns about —
so this handler never calls `$ctx->send_text_if_connected` directly from more
than one place. Instead, both branches route through one small serializing
queue:

```perl
my $send_queue = Future->done;
my $queue_send = sub {
    my (@text) = @_;
    my $prev = $send_queue;
    $send_queue = (async sub {
        await $prev;
        await $ctx->send_text_if_connected(@text);
    })->();
    return $send_queue;
};
```

Every call chains after the one before it, so only one send is ever in
flight on this socket regardless of which branch queued it; awaiting the
returned Future both confirms the send went out and naturally paces a
producer against a slow or backpressured connection.

This is **the** pattern for a full-duplex handler with more than one
send-producer — every other example in this repo that faces the same
problem (`sse-dashboard`, `endpoint-demo`, `background-tasks`,
`10-chat-showcase`, `websocket-chat-v2`) points back to this same queue
shape rather than inventing its own variant.

## Run

```bash
pagi-server --app examples/websocket-bidirectional/app.pl --port 5000
```

From an uninstalled checkout, add the dist libs:

```bash
perl -I /path/to/PAGI-Server/lib -I /path/to/PAGI-Tools/lib \
  /path/to/PAGI-Server/bin/pagi-server \
  --app examples/websocket-bidirectional/app.pl --port 5000
```

## Test

Use a **WebSocket-aware** client — not `curl` or `socat`, which can't do the
WebSocket `Upgrade` handshake or frame masking. With
[`websocat`](https://github.com/vi/websocat):

```bash
websocat ws://localhost:5000/
# server tick #1          <- arrives on its own every second
hello                     <- you type this
you said: HELLO           <- echoed back, uppercased
# server tick #2
```

...or a browser console, nothing to install:

```js
let ws = new WebSocket('ws://localhost:5000/');
ws.onmessage = e => console.log(e.data);
ws.onopen    = () => ws.send('hello');
```

The `tick` lines keep arriving whether or not you type — that's the outgoing
branch running concurrently with the incoming one.
