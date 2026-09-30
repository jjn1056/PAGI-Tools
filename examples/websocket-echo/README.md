# WebSocket Echo

The smallest PAGI-Tools WebSocket application: one route whose handler
receives one `PAGI::WebSocket`.

Compare the raw PAGI protocol version, `examples/04-websocket-echo/` in the
PAGI distribution.

## Run

```bash
pagi-server --app examples/websocket-echo/app.pl --port 5000
```

Test with:
```bash
websocat ws://localhost:5000/
```

## Code

```perl
async sub echo {
    my ($ws) = @_;

    $ws->on_close(sub {
        my ($code) = @_;
        print STDERR 'Client disconnected: ', ($code // 'no close frame'), "\n";
    });

    await $ws->accept;
    await $ws->each_text(async sub {
        my ($text) = @_;
        await $ws->send_text("echo: $text");
    });
}

compose(routes => [websocket('/' => \&echo)]);
```

## vs Raw Protocol

| PAGI::WebSocket | Raw Protocol |
|-----------------|--------------|
| `await $ws->accept` | Manual handshake events |
| `$ws->each_text(...)` | Manual event loop |
| `$ws->send_text(...)` | Build event hashref |
| `$ws->on_close(...)` | Check disconnect events |
