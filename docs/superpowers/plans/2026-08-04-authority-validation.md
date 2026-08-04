# Authority Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one fail-closed `PAGI::Authority` implementation and route every
current Host-aware Request, Context, URL middleware, and trusted proxy rewrite
through it without changing middleware protocol gates.

**Architecture:** `PAGI::Authority` is a stateless, non-exporting service module
that validates one authority, enforces unique Host cardinality, and formats the
scope-server fallback used by absolute URLs. Request and Context expose the
semantic Host accessor; existing HTTP middleware translates Authority failures
to 400 while retaining its own trust and allowlist policy. ReverseProxy remains
the only request-header mutator and explicitly invalidates the inherited header
snapshot after producing one Host pair.

**Tech Stack:** Perl 5.18-compatible source, core `Socket`, `Future`,
`Future::AsyncAwait`, `Test2::V0`, existing PAGI scope/header contracts, and the
repository's IO::Async test harness. No new runtime dependency.

## Global Constraints

- The approved design is the source of truth:
  `docs/superpowers/specs/2026-08-04-authority-design.md`.
- Work only in `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools`.
- Preserve the unrelated untracked files `.cpan-testers-fix-report.md`,
  `.csrf-helper-brief.md`, and `.csrf-helper-report.md`. Never stage them.
- Use classic argument unpacking (`my ($self, $value) = @_`) in shipped code
  and tests. The distribution supports Perl 5.18; do not use signatures,
  postfix dereferencing, `try`/`catch`, or other newer syntax.
- Add no URI/IDNA dependency. Use core `Socket` only to validate IPv6. Do not
  resolve DNS or accept Unicode, IPvFuture, zone IDs, percent escapes, or
  alternate numeric-IP spellings.
- `PAGI::Authority` exports nothing, holds no mutable package/request state,
  mutates no caller input, and caches no derived authority in scope.
- Preserve valid authority spelling and every explicit Host-header port.
  Server-derived default ports are omitted only under the exact scheme rules in
  the design.
- Never include the rejected raw authority in an exception or HTTP error body.
- Keep generic `header($name)` and `PAGI::Headers->get($name)` last-value
  behavior unchanged. They are the documented raw escape hatch.
- Do not extend ReverseProxy, TrustedHosts, or HTTPSRedirect beyond their
  existing scope-type gates. The cross-protocol middleware migration remains a
  separate design.
- Catch only the direct Authority call in Host-aware middleware. Do not catch
  downstream or unrelated middleware exceptions.
- Follow TDD for every behavior: add a focused failing assertion, run it and
  observe the expected failure, implement the minimum behavior, rerun the
  focused test, then run neighboring tests.
- Use stable diagnostic fragments such as `invalid authority`, `Host header
  must occur at most once`, and `scope server cannot provide an authority`.
  Capture intentional failures with `dies`; test output must remain clean.
- Put POD beside `PAGI::Authority`, both public `host` accessors, and every
  changed middleware behavior in the task that introduces it.
- Each task ends in a focused commit after tests pass. Stage named files; never
  use `git add -A` or `git add .`.
- Before Task 1, both execution modes must run the
  `superpowers:subagent-driven-development` skill's `scripts/sdd-workspace`
  helper for this plan and create
  `.superpowers/sdd/2026-08-04-authority-validation/progress.md`. Its first line
  is:

  ```text
  # SDD ledger — plan: docs/superpowers/plans/2026-08-04-authority-validation.md
  ```

  Maintain this task table:

  ```text
  Task | Status | Commit range | Focused verification | Full-suite verification | Review
  ```

  Status is `pending`, `in_progress`, `complete`, or `blocked`. Verification
  cells contain the coordinator-observed exact command, exit status, and actual
  test count. After implementation and review, the coordinator independently
  verifies the commit range and tests, updates the row, appends the
  skill-compatible `Task <N>: complete (...)` recovery line, and only then
  advances.
- The same ledger contains:

  ```text
  ID | Status | Conflicting plan text | Evidence and rationale | Affected tasks | User decision
  ```

  Use stable IDs such as `DEV-001`. A proposed deviation blocks dependent work
  until the user's explicit decision is recorded. Retain rejected and
  superseded entries. The controller, not an implementation worker, owns this
  table.
- Run Perl commands through the project Perl:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/authority.t'
  ```

- Run the whole suite after Tasks 3, 4, and 5 and before claiming completion:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t'
  ```

---

### Task 1: Stateless authority parser and scope fallback

