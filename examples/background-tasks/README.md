# Background Tasks Example

Patterns for starting background work from a request without making the
client wait for it.

Every route is an ordinary handler. An HTTP handler receives one
`PAGI::Request`, starts its background work -- asynchronous I/O, or a
subprocess for blocking work -- and returns its Response; the WebSocket
handler receives one `PAGI::WebSocket`. The background work runs on after the
handler has returned, so the response is not held up by it:

```perl
async sub signup {
    my ($request) = @_;
    my $data = await $request->json;
    fire_and_forget(send_welcome_email($data->{email}));
    return response('JSON', { status => 'created' }, status => 201);
}

compose(routes => [
    route('/signup' => \&signup, methods => ['POST']),
    websocket('/ws' => \&messages),
    ...
]);
```

## Run

```bash
pagi-server --app examples/background-tasks/app.pl --port 5000
```

Watch the server console for background task output.

## Patterns

### 1. Async I/O (Non-Blocking)

For network calls, database queries, file I/O using async libraries:

```perl
fire_and_forget(send_welcome_email($email));
```

Always use `->on_fail()` before `->retain()` to avoid silently swallowing errors.

### 2. Blocking/CPU Work (Subprocess)

For CPU-intensive or blocking operations, use `IO::Async::Function` (this
pattern ties the application to IO::Async, the loop `pagi-server` runs):

```perl
run_blocking_task("heavy_computation", 3);
```

Runs in a child process, doesn't block the event loop.

### 3. Quick Sync Work

For very fast bookkeeping (<10ms), call it in the handler before returning.
It delays that response by however long it takes:

```perl
quick_sync_task("log");
return response('JSON', { status => 'ok' });
```

**Warning:** Any blocking here blocks ALL requests! Anything slower belongs
in pattern 1 or 2.

## Endpoints

- `GET /async` - Fire-and-forget async I/O
- `GET /blocking` - CPU work in subprocess
- `POST /signup` - Real-world example with background email
- `WS /ws` - WebSocket replies, with background analytics per message
