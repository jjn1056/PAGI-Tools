# PAGI::App::File Example

Static file server using PAGI::App::File.

## Setup

The example uses the caller-relative component constructor, so the app file
needs no manual `__FILE__` or platform-path handling:

```perl
PAGI::App::File->from_app_path('static')->to_app;
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
- Lexically rooted request-path validation
- Hidden files forbidden by default

## Security Boundary

`PAGI::App::File` validates request paths lexically. Its path helper performs no
I/O and does not resolve symlinks; the PAGI server opens the later `file` event.
Configured symlinks therefore extend the administrator's authority and may
lead outside the lexical root. Use a dedicated static tree that is not writable
by attackers, and enforce appropriate filesystem ownership and permissions.
Those deployment practices reduce pathname races and unintended exposure; the
component does not claim physical confinement.

Authorization is a separate application policy. If access depends on the
current user or resource record, perform that check explicitly or follow the
authenticated XSendfile recipe in
[`PAGI::Tools::Cookbook`](../../lib/PAGI/Tools/Cookbook.pod); do not infer
authorization from lexical path validity. Existing deployments should also
review the [rooted file-serving upgrade guide](../../UPGRADING.md#rooted-file-serving-security-contract).

## Test URLs

- http://localhost:5000/ - `index.html`
- http://localhost:5000/test.txt - Plain text
- http://localhost:5000/data.json - JSON
- http://localhost:5000/style.css - CSS
- http://localhost:5000/subdir/nested.txt - Nested file