**Files:**

- Create: `lib/PAGI/Authority.pm`
- Create: `t/authority.t`
- Modify: `t/00-load.t`

**Interfaces:**

- Produces: `PAGI::Authority->validate($value) -> $safe_string`, croaking on
  undefined, referenced, empty, or malformed input.
- Produces: `PAGI::Authority->host_from_scope($scope) -> $safe_string | undef`,
  croaking on malformed header shape or more than one Host pair.
- Produces: `PAGI::Authority->from_scope($scope) -> $safe_string`, preferring a
  valid Host and using `scope->{server}` only when Host is absent.
- All three methods are synchronous class methods and mutate nothing.

- [ ] **Step 1: Write the failing direct-validation tests.** Create
  `t/authority.t` with `Test2::V0` and table-driven assertions. The valid table
  includes `example.com`, `Example.COM`, `localhost`, `api_v1.example`,
  `example.com.`, `192.0.2.1`, `[2001:db8::1]`, `example.com:80`,
  `example.com:00080`, and `[2001:db8::1]:443`; assert exact spelling is
  returned. The invalid table includes `undef`, a scalar reference, empty,
  whitespace/control/non-ASCII, each forbidden delimiter, empty/consecutive
  registered-name labels, malformed brackets, unbracketed IPv6, zone ID,
  IPvFuture, `127.1`, `2130706433`, `01.2.3.4`, `256.1.1.1`, empty/nondigit
  port, and 65536. Use stable diagnostics without asserting line numbers:

  ```perl
  for my $case (@valid) {
      is(
          PAGI::Authority->validate($case),
          $case,
          "valid authority is preserved: $case",
      );
  }

  like(
      dies { PAGI::Authority->validate('example.com/path') },
      qr/invalid authority/,
      'path delimiter is rejected',
  );
  ```

- [ ] **Step 2: Write the failing Host-cardinality and fallback tests.** Cover
  absent headers, one mixed-case Host, duplicate identical/conflicting/mixed
  case Host pairs, undefined pair values, malformed header/pair shapes, and
  immutable input. Cover server hostname/IPv4/unbracketed IPv6, an optional
  bracketed IPv6 server host, ports 0/80/443/8443, missing scheme defaulting to
  HTTP, unknown scheme retaining a defined port, invalid tuple lengths/ports,
  and no source. Explicitly prove a malformed or duplicate Host never falls
  back to an otherwise valid server:

  ```perl
  my $scope = {
      scheme  => 'https',
      headers => [['Host', 'good.example'], ['host', 'evil.example']],
      server  => ['fallback.example', 443],
  };

  like(
      dies { PAGI::Authority->from_scope($scope) },
      qr/Host header must occur at most once/,
      'duplicate Host cannot fall back to server',
  );
  ```

- [ ] **Step 3: Run the new test and observe the missing-module failure.** Run
  the project-Perl command for `t/authority.t`. Expected: FAIL because
  `PAGI/Authority.pm` does not exist.

- [ ] **Step 4: Implement the private parser and public validation method.** In
  `PAGI::Authority`, use `strict`, `warnings`, `Carp qw(croak)`, and core
  `Socket qw(AF_INET6 inet_pton)`. Reject anything outside visible ASCII before
  structural parsing. Parse either bracketed IPv6 plus optional port, or one
  colon-free registered name/IPv4 plus optional port:

  ```perl
  sub validate {
      my ($class, $value) = @_;
      _invalid() unless defined $value && !ref($value) && length($value);
      _invalid() if $value =~ /[^\x21-\x7e]/;

      my ($host, $port);
      if ($value =~ /\A\[([^\[\]]+)\](?::([0-9]+))?\z/) {
          ($host, $port) = ($1, $2);
          _invalid() unless inet_pton(AF_INET6, $host);
      } elsif ($value =~ /\A([^:]+)(?::([0-9]+))?\z/) {
          ($host, $port) = ($1, $2);
          _validate_reg_name_or_ipv4($host);
      } else {
          _invalid();
      }

      _validate_port($port) if defined $port;
      return $value;
  }
  ```

  `_validate_reg_name_or_ipv4` requires nonempty dot-separated labels from
  `[A-Za-z0-9_~-]+`, permitting exactly one optional trailing dot. When the
  entire host contains only digits and dots, require exactly four canonical
  decimal octets matching `(?:0|[1-9][0-9]{0,2})`, each at most 255. This also
  rejects a bare decimal integer and abbreviated IP. `_validate_port` compares
  the digit string without numeric overflow: strip leading zeroes into a copy,
  then reject a significant length over five or a five-digit value lexically
  greater than `65535`. `_invalid` croaks `invalid authority` without echoing
  input.

