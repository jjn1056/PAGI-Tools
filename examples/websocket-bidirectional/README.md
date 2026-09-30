# websocket-bidirectional — full-duplex WebSocket

Send **and** receive at the same time. After accepting, the handler runs two
concurrent branches on one connection:

- **incoming** — echo each client message back, uppercased.
- **outgoing** — push an unsolicited server `tick` every second.

You see the server's ticks interleaved with echoes of whatever you type — both
directions live at once.

This is the same demo as the raw-protocol
[`examples/18-bidirectional-websocket`](https://github.com/jjn1056/pagi/tree/main/examples/18-bidirectional-websocket)
in the `PAGI` distribution, written with PAGI-Tools: a WebSocket route whose
handler receives one **`PAGI::WebSocket`**.

## One handler, one WebSocket

```perl
async sub duplex {
    my ($ws) = @_;
    await $ws->accept;

    my $incoming = $ws->each_text(async sub {
        my ($text) = @_;
        await $ws->send_text_if_connected("you said: \U$text");
    });

    my $outgoing = (async sub {
        my $n = 0;
        while ($ws->is_connected) {
            await Future::IO->sleep(1);
            await $ws->send_text_if_connected('server tick #' . ++$n);
        }
    })->();

    await Future->wait_any($incoming, $outgoing);
}

compose(routes => [websocket('/' => \&duplex)]);
```

| `PAGI::WebSocket` | does |
|---|---|
| `$ws->accept` | the handshake |
| `$ws->each_text(sub {...})` | the **receive loop**, a Future that completes when the client disconnects |
| `$ws->send_text_if_connected(...)` | a send that becomes a **no-op once the socket is closing**, so the send loop never races the teardown |
| `$ws->is_connected` | a clean loop guard |

The two branches are joined with `Future->wait_any`: a client disconnect ends
`incoming`, and `wait_any` then cancels the idle `outgoing` tick loop. (That
cancel is right here because the losers are *our own branches* — unlike a
receive multiplex, where the raced future is the live `$receive` that must not
be cancelled.)

## Two producers, no queue

`incoming` and `outgoing` both send on the same socket, whenever they like.
The PAGI specification requires sends on a connection to go out one at a time
("Sends Are Sequential"), and `PAGI::WebSocket` does that for you: a send made
while another is in flight waits for it. So any handler with more than one
producer — this one, a chat where a reply races a broadcast, a server push
racing a request — simply calls the send methods. Only code that calls the raw
`$send` itself has to serialize its own sends.

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
