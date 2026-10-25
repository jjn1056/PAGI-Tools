# The same signed-requests application in Starlette, for comparison with
# app.pl: a middleware checks an HMAC over each request body through the
# receive it hands the routes, as Starlette's RequestBodyLimitMiddleware
# counts bytes, and the routes read their bodies as usual.
#
# Run:  pip install starlette uvicorn
#       SIGNING_SECRET=s3cret uvicorn app:app --port 8000

import contextlib
import hashlib
import hmac
import os
import tempfile

from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.responses import JSONResponse
from starlette.routing import Mount, Route

SECRET = os.environ.get("SIGNING_SECRET", "s3cret")


# The middleware's own failure. Not an HTTPException: a route-level
# exception handler would answer that at the route, before the middleware
# could tell its own failure from the route's.
class BadSignature(Exception):
    pass


class VerifySignature:
    def __init__(self, app, secret):
        self.app = app
        self.secret = secret.encode()

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        given = dict(scope["headers"]).get(b"x-signature")
        if given is None:
            return await self.refuse(scope, receive, send)

        # The routes' receive: each chunk is hashed as they read it, and the
        # last is handed over only if the signature covers the body.
        sha = hashlib.sha256()

        async def verifying():
            message = await receive()
            if message["type"] != "http.request":
                return message
            sha.update(message.get("body", b""))
            if not message.get("more_body", False):
                expected = "sha256=" + hmac.new(self.secret, sha.hexdigest().encode(), hashlib.sha256).hexdigest()
                if not hmac.compare_digest(given.decode(), expected):
                    raise BadSignature()
            return message

        # Its own failed read is answered here when nothing was sent yet,
        # and re-raised otherwise; any other error passes through.
        started = False

        async def watching(message):
            nonlocal started
            if message["type"] == "http.response.start":
                started = True
            await send(message)

        try:
            await self.app(scope, verifying, watching)
        except BadSignature:
            if started:
                raise
            await self.refuse(scope, receive, send)

    async def refuse(self, scope, receive, send):
        await JSONResponse({"error": "bad signature"}, status_code=401)(scope, receive, send)


# A build event: read by the Request, through the verifying receive.
async def record_event(request):
    event = await request.json()
    request.state.events.append(event)
    return JSONResponse({"ok": 1, "build": event["build"]}, status_code=202)


# A build artifact: streamed to a .part file and given its name only once
# the whole body was read, which is when the signature has been checked.
async def store_artifact(request):
    path = os.path.join(request.state.artifacts, request.path_params["name"])
    size = 0
    try:
        with open(path + ".part", "wb") as part:
            async for chunk in request.stream():
                part.write(chunk)
                size += len(chunk)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(path + ".part")
        raise
    os.rename(path + ".part", path)
    with open(path, "rb") as stored:
        digest = hashlib.sha256(stored.read()).hexdigest()
    return JSONResponse({"bytes": size, "sha256": digest}, status_code=201)


async def list_events(request):
    return JSONResponse(request.state.events)


@contextlib.asynccontextmanager
async def lifespan(app):
    with tempfile.TemporaryDirectory() as artifacts:
        yield {"events": [], "artifacts": artifacts}


app = Starlette(
    routes=[
        Mount(
            "/signed",
            routes=[
                Route("/events", record_event, methods=["POST"]),
                Route("/artifacts/{name}", store_artifact, methods=["POST"]),
            ],
            middleware=[Middleware(VerifySignature, secret=SECRET)],
        ),
        Route("/events", list_events),
    ],
    lifespan=lifespan,
)