- [ ] **Step 5: Implement scope Host extraction and server fallback.** Validate
  `$scope` and the raw header-pair shape, ASCII-fold field names, collect all
  Host values, and enforce cardinality before calling `validate`:

  ```perl
  sub host_from_scope {
      my ($class, $scope) = @_;
      croak 'authority scope must be a hashref' unless ref($scope) eq 'HASH';
      my $pairs = $scope->{headers} // [];
      croak 'scope headers must be an arrayref of pairs'
          unless ref($pairs) eq 'ARRAY';

      my @host;
      for my $pair (@$pairs) {
          croak 'scope headers must be an arrayref of pairs'
              unless ref($pair) eq 'ARRAY' && @$pair == 2
                  && defined $pair->[0] && !ref($pair->[0])
                  && defined $pair->[1] && !ref($pair->[1]);
          my $name = $pair->[0];
          $name =~ tr/A-Z/a-z/;
          push @host, $pair->[1] if $name eq 'host';
      }

      croak 'Host header must occur at most once' if @host > 1;
      return undef unless @host;
      return $class->validate($host[0]);
  }
  ```

  `from_scope` returns that value when defined. Otherwise require a one- or
  two-element server tuple and delegate to a private formatter:

  ```perl
  sub from_scope {
      my ($class, $scope) = @_;
      my $host = $class->host_from_scope($scope);
      return $host if defined $host;

      my $scheme = defined $scope->{scheme} ? lc($scope->{scheme}) : 'http';
      return _format_server($scope->{server}, $scheme);
  }
  ```

  Validate the tuple's non-IPv6 host with the same private helper; accept
  bracketed or unbracketed core-validated IPv6 and emit brackets. Validate the
  structured port with the same decimal range rule. Omit only server-derived 80
  for `http`/`ws` and 443 for `https`/`wss`; missing scheme is `http`, and
  unknown schemes have no default. Croak `scope server cannot provide an
  authority` for every unusable fallback without embedding values.

- [ ] **Step 6: Add complete module POD and the load assertion.** Document all
  three methods, accepted/rejected grammar, explicit-versus-server port
  handling, failure behavior, absence versus invalidity, no caching/mutation,
  and the difference from raw last-value header lookup. Add `PAGI::Authority`
  to `@core_modules` in `t/00-load.t`.

- [ ] **Step 7: Run focused and neighboring tests.** Run `t/authority.t`,
  `t/00-load.t`, and `t/headers.t` through project Perl. Expected: all pass with
  no warning output. Run `git diff --check`.

- [ ] **Step 8: Commit Task 1.** Stage only `lib/PAGI/Authority.pm`,
  `t/authority.t`, and `t/00-load.t`; commit with message
  `Authority: validate Host and scope fallback`. After implementation review,
  complete Task 1's ledger row and recovery line before Task 2.

---

### Task 2: Request and cross-protocol Context Host accessors

**Files:**

- Modify: `lib/PAGI/Request.pm`
- Modify: `lib/PAGI/Context.pm`
- Modify: `t/request/01-basic.t`
- Modify: `t/context/01-factory.t`

**Interfaces:**

- Consumes: `PAGI::Authority->host_from_scope($scope)` from Task 1.
- Produces: `$request->host -> $validated_host | undef`.
- Produces: base `$context->host -> $validated_host | undef`, inherited by
  HTTP, WebSocket, and SSE Context classes.
- Preserves: `$request->header('host')` and `$context->header('host')` as raw
  last-value lookups.

- [ ] **Step 1: Add failing Request accessor tests.** Retain the existing valid
  assertion and add missing, explicit-port, malformed, duplicate-identical,
  duplicate-conflicting, and mixed-case duplicate cases. In the duplicate case
  assert that raw `header('host')` still returns the last value while `host`
  croaks:

  ```perl
  my $request = PAGI::Request->new({
      type    => 'http',
      headers => [['Host', 'one.example'], ['host', 'two.example']],
  });

  is($request->header('host'), 'two.example', 'raw lookup remains last-value');
  like(dies { $request->host }, qr/Host header must occur at most once/);
  ```

