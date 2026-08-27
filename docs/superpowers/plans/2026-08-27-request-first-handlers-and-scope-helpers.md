# Request-First Handlers and Scope-Bound Helpers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `PAGI::Context` as PAGI::Routing's normal handler argument with direct protocol objects, keep `PAGI::Request` focused on HTTP input, and expose Router- and middleware-owned capabilities through strict, cheap scope-bound helpers.

**Architecture:** The shared Routing compiler materializes `PAGI::Request`, `PAGI::WebSocket`, or `PAGI::SSE` only after selecting the exact leaf scope; raw applications and all middleware remain native three-argument PAGI. A private scope-source resolver underpins small `PAGI::State`, `PAGI::Transport`, `PAGI::CSRF`, Stash, Session, and `PAGI::Routing::URL` facades without identity or scope-cache semantics. Context remains installed for deferred compatibility but Routing stops constructing it, and its reverse methods delegate to the new URL facade so there is one algorithm.

**Tech Stack:** Perl 5.18-compatible distribution code; Perl 5.40 signatures only in modern examples; `Future`, `Future::AsyncAwait`, `Exporter`, `Scalar::Util`, `PAGI::Authority`, `PAGI::Utils::SecureCompare`, `PAGI::Response`, `PAGI::Pages`, `Test2::V0`, `PAGI::Test::Client`, POD, and Dist::Zilla. No new CPAN dependency.

**Spec:** `docs/superpowers/specs/2026-08-27-request-first-handlers-and-scope-helpers-design.md` at commit `d378d107a710652aee782fdba15d95d5719f1ce2`

## Global Constraints

- The approved contract is the specification above. If implementation evidence conflicts with it, record a deviation and obtain the user's decision before dependent work continues.
- This campaign follows the already-implemented 2026-08-26 routing-composition campaign at `1d780068088ea0c9080e1e9ad72ab3321f9644bc`; do not reintroduce `group`, positional Mounts, trace-based declines, Compose-owned routing fallbacks, or multiprotocol Router `default`.
- Work only in `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` or an isolated worktree created for this repository through the Superpowers worktree workflow.
- Preserve the unrelated untracked files `.pagi-0.4-alignment-tools-review.md`, `.pagi-0.4-alignment-tools-rulings.md`, and pre-existing state under `.superpowers/`. Never stage them.
- Keep every file under `lib/` and every ordinary test parseable on Perl 5.18. Use classic `@_` unpacking and avoid signatures, postfix dereferencing, `try`/`catch`, and newer syntax there. Existing Perl 5.40 examples may use signatures.
- Use installed Perl 5.16.3 for syntax-only compatibility gates. Passing that stricter parser is evidence for the declared Perl 5.18 floor; functional tests run under project Perl 5.42.2.
- Normal Routing handlers receive one direct protocol object: HTTP receives `PAGI::Request`, WebSocket receives `PAGI::WebSocket`, and SSE receives `PAGI::SSE`. Do not retain Context-handler detection, aliases, or dual dispatch.
- Raw Route targets, Mount children, Router `http_default`, Compose targets, and middleware remain native `($scope, $receive, $send)` PAGI applications.
- HTTP handlers may return an immediate Response or a Future resolving to one. Always use `Future->wrap`; never directly await a possibly immediate value. The adapter calls `$response->respond($send)` exactly once.
- `PAGI::Request->new($scope, $receive)` requires an unblessed explicit HTTP scope and a receive coderef. It does not accept `$send`, infer missing type, or dispatch custom event types.
- Request retains HTTP input/body parsing, `scope`, `raw`, `path_params`, `state`, `has_state`, `connection`, and tri-state `is_disconnected`. Do not add URL, Stash, Session, CSRF, Transport, send, or outgoing response shortcuts.
- Do not remove `PAGI::Request->response`, deprecated query/form aliases, `PAGI::Request->raw`, the Context family, or standalone `PAGI::Endpoint::HTTP`, `::WebSocket`, and `::SSE`; those are explicitly deferred.
- Export `app_state`, never `state`. Under `use v5.40`, `state($request)` is a Perl declarator and silently does not call an imported sub.
- `PAGI::State` is read-oriented: strict/default `get`, `exists`, `keys`, and `data`; no `set` or `delete`. Absent state returns `undef`, an empty hash is present, and malformed state croaks.
- State's temporary `%{}` overload warns once per package/file/line unless `PAGI_SILENCE_STATE_HASHREF_WARNING` is exactly `1`. It preserves dereference syntax, not `ref(...) eq 'HASH'` or HashRef type acceptance.
- Every scope-bound helper accepts exactly one unblessed scope hashref or one blessed object whose `scope` returns an unblessed scope hashref. Package strings, malformed objects, missing sources, and extra constructor arguments croak.
- Helpers are cheap per-call facades. Do not store helper objects or helper-cache records in scope, promise referential identity, use weak-reference lifecycle machinery, or rebuild a Routing Resolver.
- Capability absence follows ownership: optional State and Transport return `undef`; Stash creates its backing hash; URL, Session, and CSRF croak when their Router/middleware provider is absent.
- All helper exports are opt-in, provide uppercase `:ALL`, and provide no lowercase `:all` tag or default exports.
- `PAGI::Routing::URL` owns handler-bound reverse lookup and preserves the approved absolute/relative names, capture inheritance, params/query/fragment forms, root path, route-kind schemes, constraint validation, and `PAGI::Authority` behavior. `PAGI::Routing::Router->path_for` remains placement independent.
- Keep one reverse implementation: rename the Resolver's Context-specific entry point to a neutral scope-bound operation; old Context methods may delegate to URL, but URL must not depend on Context.
- `PAGI::Pages` receives only the minimal scope-bearing Request source seam. Do not redesign its rendering, catalog, negotiation, favicon, or retained one-argument/three-argument endpoint interoperability contract.
- Pure middleware continues to receive native PAGI arguments. Do not add a Request middleware convention or value-flow `$next`.
- Put public POD beside every changed public constructor, export, method, diagnostic, and compatibility boundary in the task that changes it. The documentation task reconciles README, Tutorial, Cookbook, examples, `UPGRADING.md`, and Changes.
- Use TDD for each task: write focused failing assertions, run them and record the semantic failure, implement the minimum contract, rerun the focused files, then run the named task gate.
- Use `PAGI::Test::Client` for complete HTTP requests. Use direct scope/receive/send recorders for WebSocket, SSE, exact protocol object identity, event ownership, malformed invocation, or middleware behavior.
- Stage only files named by the current task. Never use `git add .` or `git add -A`. `docs/superpowers` is ignored; use `git add -f` only for this exact plan path.
- Every implementation task ends with one focused commit and an independent review gate. The coordinator verifies the diff, test output, commit SHA, and ledger row before dependent work starts.
- Run the repository-wide `prove -lr t` suite exactly once at the final reviewed HEAD. Focused tests may run as often as TDD requires. Do not run `dzil test`, because it repeats the suite. If the final suite exposes a defect and HEAD changes, record the failure and run one new final suite at the corrected HEAD.
- Run functional Perl commands through the project Perl, for example:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/request-state.t'
  ```

## Work Map

Record and reconfirm this map before implementation, whenever architecture or ticket scope changes, and before any authorized push:

| Repository | Ticket | Execution branch | Base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | Request-first handlers and scope-bound helpers | isolated feature branch/worktree created by the selected execution skill | `main@d378d107a710652aee782fdba15d95d5719f1ce2` | Exact modules, tests, examples, POD, README, Tutorial, Cookbook, `UPGRADING.md`, Changes, and audit evidence named below | Unreleased PAGI-Tools `0.002003`; no deployment or CPAN release in this plan | None unless the user separately authorizes publication |

## Execution Tracking and Deviation Control

Before Task 1, create the isolated execution workspace using the selected execution skill. For subagent-driven development, run:

```bash
/Users/jnapiorkowski/.codex/plugins/cache/openai-curated-remote/superpowers/6.3.0/skills/subagent-driven-development/scripts/sdd-workspace docs/superpowers/plans/2026-08-27-request-first-handlers-and-scope-helpers.md
```

The command must print a directory ending in `.superpowers/sdd/2026-08-27-request-first-handlers-and-scope-helpers`. Create `progress.md` there with this exact initial structure:

```markdown
# SDD ledger — plan: docs/superpowers/plans/2026-08-27-request-first-handlers-and-scope-helpers.md

