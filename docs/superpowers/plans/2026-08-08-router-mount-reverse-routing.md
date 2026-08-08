# Router Mount and Composed Reverse Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add routing-aware Router mounts, one composed slash-addressed reverse-routing graph, exact relative Context lookup with request-local parameter inheritance, compact and named query/fragment arguments, and a modular large-application example that no longer duplicates URLs.

**Architecture:** Immutable `Router`, `Mount`, and `Route` descriptions remain placement-free. `Resolver` recursively indexes direct routes, inline mounts, and explicit Router mounts when the containing Router is constructed, stopping at opaque applications. `Compiler` compiles a Router mount as a real child dispatch boundary while sharing the outer resolver frame and one outermost HEAD wire boundary. The request-local `pagi.routing` frame records the active logical namespace and an unaliased capture snapshot; `PAGI::Context` supplies those values only for relative reverse lookup. Router-object lookup always starts at that Router's own root and inherits nothing.

**Tech Stack:** Perl 5.18-compatible source, `Future`, `Future::AsyncAwait`, `Test2::V0`, existing `PAGI::Routing`, `PAGI::Context`, `PAGI::Authority`, `PAGI::Compose`, `PAGI::Test::Client`, POD, and Dist::Zilla. No new runtime dependency.

## Global Constraints

- The approved contract is `docs/superpowers/specs/2026-08-08-router-mount-reverse-routing-design.md`. If implementation evidence conflicts with that document, record a deviation and obtain the user's decision before dependent work continues.
- This declarative routing API has not been released. Do not add dotted-name compatibility, ignored opaque namespaces, signature aliases, warnings, or deprecation machinery. Update tests, examples, and documentation to the new contract in the same feature branch.
- Work only in `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools`.
- Preserve the unrelated untracked files `.cpan-testers-fix-report.md`, `.csrf-helper-brief.md`, and `.csrf-helper-report.md`. Never stage them.
- Keep shipped source compatible with Perl 5.18: classic `@_` unpacking, no signatures, postfix dereferencing, `try`/`catch`, or new language features.
- Use hand-written blessed hashes and the repository's existing style. Do not add Moo, Moose, Role::Tiny, URI, an HTML parser, or another CPAN dependency.
- Keep all routing descriptions immutable. A child Router must never store a parent path, placement namespace, request captures, compiled middleware instance, or current match.
- Public collection accessors remain defensive shallow copies. Source route identity remains stable through `named_routes` and `route_named`.
- Path parameters are decoded input. Reverse generation validates and encodes them but never coerces them. Do not add parameter-renaming or automatic collision repair.
- Preserve pure PAGI app-to-app middleware. Do not introduce a request-time `$next` API.
- Preserve the existing Router-boundary ownership contract: after a Router-mount prefix matches, the child owns FULL, PARTIAL, and NONE; the parent does not resume scanning or union methods.
- Preserve one outermost `PAGI::Routing::HeadBoundary`. Router, mount, and route middleware must see the unsuppressed GET representation before the wire boundary removes every HTTP body event, including sendfile events.
- Continue using `Future->wrap($returned)` at every application/handler adaptation boundary so synchronous and Future-backed callables both work.
- Use `PAGI::Authority` for absolute URL authority and scheme handling. Do not rescan Host headers or add proxy interpretation to routing.
- Do not change `PAGI::App::Router`, `PAGI::Endpoint::Router`, `PAGI::URLMap`, `PAGI::App::File`, `PAGI::Middleware::Builder`, or the open 404/405/no-match-bubbling model.
- Put POD beside each changed public constructor, accessor, reverse helper, metadata field, and dispatch distinction in the task that changes it. The later documentation task reconciles the longer guides and examples; it does not defer API documentation.
- Use TDD for behavior changes: add the smallest focused failing assertion, run it and record the expected failure, implement the behavior, rerun the focused test, then run the named regression gate.
- Capture intentional failures with `dies`; use stable diagnostic fragments that state the bad form, reference, parameter, or placement. Test output must stay clean.
- Stage only paths named by the current task. Never use `git add -A` or `git add .`.
- Every task ends with a focused commit and the execution workflow's review gate. The coordinator verifies the commit and commands independently before marking the ledger row complete.
- Run Perl commands through the project Perl:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/01-constructors.t'
  ```

## Execution Tracking and Deviation Control

Before Task 1, run the `superpowers:subagent-driven-development` workspace helper even when using inline execution:

```bash
/Users/jnapiorkowski/.codex/plugins/cache/openai-curated-remote/superpowers/6.2.0/skills/subagent-driven-development/scripts/sdd-workspace docs/superpowers/plans/2026-08-08-router-mount-reverse-routing.md
```

The command must print a directory ending in `.superpowers/sdd/2026-08-08-router-mount-reverse-routing`. Create its `progress.md` with this exact first line and tables:

```markdown
# SDD ledger — plan: docs/superpowers/plans/2026-08-08-router-mount-reverse-routing.md

| Task | Status | Commit range | Focused verification | Full-suite verification | Review |
|---|---|---|---|---|---|
| 1 | pending | — | — | — | — |
| 2 | pending | — | — | — | — |
| 3 | pending | — | — | — | — |
| 4 | pending | — | — | — | — |
| 5 | pending | — | — | — | — |
| 6 | pending | — | — | — | — |
| 7 | pending | — | — | — | — |
| 8 | pending | — | — | — | — |

## Deviations

