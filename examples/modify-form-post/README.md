# Modify a form POST in middleware

A middleware rewrites a form's body before the application reads it: the
`username` field is trimmed and upper-cased, and a `middleware_processed`
field is added. The route reads its form as usual and sees only the
rewritten one. `app.py` is the same application in Starlette; both were run
(`pagi-server` and `uvicorn`) with the requests below and gave the same
answers (one difference in the page's HTML escaping, below).

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
right for a small form; bound its size if it may not be small. To read it
only when the application asks, do the same inside the receive you hand
on, as the gzip recipe in `PAGI::Tools::Cookbook` ("Watching or changing
the request body") does; to change a body as it streams, change each event
there and hand it on.

## Differences from the Starlette version

`app.py` is the Starlette version as written, with two fixes, marked in it:

- Its `mock_receive` returned the body on every call. It now delivers the
  body once, then carries on with the client's receive, as the Perl one
  does.
- `handle_submit` put the form's values into HTML unescaped; it now escapes
  them (`html.escape`), as the Perl one does.

The page escapes with `HTML::Escape`, which also escapes `{` and `}` (as
`&#123;` and `&#125;`), so its HTML differs from `html.escape`'s there; a
browser shows the same text. The form is re-encoded with `URI`'s
`query_form`, as `app.py` uses `urlencode`, and the middleware's
`middleware_processed` replaces one the client sent, as `app.py`'s
assignment does.

Starlette changes `scope["headers"]` in place; the Perl version gives the
application a copy of the scope, as PAGI middleware does. Two smaller
differences: `parse_qs` drops fields with blank values, which the Perl
version keeps; and `app.py` replaces `Content-Length` only when the request
had one, where `app.pl` always sets it and drops a chunked request's
`Transfer-Encoding`.
