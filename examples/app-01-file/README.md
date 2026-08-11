# PAGI::App::File Example

Static file server using PAGI::App::File.

## Setup

The example uses the caller-relative component constructor, so the app file
needs no manual `__FILE__` or platform-path handling:

```perl
PAGI::App::File->app_path('static')->to_app;
```

`PAGI_ENV=development` prints one `PAGI::App::File: attempting ...` line to
STDOUT for each valid candidate. The line contains an absolute local path.
Unset or empty `PAGI_ENV`, plus `test`, `staging`, and `production`, are
silent. Any other nonempty value is a typo and fails loudly through
`PAGI::Utils::pagi_env` rather than being treated as a silent mode. Requests
rejected before the diagnostic boundary do not inspect `PAGI_ENV`.

## Run

```bash
pagi-server --app examples/app-01-file/app.pl --port 5000
```

## Features

- Static file serving from a root directory
- Index file resolution (`index.html`)
- MIME type detection
- ETag caching (304 Not Modified)
- Range requests for partial content
- Path traversal protection

## Test URLs

- http://localhost:5000/ - `index.html`
- http://localhost:5000/test.txt - Plain text
- http://localhost:5000/data.json - JSON
- http://localhost:5000/style.css - CSS
- http://localhost:5000/subdir/nested.txt - Nested file