| ID | Status | Conflicting plan text | Evidence and rationale | Affected tasks | User decision |
|---|---|---|---|---|---|
```

The coordinator owns this ledger. Record exact commands, exit status, real test-file/assertion counts, elapsed time, commit SHAs, and review evidence—never estimates or an implementer's unsupported summary. A discovered contract conflict gets the next stable ID (`D-001`, `D-002`, and so on), status `awaiting decision`, the conflicting plan/spec text, concrete evidence, and every blocked dependent task. Record the user's explicit approval, rejection, or replacement before continuing. Ordinary defects that preserve the approved contract are not deviations.

## File and Responsibility Map

- `lib/PAGI/Routing/Mount.pm`: the three mount forms, form-specific validation/accessors, and immutable placement declaration.
- `lib/PAGI/Routing/Route.pm`: local route-name segment validation shared with mount namespaces.
- `lib/PAGI/Routing/Router.pm`: immutable local Router plus its construction-time composed Resolver.
- `lib/PAGI/Routing/Resolver.pm`: placement traversal, canonical logical addresses, reference normalization, reverse-argument parsing, rendering, inspection, and URL scheme/authority selection.
- `lib/PAGI/Routing/Compiler.pm`: fresh executable graphs, Router-boundary dispatch, middleware ordering, and request-local routing metadata.
- `lib/PAGI/Context.pm`: request-aware relative lookup, active-placement capture inheritance, and root-path application.
- `lib/PAGI/Routing/HeadBoundary.pm`: existing outermost wire suppression; behavior is verified but should not need redesign.
- `t/routing/01-constructors.t`: mount forms and declaration grammar.
- `t/routing/03-reverse-inspection.t`: graph discovery, collisions, reference grammar, inspection, and Router-object reverse generation.
- `t/routing/06-head.t`, `07-mounts.t`, `08-protocols.t`, `09-metadata-isolation.t`, and `10-head-boundary.t`: dispatch ownership, middleware, protocol, metadata, concurrency, and HEAD regressions.
- `t/context/12-routing-reverse.t`: Context relative resolution, inheritance, root path, query/fragment, authority, and frame validation.
- `t/integration-declarative-routing-demo.t`: the small shipped declarative example.
- `t/integration-large-application.t`: lifespan-backed modular application and followed-link integration.
- `examples/15-large-application`: the target `Root` / `Person` / `Blogs` component shape.
- `lib/PAGI/Routing.pm`, class POD, `PAGI::Tools::Tutorial`, `PAGI::Tools::Cookbook`, example READMEs, `README.md`, and `Changes`: the public explanation and release surface.

---

### Task 1: Add the Explicit Router Mount Form and Logical Segments

**Files:**

- Modify: `lib/PAGI/Routing/Mount.pm`
- Modify: `lib/PAGI/Routing/Route.pm`
- Modify: `t/routing/01-constructors.t`
- Modify: `t/routing/03-reverse-inspection.t` only to remove the old accepted opaque namespace fixture

**Interfaces:**

- Produces `mount($path => $opaque_app, %opts)` with `target` defined and `is_raw => 1`.
- Produces `mount($path, routes => \@nodes, %opts)` with `routes` defined and `is_raw => 0`.
- Produces `mount($path, router => $router, namespace => $segment, %opts)` with `router` defined and `is_raw => 0`.
- Exactly one of `target`, `routes`, and `router` is defined.
- `router =>` accepts only a blessed `PAGI::Routing::Router` instance/subclass and requires `namespace`.
- Opaque mounts reject `namespace`; inline mounts keep it optional.
- Route names and mount namespaces are one nonempty scalar segment: `/`, `.`, and `..` are forbidden; dots such as `v1.1` are literal and allowed.
- Named selectors may appear in any key order. A malformed positional or named tail reports `mount option list must be key/value pairs` before hash construction.

- [ ] **Step 1: Add failing three-form construction and accessor tests**

  Add one valid object of each form. Assert target identity, `routes` copies, child Router identity, `router`, `target`, and `routes` applicability, `namespace`, and `is_raw`:

  ```perl
  my $child = router(routes => [
      route('/' => sub { }, name => 'index'),
  ]);
  my $known = mount('/known',
      desc      => 'Known child',
      namespace => 'known',
      router    => $child,
  );

  is(refaddr($known->router), refaddr($child), 'Router target is preserved');
  is($known->target, undef, 'Router mount has no opaque target');
  is($known->routes, undef, 'Router mount has no inline routes');
  ok(!$known->is_raw, 'Router mount is inspectable');
  ```

  Include `routes` and `router` before, between, and after other named options to prove option-order independence.

- [ ] **Step 2: Pin selector and malformed-list diagnostics**

  Cover zero selectors; positional plus `routes`; positional plus `router`; `routes` plus `router`; all three; invalid/unblessed Router target; missing Router namespace; opaque namespace; and malformed positional/named tails. Use these stable fragments:

  ```text
  mount requires exactly one of target, routes, or router
  mount option list must be key/value pairs
  router mount target must be a PAGI::Routing::Router
  router mount requires a namespace
  opaque application mounts do not accept namespace
  ```

  Include malformed cases whose first value is a coderef and a blessed object so the parser never stringifies either as an alleged option name.

- [ ] **Step 3: Pin logical-segment grammar**

  Test both `name` and `namespace` with `show`, `v1.1`, `/`, `.`, `..`, `person/show`, empty strings, and references. Keep `desc` behavior unchanged. Required failures identify the field and say it must be one logical address segment.

- [ ] **Step 4: Pin direct-Router structural guidance**

  Put a Router directly inside both `router(routes => [...])` and `mount(..., routes => [...])`. Replace the old positional advice with a diagnostic containing:

  ```text
  mount('/prefix', router => $router, namespace => '...')
  ```

  Also prove `mount('/opaque' => $router)` remains accepted and deliberately opaque.

- [ ] **Step 5: Run the red gate**

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/01-constructors.t t/routing/03-reverse-inspection.t'
  ```

  Expected before implementation: failures for unknown `router`, missing `router` accessor, accepted opaque namespace, accepted slash/dot segments, and old structural guidance.

- [ ] **Step 6: Implement one mount-argument parser before constructing `%opts`**

  Keep parsing private to `Mount`. Determine the candidate form, validate that its tail is key/value shaped, then build `%opts` and count selectors. Do not coerce or compile any target. Store one of `target`, `routes`, or `router`; make `is_raw` derive solely from the opaque form.

  Explicitly reject `namespace` after form selection when the form is opaque. Validate `router` with `blessed($value) && $value->isa('PAGI::Routing::Router')` without accepting arbitrary `to_app` objects.

- [ ] **Step 7: Implement and reuse logical-segment validation**

  Add a private Route helper used by route `name` and mount `namespace`; retain `_validate_text` for `desc`. The segment helper must reject slash anywhere and exact `.`/`..`, but it must not split or reinterpret dots.

