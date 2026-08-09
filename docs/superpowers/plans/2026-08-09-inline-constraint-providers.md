# Inline Constraint Providers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended for this session) or
> `superpowers:executing-plans` to implement this plan task by task. Use
> `superpowers:test-driven-development` for every behavior change and
> `superpowers:verification-before-completion` before claiming completion.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `/{id:&Provider}` to `PAGI::Routing` as a construction-time,
package-function constraint provider; normalize all existing constraint shapes
to one executable predicate-record form; preserve those exact predicates across
composed reverse routing; give HTTP, WebSocket, SSE, and mount paths one
constraint grammar; and modernize the large application example to demonstrate
the feature with Perl 5.40 signatures and `Types::Standard::Int`.

**Architecture:** `PAGI::Routing::Pattern` remains the only path compiler. It
captures a declaration package, recognizes the reserved unescaped-leading-`&`
source, resolves an exact existing symbol-table CODE slot, invokes the provider
once per occurrence, and normalizes regexes, coderefs, and check objects to
private `{ check => CODE, explain => CODE? }` records. Route and Mount public
factories carry their direct caller into Pattern construction. `Resolver`
composes defensive copies of those already-normalized records rather than
reparsing constraint syntax or reapplying the public `constraints` hash.
Matching and reverse rendering execute only `record->{check}` and retain the
original scalar value.

**Tech Stack:** Perl 5.18-compatible distribution source, Perl 5.40+ example
source, hand-written blessed hashes, `Future`, `Future::AsyncAwait`,
`Test2::V0`, `PAGI::Test::Client`, POD, and Type::Tiny as a test-only/example
dependency. No new runtime dependency.

## Global Constraints

- The approved contract is
  `docs/superpowers/specs/2026-08-09-inline-constraint-providers-design.md`.
  If implementation evidence conflicts with it, record a deviation and obtain
  the user's decision before dependent work continues.
- The declarative routing API is unreleased. Do not add compatibility aliases,
  fallback-to-regex behavior for malformed provider intent, warnings, or a
  deprecation cycle. Update tests, examples, and documentation directly.
- Work only in `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools`.
- Preserve the unrelated untracked files `.cpan-testers-fix-report.md`,
  `.csrf-helper-brief.md`, and `.csrf-helper-report.md`. Never stage them.
- Keep every file under `lib/` and every ordinary test parseable on Perl 5.18.
  Signatures belong only under `examples/15-large-application`; its integration
  test must skip before loading that code on Perl older than 5.40.
- Do not add Type::Tiny to runtime prerequisites. Add `Type-Tiny` only inside
  the `cpanfile` test phase because the shipped example integration test uses
  `Types::Standard`.
- Do not add `FIND_ROUTER_CONSTRAINT`, `Type::Registry`, a registry object,
  builtin converters, module autoloading, method lookup, inheritance lookup,
  `AUTOLOAD`, coercion, asynchronous providers, or provider arguments.
- Reserve every inline constraint source whose first unescaped character is
  `&`. A malformed provider spelling croaks and points to `[&]`; it never falls
  back to regex compilation.
- Provider lookup is an exact CODE-slot lookup in an already-existing symbol
  table. Probing must not create a package stash or terminal glob.
- Invoke each provider occurrence exactly once per declared source Pattern
  construction. Never invoke a provider while matching, rendering, building a
  Router, composing an effective Pattern, compiling an app, or placing the same
  Router more than once.
- Normalize every inline regex, inline provider result, and explicit constraint
  to `{ check => CODE, explain => CODE? }` during source Pattern construction.
  Request matching and reverse rendering must not branch on the original shape.
- Constraints remain synchronous, unary, non-coercing validators. The handler
  and URL renderer keep the original decoded or caller-supplied scalar.
- Public `constraints` accessors continue to expose defensive copies of only
  the explicit `constraints => {...}` declaration. Predicate records and the
  pre-normalized constructor channel remain private.
- Keep routing descriptions immutable. Private predicate-record access returns
  fresh container/array/record hashes while preserving contained CODE identity.
- Apply the shared path grammar and explicit `constraints` option to normal and
  raw HTTP, WebSocket, SSE, inline mounts, Router mounts, and opaque mounts.
  Only HTTP routes accept `methods`.
- Do not change `PAGI::App::Router`; in that API `{id:&Int}` remains ordinary
  inline regex text. Feature parity is a separate future plan.
- Do not redesign 404, 405, no-match bubbling, Context URL arguments, Router
  namespaces, route middleware, HEAD handling, or the large example's
  class-method composition.
- Put short public API POD beside the code task that changes the API. The final
  documentation task reconciles the longer `PAGI::Routing`, Tutorial, Cookbook,
  example README, and Changes narratives.
- Use TDD: add the smallest focused failing assertion, run it and record the
  expected failure, implement the behavior, then rerun the focused file and the
  task's named regression gate.
- Capture intended errors with `dies` and assert stable semantic fragments, not
  file/line suffixes. Test output must remain clean.
- Stage only files named by the current task. Never use `git add .` or
  `git add -A`. Because `docs/superpowers` may be ignored, use `git add -f` only
  for the exact approved spec/plan path when needed.
- Every implementation task ends with one focused commit and review gate. The
  coordinator independently verifies the diff, test output, SHA, and ledger
  row before starting the next task.
- Run the repository-wide suite exactly once, at the final reviewed HEAD. Do
  not run `dzil test` afterward because that would run it again. Focused test
  files may be rerun as required by TDD and regression isolation.
