# PSGI Bridge Demo

Runs a legacy PSGI application inside a PAGI-Tools application, beside native
routes:

```perl
compose(routes => [
    route('/health' => sub { return response('JSON', { ok => 1 }) }),
    route('/*path' => PAGI::App::WrapPSGI->new(psgi_app => $psgi_app), methods => '*'),
]);
```

`PAGI::App::WrapPSGI`:
- converts the PAGI scope into a PSGI `%env` hash;
- reads `http.request` events and exposes them as `psgi.input`;
- sends the PSGI response back as PAGI `http.response.*` events.

`methods => '*'` hands every HTTP method to the PSGI app, as it expects. The
route is HTTP-only, so WebSocket and SSE requests never reach it. New code can
be added as native routes ahead of the catch-all, and the PSGI app shrinks
over time.

*Note*: This demo's PSGI app returns a simple arrayref
`[ $status, $headers, $body_chunks ]`.

## Quick Start

```bash
pagi-server --app examples/psgi-bridge/app.pl --port 5000
```

```bash
curl http://localhost:5000/health
# => {"ok":1}                         <- native PAGI route

curl http://localhost:5000/
# => PSGI says hi                     <- the PSGI application
#    Body:

curl -X POST http://localhost:5000/ -d "data=test"
# => PSGI says hi
#    Body: data=test
```

## Use Case

Running an existing PSGI application (Catalyst, Dancer, Mojolicious::Lite,
etc.) on a PAGI server without modification, and migrating it route by route.

## See Also

- `PAGI::App::WrapPSGI`
- `PAGI::Spec::Www` -- the PAGI HTTP, WebSocket and SSE specification