- [ ] **Step 8: Update class POD and run regressions**

  Document all three forms together in `Mount` POD, including positional Router opacity and form-specific namespace rules. Document `router`, `target`, `routes`, and `is_raw`. Update `Route` POD to call `name` a local segment.

  Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/01-constructors.t t/routing/03-reverse-inspection.t t/routing/11-bare-middleware.t'
  ```

  Then run the full suite once. Both must pass.

- [ ] **Step 9: Commit and complete the review gate**

  Stage only the four named files and commit:

  ```bash
  git commit -m "Routing: add explicit Router mount descriptions"
  ```

  Record the SHA, focused/full counts, and review result in Task 1's ledger row before Task 2.

---

### Task 2: Build the Composed Slash-Address Resolver

**Files:**

- Modify: `lib/PAGI/Routing/Router.pm`
- Modify: `lib/PAGI/Routing/Resolver.pm`
- Modify: `t/routing/03-reverse-inspection.t`
- Modify: `t/routing/09-metadata-isolation.t`
- Modify: `t/context/12-routing-reverse.t`
- Modify: `examples/declarative-routing/lib/MyApp/Routes/Home.pm`

**Interfaces:**

- `Router` constructs one Resolver from itself, after it has been blessed, so recursive traversal may call the virtual `routes` method and defensively detect subclass cycles.
- Resolver traversal sees direct routes, inline mounts, and `router =>` children; it stops at positional opaque mounts.
- Canonical named keys are absolute slash addresses such as `/person/blog/show`.
- `named_routes` returns `{ absolute_address => original_leaf }`; `route_named` resolves from the Router root and returns the original leaf or `undef` when a well-formed address is unknown.
- Resolver placement metadata contains effective URL pattern, canonical name, containing logical namespace, route kind, source leaf, mount data, constraints, and child location.
- Duplicate canonical addresses name both effective URL patterns.
- Duplicate path parameters fail only on one ancestor-to-descendant effective path, including a known opaque mount prefix.
- A Router may appear in multiple completed sibling branches; only an identity already active in the current ancestry is a cycle.

- [ ] **Step 1: Rewrite inspection expectations to canonical slash addresses**

  Update `t/routing/03-reverse-inspection.t` so declarations use local names such as `show`, namespaces supply hierarchy, and keys look like:

  ```perl
  is(
      [sort keys %{$root->named_routes}],
      [qw(/health /person/blog/index /person/blog/show /person/show)],
      'inspection exposes canonical absolute addresses',
  );
  is(
      refaddr($root->route_named('/person/blog/show')),
      refaddr($blog_show),
      'route_named preserves source leaf identity',
  );
  ```

  Retain one `name => 'v1.1'` case and prove its address is `/v1.1`, not a hierarchy.

- [ ] **Step 2: Add failing known-Router traversal and opacity tests**

  Construct Root -> Person Router -> Blogs Router plus one inline mount. Assert the complete logical-address/effective-path table. Add a positional Router application mount containing a named leaf and prove the leaf is hidden. Add a Router containing an opaque application and prove discovery stops only at that terminal.

- [ ] **Step 3: Add failing composed collision tests**

  Cover:

  - duplicate absolute address across inline and Router placements, naming both URL patterns;
  - repeated `{id}` across Router-mount prefix and child leaf;
  - repeated parameter on an opaque mount prefix before traversal stops;
  - sibling branches reusing `id` successfully; and
  - the same ordinary child Router mounted under `/authors` and `/editors` successfully.

- [ ] **Step 4: Add the defensive cycle pathology**

  Define a local `PAGI::Routing::Router` subclass whose `routes` method returns a Router mount of `$self`. Construction must croak with `Router cycle`, the URL mount ancestry, and logical namespace ancestry. This is deliberately a subclass pathology; do not add lazy/self-referential public constructors merely to manufacture the test.

- [ ] **Step 5: Run the red resolver gate**

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/03-reverse-inspection.t'
  ```

  Expected: the old dot join, opaque-only traversal, missing child records, duplicate-address misses, and absent cycle guard fail.

- [ ] **Step 6: Refactor Router construction around a blessed local description**

  Build and bless the immutable Router fields first, then assign its private Resolver exactly once:

  ```perl
  my $self = bless {
      kind       => 'router',
      routes     => \@routes,
      middleware => $middleware,
      desc       => $opts{desc},
      not_found  => $opts{not_found},
      method_not_allowed => $opts{method_not_allowed},
  }, $class;

  $self->{_resolver} = PAGI::Routing::Resolver->new(router => $self);
  return $self;
  ```

  Add a private `_resolver` accessor for Compiler/Context internals. Do not expose placement mutators.

- [ ] **Step 7: Implement recursive placement traversal**

  Replace dot-prefix state with canonical address segments. Traverse child Routers by calling `$child->routes`; do not reuse the child's local resolver because each outer placement has a different path/address prefix. Track active Router identities by `refaddr`, pushing on entry and removing on exit. Keep location arrays placement-specific so two mounts of the same Router have distinct metadata.

  Validate every mount's own parameters before deciding whether its target is opaque. For a root mount, contribute no URL prefix. Join address segments as `'/'.join('/', @segments)` only for published leaf keys; retain the root namespace separately.

- [ ] **Step 8: Publish absolute metadata and migrate executable expectations**

  Set matched metadata `name` to the canonical absolute address and add `logical_namespace` for every leaf, including unnamed leaves. Update exact metadata hashes in `t/routing/09-metadata-isolation.t`.

  Update Context test fixtures and the declarative demo handler from dotted effective references such as `tenant.show` and `api.item` to canonical absolute/root references. Do not add a dotted alias. The rendered URL strings remain unchanged.

