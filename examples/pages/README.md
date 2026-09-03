# Pages Application Values

This runnable example places source-free `PAGI::Pages` applications behind one
`PAGI::Compose` root. It demonstrates class, configured-object, and exported
factories; direct Route placement; Request-derived application returns; a
direct application Mount; explicit native Route delegation; negotiated
representations; and lifespan startup/shutdown.

Run it from the PAGI-Tools checkout:

```bash
pagi-server --app examples/pages/app.pl --port 5000
```

Try each representation and placement:

```bash
curl -i -H 'Accept: text/html' http://localhost:5000/
curl -i -H 'Accept: application/problem+json' http://localhost:5000/missing
curl -i http://localhost:5000/configured
curl -i -H 'Accept: text/plain' http://localhost:5000/terminal/anything
curl -i http://localhost:5000/raw
curl -i http://localhost:5000/old
```

## Factories and direct Routes

Every factory returns an HTTP application value without request input or I/O.
An exported factory application and a class factory application can therefore
sit directly in Route:

```perl
route('/' => welcome());
route('/missing' => PAGI::Pages->not_found);
```

Configured policies retain their exact object and decide representation when
the application is invoked:

```perl
my $pages = PAGI::Pages->new(as => 'auto', default => 'text');
route('/configured' => $pages->not_found(
    detail => 'Missing under configured Pages policy',
));
```

The `/request` handler receives one `PAGI::Request` and returns an application
whose detail is derived from that request. Router invokes the returned value:

```perl
route('/request' => sub {
    my ($request) = @_;
    return not_found(
        as      => 'text',
        detail  => 'No page at ' . $request->path,
        headers => ['X-Demo' => 'Request application value'],
    );
});
```

The fixed redirect is another direct application Route. Because
`route('/old' => ...)` is exact, `/old/child` does not reach it.

## Native placements

A Mount `app` is a native application position. The static Gone application
can therefore own the `/terminal` subtree directly:

```perl
mount('/terminal', app => gone(
    detail => 'This mounted subtree is gone',
));
```

The `/raw` leaf deliberately owns all three PAGI channels. Native CODE at a
Route is marked with `as_app_object`, and raw triplet delegation to the Pages value is
performed by `invoke_app`:

```perl
route('/raw' => as_app_object(async sub {
    my ($scope, $receive, $send) = @_;
    await invoke_app(
        not_found(as => 'text'),
        $scope, $receive, $send,
    );
}));
```

`invoke_app` belongs at that existing native boundary. Direct application
Routes and one-Request handlers returning applications do not need it.

## Root and lifespan behavior

The final `compose(routes => [...], lifespan => { ... })` expression is an
inspectable root application. Compose constructs and owns the root Router,
startup/shutdown, error handling, and response completion; that root owns
negotiated 404/405 and automatic HEAD behavior.

A Pages application can also be the root directly, for example
`PAGI::Pages->welcome`. Pages is intentionally HTTP-only: a server using
automatic lifespan mode treats its lifespan exception as a clean decline,
while strict `lifespan_mode => 'on'` rejects that root. Use Compose when the
application must own lifecycle hooks, as this executable example does.
