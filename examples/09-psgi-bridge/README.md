# 09 – PSGI Bridge Demo

Wraps a synchronous PSGI app so it can run inside a PAGI HTTP scope:
- Converts the PAGI scope into a PSGI `%env` hash.
- Reads `http.request` events and exposes them as `psgi.input`.
- Sends the PSGI response back as PAGI `http.response.*` events.

This mirrors the compatibility guidance in `docs/specs/www.mkdn`.

*Note*: This demo assumes the PSGI app returns a simple arrayref `[ $status, $headers, $body_chunks ]`.