- [ ] **Step 9: Update Router/Resolver POD and run regressions**

  Explain composed inspection, opacity, local-versus-mounted Router paths, early collisions, cycle defense, and source identity. Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/03-reverse-inspection.t t/routing/09-metadata-isolation.t t/context/12-routing-reverse.t t/integration-declarative-routing-demo.t'
  ```

  Then run the full suite once. Both must pass.

- [ ] **Step 10: Commit and complete the review gate**

  Stage only the six named files and commit:

  ```bash
  git commit -m "Routing: index composed Router graphs by slash address"
  ```

---

### Task 3: Implement Exact References and Dual Reverse Arguments

**Files:**

- Modify: `lib/PAGI/Routing/Resolver.pm`
- Modify: `lib/PAGI/Routing/Router.pm`
- Modify: `lib/PAGI/Context.pm`
- Modify: `t/routing/03-reverse-inspection.t`
- Modify: `t/context/12-routing-reverse.t`

**Interfaces:**

- All three public reverse methods accept the same compact and named forms:

  ```perl
  path_for($reference, \%params, \%query, $fragment)
  path_for($reference, params => \%params, query => \%query, fragment => $fragment)
  ```

- A first trailing hashref selects compact form; a first trailing defined non-reference scalar selects named form. `undef` or another reference in first position fails. Forms cannot mix.
- Compact params/query are hashrefs; the optional fragment is a plain scalar or `undef`. Empty fragment emits `#`.
- Named options are `params`, `query`, and `fragment`, order-independent.
- Absolute and root-relative references normalize exactly. Interior `.` and `..` are legal; traversal above root, malformed separators, and a result ending on a namespace fail.
- Query pairs remain sorted and UTF-8 component encoded. Fragment is encoded as one component after the query.
- `path_for` emits no protocol event; `url_for` adds scheme/authority and also emits no event.

- [ ] **Step 1: Add a reverse-argument matrix before implementation**

  In both Router and Context tests, compare compact and named results for:

  ```perl
  $routing->path_for('/item/show');
  $routing->path_for('/item/show', { id => 7 });
  $routing->path_for('/item/show', { id => 7 }, { q => 'two words' });
  $routing->path_for('/item/show', { id => 7 }, { q => 'two words' }, 'details');
  $routing->path_for('/item/show',
      params => { id => 7 }, query => { q => 'two words' }, fragment => 'details');
  ```

  Add query-only and fragment-only compact calls with `{}` placeholders, named options in several orders, `undef` fragment omission, and empty-fragment terminal `#`.

- [ ] **Step 2: Pin argument failures and mixed-form diagnostics**

  Cover too many compact values; non-hash params/query; array/object/scalar-ref fragment; first trailing `undef`; array/object/scalar-ref form selector; odd named list; unknown named key; non-hash named params/query; reference-valued named fragment; and mixed examples such as:

  ```perl
  $routing->path_for('/show', { id => 8 }, query => { view => 'full' });
  ```

  Require operation-specific messages and the stable mixed fragment:

  ```text
  compact and named reverse-routing forms cannot be mixed
  ```

- [ ] **Step 3: Pin reference grammar at the Router root**

  Test `/show`, `show`, `./show`, `group/../show`, and a child reference. Reject repeated slashes, trailing slash, empty segment, above-root traversal, `/`, bare `.`, bare `..`, `group/..`, and unknown exact targets. Prove `%2F` remains literal input and does not become a separator.

- [ ] **Step 4: Run the red reverse gate**

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/03-reverse-inspection.t t/context/12-routing-reverse.t'
  ```

  Expected: fragment cases, named options, normalization, and mixed-form errors fail against the old fixed positional signature.

- [ ] **Step 5: Implement one private reverse-argument parser in Resolver**

  Return a new hash for every call:

  ```perl
  {
      params       => { %path_params_copy },
      query        => { %query_params_copy },
      has_fragment => 0_or_1,
      fragment     => $value,
  }
  ```

  Parse before route rendering. Copy params/query so later caller mutation cannot alter an in-progress render. Detect mixed compact/named input explicitly rather than allowing a type error to obscure it. All Router and Context APIs must delegate to this parser.

- [ ] **Step 6: Implement exact logical-reference normalization**

  Split without URI decoding, reject empty components, and normalize `.`/`..` from left to right against an explicit base segment array. Return both the canonical absolute key and whether the caller used an absolute spelling. Namespace-only results fail before lookup. Do not search ancestors, retry absolute, or fold overlapping prefixes.

- [ ] **Step 7: Separate lookup, render, and URL assembly internally**

  Have one private operation resolve the record and render path/query/fragment. `url_for_scope` must reuse that resolved record for route-kind scheme mapping instead of resolving a second time. Change its private signature so Context can forward arbitrary reverse arguments without padding missing positions with `undef`:

  ```perl
  $resolver->url_for_scope($scope, $reference, $root_path, @reverse_args)
  ```

  Apply `root_path` before the already-rendered query/fragment boundary. Continue to obtain authority only from `PAGI::Authority->from_scope($scope)`.

- [ ] **Step 8: Update public POD and run regressions**

  Add both forms, selection rules, placeholder examples, exact grammar, query/fragment encoding, and no-I/O wording to Resolver, Router, and Context POD. Include HTTP/SSE and WebSocket URLs with query and fragment so scheme selection and suffix order are unambiguous. Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/03-reverse-inspection.t t/context/12-routing-reverse.t t/integration-declarative-routing-demo.t'
  ```

  Then run the full suite once.

- [ ] **Step 9: Commit and complete the review gate**

  ```bash
  git commit -m "Routing: add exact references and reverse URL options"
  ```

  Record actual counts and review evidence before Task 4.

---

### Task 4: Compile Router Mounts as Child Dispatch Boundaries

**Files:**

- Modify: `lib/PAGI/Routing/Compiler.pm`
- Modify: `lib/PAGI/Routing/Router.pm`
- Modify: `t/routing/05-generated-outcomes.t`
- Modify: `t/routing/06-head.t`
- Modify: `t/routing/07-mounts.t`
- Modify: `t/routing/08-protocols.t`
- Modify: `t/routing/09-metadata-isolation.t`
- Modify: `t/routing/10-head-boundary.t`
- Create: `t/routing/12-router-mounts.t`

**Interfaces:**

- Root `compile($router)` installs one routing frame and one outermost `HeadBoundary`.
- A private child-Router compiler builds that Router's own not-found/405 adapters, dispatcher, and Router middleware without adding another frame or HEAD boundary.
- Router mounts use the containing Resolver and a placement-specific metadata location prefix.
- Middleware order is outer Router -> Router-mount -> child Router -> inline mount -> route -> handler.
- Prefix match terminates parent scanning. Child FULL/PARTIAL/NONE and protocol outcomes remain final.
- Every Router placement and every outer `to_app` call compiles fresh middleware instances.