- Run Perl commands through the project Perl:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/02-patterns.t'
  ```

## Execution Tracking and Deviation Control

Before Task 1, run the subagent-driven-development workspace helper even if
the coordinator executes the work inline:

```bash
/Users/jnapiorkowski/.codex/plugins/cache/openai-curated-remote/superpowers/6.2.0/skills/subagent-driven-development/scripts/sdd-workspace docs/superpowers/plans/2026-08-09-inline-constraint-providers.md
```

The command must print a directory ending in
`.superpowers/sdd/2026-08-09-inline-constraint-providers`. Create its
`progress.md` with this exact first line and tables:

```markdown
# SDD ledger — plan: docs/superpowers/plans/2026-08-09-inline-constraint-providers.md

| Task | Status | Commit range | Focused verification | Full-suite verification | Review |
|---|---|---|---|---|---|
| 1 | pending | — | — | deferred to final gate | — |
| 2 | pending | — | — | deferred to final gate | — |
| 3 | pending | — | — | deferred to final gate | — |
| 4 | pending | — | — | deferred to final gate | — |
| 5 | pending | — | — | deferred to final gate | — |
| 6 | pending | — | — | deferred to final gate | — |
| 7 | pending | — | — | final gate | — |

## Deviations

| ID | Status | Conflicting plan text | Evidence and rationale | Affected tasks | User decision |
|---|---|---|---|---|---|
```

Record the starting HEAD and `git status --short` before Task 1. The coordinator
owns the ledger. Update a task's row in the same working step as its commit and
record exact commands, exit status, real test-file/assertion counts, elapsed
time, commit SHA, and review evidence—never estimates or a worker's unsupported
summary.

A discovered contract conflict gets the next stable ID (`D-001`, `D-002`, and
so on), status `awaiting decision`, the conflicting plan/spec text, concrete
evidence, and every blocked dependent task. Record the user's explicit
approval, rejection, or replacement before continuing. An ordinary defect
whose fix preserves the approved contract is not a deviation.

## File and Responsibility Map

- `lib/PAGI/Routing/Pattern.pm`: inline grammar, provider resolution/execution,
  normalization, immutable predicate records, matching, and reverse rendering.
- `lib/PAGI/Routing.pm`: public factory caller capture and high-level provider
  documentation.
- `lib/PAGI/Routing/Route.pm`: direct-constructor caller capture, shared
  declaration-package seam, and explicit constraints for every leaf protocol.
- `lib/PAGI/Routing/Mount.pm`: direct-constructor caller capture and Pattern
  declaration-package propagation for every mount form.
- `lib/PAGI/Routing/Resolver.pm`: ancestry predicate-record composition and
  effective reverse Pattern construction without reparsing constraints.
- `t/routing/01-constructors.t`: constructor options, direct-caller ownership,
  re-export/wrapper/role semantics, and descriptor immutability.
- `t/routing/02-patterns.t`: normalization, provider grammar, exact lookup,
  execution timing, diagnostics, literal `&`, and private composition channel.
- `t/routing/03-reverse-inspection.t`: provider-aware composed `path_for`,
  provider identity/call counts, repeat placement, and reverse validation.
- `t/routing/05-http-dispatch.t`: normal/raw HTTP provider-backed matching.
- `t/routing/07-mounts.t`: inline, Router, and opaque mount provider-backed
  selection.
- `t/routing/08-protocols.t`: normal/raw WebSocket and SSE provider/explicit
  constraint parity.
- `t/routing/09-metadata-isolation.t`: concurrent provider-backed dispatch does
  not introduce request-local state sharing.
- `t/context/12-routing-reverse.t`: request-aware `path_for`/`url_for` enforce
  composed normalized constraints with inherited captures.
- `cpanfile`: Type-Tiny test prerequisite only.
- `examples/15-large-application`: Perl 5.40/signature modernization and
  `&Int` demonstration.
- `t/integration-large-application.t`: old-Perl load guard, Type::Tiny route
  semantics, followed links, and lifespan integration.
- `lib/PAGI/Tools/Tutorial.pod`, `lib/PAGI/Tools/Cookbook.pod`,
  `examples/15-large-application/README.md`, and `Changes`: public guidance,
  example requirements, API contrast, and release note.

---

### Task 1: Normalize Every Constraint to One Predicate Record

**Files:**

- Modify: `lib/PAGI/Routing/Pattern.pm`
- Modify: `t/routing/02-patterns.t`

**Interfaces:**

- Every compiled constraint is a private record whose `check` value is a CODE
  reference and whose optional `explain` value is a CODE reference.
- Regexp normalization closes over `qr/\A(?:$regexp)\z/`.
- A predicate coderef is retained as the `check` coderef itself.
- A blessed check object becomes a closure calling `check`; its optional
  `get_message` becomes an `explain` closure.
- `_predicate_records` returns a fresh hash, arrays, and record hashes but the
  same contained CODE references.
- The private `_predicate_records => {...}` constructor channel accepts one
  record array for every declared parameter, rejects unknown/missing names and
  malformed records, and cannot be combined with a nonempty public
  `constraints` hash.
- Public `constraints` remains unchanged and preserves declared value identity.

- [ ] **Step 1: Add failing normalization and private-channel tests.** Extend
  the existing constraint subtest with assertions that regex, predicate, and
  check-object records all expose CODE-valued `check`; only the check object
  with `get_message` has `explain`; returned containers are defensive; and
  mutating a returned record does not affect matching/rendering. Use
  `Scalar::Util::refaddr` to prove predicate CODE identity is retained.

  Add a private-channel fixture like:

  ```perl
  my $check = sub { return $_[0] eq 'kept' };
  my $composed = PAGI::Routing::Pattern->new(
      path               => '/items/{id}',
      mode               => 'route',
      constraints        => {},
      _predicate_records => {
          id => [{ check => $check }],
      },
  );

  is($composed->match_route('/items/kept'), { id => 'kept' });
  like(
      dies { $composed->render({ id => 'lost' }, '/show') },
      qr/path parameter 'id' failed constraint/,
  );
  ```

  Cover malformed top-level/array/record shapes, a non-CODE `check`, a
  non-CODE `explain`, an unknown parameter, an omitted declared parameter, and
  nonempty `constraints` plus `_predicate_records`.

- [ ] **Step 2: Run the red gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/02-patterns.t'
  ```

  Expected before implementation: the constructor rejects
  `_predicate_records` as unknown and `_predicate_records` is missing.

