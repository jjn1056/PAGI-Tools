# The same notes application in Starlette, for comparison with app.pl.
# Starlette ships no method override, so the middleware app.pl takes from
# PAGI-Tools is written out here: a POST becomes PUT, PATCH or DELETE from
# the X-HTTP-Method-Override header or the _method query parameter, never
# from the body.
#
# Run:  pip install starlette uvicorn python-multipart
#       uvicorn app:app --port 8000

import html
from urllib.parse import parse_qs

from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.responses import HTMLResponse, PlainTextResponse, RedirectResponse
from starlette.routing import Route

NOTES = {}
NEXT_ID = [1]
ALLOWED = {"PUT", "PATCH", "DELETE"}


class MethodOverride:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http" and scope["method"] == "POST":
            wanted = dict(scope["headers"]).get(b"x-http-method-override", b"").decode()
            if not wanted:
                wanted = parse_qs(scope["query_string"].decode()).get("_method", [""])[0]
            if wanted.upper() in ALLOWED:
                scope = {**scope, "method": wanted.upper()}
        await self.app(scope, receive, send)


# Each note has a rename form (?_method=PUT) and a delete form
# (?_method=DELETE); the page ends with a plain POST form to add one.
async def list_notes(request):
    items = "".join(
        f'<li><form method="post" action="/notes/{id}?_method=PUT">'
        f'<input name="text" value="{html.escape(text)}"><button>Rename</button></form>'
        f'<form method="post" action="/notes/{id}?_method=DELETE"><button>Delete</button></form></li>'
        for id, text in sorted(NOTES.items())
    )
    return HTMLResponse(
        f"<ul>{items}</ul>"
        '<form method="post" action="/notes"><input name="text"><button>Add</button></form>'
    )


async def add_note(request):
    form = await request.form()
    NOTES[NEXT_ID[0]] = form.get("text", "")
    NEXT_ID[0] += 1
    return RedirectResponse("/notes", status_code=303)


# Reached as PUT: the form was POSTed to /notes/{id}?_method=PUT, and its
# body is read here, where the middleware left it.
async def rename_note(request):
    id = request.path_params["id"]
    if id not in NOTES:
        return PlainTextResponse("No such note.", status_code=404)
    form = await request.form()
    NOTES[id] = form.get("text", "")
    return RedirectResponse("/notes", status_code=303)


async def delete_note(request):
    if NOTES.pop(request.path_params["id"], None) is None:
        return PlainTextResponse("No such note.", status_code=404)
    return RedirectResponse("/notes", status_code=303)


app = Starlette(
    routes=[
        Route("/notes", list_notes, methods=["GET"]),
        Route("/notes", add_note, methods=["POST"]),
        Route("/notes/{id:int}", rename_note, methods=["PUT"]),
        Route("/notes/{id:int}", delete_note, methods=["DELETE"]),
    ],
    middleware=[Middleware(MethodOverride)],
)
