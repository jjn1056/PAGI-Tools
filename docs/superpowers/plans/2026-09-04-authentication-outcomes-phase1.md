# Authentication Outcomes Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add standards-aware authentication challenge and authorization-forbid outcome applications, expose safe Pages materialization for protocol denials, and prove the API through focused tests, documentation, the apples canary, and a separate cookie-login policy example.

**Architecture:** `PAGI::Auth` supplies opt-in Basic, Bearer, and extension challenge builders plus concise `challenge`/`forbid` factories. Immutable `PAGI::Auth::Challenge` values carry validated wire text and private status metadata; `PAGI::Auth::Outcomes` validates semantic outcome combinations and delegates all presentation work to a retained `PAGI::Pages` policy. `PAGI::Pages::Application->response_for($source)` exposes the existing synchronous descriptor-to-Response seam so WebSocket, SSE, and future request-like protocols can materialize a concrete response while their existing adapters retain lifecycle and send ownership.

**Tech Stack:** Perl 5.18-compatible distribution code; `Future`, `Future::AsyncAwait`, `PAGI::Pages`, `PAGI::Response`, `PAGI::WebSocket`, `PAGI::SSE`, `PAGI::Session`, `PAGI::Test::Client`, Test2::V0, POD, and Dist::Zilla. Perl 5.40 signatures remain limited to examples already declaring that floor. No new runtime dependency.

**Spec:** `docs/superpowers/specs/2026-09-04-authentication-outcomes-design.md`, approved on local branch `feature/authentication-outcomes-phase1`; reviewed design commit `9a6247f3ca3a8a05ca0bac3df9373adc0500776d`, with the subsequently approved example-scope clarification committed with this plan.

## Global Constraints

- The approved specification and the user's later example ruling are authoritative. Phase 1 ships the outcome API, not credential acquisition, identity state, an authorization engine, or replacement auth middleware.
- Work in the current checkout on local branch `feature/authentication-outcomes-phase1`; do not create a worktree.
- The branch is based on local `main` at `c4c007f7a0603c2e36cd88266f2289db4f3baa12`. The reviewed design commit is `9a6247f3ca3a8a05ca0bac3df9373adc0500776d`. Record the actual execution HEAD after this plan commit before editing implementation files.
- Preserve the existing untracked `.pagi-*` and `.superpowers/brainstorm/` notes. Never stage with `git add .` or `git add -A`; stage only task-owned paths.
- Keep distribution modules compatible with the declared Perl 5.18 floor. Do not add signatures, postfix dereferencing that exceeds the floor, or a new dependency to `cpanfile`.
- Use no arity inspection, exception-driven auth control flow, challenge registry, dynamic package loading, response replay, body buffering, hidden scope cache, or universal app-to-Response coercion protocol.
- Keep dependency direction one-way: Phase 2 identity/provider code -> `PAGI::Auth` -> `PAGI::Pages` -> `PAGI::Response`. Pages, Response, Request, WebSocket, SSE, Routing, and Compose must not depend on Auth.
- `PAGI::Auth` exports nothing by default and has no `new`. `PAGI::Auth::Outcomes` owns configured Pages policy. `PAGI::Auth::Challenge` is an immutable structured protocol value, not a Response or app.
- Preserve one `WWW-Authenticate` field line per challenge in declaration order. Never join challenges with commas.
- Challenge construction and outcome validation are synchronous and finish before any response event. Do not read request bodies, credentials, sessions, files, networks, or send channels.
- `response_for($source)` materializes one fresh concrete Response and sends nothing. `invoke_app`, `WebSocket->deny`, or `SSE->decline` retains emission ownership.
- Keep WebSocket/SSE denial settlement, start-commit timing, backpressure, disconnect observation, and cleanup in their existing adapters. Do not introduce an Auth watcher, mapped-send wrapper, or second state machine.
- `PAGI::Response::File` remains ineligible for protocol denial because PAGI denial bodies exclude `file`/`fh` events.
- Leave `PAGI::Middleware::Auth::Basic` and `PAGI::Middleware::Auth::Bearer` behavior unchanged in Phase 1. Do not mechanically migrate them unless the user separately approves that isolated work.
- The apples example remains the public API canary and must retain its CRUD, NDJSON, middleware, URL-generation, lifespan, source-sync, and original-Python-checksum coverage.
- Add a cookie-login example, but state plainly that its hardcoded credential and in-memory session store are demo choices. The Auth API must not automatically redirect browsers.
- Per the user's latest ruling, defer a full runnable HTTP/WebSocket/SSE credential-enforcement application to Phase 2. Phase 1 proves protocol reuse in focused tests and Cookbook snippets.
- Use strict TDD for every behavior task: write the named failing test, run it and record the RED reason, implement the minimum clean code, then run the focused GREEN gate.
- Run focused suites during Tasks 1–7. Run `prove -lr t` once at Task 8; repeat only if a later correction changes HEAD.
- Every task ends with a task commit, an immediate tracking-ledger update containing the implementation SHA and exact test evidence, and a review gate before dependent work begins.
- Stop for user review if implementation requires several special cases, cloning retained policy objects, mutating source scopes, accepting raw challenge strings, changing PAGI/PAGI::Server, or hacking around a lifecycle rather than using its public seam.

Use the project Perl for all test commands:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/auth/01-challenge-values.t'
```

## Work Map

| Repository | Ticket | Execution branch | Base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | No external ticket; approved Phase 1 Auth outcomes | Local `feature/authentication-outcomes-phase1` in the primary checkout | local `main` `c4c007f7a0603c2e36cd88266f2289db4f3baa12`; design `9a6247f3ca3a8a05ca0bac3df9373adc0500776d` | Auth packages, Pages materialization, focused protocol integration, cookie-login example, apples canary, POD/Cookbook/Tutorial/Changes/tests | Unreleased PAGI-Tools code only; no release, tag, merge, PAGI spec change, or PAGI::Server change | Local branch only until the user requests a PR/push |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI` | Protocol semantics reference | Read-only | Current local PAGI 0.5 specification | Normative reference only | No change | None |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server` | Settlement/lifespan behavior reference | Read-only | Current installed/local server behavior | Integration context only | No change | None |

Reconfirm this map before Task 1, whenever scope changes, and before any push. If a PAGI or PAGI::Server defect appears, stop and create a separate work item rather than editing a sibling repository.

## Execution Tracking and Deviation Control

Before Task 1, create these tracked files with `apply_patch`:

```text
docs/superpowers/plans/2026-09-04-authentication-outcomes-phase1-tracking.md
.superpowers/sdd/2026-09-04-authentication-outcomes-phase1/starting-head
```

`starting-head` contains the exact 40-character output of `git rev-parse HEAD` and one newline. Initialize the tracking document with this shape, substituting that exact SHA as part of the same edit:

```markdown
# Authentication Outcomes Phase 1 Execution Tracking