- [ ] **Step 3: Replace shape-specific checker execution with normalization.**
  Rename token `checkers` storage to `predicates`. Make the normalizer return:

  ```perl
  # Regexp
  my $anchored = qr/\A(?:$value)\z/;
  return { check => sub { return $_[0] =~ $anchored ? 1 : 0 } };

  # CODE
  return { check => $value };

  # check object
  my $record = { check => sub { return $value->check($_[0]) } };
  $record->{explain} = sub { return $value->get_message($_[0]) }
      if $value->can('get_message');
  return $record;
  ```

  This use of `can` is only for a supplied constraint object's public contract;
  it is not provider-name resolution. Keep the existing generic invalid-shape
  diagnostic.

- [ ] **Step 4: Make matching and rendering shape-blind.** Replace
  `_checkers_accept` with one loop that always calls
  `$record->{check}->($value)`, applies the existing Future-result guard, and
  uses `explain` only after a false reverse-render result. A false match remains
  a non-match; no accepted value is replaced.

- [ ] **Step 5: Implement the private record channel.** Validate and defensively
  copy its structure, attach its records after normal tokenization, and persist
  a per-parameter record map built from the final tokens. Include empty arrays
  for unconstrained parameters so composition can require an exact key set.
  When the private channel is present, tokenize inline constraint text but do
  not compile it; the channel is the sole constraint source for that effective
  Pattern.

- [ ] **Step 6: Run focused regressions.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/02-patterns.t t/routing/03-reverse-inspection.t t/context/12-routing-reverse.t'
  ```

  Verify the existing match/render counts, ordering, Future rejection,
  check-object message, inline-regex reverse validation, and defensive public
  `constraints` assertions remain green.

- [ ] **Step 7: Commit and review.** Stage only Pattern and its focused test:

  ```bash
  git add lib/PAGI/Routing/Pattern.pm t/routing/02-patterns.t
  git commit -m "Routing: normalize path constraint predicates"
  ```

  Review for behavioral equivalence outside the new private channel. Record the
  SHA, exact test evidence, and review result in Task 1's ledger row.

---

### Task 2: Parse, Resolve, and Execute Inline Providers in Pattern

**Files:**

- Modify: `lib/PAGI/Routing/Pattern.pm`
- Modify: `t/routing/02-patterns.t`

**Interfaces:**

- `declaration_package` is an optional Pattern construction value; absent means
  the direct caller of `Pattern->new`.
- After the existing inline scanner extracts a source, a first character `&`
  reserves provider intent. The complete ASCII grammar is
  `&(?:Package::)*CapitalizedFunction`.
- `[&]Int`, `[&][A-Z]+`, and a source retaining `\&Int` remain regexes.
- Exact resolution traverses existing stashes from `%main::`, checks the
  terminal glob's CODE slot, and never calls `can` or creates a stash/glob.
- Provider call errors, Future results, and invalid result shapes fail Pattern
  construction with provider/parameter/package context.

- [ ] **Step 1: Add package-local provider fixtures.** In
  `t/routing/02-patterns.t`, define test packages for:

  - a regex-returning `Digits` provider;
  - a coderef-returning `Even` provider;
  - a check-object-returning `Typed` provider with `get_message`;
  - one provider used twice in one path with an invocation counter and `@_`
    capture;
  - a throwing provider;
  - a Future-returning provider;
  - a package that exists but lacks the requested CODE slot;
  - a parent package with an inherited-looking method and a child `@ISA`;
  - an `AUTOLOAD` package; and
  - a package variable/non-CODE glob with a capitalized name.

- [ ] **Step 2: Add failing provider behavior tests.** Construct Patterns with
  an explicit declaration package and cover all three returned shapes during
  both `match_route` and `render`. Assert the provider runs at construction,
  receives no args, runs once per occurrence (twice for two references in one
  path), and does not run again during match or render. Combine `&Digits` with
  an explicit predicate and assert inline-first ordering.

  Include one qualified provider:

  ```perl
  PAGI::Routing::Pattern->new(
      path => '/items/{id:&Local::ConstraintProviders::Digits}',
      mode => 'route', constraints => {},
      declaration_package => 'Local::UnrelatedDeclaration',
  );
  ```

- [ ] **Step 3: Add failing grammar and literal-ampersand tests.** Table-drive
  lowercase, trailing-space, malformed qualification, `&[A-Z]+`, `&Foo|Bar`,
  `&Foo.*`, `&Foo::lower`, and a Unicode lookalike. Each must croak naming the
  source/parameter, the capitalized-provider rule, and `[&]`. Prove these remain
  regexes:

  ```perl
  '/{value:[&]Int}'
  '/{value:[&][A-Z]+}'
  '/{value:\&Int}'       # single-quoted Perl string
  ```

  Add a double-quoted `"/{value:\&Int}"` case and assert it enters provider
  parsing because Perl removes the backslash before Pattern sees the string.

- [ ] **Step 4: Add failing exact-lookup and diagnostic tests.** Cover:

  - missing unqualified CODE in the declaration package;
  - missing qualified package stash, with the load-module guidance;
  - existing qualified package but missing terminal CODE;
  - inherited method and `AUTOLOAD` not resolving;
  - an already-unloaded-looking package not being loaded automatically;
  - missing-stash probing leaving its parent stash entry absent;
  - missing-CODE probing leaving its terminal glob absent;
  - provider exception detail retained after the contextual prefix;
  - Future result using the distinct `returned a Future` error; and
  - scalar, array/hash, unblessed object, and invalid blessed results using the
    provider-specific accepted-shapes error; and
  - undefined, reference-valued, empty-component, and otherwise malformed
    explicit `declaration_package` values failing construction.

- [ ] **Step 5: Run the red gate.** Run only Pattern tests and record provider
  sources compiling as literal regexes or failing for the wrong reason:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/02-patterns.t'
  ```

