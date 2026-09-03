# HTTP Default Request Handler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Router and Compose `http_default` treat a bare coderef as a one-`PAGI::Request` handler while continuing to accept app objects directly and requiring `as_app_object` for native coderefs.

**Architecture:** Router retains the declared default unchanged. During compilation, one shared private HTTP endpoint compiler converts both Route CODE endpoints and CODE defaults through `PAGI::Routing::RequestResponse`, while app objects compile through `PAGI::Utils::to_app`. Mount and every explicitly named `app` position retain their native three-argument coderef contract.

**Tech Stack:** Perl 5.18-compatible distribution modules; Perl 5.40 signatures only in already-modern examples; `Future`, `Future::AsyncAwait`, `PAGI::Request`, `PAGI::Routing`, `PAGI::Pages`, `PAGI::Response`, `Test2::V0`, `PAGI::Test::Client`, POD, and Dist::Zilla. No new dependency.

**Spec:** `docs/superpowers/specs/2026-09-02-http-default-request-handler-design.md`

## Global Constraints

- Work in the existing `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/.worktrees/compose-retained-router` worktree on `feature/remove-mutable-router-frontends` unless the user explicitly changes the branch mapping.
- This is a deliberate breaking correction to an unreleased API. Do not retain the former native interpretation of a bare `http_default` CODE value.
- Never inspect coderef arity, signatures, prototypes, symbol names, or anonymity.
- An HTTP handler CODE receives exactly one `PAGI::Request` and returns an immediate or Future-backed PAGI application value.
- An app object is an instantiated object with `to_app`; compile it once per Router compilation and invoke the resulting native coderef per matching request.
- `as_app_object` is the only marker for a native CODE in Route or `http_default` handler positions.
- Mount `app`, `PAGI::Utils::to_app`, and other true application positions retain native CODE semantics.
- `request_response` remains public in `PAGI::Routing`, but ordinary `http_default` declarations no longer need it.
- Preserve Router FULL/PARTIAL/NONE selection, authoritative 405/Allow behavior, nested Router ownership, Router middleware ordering, the outer HEAD boundary, and protocol-specific WebSocket/SSE misses.
- Every immediate-or-Future result is normalized with `Future->wrap`; every send Future remains awaited.
- Do not add body replay, response buffering, hidden caches, compatibility shims, or special cases for Pages/Response subclasses.
- Use strict TDD: establish the semantic RED, implement the smallest coherent compiler change, then run the named GREEN gate.
- Update every maintained example, live POD, `UPGRADING.md`, and `Changes` claim affected by the changed callable meaning. Historical design documents remain unchanged and are superseded by the new spec.
- Run the full suite once at the final integration boundary. Run `dzil build` once after the final suite; do not repeatedly run repository-wide gates between focused tasks.

---

## Work Map

Reconfirm this map before implementation, whenever scope changes, and before any push:

| Repository path | Ticket | Branch | Base branch/commit | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/.worktrees/compose-retained-router` | None; approved WIP API correction | `feature/remove-mutable-router-frontends` | `origin/main@b9cd32528a053190e9c560098f4323c78d7999bb`; planning HEAD `141f927c5dd49f9f7c089604a242a6ea79aa6538` | Router/default validation and compilation, focused tests, affected examples and live docs | Unreleased PAGI-Tools API; no CPAN release or deployment | Existing PR #28 branch, only after explicit user authorization |

Do not edit PAGI or PAGI-Server. If implementation reveals a protocol or server defect, record it as a separate follow-up and stop dependent work.

## Execution Tracking

Before Task 1, create `.superpowers/sdd/2026-09-02-http-default-request-handler/progress.md`:

```markdown
# SDD ledger — HTTP default request handler

Starting HEAD: record the exact 40-character execution SHA

| Task | Status | Implementation SHA | Review/fix SHAs | Focused verification and actual counts | Final evidence | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | pending | — | — | — | deferred to Task 4 | — |
| 2 | pending | — | — | — | deferred to Task 4 | — |
| 3 | pending | — | — | — | deferred to Task 4 | — |
| 4 | pending | — | — | — | final gate | — |

