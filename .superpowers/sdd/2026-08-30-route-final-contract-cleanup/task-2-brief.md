### Task 2: Collapse Route and Mount Constraints to a Stable Hashref Shape

**Files:**

- Modify: `lib/PAGI/Routing/Route.pm`
- Modify: `lib/PAGI/Routing/Mount.pm`
- Modify: `t/routing/01-constructors.t`
- Modify: `t/routing/02-patterns.t`
- Modify: `lib/PAGI/Routing/Route.pm` POD
- Modify: `lib/PAGI/Routing/Mount.pm` POD
- Modify: `Changes`

**Interfaces:**

- Consumes: optional constructor option `constraints => \%constraints` for Route and Mount.
- Produces: `Route->constraints` and `Mount->constraints` always return fresh hashrefs, with `{}` when no explicit constraint hash was declared. `Router->constraints` remains `undef` because constraints are inapplicable to Router.

- [ ] **Step 1: Add failing accessor-shape tests.**

In `t/routing/01-constructors.t`, add explicit assertions for omitted and explicitly empty constraints:

```perl
my $plain_route = route('/plain' => sub { });
is($plain_route->constraints, {},
    'Route exposes omitted explicit constraints as an empty hash');

my $empty_route = route('/empty' => sub { }, constraints => {});
is($empty_route->constraints, {},
    'Route exposes explicit empty constraints with the same shape');

my $plain_mount = mount('/plain-mount', routes => []);
is($plain_mount->constraints, {},
    'Mount exposes omitted explicit constraints as an empty hash');
```

Mutate each returned hash and assert a later accessor call still returns `{}`. Retain the existing `Router->constraints` `undef` assertion.

- [ ] **Step 2: Run constructor and pattern tests and confirm RED.**

Run:

```bash
prove -lv t/routing/01-constructors.t t/routing/02-patterns.t
```

Expected: the new omitted-constraint Route/Mount assertions fail because the current accessors return `undef`.

- [ ] **Step 3: Remove the construction-history flag.**

In both Route and Mount:

1. Normalize the option once:

   ```perl
   my $constraints = exists $opts->{constraints}
       ? $opts->{constraints}
       : {};
   ```

2. Pass `$constraints` to `PAGI::Routing::Pattern->new`.
3. Remove `_has_constraints` from the blessed object.
4. Make the public accessor delegate directly to the Pattern copy:

   ```perl
   sub constraints { $_[0]->{_pattern}->constraints }
   ```

Do not alter inline constraint/provider normalization, predicate order, matching, reverse rendering, or checker identity.

- [ ] **Step 4: Run focused constraints and routing tests and confirm GREEN.**

Run:

```bash
prove -lv \
  t/routing/01-constructors.t \
  t/routing/02-patterns.t \
  t/routing/03-reverse-inspection.t \
  t/routing/05-http-dispatch.t \
  t/routing/07-mounts.t \
  t/routing/13-url-helper.t
```

Expected: PASS. Confirm explicit constraint checker identity and defensive hash copying still pass.

- [ ] **Step 5: Update public POD and Changes.**

Document in Route and Mount:

```text
constraints returns a fresh hashref containing the explicitly declared
constraint map, or an empty hashref when none was declared. Inline path
constraints remain represented by the path pattern and are not reconstructed
as entries in this explicit map.
```

Add a concise `0.002003 - UNRELEASED` Changes bullet for the stable hashref accessor shape.

- [ ] **Step 6: Commit.**

```bash
git add Changes \
  lib/PAGI/Routing/Route.pm \
  lib/PAGI/Routing/Mount.pm \
  t/routing/01-constructors.t \
  t/routing/02-patterns.t
git commit -m "refactor: simplify route constraint inspection"
```

---