- [ ] **Step 6: Implement provider recognition after token extraction.** Keep
  `_scan_inline_parameter` unchanged. Dispatch its extracted source through a
  new helper: first-character `&` goes only to provider parsing; every other
  source goes to the existing anchored regex compiler. Private pre-normalized
  construction skips both branches after tokenization. Validate an explicit
  `declaration_package` as one plain ASCII Perl package name; when absent,
  capture the direct caller of `Pattern->new` before delegating to its internal
  construction path.

- [ ] **Step 7: Implement non-autovivifying exact CODE lookup.** Traverse
  existing package stashes component by component. The implementation shape is:

  ```perl
  sub _existing_stash {
      my ($package) = @_;
      my $stash = \%main::;
      return $stash if $package eq 'main';

      no strict 'refs';
      for my $component (split /::/, $package) {
          my $key = $component . '::';
          return unless exists $stash->{$key};
          my $next = *{$stash->{$key}}{HASH};
          return unless $next;
          $stash = $next;
      }
      return $stash;
  }
  ```

  Inspect the terminal CODE slot only after `exists $stash->{$function}`. Do not
  use symbolic invocation by string, `$package->can`, `UNIVERSAL::can`,
  `require`, or `eval STRING`. Keep qualified missing-stash and missing-CODE
  diagnostics distinct.

- [ ] **Step 8: Invoke once and reuse Task 1 normalization.** Call the resolved
  CODE in list-independent scalar context with no arguments. Wrap invocation in
  `eval` only to add provider/parameter/package context while preserving the
  original exception text. Detect a blessed `Future` before passing the result
  to the same constraint normalizer used by explicit values; parameterize only
  the invalid-shape diagnostic so shape logic is not duplicated.

- [ ] **Step 9: Update Pattern POD and run focused regressions.** Document the
  provider grammar, declaration-package ownership, construction-time execution,
  accepted result shapes, literal-ampersand escape, and normalized runtime
  predicates in Pattern's internal POD. Then run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/02-patterns.t t/routing/03-reverse-inspection.t'
  ```

  Confirm existing nested braces, character classes, comments, escaped braces,
  regex anchoring, render diagnostics, and constraint ordering remain green.

- [ ] **Step 10: Commit and review.** Stage only Pattern and its test:

  ```bash
  git add lib/PAGI/Routing/Pattern.pm t/routing/02-patterns.t
  git commit -m "Routing: add inline constraint providers"
  ```

  Review every symbol-table read for autovivification and every provider failure
  for construction-time context. Update Task 2's ledger row.

---

### Task 3: Preserve the Public Constructor's Declaration Package

**Files:**

- Modify: `lib/PAGI/Routing.pm`
- Modify: `lib/PAGI/Routing/Route.pm`
- Modify: `lib/PAGI/Routing/Mount.pm`
- Modify: `t/routing/01-constructors.t`

**Interfaces:**

- Public `route`, `websocket`, `sse`, and `mount` capture their direct caller
  before requiring/delegating.
- Factories call `Route->_new_from($package, $kind, @args)` or
  `Mount->_new_from($package, @args)`.
- Direct `Route->new` and `Mount->new` capture their own direct caller and
  delegate to the same seam.
- Route/Mount pass `declaration_package` into their source Pattern exactly once.
- Moving an already-built descriptor through another package or Router does not
  rebind or re-resolve it.

- [ ] **Step 1: Add failing factory/direct-constructor tests.** Define distinct
  packages with same-named providers accepting different sentinel values. Build
  HTTP, WebSocket, SSE, and all three mount forms through imported public
  functions, then direct `Route->new`/`Mount->new`. Match their private Patterns
  to prove the package containing the call owns unqualified lookup.

- [ ] **Step 2: Pin re-export, wrapper, and role semantics.** Add three separate
  fixtures:

  - an ordinary `Exporter` re-export of the aliased `route` function, where the
    consuming package is still the direct caller;
  - a real wrapper sub that calls `route`, where the wrapper package owns lookup;
  - a role-package method aliased into/invoked on a consuming class, where the
    call expression compiled in the role package owns lookup.

  Give consumer, wrapper, and role providers intentionally different accepted
  values so a false positive cannot pass. Also build a descriptor in one
  package, place it into a Router in another, and prove its original predicate
  still selects the request without another provider call.

- [ ] **Step 3: Run the red gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/01-constructors.t t/routing/02-patterns.t'
  ```

  Expected before implementation: lookup occurs in `PAGI::Routing::Route` or
  `PAGI::Routing::Mount`, not in the application declaration package.

- [ ] **Step 4: Add explicit private constructor seams.** Refactor without
  duplicating validation:

  ```perl
  sub new {
      my ($class, @args) = @_;
      my $package = caller;
      return $class->_new_from($package, @args);
  }

  sub _new_from {
      my ($class, $package, @args) = @_;
      # existing validation and construction
  }
  ```

  `Route` retains its leading `$kind`; its `_new_from` signature is
  `($class, $package, $kind, @args)`. Validate `declaration_package` as a plain
  ASCII Perl package name through Pattern's Task 2 constructor contract. Do not
  retain it on the public Route or Mount hash after the normalized Pattern
  exists.