## Deviations

| ID | Status | Conflicting plan/spec text | Evidence and rationale | Affected tasks | User decision |
| --- | --- | --- | --- | --- | --- |
```

Record each focused command, actual file/assertion counts, and commit SHA before beginning a dependent task. If clean implementation requires arity inspection, response replay, duplicate HTTP adapter policy, or a Pages-specific exception, create `DEV-001`, stop, and ask the user before proceeding.

### Task 1: Establish and implement the shared HTTP endpoint-value compiler

**Files:**
- Modify: `t/routing/16-http-outcomes.t`
- Modify: `t/routing/05-http-dispatch.t`
- Modify: `lib/PAGI/Routing/Compiler.pm`
- Modify: `lib/PAGI/Routing/RequestResponse.pm`

**Interfaces:**
- Consumes: Route `endpoint` and Router `http_default`, each either CODE or an instantiated app object.
- Produces: private `PAGI::Routing::Compiler->_compile_http_endpoint($value) -> native CODE`; generalized runtime diagnostic `request handler must return a PAGI application: a native coderef or app object (an instantiated object with to_app)`.

- [ ] **Step 1: Add failing HTTP NONE handler tests.** Add a `t/routing/16-http-outcomes.t` subtest that constructs a Router with a bare CODE `http_default`, records `scalar @_`, verifies the sole argument is `PAGI::Request`, returns `PAGI::Response::Text->new('request default')`, and asserts a missing HTTP path emits that body. Invoke the compiled app twice and assert the handler runs once per miss.

```perl
my @seen;
my $app = router(
    routes => [],
    http_default => sub {
        push @seen, [scalar(@_), $_[0]];
        return PAGI::Response::Text->new('request default');
    },
)->to_app;

my $first = run_app($app, path => '/missing', raw_path => '/missing');
my $second = run_app($app, path => '/again', raw_path => '/again');
is(response_body($first), 'request default');
is(response_body($second), 'request default');
is([map { $_->[0] } @seen], [1, 1]);
isa_ok($_->[1], 'PAGI::Request') for @seen;
```

- [ ] **Step 2: Add failing normalization and failure tests.** In the same subtest group, cover an async handler returning a Future-backed Response, a handler returning a native PAGI coderef, and a handler returning `undef`. Assert both valid results are invoked against the original triplet and the invalid result fails with `request handler must return a PAGI application` before any response event is sent.

- [ ] **Step 3: Run the focused tests to verify RED.** Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/16-http-outcomes.t t/routing/05-http-dispatch.t'
```

Expected: the new bare-default test fails because the current compiler invokes the CODE with `($scope, $receive, $send)`; existing tests remain green up to that assertion.

- [ ] **Step 4: Add one private compiler path for HTTP endpoint values.** In `lib/PAGI/Routing/Compiler.pm`, add a private method with this behavior and use it from both `_compile_http_leaf` and `_compile_router_body`:

```perl
sub _compile_http_endpoint {
    my ($class, $value) = @_;
    return ref($value) eq 'CODE'
        ? PAGI::Routing::RequestResponse->new(handler => $value)->to_app
        : PAGI::Utils::to_app($value);
}
```

Replace the current duplicate Route classification in `_compile_http_leaf`. For a declared Router default, call this helper instead of `PAGI::Utils::to_app`. Keep the stock `PAGI::Pages->not_found` object on the app-object branch. Do not change dispatcher selection or middleware placement.

- [ ] **Step 5: Generalize RequestResponse's result diagnostic.** In `lib/PAGI/Routing/RequestResponse.pm`, change only the invalid-result label from `request endpoint must return a PAGI application:` to `request handler must return a PAGI application:`. Update the exact expectations in `t/routing/05-http-dispatch.t` and `t/routing/17-request-response.t`; do not restructure invocation or Future handling.

