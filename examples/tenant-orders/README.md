# Tenant orders

An orders API for several tenants, behind four middleware that each read the
request through an object of their own -- a `PAGI::Request` where they read
the body, a `PAGI::HTTPConnection` where they read only the scope, as
Starlette's own middleware read headers through `Headers(scope=...)` /
`HTTPConnection` -- while the route reads the body through its own:

| Middleware | Reads | Hands on |
|---|---|---|
| `request_log` | the headers, and the body ahead, to log its size | the same body (`record_receive`) |
| `legacy_api_key` | `X-Api-Key` | a copy of the scope with `Authorization: Bearer` instead |
| `tenant` | `Authorization` and `?region=` | a copy of the scope with the tenant |
| `legacy_items` | the JSON order | a body whose comma-separated `items` string is a list |

`app.py` is the same application in Starlette; both were run (`pagi-server`
and `uvicorn`) with the requests below and gave the same answers.

Requires Perl 5.40.

```
pagi-server --app examples/tenant-orders/app.pl --port 5000
uvicorn app:app --port 8000      # from this directory
```

## Each reader reads what it was handed

A `PAGI::Request` (and a `PAGI::HTTPConnection`, which it extends) keeps what
it parses -- headers, query, body -- on itself, and writes nothing to the
scope. So each reads the scope and the body it was handed, whoever read the
request before it:

- `tenant` sees the `Authorization` that `legacy_api_key` wrote on its copy
  of the scope, although `request_log` had read the headers first;
- the route reads the list `legacy_items` handed on, although `request_log`
  had read the original body.

Until this release, a Request kept its parse in the scope, and a copy of the
scope carried it along. Run on PAGI-Server with the 0.002 Request (PAGI-Tools'
`main` before this change), the same requests show both effects: a legacy
client's order is refused (401: `tenant` was served the headers
`request_log` had parsed, before the rewrite), and a bearer client's
`"items":"tea,cups"` reaches the route as the string `request_log` read, not
the list. This is why Starlette keeps its parse on the Request, and why
PAGI-Tools now does.

Whoever reads the body ahead hands the application a receive that delivers
a body: the same one (`request_log`, with `record_receive`), or a different
one (`legacy_items`, as `examples/modify-form-post` does). See "Reading the
request body" in `PAGI::Middleware`.

## Try

```bash
curl -i localhost:5000/orders -H 'Authorization: Bearer k-acme' \
     -H 'Content-Type: application/json' -d '{"items":["tea","cups"]}'          # 201, acme, eu
curl -i 'localhost:5000/orders?region=us' -H 'X-Api-Key: k-globex' \
     -H 'Content-Type: application/json' -d '{"items":"coffee,filters,mugs"}'   # 201, globex, a list of 3
curl -i localhost:5000/orders -H 'X-Api-Key: k-nobody' -d '{}'                  # 401
curl localhost:5000/log
```

## The Starlette version

`app.py` writes each middleware as a pure ASGI class that builds a
`Request(scope, receive)` where it reads the body and an
`HTTPConnection(scope)` where it reads only the scope, copies the scope to
change it, and hands on a receive that delivers the body it read; the tenant goes in the scope's
`state`, which the route reads as `request.state`. Run on PAGI-Server and on
uvicorn 0.54.0 / Starlette 1.10.0, the four requests above and the log gave
the same statuses and bodies.

## See also

- `PAGI::Request` (SUBCLASSING: a copied scope is a new scope and needs a
  new Request), `PAGI::Utils::Middleware`'s `record_receive`
- `examples/modify-form-post`, `examples/signed-requests`,
  `examples/method-override`: the other shapes of a middleware and the body