- [ ] **Step 5: Capture factory callers before delegation.** In each exported
  function, store `my $package = caller`, load the class, then call `_new_from`.
  Do not add another stack walk and do not have `_new_from` call `caller`.

- [ ] **Step 6: Update class POD at the changed seam.** Briefly document that an
  unqualified inline provider belongs to the package directly calling the
  factory or object constructor and that moving a completed descriptor cannot
  rebind it. Leave full wrapper/re-export/role guidance to Task 7.

- [ ] **Step 7: Run focused regressions.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/01-constructors.t t/routing/02-patterns.t t/routing/03-reverse-inspection.t t/routing/07-mounts.t'
  ```

- [ ] **Step 8: Commit and review.** Stage only the four named files:

  ```bash
  git add lib/PAGI/Routing.pm lib/PAGI/Routing/Route.pm lib/PAGI/Routing/Mount.pm t/routing/01-constructors.t
  git commit -m "Routing: retain constraint declaration packages"
  ```

  Review public factory, direct constructor, re-export, wrapper, and role cases
  independently. Update Task 3's ledger row.

---

### Task 4: Give Every Protocol and Mount the Same Constraint Surface

**Files:**

- Modify: `lib/PAGI/Routing/Route.pm`
- Modify: `t/routing/01-constructors.t`
- Modify: `t/routing/05-http-dispatch.t`
- Modify: `t/routing/07-mounts.t`
- Modify: `t/routing/08-protocols.t`

**Interfaces:**

- HTTP, WebSocket, and SSE Route descriptions all accept `constraints` and
  expose its defensive public accessor when supplied.
- Inline and explicit constraints participate together for all three kinds.
- `methods` remains rejected for WebSocket and SSE.
- Raw forms use the same Pattern before their native app receives a scope.
- Inline, known Router, and opaque application mounts already accept explicit
  constraints and now receive provider-backed dispatch coverage.

- [ ] **Step 1: Replace the obsolete rejection test.** In constructor tests,
  remove the assertion that WebSocket rejects `constraints`. Add WebSocket and
  SSE descriptors with regex, coderef, and check-object constraints; assert
  declared identity/defensive hashes, accepted and rejected `_pattern`
  matches, and continued `methods` rejection.

- [ ] **Step 2: Add failing HTTP/raw HTTP provider dispatch tests.** Add one
  normal and one raw route whose provider accepts one value and rejects another.
  Assert rejected paths continue scanning or produce the existing generated
  outcome, and raw targets are never invoked after rejection.

- [ ] **Step 3: Add failing mount-form provider dispatch tests.** In
  `t/routing/07-mounts.t`, cover provider-backed inline, Router, and opaque
  prefixes. Assert accepted captures reach the selected child with the original
  scalar and a rejected prefix does not invoke mount middleware or target.

- [ ] **Step 4: Add failing WebSocket/SSE normal and raw tests.** Reuse the
  protocol test harness to cover:

  - normal WebSocket inline provider;
  - raw WebSocket explicit predicate/check object;
  - normal SSE explicit constraint;
  - raw SSE inline provider; and
  - rejected values following the existing denial/decline behavior without
    invoking the selected handler/app.

  Include named WebSocket/SSE leaves so later reverse tests can render them.

- [ ] **Step 5: Run the red gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/01-constructors.t t/routing/05-http-dispatch.t t/routing/07-mounts.t t/routing/08-protocols.t'
  ```

  Expected pre-change failure: WebSocket/SSE reject `constraints`; provider
  fixtures depending on factory package capture may now pass from Task 3.

- [ ] **Step 6: Remove the protocol-only option asymmetry.** Add `constraints`
  to the common Route option set, validate it whenever present, compute
  `_has_constraints` independently of `$kind`, and always pass the declared
  hash into Pattern. Keep only `methods` behind `$kind eq 'route'`.

