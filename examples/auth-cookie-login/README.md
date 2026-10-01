# Explicit cookie login policy

This small application demonstrates a cookie login: the session holds who is
logged in, a two-line Authentication backend turns that into the request's
authentication context, and `PAGI::Auth`'s `requires` redirects anyone not
logged in to the login form, like Starlette's
`@requires('authenticated', redirect='login')`. Checking credentials and the
session lifecycle stay ordinary application code.

This example requires Perl 5.40 or newer. Run it from the distribution root
and give the runner the checkout's local library path:

```console
pagi-server --lib lib --app examples/auth-cookie-login/app.pl --port 5000
```

Open <http://localhost:5000/> and sign in with the demo-only credential:

- username: `demo`
- password: `secret`

An anonymous `GET /` redirects to `GET /login?next=%2F`:
`requires([], \&home, redirect => ['login'])` sends it to the route named
`login` (the arrayref holds `path_for` arguments) and records where it was
going. The form carries `next` in a hidden
field and submits to `POST /login`; valid credentials regenerate the
`hello_session` identifier, store the fixed demo identity, and redirect to
`next` -- but only when it is a local path, so the login page cannot be used to
redirect to another site. Invalid credentials leave
the session unauthenticated. `POST /logout` destroys the session and redirects
to the login form. Explicit methods prevent `GET` from submitting either
operation.

> **Demo boundary:** Run this example with one worker only because the default
> session store is process-local memory. Production deployment also requires
> TLS, `cookie_options =>
> { secure => 1 }` on the `PAGI::Middleware::Session::State::Cookie` the app
> passes as `state`, CSRF protection, login
> throttling, and a store every worker shares -- for example
> `PAGI::Middleware::Session::Store::Cookie` (distribution
> PAGI-Middleware-Session-Store-Cookie), or a server-side store if sessions
> must be revocable.

The HTML is fixed and never reflects submitted credentials. The literal
credentials exist only to make the local example reproducible.