**Plan:** `docs/superpowers/plans/2026-09-04-authentication-outcomes-phase1.md`

**Starting HEAD:** Read the exact value from the adjacent `starting-head` file;
replace this sentence with that 40-character SHA during Task 1 initialization.

| Task | Status | Implementation SHA | Review/fix SHAs | Focused verification and actual counts | Full-suite/build evidence | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | pending | — | — | — | deferred to Task 8 | — |
| 2 | pending | — | — | — | deferred to Task 8 | — |
| 3 | pending | — | — | — | deferred to Task 8 | — |
| 4 | pending | — | — | — | deferred to Task 8 | — |
| 5 | pending | — | — | — | deferred to Task 8 | — |
| 6 | pending | — | — | — | deferred to Task 8 | — |
| 7 | pending | — | — | — | deferred to Task 8 | — |
| 8 | pending | — | — | — | final gate | — |

## Deviations and rulings

| ID | Status | Conflicting plan/spec text | Evidence and rationale | Affected tasks | User decision |
| --- | --- | --- | --- | --- | --- |
```

The literal angle-bracket instruction above is for initialization, not a value permitted in the committed tracking file. After each task commit, immediately record its SHA, exact command, actual file/assertion counts, elapsed time, and review verdict in a small follow-up ledger commit. A commit cannot contain its own final SHA. Any divergence receives the next stable `DEV-NNN` identifier and blocks dependent work until the user rules on it.

## File Responsibility Map

| File | Responsibility |
| --- | --- |
| `lib/PAGI/Auth.pm` | Opt-in exports, Basic/Bearer/custom challenge builders, shared validation/serialization, and delegation to Outcomes |
| `lib/PAGI/Auth/Challenge.pm` | Immutable authentication challenge value and private outcome metadata |
| `lib/PAGI/Auth/Outcomes.pm` | Configured Pages policy, `challenge`/`forbid` semantic validation, and Pages application construction |
| `lib/PAGI/Pages/Application.pm` | Public synchronous `response_for`, shared source/type validation, and one descriptor-to-Response materialization path |
| `lib/PAGI/Pages.pm` | HTTP metadata view helper and public cross-link; no Auth dependency |
| `lib/PAGI/Response.pm` | Documentation cross-link only |
| `lib/PAGI/Response/File.pm` | Documentation cross-link for denial-body capability opt-out only |
| `lib/PAGI/WebSocket.pm` | `deny` documentation showing explicit materialization only |
| `lib/PAGI/SSE.pm` | `decline` documentation showing explicit materialization only |
| `t/auth/01-challenge-values.t` | Export policy, immutable values, Basic and generic scheme grammar |
| `t/auth/02-bearer.t` | Bearer core/extension grammar, deterministic serialization, dependencies, errors |
| `t/auth/03-outcomes.t` | 401/403 semantics, Pages delegation, negotiation, reuse, and policy identity |
| `t/pages/07-response-for.t` | Source grammar, metadata views, cache invalidation, fresh responses, and shared materialization |
| `t/auth/04-protocol-integration.t` | Request-handler/native HTTP, WebSocket denial, SSE decline, capability and settlement regression |
| `examples/auth-cookie-login/app.pl` | Explicit cookie/session login policy example with hardcoded demo credentials |
| `examples/auth-cookie-login/README.md` | Run instructions, flow, and production security caveats |
| `t/integration-auth-cookie-login.t` | Test Client login, invalid login, fixation defense, protected page, and logout |
| `examples/starlette-apples/app.pl` | One outcome-only `/apples/auth-required` canary Route |
| `examples/starlette-apples/README.md` | Preserved Python comparison and synchronized current Perl source |
| `t/integration-starlette-apples.t` | Negotiated Auth outcome coverage without disturbing existing behavior |
| `lib/PAGI/Tools/Cookbook.pod` | Complete outcome recipes, explicit protocol shapes, and corrected SSE auth recipe |
| `lib/PAGI/Tools/Tutorial.pod` | Concise high-level outcome introduction |
| `lib/PAGI/Tools.pm` | Auth discoverability and package cross-links |
| `examples/README.md` | Discovery entries for cookie login and updated apples Auth canary |
| `t/00-load.t` | Loadability of all three Auth packages |
| `t/00-pod/cookbook-examples.t` | Executable public API examples where supported by the current harness |
| `Changes` | Unreleased Phase 1 Auth outcome and Pages materialization notes |

## Specification Coverage Map

| Design area | Owning tasks |
| --- | --- |
| Public packages, exports, and challenge value (§8) | Tasks 1–3 and 8 |
| Basic and generic builders (§§9.1, 9.2, 9.4) | Task 1 |
| Bearer core and extension grammar (§9.3) | Task 2 |
| Challenge/forbid applications and matrix (§§10, 13–16) | Task 3 |
| Pages materialization (§11) | Task 4 |
| HTTP/WebSocket/SSE protocol use (§12) | Task 5 |
| Existing auth middleware boundary (§17) | Tasks 5 and 8 regression gates; no implementation change |
| Phase 2 separation (§18) | Enforced globally and documented in Tasks 6–8 |
| Flagship apples application (§19.1) | Task 7 |
| Cookie login and remaining documentation (§19.2, later ruling) | Tasks 6 and 8 |
| Verification outcomes (§20) | Tasks 1–8 |
| Stop conditions (§21) | Enforced at every task review and audited in Task 8 |

---

### Task 1: Add Immutable Challenge Values, Basic, and Custom Schemes

**Files:**

- Create: `lib/PAGI/Auth.pm`
- Create: `lib/PAGI/Auth/Challenge.pm`
- Create: `t/auth/01-challenge-values.t`
- Create: `docs/superpowers/plans/2026-09-04-authentication-outcomes-phase1-tracking.md`
- Create: `.superpowers/sdd/2026-09-04-authentication-outcomes-phase1/starting-head`

**Interfaces:**

- `PAGI::Auth::basic(realm => $scalar, charset => 'UTF-8') -> PAGI::Auth::Challenge`
- `PAGI::Auth::custom_challenge(scheme => $token, params => \%params | token68 => $scalar) -> PAGI::Auth::Challenge`
- `PAGI::Auth::Challenge->scheme -> scalar`
- `PAGI::Auth::Challenge->header_value -> scalar`
- Private construction: `PAGI::Auth::Challenge->_new(%validated_fields)`; no public `new`
- Private metadata consumed by Task 3: `_kind` and `_error`

- [ ] **Step 1: Reconfirm and record the local branch.** Run:

  ```bash
  git status -sb
  git branch --show-current
  git rev-parse HEAD
  git rev-parse main
  git rev-parse origin/main
  ```

  Verify the branch is `feature/authentication-outcomes-phase1`, classify every pre-existing untracked path, create the tracking files described above, and record the exact execution SHA. Do not fetch, rebase, create a worktree, or alter the unrelated note files.

- [ ] **Step 2: Write the failing export and value tests.** Create `t/auth/01-challenge-values.t` with these representative assertions and a table covering every invalid class from spec §§9.1, 9.2, and 9.4:

  ```perl
  use strict;
  use warnings;
  use Test2::V0;
  use PAGI::Auth qw(basic custom_challenge);

  my $basic = basic(realm => 'Staff "and" Support', charset => 'utf-8');
  isa_ok $basic, 'PAGI::Auth::Challenge';
  is $basic->scheme, 'Basic';
  is $basic->header_value,
      'Basic realm="Staff \\"and\\" Support", charset="UTF-8"';
  ok !$basic->can('new'), 'no public constructor is inherited by the value';
  like dies { $basic->{scheme} = 'Changed' }, qr/read.?only|restricted/i;

  my $generic = custom_challenge(
      scheme => 'DemoToken',
      params => { realm => 'demo', mode => 'interactive' },
  );
  is $generic->header_value,
      'DemoToken mode="interactive", realm="demo"';
  is custom_challenge(scheme => 'Mutual')->header_value, 'Mutual';
  is custom_challenge(scheme => 'Negotiate', token68 => 'abc+/==')->header_value,
      'Negotiate abc+/==';

  is \@PAGI::Auth::EXPORT, [], 'Auth exports nothing by default';
  is $PAGI::Auth::EXPORT_TAGS{outcomes}, [qw(challenge forbid)];
  is $PAGI::Auth::EXPORT_TAGS{challenges},
      [qw(basic bearer custom_challenge)];
  ```

  Assert Basic requires `realm`, accepts an empty realm, rejects unknown/odd/reference-valued options, rejects non-UTF-8 charset, and rejects CR/LF/NUL/control/DEL/non-ASCII values. Assert custom schemes validate token/token68, reject Basic and Bearer case-insensitively, reject empty explicit params, reject `params` plus `token68`, reject case-insensitive duplicate keys, sort keys case-insensitively, and quote backslash/double quote correctly. Assert the value has no string/hash/code overload and changing or extending its locked representation dies.

- [ ] **Step 3: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/auth/01-challenge-values.t'
  ```

  Expected: FAIL because `PAGI/Auth.pm` and `PAGI/Auth/Challenge.pm` do not exist. Record the actual failure in the tracking row.

