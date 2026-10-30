# The same tenant orders API in Starlette, for comparison with app.pl:
# pure ASGI middleware each read the request through an object of their own
# -- a Request where they read the body, an HTTPConnection where they read
# only the scope -- and the route reads the body through its own.
#
# Run:  pip install starlette uvicorn
#       uvicorn app:app --port 8000

import json

from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.requests import HTTPConnection, Request
from starlette.responses import JSONResponse
from starlette.routing import Route

TENANT_FOR_KEY = {"k-acme": "acme", "k-globex": "globex"}
LOG = []


def delivering(body, receive):
    # A receive that delivers body once, then carries on with the client's.
    delivered = False

    async def receive_body():
        nonlocal delivered
        if delivered:
            return await receive()
        delivered = True
        return {"type": "http.request", "body": body, "more_body": False}

    return receive_body


# Reads the headers and the body through its own Request, and hands the
# application the same body.
class RequestLog:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        request = Request(scope, receive)
        caller = ("legacy key" if "x-api-key" in request.headers
                  else "bearer token" if "authorization" in request.headers else "anonymous")
        body = await request.body()
        LOG.append(f"{request.method} {request.url.path} ({caller}, {len(body)} bytes)")
        await self.app(scope, delivering(body, receive), send)


# An old client's X-Api-Key becomes Authorization: Bearer, on a copy of the
# scope; the original scope is left as it was.
class LegacyApiKey:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        key = HTTPConnection(scope).headers.get("x-api-key")
        if key is None:
            return await self.app(scope, receive, send)
        headers = [(k, v) for k, v in scope["headers"] if k not in (b"x-api-key", b"authorization")]
        await self.app({**scope, "headers": headers + [(b"authorization", b"Bearer " + key.encode("latin-1"))]}, receive, send)


# Reads Authorization and the query through its own HTTPConnection: the scope it
# is given is LegacyApiKey's copy, so it sees the rewritten header.
class Tenant:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        connection = HTTPConnection(scope)
        auth = connection.headers.get("authorization", "")
        tenant = TENANT_FOR_KEY.get(auth[len("Bearer "):]) if auth.startswith("Bearer ") else None
        if tenant is None:
            refusal = JSONResponse({"error": "unknown API key"}, status_code=401,
                                   headers={"WWW-Authenticate": "Bearer"})
            return await refusal(scope, receive, send)
        state = {**scope.get("state", {}), "tenant": tenant,
                 "region": connection.query_params.get("region", "eu")}
        await self.app({**scope, "state": state}, receive, send)


# Reads the order through its own Request, and hands the route a scope and a
# receive that deliver the rewritten body.
class LegacyItems:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        order = await Request(scope, receive).json()
        if isinstance(order.get("items"), str):
            order["items"] = order["items"].split(",")
        body = json.dumps(order).encode()
        headers = [(k, v) for k, v in scope["headers"]
                   if k not in (b"content-length", b"transfer-encoding")] + [(b"content-length", str(len(body)).encode())]
        await self.app({**scope, "headers": headers}, delivering(body, receive), send)


# The route's own Request: it reads the body LegacyItems handed on, and the
# state the middleware handed on.
async def create_order(request):
    order = await request.json()
    return JSONResponse({
        "tenant": request.state.tenant,
        "region": request.state.region,
        "items": order.get("items"),
        "auth": request.headers["authorization"].split(" ")[0],
        "legacy_key": "still there" if "x-api-key" in request.headers else "gone",
    }, status_code=201)


async def show_log(request):
    return JSONResponse(LOG)


app = Starlette(
    routes=[
        Route("/orders", create_order, methods=["POST"],
              middleware=[Middleware(Tenant), Middleware(LegacyItems)]),
        Route("/log", show_log),
    ],
    middleware=[Middleware(RequestLog), Middleware(LegacyApiKey)],
)
