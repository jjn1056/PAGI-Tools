# Modify a form POST in middleware

A middleware rewrites a form's body before the application reads it: the
`username` field is trimmed and upper-cased, and a `middleware_processed`
field is added. The route reads its form as usual and sees only the
rewritten one. `app.py` is the same application in Starlette; both were run
(`pagi-server` and `uvicorn`) with the same requests and answer them the
same way.

Requires Perl 5.40.

```
pagi-server --app examples/modify-form-post/app.pl --port 5000
curl localhost:5000/submit --data-urlencode 'username= john_doe ' -d role=Developer
```

## Reading the body in middleware

A request body arrives once. The middleware reads all of it, through a
`PAGI::Request` of its own, and from then on it owns the client's receive.
So it hands the application a receive of its own that delivers the
rewritten body, and a scope whose `Content-Length` matches it:

```perl
my $delivered = 0;
my $rewritten_receive = async sub {
    return await $receive->() if $delivered++;
    return { type => 'http.request', body => $body, more => 0 };
};
await $app->($rewritten_scope, $rewritten_receive, $send);
```

The rule is that whoever reads the body hands the application a receive
that delivers a body: here the rewritten one. After the body, the receive
carries on with the client's, which reports the disconnect when the client
goes. Handing the application the client's receive after reading it would
leave the application waiting for a body that never comes.

The middleware reads the whole body before the application runs, which is
right for a small form. To change a large body as it streams, change each
event inside the receive instead, as the `gzip` recipe in
`PAGI::Tools::Cookbook` ("Watching or changing the request body") does.

## Differences from the Starlette version

`app.py` is the Starlette version as written, with two fixes, marked in it:

- Its `mock_receive` returned the body on every call. It now delivers the
  body once, then carries on with the client's receive, as the Perl one
  does.
- `handle_submit` put the form's values into HTML unescaped; it now escapes
  them (`html.escape`), as the Perl one does.

Starlette changes `scope["headers"]` in place; the Perl version gives the
application a copy of the scope, as PAGI middleware does.
