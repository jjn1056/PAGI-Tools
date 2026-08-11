# Endpoint Demo

Showcases all three PAGI endpoint types with middleware.

## Run

```bash
pagi-server -I lib --app examples/endpoint-demo/app.pl --port 5000
```

Visit http://localhost:5000/

## Features

### HTTP Endpoint (REST API)

```perl
package MessageAPI;
use parent 'PAGI::Endpoint::HTTP';

async sub get { ... }
async sub post { ... }
```

### WebSocket Endpoint (Echo)

```perl
package EchoWS;
use parent 'PAGI::Endpoint::WebSocket';

async sub on_connect { ... }
async sub on_receive { ... }
```

### SSE Endpoint (Notifications)

```perl
package MessageEvents;
use parent 'PAGI::Endpoint::SSE';

async sub on_connect { ... }
sub on_disconnect { ... }
```

### Middleware Examples

- `PAGI::Middleware::AccessLog` - Request logging
- Coderef middleware - Request timing, JSON validation

The three Endpoint applications are already compiled native PAGI components,
so the App Router attaches them as explicit opaque mounts. The `/` static-file
mount is last because the shared routing engine preserves written order and a
matched mount prefix owns dispatch immediately.

```perl
$router->mount('/' => PAGI::App::File->app_path('public'));
```

## Routes

- `GET/POST /api/messages` - REST API
- `WS /ws/echo` - WebSocket echo
- `SSE /events` - Live notifications
- `GET /*` - Static files
