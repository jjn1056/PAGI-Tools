# Signed requests

A CI system posts build events and build artifacts, each signed with a
shared secret. A middleware checks every signature; the routes read their
bodies as usual, an event with `$request->json` and an artifact streamed to
disk with `body_stream`, and never mention signatures.

Requires Perl 5.40. `app.py` is the same application in Starlette; both were
run (`pagi-server` and `uvicorn`) with the same requests and gave the same
answers but one (see "The Starlette version" below).

```
SIGNING_SECRET=s3cret pagi-server --app examples/signed-requests/app.pl --port 5000
SIGNING_SECRET=s3cret uvicorn app:app --port 8000      # from this directory
```

The comment at the top of `app.pl` has `curl` commands that sign a JSON
event and a 5MB artifact, and one that is refused.

## A middleware that checks the body without reading it

A request body can be received only once, and it is the route's. So the
middleware never reads it: it hands the route a receive of its own that
passes each chunk through as the route reads it, hashing it on the way, and
fails the read of the last chunk when the signature does not cover the
body:

```perl
my $verifying = async sub {
    my $event = await $receive->();
    return $event unless $event->{type} eq 'http.request';
    $sha->add($event->{body} // '');
    SignedRequests::BadSignature->throw
        if !$event->{more}
        && !secure_compare($given, 'sha256=' . hmac_sha256_hex($sha->hexdigest, $secret));
    return $event;
};
await $app->($scope, $verifying, $send);
```

This is the shape of Starlette's `RequestBodyLimitMiddleware`, which counts
the bytes in the receive it hands the app and fails the read past its limit,
and of the body-changing middleware Starlette's documentation points to
(msgpack-asgi). As Starlette's does, the middleware answers the failure
itself when nothing has been sent yet, and rethrows it otherwise; it
throws a class of its own, `SignedRequests::BadSignature`, so a route's
own 401 passes through untouched, as Starlette's catches only its own
`_RequestBodyTooLarge`. That class is deliberately not an HTTP error: the
failure is raised inside the route's read, and an HTTP error a route raises
is answered at the route (by the innermost ErrorHandler, or Starlette's
route-level exception handlers) before the middleware could answer it. A
request with no signature header at all is refused before any route runs.

## What the routes do about it

- `record_event` needs nothing: `$request->json` reads the whole body, and
  for a forged one it throws the 401 instead of returning.
- `store_artifact` streams to `build.tar.part` and renames it only after the
  whole body was read, which is when the signature has been checked. A
  forged artifact fails on its last chunk, after the rest was written, so
  the route deletes the `.part` file and rethrows. A real server delivers a
  large body in many chunks; `t/integration/example-signed-requests-chunked.t`
  sends a forged 2MB artifact that way and checks nothing is left.

- The check runs as the body is read. A route that acts without reading the
  body gets only the "a signature header is present" check: under `/signed`
  a `GET` with a forged header reaches the router (a 405 here). Every
  `/signed` route reads its body.
- The signature is an HMAC of the body's SHA-256, as AWS signs a payload's
  hash, so the middleware hashes each chunk as it arrives and never holds
  the body in one string. GitHub's scheme, an HMAC over the body itself,
  needs an incremental HMAC (`Digest::HMAC`), which is not in core Perl.
## The Starlette version

`app.py` is the same application: a pure ASGI middleware hands the routes a
receive that hashes each chunk, `record_event` reads `await request.json()`,
and `store_artifact` streams `request.stream()` to a `.part` file. Run on
PAGI-Server and on uvicorn 0.54.0 / Starlette 1.10.0, the same requests gave
the same statuses and bodies: a signed event 202, an unsigned or forged one
401 `{"error":"bad signature"}`, a signed 5MB artifact 201 with the same
SHA-256, a forged one 401, a `GET` with a forged header 405, and the event
list. One answer differs: a signed body that is not JSON is a 400 ("The
request body is not valid JSON.") from PAGI, where `request.json()` raises a
`PAGI::Exception::RequestBody`, and a 500 from Starlette, whose
`request.json()` raises a plain `JSONDecodeError` (uvicorn logs the
traceback).

## Notes

- This middleware watches the body through the receive it hands the app;
  `Reading the request body` in `PAGI::Middleware` has the other shapes,
  reading the body ahead and handing on the same one (`record_receive`) or
  a different one.