- [ ] **Step 2: Add failing Context inheritance tests.** Construct HTTP,
  WebSocket, and SSE Contexts over equivalent scopes and assert the same valid,
  missing, malformed, and duplicate behavior. Also prove the base raw
  `header('host')` behavior is unchanged and `host` does not add a scope cache
  key.

- [ ] **Step 3: Run both focused files and observe failures.** Run
  `t/request/01-basic.t` and `t/context/01-factory.t`. Expected: duplicate
  Request tests fail under last-wins semantics and Context has no `host` method.

- [ ] **Step 4: Delegate both accessors.** Load `PAGI::Authority` explicitly in
  each module and keep each method as a one-line semantic delegation:

  ```perl
  sub host {
      my ($self) = @_;
      return PAGI::Authority->host_from_scope($self->{scope});
  }
  ```

  Do not route this through `header`, `headers`, or the
  `pagi.request.headers` cache.

- [ ] **Step 5: Update Request and Context POD.** State that `host` returns the
  complete validated Host field, including an explicit port; returns `undef`
  only when absent; and croaks on malformed/duplicate fields. Add the method to
  Context's scope-accessor synopsis and protocol-shape documentation, explicitly
  noting that all three built-in Context types inherit it. Document
  `header('host')` as the raw escape hatch.

- [ ] **Step 6: Run focused and neighboring tests.** Run
  `t/request/01-basic.t`, all `t/context` tests, `t/headers.t`, and `t/00-load.t`.
  Expected: all pass and the generic header tests remain unchanged. Run
  `git diff --check`.

- [ ] **Step 7: Commit Task 2.** Stage the four named files and commit with
  message `Request: share validated Host with Context`. After implementation
  review, complete Task 2's ledger row and recovery line before Task 3.

---

### Task 3: TrustedHosts and HTTPSRedirect authority handling

**Files:**

- Modify: `lib/PAGI/Middleware/TrustedHosts.pm`
- Modify: `lib/PAGI/Middleware/HTTPSRedirect.pm`
- Modify: `t/middleware/06-security.t`
- Modify: `t/middleware/11-url-handling.t`

**Interfaces:**

- Consumes: `host_from_scope` for TrustedHosts and `from_scope` for
  HTTPSRedirect.
- Produces: generic HTTP 400 start/body events for Authority failure without
  invoking downstream.
- Preserves: TrustedHosts allowlist/`allow_empty`, HTTPS exclusions/HSTS, and
  every non-HTTP pass-through gate.

- [ ] **Step 1: Add failing TrustedHosts security tests.** Use a downstream
  call counter and event capture. Cover duplicate-identical,
  duplicate-conflicting, malformed, one valid explicit port, missing with
  `allow_empty => 1`, and missing without it. Require status 400 and no
  downstream call for Authority failures. Add a WebSocket scope containing
  duplicate Host and prove it still passes through untouched under the current
  type gate. With one valid Host, make downstream die and assert the wrapped
  Future fails with that exact downstream diagnostic rather than converting it
  to 400.

- [ ] **Step 2: Add failing HTTPSRedirect tests.** Cover valid Host preference,
  explicit `:80` preservation, absent Host plus `server => ['example.com', 80]`
  producing `https://example.com/path`, server IPv6 formatting, query
  retention, duplicate/malformed Host returning 400, absent Host plus unusable
  server returning 400, and no downstream call on failures. Retain a non-HTTP
  pass-through assertion whose downstream app dies and prove that exception is
  not caught as an Authority failure.

- [ ] **Step 3: Run the two focused middleware files and observe failures.**
  Expected: TrustedHosts can accept the first duplicate, HTTPSRedirect can use
  an arbitrary first Host or `localhost`, and the new failure cases do not
  produce the required 400 behavior.

- [ ] **Step 4: Replace TrustedHosts' private Host scan.** Remove its `_get_header`
  use for Host. Evaluate only the synchronous Authority call, save `$@`, and
  branch before downstream:

  ```perl
  my ($host, $authority_error);
  {
      local $@;
      $host = eval { PAGI::Authority->host_from_scope($scope) };
      $authority_error = $@;
  }
  if ($authority_error) {
      await $self->_send_error($send, 400, 'Invalid Host header');
      return;
  }
  ```

  Apply the existing `allow_empty` and allowlist logic only after successful
  parsing. Do not include Authority diagnostics in the response and do not
  widen the initial `type ne 'http'` branch.

