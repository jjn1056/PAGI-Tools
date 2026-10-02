# Multi-User Chat

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
# From the PAGI-Tools root directory, with PAGI-Server installed
pagi-server -I lib --app examples/chat/app.pl --port 5000

# Then open http://localhost:5000 (two tabs to chat with yourself)
```

## How It Is Built

One `compose` declares every entry point. Each handler receives one object
for its protocol and returns a value or awaits that object's methods:

```perl
compose(
    routes => [
        websocket('/ws/chat' => \&ChatApp::WebSocket::chat),   # gets a PAGI::WebSocket
        sse('/events' => \&ChatApp::SSE::events),               # gets a PAGI::SSE
        mount('/api', app => ChatApp::HTTP::routing()),         # a Router of Request handlers
        route('/*path' => PAGI::App::File->from_app_path('public')),
    ],
    middleware => [middleware(\&with_logging)],
    lifespan   => { startup => ..., shutdown => ... },
);
```

- **`ChatApp::HTTP::routing()`** returns an immutable Router. Its handlers take
  a `PAGI::Request` and return `response('JSON', ...)`, or a negotiated
  `not_found(detail => ...)` from `PAGI::Pages`, which is HTML for a browser
  and a problem document for an API client.
- **`ChatApp::WebSocket::chat($ws)`** reads the session from `$ws->query`,
  registers cleanup with `$ws->on_close`, then `accept`s, talks JSON with
  `send_json`/`each_json`, and asks the server for protocol pings with
  `$ws->keepalive(25)`.
- **`ChatApp::SSE::events($sse)`** replays the system events a reconnecting
  client missed (`$sse->last_event_id`), receives new ones live from
  `ChatApp::State`, and sends statistics with `$sse->every(10, ...)`.
- **Static files** use `PAGI::App::File`, which owns index selection, MIME
  types, ranges, conditional requests and negotiated errors. It sits on an
  HTTP `route` rather than a `mount('/')`, because a Route is HTTP-only: a
  WebSocket or SSE request to an unknown path still gets the Router's refusal
  instead of reaching the file application.
- **`with_logging`** is written out because `PAGI::Middleware::AccessLog`
  covers HTTP only; this one also logs WebSocket and SSE connections and the
  lifespan loop.

No event loop is named in application code. The one timer the application
needs, the grace period before announcing that a disconnected user left, is a
`Future::IO->sleep`; `pagi-server` binds the Future::IO implementation.

```
examples/chat/
├── app.pl                    # the compose: routes, logging, lifespan
├── lib/ChatApp/
│   ├── State.pm              # shared in-memory state
│   ├── HTTP.pm               # JSON API (a Router mounted at /api)
│   ├── WebSocket.pm          # chat($ws)
│   └── SSE.pm                # events($sse)
└── public/
    ├── index.html            # chat interface
    ├── css/style.css         # styles (light/dark themes)
    └── js/app.js             # frontend JavaScript
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
System events as they happen (users connecting and leaving, rooms created and
deleted), replayed after a reconnect, plus statistics every 10 seconds.

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
{ "type": "connected", "session_id": "...", "name": "...", "rooms": [...] }
{ "type": "resumed", "session_id": "...", "name": "...", "rooms": [...], "missedMessages": {...} }
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