- [ ] **Step 4: Implement the minimal immutable value and shared serializers.** In `PAGI::Auth::Challenge`, retain only validated scalar fields and lock the hash:

  ```perl
  package PAGI::Auth::Challenge;

  use strict;
  use warnings;
  use Hash::Util qw(lock_hashref);

  sub _new {
      my ($class, %fields) = @_;
      my $self = bless \%fields, $class;
      lock_hashref($self);
      return $self;
  }

  sub scheme       { return $_[0]{scheme} }
  sub header_value { return $_[0]{header_value} }
  sub _kind        { return $_[0]{kind} }
  sub _error       { return $_[0]{error} }
  ```

  In `PAGI::Auth`, define exact export bundles and central private validators for HTTP token, token68, printable ASCII quoted values, case-insensitive parameter uniqueness, quoting, and deterministic sorting. Builders validate fully before calling `_new`:

  ```perl
  our @EXPORT = ();
  our @EXPORT_OK = qw(challenge forbid basic bearer custom_challenge);
  our %EXPORT_TAGS = (
      outcomes   => [qw(challenge forbid)],
      challenges => [qw(basic bearer custom_challenge)],
      all        => [@EXPORT_OK],
  );

  sub _quote {
      my ($value) = @_;
      $value =~ s/([\\"])/\\$1/g;
      return '"' . $value . '"';
  }
  ```

  `challenge` and `forbid` may be thin lazy delegates to the Task 3 package now; do not implement outcome policy in this task. Fully qualified builder calls such as `PAGI::Auth::basic(...)` must work without import.