- [ ] **Step 1: Create a focused Router-mount dispatch test**

  In `t/routing/12-router-mounts.t`, build parent siblings around one Router mount. Cover child FULL, PARTIAL, and NONE. Prove:

  - a prefix match terminates parent scanning even if a later parent route would fully match;
  - child 405 contains only child methods;
  - child custom 404/405 bodies win, and a fresh 405 Response still receives `Allow` when it omitted that header;
  - an explicit handler-returned 404 passes through unchanged; and
  - parent handlers are not called after ownership transfers.

- [ ] **Step 2: Add middleware-order and generated-outcome tests**

  Record before/after labels around a successful route and child-generated 404/405. Assert the exact nesting order. Add one stateful middleware factory and prove two placements of the same child receive different build identities; compile the outer Router twice and prove another fresh pair is built. Snapshot the child's public `routes`, `named_routes`, middleware descriptions, and local `path_for` result before composition; assert they are unchanged after both compilations and requests.

- [ ] **Step 3: Add HEAD-boundary tests**

  Place body-derived-header middleware at child Router and Router-mount levels. Assert GET and HEAD expose identical calculated headers and `Content-Length`, while HEAD emits no body bytes and no sendfile body event. Assert the private HeadBoundary marker prevents a nested Router mount from suppressing before middleware calculates headers. Mount a child Router at `/` and prove it consumes nothing: child `path` and `root_path` are unchanged and no leading slash is duplicated.

- [ ] **Step 4: Add WebSocket and SSE ownership tests**

  Through a Router mount, test successful WebSocket/SSE routes plus unmatched WebSocket HTTP denial/close and SSE decline. Prove HTTP generated handlers are not invoked for protocol misses and no protocol event is rewritten by the mount.

- [ ] **Step 5: Run the red compiler gate**

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/12-router-mounts.t t/routing/06-head.t t/routing/08-protocols.t t/routing/10-head-boundary.t'
  ```

  Expected: the new Router mount has no executable branch or attempts to use undefined inline routes; ownership/middleware assertions fail.

- [ ] **Step 6: Split root compilation from child-Router body compilation**

  Refactor `_compile_router` so only the public/root boundary prepares HEAD, creates `_routing_scope`, and awaits the fully wrapped body. Add a private builder shaped like:

  ```perl
  sub _compile_router_body {
      my ($class, $router, $resolver, $location_prefix) = @_;
      # compile this Router's generated handlers and dispatcher
      # wrap this Router's middleware and return one native app
  }
  ```

  Use `$router->_resolver` at the outer root. For a Router mount, call `_compile_router_body($mount->router, $resolver, \@location)` and then wrap mount middleware outside it. Do not call child `to_app`; that would create an opaque frame and a second HEAD boundary.

- [ ] **Step 7: Preserve sync/Future adaptation at every boundary**

  Router mount targets, raw applications, protocol handlers, HTTP handlers, and generated handlers must continue using `Future->wrap($returned)` before `await`. Do not replace this with bare `await $callable->(...)`.

- [ ] **Step 8: Extend metadata recording for Router placements**

  Append Router-mount path/namespace/description to the same request-local frame mount chain. Use Resolver location metadata for child leaves so the final match has the complete effective path and absolute logical address. Parent middleware must observe the final child match after downstream returns.

- [ ] **Step 9: Run focused and full regressions**

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/05-generated-outcomes.t t/routing/06-head.t t/routing/07-mounts.t t/routing/08-protocols.t t/routing/09-metadata-isolation.t t/routing/10-head-boundary.t t/routing/12-router-mounts.t'
  ```

  Then run the full suite once. Both must pass.

- [ ] **Step 10: Update Compiler POD, commit, and review**

  Document inspection transparency versus dispatch boundary, ownership, middleware order, one frame, and one HEAD boundary. Commit:

  ```bash
  git commit -m "Routing: compile Router mounts as child boundaries"
  ```

---

### Task 5: Add Request-Relative Context Resolution and Capture Inheritance

**Files:**

- Modify: `lib/PAGI/Routing/Resolver.pm`
- Modify: `lib/PAGI/Routing/Compiler.pm`
- Modify: `lib/PAGI/Context.pm`
- Modify: `t/context/12-routing-reverse.t`
- Modify: `t/routing/05-generated-outcomes.t`
- Modify: `t/routing/09-metadata-isolation.t`
- Modify: `t/routing/12-router-mounts.t`

**Interfaces:**

- Every v1 frame has `logical_namespace` and `captures` in addition to `resolver`, `root_path`, `mounts`, and `match`.
- Root starts at logical namespace `/` with an empty capture hash.
- Entering inline/Router mounts advances namespace and replaces the snapshot with consumed effective prefix captures.
- FULL leaf selection replaces namespace with the leaf's containing namespace and captures with the complete effective leaf captures.
- Generated child 404/405 retains the owning Router/mount namespace and consumed-prefix snapshot; it never borrows a PARTIAL leaf's captures.
- Context relative references use frame namespace and inherit only target-required captured keys. Explicit params override. Absolute Context references and all Router-object calls inherit nothing.
- Frame captures are a fresh hash, never aliased to `scope->{path_params}`.

- [ ] **Step 1: Add the full relative-reference matrix**

  From a request matched at `/person/42/blog/7` with logical route `/person/blog/show`, assert:

  ```perl
  $c->path_for('show')        eq '/person/42/blog/7';
  $c->path_for('index')       eq '/person/42/blog/';
  $c->path_for('../show')     eq '/person/42';
  $c->path_for('./show')      eq '/person/42/blog/7';
  $c->path_for('x/../show')   eq '/person/42/blog/7';
  $c->path_for('show', { blog_id => 8 }) eq '/person/42/blog/8';
  ```

  Add `/home`, `../../home`, unknown relative, overlapping `person/show`, above-root, namespace-only, repeated/trailing slash, and absolute parameter-missing cases. Prove no fuzzy ancestor or absolute fallback occurs.