- [ ] **Step 6: Run the focused tests to verify GREEN.** Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/05-http-dispatch.t t/routing/16-http-outcomes.t t/routing/17-request-response.t'
```

Expected: all files and assertions pass; record actual counts in the ledger.

- [ ] **Step 7: Commit the shared compiler behavior.** Stage only the four files above plus the updated Task 1 ledger row and commit:

```bash
git commit -m "Treat HTTP defaults as request handlers"
```

### Task 2: Pin construction, native escape-hatch, and boundary semantics

**Files:**
- Modify: `t/routing/01-constructors.t`
- Modify: `t/routing/06-head.t`
- Modify: `t/routing/08-protocols.t`
- Modify: `t/routing/12-router-mounts.t`
- Modify: `t/integration-router-application-boundaries.t`
- Modify: `t/compose/01-description.t`
- Modify: `t/compose/02-dispatch.t`
- Modify: `lib/PAGI/Routing/Router.pm`
- Modify: `lib/PAGI/Routing/Route.pm`
- Modify: `lib/PAGI/Utils.pm`

**Interfaces:**
- Consumes: Task 1's `_compile_http_endpoint` semantics.
- Produces: synchronous placement-specific validation; direct app-object and explicit native-CODE behavior; unchanged declared-value identity.

- [ ] **Step 1: Add failing constructor and escape-hatch tests.** In `t/routing/01-constructors.t`, retain the assertion that `http_default` returns the exact declared CODE identity. Change invalid-value expectations to:

```text
router http_default must be a request handler coderef or app object (an instantiated object with to_app)
```

Add a case proving `as_app_object($native)` remains accepted and stored by identity. In `t/integration-router-application-boundaries.t`, change the Router case in the adapter table to a direct bare handler; retain `request_response($handler)` for Mount and direct native application cases.

- [ ] **Step 2: Add failing app-object and Compose tests.** Assert an app-object default has `to_app` called once per Router compilation and receives the native triplet on multiple misses. Add a Compose case whose bare CODE default receives one `PAGI::Request`, proving Compose delegates the same grammar rather than adapting independently.

- [ ] **Step 3: Run the focused constructor/boundary tests to verify RED.** Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/01-constructors.t t/routing/06-head.t t/routing/08-protocols.t t/routing/12-router-mounts.t t/integration-router-application-boundaries.t t/compose/01-description.t t/compose/02-dispatch.t'
```

Expected: the new placement-specific diagnostic fails because the validator still says `native coderef`; existing native bare-CODE defaults fail because Task 1 now correctly treats them as request handlers. The new app-object and Compose request-handler assertions pass under Task 1's shared compiler path.

- [ ] **Step 4: Make the private app-value validator position-aware.** Extend `PAGI::Utils::_validate_app_value` with an optional third argument naming the CODE role, defaulting to `native coderef` for all existing app positions:

```perl
sub _validate_app_value {
    my ($value, $label, $coderef_role) = @_;
    $label = 'application' unless defined $label && length $label;
    $coderef_role = 'native coderef'
        unless defined $coderef_role && length $coderef_role;

    if (blessed($value) && $value->can('wrap') && !$value->can('to_app')) {
        croak "$label middleware object is not an app";
    }

    my $separator = $label =~ /:\z/ ? ' ' : ' must be ';
    croak "$label${separator}a $coderef_role or app object "
        . '(an instantiated object with to_app)'
        unless defined $value
            && (ref($value) eq 'CODE'
                || (blessed($value) && $value->can('to_app')));
    return $value;
}
```

Call it from `PAGI::Routing::Router` and `PAGI::Routing::Route` with `request handler coderef`. Leave Mount, `to_app`, RequestResponse return values, Endpoint returns, and Test Client application coercion on the default `native coderef` wording.

- [ ] **Step 5: Explicitly migrate native test defaults.** Every existing test default that directly performs three-channel emission must become:

```perl
http_default => as_app_object(async sub {
    my ($scope, $receive, $send) = @_;
    return $send->({
        type => 'http.response.start',
        status => 404,
        headers => [],
    });
}),
```

