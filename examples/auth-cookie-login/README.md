# Explicit cookie login policy

This small application demonstrates login redirects and session lifecycle as
application policy. It intentionally does not use `PAGI::Auth`: the Auth facade
does not perform interactive login or redirect policy.

This example requires Perl 5.40 or newer. Run it from the distribution root
and give the runner the checkout's local library path:

```console
pagi-server --lib lib --app examples/auth-cookie-login/app.pl --port 5000
```

Open <http://localhost:5000/> and sign in with the demo-only credential:

- username: `demo`
- password: `secret`

An anonymous `GET /` redirects to `GET /login`. The form submits to
`POST /login`; valid credentials regenerate the `hello_session` identifier,
store the fixed demo identity, and redirect home. Invalid credentials leave
the session unauthenticated. `POST /logout` destroys the session and redirects
to the login form. Explicit methods prevent `GET` from submitting either
operation.

> **Demo boundary:** Run this example with one worker only because the default
> session store is process-local memory. Production deployment also requires
> TLS, a secret loaded from protected configuration, `cookie_options =>
> { secure => 1 }` on the `PAGI::Middleware::Session::State::Cookie` the app
> passes as `state`, CSRF protection, login
> throttling, and a store every worker shares -- for example
> `PAGI::Middleware::Session::Store::Cookie` (distribution
> PAGI-Middleware-Session-Store-Cookie), or a server-side store if sessions
> must be revocable.

The HTML is fixed and never reflects submitted credentials. The literal secret
and credential exist only to make the local example reproducible.