- [ ] **Step 2: Add inheritance and validation tests**

  Prove only target-required keys are selected from the snapshot, explicit values win, explicit extra params fail, constraints run after merge, query/fragment do not inherit, and absolute Context plus Router-object calls require all path params explicitly.

- [ ] **Step 3: Test unnamed and generated-handler namespace behavior**

  Add an unnamed Blogs catchall whose handler resolves `index`. Add custom generated 404 and 405 handlers in a child Router that resolve a local route. For 405, create several same-path method leaves with distinct leaf parameters/constraints and prove the handler inherits only consumed mount-prefix captures—not an arbitrary PARTIAL candidate.

- [ ] **Step 4: Test snapshot isolation and concurrency**

  After matching, mutate and replace `scope->{path_params}` and prove inherited links retain the original captures. Start two requests through one compiled app, hold each handler on a separate Future, and assert distinct frame hashes, capture hashes, namespaces, and generated links. The Resolver may be shared; no mutable request data may be.

- [ ] **Step 5: Test active placement reuse**

  Mount the same child Router under `/authors` and `/editors`. Invoke the same child handler through both and assert relative `show` uses the active path/address placement. Confirm `$child->path_for('show', { person_id => 42 })` remains local and cannot include either parent prefix.

- [ ] **Step 6: Run the red Context gate**

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/context/12-routing-reverse.t t/routing/05-generated-outcomes.t t/routing/09-metadata-isolation.t t/routing/12-router-mounts.t'
  ```

  Expected: relative non-root references are resolved from root or fail; captures are missing; generated handlers have no deterministic base; mutation/reuse tests fail.

- [ ] **Step 7: Install request-local namespace and capture state**

  Initialize each new frame with:

  ```perl
  logical_namespace => '/',
  captures          => {},
  ```

  Pass actual match captures into `_record_mount_match` and `_record_leaf_match`. Replace the frame hash values with fresh hashes; never retain the matcher result or `path_params` reference. PARTIAL leaf scans must not record leaf state.

- [ ] **Step 8: Add a Context-aware Resolver entry point**

  Keep Router `path_for` rooted and inheritance-free. Add one private/public-internal Resolver method used only by Context that receives the frame's base namespace and snapshot. It must:

  1. parse the reverse arguments once;
  2. normalize the reference against the frame namespace;
  3. inherit only for relative spelling;
  4. select only parameters required by the target Pattern;
  5. overlay explicit params; and
  6. use the existing Pattern renderer for missing/extra/constraint checks.

  `url_for` must use the same resolved record and merged values as `path_for` before adding scheme/authority.

- [ ] **Step 9: Tighten v1 frame validation and document the jailbreak boundary**

  Require a scalar canonical `logical_namespace` and hashref `captures` on compatible frames created by this API. Update manual test fixtures. Document that Context reads compiled metadata, direct mutation of `pagi.routing` is an unsupported jailbreak, and URL construction is not authorization.

- [ ] **Step 10: Run regressions, commit, and review**

  Run the focused gate from Step 6, then:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/03-reverse-inspection.t t/routing/06-head.t t/routing/07-mounts.t t/routing/08-protocols.t t/routing/09-metadata-isolation.t t/routing/10-head-boundary.t t/routing/12-router-mounts.t t/context/12-routing-reverse.t'
  ```

  Then run the full suite once and commit:

  ```bash
  git commit -m "Routing: resolve relative links from request placement"
  ```

---

### Task 6: Publish the New Routing Contract Across Core Documentation

**Files:**

- Modify: `lib/PAGI/Routing.pm`
- Modify: `lib/PAGI/Routing/Mount.pm`
- Modify: `lib/PAGI/Routing/Router.pm`
- Modify: `lib/PAGI/Routing/Resolver.pm`
- Modify: `lib/PAGI/Routing/Compiler.pm`
- Modify: `lib/PAGI/Context.pm`
- Modify: `lib/PAGI/Tools/Cookbook.pod`
- Modify: `lib/PAGI/Tools/Tutorial.pod`
- Modify: `examples/declarative-routing/README.md`
- Modify: `README.md`
- Modify: `lib/PAGI/Tools.pm`
- Modify: `Changes`

**Interfaces:**

- Public docs show one coherent unreleased API: slash logical addresses, three mount forms, relative Context lookup, compact/named reverse arguments, and Router-boundary ownership.
- Docs distinguish declaration-local `Route->name` from absolute matched metadata `name`.
- Docs distinguish inline structure, known Router mounts, opaque applications, and `route(..., raw => ...)`.
- Docs state that reverse helpers return strings/croak and perform no protocol I/O.
- No historical design/plan document is rewritten as though it had always specified this contract.

- [ ] **Step 1: Audit every current user-facing occurrence**

  Run:

  ```bash
  rg -n "dot-separated|prefixes lookup names with dots|api\\.user|tenant\\.user|path_for|url_for|route_named|named_routes|mount\\(" lib/PAGI/Routing.pm lib/PAGI/Routing/*.pm lib/PAGI/Context.pm lib/PAGI/Tools/Cookbook.pod lib/PAGI/Tools/Tutorial.pod examples/declarative-routing/README.md README.md lib/PAGI/Tools.pm Changes
  ```

  Classify each hit as current declarative Routing, legacy `App::Router`/`Endpoint::Router`, or historical text. Change only current declarative Routing claims.

- [ ] **Step 2: Rewrite `PAGI::Routing` as the canonical reference**

  Add:

  - a side-by-side three-form mount table;
  - positional Router versus `router =>` examples;
  - namespace requirements and opacity;
  - slash address construction and exact relative grammar;
  - current namespace and parameter inheritance, including absolute non-inheritance;
  - compact and named params/query/fragment forms;
  - duplicate address/parameter and cycle failures;
  - Router reuse and Context active-placement behavior;
  - metadata with `logical_namespace`;
  - middleware and child ownership order; and
  - no-match bubbling as explicitly deferred.

  Use compact calls for common examples and named calls when skipping values or labels aid reading.

