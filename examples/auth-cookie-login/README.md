# Explicit cookie login policy

This small application demonstrates a cookie login: the session holds who is
logged in, a two-line Authentication backend turns that into the request's
authentication context, and `PAGI::Auth`'s `requires` redirects anyone not
logged in to the login form, like Starlette's
`@requires('authenticated', redirect='login')`. Checking credentials and the
session lifecycle stay ordinary application code. The account pages live
under `mount('/account')`, and every link and redirect they emit comes from
`path_for`, so they stay correct wherever the account area is mounted.

This example requires Perl 5.40 or newer. Run it from the distribution root
and give the runner the checkout's local library path:

```console
pagi-server --lib lib --app examples/auth-cookie-login/app.pl --port 5000
```

Open <http://localhost:5000/account/> and sign in with the demo-only credential:

- username: `demo`
- password: `secret`

An anonymous `GET /account/` redirects to
`GET /account/login?next=%2Faccount%2F`:
`requires([], \&home, redirect => ['login'])` sends it to the route named
`login` (the arrayref holds `path_for` arguments) and records where it was
going. The form carries `next` in a hidden field and submits to
`POST /account/login`; valid credentials regenerate the `hello_session`
identifier, store the fixed demo identity, and redirect to `next` -- but only
when it is a local path, so the login page cannot be used to redirect to
another site; otherwise they go to the `home` route. Invalid credentials leave
the session unauthenticated. `POST /account/logout` destroys the session and
redirects to the login form. Explicit methods prevent `GET` from submitting
either operation.

## CSRF protection

Both forms are protected by `PAGI::Middleware::CSRF`. They post plain HTML, so
the token travels in a hidden `csrf_token` field, which the middleware does
not read: the app runs it with `refuse => 0`, and each POST handler checks
the parsed field with `csrf($request)->verify` and answers 403 when it does
not match. The token cookie is `HttpOnly`, so the page -- not JavaScript --
hands the token back. Set `CSRF_SECRET` outside a local demo.

## Serving it under a prefix

Behind a reverse proxy that publishes the app under `/app`, mount it there and
let the proxy forward the path unchanged:

```perl
my $served = compose(routes => [mount('/app', app => $app)]);
```

Every link, the login redirect's `next`, and the post-login redirect then
start with `/app/account/`, because they come from `path_for` and
`request_uri`. `t/integration-auth-cookie-login.t` runs the whole flow both
ways. See "Serving behind a proxy prefix" in `PAGI::Tools::Cookbook`.

> **Demo boundary:** Run this example with one worker only because the default
> session store is process-local memory. Production deployment also requires
> TLS, `cookie_options =>
> { secure => 1 }` on the `PAGI::Middleware::Session::State::Cookie` the app
> passes as `state`, a real `CSRF_SECRET`, login
> throttling, and a store every worker shares -- for example
> `PAGI::Middleware::Session::Store::Cookie` (distribution
> PAGI-Middleware-Session-Store-Cookie), or a server-side store if sessions
> must be revocable.

The HTML is fixed and never reflects submitted credentials. The literal
credentials exist only to make the local example reproducible.