Apply this only to native defaults in `t/routing/06-head.t`, `t/routing/08-protocols.t`, `t/routing/12-router-mounts.t`, and `t/integration-router-application-boundaries.t`. Import `as_app_object` explicitly where required. Do not wrap Pages/Response app objects or one-Request defaults.

- [ ] **Step 6: Verify routing boundaries remain unchanged.** Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/01-constructors.t t/routing/06-head.t t/routing/08-protocols.t t/routing/12-router-mounts.t t/integration-router-application-boundaries.t t/compose/01-description.t t/compose/02-dispatch.t'
```

Expected: all tests pass. Confirm from assertions that FULL and PARTIAL do not invoke the default, 405 retains its Allow union, WebSocket/SSE misses do not invoke it, nested Router defaults remain boundary-local, HEAD suppression remains outermost, and Compose uses the same request-handler contract.

- [ ] **Step 7: Commit construction and boundary coverage.** Stage only the files listed for Task 2 plus the updated ledger row and commit:

```bash
git commit -m "Align HTTP default validation with routes"
```

### Task 3: Migrate examples and document the positional grammar

**Files:**
- Modify: `examples/declarative-routing/app.pl`
- Verify/update: `examples/starlette-apples/app.pl`
- Verify/update: `examples/starlette-apples/README.md`
- Modify: `lib/PAGI/Routing.pm`
- Modify: `lib/PAGI/Routing/Router.pm`
- Modify: `lib/PAGI/Routing/RequestResponse.pm`
- Modify: `lib/PAGI/Compose.pm`
- Modify: `lib/PAGI/Tools/Cookbook.pod`
- Modify: `UPGRADING.md`
- Modify: `Changes`
- Test: `t/integration-declarative-routing-demo.t`
- Test: `t/integration-starlette-apples.t`
- Test: `t/00-pod/cookbook-examples.t`

**Interfaces:**
- Consumes: Tasks 1–2's final `http_default` callable contract.
- Produces: one documented handler-vs-app positional grammar and migrated maintained examples.

- [ ] **Step 1: Add or update example assertions before changing examples.** Ensure the declarative-routing integration test exercises both API and root missing paths and sees their custom bodies. Ensure the Starlette apples integration test exercises an unknown path and sees `That page does not exist in the Apple demo.` These assertions pin behavior while syntax changes.

- [ ] **Step 2: Run example tests before migration.** Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-declarative-routing-demo.t t/integration-starlette-apples.t'
```

Expected: existing behavior assertions pass. If either named test file has a different current name, locate the maintained integration test with `rg --files t | rg 'declarative|starlette|apple'`, use that exact file, and record the resolved command in the ledger before editing.

- [ ] **Step 3: Remove unnecessary request adapters from the declarative example.** In `examples/declarative-routing/app.pl`, remove `request_response` from the `PAGI::Routing` import and replace:

```perl
http_default => request_response(\&api_not_found),
http_default => request_response(\&root_not_found),
```

with:

```perl
http_default => \&api_not_found,
http_default => \&root_not_found,
```

Keep both handlers one-argument request handlers returning Pages app objects. Do not convert them into native closures.

- [ ] **Step 4: Keep the apples canary on the shortest common form.** Verify `examples/starlette-apples/app.pl` and its README continue showing:

```perl
http_default => not_found(
    detail => 'That page does not exist in the Apple demo.',
),
```

Do not wrap this app object in a closure, `request_response`, or `as_app_object`.

- [ ] **Step 5: Rewrite live API documentation around the positional rule.** Update Routing, Router, RequestResponse, Compose, and Cookbook POD with one consistent table:

```text
Route endpoint / http_default CODE  -> one Request handler
Route endpoint / http_default object -> app object via to_app
Mount app CODE                       -> native PAGI application
Mount app object                     -> app object via to_app
```

Show the direct Pages/default form first, the request-dependent custom Response second, and `as_app_object` only in the advanced native example. State that `request_response` remains appropriate for adapting a handler into Mount `app`, but not for ordinary `http_default` use.

