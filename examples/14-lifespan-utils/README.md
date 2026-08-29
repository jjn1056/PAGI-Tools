# 14 – Lifespan Hooks via PAGI::Utils

Minimal app that uses `PAGI::Utils::handle_lifespan` for startup/shutdown hooks
and `PAGI::Pages` for its plain-text welcome response.

## Requirements

- Perl 5.42+
- `Future::AwaitAsync`

## Quick Start

```bash
pagi-server --app examples/14-lifespan-utils/app.pl --port 5000
```

## Demo

```bash
curl http://localhost:5000/
# => Welcome to PAGI
#    ...
#    https://metacpan.org/pod/PAGI
```

Stop the server with Ctrl+C to see the shutdown hook log message.

`handle_lifespan` owns lifecycle scopes. Once the application reaches an HTTP
scope, it constructs `welcome_page($scope, as => 'text')` and explicitly emits
that Response with the raw application's full `($scope, $receive, $send)`
triplet.

## Spec References

- Lifespan events – `docs/specs/lifespan.mkdn`
- HTTP events – `docs/specs/www.mkdn`