- [ ] **Step 7: Run focused regressions.** Run the red-gate command again, then:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/03-reverse-inspection.t t/routing/09-metadata-isolation.t'
  ```

  Ensure denial, SSE decline, raw event ownership, middleware selection, and
  HTTP method behavior are unchanged.

- [ ] **Step 8: Update Route POD, commit, and review.** State that all leaf
  protocols accept path constraints while only HTTP accepts methods. Stage only
  the five named files:

  ```bash
  git add lib/PAGI/Routing/Route.pm t/routing/01-constructors.t t/routing/05-http-dispatch.t t/routing/07-mounts.t t/routing/08-protocols.t
  git commit -m "Routing: share constraints across route protocols"
  ```

  Review accepted/rejected behavior for all six normal/raw protocol forms and
  all three mount forms. Update Task 4's ledger row.

---

### Task 5: Compose Normalized Predicates for Reverse Routing

**Files:**

- Modify: `lib/PAGI/Routing/Resolver.pm`
- Modify: `t/routing/03-reverse-inspection.t`
- Modify: `t/routing/09-metadata-isolation.t`
- Modify: `t/context/12-routing-reverse.t`

**Interfaces:**

- Resolver traversal carries `parameter name => [predicate records]` rather
  than original explicit constraint values.
- `_extend_parameters` rejects duplicate names as today, then defensively
  copies each node Pattern's private records into the ancestry map.
- Effective named-route Patterns receive `constraints => {}` plus the private
  `_predicate_records` channel. They never compile inline regexes, resolve
  providers, normalize check objects, or append explicit constraints again.
- Existing matching and reverse generation enforce the same CODE identities.
- Public route metadata and public constraint accessors do not expose records.

- [ ] **Step 1: Add failing composed-provider tests in two packages.** Define a
  provider-backed mount in one package and provider-backed named leaf in another,
  with separate call counters. Compose through an inline mount and a known
  Router mount. Assert construction calls each source occurrence once, then
  `path_for` accepts valid outer/leaf values and rejects each invalid value
  without changing provider counts.

- [ ] **Step 2: Pin `path_for` and `url_for` constraint identity.** Add:

  - a check object whose `get_message` detail survives composed reverse errors;
  - a named WebSocket and SSE route enforcing provider/explicit constraints;
  - Context-relative `path_for` inheriting a valid mount capture;
  - Context `url_for` with query and fragment enforcing an explicit leaf value;
  - existing inline regex on a mount and leaf continuing to reject invalid
    reverse values; and
  - a provider-backed negative integer value rendering without coercion.

- [ ] **Step 3: Add the double-application sentinel.** Put a side-effecting
  explicit predicate on a named leaf beneath a constrained mount. Reset its
  counter after Router construction, call `path_for` once and `url_for` once,
  and assert exactly one predicate call per render. A count of two identifies
  the forbidden combination of pre-normalized records plus original
  `constraints`.

- [ ] **Step 4: Add repeated-placement and concurrency coverage.** Mount the
  same child Router twice, assert provider counters do not increase, and render
  both canonical addresses. In `t/routing/09-metadata-isolation.t`, use one
  compiled app for concurrent provider-backed requests with distinct captured
  values and prove each handler/metadata frame sees only its request's original
  scalar.

- [ ] **Step 5: Run the red gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/03-reverse-inspection.t t/context/12-routing-reverse.t t/routing/09-metadata-isolation.t'
  ```

  Expected before Resolver changes: an effective Pattern reparses `&Provider`
  under the wrong declaration package or invokes it again; preserving both the
  source provider and exact one-call render count is impossible.

- [ ] **Step 6: Replace Resolver's original-value ancestry map.** Rename
  `$outer_constraints` to `$outer_predicates` throughout traversal. Implement
  `_extend_parameters` in this shape:

  ```perl
  my %predicates = map {
      $_ => [map { +{%$_} } @{$outer_predicates->{$_}}]
  } keys %$outer_predicates;

  my $local = $node->_pattern->_predicate_records;
  for my $name (@{$node->parameters}) {
      croak "duplicate path parameter '$name' in effective path '$effective_path'"
          if $seen{$name}++;
      push @names, $name;
      $predicates{$name} = [map { +{%$_} } @{$local->{$name}}];
  }
  ```

  Keep fresh containers but preserve `check`/`explain` CODE identities.

- [ ] **Step 7: Build effective Patterns only from normalized records.** Use:

  ```perl
  my $pattern = PAGI::Routing::Pattern->new(
      path               => $effective_path,
      mode               => 'route',
      constraints        => {},
      _predicate_records => $predicates,
  );
  ```

  Rename private Resolver metadata storage from misleading raw `constraints`
  wording to predicate-record wording where it is retained. Do not add the
  records to `_metadata_for_location` or any public inspection result.

- [ ] **Step 8: Run focused regressions.** Run the red-gate command again, then:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/02-patterns.t t/routing/03-reverse-inspection.t t/routing/05-http-dispatch.t t/routing/07-mounts.t t/routing/08-protocols.t t/routing/09-metadata-isolation.t t/context/12-routing-reverse.t'
  ```

- [ ] **Step 9: Update Resolver POD, commit, and review.** Describe composed
  normalized predicates rather than reparsed constraint inputs. Stage only:

  ```bash
  git add lib/PAGI/Routing/Resolver.pm t/routing/03-reverse-inspection.t t/routing/09-metadata-isolation.t t/context/12-routing-reverse.t
  git commit -m "Routing: preserve predicates through reverse composition"
  ```

  Review provider invocation counts, explicit predicate call counts, CODE
  identity, repeated placement, relative inheritance, and concurrent request
  isolation. Update Task 5's ledger row.

---

### Task 6: Modernize the Large Application and Demonstrate Type::Tiny

**Files:**

- Modify: `cpanfile`
- Modify: `examples/15-large-application/app.pl`
- Modify: `examples/15-large-application/lib/MyApp/Data.pm`
- Modify: `examples/15-large-application/lib/MyApp/Root.pm`
- Modify: `examples/15-large-application/lib/MyApp/Person.pm`
- Modify: `examples/15-large-application/lib/MyApp/Person/Blogs.pm`
- Modify: `examples/15-large-application/lib/MyApp/View.pm`
- Modify: `t/integration-large-application.t`

**Interfaces:**

- Core distribution minimum remains Perl 5.18.
- The large example requires Perl 5.40 and Type::Tiny, uses signatures, and
  retains class-method `routing`/`to_app` composition.
- Person and Blog identifiers use imported `Types::Standard::Int` through
  `&Int` path syntax.
- Type::Tiny is a test prerequisite only.
- `/person/-1` reaches `show_person` and returns its branded handler-owned 404;
  a noninteger path does not reach the typed leaf.

- [ ] **Step 1: Make the integration test safely version-gated.** Keep the test
  itself in Perl 5.18 syntax. Retain compile-time `use Test2::V0`, `FindBin`,
  the example `lib` path, and `PAGI::Test::Client`, but remove compile-time
  `use MyApp::*`. Immediately after setup:

  ```perl
  if ($] < 5.040) {
      plan skip_all => 'examples/15-large-application requires Perl 5.40';
      exit 0;
  }

  require MyApp::Data;
  require MyApp::Person;
  require MyApp::Person::Blogs;
  require MyApp::Root;
  require MyApp::View;
  ```

  Verify the whole test file contains no signatures or other post-5.18 syntax.

- [ ] **Step 2: Add failing source and behavior assertions.** Read each example
  Perl source and assert `use v5.40`, signature-style entry points, no legacy
  `my (...) = @_` unpacking, `Types::Standard qw(Int)` in Person/Blogs, and
  `&Int` on the two `person_id` declarations plus `blog_id` leaf. Add Test Client
  assertions that `/person/-1` has the branded `Person not found` body, while a
  noninteger path returns the child Router's generated `Not Found` and does not
  contain the branded heading. Add reverse assertions that `-1` renders.

- [ ] **Step 3: Run the red gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-large-application.t'
  ```

  Expected before modernization: source-style assertions fail and `-1` does not
  reach the old `qr/\d+/` leaf.