- [ ] **Step 5: Run the GREEN gate and syntax checks.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/auth/01-challenge-values.t && perl -Ilib -c lib/PAGI/Auth.pm && perl -Ilib -c lib/PAGI/Auth/Challenge.pm'
  git diff --check
  ```

  Expected: all challenge-value assertions pass; both modules report `syntax OK`; diff check is empty.

- [ ] **Step 6: Commit and update the ledger.** Stage only Task 1 paths and commit:

  ```bash
  git add lib/PAGI/Auth.pm lib/PAGI/Auth/Challenge.pm t/auth/01-challenge-values.t docs/superpowers/plans/2026-09-04-authentication-outcomes-phase1-tracking.md
  git commit -m "Add authentication challenge values"
  ```

  Record the implementation SHA, RED/GREEN commands, actual counts, elapsed time, and reviewer verdict in the tracking row; commit that exact tracking file separately.

---

### Task 2: Implement the Extensible Bearer Challenge Builder

**Files:**

- Modify: `lib/PAGI/Auth.pm`
- Create: `t/auth/02-bearer.t`

**Interfaces:**

- `PAGI::Auth::bearer(%options) -> PAGI::Auth::Challenge`
- Options: `realm`, `scope`, `error`, `error_description`, `error_uri`, `params`
- Private metadata: `_kind` returns `bearer`; `_error` returns the normalized error or `undef`

- [ ] **Step 1: Write the failing Bearer success matrix.** Create `t/auth/02-bearer.t` and pin deterministic serialization:

  ```perl
  use strict;
  use warnings;
  use Test2::V0;
  use PAGI::Auth qw(bearer);

  is bearer(realm => 'api')->header_value, 'Bearer realm="api"';

  my $value = bearer(
      realm             => 'api',
      scope             => ['apples:read', 'apples:write'],
      error             => 'invalid_token',
      error_description => 'The token is no longer valid',
      error_uri         => 'https://example.test/auth/invalid-token',
      params            => { zeta => 'last', acr_values => 'urn:example:strong' },
  );
  is $value->header_value,
      'Bearer realm="api", scope="apples:read apples:write", error="invalid_token", '
      . 'error_description="The token is no longer valid", '
      . 'error_uri="https://example.test/auth/invalid-token", '
      . 'acr_values="urn:example:strong", zeta="last"';
  ```

  Add positive cases for `invalid_request`, `invalid_token`, `insufficient_scope`, `insufficient_user_authentication`, an unknown token-shaped extension error, RFC 9470 `acr_values`/`max_age`, and RFC 9728 `resource_metadata`.

- [ ] **Step 2: Add the failing Bearer rejection matrix.** Table-drive absence of every required parameter; unknown and odd options; invalid scope shape/token/duplicates; `error_description` or `error_uri` without error; relative or malformed `error_uri`; malformed extension error; invalid `params` shape; empty params; core-name collisions; keys differing only by case; invalid names/values; refs; CR/LF/NUL/control/DEL/non-ASCII. Confirm extension-specific semantics such as numeric `max_age` are caller-owned while their generic serialized shape remains safe.

- [ ] **Step 3: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/auth/02-bearer.t'
  ```

  Expected: FAIL because `bearer` is not implemented.

- [ ] **Step 4: Implement Bearer through the shared validators.** Normalize core parameters in fixed order and extension keys afterward in case-insensitive ASCII lexical order. Preserve scope declaration order and reject duplicates instead of deduplicating. Require an RFC token for unknown errors, use the strict printable field grammars from the spec, and validate `error_uri` with the same conservative absolute-URI shape already used by Pages:

  ```perl
  my @core_order = qw(realm scope error error_description error_uri);
  my %known_error = map { $_ => 1 } qw(
      invalid_request invalid_token insufficient_scope
      insufficient_user_authentication
  );

  my @serialized;
  push @serialized, 'realm=' . _quote($opts->{realm}) if exists $opts->{realm};
  push @serialized, 'scope=' . _quote(join ' ', @{$opts->{scope}})
      if exists $opts->{scope};
  # append remaining core values in @core_order, then sorted extensions
  return PAGI::Auth::Challenge->_new(
      scheme       => 'Bearer',
      header_value => 'Bearer ' . join(', ', @serialized),
      kind         => 'bearer',
      error        => $opts->{error},
  );
  ```

  Do not use URI network access, fetch metadata, or interpret extension semantics.

- [ ] **Step 5: Run focused GREEN gates.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/auth/01-challenge-values.t t/auth/02-bearer.t'
  git diff --check
  ```

  Expected: both Auth builder files pass with no warnings or diff errors.

- [ ] **Step 6: Commit and update the ledger.** Commit only `lib/PAGI/Auth.pm` and `t/auth/02-bearer.t` as `Add validated Bearer challenges`, then record SHA, counts, timing, and review evidence in the tracking file and commit that update.

---

### Task 3: Build Challenge and Forbid Outcome Applications

**Files:**

- Create: `lib/PAGI/Auth/Outcomes.pm`
- Modify: `lib/PAGI/Auth.pm`
- Create: `t/auth/03-outcomes.t`

**Interfaces:**

- `PAGI::Auth::Outcomes->new(pages => $pages?) -> Outcomes`
- Class or instance `challenge(%options) -> PAGI::Pages::Application`
- Class or instance `forbid(%options) -> PAGI::Pages::Application`
- Exported `PAGI::Auth::challenge` and `forbid` delegate to base Outcomes class
- Shared Pages options: `as`, `detail`, `type`, `title`, `instance`, `extensions`, `headers`, `cache_control`; Auth-only `challenges`

- [ ] **Step 1: Write failing outcome construction and header tests.** In `t/auth/03-outcomes.t`, create a small `run_http_app` helper using `PAGI::Utils::invoke_app`, then assert:

  ```perl
  my $failure = challenge(
      challenges => [
          basic(realm => 'Staff'),
          bearer(realm => 'api'),
      ],
      detail => 'Authenticate with either supported scheme.',
  );
  isa_ok $failure, 'PAGI::Pages::Application';

  my $events = run_http_app($failure, accept => 'application/problem+json');
  is $events->[0]{status}, 401;
  is header_all($events->[0], 'WWW-Authenticate'), [
      'Basic realm="Staff"',
      'Bearer realm="api"',
  ];
  is header_all($events->[0], 'Vary'), ['Accept'];
  is header_all($events->[0], 'Cache-Control'), ['no-store'];
  ```

  Cover HTML, text, problem JSON, fixed `as`, repeated Accept, total rejection fallback, and `forbid(detail => ...)` with no challenge. Assert every invocation produces a fresh Response and one outcome app can serve overlapping requests.

- [ ] **Step 2: Add failing validation and status-matrix tests.** Assert challenges accepts exactly one Challenge or a nonempty array of them; diagnostics name invalid positions. Reject raw strings, nested arrays, arbitrary blessed values, caller `WWW-Authenticate`, `status`, singular `challenge`, proxy options, and unknown options. Pin the complete known Bearer matrix:

  ```text
  challenge: absent error, invalid_token, insufficient_user_authentication => valid
  challenge: invalid_request => croak directing to explicit 400
  challenge: insufficient_scope => croak directing to forbid
  forbid: insufficient_scope => valid
  forbid: absent error, invalid_token, invalid_request,
          insufficient_user_authentication => croak
  either outcome: unknown extension error => accepted without inferred status
  ```

  Confirm `forbid(challenges => [...])` emits repeated Auth-owned header lines even though caller headers cannot claim that field. Basic/generic values on 403 remain syntactically accepted.

- [ ] **Step 3: Add failing configured-policy tests.** Define a Pages subclass with a distinctive `render_problem`, retain an exact instance in `PAGI::Auth::Outcomes->new(pages => $pages)`, and assert class/instance/subclass invocation, identity retention, and concurrent reuse. Reject every constructor key except `pages`, non-Pages objects, class names, and unblessed refs. Confirm `PAGI::Auth` has no `new`.

- [ ] **Step 4: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/auth/03-outcomes.t'
  ```

  Expected: FAIL because Outcomes does not exist and exported outcome delegates cannot complete.

