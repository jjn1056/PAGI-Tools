# Protocol refusal applications

This executable `PAGI::Compose` app demonstrates every application form
accepted by `PAGI::WebSocket->deny` and `PAGI::SSE->decline`:

- `response`: a concrete text Response for WebSocket and JSON Response for SSE;
- `handler`: one synchronous `PAGI::Request` handler reused by both protocols;
- `async-handler`: a Request handler awaiting a labelled in-memory notice
  service before returning its Response;
- `pages`: a negotiated Pages application passed directly or returned by a
  Request handler;
- `object`: a complete custom object whose `to_app` method returns a native
  application; and
- `native`: a three-argument application wrapped with `as_app_object` so its
  coderef is not interpreted as a Request handler.

Each form has separate `/ws/<form>` and `/events/<form>` routes. Every route
awaits one refusal and returns. The WebSocket responses use status 503; SSE
also permits ordinary HTTP 200 and 204 declines when application policy calls
for them.

Run the example from the distribution root:

```sh
pagi-server --app examples/protocol-refusal/app.pl --port 5000
```

The Test::Client integration test exercises all twelve routes and the Pages
HTML/JSON negotiation branches:

```sh
prove -l t/integration-protocol-refusal-example.t
```

The selected application receives the original WebSocket or SSE scope and the
remaining original receive/send channels. These forms require a server with
the universal `pagi.connection` capability.
