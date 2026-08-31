### Task 1: Make Method-Capability Diagnostics Name Their Source

**Files:**

- Modify: `lib/PAGI/Routing/Route.pm`
- Modify: `t/routing/01-constructors.t`
- Modify: `Changes`

**Interfaces:**

- Consumes: `PAGI::Routing::Route::_normalize_methods($value)` and the existing `allowed_methods` construction-time capability.
- Produces: `_normalize_methods($value, $origin)` where `$origin` is either `methods` or `route endpoint allowed_methods`; explicit-option diagnostics remain compatible, while capability diagnostics identify the endpoint contract.

- [ ] **Step 1: Add failing capability-diagnostic tests.**

Extend the existing `Local::MethodEndpoint` matrix in `t/routing/01-constructors.t`. Preserve all current construction-time rejection assertions and require capability-specific diagnostics for these results:

```perl
for my $case (
    [empty     => [],                 qr/route endpoint allowed_methods returned no methods/],
    [separator => ['GET POST'],       qr/route endpoint allowed_methods must return valid HTTP method strings/],
    [reference => [{}],               qr/route endpoint allowed_methods must return valid HTTP method strings/],
    [future    => [Future->done('GET')], qr/route endpoint allowed_methods must return valid HTTP method strings/],
    [wildcard  => ['*'],              qr/route endpoint allowed_methods must return valid HTTP method strings/],
    [mixed     => ['GET', '*'],       qr/route endpoint allowed_methods must return valid HTTP method strings/],
) {
    my ($label, $returned, $error) = @$case;
    my $endpoint = Local::MethodEndpoint->new(@$returned);
    like dies { route "/invalid-capability-$label" => $endpoint },
        $error,
        "$label allowed_methods failure names the endpoint capability";
}
```

Retain separate tests proving malformed explicit `methods` still report the explicit option contract rather than `allowed_methods`.

- [ ] **Step 2: Run the constructor test and confirm RED.**

Run:

```bash
prove -lv t/routing/01-constructors.t
```

Expected: only the new diagnostic assertions fail; the existing rejection behavior remains intact.

- [ ] **Step 3: Add an origin-aware normalization diagnostic.**

Change the two call sites in `Route->_build`:

```perl
$methods = _normalize_methods($opts->{methods}, 'methods');
```

and:

```perl
my @capability_methods = $endpoint->allowed_methods;
$methods = _normalize_methods(
    \@capability_methods,
    'route endpoint allowed_methods',
);
```

Update the helper so the existing explicit-option wording is retained, while the capability path uses these exact diagnostics:

```perl
sub _normalize_methods {
    my ($methods, $origin) = @_;
    $origin ||= 'methods';

    my $from_capability = $origin eq 'route endpoint allowed_methods';
    my $shape_error = $from_capability
        ? 'route endpoint allowed_methods must return valid HTTP method strings'
        : "methods must be a method string, arrayref, or '*'";

    return '*'
        if !$from_capability
            && defined($methods) && !ref($methods) && $methods eq '*';

    my @methods;
    if (!$from_capability && defined($methods) && !ref($methods)) {
        @methods = ($methods);
    }
    elsif (ref($methods) eq 'ARRAY') {
        @methods = @$methods;
    }
    else {
        croak $shape_error;
    }

    croak 'route endpoint allowed_methods returned no methods'
        if $from_capability && !@methods;
    croak $shape_error unless @methods;

    my %seen;
    my @normalized;
    for my $method (@methods) {
        croak $shape_error unless defined($method)
            && !ref($method)
            && $method ne '*'
            && $method =~ /\A[!#\$%&'\+\-.\^_`|~0-9A-Za-z]+\z/;
        $method = uc $method;
        next if $seen{$method}++;
        push @normalized, $method;
        if ($method eq 'GET' && !$seen{HEAD}) {
            $seen{HEAD} = 1;
            push @normalized, 'HEAD';
        }
    }
    return \@normalized;
}
```

Do not introduce another parser or capability wrapper. The implementation must still uppercase, deduplicate in first-seen order, and insert HEAD immediately after GET.

- [ ] **Step 4: Run focused method tests and confirm GREEN.**

Run:

```bash
prove -lv \
  t/routing/01-constructors.t \
  t/routing/05-http-dispatch.t \
  t/endpoint/03-http-to-app.t \
  t/endpoint/04-http-options.t \
  t/app-router/01-builder-core.t \
  t/endpoint/13-router-frontends.t
```

Expected: PASS. Confirm explicit `methods`, capability methods, GET+HEAD, OPTIONS, scalar `'*'`, Router-owned 405, and `Allow` behavior remain unchanged.

- [ ] **Step 5: Record the diagnostic correction and commit.**

Add one concise `0.002003 - UNRELEASED` Changes bullet stating that invalid `allowed_methods` results now identify the endpoint capability rather than blaming a nonexistent `methods` option.

Commit:

```bash
git add Changes lib/PAGI/Routing/Route.pm t/routing/01-constructors.t
git commit -m "fix: identify invalid route method capabilities"
```

---

