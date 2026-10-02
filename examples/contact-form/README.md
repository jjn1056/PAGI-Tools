# Contact Form Example

Demonstrates PAGI::Request form handling and file uploads.

## Run

```bash
pagi-server --app examples/contact-form/app.pl --port 5000
```

Visit http://localhost:5000/

## Features

- Form parsing with validation
- File upload handling with type/size validation
- MIME type whitelist (PDF, images, text)
- JSON API responses
- Static file serving from `public/`

The whole application is one `compose`:

```perl
compose(
    routes => [
        route('/submit' => \&submit, methods => ['POST']),   # one PAGI::Request in, a JSON Response out
        route('/*path' => PAGI::App::File->from_app_path('public')),
    ],
    lifespan => { startup => async sub { mkdir $UPLOAD_DIR ... }, ... },
);
```

`submit` validates the fields and the attachment and returns
`response('JSON', ...)`, with status 400 and every error named when anything is
wrong. An attachment over the 5MB limit never reaches those checks:
`form_params` refuses it with a `PAGI::Request::BodyError`, which the
application answers as 413 (Content Too Large), a problem document for API
clients. Only `public` uses the application-relative file constructor; writable
uploads keep an explicit path beside `app.pl`, created by the startup hook.

## Upload Limits

Pass per-request limits to `form_params` (the call that triggers multipart
parsing):

```perl
my $form = await $req->form_params(max_file_size => 5 * 1024 * 1024);
```

To change a default process-wide, `local`-ize the package variable in
`PAGI::Request::MultiPartHandler` (e.g. `$MAX_FILE_SIZE`).

## API

- `POST /submit` - Submit form with optional attachment
- `GET /*` - Static files from `public/`
