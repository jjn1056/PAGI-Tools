# Compose Application Root

This example uses `PAGI::Compose` to put one declarative route target,
application-wide request-ID middleware, and startup/shutdown callbacks at the
deployed application root. Its direct root declares `routes => [...]`;
`compose(%options)` returns an immutable description;
the final `->to_app` compiles the PAGI coderef that the server runs.

Run it with:

```bash
pagi-server examples/compose/app.pl --port 5000
curl -i http://localhost:5000/
```

The server must support PAGI lifespan state when callbacks are configured.
Only the deployed root owns lifespan: mounting this composition below another
app dispatches its request routes but does not run its callbacks.
