# framework-wrap-style

A small wrap-style framework, `Mini` (`lib/Mini.pm`), built on PAGI-Tools the
way Thunderhorse and Responder are built on their bases: handlers get a
request and a mutable response, and the framework's own router re-dispatches
one request through chained matches. `app.pl` is a notes app on it.

Requires Perl 5.40.

```
pagi-server --app examples/framework-wrap-style/app.pl --port 5000
curl -i localhost:5000/tenants/acme/notes/7
```

Each seam it exercises, and where PAGI-Tools documents it:

| Seam | In Mini | PAGI-Tools |
|---|---|---|
| A Request subclass with its own field | `Mini::Request` | `PAGI::Request`, SUBCLASSING |
| Re-dispatch through one scope | the router writes `path_params` per match; a bridge returns `'next'` | `PAGI::Request`, SUBCLASSING |
| Staging on the empty response | `Mini::Response` stages on `PAGI::Response->new` | `PAGI::Response`, `new` |
| One constructor call for every outcome | `finalize` | `PAGI::Response`, CONSTRUCTOR CONTRACT |
| A no-body status without Empty | `/seen` (204 with a cookie), `/old` (a bodyless 302) | `PAGI::Response`, `new` |
| A staged Content-Type keeps the class rule | `/csv` | `PAGI::Response`, Owned fields |
| An HTTP exception with headers | `/private` (401 with `WWW-Authenticate`) | `PAGI::Exception::HTTP`, `new` |
| A page turned into a response | unmatched paths | `PAGI::Pages`, APPLICATION INVOCATION |
