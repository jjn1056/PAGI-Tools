# Pages Response Factory

This runnable example puts `PAGI::Pages` behind one `PAGI::Compose` application
root. It demonstrates the Welcome page, fixed redirects, negotiated errors,
the difference between Route and Mount, both Response ownership models, and
lifespan startup and shutdown.

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
redirect endpoint. `mount('/terminal', app => ...)` transfers the entire
subtree to an opaque terminal application, so both `/terminal` and every
descendant such as `/terminal/anything` return the configured Gone page for
every HTTP method.

The `/context` handler receives `$c`. `PAGI::Pages->not_found($c)` returns an
ordinary unsent `PAGI::Response`; the handler adds `X-Demo` and returns it so
Router can own the send step:

```perl
route('/context' => sub {
    my ($c) = @_;
    my $response = PAGI::Pages->not_found($c, as => 'text');
    $response->header('X-Demo' => 'Context response value');
    return $response;
});
```

The `/raw` route is explicitly marked `raw`. Its native PAGI closure owns
`$scope`, `$receive`, and `$send`, so constructing the unsent Response and
sending it are separate operations:

```perl
route('/raw', raw => async sub {
    my ($scope, $receive, $send) = @_;
    my $response = PAGI::Pages->not_found($scope, as => 'text');
    $response->header('X-Demo' => 'raw response value');
    await Future->wrap($response->respond($send));
});
```

Compose owns the deployed protocol boundary around those routes, including
lifespan startup/shutdown and response/error safety. The enclosed Router owns
automatic negotiated 404/405 and HEAD body suppression. The final
`compose(...)` expression is returned as an inspectable object; a conforming
server compiles it once through `to_app`.
