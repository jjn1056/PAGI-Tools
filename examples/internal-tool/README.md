# Internal Tool

A task board for a small team: the everyday HTML workflow every web
framework is judged on. Pages come from templates, the add form re-renders
with its errors and what was typed, a good submission redirects and the next
page shows a flash message, every form carries a CSRF token, and the
stylesheet comes from a static directory.

PAGI-Tools ships no template engine, flash or validation. This app shows
what each costs on top of it. The same application in Flask, which has all
three built in, is at the end of this README; it was driven with the same
requests and answers them the same way.

## Run

```bash
pagi-server --app examples/internal-tool/app.pl --port 5000
```

Then open http://localhost:5000/. Template Toolkit (`Template`) must be
installed; it is not a dependency of PAGI-Tools.

## What it shows

- **Templates.** `Template->new(INCLUDE_PATH => ...)` renders into a string
  and `response('HTML', $html)` sends it; the `page` helper adds the CSRF
  token, the flash and a `url` function (`path_for`) to every render. Ten
  lines, written once.
- **Redirect after POST.** `response('Redirect', path_for($request, 'index'),
  status => 303)`.
- **Flash.** Two lines on the session: `set(flash => ...)` in the POST
  handler, `get`-then-`delete` in `page`.
- **Validation errors.** Hand-written: a `validate` returning values and
  errors, and a 422 re-render of the same template.
- **CSRF on forms.** `middleware('CSRF', session => 1, form_field =>
  'csrf_token')` keeps the token in the session and refuses a cross-site
  POST. Each POST route is wrapped in `csrf_protect`, which reads the hidden
  `csrf_token` field from the handler's own Request and answers a missing or
  wrong token with a 403 before the handler runs. One token serves every form
  on the page. `create` then reads its fields with `form_params`, the same
  parse.
- **Static files.** `mount('/static', app =>
  PAGI::App::File->from_app_path('public'), name => 'static')`. The mount is
  named `static`, so the layout links the stylesheet with
  `url('static', { path = 'style.css' })`, which keeps a proxy prefix.
- **State at startup.** The board lives in lifespan state and is read with
  `app_state($request)`.

Measured with the gut-check line counter (code lines, imports in
parentheses): PAGI-Tools 74 (9), Flask 51 (2). The templates are 47 and 44
lines. The difference is the batteries: Flask's `render_template` and
`flash`/`get_flashed_messages` are the `page` and `flash` helpers here,
`url_for('static', ...)` is the template's `url('static', ...)`, and Flask's
module-level `BOARD` is
Compose's `lifespan` block. CSRF has the same shape in both: the Flask
version calls `check_csrf` in its three handlers, and PAGI-Tools wraps the
three routes in `csrf_protect`.

## Try

```bash
curl -c jar -b jar localhost:5000/                      # the board, with a csrf_token field
tok=...                                                  # copy it from the form
curl -c jar -b jar -X POST localhost:5000/tasks --data-urlencode 'title=' \
     --data-urlencode "csrf_token=$tok"                  # 422, re-rendered with errors
curl -c jar -b jar -X POST localhost:5000/tasks --data-urlencode 'title=Rotate the key' \
     --data-urlencode "csrf_token=$tok" -i               # 303 to /
curl -c jar -b jar localhost:5000/                      # the flash, then the task
curl -c jar -b jar -X POST localhost:5000/tasks/1/toggle --data-urlencode "csrf_token=$tok" -i
curl -i localhost:5000/static/style.css
```

## The Flask version

The same application, as measured and driven with the same requests.

### flask_app.py