- [ ] **Step 5: Replace HTTPSRedirect authority construction.** Around only
  `PAGI::Authority->from_scope($scope)`, capture a synchronous error as above.
  On error call a new local async `_send_error($send, 400, 'Invalid Host
  header')` that emits one `http.response.start` and one terminal body with
  correct Content-Length. On success concatenate `https://$authority`, the
  existing path, and existing query. Remove `_get_header` and the `localhost`
  default. Keep scheme pass-through, HSTS, and exclusion checks in their
  current order.

- [ ] **Step 6: Update both middleware POD sections.** TrustedHosts documents
  duplicate/malformed 400 behavior and raw allowlist matching after structural
  validation. HTTPSRedirect documents Host preference, server-only fallback,
  no invented localhost, and 400 failure. Both explicitly say their existing
  non-HTTP pass-through remains unchanged.

- [ ] **Step 7: Run focused, neighboring, and full suites.** Run
  `t/middleware/06-security.t`, `t/middleware/11-url-handling.t`,
  `t/middleware/03-error-handler.t`, and the full suite. Confirm Authority
  failures are handled locally but a deliberately dying downstream app still
  propagates to ErrorHandler. Run `git diff --check`.

- [ ] **Step 8: Commit Task 3.** Stage the four named files and commit with
  message `Middleware: fail closed on invalid Host authority`. After review,
  record focused/full evidence and complete Task 3's ledger row before Task 4.

---

### Task 4: ReverseProxy unique Host rewriting and cache safety

**Files:**

- Modify: `lib/PAGI/Middleware/ReverseProxy.pm`
- Modify: `t/middleware/11-url-handling.t`

**Interfaces:**

- Consumes: `PAGI::Authority->validate($forwarded_host)` only after the existing
  trusted-proxy decision.
- Produces: exactly one Host pair after a valid trusted `X-Forwarded-Host`, plus
  a shallow scope without inherited `pagi.request.headers`.
- Produces: HTTP 400/no downstream call for repeated or invalid trusted
  forwarded Host.
- Preserves: untrusted requests, requests without `X-Forwarded-Host`, other
  forwarded-field behavior, original scope/header arrays, and non-HTTP gates.

- [ ] **Step 1: Add failing trusted rewrite tests.** Cover valid forwarded Host
  with zero, one, and multiple incoming Host pairs. Assert downstream sees
  exactly `[['host', $validated]]` for the Host subset, unrelated header order
  is retained, and the input scope/header pairs remain byte-for-byte unchanged.

- [ ] **Step 2: Add failing ambiguity/error tests.** Cover repeated identical,
  repeated conflicting, mixed-case repeated `X-Forwarded-Host`, comma-containing
  value, malformed authority, and an explicit port over 65535. Require generic
  400 events and no downstream call. Give an untrusted proxy the same malformed
  field and prove ReverseProxy does not validate or reject it.

- [ ] **Step 3: Add the stale-snapshot regression.** Before invoking wrapped
  middleware, construct `PAGI::Request` over the input scope and call
  `headers()` so `pagi.request.headers` is populated. In downstream construct a
  fresh Request over the rewritten scope and assert both `host` and
  `header('host')` see the forwarded value. Assert the original scope still
  owns its original cached snapshot.

- [ ] **Step 4: Run `t/middleware/11-url-handling.t` and observe failures.**
  Expected: missing original Host is not inserted, multiple original Host pairs
  survive as duplicates, repeated forwarded fields are selected arbitrarily,
  malformed forwarded authority passes, and the cloned cached snapshot is stale.

- [ ] **Step 5: Collect and validate trusted forwarded Host once.** Immediately
  after the trusted-proxy check, collect field lines with an ASCII-folded name.
  No field leaves Host unchanged; more than one sends 400 and returns. For one,
  evaluate only the Authority validation call:

  ```perl
  my @forwarded_host = map { $_->[1] }
      grep {
          my $name = $_->[0];
          $name =~ tr/A-Z/a-z/;
          $name eq 'x-forwarded-host';
      } @{ $scope->{headers} // [] };

  if (@forwarded_host > 1) {
      await $self->_send_error($send, 400, 'Invalid forwarded Host');
      return;
  }
  ```

  For exactly one, call `PAGI::Authority->validate`; translate failure into the
  same generic 400. Do not use `_get_header` for this field and do not expose
  the rejected value.

- [ ] **Step 6: Replace Host atomically and invalidate the cloned cache.** In
  the existing shallow `%new_scope`, remove every case-insensitive Host pair,
  append one `['host', $safe_forwarded_host]`, assign a new header arrayref, and
  delete `$new_scope{'pagi.request.headers'}`. Do this even when the incoming
  scope has no Host. Do not mutate pair arrays owned by the input scope.