- [ ] **Step 4: Add the test-only dependency.** Inside `on 'test'`, add:

  ```perl
  requires 'Type::Tiny';
  ```

  Do not add it to the runtime/recommends/develop phases and do not import it in
  core routing modules.

- [ ] **Step 5: Modernize every example Perl source.** Replace legacy preambles
  with `use v5.40;`, retain `use utf8` only where useful, and convert every
  named sub to signatures. Examples include:

  ```perl
  sub routing($class) { ... }
  sub show_person($c) { ... }
  sub person($self, $person_id) { ... }
  sub document($class, $title, $body) { ... }
  ```

  Keep data, lifespan, HTML, routing ownership, links, descriptions, and
  class-method composition otherwise unchanged.

- [ ] **Step 6: Replace example regex declarations with providers.** In Person
  and Blogs:

  ```perl
  use Types::Standard qw(Int);

  route('/{person_id:&Int}' => \&show_person, name => 'show', ...);
  mount('/{person_id:&Int}/blog', router => ..., namespace => 'blog', ...);
  route('/{blog_id:&Int}' => \&show_blog, name => 'show', ...);
  ```

  Do not introduce `PersonId`, coercion, cached Router globals, exported route
  arrays, or a component base class in this task.

- [ ] **Step 7: Compile and run focused integration.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -Iexamples/15-large-application/lib -c examples/15-large-application/app.pl && prove -lv t/integration-large-application.t t/routing/03-reverse-inspection.t'
  ```

  Confirm lifespan startup/shutdown, followed links, local/custom 404s, static
  mounting, method handling, and HEAD remain green in addition to new signed-Int
  semantics.

- [ ] **Step 8: Commit and review.** Stage exactly the eight named paths:

  ```bash
  git add cpanfile examples/15-large-application/app.pl examples/15-large-application/lib/MyApp/Data.pm examples/15-large-application/lib/MyApp/Root.pm examples/15-large-application/lib/MyApp/Person.pm examples/15-large-application/lib/MyApp/Person/Blogs.pm examples/15-large-application/lib/MyApp/View.pm t/integration-large-application.t
  git commit -m "examples: demonstrate typed inline route constraints"
  ```

  Review that only the example minimum changed, the test skips before module
  load, and negative-ID behavior is intentional and asserted. Update Task 6's
  ledger row.

---

### Task 7: Reconcile Documentation, Release Notes, and Final Verification

**Files:**

- Modify: `lib/PAGI/Routing.pm`
- Modify: `lib/PAGI/Routing/Pattern.pm`
- Modify: `lib/PAGI/Routing/Route.pm`
- Modify: `lib/PAGI/Routing/Mount.pm`
- Modify: `lib/PAGI/Routing/Resolver.pm`
- Modify: `lib/PAGI/Tools/Tutorial.pod`
- Modify: `lib/PAGI/Tools/Cookbook.pod`
- Modify: `examples/15-large-application/README.md`
- Modify: `Changes`

**Documentation contract:**

- Present inline regex, inline provider, explicit object, and explicit predicate
  forms together without declaring one universally clearer.
- Recommend a short inline regex for a short path-local rule, `&Provider` for a
  reusable named semantic constraint beside the parameter, and the explicit
  hash for dynamic, subclass-dependent, or syntactically complex constraints.
- Explain complete provider grammar; uppercase terminal; reservation of every
  unescaped-leading `&`; `[&]` canonical literal escape; single-quoted `\&`
  alternative; and the double-quoted Perl-string trap.
- Explain direct declaration package lookup, qualified lookup, re-export versus
  wrapper/role boundaries, exact CODE-slot semantics, construction-time
  invocation, accepted returned shapes, provider versus returned predicate,
  synchronous/non-coercing checks, and lack of loading/method/registry fallback.
- State that provider and explicit constraints can coexist inline-first and are
  enforced by request matching, `path_for`, and `url_for` for every protocol.
- Contrast `PAGI::App::Router`, where the same `&Int` text remains regex syntax.
- Explain that `Types::Standard::Int` accepts signed integers and that
  application identifiers may need a narrower local provider.
- Document the example's Perl 5.40 and Type::Tiny requirements without implying
  a distribution-wide minimum/runtime dependency.

- [ ] **Step 1: Update the principal `PAGI::Routing` constraint section.** Replace
  “explicit Perl constraints are clearer” with the four-form comparison from
  the approved spec. Add concise construction, lookup, escaping, Type::Tiny,
  reverse-routing, and App::Router-contrast subsections. Update constructor
  option text so WebSocket/SSE constraints are no longer described as invalid.

- [ ] **Step 2: Reconcile class/internal POD.** In Pattern, document one-time
  predicate normalization and private record composition. In Route, document
  constraints for every leaf and methods only for HTTP. In Mount, document
  provider-backed prefixes and declaration-package ownership. In Resolver,
  document that effective reverse Patterns reuse normalized source predicates
  rather than reparsing syntax. Do not expose private option names as supported
  application API.

- [ ] **Step 3: Update Tutorial and Cookbook examples.** Add one minimal
  `Types::Standard qw(Int)` provider example and one application-local
  `PersonId` provider. Retain explicit predicate/object examples. Ensure every
  `&` provider path shown in Perl source is quoted correctly and every literal
  ampersand example uses `[&]` or a single-quoted backslash spelling.

- [ ] **Step 4: Update the large-example README.** State Perl 5.40+ and
  Type::Tiny requirements, explain why `&Int` is concise but validates rather
  than converts, retain the Python/Starlette comparison, and explicitly call
  out that signed `Int` makes `/person/-1` a matched handler-owned 404.

- [ ] **Step 5: Add the unreleased Changes entry.** Under `0.002003`, record
  provider syntax, exact declaration-package function lookup, uniform protocol
  constraints, composed reverse preservation, and the example modernization.
  Do not claim App::Router parity, registry support, coercion, or a runtime
  Type::Tiny dependency.

- [ ] **Step 6: Run documentation and focused verification before commit.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && podchecker lib/PAGI/Routing.pm lib/PAGI/Routing/Pattern.pm lib/PAGI/Routing/Route.pm lib/PAGI/Routing/Mount.pm lib/PAGI/Routing/Resolver.pm lib/PAGI/Tools/Tutorial.pod lib/PAGI/Tools/Cookbook.pod'
  ```

  Then run the complete focused feature matrix:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/01-constructors.t t/routing/02-patterns.t t/routing/03-reverse-inspection.t t/routing/05-http-dispatch.t t/routing/07-mounts.t t/routing/08-protocols.t t/routing/09-metadata-isolation.t t/context/12-routing-reverse.t t/integration-large-application.t'
  ```

- [ ] **Step 7: Commit documentation.** Stage only the nine named files:

  ```bash
  git add lib/PAGI/Routing.pm lib/PAGI/Routing/Pattern.pm lib/PAGI/Routing/Route.pm lib/PAGI/Routing/Mount.pm lib/PAGI/Routing/Resolver.pm lib/PAGI/Tools/Tutorial.pod lib/PAGI/Tools/Cookbook.pod examples/15-large-application/README.md Changes
  git commit -m "docs: explain inline constraint providers"
  ```

- [ ] **Step 8: Perform the implementation/spec review gate.** Use
  `superpowers:requesting-code-review`. Review the entire Task 1–7 commit range
  against every approved spec section and adversarial finding. Independently
  inspect:

  - all `caller` boundaries;
  - symbol-table reads and absence of `can`/`require` provider lookup;
  - provider invocation counts;
  - private record defensive copies and CODE identity;
  - absence of double-applied explicit constraints;
  - all normal/raw protocol and mount forms;
  - Perl 5.18 core syntax versus Perl 5.40 example syntax;
  - `cpanfile` phase placement; and
  - docs/Changes claims versus shipped behavior.

  Resolve ordinary in-contract findings with a focused red test and the smallest
  correction. Record any contract conflict as a deviation and stop affected
  work for user direction.

- [ ] **Step 9: Run the final static gates.** At the reviewed HEAD, run:

  ```bash
  git diff --check
  ```

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -c lib/PAGI/Routing/Pattern.pm && perl -Ilib -c lib/PAGI/Routing/Route.pm && perl -Ilib -c lib/PAGI/Routing/Mount.pm && perl -Ilib -c lib/PAGI/Routing/Resolver.pm && perl -Ilib -Iexamples/15-large-application/lib -c examples/15-large-application/app.pl'
  ```

  Rerun `podchecker` only if review changed POD after Step 6.