Starting HEAD: d378d107a710652aee782fdba15d95d5719f1ce2

| Task | Status | Commit range | Focused verification | Full-suite verification | Review |
|---|---|---|---|---|---|
| 1 | pending | — | — | deferred to Task 12 | — |
| 2 | pending | — | — | deferred to Task 12 | — |
| 3 | pending | — | — | deferred to Task 12 | — |
| 4 | pending | — | — | deferred to Task 12 | — |
| 5 | pending | — | — | deferred to Task 12 | — |
| 6 | pending | — | — | deferred to Task 12 | — |
| 7 | pending | — | — | deferred to Task 12 | — |
| 8 | pending | — | — | deferred to Task 12 | — |
| 9 | pending | — | — | deferred to Task 12 | — |
| 10 | pending | — | — | deferred to Task 12 | — |
| 11 | pending | — | — | deferred to Task 12 | — |
| 12 | pending | — | — | final gate | — |

## Deviations

| ID | Status | Conflicting plan text | Evidence and rationale | Affected tasks | User decision |
|---|---|---|---|---|---|
```

Write the exact 40-character starting SHA plus one newline to `.superpowers/sdd/2026-08-27-request-first-handlers-and-scope-helpers/starting-head`. Record `git status --short`, including every preserved untracked artifact. The coordinator owns the ledger and updates a row in the same working step as its commit/review with exact commands, exit status, actual file/assertion counts, elapsed time, commit SHA, and review evidence.

A contract conflict gets the next stable ID (`DEV-001`, `DEV-002`, then sequentially), status `awaiting decision`, the exact conflicting text, concrete evidence, and every blocked task. Record the user's explicit decision before dependent work continues. An ordinary defect whose fix preserves the approved contract is not a deviation.

## File and Responsibility Map

- `lib/PAGI/Utils/Scope.pm`: private exact-arity scope-source recognition and resolution shared by helper modules and Pages.
- `lib/PAGI/Request.pm`: strict HTTP input object, server tuple, State access, minimal connection access, and existing body-consumption machine.
- `lib/PAGI/State.pm`: optional read-oriented lifespan-state facade and warned hash-dereference bridge; exports `app_state` only.
- `lib/PAGI/Stash.pm` and `lib/PAGI/Session.pm`: mutable scope-backed facades with strict constructors and opt-in factories; their `from_data` test constructors remain direct.
- `lib/PAGI/CSRF.pm`: middleware-required token/verification facade using the shared timing-safe comparison utility.
- `lib/PAGI/Transport.pm`: optional outbound transport facade and watermark/callback capability degradation.
- `lib/PAGI/Routing/URL.pm`: handler-bound URL/path generation facade and opt-in `url`, `url_for`, and `path_for` exports.
- `lib/PAGI/Routing/Resolver.pm`: single neutral scope-bound reverse-rendering implementation plus existing rooted Router rendering.
- `lib/PAGI/Context.pm`: deferred compatibility object whose old reverse methods delegate to URL; no new responsibility.
- `lib/PAGI/Pages.pm`: minimal scope-bearing Request acceptance and metadata-only Request construction.
- `lib/PAGI/Routing/Compiler.pm`: exact selected protocol-object materialization and HTTP Response adapter.
- `lib/PAGI/App/Router.pm`: mutable frontend documentation of the shared direct handler contract; no independent adapter.
- `lib/PAGI/Endpoint/Router.pm` and `Builder.pm`: method-oriented frontend, `new_request`, and method binding to direct protocol objects.
- Request, helper, Routing, Context, Pages, App Router, Endpoint Router, integration, and upgrade tests: focused behavior coverage without helper identity or dual Context dispatch.
- `examples/starlette-apples`, `examples/15-large-application`, `examples/declarative-routing`, `examples/endpoint-router-demo`, and other normal-Routing examples: canonical Request/Response/helper forms.
- Public POD, `README.md`, `lib/PAGI/Tools/Tutorial.pod`, `lib/PAGI/Tools/Cookbook.pod`, `UPGRADING.md`, and Changes: one coherent ownership model, deliberate Starlette Request divergence, and downstream handoff.

---

### Task 1: Add One Private Scope-Source Contract

**Files:**

- Create: `lib/PAGI/Utils/Scope.pm`
- Create: `t/utils-scope-source.t`
- Modify: `t/00-load.t`

**Interfaces:**

- Produces `PAGI::Utils::Scope::is_scope_source($value) -> bool`, true only for an unblessed hashref or blessed object with `scope`.
- Produces `PAGI::Utils::Scope::scope_from_source($owner, @arguments) -> unblessed HASH`, enforcing exactly one source and validating the returned scope.
- This is an internal module with no exports and no public cache or identity behavior.

- [ ] **Step 1: Write the failing source-shape matrix.** In `t/utils-scope-source.t`, define `Local::Bearer`, `Local::BadScope`, and `Local::DiesScope`, then assert:

  ```perl
  my $scope = { type => 'http' };
  is(scope_from_source('Widget', $scope), exact_ref($scope),
      'an unblessed scope is returned by identity');
  is(scope_from_source('Widget', Local::Bearer->new($scope)), exact_ref($scope),
      'a scope-bearing object resolves to its exact scope');
  ok(is_scope_source($scope), 'scope is a source candidate');
  ok(is_scope_source(Local::Bearer->new($scope)), 'bearer is a candidate');
  ok(!is_scope_source('Local::Bearer'), 'package string is not a source');
  like(dies { scope_from_source('Widget') }, qr/Widget.*exactly one.*scope/i);
  like(dies { scope_from_source('Widget', $scope, 1) }, qr/Widget.*exactly one/i);
  like(dies { scope_from_source('Widget', []) }, qr/Widget.*scope hashref.*scope method/i);
  like(dies { scope_from_source('Widget', Local::BadScope->new) },
      qr/Widget.*scope\(\).*unblessed hashref/i);
  ```

- [ ] **Step 2: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/utils-scope-source.t t/00-load.t'
  ```

  Expected: `PAGI/Utils/Scope.pm` cannot be loaded and the new API is undefined.

