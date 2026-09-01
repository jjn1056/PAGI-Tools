# Background Tasks Example

Patterns for running work after sending a response.

This example deliberately sends responses before starting follow-up work, so
its App Router declarations wrap native three-channel applications with
`as_app`. Ordinary App handlers instead receive `PAGI::Request`, return an
application value, and leave invocation to the shared routing compiler.

`PAGI::App::Router` already implements `to_app`, so Compose mounts the
background-task frontend directly:

```perl
compose(routes => [mount('/' => app => $router)]);
```

The unnamed root Mount consumes no path and keeps the Router's middleware,
default, and routing outcomes. The outer Compose Router treats the frontend as
an application boundary and does not inspect its descendant names. The frontend
already implements `to_app`: mount it directly for ordinary deployment. Use
`to_router` only when a parent must discover those names or retain an immutable
snapshot; this application has no such parent-side consumer.

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