```python
# The same task board in Flask, for comparison with app.pl. Flask has
# templates, flash and static files built in; CSRF is the Flask-WTF
# extension, done by hand here so the two apps need the same extras.
#
# Run:  pip install flask
#       flask --app flask_app run --port 8000

import hmac, os, re, secrets
from flask import Flask, abort, flash, redirect, render_template, request, session, url_for

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY", "dev")
BOARD = {"next": 1, "list": []}


def csrf_token():
    return session.setdefault("csrf_token", secrets.token_urlsafe(32))


app.jinja_env.globals["csrf_token"] = csrf_token


def check_csrf():
    if not hmac.compare_digest(request.form.get("csrf_token", ""), session.get("csrf_token", "-")):
        abort(403, "CSRF token validation failed")


def validate(form):
    errors = {}
    title = form.get("title", "").strip()
    if not title:
        errors["title"] = "A title is required."
    elif len(title) > 80:
        errors["title"] = "Keep the title under 80 characters."
    due = form.get("due", "")
    if due and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", due):
        errors["due"] = "Use YYYY-MM-DD."
    return {"title": title, "due": due}, errors


@app.get("/")
def index():
    return render_template("index.html", tasks=BOARD["list"], form={}, errors={})


@app.post("/tasks")
def create():
    check_csrf()
    values, errors = validate(request.form)
    if errors:
        return render_template("index.html", tasks=BOARD["list"], form=values, errors=errors), 422
    BOARD["list"].append({"id": BOARD["next"], **values, "done": False})
    BOARD["next"] += 1
    flash(f'Added "{values["title"]}".')
    return redirect(url_for("index"), 303)


@app.post("/tasks/<int:id>/toggle")
def toggle(id):
    check_csrf()
    task = next((t for t in BOARD["list"] if t["id"] == id), None) or abort(404)
    task["done"] = not task["done"]
    flash(("Done: " if task["done"] else "Reopened: ") + task["title"] + ".")
    return redirect(url_for("index"), 303)


@app.post("/tasks/<int:id>/delete")
def delete(id):
    check_csrf()
    before = len(BOARD["list"])
    BOARD["list"] = [t for t in BOARD["list"] if t["id"] != id]
    if len(BOARD["list"]) == before:
        abort(404)
    flash("Deleted.")
    return redirect(url_for("index"), 303)
```

### templates/index.html

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Task board</title>
  <link rel="stylesheet" href="{{ url_for('static', filename='style.css') }}">
</head>
<body>
<h1>Task board</h1>

{% for message in get_flashed_messages() %}<p class="flash">{{ message }}</p>{% endfor %}

<form method="post" action="{{ url_for('create') }}" class="add">
  <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
  <label>Title
    <input name="title" value="{{ form.title or '' }}" autofocus>
    {% if errors.title %}<span class="error">{{ errors.title }}</span>{% endif %}
  </label>
  <label>Due
    <input name="due" value="{{ form.due or '' }}" placeholder="YYYY-MM-DD">
    {% if errors.due %}<span class="error">{{ errors.due }}</span>{% endif %}
  </label>
  <button type="submit">Add task</button>
</form>

<ul class="tasks">
{% for task in tasks %}
  <li class="{{ 'done' if task.done else 'open' }}">
    <span class="title">{{ task.title }}</span>
    {% if task.due %}<span class="due">{{ task.due }}</span>{% endif %}
    <form method="post" action="{{ url_for('toggle', id=task.id) }}">
      <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
      <button type="submit">{{ 'Reopen' if task.done else 'Done' }}</button>
    </form>
    <form method="post" action="{{ url_for('delete', id=task.id) }}">
      <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
      <button type="submit">Delete</button>
    </form>
  </li>
{% endfor %}
</ul>
{% if not tasks %}<p class="empty">Nothing to do.</p>{% endif %}
</body>
</html>
```

### static/style.css

```css
body { font: 16px/1.4 system-ui, sans-serif; max-width: 40em; margin: 2em auto; padding: 0 1em; }
.flash { background: #e6f4ea; border-left: 4px solid #2e7d32; padding: .5em 1em; }
.error { color: #b00020; font-size: .9em; }
form.add label { display: block; margin: .5em 0; }
ul.tasks { list-style: none; padding: 0; }
ul.tasks li { display: flex; gap: .5em; align-items: center; padding: .4em 0; border-bottom: 1px solid #ddd; }
ul.tasks li.done .title { text-decoration: line-through; color: #777; }
ul.tasks .due { color: #555; font-size: .9em; }
ul.tasks form { display: inline; }
.empty { color: #777; }
```

## See also

- `PAGI::Session` and `PAGI::Middleware::Session`
- `PAGI::Middleware::CSRF` for the token and the origin check; `PAGI::CSRF`
  for the token the page renders and `csrf_protect`
- `PAGI::App::File`, `from_app_path`
- `examples/auth-cookie-login`, the same form idioms with a login
- `examples/contact-form`, form fields and file uploads without a session