- [ ] **Step 3: Implement the private resolver.** Use classic Perl syntax and preserve exceptions thrown by an object's own `scope` method:

  ```perl
  package PAGI::Utils::Scope;
  use strict;
  use warnings;
  use Carp qw(croak);
  use Scalar::Util qw(blessed);

  sub is_scope_source {
      my ($value) = @_;
      return 1 if ref($value) eq 'HASH' && !blessed($value);
      return blessed($value) && $value->can('scope') ? 1 : 0;
  }

  sub scope_from_source {
      my ($owner, @arguments) = @_;
      croak "$owner requires exactly one scope hashref or object with scope()"
          unless @arguments == 1;
      my $source = $arguments[0];
      my $scope = ref($source) eq 'HASH' && !blessed($source)
          ? $source
          : blessed($source) && $source->can('scope')
              ? $source->scope
              : undef;
      croak "$owner requires an unblessed scope hashref or object with scope()"
          unless ref($scope) eq 'HASH' && !blessed($scope);
      return $scope;
  }

  1;
  ```

- [ ] **Step 4: Register loadability and run GREEN.** Add `PAGI::Utils::Scope` to `t/00-load.t`, rerun Step 2, then run:

  ```bash
  perlbrew exec --with perl-5.16.3 perl -Ilib -c lib/PAGI/Utils/Scope.pm
  git diff --check
  ```

  Expected: focused tests pass, syntax reports `OK`, and diff check is silent.

- [ ] **Step 5: Commit and update the ledger.** Stage exactly the three files and commit:

  ```bash
  git add lib/PAGI/Utils/Scope.pm t/utils-scope-source.t t/00-load.t
  git commit -m "refactor: define scope-bound helper sources"
  ```

### Task 2: Make Request a Strict HTTP Input Object

**Files:**

- Modify: `lib/PAGI/Request.pm`
- Modify: `lib/PAGI/Pages.pm`
- Modify: `lib/PAGI/Response.pm`
- Modify: `t/request/01-basic.t`
- Modify: `t/request/02-query-params.t`
- Modify: `t/request/03-cookies.t`
- Modify: `t/request/05-auth.t`
- Modify: `t/request/06-stash.t`
- Modify: `t/request/07-params.t`
- Modify: `t/request/08-body.t`
- Modify: `t/request/09-form.t`
- Modify: `t/request/12-uploads.t`
- Modify: `t/request/14-response.t`
- Modify: `t/request-body-stream.t`
- Modify: `t/request-negotiate.t`
- Modify: `t/request-stash.t`
- Modify: `t/request-state.t`
- Modify: `t/request/multipart-stream-e2e.t`
- Modify: `t/request/multipart-stream-integration.t`
- Modify: `t/response-convenience.t`
- Modify: `t/middleware/11-url-handling.t`

**Interfaces:**

- `PAGI::Request->new($scope, $receive) -> PAGI::Request` requires an unblessed `type => 'http'` scope and receive coderef.
- Adds `server() -> scope server tuple or undef` without using it as public authority.
- Retains `scope` as canonical raw access, `raw` as deferred alias, all input/body methods, `response`, and current state behavior until Task 3.
- Retains only `connection()` and changes `is_disconnected()` to return `undef` without `pagi.connection`; removes direct `is_connected`, reason, callback, Future, and outbound Transport forwarding methods.
- Metadata-only Pages/Response callers pass a private receive coderef that fails if unexpectedly consumed; no optional constructor mode is added.

- [ ] **Step 1: Add strict constructor, server, and connection RED assertions.** In `t/request/01-basic.t`, define `$receive = sub { Future->fail('body unavailable') }` and assert:

  ```perl
  like(dies { PAGI::Request->new({ type => 'http' }) }, qr/receive coderef/i);
  like(dies { PAGI::Request->new({ headers => [] }, $receive) }, qr/scope type is required/i);
  like(dies { PAGI::Request->new({ type => 'sse' }, $receive) }, qr/requires HTTP scope.*sse/i);
  like(dies { PAGI::Request->new(bless({}, 'Local::Scope'), $receive) },
      qr/unblessed scope hashref/i);
  is(PAGI::Request->new({ type => 'http', server => ['127.0.0.1', 8080] }, $receive)->server,
      ['127.0.0.1', 8080], 'server returns the local endpoint tuple');
  is(PAGI::Request->new({ type => 'http' }, $receive)->server, undef,
      'server is optional');
  ```

  Add connection assertions that absent `is_disconnected` is `undef`, connected is false, disconnected is true, and the removed forwarding methods are not in `PAGI::Request->can(...)`.

- [ ] **Step 2: Make every existing Request construction explicit.** In the named tests, pass the real receive callback where body consumption is under test and a local failing/no-body coderef where only metadata is read. Update Pages and Response internal metadata-only Request construction to pass:

  ```perl
  my $no_body = sub {
      return Future->fail('metadata-only Request cannot consume a body');
  };
  my $request = PAGI::Request->new($scope, $no_body);
  ```

  Do not add an optional receive default to Request.

- [ ] **Step 3: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t/request t/request-body-stream.t t/request-negotiate.t t/request-stash.t t/request-state.t t/request/multipart-stream-e2e.t t/request/multipart-stream-integration.t t/response-convenience.t t/middleware/11-url-handling.t'
  ```

  Expected: strict-constructor and `server` assertions fail; absent connection currently reports disconnected; removed methods still exist.

- [ ] **Step 4: Implement the narrow Request surface.** Validate before blessing:

  ```perl
  sub new {
      my ($class, $scope, $receive) = @_;
      croak 'PAGI::Request requires an unblessed scope hashref'
          unless ref($scope) eq 'HASH' && !blessed($scope);
      my $type = $scope->{type};
      croak 'PAGI::Request scope type is required'
          unless defined($type) && !ref($type) && length($type);
      croak "PAGI::Request requires HTTP scope; received '$type'"
          unless $type eq 'http';
      croak 'PAGI::Request requires a receive coderef'
          unless ref($receive) eq 'CODE';
      return bless { scope => $scope, receive => $receive }, $class;
  }

  sub server { shift->{scope}{server} }

  sub is_disconnected {
      my $connection = shift->connection;
      return undef unless $connection;
      return $connection->is_connected ? 0 : 1;
  }
  ```

  Delete only the advanced Request lifecycle and outbound flow-control delegates named by the spec. Leave Context, WebSocket, and SSE delegates unchanged.

- [ ] **Step 5: Update Request POD and run GREEN.** Document strict construction, local `server` versus validated `host`, tri-state disconnect, direct advanced access through `connection`, and deferred `response`/`raw`. Run Step 3, then:

  ```bash
  perlbrew exec --with perl-5.16.3 perl -Ilib -c lib/PAGI/Request.pm
  perlbrew exec --with perl-5.16.3 perl -Ilib -c lib/PAGI/Pages.pm
  perlbrew exec --with perl-5.16.3 perl -Ilib -c lib/PAGI/Response.pm
  podchecker lib/PAGI/Request.pm
  git diff --check
  ```

- [ ] **Step 6: Commit and update the ledger.** Stage exactly the Task 2 files and commit:

  ```bash
  git add lib/PAGI/Request.pm lib/PAGI/Pages.pm lib/PAGI/Response.pm t/request/01-basic.t t/request/02-query-params.t t/request/03-cookies.t t/request/05-auth.t t/request/06-stash.t t/request/07-params.t t/request/08-body.t t/request/09-form.t t/request/12-uploads.t t/request/14-response.t t/request-body-stream.t t/request-negotiate.t t/request-stash.t t/request-state.t t/request/multipart-stream-e2e.t t/request/multipart-stream-integration.t t/response-convenience.t t/middleware/11-url-handling.t
  git commit -m "refactor: narrow Request to HTTP input"
  ```

### Task 3: Add Strict Application State

**Files:**

- Create: `lib/PAGI/State.pm`
- Create: `t/state.t`
- Modify: `lib/PAGI/Request.pm`
- Rewrite: `t/request-state.t`
- Modify: `t/00-load.t`

**Interfaces:**

- `PAGI::State->new($source) -> PAGI::State|undef` and exported `app_state($source)` use Task 1 source normalization; no `state` export exists.
- `get($key)` is strict; `get($key, $default)`, `exists`, `keys`, and `data` are read-oriented; no `set`/`delete`.
- `%{}` overload returns the backing hash and warns once per external package/file/line unless `PAGI_SILENCE_STATE_HASHREF_WARNING` is exactly `1`.
- `$request->has_state -> bool` validates present shape; `$request->state -> PAGI::State|undef` follows the same construction rules without identity guarantees.

- [ ] **Step 1: Write RED tests for construction, exports, and data access.** In `t/state.t`, use `Exporter` imports in local packages to prove no defaults, `app_state`, uppercase `:ALL`, and absence of `state`. Include:

  ```perl
  my $scope = { type => 'http', state => { db => 'pool' } };
  my $state = app_state($scope);
  isa_ok($state, ['PAGI::State']);
  is($state->get('db'), 'pool');
  is($state->get('optional', undef), undef);
  like(dies { $state->get('typo') }, qr/State key 'typo'.*db/i);
  ok($state->exists('db'));
  is([$state->keys], ['db']);
  is($state->data, exact_ref($scope->{state}));
  ok(!$state->can('set') && !$state->can('delete'));
  is(app_state({ type => 'http' }), undef, 'absent state is optional');
  isa_ok(app_state({ type => 'http', state => {} }), ['PAGI::State']);
  like(dies { app_state({ type => 'http', state => [] }) }, qr/state.*hashref/i);
  ```

  Compile a string under `use v5.40` importing `app_state` to prove the function is invoked, and assert importing `state` fails.

- [ ] **Step 2: Add RED tests for overload limitations and warning policy.** Capture warnings for two dereferences on one line/callsite, a second callsite, suppression values `1`, `0`, empty, and missing. Assert:

  ```perl
  is($state->{db}, 'pool', 'deprecated dereference still works');
  isnt(ref($state), 'HASH', 'overload does not fake hashref identity');
  is(ref($state->data), 'HASH', 'data is the explicit raw escape');
  is($state->get('db'), 'pool', 'methods do not recurse through hash overload');
  ```

- [ ] **Step 3: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/state.t t/request-state.t t/00-load.t'
  ```

  Expected: State cannot load, `app_state` is unavailable, and Request still returns a hashref/empty hash.

