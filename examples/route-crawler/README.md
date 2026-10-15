# Route Crawler

A text adventure whose dungeon is another application's routes. Every entry
of the application's `route_table` becomes a room, and you explore it over a
WebSocket from a terminal-style page. By default the dungeon is the
[openapi-notes](../openapi-notes/README.md) example.

This example requires Perl 5.40 or newer and `Type::Tiny` (for openapi-notes).
Run it from the distribution root:

```console
pagi-server --lib lib -I examples/route-crawler/lib -I examples/openapi-notes/lib \
    --app examples/route-crawler/lib/RouteCrawler.pm --port 5000
```

Then open <http://localhost:5000/>.

## How the dungeon is built

| In the application | In the dungeon |
|---|---|
| a route (its path template) | a room; its `desc` describes it |
| the route's methods | the room's actions (`get`, `post`, `delete`, ...), HEAD folded into GET |
| an SSE or WebSocket route | the action `listen` or `connect` |
| a path with no route of its own above other routes (a mounted Router) | an open archway |
| a `mount` entry, a separate application | a sealed door |
| `Requires` on a route | the action is chained; each scope is a key, hidden in a room it does not unlock |
| `/openapi.json` | the library, where `read map` lists the rooms |

Commands: `look`, `go <path>`, `take`, `inventory`, `read map`, `help`, and
the room's actions. You win by seeing every room you can reach and opening
every lock.

## Files

```
lib/RouteCrawler.pm           the application: a PAGI::App::Compose, GET / and the /play WebSocket
lib/RouteCrawler/Dungeon.pm   the dungeon built from route_table, and the game (no I/O)
public/index.html             the page
```

`t/example-route-crawler.t` checks the dungeon against openapi-notes and
plays a game to the win over the WebSocket.
