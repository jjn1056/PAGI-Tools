from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.responses import HTMLResponse
from starlette.routing import Route
from starlette.requests import Request
import html
import urllib.parse


# 1. Custom ASGI Middleware to modify Form POST bodies
class ModifyFormPostMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        # Only intercept HTTP POST requests with form urlencoded data
        if scope["type"] == "http" and scope["method"] == "POST":
            headers = dict(scope.get("headers", []))
            content_type = headers.get(b"content-type", b"").decode("utf-8")

            if "application/x-www-form-urlencoded" in content_type:
                # Accumulate the complete body stream from the client
                body = b""
                more_body = True
                while more_body:
                    message = await receive()
                    body += message.get("body", b"")
                    more_body = message.get("more_body", False)

                # Parse the raw bytes into a dictionary of form fields
                form_data = urllib.parse.parse_qs(body.decode("utf-8"))

                # MODIFY THE BODY DATA HERE
                # Example: Force clean user inputs or append middleware tracking data
                if "username" in form_data:
                    form_data["username"] = [name.strip().upper() for name in form_data["username"]]

                form_data["middleware_processed"] = ["true"]

                # Re-serialize the modified form dictionary back into standard urlencoded bytes
                modified_body = urllib.parse.urlencode(form_data, doseq=True).encode("utf-8")

                # Re-calculate the Content-Length header to match the new body size
                new_headers = []
                for key, val in scope["headers"]:
                    if key.lower() == b"content-length":
                        new_headers.append((b"content-length", str(len(modified_body)).encode("utf-8")))
                    else:
                        new_headers.append((key, val))
                scope["headers"] = new_headers

                # Construct a mock 'receive' to stream our modified body down to Starlette.
                # It delivers the body once, then carries on with the client's receive,
                # which reports the disconnect (returning the body on every call would
                # hand an application waiting for http.disconnect the body again).
                delivered = False

                async def mock_receive():
                    nonlocal delivered
                    if delivered:
                        return await receive()
                    delivered = True
                    return {
                        "type": "http.request",
                        "body": modified_body,
                        "more_body": False
                    }

                # Pass the modified scope and mock receiver downstream
                await self.app(scope, mock_receive, send)
                return

        # Fallback for all other traffic (GET, JSON, WebSockets, etc.)
        await self.app(scope, receive, send)


# 2. Route Endpoints
async def show_form(request: Request):
    # Simple form targeting our POST route
    html_content = """
    <form action="/submit" method="post">
        <label>Username: <input type="text" name="username" value=" john_doe "></label><br><br>
        <label>Role: <input type="text" name="role" value="Developer"></label><br><br>
        <button type="submit">Submit Form</button>
    </form>
    """
    return HTMLResponse(html_content)


async def handle_submit(request: Request):
    # The endpoint parses form data natively. It will see the modified values!
    form = await request.form()

    response_data = {
        "received_username": form.get("username"),  # Should be 'JOHN_DOE' (stripped and uppercase)
        "received_role": form.get("role"),          # Should be untouched ('Developer')
        "injected_by_middleware": form.get("middleware_processed")  # Should be 'true'
    }
    # Escaped: the values are the client's, and this is HTML.
    return HTMLResponse(f"<h3>Endpoint Received:</h3><pre>{html.escape(str(response_data))}</pre>")


# 3. Application Setup
routes = [
    Route("/", show_form, methods=["GET"]),
    Route("/submit", handle_submit, methods=["POST"])
]

middleware = [
    Middleware(ModifyFormPostMiddleware)
]

app = Starlette(routes=routes, middleware=middleware)

# Run via terminal: uvicorn filename:app --reload