- [ ] **Step 4: Implement State without hash-overload recursion.** Bless an arrayref, not the backing hash, so private access is not intercepted:

  ```perl
  use overload '%{}' => '_deprecated_hashref', fallback => 1;

  sub new {
      my ($class, @arguments) = @_;
      my $scope = PAGI::Utils::Scope::scope_from_source($class, @arguments);
      return undef unless exists $scope->{state};
      croak 'PAGI::State requires scope state to be a hashref'
          unless ref($scope->{state}) eq 'HASH';
      return bless [$scope->{state}], $class;
  }

  sub app_state { return __PACKAGE__->new(@_) }
  sub data { return $_[0][0] }
  ```

  Implement warning callsite discovery by walking `caller($level)` past `PAGI::State` and `overload`, keying a lexical `%WARNED` by package/file/line. The overload returns `$self->[0]`; never access private storage through `$self->{...}`.

- [ ] **Step 5: Integrate Request.** Implement:

  ```perl
  sub has_state {
      my $self = shift;
      return 0 unless exists $self->{scope}{state};
      croak 'PAGI::Request state must be a hashref'
          unless ref($self->{scope}{state}) eq 'HASH';
      return 1;
  }

  sub state {
      my $self = shift;
      require PAGI::State;
      return PAGI::State->new($self);
  }
  ```

  Rewrite `t/request-state.t` around absent/empty/malformed State, `has_state`, strict access, stash separation, and unspecified repeated-object identity.

- [ ] **Step 6: Run GREEN, syntax, and POD gates.** Run Step 3, then:

  ```bash
  perlbrew exec --with perl-5.16.3 perl -Ilib -c lib/PAGI/State.pm
  perlbrew exec --with perl-5.16.3 perl -Ilib -c lib/PAGI/Request.pm
  podchecker lib/PAGI/State.pm
  podchecker lib/PAGI/Request.pm
  git diff --check
  ```

- [ ] **Step 7: Commit and update the ledger.** Stage exactly five files and commit:

  ```bash
  git add lib/PAGI/State.pm lib/PAGI/Request.pm t/state.t t/request-state.t t/00-load.t
  git commit -m "feat: add strict application state"
  ```

### Task 4: Normalize Stash and Session Factories

**Files:**

- Modify: `lib/PAGI/Stash.pm`
- Modify: `lib/PAGI/Session.pm`
- Modify: `t/stash.t`
- Modify: `t/request-stash.t`
- Modify: `t/request/06-stash.t`
- Modify: `t/middleware/session/helper.t`

**Interfaces:**

- `PAGI::Stash->new($source)` and exported `stash($source)` accept exactly one Task 1 source and lazily create `pagi.stash`.
- `PAGI::Session->new($source)` and exported `session($source)` accept exactly one Task 1 source and require `pagi.session`.
- Both expose named export plus uppercase `:ALL`, no default exports, and no identity guarantee.
- Existing `from_data($hashref)` and data/mutation/lifecycle methods are unchanged.

- [ ] **Step 1: Add RED export and strict-arity matrices.** For each class assert class/factory behavior over raw scope and `PAGI::Request`, shared backing data across separate facades, no referential-identity assertion, no default symbols, uppercase `:ALL`, lowercase `:all` rejection, malformed source errors, and extra-argument errors. Preserve direct `from_data` tests.

