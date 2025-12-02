# Multi-User Chat Showcase Application

## Overview

A comprehensive demo application showcasing PAGI's capabilities through a multi-user chat system with:
- Real-time WebSocket messaging
- HTTP static file serving
- SSE system notifications
- Lifespan lifecycle management
- Middleware composition

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     PAGI Application                         │
├─────────────────────────────────────────────────────────────┤
│  Middleware Stack:                                           │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Logging Middleware (request/response timing)          │ │
│  │  ┌──────────────────────────────────────────────────┐ │ │
│  │  │  Static Middleware (serve /public/* files)       │ │ │
│  │  │  ┌────────────────────────────────────────────┐ │ │ │
│  │  │  │           Core Chat App                    │ │ │ │
│  │  │  │  ┌──────────────────────────────────────┐ │ │ │ │
│  │  │  │  │  HTTP: / → index.html                │ │ │ │ │
│  │  │  │  │  HTTP: /api/rooms → room list        │ │ │ │ │
│  │  │  │  │  HTTP: /api/stats → server stats     │ │ │ │ │
│  │  │  │  │  WS:   /ws/chat → chat handler       │ │ │ │ │
│  │  │  │  │  SSE:  /events → system events       │ │ │ │ │
│  │  │  │  └──────────────────────────────────────┘ │ │ │ │
│  │  │  └────────────────────────────────────────────┘ │ │ │
│  │  └──────────────────────────────────────────────────┘ │ │
│  └────────────────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────────────────┤
│  Lifespan: startup/shutdown handling                         │
└─────────────────────────────────────────────────────────────┘
```

## Features to Showcase

### 1. Protocol Types
- **HTTP**: Static file serving, REST API endpoints
- **WebSocket**: Real-time bidirectional chat
- **SSE**: System-wide notifications (user joins, server stats)
- **Lifespan**: Graceful startup/shutdown with state initialization

### 2. Core Chat Features
- Username selection (simple auth - no password)
- Multiple chat rooms with create/join/leave
- Real-time message broadcasting
- User presence (online/offline status)
- Typing indicators
- Message history (last 100 messages per room, in-memory)
- Private messaging (/pm username message)
- System commands (/help, /rooms, /users, /nick)

### 3. Middleware Demonstration
- Request logging with timing
- Static file serving with MIME types
- ETag-based caching for static files

### 4. Frontend
- Vanilla JavaScript (no framework dependencies)
- Modern, responsive CSS
- Dark/light theme toggle
- Connection status indicator
- Emoji picker (simple)
- Notification sounds (optional)

## File Structure

```
examples/10-chat-showcase/
├── app.pl                    # Main PAGI application
├── lib/
│   └── ChatApp/
│       ├── State.pm          # Shared state management
│       ├── WebSocket.pm      # WebSocket chat handler
│       ├── SSE.pm            # SSE event broadcaster
│       └── HTTP.pm           # HTTP API handlers
├── public/
│   ├── index.html            # Main chat interface
│   ├── css/
│   │   └── style.css         # Styles (with dark/light themes)
│   └── js/
│       ├── app.js            # Main application logic
│       ├── websocket.js      # WebSocket connection manager
│       ├── ui.js             # UI rendering functions
│       └── utils.js          # Utility functions
└── README.md                 # Documentation
```

## Implementation Steps

### Step 1: State Management (ChatApp::State)
- Shared state module with:
  - `%users` - user_id => { name, send_cb, rooms, joined_at, last_seen }
  - `%rooms` - room_name => { users => {}, messages => [], created_at }
  - `@system_events` - Recent system events for SSE catch-up
  - `%sse_subscribers` - SSE client connections
- Helper functions: add_user, remove_user, add_room, broadcast_to_room, etc.

### Step 2: HTTP Handler (ChatApp::HTTP)
- `GET /` - Serve index.html
- `GET /api/rooms` - List rooms with user counts
- `GET /api/stats` - Server statistics (uptime, users, messages)
- `GET /api/room/:name/history` - Get message history for room
- Content-Type detection and proper headers

### Step 3: WebSocket Handler (ChatApp::WebSocket)
Message protocol (JSON):
```json
// Client -> Server
{ "type": "join", "room": "general" }
{ "type": "leave", "room": "general" }
{ "type": "message", "room": "general", "text": "Hello!" }
{ "type": "pm", "to": "username", "text": "Private msg" }
{ "type": "typing", "room": "general", "typing": true }
{ "type": "set_nick", "name": "NewName" }

// Server -> Client
{ "type": "connected", "user_id": "...", "rooms": [...] }
{ "type": "message", "room": "...", "from": "...", "text": "...", "ts": ... }
{ "type": "user_joined", "room": "...", "user": "..." }
{ "type": "user_left", "room": "...", "user": "..." }
{ "type": "typing", "room": "...", "user": "...", "typing": true }
{ "type": "room_list", "rooms": [...] }
{ "type": "user_list", "room": "...", "users": [...] }
{ "type": "error", "message": "..." }
{ "type": "pm", "from": "...", "text": "...", "ts": ... }
```

### Step 4: SSE Handler (ChatApp::SSE)
- Broadcast system-wide events:
  - User connected/disconnected
  - Room created/deleted
  - Server statistics (every 30s)
- Support catch-up with Last-Event-ID

### Step 5: Main App (app.pl)
- Lifespan handling (initialize default rooms on startup)
- Route dispatching based on path and protocol
- Middleware composition with builder

### Step 6: Frontend (HTML/CSS/JS)
- Responsive layout with sidebar (rooms/users) and main chat area
- WebSocket connection with auto-reconnect
- Message rendering with timestamps
- Typing indicator display
- Room switching
- Theme toggle

## Data Structures

### User State
```perl
$users{$user_id} = {
    id        => $user_id,
    name      => $username,
    send_cb   => $send,          # WebSocket send callback
    rooms     => { general => 1 },
    joined_at => time(),
    last_seen => time(),
    typing_in => undef,          # Room currently typing in
};
```

### Room State
```perl
$rooms{$room_name} = {
    name       => $room_name,
    users      => { $user_id => 1, ... },
    messages   => [ { from => ..., text => ..., ts => ... }, ... ],
    created_at => time(),
    created_by => $username,
};
```

### Message Format (stored)
```perl
{
    id   => $msg_id,
    from => $username,
    text => $message,
    ts   => time(),
    type => 'message', # or 'system', 'pm'
}
```

## Protocol Details

### WebSocket Connection Flow
1. Client connects to `/ws/chat?name=Username`
2. Server sends `websocket.connect`, client waits
3. Server sends `connected` event with user_id and room list
4. Server auto-joins user to "general" room
5. Server broadcasts `user_joined` to room
6. Client can send messages, join/leave rooms
7. On disconnect, server broadcasts `user_left` to all user's rooms

### SSE Event Stream
```
event: user_connected
data: {"user":"Alice","count":5}
id: 123

event: stats
data: {"users":5,"rooms":3,"messages":1234,"uptime":3600}
id: 124
```

## Security Considerations (Demo-Level)
- Usernames sanitized (alphanumeric + underscore, 3-20 chars)
- Message text HTML-escaped before display
- Room names sanitized
- No rate limiting (demo app)
- No persistent storage (in-memory only)

## Testing
- Manual testing via browser
- Can add t/10-chat-showcase.t for automated WebSocket testing

## Commands Reference

In chat, users can type:
- `/help` - Show available commands
- `/rooms` - List all rooms
- `/users` - List users in current room
- `/join <room>` - Join/create a room
- `/leave [room]` - Leave current or specified room
- `/pm <user> <message>` - Send private message
- `/nick <name>` - Change nickname
- `/me <action>` - Send action message (*User does something*)

---

## Acceptance Criteria

1. User can open the chat in a browser and set a username
2. User can see list of rooms and create/join rooms
3. Messages are delivered in real-time to all users in the room
4. Users see who's online in each room
5. Typing indicators work
6. Private messages work
7. SSE stream shows system events
8. Frontend is responsive and looks professional
9. Application handles disconnects gracefully
10. Multiple simultaneous users work correctly