- [ ] **Step 5: Implement Outcomes as thin Pages policy.** Use explicit class/instance normalization modeled on Pages without caller inference:

  ```perl
  sub new {
      my ($class, %args) = @_;
      croak "PAGI::Auth::Outcomes has unknown option '$key'" ...;
      my $pages = exists $args{pages} ? $args{pages} : PAGI::Pages->new;
      croak 'PAGI::Auth::Outcomes pages must be a PAGI::Pages instance'
          unless blessed($pages) && $pages->isa('PAGI::Pages');
      return bless { pages => $pages }, $class;
  }

  sub challenge {
      my ($self, @args) = _invocation(@_);
      my ($opts, $values) = $self->_normalize_outcome('challenge', @args);
      $opts->{challenge} = [map { $_->header_value } @$values];
      return $self->{pages}->unauthorized(%$opts);
  }

  sub forbid {
      my ($self, @args) = _invocation(@_);
      my ($opts, $values) = $self->_normalize_outcome('forbid', @args);
      my @headers = @{$opts->{headers} || []};
      push @headers, map { ('WWW-Authenticate' => $_->header_value) } @$values;
      $opts->{headers} = \@headers if @headers;
      return $self->{pages}->forbidden(%$opts);
  }
  ```

  Validate caller headers before appending Auth-owned fields. Let Pages remain authoritative for presentation-option validation; do not copy renderer/negotiation behavior. In `PAGI::Auth`, lazy-load Outcomes and delegate exported functions to its base class.

- [ ] **Step 6: Run focused GREEN gates.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/auth/01-challenge-values.t t/auth/02-bearer.t t/auth/03-outcomes.t t/pages/02-rendering-negotiation.t t/pages/03-invocation-composition.t t/pages/04-status-fields-cache.t'
  git diff --check
  ```

  Expected: Auth outcomes and existing Pages semantics all pass.

- [ ] **Step 7: Commit and update the ledger.** Commit Task 3 as `Add authentication outcome applications`, then commit the tracking update with exact evidence.

---

### Task 4: Expose One Pages Materialization Seam

**Files:**

- Modify: `lib/PAGI/Pages/Application.pm`
- Modify: `lib/PAGI/Pages.pm`
- Create: `t/pages/07-response-for.t`

**Interfaces:**

- `$application->response_for($source) -> fresh PAGI::Response` synchronously
- `$source`: exactly one unblessed scope hashref or blessed object with `scope()` returning one
- Internal shared path: resolve/validate source -> descriptor once on original scope -> HTTP metadata view -> policy once -> fresh Response
- `to_app` remains HTTP-only and delegates its concrete Response with `invoke_app`

- [ ] **Step 1: Write failing source and response tests.** In `t/pages/07-response-for.t`, construct a negotiated `PAGI::Pages->unauthorized(challenge => 'Bearer realm="api"')` and assert materialization from HTTP, WebSocket, SSE, and custom typed scopes, plus `PAGI::Request`, `PAGI::WebSocket`, `PAGI::SSE`, and a custom object with `scope()`. Pin concrete response class/status/content type/body and freshness:

  ```perl
  my $page = PAGI::Pages->unauthorized(
      challenge => 'Bearer realm="api"',
      as        => 'json',
  );
  my $one = $page->response_for({
      type => 'websocket', path => '/chat', headers => [],
  });
  my $two = $page->response_for({
      type => 'websocket', path => '/chat', headers => [],
  });
  isa_ok $one, 'PAGI::Response::Problem';
  isnt refaddr($one), refaddr($two);
  is $one->status, 401;
  ```

  Add missing/invalid type, blessed scope, invalid source, throwing `scope()`, lifespan, extra options, Future descriptor, and Future renderer rejection cases.

- [ ] **Step 2: Write failing metadata-view and cache-collision tests.** Use a counting descriptor and Pages subclass to prove exactly one call each. Assert descriptor sees the original non-HTTP scope; renderer negotiation sees an HTTP view with preserved valid method/path or defaults `GET` and `/`; nested refs retain identity; source stays unchanged. Before materialization, call `$ws->headers` and `$sse->headers` so `pagi.request.headers` contains `Hash::MultiValue`; then prove repeated raw Accept lines are rebuilt into `PAGI::Headers` semantics and select the correct representation without replacing the original protocol cache.

- [ ] **Step 3: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/pages/07-response-for.t'
  ```

  Expected: FAIL because `response_for` is absent.

- [ ] **Step 4: Refactor Application cleanly around shared private operations.** Retain the exact policy and descriptor factory; do not clone or freeze them. A clean implementation may store them directly in the Application object and retain one native closure, but must avoid a self-capture cycle. Use one validator and one materializer:

  ```perl
  sub response_for {
      my ($self, @sources) = @_;
      my $scope = $self->_validated_scope(@sources);
      return $self->_materialize_scope($scope);
  }

  sub _materialize_scope {
      my ($self, $scope) = @_;
      my $descriptor = $self->{descriptor_factory}->($scope);
      my $metadata = PAGI::Pages::_http_metadata_scope($scope);
      return $self->{policy}->_response_for($metadata, $descriptor);
  }
  ```

  The native `to_app` closure calls the same `_validated_scope` and `_materialize_scope`, adds only `type eq 'http'`, and awaits `invoke_app`. If closure storage would create a cycle, return a closure that captures the exact policy/factory values or build the closure in `to_app`; do not use weak references, identity tokens, clones, or a scope cache.

