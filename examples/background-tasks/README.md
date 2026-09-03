# Background Tasks Example

Patterns for running work after sending a response.

The index is an ordinary Route handler: it receives `PAGI::Request`, returns an
application value, and leaves invocation to the shared routing compiler. The
three task routes deliberately send their responses before starting follow-up
work, so only those routes wrap native three-channel applications with
`as_app_object`.

The native WebSocket application is a Mount application and is passed directly:

```perl
mount('/ws', app => async sub { ... });
```

The HTTP declarations retain their written order inside Compose. Only Route
endpoints that must know response emission has completed use `as_app_object` and own
the live protocol channels. The WebSocket Mount already occupies a native
application position and needs no wrapper.

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

For CPU-intensive or blocking operations, use `IO::Async::Function`:

```perl
run_blocking_task("heavy_computation", 3);
```

Runs in a child process, doesn't block the event loop.

### 3. Quick Sync Work

For very fast operations (<10ms) after response - just call directly after `await`:

```perl
my $response = json_response({ status => 'ok' });
await invoke_app($response, $scope, $receive, $send);
quick_sync_task("log");  # runs after response is sent
```

**Warning:** Any blocking here blocks ALL requests!

## Endpoints

- `GET /async` - Fire-and-forget async I/O
- `GET /blocking` - CPU work in subprocess
- `POST /signup` - Real-world example with background email