- [ ] **Step 10: Run the repository-wide suite exactly once.** Use the only full
  suite invocation in this plan:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t'
  ```

  Record exact files/assertions, elapsed time, exit status, and clean output in
  Task 7's ledger row. Do not follow this with `dzil test` or a second full-suite
  invocation. If it fails, use `superpowers:systematic-debugging`, add/tighten
  the closest focused test, make the smallest in-scope fix, rerun that focused
  test, and rerun the full suite only after the HEAD changes; record both the
  failed and replacement final-gate attempts honestly.

- [ ] **Step 11: Close the ledger and hand off.** Confirm `git status --short`
  contains only the three preserved unrelated untracked reports, every task row
  has one commit range and review result, the final suite appears exactly once
  as a successful gate, and every deviation has a user decision. If review or
  final verification required a correction after the documentation commit,
  commit only the explicitly changed files with a precise message and add that
  SHA to Task 7's commit range.

## Completion Criteria

- `/{id:&Provider}` works for every declared path kind and malformed provider
  intent fails during construction.
- Exact package-function lookup is non-inherited, non-loading, and
  non-autovivifying.
- Providers run once per source occurrence; only normalized unary predicates
  run during match/render.
- Regex, coderef, and check-object constraints share one runtime execution path.
- Reverse composition preserves exact predicate identities and never applies an
  explicit constraint twice.
- WebSocket and SSE accept the same explicit constraint shapes as HTTP while
  continuing to reject HTTP methods.
- The large example uses Perl 5.40 signatures and `&Int`, demonstrates signed
  Type::Tiny semantics, and does not raise the core distribution minimum.
- Public POD, Tutorial, Cookbook, example README, dependency declarations, and
  Changes agree with the implementation.
- Focused gates, static/POD checks, independent review, and the one final full
  suite are recorded with real evidence in the SDD ledger.
