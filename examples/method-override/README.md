# Method override

Notes renamed and deleted from plain HTML forms. A form can only `GET` or
`POST`, so each one names the method it means in its action URL, and
`middleware('MethodOverride')` turns the `POST` into that method before
routing:

```html
<form method="post" action="/notes/1?_method=PUT">
  <input name="text" value="milk"><button>Rename</button>
</form>
<form method="post" action="/notes/1?_method=DELETE"><button>Delete</button></form>
```

`app.py` is the same application in Starlette; both were run (`pagi-server`
and `uvicorn`) with the requests below and gave the same statuses.

Requires Perl 5.40.

```
pagi-server --app examples/method-override/app.pl --port 5000
uvicorn app:app --port 8000      # from this directory
```

Then open http://localhost:5000/notes.

## The override reads the header and the query, never the body

MethodOverride takes the method from the `X-HTTP-Method-Override` header (for
an API client) or the `_method` query parameter (for a form), and only for a
`POST`; only `PUT`, `PATCH` and `DELETE` are allowed by default. It never
reads the body: the body is the route's, and it reaches the route untouched.
So the rename route, reached as `PUT`, reads its form as usual:

```perl
async sub rename_note ($request) {
    ...
    $NOTES{$id} = (await $request->form_params)->get('text') // '';
```

A `_method` field in the form body is therefore not an override: the request
stays a `POST`, and `/notes/1` has no `POST` route, so it is a 405. This is
what Plack::Middleware::MethodOverride does, and why: to read a body field
the middleware would have to read the body before the route, and hand the
route a receive that delivers it again.

## Try

```bash
curl -i localhost:5000/notes -d text=milk                          # 303: note 1
curl -i 'localhost:5000/notes/1?_method=PUT' -d text=oat+milk      # 303: renamed
curl -i -X POST localhost:5000/notes/1 -H 'X-HTTP-Method-Override: DELETE'   # 303: deleted
curl -i localhost:5000/notes/1 -d _method=DELETE                   # 405: a body field is not an override
curl -i 'localhost:5000/notes/1?_method=TRACE'                     # 405: not an allowed override
```

## The Starlette version

Starlette ships no method override, so `app.py` writes the one `app.pl`
takes from PAGI-Tools as a pure ASGI middleware: header first, then the
query, never the body, `POST` only. Run on PAGI-Server and on uvicorn
0.54.0 / Starlette 1.10.0, the requests above gave the same statuses: 303
for the add, the rename and the header delete, 404 for deleting it again,
405 for the body field and for `TRACE`. Three differences:

- A 405's `Allow`: PAGI's router sends the method union of every route on
  the path, `PUT, DELETE`; Starlette's sends the first partly matching
  route's, `PUT`.
- A 303: PAGI's `Redirect` response carries a short HTML body linking the
  new location; Starlette's `RedirectResponse` sends none.
- HTML escaping: `&#60;` from the Perl version, `&lt;` from Python's
  `html.escape`; the same characters.

## See also

- `PAGI::Middleware::MethodOverride`: `param`, `header` and
  `allowed_methods`
- `examples/modify-form-post`, a middleware that does read a form body --
  and hands the route a receive that delivers the rewritten one