- [ ] **Step 5: Correct the non-HTTP metadata view.** In `PAGI::Pages::_http_metadata_scope`, return the original HTTP scope, otherwise shallow-copy only the top-level hash, force `type => 'http'`, default invalid/missing method/path, and delete only the incompatible derived header cache:

  ```perl
  sub _http_metadata_scope {
      my ($scope) = @_;
      return $scope if $scope->{type} eq 'http';
      my %metadata = %$scope;
      $metadata{type} = 'http';
      $metadata{method} = 'GET'
          unless defined($metadata{method}) && !ref($metadata{method});
      $metadata{path} = '/'
          unless defined($metadata{path}) && !ref($metadata{path});
      delete $metadata{'pagi.request.headers'};
      return \%metadata;
  }
  ```

- [ ] **Step 6: Run focused GREEN gates.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/pages/02-rendering-negotiation.t t/pages/03-invocation-composition.t t/pages/04-status-fields-cache.t t/pages/06-lifespan-decline.t t/pages/07-response-for.t'
  git diff --check
  ```

  Expected: existing Pages behavior and the new materialization contract pass.

- [ ] **Step 7: Commit and update the ledger.** Commit Task 4 as `Expose Pages response materialization`, then commit the exact tracking evidence.

---

### Task 5: Prove HTTP, WebSocket, and SSE Integration Without New Lifecycles

**Files:**

- Create: `t/auth/04-protocol-integration.t`
- Modify: `lib/PAGI/WebSocket.pm` (POD only)
- Modify: `lib/PAGI/SSE.pm` (POD only)
- Modify: `lib/PAGI/Response.pm` (POD only)
- Modify: `lib/PAGI/Response/File.pm` (POD only if the Auth cross-link adds useful clarity)

**Interfaces:**

- HTTP Request handler returns an Auth outcome application directly
- Native app uses `invoke_app($outcome, $scope, $receive, $send)`
- WebSocket uses `await $ws->deny($outcome->response_for($ws))`
- SSE uses `await $sse->decline($outcome->response_for($sse))`

- [ ] **Step 1: Write failing HTTP integration tests.** Use `compose`, `route`, and `PAGI::Test::Client` to prove a one-Request handler can return `challenge(...)` directly. Add a raw native app that uses `invoke_app`; assert both negotiate 401 representations and preserve separate challenges.

- [ ] **Step 2: Write failing WebSocket and SSE tests.** Build direct protocol handlers:

  ```perl
  my $failure = challenge(
      challenges => [bearer(realm => 'private')],
      as          => 'json',
  );

  async sub denied_socket {
      my ($ws) = @_;
      return await $ws->deny($failure->response_for($ws));
  }

  async sub declined_stream {
      my ($sse) = @_;
      return await $sse->decline($failure->response_for($sse));
  }
  ```

  Through `PAGI::Test::Client`, assert WebSocket denial and SSE decline yield captured 401 Responses with `application/problem+json`, `Cache-Control: no-store`, and one Bearer field. Add a direct WebSocket scope without the denial extension and assert the existing policy-close fallback remains intact.

- [ ] **Step 3: Pin lifecycle and capability regression.** Reuse the existing pending-send test idiom to prove start-send failure leaves the protocol object pending/retryable, start settlement owns the slot, body backpressure/disconnect behavior is unchanged, and terminal close callbacks run once. Assert Pages-selected concrete classes advertise `body-events-v1`; a File response remains rejected. These tests must exercise existing public adapters rather than adding Auth runtime code.

- [ ] **Step 4: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/auth/04-protocol-integration.t'
  ```

  Expected: pre-integration failures identify any missing Auth/Pages behavior; if it already passes solely from Tasks 1–4, record that as an integration characterization gate rather than manufacturing a failure.

- [ ] **Step 5: Add only lifecycle-boundary documentation.** Update POD with complete snippets and explicit lifecycle prose: `response_for` creates local Response state but sends nothing; `deny`/`decline` validate capability and own mapped sends, settlement, disconnect, and cleanup; start-send resolution means accepted by the server, not delivered to the client. Cite PAGI's body-only denial rule in File POD. Do not add runtime behavior merely to make this task produce a diff.

- [ ] **Step 6: Run focused GREEN and regression gates.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/auth/04-protocol-integration.t t/routing/17-request-response.t t/websocket/denial-response.t t/sse/13-decline.t t/response/03-stream.t t/response/04-file.t'
  git diff --check
  ```

  Expected: all focused protocol, settlement, and capability tests pass unchanged except for additive assertions.

- [ ] **Step 7: Commit and update the ledger.** Commit Task 5 as `Document and prove auth protocol outcomes`, then commit the tracking update.

---

### Task 6: Add the Explicit Cookie Login Policy Example

**Files:**

- Create: `examples/auth-cookie-login/app.pl`
- Create: `examples/auth-cookie-login/README.md`
- Create: `t/integration-auth-cookie-login.t`
- Modify: `examples/README.md`

**Interfaces:**

- Demo credential: username `demo`, password `secret`
- Routes: `GET /`, `GET /login`, `POST /login`, `POST /logout`
- Global Session middleware with cookie name `hello_session`
- This example demonstrates redirect/session application policy and does not use `PAGI::Auth`

- [ ] **Step 1: Write the failing Test Client journey.** Create `t/integration-auth-cookie-login.t` to load the example and assert:

  ```perl
  my $client = PAGI::Test::Client->new(app => $app);
  my $protected = $client->get('/');
  is $protected->status, 303;
  is $protected->header('Location'), '/login';

  my $invalid = $client->post('/login', form => {
      username => 'demo', password => 'wrong',
  });
  is $invalid->status, 200;
  like $invalid->text, qr/Invalid username or password/;

  my $login = $client->post('/login', form => {
      username => 'demo', password => 'secret',
  });
  is $login->status, 303;
  is $login->header('Location'), '/';

  my $home = $client->get('/');
  is $home->status, 200;
  like $home->text, qr/Hello, demo/;

  my $logout = $client->post('/logout');
  is $logout->status, 303;
  is $client->get('/')->header('Location'), '/login';
  ```

  Also prove the session identifier changes on successful login, invalid login does not create authenticated state, GET cannot submit login/logout, and an unknown path receives Compose's normal default.

- [ ] **Step 2: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-auth-cookie-login.t'
  ```

  Expected: FAIL because the example does not exist.

