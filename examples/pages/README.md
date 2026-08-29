# Pages Response Factory

This runnable example puts `PAGI::Pages` behind one `PAGI::Compose` application
root. It demonstrates the Welcome page, fixed redirects, negotiated errors,
ordinary exported Request handlers, explicit native adaptation, the difference
between Route and Mount, both Response ownership models, and lifespan startup
and shutdown.

Run it from the PAGI-Tools checkout:

```bash
pagi-server --app examples/pages/app.pl --port 5000
```

Try each stock representation:

```bash
curl -i -H 'Accept: text/html' http://localhost:5000/
curl -i -H 'Accept: application/problem+json' http://localhost:5000/missing
curl -i -H 'Accept: text/plain' http://localhost:5000/terminal/anything
curl -i http://localhost:5000/old
```

`route('/old' => ...)` is an exact route, so `/old/child` does not reach its
redirect handler. `mount('/terminal', app => request_app(\&gone_page))`
explicitly adapts the ordinary Request handler and transfers the entire
subtree to an opaque terminal application, so both `/terminal` and every
descendant such as `/terminal/anything` return the configured Gone page for
every HTTP method.

Page functions are ordinary Request handlers and work directly in Route:

```perl
route('/' => \&welcome_page);
route('/missing' => \&not_found_page);
```

The `/request` handler receives `PAGI::Request`.
`not_found_page($request)` returns an ordinary unsent concrete Response; the
handler adds `X-Demo` and returns it so Router can own the send step:

```perl
route('/request' => sub {
    my ($request) = @_;
    my $response = not_found_page($request, as => 'text');
    $response->header('X-Demo' => 'Request response value');
    return $response;
});
```

The `/raw` route is explicitly marked `raw`. Its native PAGI closure owns
`$scope`, `$receive`, and `$send`, so constructing the unsent Response and
sending it are separate operations:

```perl
route('/raw', raw => async sub {
    my ($scope, $receive, $send) = @_;
    my $response = not_found_page($scope, as => 'text');
    $response->header('X-Demo' => 'raw response value');
    await Future->wrap($response->respond($scope, $receive, $send));
});
```

Page functions never arity-switch into native applications. Use
`request_app(\&handler)` for Mount, Compose `app`, or another native placement.
Only a real raw closure owns `($scope, $receive, $send)` and calls full-triplet
`respond` itself.

Compose owns the deployed protocol boundary around those routes, including
lifespan startup/shutdown and response/error safety. The enclosed Router owns
automatic negotiated 404/405 and HEAD body suppression. The final
`compose(...)` expression is returned as an inspectable object; a conforming
server compiles it once through `to_app`.