- [ ] **Step 2: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/stash.t t/request-stash.t t/request/06-stash.t t/middleware/session/helper.t'
  ```

  Expected: imports fail, constructors still ignore extra arguments, and source diagnostics differ.

- [ ] **Step 3: Implement opt-in factories and shared source resolution.** In each module add:

  ```perl
  use Exporter 'import';
  our @EXPORT_OK = qw(stash);          # session in PAGI::Session
  our %EXPORT_TAGS = (ALL => [@EXPORT_OK]);

  sub stash { return __PACKAGE__->new(@_) }
  ```

  Replace bespoke constructor branching with `PAGI::Utils::Scope::scope_from_source($class, @args)`. Stash initializes `pagi.stash`; Session croaks with `PAGI::Session requires Session middleware (missing pagi.session)` when absent. Do not write facade/cache keys into scope.

- [ ] **Step 4: Update POD and run GREEN.** Run Step 2, then syntax-check both modules under Perl 5.16.3, run `podchecker` on both, and run `git diff --check`.

- [ ] **Step 5: Commit and update the ledger.** Stage exactly six files and commit:

  ```bash
  git add lib/PAGI/Stash.pm lib/PAGI/Session.pm t/stash.t t/request-stash.t t/request/06-stash.t t/middleware/session/helper.t
  git commit -m "feat: export scope-bound stash and session"
  ```

### Task 5: Add CSRF and Transport Facades

**Files:**

- Create: `lib/PAGI/CSRF.pm`
- Create: `lib/PAGI/Transport.pm`
- Create: `t/csrf-helper.t`
- Rewrite: `t/transport-helpers.t`
- Modify: `t/33-csrf-timing-safe.t`
- Modify: `lib/PAGI/Middleware/CSRF.pm`
- Modify: `t/00-load.t`

**Interfaces:**

- `PAGI::CSRF->new($source)` and `csrf($source)` require a defined, nonempty, non-reference `csrf_token`; `token` reads it and `verify($submitted)` uses `PAGI::Utils::SecureCompare::secure_compare`.
- `PAGI::Transport->new($source)` and `transport($source)` return `undef` without `pagi.transport`, require `buffered_amount` when present, and wrap optional watermarks/callbacks.
- Both export only their named factory and uppercase `:ALL`; neither caches in scope.
- Existing Context CSRF and Context/WebSocket/SSE transport convenience remains until deferred cleanup; Request transport methods were removed by Task 2.

- [ ] **Step 1: Write CSRF RED tests.** Cover raw scope and Request sources, no/default/`:ALL` exports, missing key, undef/empty/reference token rejection, exact token retrieval, matching/mismatching/missing/empty submitted values, timing-safe utility delegation, no token text in diagnostics, strict arity, and two independent facades reading the same backing token.

- [ ] **Step 2: Rewrite Transport tests around the facade.** Preserve full and read-only mock handles, then assert:

  ```perl
  is(transport({ type => 'http' }), undef, 'transport is optional');
  my $flow = transport({ type => 'http', 'pagi.transport' => $handle });
  is($flow->buffered_amount, 4096);
  is($flow->high_water_mark, 65536);
  ok($flow->is_writable);
  is($flow->on_drain($cb), exact_ref($flow), 'callback registration chains');
  like(dies { transport({ 'pagi.transport' => bless({}, 'Bad') }) },
      qr/transport.*buffered_amount/i);
  ```

  Test missing watermark methods as `undef`, missing callbacks as chaining no-ops, at/above-high as not writable, no cache keys added to scope, and source support for Request/WebSocket/SSE.

- [ ] **Step 3: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/csrf-helper.t t/33-csrf-timing-safe.t t/transport-helpers.t t/00-load.t'
  ```

  Expected: new modules cannot load and old transport tests still target convenience methods.

- [ ] **Step 4: Implement CSRF and Transport.** Use Task 1 resolution and the Task 4 Exporter shape. CSRF stores the resolved scope and reads its token at operation time. Transport stores only the provided handle in its facade; use `can` before optional calls and return `$self` from callbacks.

- [ ] **Step 5: Reconcile CSRF middleware POD.** Replace Context-only `csrf_verify` recommendations with `use PAGI::CSRF qw(csrf)` normal-handler and raw-scope examples while noting the surviving Context compatibility method. Do not change token generation or middleware enforcement.

- [ ] **Step 6: Run GREEN, syntax, and POD gates.** Run Step 3; syntax-check both new modules and CSRF middleware under Perl 5.16.3; run `podchecker` on all three; run `git diff --check`.

- [ ] **Step 7: Commit and update the ledger.** Stage exactly seven files and commit:

  ```bash
  git add lib/PAGI/CSRF.pm lib/PAGI/Transport.pm lib/PAGI/Middleware/CSRF.pm t/csrf-helper.t t/transport-helpers.t t/33-csrf-timing-safe.t t/00-load.t
  git commit -m "feat: add CSRF and transport facades"
  ```

### Task 6: Move Handler-Bound Reverse Routing to URL

**Files:**

- Create: `lib/PAGI/Routing/URL.pm`
- Create: `t/routing/13-url-helper.t`
- Modify: `lib/PAGI/Routing/Resolver.pm`
- Modify: `lib/PAGI/Context.pm`
- Modify: `t/context/12-routing-reverse.t`
- Modify: `t/routing/03-reverse-inspection.t`
- Modify: `t/routing/12-router-mounts.t`
- Modify: `t/00-load.t`

**Interfaces:**

- `PAGI::Routing::URL->new($source)`, `url($source)`, `path_for($source, $reference, @args)`, and `url_for(...)` accept Task 1 sources; object methods and functional delegates share the same subs without changing return type by arity.
- `PAGI::Routing::Resolver->reverse_for_scope($operation, $scope, $reference, $root_path, $logical_namespace, $captures, @args)` replaces `reverse_for_context` and preserves all rendering.
- Context `path_for` and `url_for` instantiate/delegate to URL; URL has no Context dependency.
- URL facade identity is unspecified and no facade/cache key enters scope.

- [ ] **Step 1: Port the complete Context reverse matrix to the new facade.** In `t/routing/13-url-helper.t`, build real compiled Router frames and cover absolute/relative references, `.`/`..`, namespace failures, capture inheritance and override, compact/named params-query-fragment forms, root path, nested Mounts, HTTP/HTTPS/WS/WSS schemes, Type::Tiny/regex/coderef constraints, duplicate Host rejection, malformed/missing/versioned frames, and raw scope plus Request/WebSocket/SSE sources.

- [ ] **Step 2: Add export and identity-free assertions.** Assert no defaults, `url/url_for/path_for`, uppercase `:ALL`, lowercase rejection, strict source arity, equivalent output from two facade instances, and absence of helper/cache keys after use. Construct a facade before updating a test frame's selected leaf, then prove operation-time lookup sees the later valid frame.

- [ ] **Step 3: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/13-url-helper.t t/context/12-routing-reverse.t t/routing/03-reverse-inspection.t t/routing/12-router-mounts.t t/00-load.t'
  ```

  Expected: URL cannot load, Resolver has only the Context-named entry point, and exports are absent.

- [ ] **Step 4: Implement URL and neutralize Resolver.** Use one dual object/function entry shape:

  ```perl
  sub url { return __PACKAGE__->new(@_) }

  sub path_for {
      my ($source, @args) = @_;
      my $self = blessed($source) && $source->isa(__PACKAGE__)
          ? $source : __PACKAGE__->new($source);
      return $self->_path_for(@args);
  }
  ```

  Store the exact scope in the facade. Move Context's frame validation into URL, requiring Resolver `reverse_for_scope`. Rename Context-specific diagnostics to `scope-bound reverse operation`. Do not copy `_render_reverse*` logic or Resolver records into URL.

- [ ] **Step 5: Delegate surviving Context methods.** Replace Context's `_routing_frame`, path, and URL implementation with lazy URL delegation:

  ```perl
  sub path_for {
      my $self = shift;
      require PAGI::Routing::URL;
      return PAGI::Routing::URL->new($self)->path_for(@_);
  }
  ```

  Keep Context's public methods and POD marked compatibility; remove its direct Resolver dependency only if no other method needs it.

- [ ] **Step 6: Run GREEN, syntax, and POD gates.** Run Step 3; syntax-check URL, Resolver, and Context under Perl 5.16.3; run `podchecker` on all three; run `git diff --check`.

- [ ] **Step 7: Commit and update the ledger.** Stage exactly eight files and commit:

  ```bash
  git add lib/PAGI/Routing/URL.pm lib/PAGI/Routing/Resolver.pm lib/PAGI/Context.pm t/routing/13-url-helper.t t/context/12-routing-reverse.t t/routing/03-reverse-inspection.t t/routing/12-router-mounts.t t/00-load.t
  git commit -m "feat: expose scope-bound routing URLs"
  ```

### Task 7: Let Pages Accept Request Sources

**Files:**

- Modify: `lib/PAGI/Pages.pm`
- Modify: `t/pages/03-invocation-composition.t`
- Modify: `t/pages/02-rendering-negotiation.t`

**Interfaces:**

- Pages recognizes any Task 1 scope source and validates that its resolved scope is explicit HTTP.
- A Pages endpoint invoked with one Request returns a Response; three native arguments still send and return a Future.
- Pages keeps all rendering, negotiation, status-field, and endpoint semantics unchanged.

- [ ] **Step 1: Add Request-source RED tests.** Construct a strict Request with receive callback and exercise class and configured-instance `welcome`, named error, status, and redirect methods. Invoke generated endpoints with one Request and assert a Response with negotiated representation. Add malformed scope-bearing object, non-HTTP object, one-versus-three arity, ignored callback-metadata rejection, and native-send preservation tests.

- [ ] **Step 2: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/pages/03-invocation-composition.t t/pages/02-rendering-negotiation.t'
  ```

  Expected: Request is not a Context candidate and endpoint invocation croaks.

