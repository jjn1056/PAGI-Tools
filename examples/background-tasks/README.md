# Background Tasks Example

Patterns for running work after sending a response.

This example deliberately sends responses before starting follow-up work, so
its App Router declarations use explicit `raw` handlers. Ordinary App handlers
instead receive `$c`, return a Response, and leave emission to the shared
routing compiler.

The final Router is deployed through `compose(app => $router)`. Direct
`$router->to_app` remains useful as a low-level routing component, but an
unknown HTTP path then completes without response events; Compose supplies the
complete application boundary used by the server example.

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
await $res->json({ status => 'ok' })->respond($send);
quick_sync_task("log");  # runs after response is sent
```

**Warning:** Any blocking here blocks ALL requests!

## Endpoints

- `GET /async` - Fire-and-forget async I/O
- `GET /blocking` - CPU work in subprocess
- `POST /signup` - Real-world example with background email