- [ ] **Step 3: Implement the small Request-first example.** Use `PAGI::Session qw(session)`, `PAGI::Pages qw(redirect not_found)`, `PAGI::Response qw(html_response)`, and explicit Route methods. The login handler must regenerate before setting identity:

  ```perl
  async sub login_submit {
      my ($request) = @_;
      my $form = await $request->form_params(strict => 1);
      my $username = $form->get('username') // '';
      my $password = $form->get('password') // '';

      return login_page('Invalid username or password.')
          unless $username eq 'demo' && $password eq 'secret';

      my $session = session($request);
      $session->regenerate;
      $session->set(user => $username);
      return redirect('/', status => 303);
  }

  async sub logout {
      my ($request) = @_;
      session($request)->destroy;
      return redirect('/login', status => 303);
  }

  compose(
      routes => [
          route('/' => \&home, methods => ['GET']),
          route('/login' => \&login_form, methods => ['GET']),
          route('/login' => \&login_submit, methods => ['POST']),
          route('/logout' => \&logout, methods => ['POST']),
      ],
      http_default => not_found(),
      middleware => [middleware(
          'Session',
          secret      => 'demo-only-secret-change-me',
          cookie_name => 'hello_session',
          expire      => 3600,
      )],
  );
  ```

  `home` uses `session($request)->get('user', undef)` and redirects if absent. Keep all HTML fixed or safely escaped; never reflect arbitrary credentials into it.

- [ ] **Step 4: Document its boundary honestly.** README includes exact run command using the runner-supplied library path, demo credential, request flow, and a boxed warning: one worker only with the default memory store; production needs TLS, a secret from protected configuration, `secure => 1`, CSRF protection, login throttling, and a shared store. Explain that login redirect is application policy; Phase 1 Auth outcomes are for 401/403 and do not perform login.

- [ ] **Step 5: Run the GREEN gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-auth-cookie-login.t t/middleware/10-session-auth.t'
  git diff --check
  ```

  Expected: the new journey and existing Session/Auth middleware regression suite pass.

- [ ] **Step 6: Commit and update the ledger.** Commit Task 6 as `Add cookie login policy example`, then commit tracking evidence.

---

### Task 7: Update the Starlette Apples Canary With an Outcome-Only Route

**Files:**

- Modify: `examples/starlette-apples/app.pl`
- Modify: `examples/starlette-apples/README.md`
- Modify: `t/integration-starlette-apples.t`

**Interfaces:**

- New named route: `GET /apples/auth-required`, local name `auth_required`
- Handler returns a Bearer 401 outcome; it does not parse or validate a token
- Representations: HTML, text, and RFC 9457 problem JSON

- [ ] **Step 1: Write the failing canary assertions.** Extend `t/integration-starlette-apples.t` with three requests:

  ```perl
  my $problem = $client->get('/apples/auth-required',
      headers => { Accept => 'application/problem+json' });
  is $problem->status, 401;
  is $problem->header_all('WWW-Authenticate'), ['Bearer realm="apples"'];
  is $problem->json->{detail}, 'A valid access token is required.';

  my $text = $client->get('/apples/auth-required',
      headers => { Accept => 'text/plain' });
  is $text->content_type, 'text/plain; charset=utf-8';

  my $html = $client->get('/apples/auth-required',
      headers => { Accept => 'text/html' });
  is $html->content_type, 'text/html; charset=utf-8';
  ```

  Assert global RequestId and mounted `X-Apples-API` middleware still apply, HEAD suppresses the body while preserving the challenge, and the named route precedes `/{apple_id:&Int}` so `auth-required` does not become a constraint miss.

- [ ] **Step 2: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-starlette-apples.t'
  ```

  Expected: FAIL because `/apples/auth-required` is not declared.

- [ ] **Step 3: Add the handler and Route exactly once.** In `app.pl`:

  ```perl
  use PAGI::Auth qw(challenge bearer);

  async sub authentication_required($request) {
      return challenge(
          challenges => [bearer(realm => 'apples')],
          detail      => 'A valid access token is required.',
      );
  }

  route('/auth-required' => \&authentication_required,
      methods => ['GET'], name => 'auth_required'),
  ```

  Do not add credential parsing, state, or auth middleware. Copy the complete current Perl source into README exactly as its existing source-sync test expects; leave the supplied Python block byte-for-byte unchanged.

- [ ] **Step 4: Update README usage and rationale.** Add curl examples for the three representations and explain that this route demonstrates outcome construction only. It always challenges on purpose; Phase 2 will own credential acquisition and identity state.

- [ ] **Step 5: Run the GREEN gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-starlette-apples.t t/auth/03-outcomes.t'
  git diff --check
  ```

  Expected: the source checksum/synchronization checks and all old/new apples behavior pass.

- [ ] **Step 6: Commit and update the ledger.** Commit Task 7 as `Demonstrate auth outcomes in apples`, then commit tracking evidence.

---

### Task 8: Complete Public Documentation, Distribution Integration, and Final Verification

**Files:**

- Modify: `lib/PAGI/Auth.pm`
- Modify: `lib/PAGI/Auth/Challenge.pm`
- Modify: `lib/PAGI/Auth/Outcomes.pm`
- Modify: `lib/PAGI/Pages/Application.pm`
- Modify: `lib/PAGI/Pages.pm`
- Modify: `lib/PAGI/Tools/Cookbook.pod`
- Modify: `lib/PAGI/Tools/Tutorial.pod`
- Modify: `lib/PAGI/Tools.pm`
- Modify: `t/00-load.t`
- Modify: `t/00-pod/cookbook-examples.t` only if its current extraction table needs explicit new snippets
- Modify: `Changes`

**Interfaces:** No new runtime interface. This task documents and verifies the exact public contracts from Tasks 1–7.

- [ ] **Step 1: Write failing load/discovery assertions.** Add all three new modules to `t/00-load.t`. Where the existing Cookbook harness can execute a self-contained Auth snippet, add it without inventing a second test runner. Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/00-load.t t/00-pod/cookbook-examples.t'
  ```

  Expected RED: load test fails before the module list/source documentation is fully integrated, or record a characterization pass if task-ordering already satisfies loadability.