- [ ] **Step 3: Generalize only source recognition.** Replace `_is_context_candidate` with Task 1 `is_scope_source`; resolve through `scope_from_source('PAGI::Pages', $source)`, then retain explicit HTTP validation. Preserve exact one-argument Response and three-argument send branches; do not accept two arguments or arbitrary metadata.

- [ ] **Step 4: Update Pages POD and run GREEN.** Document Request as the normal handler form, scope as immediate/raw response source, and native three-argument endpoint as the retained interoperability exception. Run Step 2, Perl 5.16.3 syntax, Pages POD, and diff check.

- [ ] **Step 5: Commit and update the ledger.** Stage exactly three files and commit:

  ```bash
  git add lib/PAGI/Pages.pm t/pages/03-invocation-composition.t t/pages/02-rendering-negotiation.t
  git commit -m "feat: accept Request in Pages handlers"
  ```

### Task 8: Materialize Direct Protocol Objects in Routing

**Files:**

- Modify: `lib/PAGI/Routing/Compiler.pm`
- Modify: `lib/PAGI/Routing.pm`
- Modify: `lib/PAGI/Routing/Route.pm`
- Modify: `t/routing/05-http-dispatch.t`
- Modify: `t/routing/06-head.t`
- Modify: `t/routing/07-mounts.t`
- Modify: `t/routing/08-protocols.t`
- Modify: `t/routing/09-metadata-isolation.t`
- Modify: `t/routing/11-bare-middleware.t`
- Modify: `t/routing/12-router-mounts.t`
- Modify: `t/routing/16-http-outcomes.t`

**Interfaces:**

- `_compile_http_handler($handler)` constructs `PAGI::Request->new($scope, $receive)`, awaits `Future->wrap($handler->($request))`, requires a Response, and awaits `$response->respond($send)`.
- `_compile_protocol_leaf($route)` constructs `PAGI::WebSocket` or `PAGI::SSE` from exact scope/receive/send and awaits handler completion.
- Raw targets and all middleware remain unchanged native apps.
- Selected path params and routing frame are installed before protocol-object construction.

- [ ] **Step 1: Rewrite core handler assertions before production.** HTTP handlers assert `isa_ok($request, ['PAGI::Request'])`, exact scope identity, path params, body receive, immediate Response, async Response, failed Future, `undef`, arbitrary value, and exactly one send. Replace `$c->text/json/response` with `PAGI::Response` factories.

- [ ] **Step 2: Rewrite WebSocket and SSE assertions.** Assert the handler receives the exact cached protocol object from `PAGI::WebSocket->new`/`PAGI::SSE->new`, can use protocol methods directly, sees path params and scope helpers, and has immediate/Future completion awaited. Keep denial/decline/protocol-miss event tests unchanged in behavior.

- [ ] **Step 3: Pin raw and middleware boundaries.** Add handlers that record `scalar @_`; normal receives one object, raw receives exactly three native values, and route/Router/Mount middleware continues wrapping three-argument apps without Request adaptation.

- [ ] **Step 4: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/05-http-dispatch.t t/routing/06-head.t t/routing/07-mounts.t t/routing/08-protocols.t t/routing/09-metadata-isolation.t t/routing/11-bare-middleware.t t/routing/12-router-mounts.t t/routing/16-http-outcomes.t'
  ```

  Expected: handlers receive Context subclasses, HTTP response factories use old Context methods, and protocol-object assertions fail.

- [ ] **Step 5: Implement the shared compiler adapters.** Remove compile-time `use PAGI::Context`; load direct protocol classes. HTTP minimum:

  ```perl
  my $request = PAGI::Request->new($scope, $receive);
  my $result = await Future->wrap($handler->($request));
  croak 'handler did not return a response'
      unless PAGI::Utils::is_response($result);
  await Future->wrap($result->respond($send));
  ```

  For protocol routes, branch on `$route->kind`, construct WebSocket/SSE once, invoke the handler with one object, and await its immediate/Future result. Never validate protocol completion as a Response.

- [ ] **Step 6: Update focused Routing POD and run GREEN.** Reconcile handler tables, normal/raw distinction, Pages example, and jailbreak guidance. Run Step 4; syntax-check Compiler, Routing, and Route under Perl 5.16.3; run POD checks and diff check.

- [ ] **Step 7: Commit and update the ledger.** Stage exactly eleven files and commit:

  ```bash
  git add lib/PAGI/Routing/Compiler.pm lib/PAGI/Routing.pm lib/PAGI/Routing/Route.pm t/routing/05-http-dispatch.t t/routing/06-head.t t/routing/07-mounts.t t/routing/08-protocols.t t/routing/09-metadata-isolation.t t/routing/11-bare-middleware.t t/routing/12-router-mounts.t t/routing/16-http-outcomes.t
  git commit -m "refactor: pass direct protocol handlers"
  ```

### Task 9: Align App Router and Endpoint Router Frontends

**Files:**

- Modify: `lib/PAGI/App/Router.pm`
- Modify: `lib/PAGI/Endpoint/Router.pm`
- Modify: `lib/PAGI/Endpoint/Router/Builder.pm`
- Modify: `t/app-router.t`
- Modify: `t/app-router/01-builder-core.t`
- Modify: `t/app-router/02-declaration-package.t`
- Modify: `t/app-router/03-composition-order.t`
- Modify: `t/app-router/04-snapshots-cycles.t`
- Modify: `t/app-router/05-middleware-order.t`
- Modify: `t/app-router/06-public-api.t`
- Modify: `t/app-router/07-public-reverse-metadata.t`
- Modify: `t/app/02-routing.t`
- Modify: `t/app/03-router.t`
- Modify: `t/app/07-routing-composition.t`
- Modify: `t/context/07-router.t`
- Modify: `t/endpoint/12-route-middleware.t`
- Modify: `t/endpoint/13-router-frontends.t`
- Modify: `t/endpoint-router.t`
- Modify: `t/integration/sse-decline-end-to-end.t`
- Modify: `t/lib/TestRoutes/Admin.pm`
- Modify: `t/lib/TestRoutes/Users.pm`
- Modify: `t/router-middleware.t`
- Modify: `t/sse-router-support.t`
- Modify: `t/upgrading-router-frontends.t`

**Interfaces:**

- App Router inherits Task 8 behavior without its own adapter.
- Endpoint method-name handlers receive `($endpoint, $request)`, `($endpoint, $websocket)`, or `($endpoint, $sse)` through the same one-object closure.
- `new_context` is removed without alias; `new_request($scope, $receive)` explicitly constructs a strict HTTP Request and is never called by compiled dispatch.
- `middleware_as` and `app_as` remain pure native three-argument application helpers.

- [ ] **Step 1: Rewrite the complete App Router test surface to direct objects.** Preserve order, methods, Mount, middleware, raw, callback materialization, defaults, errors, declaration-package fixtures, reverse metadata, and SSE decline behavior while replacing Context factory assertions with Request/Response and direct WS/SSE expectations. Rewrite the former Context-Router integration test as a migration-boundary test; it must not imply that the Context family itself is removed.

- [ ] **Step 2: Rewrite Endpoint tests.** Pin method string/coderef binding, constructor instance lifetime, HTTP/WS/SSE object classes, helper use from exact scope, route-level pure middleware, raw application methods, and immediate/Future handler completion. Assert:

  ```perl
  ok(!$endpoint->can('new_context'));
  my $request = $endpoint->new_request($http_scope, $receive);
  isa_ok($request, ['PAGI::Request']);
  like(dies { $endpoint->new_request($sse_scope, $receive) }, qr/HTTP scope/i);
  ```

  Override `new_request` in a test subclass and prove only explicit calls increment the override counter; compiled dispatch bypasses it.

- [ ] **Step 3: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/app-router.t t/app-router t/app/02-routing.t t/app/03-router.t t/app/07-routing-composition.t t/context/07-router.t t/endpoint/12-route-middleware.t t/endpoint/13-router-frontends.t t/endpoint-router.t t/integration/sse-decline-end-to-end.t t/router-middleware.t t/sse-router-support.t t/upgrading-router-frontends.t'
  ```

  Expected: old tests/production expose Context, `new_context` exists, and `new_request` is absent.

