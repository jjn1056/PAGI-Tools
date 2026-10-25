# Signed requests

A CI system posts build events and build artifacts, each signed with a
shared secret. A middleware checks every signature; the routes read their
bodies as usual, an event with `$request->json` and an artifact streamed to
disk with `body_stream`, and never mention signatures.

Requires Perl 5.40.

```
SIGNING_SECRET=s3cret pagi-server --app examples/signed-requests/app.pl --port 5000
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
    SignedRequests::BadSignature->throw(401, 'bad signature')
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
`_RequestBodyTooLarge`. A request
with no signature header at all is refused before any route runs.

## What the routes do about it

- `record_event` needs nothing: `$request->json` reads the whole body, and
  for a forged one it throws the 401 instead of returning.
- `store_artifact` streams to `build.tar.part` and renames it only after the
  whole body was read, which is when the signature has been checked. A
  forged artifact fails on its last chunk, after the rest was written, so
  the route deletes the `.part` file and rethrows. A real server delivers a
  large body in many chunks; `t/integration/example-signed-requests-chunked.t`
  sends a forged 2MB artifact that way and checks nothing is left.

## Notes

- The check runs as the body is read. A route that acts without reading the
  body gets only the "a signature header is present" check: under `/signed`
  a `GET` with a forged header reaches the router (a 405 here). Every
  `/signed` route reads its body.
- The signature is an HMAC of the body's SHA-256, as AWS signs a payload's
  hash, so the middleware hashes each chunk as it arrives and never holds
  the body in one string. GitHub's scheme, an HMAC over the body itself,
  needs an incremental HMAC (`Digest::HMAC`), which is not in core Perl.
- This middleware watches the body through the receive it hands the app;
  `Reading the request body` in `PAGI::Middleware` has the other shapes,
  reading the body ahead and handing on the same one (`record_receive`) or
  a different one.