- [ ] **Step 3: Reconcile class POD rather than duplicating contradictions**

  Verify Mount, Router, Resolver, Compiler, and Context POD use the same terminology and signatures. Explicitly state:

  - `Route->name` is a local segment; match `name` is absolute;
  - child Router object generation is local, while Context knows placement;
  - relative inheritance is convenience, not authorization;
  - wildcard captures remain unsafe filesystem input; use `PAGI::App::File`/Static instead; and
  - root Router mounts consume no prefix and leave `path`/`root_path` unchanged.

- [ ] **Step 4: Update Tutorial, Cookbook, and small example documentation**

  Replace dotted declarative references and old mount guidance. Add one modular Router-mount recipe and one query/fragment recipe. Preserve legacy router examples in their own labeled sections. Explain that `mount('/x' => $router)` is opaque by contract, not shorthand for `router =>`.

- [ ] **Step 5: Add a concise release note**

  Under the current unreleased `Changes` section, record the routing-aware mount, composed reverse routing, relative Context links, and query/fragment forms. Do not call it backward compatible or deprecated.

- [ ] **Step 6: Run POD and documentation regressions**

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && podchecker lib/PAGI/Routing.pm lib/PAGI/Routing/Mount.pm lib/PAGI/Routing/Router.pm lib/PAGI/Routing/Resolver.pm lib/PAGI/Routing/Compiler.pm lib/PAGI/Context.pm lib/PAGI/Tools/Cookbook.pod lib/PAGI/Tools/Tutorial.pod'
  ```

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/00-load.t t/routing/03-reverse-inspection.t t/context/12-routing-reverse.t t/integration-declarative-routing-demo.t'
  ```

  Audit again with `rg`; any remaining dotted declarative example is a failure unless it deliberately demonstrates that dots are literal within one segment.

- [ ] **Step 7: Commit and complete the review gate**

  Stage only files actually changed from the task whitelist and commit:

  ```bash
  git commit -m "docs: publish composed Router reverse routing"
  ```

---

### Task 7: Convert the Modular Large Application and Follow Its Links

**Files:**

- Modify: `examples/15-large-application/lib/MyApp/Root.pm`
- Modify: `examples/15-large-application/lib/MyApp/Person.pm`
- Modify: `examples/15-large-application/lib/MyApp/Person/Blogs.pm`
- Delete: `examples/15-large-application/lib/MyApp/URL.pm`
- Modify: `examples/15-large-application/README.md`
- Modify: `examples/15-large-application/GAPS.md`
- Modify: `t/integration-large-application.t`
- Modify: `examples/README.md`

**Interfaces:**

- `MyApp::Root`, `MyApp::Person`, and `MyApp::Person::Blogs` each expose `routing()` returning a Router description.
- Root `to_app()` calls `compose(app => $class->routing, lifespan => \%callbacks)->to_app`.
- Root mounts Person with `router =>`; Person mounts Blogs with `router =>`; static files remain an opaque app mount.
- All cross-component links use Context `path_for`/`url_for`; `MyApp::URL` no longer exists.
- Blogs retains its explicit local catchall. Root retains its ordinary catchall. Child Router NONE remains child-owned and demonstrates GAP-02.
- Integration tests use `PAGI::Test::Client->run`, extract generated links from HTML, and request those extracted targets instead of repeating mount paths as test constants.

- [ ] **Step 1: Replace the URL-helper unit subtest with Router-shape assertions**

  Remove `use MyApp::URL`. Assert each package's `routing` method returns `PAGI::Routing::Router`; Root's composed `named_routes` contains the five-address table from the spec and preserves leaf identity. Assert `MyApp/URL.pm` is absent.

- [ ] **Step 2: Add a small generated-link follower**

  Because the example emits controlled HTML, add a test-local helper that extracts the `href` for an exact anchor label, decodes only HTML syntax the example emits, removes an absolute `http://testserver` authority when present, and strips the fragment before issuing the request. Do not add an HTML/URI dependency.

  The helper must return both the original href and the request target so query/fragment generation can be asserted before following.

- [ ] **Step 3: Rewrite the integration navigation as linked journeys**

  Starting only at `/`, follow rendered links through:

  - Root -> Person index;
  - Person index -> Ada detail;
  - Person detail -> Blogs index;
  - Blogs index -> blog detail;
  - blog detail -> Root, Person, and Blogs; and
  - blog detail -> the query/fragment comments URL.

  Keep assertions for handler 404s, Blogs catchall, child NONE, child 405/Allow, static-file ownership, HEAD/Content-Length, lifespan startup data, and shutdown cleanup.

- [ ] **Step 4: Run the red example gate before changing the packages**

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-large-application.t'
  ```

  Expected: missing `routing` methods/address map, continued `MyApp::URL` dependency, and link-following assertions fail.

- [ ] **Step 5: Implement `routing` in all three packages**

  Follow the approved example exactly:

  ```perl
  sub routing {
      my ($class) = @_;
      return router(routes => [
          route('/' => \&index, name => 'index'),
      ]);
  }
  ```

  Root uses `name => 'home'`, Person uses `index`/`show`, Blogs uses `index`/`show`, and Router mounts contribute `person`/`blog`. Use `person_id` and `blog_id` so composed path parameters never collide.

- [ ] **Step 6: Replace all hardcoded cross-component paths with Context reverse calls**

  Use relative calls inside a component and absolute calls for graph-wide targets. Include:

  ```perl
  $c->path_for('show', { blog_id => $blog->{id} });
  $c->path_for('../show');
  $c->path_for('/home');
  $c->url_for('show', query => { view => 'full' }, fragment => 'comments');
  ```

  Delete `MyApp::URL` only after every import/call has been replaced and the exact deletion target is confirmed.

- [ ] **Step 7: Update README and GAPS accurately**

  README shows the new file tree without `URL.pm`, the `routing` convention, known Router mounts versus opaque static files, address map, and current real launch command. Keep `pagi-server --lib /Project-MyApp/lib --module MyApp::Root -e 'MyApp::Root->to_app'` labeled deferred.

  In `GAPS.md`:

  - rewrite GAP-01 with `/person/blog/index`, mark known-Router reverse discovery resolved, and retain opaque-app limits;
  - keep GAP-02 as the unsolved no-match-bubbling issue; and
  - revise GAP-03 to point to `docs/superpowers/specs/2026-08-06-pagi-app-base-design.md` as the separate approved/deferred base-class design without claiming GAPS previously proposed it.

- [ ] **Step 8: Run example, integration, and full regressions**

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-large-application.t t/integration-declarative-routing-demo.t t/context/12-routing-reverse.t t/routing/12-router-mounts.t'
  ```

  Then run the full suite once. Confirm `rg -n 'MyApp::URL|URL.pm' examples/15-large-application t/integration-large-application.t` returns no hits.