- [ ] **Step 7: Add the local 400 sender and update POD.** Add an async
  `_send_error` with correct status/body/Content-Length events. Document
  trusted-only validation, exactly-one forwarded field, comma rejection,
  exactly-one resulting Host, cache invalidation, and unchanged protocol gates.
  Do not claim support for RFC `Forwarded` or forwarded chains.

- [ ] **Step 8: Run focused, Request, and full suites.** Run
  `t/middleware/11-url-handling.t`, `t/request/01-basic.t`, `t/headers.t`, and
  the full suite. Run `git diff --check` and inspect the diff to prove no
  unrelated forwarded-header policy changed.

- [ ] **Step 9: Commit Task 4.** Stage only the module and test file; commit
  with message `ReverseProxy: replace trusted Host without ambiguity`. After
  review, record focused/full evidence and complete Task 4's ledger row before
  Task 5.

---

### Task 5: Release documentation and final verification

**Files:**

- Modify: `Changes`
- Verify POD in: `lib/PAGI/Authority.pm`
- Verify POD in: `lib/PAGI/Request.pm`
- Verify POD in: `lib/PAGI/Context.pm`
- Verify POD in: `lib/PAGI/Middleware/TrustedHosts.pm`
- Verify POD in: `lib/PAGI/Middleware/HTTPSRedirect.pm`
- Verify POD in: `lib/PAGI/Middleware/ReverseProxy.pm`

**Interfaces:**

- Produces: one user-visible compatibility/security note for every changed
  public accessor and middleware behavior.
- Produces: release-ready POD and distribution tests.
- Establishes: the authority implementation is complete, allowing the separate
  declarative-routing implementation plan to begin.

- [ ] **Step 1: Add an unreleased Changes section.** Add `0.002003` above the
  released `0.002002` entry. Describe the shared Authority module, strict
  Request/Context Host accessors, TrustedHosts/HTTPSRedirect 400 behavior,
  ReverseProxy exactly-one rewrite/cache invalidation, raw `header('host')`
  escape hatch, and unchanged non-HTTP middleware gates. Label the stricter
  duplicate/malformed behavior as intentional security hardening.

- [ ] **Step 2: Audit all changed POD against the approved spec.** Confirm each
  method says whether it returns a local value or sends response events; Host
  versus server fallback is unambiguous; explicit/default ports are explained;
  raw lookup is distinguished; proxy trust remains outside Authority; and no
  page claims the deferred cross-protocol middleware extension shipped.

- [ ] **Step 3: Run POD validation.** Through project Perl, run `podchecker` on
  each of the six named modules. Expected: every file reports syntax OK. Run
  `t/00-load.t` again.

- [ ] **Step 4: Run focused final verification.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/authority.t t/request/01-basic.t t/context/01-factory.t t/middleware/06-security.t t/middleware/11-url-handling.t'
  ```

  Record actual file/assertion counts and exit status in the ledger.

- [ ] **Step 5: Run distribution verification.** Run the complete suite, then
  `dzil test` under the project Perl. Inspect the generated MANIFEST/build input
  and confirm `lib/PAGI/Authority.pm` is included while `docs/` and the three
  unrelated untracked files are absent. Run `git diff --check` and
  `git status --short`.

- [ ] **Step 6: Commit documentation or verification corrections.** Stage only
  `Changes` and any named POD-bearing module actually corrected in this task.
  Commit with message `docs: document strict authority handling`. Do not create
  an empty commit if Task 1–4 POD needed no correction beyond the Changes entry.

- [ ] **Step 7: Complete final review and ledger.** Independently verify every
  task commit range, focused evidence, full-suite evidence, and the absence of
  unrelated files. Complete Task 5's ledger row and recovery line. Authority is
  not complete until this gate passes; declarative routing remains blocked on
  it.

## Plan Self-Review

- Spec coverage: Tasks 1–5 cover all public APIs, grammar/fallback rules,
  Request/Context delegation, current HTTP middleware consumers, ReverseProxy
  cache mutation, compatibility notes, protocol-gate preservation, and tests.
- Placeholders: no TBD/TODO/deferred implementation steps remain. Deferred
  cross-protocol middleware behavior is explicitly outside this plan and has a
  separate design.
- Interface consistency: every consumer calls one of Task 1's exact class
  methods; `host` is header-only while `from_scope` owns server fallback;
  middleware catches only those synchronous calls.