- [ ] **Step 4: Implement the Endpoint seam.** Change only local naming/binding and explicit helper:

  ```perl
  sub new_request {
      my ($self, $scope, $receive) = @_;
      require PAGI::Request;
      return PAGI::Request->new($scope, $receive);
  }

  $target = sub {
      my ($protocol) = @_;
      return $method->($endpoint, $protocol);
  };
  ```

  Remove `new_context` code/POD/tests. Do not change standalone `PAGI::Endpoint::HTTP`, `::WebSocket`, or `::SSE` in this campaign.

- [ ] **Step 5: Update frontend POD and run GREEN.** Document direct normal objects, native middleware/raw helpers, and `new_request`'s explicit-only scope. Run Step 3; syntax-check all three modules under Perl 5.16.3; run POD checks and diff check.

- [ ] **Step 6: Commit and update the ledger.** Stage exactly twenty-four files and commit:

  ```bash
  git add lib/PAGI/App/Router.pm lib/PAGI/Endpoint/Router.pm lib/PAGI/Endpoint/Router/Builder.pm t/app-router.t t/app-router t/app/02-routing.t t/app/03-router.t t/app/07-routing-composition.t t/context/07-router.t t/endpoint/12-route-middleware.t t/endpoint/13-router-frontends.t t/endpoint-router.t t/integration/sse-decline-end-to-end.t t/lib/TestRoutes/Admin.pm t/lib/TestRoutes/Users.pm t/router-middleware.t t/sse-router-support.t t/upgrading-router-frontends.t
  git commit -m "refactor: align Router frontend handlers"
  ```

### Task 10: Migrate Canonical Examples and Integrations

**Files:**

- Modify: `examples/starlette-apples/app.pl`
- Modify: `examples/starlette-apples/README.md`
- Modify: `examples/15-large-application/lib/MyApp/Root.pm`
- Modify: `examples/15-large-application/lib/MyApp/Person.pm`
- Modify: `examples/15-large-application/lib/MyApp/Person/Blogs.pm`
- Modify: `examples/15-large-application/README.md`
- Modify: `examples/15-large-application/GAPS.md`
- Modify: `examples/declarative-routing/lib/MyApp/Routes/Home.pm`
- Modify: `examples/declarative-routing/README.md`
- Modify: `examples/endpoint-router-demo/lib/MyApp/API.pm`
- Modify: `examples/endpoint-router-demo/lib/MyApp/API/Events.pm`
- Modify: `examples/endpoint-router-demo/lib/MyApp/Main.pm`
- Modify: `examples/endpoint-router-demo/README.md`
- Modify: `examples/compose/app.pl`
- Modify: `examples/pages/app.pl`
- Modify: `examples/pages/README.md`
- Modify: `examples/background-tasks/app.pl`
- Modify: `examples/background-tasks/README.md`
- Modify: `examples/full-demo/README.md`
- Modify: `examples/README.md`
- Modify: `t/integration-starlette-apples.t`
- Modify: `t/integration-large-application.t`
- Modify: `t/integration-declarative-routing-demo.t`
- Modify: `t/integration-endpoint-router-demo.t`
- Modify: `t/integration-pages-example.t`

**Interfaces:**

- Every normal Routing handler in these examples uses `$request`, `$websocket`, or `$sse`; raw apps and middleware retain native names.
- HTTP responses use explicit `PAGI::Response`/`PAGI::Pages`; URL, Session, Stash, CSRF, State, and Transport use owning imports where needed.
- Starlette apples retains the original Python source byte-for-byte in README, Type::Tiny `Int`, Compose lifespan, generated links/Location, and explicit missing-lifespan diagnostic.
- Large application preserves all generated links and nested routing behavior while replacing Context helpers.

- [ ] **Step 1: Rewrite integration expectations first.** Assert Request handlers, absolute apple links, create Location, lifespan-backed CRUD, large-app link following, Pages Request endpoint, and Endpoint Router HTTP/WS/SSE behavior. Keep the original Python README block as a golden extraction and compare only the Perl block to the app source where the existing test does so.

