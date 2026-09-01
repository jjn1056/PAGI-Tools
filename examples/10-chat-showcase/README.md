# Multi-User Chat Showcase

A comprehensive demo application showcasing PAGI's capabilities through a real-time multi-user chat system.

## Features Demonstrated

### PAGI Protocol Types
- **WebSocket** (`/ws/chat`) - Real-time bidirectional messaging
- **HTTP** - Static file serving and REST API endpoints
- **SSE** (`/events`) - Server-Sent Events for system notifications
- **Lifespan** - Application startup/shutdown lifecycle

### Chat Features
- Multiple chat rooms (create, join, leave)
- Real-time message broadcasting
- Typing indicators
- Private messaging (`/pm user message`)
- User presence tracking
- Message history (last 100 per room)
- Chat commands (`/help`, `/nick`, `/rooms`, `/users`, `/me`)

## Running the Application

```bash
# From the PAGI root directory
perl -Ilib -Iexamples/10-chat-showcase/lib bin/pagi-server \
    --app examples/10-chat-showcase/app.pl \
    --port 5000

# Then open http://localhost:5000 in your browser
```

## Architecture

The mutable `PAGI::App::Router` is this showcase's declaration-time frontend
for HTTP, WebSocket, SSE, and static routes. `PAGI::App::Router` already
implements `to_app`, so Compose mounts both chat frontends directly:

```text
PAGI::App::Router (chat frontend)
  -> mount('/', app => $router)
    -> PAGI::Compose (deployed root)

ChatApp::HTTP's PAGI::App::Router (API frontend)
  -> mount('/', app => $router)
    -> compose(routes => [...])->to_app
    -> internal PAGI::Compose application
```

At dispatch, those completed boundaries form this graph:

```text
PAGI::Compose
  -> application-wide logging middleware
    -> Compose root Router
      -> unnamed root Mount
        -> PAGI::App::Router
          -> opaque HTTP handler
            -> internal PAGI::Compose application or PAGI::App::File
          -> WebSocket / SSE handlers
```

Configured startup and shutdown callbacks require server lifespan state
support. Application middleware receives the lifespan scope and events as well
as request protocols, so the logging middleware records both lifecycle and
request dispatch. The Compose root explicitly describes that factory as
`middleware => [middleware(\&with_logging)]`; core middleware lists contain
only inspectable immutable descriptions.

The selected Router supplies negotiated HTTP 404 and 405 outcomes. Root
Compose supplies the response-completion and 500 failsafes; neither layer
changes the WebSocket or SSE ownership described below.

The WebSocket and SSE targets are existing native PAGI applications, so their
route declarations use explicit `as_app`. The final
`any('/*path' => as_app($http_handler))` Route keeps the static/API fallback
HTTP-only, so a WebSocket or SSE miss retains the Router's protocol-specific
outcome instead of reaching the file application. `ChatApp::HTTP` therefore
gives its internal API Router a Compose boundary of its own. An unknown
`/api/...` path receives that child's complete 404 instead of falling through
to static serving.

Inside that HTTP boundary, `/api/...` dispatch runs first. Every other HTTP
request is delegated to one caller-relative
`PAGI::App::File->from_app_path('public')->to_app`, which owns index selection,
streaming, MIME types, ranges, conditional requests, and negotiated errors.
The example does not duplicate filesystem path filtering or read static files
into application memory.

Both chat frontends use the same direct application boundary:

```perl
compose(routes => [mount('/' => app => $router)]);
```

The unnamed root Mount consumes no path and keeps each Router's middleware,
default, and routing outcomes. The outer Compose Router treats each frontend
as an application boundary and does not inspect its descendant names. Call
`$router->to_router` only when a parent must discover those names or retain an
immutable snapshot; neither chat frontend has such a parent-side consumer. See
[PAGI::Compose](../../lib/PAGI/Compose.pm) and
[PAGI::Routing::Mount](../../lib/PAGI/Routing/Mount.pm) for details.

See the [rooted file-serving upgrade guide](../../UPGRADING.md#rooted-file-serving-security-contract)
for the status, hidden-file, symlink, and XSendfile migration contract.

```
examples/10-chat-showcase/
├── app.pl                    # Main PAGI application (routing + middleware)
├── lib/ChatApp/
│   ├── State.pm              # Shared state management (in-memory)
│   ├── HTTP.pm               # HTTP handler (static files + API)
│   ├── WebSocket.pm          # WebSocket chat handler
│   └── SSE.pm                # SSE system events
└── public/
    ├── index.html            # Chat interface
    ├── css/style.css         # Styles (light/dark themes)
    └── js/app.js             # Frontend JavaScript
```

## API Endpoints

### HTTP
- `GET /` - Chat frontend
- `GET /api/rooms` - List rooms with user counts
- `GET /api/room/{name}/history` - Message history
- `GET /api/room/{name}/users` - Users in room
- `GET /api/stats` - Server statistics

### WebSocket (`/ws/chat?name=Username`)
JSON message protocol for real-time chat.

### SSE (`/events`)
System-wide event stream (user connects, stats updates).

## Chat Commands

Type these in the chat input:

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/rooms` | List all rooms |
| `/users` | List users in current room |
| `/join <room>` | Join or create a room |
| `/leave` | Leave current room |
| `/pm <user> <msg>` | Send private message |
| `/nick <name>` | Change your nickname |
| `/me <action>` | Send action message |

## WebSocket Message Protocol

### Client to Server
```json
{ "type": "message", "room": "general", "text": "Hello!" }
{ "type": "join", "room": "random" }
{ "type": "leave", "room": "random" }
{ "type": "typing", "room": "general", "typing": true }
{ "type": "pm", "to": "username", "text": "Hi!" }
{ "type": "set_nick", "name": "NewName" }
```

### Server to Client
```json
{ "type": "connected", "user_id": "...", "name": "...", "rooms": [...] }
{ "type": "message", "room": "...", "from": "...", "text": "...", "ts": ... }
{ "type": "user_joined", "room": "...", "user": "...", "users": [...] }
{ "type": "user_left", "room": "...", "user": "...", "users": [...] }
{ "type": "typing", "room": "...", "user": "...", "typing": true }
{ "type": "pm", "from": "...", "text": "...", "ts": ... }
{ "type": "error", "message": "..." }
```

## Frontend Features

- Responsive design (mobile-friendly)
- Dark/light theme toggle (persisted)
- Auto-reconnecting WebSocket
- Connection status indicator
- Keyboard-friendly navigation
- Real-time stats via SSE