- [ ] **Step 2: Complete module POD.** Document every export, tag, constructor/factory option, grammar, status mapping, diagnostic category, and example. Explicitly state:

  ```text
  PAGI::Auth::Challenge is protocol metadata, not a Response.
  challenge()/forbid() return reusable Pages applications.
  response_for() is synchronous materialization and sends no events.
  Each WWW-Authenticate challenge remains a separate field line.
  error_description is public wire text and must never contain secrets.
  Basic and Bearer require TLS in real deployments.
  ```

  Include configured `MyApp::Pages` presentation with `PAGI::Auth::Outcomes->new(pages => ...)`, custom scheme construction, unknown Bearer extension semantics, and the explicit absolute `error_uri` choice.

- [ ] **Step 3: Add complete Cookbook recipes.** Add named sections for Basic challenge, missing Bearer token, invalid Bearer token, insufficient scope, multiple challenges, explicit login redirect, deliberate 404 concealment, WebSocket denial, SSE decline, native `invoke_app`, and custom Pages presentation. Every snippet labels whether it is a Request handler, WebSocket endpoint, SSE endpoint, or native triplet app. Correct the existing SSE recipe so its 401 has a structured Bearer `WWW-Authenticate` value:

  ```perl
  my $failure = challenge(
      challenges => [bearer(realm => 'events')],
      as          => 'text',
  );
  return await $sse->decline($failure->response_for($sse));
  ```

  Explain that `response_for` creates the concrete local Response and `decline` performs event emission.

- [ ] **Step 4: Add the concise Tutorial and discovery links.** Tutorial shows one missing-token `challenge` and one permission `forbid` without teaching parser/provider code. `PAGI::Tools` lists Auth outcomes separately from the legacy auth middleware. Cross-link the cookie-login example as explicit application policy, not an alternate Auth renderer.

- [ ] **Step 5: Update `Changes`.** Under `0.002003 - UNRELEASED`, add one concrete section covering structured Basic/Bearer/custom challenges, challenge/forbid Pages applications, separate repeated fields, `response_for`, explicit WS/SSE materialization, the apples canary, and the cookie-login policy example. State that credential/identity middleware remains Phase 2.

- [ ] **Step 6: Run the complete focused gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/auth/01-challenge-values.t t/auth/02-bearer.t t/auth/03-outcomes.t t/auth/04-protocol-integration.t t/pages/02-rendering-negotiation.t t/pages/03-invocation-composition.t t/pages/04-status-fields-cache.t t/pages/06-lifespan-decline.t t/pages/07-response-for.t t/routing/17-request-response.t t/websocket/denial-response.t t/sse/13-decline.t t/response/03-stream.t t/response/04-file.t t/middleware/10-session-auth.t t/integration-auth-cookie-login.t t/integration-starlette-apples.t t/00-load.t t/00-pod/cookbook-examples.t'
  ```

  Expected: all named files pass. Record actual file/test counts and timing.

- [ ] **Step 7: Audit architecture and forbidden drift.** Run:

  ```bash
  rg -n 'PAGI::Auth' lib/PAGI/Pages.pm lib/PAGI/Pages/Application.pm lib/PAGI/Response.pm lib/PAGI/WebSocket.pm lib/PAGI/SSE.pm lib/PAGI/Request.pm
  rg -n 'Authorization|credential|password|token' lib/PAGI/Auth.pm lib/PAGI/Auth/Challenge.pm lib/PAGI/Auth/Outcomes.pm
  rg -n 'WWW-Authenticate' lib/PAGI/Auth.pm lib/PAGI/Auth/Outcomes.pm lib/PAGI/Tools/Cookbook.pod examples/starlette-apples examples/auth-cookie-login
  git diff --check
  git status -sb
  ```

  Classify every match. Expected: lower layers mention Auth only in POD cross-links; Auth does not parse credentials; the cookie example alone contains the hardcoded password and labels it; no source scope mutation/cache, send wrapper, lifecycle copy, or middleware behavior change appears.

- [ ] **Step 8: Run the full suite once.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t'
  ```

  Expected: PASS. If failures occur, use `superpowers:systematic-debugging`; distinguish campaign regressions from independently reproduced baseline/environment failures and record evidence. Do not simply rerun the suite.

- [ ] **Step 9: Build and inspect the distribution.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && dzil build'
  tar -tzf PAGI-Tools-0.002002.tar.gz | rg 'PAGI/Auth|README.md|Changes'
  ```

  Expected: build succeeds; all three Auth modules, generated README, and Changes ship; `docs/` and `.superpowers/` remain pruned. If Dist::Zilla uses a different archive version because branch metadata has changed, inspect that exact generated archive and record it rather than renaming it.

- [ ] **Step 10: Commit documentation/integration and finalize tracking.** Commit exact Task 8 paths as `Document authentication outcomes`, then update the tracking document with its SHA, the complete spec-coverage table, all focused/full/build evidence, and any ruled deviations. Commit the tracking update separately.

- [ ] **Step 11: Reconfirm the work map and prepare review.** Run:

  ```bash
  git status -sb
  git branch --show-current
  git rev-parse HEAD
  git log --oneline --decorate --max-count=20
  git diff --stat c4c007f7a0603c2e36cd88266f2289db4f3baa12..HEAD
  ```

  Confirm the branch remains local, no sibling repository changed, unrelated untracked notes remain untouched, every task has evidence, and no open `DEV-NNN` remains. Do not push or open a PR until the user requests it.

## Final Review Checklist

- `challenge` always produces 401 and at least one separate challenge line.
- `forbid` produces 403 and works with no challenge.
- The known Bearer status matrix is enforced; unknown extension errors stay open without inferred semantics.
- Basic/Bearer/custom builders reject injection and malformed input synchronously.
- Auth never sees credentials or request bodies.
- Pages owns negotiation, encoding, RFC 9457, caching, and rendering.
- `response_for` does not emit and does not mutate its source.
- WebSocket/SSE retain all denial/decline lifecycle ownership.
- File remains opted out of body-only protocol response adaptation.
- Existing auth middleware is unchanged and still passes.
- Cookie login is clearly policy/demo code and is covered end to end.
- Apples remains source-synchronized, preserves the Python block, and demonstrates all three representations.
- The full runnable multi-protocol authentication application is explicitly deferred to Phase 2.
- Full suite and distribution build evidence are recorded once at the final boundary.