- [ ] **Step 9: Commit and complete the review gate**

  Stage the exact example/test paths, including the deletion, and commit:

  ```bash
  git commit -m "examples: compose modular Routers with named links"
  ```

---

### Task 8: Run Release Verification and Audit the Contract

**Files:**

- Modify only files already named in Tasks 1–7 when a verified failure requires a correction
- Inspect: `docs/superpowers/specs/2026-08-08-router-mount-reverse-routing-design.md`
- Inspect: `.superpowers/sdd/2026-08-08-router-mount-reverse-routing/progress.md`
- Inspect: complete feature diff from the pre-feature base through `HEAD`

**Interfaces:**

- Produces a fully verified branch, completed evidence ledger, and whole-feature review.
- Does not create an empty verification commit. A real correction gets a focused red test, minimal fix, rerun gates, and an explicit commit.

- [ ] **Step 1: Run the focused feature matrix from a clean process**

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/00-load.t t/routing/01-constructors.t t/routing/03-reverse-inspection.t t/routing/05-generated-outcomes.t t/routing/06-head.t t/routing/07-mounts.t t/routing/08-protocols.t t/routing/09-metadata-isolation.t t/routing/10-head-boundary.t t/routing/11-bare-middleware.t t/routing/12-router-mounts.t t/context/12-routing-reverse.t t/integration-declarative-routing-demo.t t/integration-large-application.t'
  ```

  Record exact file/assertion counts and elapsed time.

- [ ] **Step 2: Run the complete suite twice**

  Run as two distinct invocations:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t/'
  ```

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t/'
  ```

  Both must pass with the same test-file/assertion count. A difference or flaky failure must be investigated, not accepted as a rerun.

- [ ] **Step 3: Run packaging and POD verification**

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && dzil test'
  ```

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && podchecker lib/PAGI/Routing.pm lib/PAGI/Routing/Mount.pm lib/PAGI/Routing/Route.pm lib/PAGI/Routing/Router.pm lib/PAGI/Routing/Resolver.pm lib/PAGI/Routing/Compiler.pm lib/PAGI/Context.pm lib/PAGI/Tools/Cookbook.pod lib/PAGI/Tools/Tutorial.pod'
  ```

- [ ] **Step 4: Audit implementation coverage and non-goals by search**

  ```bash
  rg -n "sub (new|router|path_for|url_for|route_named|named_routes)|logical_namespace|captures|HeadBoundary|Future->wrap|PAGI::Authority" lib/PAGI/Routing lib/PAGI/Context.pm
  ```

  Map every approved design section 5–17 to implementation and a test. Then run:

  ```bash
  rg -n "url_params|PathParamMap|path_to|walk_routes|pagi-server.*--module|cooperative|bubble|sub (get|post|put|patch|delete)|\\$next" lib/PAGI/Routing.pm lib/PAGI/Routing lib/PAGI/Context.pm examples/15-large-application
  ```

  Expected: only clearly labeled documentation/non-goal discussion where appropriate; no implementation of deferred parameter mapping, general provider contracts, route walking, verb shortcuts, loader flags, `$next`, or no-match bubbling.

- [ ] **Step 5: Audit migration completeness**

  ```bash
  rg -n "api\\.user|tenant\\.user|api\\.item|dot-separated|prefixes lookup names with dots|MyApp::URL|URL.pm" lib/PAGI/Routing.pm lib/PAGI/Routing lib/PAGI/Context.pm lib/PAGI/Tools/Cookbook.pod lib/PAGI/Tools/Tutorial.pod examples/declarative-routing examples/15-large-application t/routing t/context/12-routing-reverse.t t/integration-large-application.t
  ```

  Every hit must be either gone or an explicit dot-is-literal test. Verify no opaque mount accepts namespace and no positional Router is accidentally inspected.

- [ ] **Step 6: Audit diff hygiene and unrelated files**

  ```bash
  git diff --check
  git status --short
  git diff --name-status "$(git merge-base main HEAD)"..HEAD
  ```

  Inspect every path. Confirm the three unrelated untracked files remain untracked and absent from every feature commit.

- [ ] **Step 7: Correct a verified defect narrowly, if necessary**

  Record the failing evidence in Task 8's ledger row, add/tighten the closest owning test, observe red, make the smallest in-scope fix, and rerun the focused matrix, both full suites, POD, and `dzil test`. If a correction is real, stage only its named files and commit:

  ```bash
  git commit -m "fix: resolve composed routing verification findings"
  ```

  If there is no defect, record `no correction commit required`; do not make an empty commit.

- [ ] **Step 8: Complete the ledger and whole-feature review**

  Fill every ledger cell with actual evidence. Ensure every deviation is user-decided. Run the execution skill's final whole-feature review against the recorded base through `HEAD` and record the result. The feature is complete only when all eight rows are `complete`, every review is approved, focused/POD/packaging gates pass, both full-suite runs agree, and unrelated user files remain untouched.

---

## Required Final Evidence

The implementation handoff must report:

- the final commit range and each task commit SHA;
- exact focused and twice-run full-suite test counts;
- POD and `dzil test` results;
- whole-feature review result;
- approved deviation IDs and user decisions, or `none`;
- confirmation that the three unrelated untracked files were preserved; and
- links to `lib/PAGI/Routing/Mount.pm`, `lib/PAGI/Routing/Resolver.pm`, `lib/PAGI/Routing/Compiler.pm`, `lib/PAGI/Context.pm`, `examples/15-large-application/lib/MyApp/Root.pm`, and the completed execution ledger.