- [ ] **Step 6: Update migration and release notes.** Add an `UPGRADING.md` before/after entry:

```perl
# Before: bare CODE was native
my $before = router(
    routes => [],
    http_default => async sub ($scope, $receive, $send) {
        return await $send->({
            type => 'http.response.start', status => 404, headers => [],
        });
    },
);

# After: bare CODE is a Request handler
my $after = router(
    routes => [],
    http_default => sub ($request) {
        return MyApp::NotFoundResponse->new(path => $request->path);
    },
);

# Native escape hatch
my $native = router(
    routes => [],
    http_default => as_app_object(
        async sub ($scope, $receive, $send) {
            return await $send->({
                type => 'http.response.start', status => 404, headers => [],
            });
        },
    ),
);
```

Add a `Changes` entry naming this as an unreleased consistency correction. Remove live claims that `http_default` is a native CODE position; do not rewrite historical plans/specs.

- [ ] **Step 7: Run documentation and example gates.** Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-declarative-routing-demo.t t/integration-starlette-apples.t t/00-pod/cookbook-examples.t'
```

Expected: all selected tests pass; record actual files and assertion counts.

- [ ] **Step 8: Audit all maintained references.** Run:

```bash
rg -n "http_default|request_response" lib t examples README.md UPGRADING.md Changes
```

Classify every bare CODE `http_default`: it must be a one-Request handler, or be wrapped with `as_app_object` if native. Confirm no live documentation calls it a native CODE position. Record the audit result in the ledger.

- [ ] **Step 9: Commit examples and documentation.** Stage only Task 3 files plus the ledger row and commit:

```bash
git commit -m "Document HTTP defaults as request handlers"
```

### Task 4: Final integration and review

**Files:**
- Modify: `.superpowers/sdd/2026-09-02-http-default-request-handler/progress.md`

**Interfaces:**
- Consumes: the complete implementation and migration.
- Produces: reviewable branch evidence with no unclassified callable boundary.

- [ ] **Step 1: Review the final diff against the spec.** Verify there are no changes to Mount semantics, Route matching, method defaults, 405 generation, middleware order, response settlement, or protocol misses. Confirm the compiler has one HTTP handler/app classification path rather than parallel Route/default implementations.

- [ ] **Step 2: Run whitespace and stale-claim checks.** Run:

```bash
git diff --check
rg -n "http_default.*native|native.*http_default|http_default\s*=>\s*request_response" lib examples README.md UPGRADING.md Changes
```

Expected: `git diff --check` succeeds. Every search hit is either an explicit before-example, a statement that the old behavior was removed, or an error requiring correction before proceeding.

- [ ] **Step 3: Run the full suite once.** Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t'
```

Expected: all tests pass. Record exact file/assertion counts and elapsed time.

- [ ] **Step 4: Build the distribution once.** Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && dzil build'
```

Expected: build succeeds with no new missing-file, POD, prerequisite, or packaging failure. Do not publish the resulting distribution.

- [ ] **Step 5: Perform final scope and work-map verification.** Run `git status -sb`, `git diff --stat`, and `git log --oneline --decorate -8`. Reconfirm repository, branch, base, owned files, deployment boundary, and push target from the Work Map. Any unexpected file or sibling-repository change stops completion.

- [ ] **Step 6: Route verified failures back to their owning task.** If Steps 1–5 reveal a defect, reopen Task 1, 2, or 3 according to the affected file, add the smallest regression assertion, fix it there, rerun that task's focused gate, and then rerun Steps 1–5. Record the fix commit in both task rows:

```bash
git commit -m "Finish HTTP default handler migration"
```

Do not create an empty Task 4 commit. Mark Task 4 complete in the ledger only after the corrected HEAD passes the full suite and build.

- [ ] **Step 7: Request independent code review.** Use `superpowers:requesting-code-review` against the spec and this plan. Resolve only verified in-scope findings, rerunning the smallest affected gate and then the final suite if HEAD changes. Do not push or update PR #28 until the user explicitly authorizes it.