- [ ] **Step 2: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-starlette-apples.t t/integration-large-application.t t/integration-declarative-routing-demo.t t/integration-endpoint-router-demo.t t/integration-pages-example.t'
  ```

  Expected: examples still call Context methods and fail under Task 8/9 direct handlers.

- [ ] **Step 3: Migrate the apples application and copied README block.** Use the spec's full example, including:

  ```perl
  sub apples_db($request) {
      my $state = $request->state
          or die 'starlette-apples requires Compose lifespan state';
      return $state->get('apples_db');
  }
  ```

  Use `url_for` for item links, `path_for` for Location, `PAGI::Response->json`, and `\1` for JSON true. Do not edit the original Python comparison block.

- [ ] **Step 4: Migrate large and Endpoint Router examples.** Replace `$c->path_for/url_for` with `PAGI::Routing::URL` exports, `$c->state->{...}` with strict State, `$c->request->json` with `$request->json`, Context response shortcuts with Response/Pages, and Endpoint `new_context` with `new_request` only inside explicit native middleware. Preserve pure middleware signatures.

- [ ] **Step 5: Migrate remaining normal-Routing examples.** Update declarative, Compose, Pages, background-task, full-demo, and index documentation. Leave standalone `examples/endpoint-demo`, standalone Endpoint WebSocket/SSE examples, and raw PAGI Context examples on their currently valid Context API; label those surfaces explicitly if adjacent prose could imply Routing handler parity.

- [ ] **Step 6: Run GREEN and example syntax gates.** Run Step 2, then compile every changed `.pl`/`.pm` under project Perl, use Perl 5.16.3 for non-5.40 modules, run POD/markdown source-copy checks, and run `git diff --check`.

- [ ] **Step 7: Commit and update the ledger.** Stage exactly the 25 Task 10 paths and commit:

  ```bash
  git add examples/starlette-apples examples/15-large-application examples/declarative-routing examples/endpoint-router-demo examples/compose/app.pl examples/pages examples/background-tasks examples/full-demo/README.md examples/README.md t/integration-starlette-apples.t t/integration-large-application.t t/integration-declarative-routing-demo.t t/integration-endpoint-router-demo.t t/integration-pages-example.t
  git commit -m "examples: adopt request-first handlers"
  ```

  Before committing, inspect `git diff --cached --name-only`; if directory staging includes an unlisted file, unstage it and stage only the named files.

### Task 11: Reconcile Public Documentation and Upgrade Guidance

**Files:**

- Modify: `README.md`
- Modify: `lib/PAGI/Tools.pm`
- Modify: `lib/PAGI/Tools/Tutorial.pod`
- Modify: `lib/PAGI/Tools/Cookbook.pod`
- Modify: `UPGRADING.md`
- Modify: `Changes`
- Create: `t/upgrading-request-first-handlers.t`
- Modify: `t/00-load.t`

**Interfaces:**

- Public narrative states that Starlette alignment governs routing topology while Request deliberately uses Perl imports for optional capability ownership.
- Upgrade guide contains exact Context-to-Request/Response/URL/State/Stash/Session/CSRF/Transport conversions and a Thunderhorse/framework-author handoff.
- It calls out State hash-overload limits, tri-state disconnect, strict Request construction, removed `new_context`, raw/middleware stability, Pages interoperability exception, and deferred Response/Context work.
- Changes records the breaking handler contract and new modules/exports under unreleased `0.002003` without claiming deferred work shipped.

- [ ] **Step 1: Write executable upgrade assertions.** In `t/upgrading-request-first-handlers.t`, compile and run focused before/after examples for HTTP handler return, URL exports, `app_state` under `use v5.40`, State `->data` for HashRef consumers, Stash/Session/CSRF factories, Transport optionality, Endpoint `new_request`, and three-argument raw middleware. Assert `PAGI::Request->can('url_for')` and `can('session')` are false.

- [ ] **Step 2: Run the RED documentation gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/upgrading-request-first-handlers.t t/00-load.t'
  ```

  Expected: the new executable guide test is missing/fails and public entry points still teach Context handlers.

- [ ] **Step 3: Write the ownership narrative and API references.** Update front-page/Tutorial/Cookbook examples to import capabilities explicitly. Include the exact reconciliation:

  ```text
  PAGI follows Starlette's Route/Mount/Router/application topology, not every
  method on Starlette Request. PAGI::Request owns HTTP input; imports identify
  the Router or middleware that supplies optional behavior.
  ```

  Keep valid standalone Endpoint and deferred Context documentation clearly scoped rather than deleting it.

- [ ] **Step 4: Write the upgrade and Thunderhorse sections.** Include before/after code from spec section 18, the `ref($state) ne 'HASH'` caveat, exact warning environment variable, no `state` export, and framework choices: Thunderhorse may keep its own Controller URL builder and need not populate PAGI::Routing frames.

- [ ] **Step 5: Add Changes and load coverage.** Register every public new module in `t/00-load.t`; record only shipped-in-this-campaign behavior in Changes.

- [ ] **Step 6: Run GREEN, POD, and live-surface searches.** Run Step 2, then:

  ```bash
  podchecker lib/PAGI/Tools.pm
  podchecker lib/PAGI/Tools/Tutorial.pod
  podchecker lib/PAGI/Tools/Cookbook.pod
  rg -n 'route\([^\n]*=>[^\n]*\$c|normal.*Context handler|Context handler.*route|new_context' lib README.md UPGRADING.md Changes examples t --glob '!context/**'
  rg -n 'qw\(state\)|\bstate\(\$request|exact-scope cach|helper cache' lib README.md UPGRADING.md Changes examples t
  git diff --check
  ```

  Expected: POD checks pass; searches return no live normal-Routing Context recommendation, poisoned `state` export, or helper-cache contract. Any retained Context/`new_context` match must be classified as standalone/deferred history or removed.

- [ ] **Step 7: Commit and update the ledger.** Stage exactly eight files and commit:

  ```bash
  git add README.md lib/PAGI/Tools.pm lib/PAGI/Tools/Tutorial.pod lib/PAGI/Tools/Cookbook.pod UPGRADING.md Changes t/upgrading-request-first-handlers.t t/00-load.t
  git commit -m "docs: explain request-first PAGI tools"
  ```

### Task 12: Final Contract Audit, Full Suite, and Distribution Build

**Files:**

- Create ignored evidence: `.superpowers/sdd/2026-08-27-request-first-handlers-and-scope-helpers/task-12-audit-report.md`
- Update ignored ledger: `.superpowers/sdd/2026-08-27-request-first-handlers-and-scope-helpers/progress.md`
- Modify production/test/docs only if a verified defect prevents an approved acceptance criterion; record each correction and review separately.

**Interfaces:**

- Produces no new API. It proves the reviewed HEAD implements every spec section, passes the one final full suite, and builds a clean distribution archive.
- Does not push, merge, tag, release, delete a worktree, or run `dzil test`.

- [ ] **Step 1: Audit specification coverage before running the suite.** Build a table in the audit report mapping spec sections 7–23 and every section 20 test bullet to production file, focused test, task commit, and evidence. Explicitly verify no helper identity/cache semantics, no poisoned `state` export, no Request router/session/transport methods, one reverse implementation, and no Context construction in Routing compiler.

- [ ] **Step 2: Run the complete focused campaign gate.** Run all new/modified helper, Request, Pages, Context reverse, Routing, App Router, Endpoint Router, integration, and upgrading tests by explicit path. Record actual file count, Test2 top-level test count, exit status, elapsed time, and HEAD SHA.

- [ ] **Step 3: Run compatibility syntax and POD gates.** Syntax-check every changed `lib/*.pm` under Perl 5.16.3, modern example files under project Perl 5.42.2, and run `podchecker` on every changed POD-bearing file. Run `git diff --check` and the Task 11 live-surface searches from a clean command transcript.

- [ ] **Step 4: Obtain independent contract review.** Review the complete base-to-HEAD diff against the approved spec, emphasizing Request ownership, helper absence/error rules, State overload limitations, URL authority/capture behavior, raw/middleware invariance, protocol object construction, examples, and scope exclusions. Fix any confirmed defect through a focused red/green test and reviewed commit before the full suite.

- [ ] **Step 5: Run the repository-wide suite exactly once at final reviewed HEAD.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t'
  ```

  Expected: all test files and assertions pass. Record exact counts, elapsed time, exit status, skips, warnings, and HEAD. If sandbox socket restrictions are the only failures, preserve that complete output and request one authorized host-access replacement run; do not rerun speculatively.

- [ ] **Step 6: Build and inspect the distribution without repeating tests.** Run project-Perl `dzil build` but not `dzil test`. Record archive path, size, entry count, and SHA-256. Inspect that new public modules, current POD, examples, tests, META prereqs, and version are present; `docs/`, `.superpowers/`, VCS data, symlinks, and unrelated artifacts are absent. If `dzil build` rewrites tracked README, restore it exactly to reviewed HEAD without touching other files and record the side effect.

- [ ] **Step 7: Close the ledger with exact evidence.** Mark every task complete with commit SHA, focused counts, review outcome, and final-suite evidence. Verify:

  ```bash
  git status --short
  git diff --check
  git rev-parse HEAD
  ```

  Expected: only the three preserved untracked paths are reported, diff check is silent, and HEAD is the reviewed campaign tip. Do not commit ignored evidence and do not publish.
