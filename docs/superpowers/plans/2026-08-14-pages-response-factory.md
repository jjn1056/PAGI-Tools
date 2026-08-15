# PAGI Pages Response Factory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `PAGI::Pages`, a synchronous response factory and dual-shape
endpoint for negotiated welcome, error, and redirect pages, then make it the
single source of first-party generic HTTP responses throughout PAGI-Tools.

**Architecture:** `PAGI::Pages` is an immutable request-independent policy
object. Every call creates a fresh descriptor and `PAGI::Response`; calls with
an HTTP Context/scope return that response immediately, while calls without a
request source return one plain coderef that also speaks native PAGI. Existing
components retain ownership of *when* a response is needed and delegate only
the default representation to Pages. Shared Request negotiation is corrected
first, then Pages lands in cohesive slices before integration call sites are
migrated.

**Tech Stack:** Perl 5.18-compatible distribution code, `Future`,
`Future::AsyncAwait`, `PAGI::Response`, `PAGI::Request`,
`PAGI::Request::Negotiate`, `JSON::MaybeXS`, `HTTP::Date`, `Encode`,
`Test2::V0`, `PAGI::Test::Client`, POD, and Dist::Zilla. No new dependency.

## Global Constraints

- The approved contract is
  `docs/superpowers/specs/2026-08-14-pages-response-factory-design.md`. If
  implementation evidence conflicts with it, record a deviation and obtain
  the user's decision before dependent work continues.
- Backward compatibility is not required. Delete `PAGI::App::NotFound` and
  `PAGI::App::Redirect`; remove ErrorHandler's `content_type` option without an
  alias, ignored option, or deprecation shim.
- Work only in
  `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` or an isolated
  worktree created for this repository by the Superpowers worktree workflow.
- Preserve the unrelated untracked files `.cpan-testers-fix-report.md`,
  `.csrf-helper-brief.md`, `.csrf-helper-report.md`, and visual-companion state
  under `.superpowers/`. Never stage them.
- Keep every file under `lib/` and every ordinary test parseable on Perl 5.18:
  use classic `@_` unpacking and avoid signatures, postfix dereferencing,
  `try`/`catch`, and newer syntax. Existing Perl 5.40+ examples may retain
  signatures.
- `PAGI::Pages` performs bounded synchronous in-memory construction only. It
  must not read files, access the network, invoke subprocesses, dynamically
  load renderers, rasterize images, or create Futures while building a page.
  Only `Response->respond($send)` performs asynchronous wire work.
- A class call constructs a fresh instance of the invoked class; there is no
  singleton. Instances, compiled endpoints, descriptors, and responses must
  not retain mutable request state across concurrent calls.
- The only constructor options are `as => auto|html|json|text` and
  `default => html|json|text`. There is no Pages object in scope, renderer
  registry, Context convenience method, Compose Pages option, Pages-specific
  endpoint object, `to_app`, or automatic localization.
- An omitted request source means “return a deferred endpoint.” A supplied
  HTTP scope or `PAGI::Context::HTTP` means “return a fresh unsent Response.”
  Never infer sending from the presence of `$send` except in the exact native
  triplet invocation of the deferred coderef.
- Require explicit HTTP scope type for Pages. Missing, empty, reference-valued,
  WebSocket, SSE, lifespan, and extension types croak before any HTTP event.
- Use `Future->wrap($returned)` wherever a callback, handler, reporter, target,
  or response send may complete immediately or through a Future. Never
  directly `await` a possibly immediate value.
- Stock English copy must be safe for end users. Production responses never
  contain exception text, decoder diagnostics, filesystem paths, credentials,
  tokens, raw rejected header values, or other dynamic internals.
- All stock HTML/text is strictly UTF-8 encoded before it enters Response;
  Content-Length is byte-correct. JSON encoding and renderer failures occur
  before response start.
- Validate raw response headers before inserting them into `PAGI::Headers`.
  Reject malformed names, controls, wide values, references, odd flat lists,
  Pages-owned fields, and semantic/raw single-field conflicts.
- Stock HTML embeds a small percent-encoded `image/svg+xml` data URI showing
  the exact three-digit status. The leading digit is large, the final two are
  smaller, and the approved family colors are `#566f60`, `#566a78`,
  `#8a7743`, and `#82505a`, with `#faf8f1` glyphs. Do not add PNG assets or
  golden/pixel tests.
- Only HTTP default branches adopt Pages. Preserve health protocol JSON,
  bodyless 204/304 and successful range responses, CORS preflight, WebSocket
  and SSE behavior, synthetic test infrastructure failures, custom handlers,
  callback bodies, and examples whose literal response is the lesson.
- Use TDD for each behavior: write the smallest focused failing assertion, run
  it and record the expected failure, implement, rerun the focused test, then
  run the named task regression gate.
- Use `PAGI::Test::Client` for complete HTTP outcomes. Use a direct
  scope/receive/send recorder only for unsent Responses, malformed invocation,
  post-start errors, non-HTTP rejection, or exact raw event ownership.
- Capture intended failures with `dies` and assert stable semantic fragments,
  never Perl file/line suffixes. Test output must remain warning-free except
  where the Context warning contract is itself under test.
- Put public POD beside each changed public API, option, response default, and
  protocol boundary in the task that changes it. Task 12 reconciles the wider
  Tutorial, Cookbook, README, upgrade guide, Changes, and examples.
- Stage only files named by the current task. Never use `git add .` or
  `git add -A`. `docs/superpowers` is ignored; use `git add -f` only for the
  exact plan path.
- Every implementation task ends with one focused commit and review gate. The
  coordinator independently checks the diff, focused output, commit SHA, and
  ledger row before the next task starts.
- Run the repository-wide `prove -lr t` suite exactly once at the final
  reviewed HEAD. Focused tests may be rerun as TDD requires. Do not run
  `dzil test`, because it repeats the suite. If the final suite exposes a
  defect and HEAD changes, record the failure/fix and run one new final suite
  at the corrected HEAD.
- Run Perl commands through the project Perl. For example:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/pages/02-rendering-negotiation.t'
  ```

## Execution Tracking and Deviation Control

Before Task 1, create the isolated execution workspace using the selected
execution skill. When using subagent-driven development, run:

```bash
/Users/jnapiorkowski/.codex/plugins/cache/openai-curated-remote/superpowers/6.2.0/skills/subagent-driven-development/scripts/sdd-workspace docs/superpowers/plans/2026-08-14-pages-response-factory.md
```

The command must print a directory ending in
`.superpowers/sdd/2026-08-14-pages-response-factory`. Create its `progress.md`
with this exact first line and tables:

```markdown
# SDD ledger — plan: docs/superpowers/plans/2026-08-14-pages-response-factory.md

| Task | Status | Commit range | Focused verification | Full-suite verification | Review |
|---|---|---|---|---|---|
| 1 | pending | — | — | deferred to Task 14 | — |
| 2 | pending | — | — | deferred to Task 14 | — |
| 3 | pending | — | — | deferred to Task 14 | — |
| 4 | pending | — | — | deferred to Task 14 | — |
| 5 | pending | — | — | deferred to Task 14 | — |
| 6 | pending | — | — | deferred to Task 14 | — |
| 7 | pending | — | — | deferred to Task 14 | — |
| 8 | pending | — | — | deferred to Task 14 | — |
| 9 | pending | — | — | deferred to Task 14 | — |
| 10 | pending | — | — | deferred to Task 14 | — |
| 11 | pending | — | — | deferred to Task 14 | — |
| 12 | pending | — | — | deferred to Task 14 | — |
| 13 | pending | — | — | deferred to Task 14 | — |
| 14 | pending | — | — | final gate | — |

## Deviations

| ID | Status | Conflicting plan text | Evidence and rationale | Affected tasks | User decision |
|---|---|---|---|---|---|
```

Before Task 1, run `git rev-parse HEAD`. Store the exact 40-character SHA in
`.superpowers/sdd/2026-08-14-pages-response-factory/starting-head` with one
trailing newline and add `Starting HEAD: SHA` to `progress.md`. Record
`git status --short`, including every preserved untracked file.

The coordinator owns the ledger. Update each row in the same working step as
its commit/review with exact commands, exit statuses, actual test-file and
assertion counts, elapsed time, commit SHA, and review evidence—never estimates
or a worker's unsupported summary.

A contract conflict gets the next stable ID (`DEV-001`, `DEV-002`, then
sequentially numbered IDs), status `awaiting decision`, exact conflicting text,
concrete evidence, and every blocked task. Record the user's explicit approval,
rejection, or replacement before dependent work continues. An ordinary defect
whose fix preserves the approved contract is not a deviation.

## File and Responsibility Map

- `lib/PAGI/Pages/_Catalog.pm`: private checked-in error catalog, named-method
  mapping, fresh entry copies, and “default can render without external facts”
  predicate. It has no public POD or introspection promise.
- `lib/PAGI/Pages.pm`: public constructor, invocation-shape dispatcher,
  descriptor creation, option/header validation, negotiation, rendering hooks,
  exact-status SVG, response construction, semantic fields, cache policy, and
  redirect target handling.
- `lib/PAGI/Request/Negotiate.pm`: effective-quality matching and documented
  bidirectional wildcard queries shared by Pages and ContentNegotiation.
- `lib/PAGI/Context.pm`: strict scope-type factory validation and warn-once
  generic Context fallback for explicit extension types.
- Routing fallback middleware and `PAGI::Middleware::ErrorHandler`: retain
  triggering/lifecycle policy but delegate stock body construction to Pages.
- Existing App/Middleware/Endpoint modules in Tasks 7–11: retain each trigger
  and component-owned facts, replace only generic default response emission.
- `t/pages/01-catalog.t` through `05-composition.t`: focused Pages unit and
  composition contract.
- Existing component tests plus `t/app-proxy.t`: trigger-specific adoption and
  negative-boundary coverage without repeating the complete Pages format
  matrix at every call site.
- `examples/pages`: one compact runnable route/mount/Compose/raw demonstration.
- `examples/15-large-application`: one natural Context-to-Pages response while
  preserving intentional branded routing-ownership catchalls.
- `UPGRADING.md`, `Changes`, `README.md`, `PAGI::Tools` Tutorial/Cookbook,
  module POD, and example READMEs: public migration and usage guidance.

---

### Task 1: Correct Shared Negotiation and Context Type Resolution

**Files:**

- Modify: `lib/PAGI/Request/Negotiate.pm`
- Modify: `t/request-negotiate.t`
- Modify: `lib/PAGI/Context.pm`
- Modify: `t/context/01-factory.t`
- Modify: `t/context/06-extension.t`

**Interfaces:**

- `PAGI::Request::Negotiate->best_match(\@supported, $accept)` returns the
  original supported spelling with the greatest positive effective quality;
  ties retain `@supported` order.
- `quality_for_type($accept, $concrete)` remains the most-specific matching
  range primitive.
- `accepts_type($accept, $type_or_wildcard)` uses effective quality for a
  concrete type and retains documented wildcard-query behavior.
- `PAGI::Context->_resolve_class($scope)` croaks on malformed/missing type,
  returns a mapped class when present, and otherwise returns exactly
  `PAGI::Context` after warning once per invoking-factory/type pair.

- [ ] **Step 1: Add failing effective-quality negotiation tests.** Extend the
  existing subtests with this exact table-driven shape:

  ```perl
  my @best_cases = (
      [['text/html', 'application/json'],
       'text/html;q=0, */*;q=1', 'application/json'],
      [['text/html', 'application/json'],
       'text/*;q=0, */*;q=0.5', 'application/json'],
      [['application/json', 'text/html'],
       'application/json;q=0.7, text/html;q=0.7', 'application/json'],
  );
  for my $case (@best_cases) {
      is(PAGI::Request::Negotiate->best_match($case->[0], $case->[1]),
          $case->[2], "effective match for $case->[1]");
  }

  my @accept_cases = (
      ['text/html;q=0, */*;q=1', 'text/html', 0],
      ['text/html',               'text/*',   1],
      ['text/*;q=0, */*;q=1',     'text/*',   0],
      ['text/*;q=0, text/html',   'text/*',   1],
  );
  for my $case (@accept_cases) {
      is(!!PAGI::Request::Negotiate->accepts_type($case->[0], $case->[1]),
          !!$case->[2], "wildcard query for $case->[0]");
  }
  ```

- [ ] **Step 2: Run the negotiation red test.** Run the project-Perl command
  for `prove -lv t/request-negotiate.t`. Expected: the positive global wildcard
  incorrectly revives `text/html`, and the excluded-family wildcard query is
  incorrectly true.

- [ ] **Step 3: Implement effective-quality selection.** Replace the
  accepted-range-first loop with supported-type-first scoring:

  ```perl
  sub best_match {
      my ($class, $supported, $accept) = @_;
      return unless $supported && @$supported;
      my ($winner, $winner_q);
      for my $candidate (@$supported) {
          my $q = $class->quality_for_type($accept, $candidate);
          next unless $q > 0;
          if (!defined($winner) || $q > $winner_q) {
              ($winner, $winner_q) = ($candidate, $q);
          }
      }
      return $winner;
  }
  ```

  For concrete `accepts_type`, return `quality_for_type(...) > 0`. For a
  wildcard query, first test the wildcard's own effective quality, then test
  each concrete Accept range covered by that wildcard using
  `quality_for_type`; this preserves `text/html` satisfying `text/*`, lets a
  positive concrete exception reopen an excluded family, and prevents a less
  specific positive range from reopening a directly excluded family.

- [ ] **Step 4: Add failing Context factory tests.** Replace the old “unknown
  falls back to HTTP” assertion and cover strict malformed types, mapped custom
  types, generic extension identity, and warning cardinality:

  ```perl
  like(dies { PAGI::Context->new({ headers => [] }, sub {}, sub {}) },
      qr/scope type.*required/i, 'missing type is malformed');

  my @warnings;
  my ($first, $second);
  {
      local $SIG{__WARN__} = sub { push @warnings, @_ };
      $first  = PAGI::Context->new({ type => 'mcp', marker => 1 }, sub {}, sub {});
      $second = PAGI::Context->new({ type => 'mcp', marker => 2 }, sub {}, sub {});
  }
  is(ref($first), 'PAGI::Context', 'unknown explicit type uses generic base');
  is($first->scope->{marker}, 1, 'generic Context preserves raw scope');
  ok(!$first->can('response'), 'generic Context has no HTTP response API');
  is(scalar @warnings, 1, 'factory/type warning is emitted once');
  like($warnings[0], qr/PAGI::Context.*mcp/, 'warning names factory and type');
  ```

  Add a second factory subclass to prove its own `mcp` warning is independent,
  and a `_type_map` entry to prove mapped extension types do not warn.

- [ ] **Step 5: Implement strict type resolution and warn-once fallback.** Use
  a lexical `%WARNED_UNMAPPED` keyed by invoking class plus type. Validate that
  scope is an unblessed hashref and type is a defined nonempty scalar. Return
  `$class->_type_map->{$type}` when mapped; otherwise `warn` once and return the
  literal base class `PAGI::Context`, not `$class` and not the HTTP mapping.
  Update constructor and extensibility POD to state this contract.

- [ ] **Step 6: Run focused regressions and commit.** Run the project-Perl
  command for:

  ```text
  prove -lv t/request-negotiate.t t/context/01-factory.t t/context/06-extension.t
  ```

  Expected: PASS with warning assertions captured. Commit only the five Task 1
  files with `git commit -m "fix: make negotiation and Context type resolution exact"`.

---

### Task 2: Private Pages Status Catalog

**Files:**

- Create: `lib/PAGI/Pages/_Catalog.pm`
- Create: `t/pages/01-catalog.t`

**Interfaces:**

- `PAGI::Pages::_Catalog->_entry($status)` returns a fresh hashref containing
  `status`, `method`, `title`, and nonempty safe `detail`, or `undef`.
- `_code_for_method($method)` returns the numeric code or `undef`.
- `_named_methods` returns a fresh arrayref in numeric order.
- The package is private implementation, is not added to public load lists,
  and has no documented public introspection contract.

- [ ] **Step 1: Create focused source/test directories.** Run:

  ```bash
  mkdir -p lib/PAGI/Pages t/pages
  ```

- [ ] **Step 2: Write the failing catalog matrix.** Create a table with every
  approved named method/code pair and verify fresh entries, titles, details,
  absence of 418/510, and default completeness:

  ```perl
  my @named = (
      [400 => 'bad_request'], [401 => 'unauthorized'],
      [402 => 'payment_required'], [403 => 'forbidden'],
      [404 => 'not_found'], [405 => 'method_not_allowed'],
      [406 => 'not_acceptable'], [407 => 'proxy_authentication_required'],
      [408 => 'request_timeout'], [409 => 'conflict'], [410 => 'gone'],
      [411 => 'length_required'], [412 => 'precondition_failed'],
      [413 => 'content_too_large'], [414 => 'uri_too_long'],
      [415 => 'unsupported_media_type'], [416 => 'range_not_satisfiable'],
      [417 => 'expectation_failed'], [421 => 'misdirected_request'],
      [422 => 'unprocessable_content'], [423 => 'locked'],
      [424 => 'failed_dependency'], [425 => 'too_early'],
      [426 => 'upgrade_required'], [428 => 'precondition_required'],
      [429 => 'too_many_requests'],
      [431 => 'request_header_fields_too_large'],
      [451 => 'unavailable_for_legal_reasons'],
      [500 => 'internal_server_error'], [501 => 'not_implemented'],
      [502 => 'bad_gateway'], [503 => 'service_unavailable'],
      [504 => 'gateway_timeout'], [505 => 'http_version_not_supported'],
      [506 => 'variant_also_negotiates'], [507 => 'insufficient_storage'],
      [508 => 'loop_detected'], [511 => 'network_authentication_required'],
  );
  for my $pair (@named) {
      my ($code, $method) = @$pair;
      my $entry = PAGI::Pages::_Catalog->_entry($code);
      is($entry->{method}, $method, "$method maps to $code");
      ok(length($entry->{title}), "$method has a title");
      ok(length($entry->{detail}), "$method has safe detail");
      is(PAGI::Pages::_Catalog->_code_for_method($method), $code,
          "$method reverse lookup");
  }
  ok(!PAGI::Pages::_Catalog->_entry(418), 'unused 418 is absent');
  ok(!PAGI::Pages::_Catalog->_entry(510), 'obsolete 510 is absent');
  ```

- [ ] **Step 3: Run the catalog red test.** Run the project-Perl command for
  `prove -lv t/pages/01-catalog.t`. Expected: FAIL because the private catalog
  module does not exist.

- [ ] **Step 4: Implement the static catalog.** Use one lexical table with the
  exact registered titles from spec section 6.3 and concise English safe
  details. Return copies such as `{ %{$ERRORS{$status}} }`; never return the
  stored row. Do not add `AUTOLOAD`, runtime IANA lookup, module loading,
  mutable access, or public POD.

- [ ] **Step 5: Run and commit.** Run `prove -lv t/pages/01-catalog.t` through
  the project Perl. Expected: PASS. Commit the two Task 2 files with
  `git commit -m "feat: add private Pages status catalog"`.

---

### Task 3: Pages Invocation, Rendering, Negotiation, and SVG

**Files:**

- Create: `lib/PAGI/Pages.pm`
- Create: `t/pages/02-rendering-negotiation.t`
- Create: `t/pages/03-invocation-composition.t`
- Modify: `t/00-load.t`

**Interfaces:**

- `PAGI::Pages->new(as => 'auto', default => 'html')` returns an immutable
  policy instance and rejects every unknown/invalid option.
- `welcome`, `status`, and all named error methods support class and instance,
  immediate Context/scope, and deferred forms from spec sections 5–6.
- A deferred endpoint supports `($context, @ignored_metadata)`, `($scope)`, and
  `($scope, $receive, $send)`; the native triplet returns the Future from
  `Response->respond`.
- Presentation hooks are `render_html`, `render_text`, `render_problem`,
  `render_json`, and `favicon_href`. They receive one fresh descriptor and
  return synchronous Unicode/hash/scalar values as documented.
- `status` accepts registered catalog errors and strict custom 400–599 errors;
  named methods are ordinary installed subs, not `AUTOLOAD`.

- [ ] **Step 1: Write failing constructor and invocation tests.** Use explicit
  HTTP scope and Context fixtures and assert the ownership distinction:

  ```perl
  my $scope = {
      type => 'http', method => 'GET', path => '/', headers => [],
      http_version => '1.1', query_string => '',
  };
  my @events;
  my $send = sub { push @events, $_[0]; return Future->done };
  my $ctx = PAGI::Context->new($scope, sub { Future->done }, $send);

  my $response = PAGI::Pages->not_found($ctx, as => 'text');
  isa_ok($response, 'PAGI::Response');
  is(\@events, [], 'immediate Context form is unsent');

  my $endpoint = PAGI::Pages->not_found(as => 'text');
  is(ref($endpoint), 'CODE', 'deferred endpoint is a plain coderef');
  isa_ok($endpoint->($ctx, bless({}, 'Local::Snapshot')), 'PAGI::Response');
  Future->wrap($endpoint->($scope, sub { Future->done }, $send))->get;
  is($events[0]{status}, 404, 'native triplet sends the page');
  ```

  Cover invalid constructor options, invalid arities/channels, missing and
  non-HTTP types, class-call freshness, subclass class dispatch, scope-only
  calls, and a generic custom-protocol Context from Task 1.

- [ ] **Step 2: Write failing rendering and negotiation tests.** Build a helper
  that sends an immediate Response and inspects events, then cover:

  ```perl
  my @cases = (
      [undef,                         'text/html; charset=utf-8'],
      ['*/*',                         'text/html; charset=utf-8'],
      ['text/plain',                  'text/plain; charset=utf-8'],
      ['application/problem+json',    'application/problem+json'],
      ['application/json',            'application/problem+json'],
      ['text/html;q=0, */*;q=1',      'application/problem+json'],
  );
  ```

  Assert default-first tie ordering, fixed `as` ignoring Accept and omitting
  Vary, auto `Vary: Accept` merge without duplicate tokens, total rejection
  falling back to configured default, problem+json not selecting welcome JSON,
  problem standard members, top-level extensions, exact Welcome copy and docs
  link, stable text newline, HTML escaping, UTF-8 byte length, and subclass hook
  dispatch. Assert registered errors require custom `type` and `title` as a
  pair, custom type is absolute and non-`about:blank`, reserved problem members
  cannot be extensions, and `instance` is emitted only when supplied. Assert
  JSON encoding failure happens before send, a full
  `render_html` override owns favicon inclusion, and a returned Response can be
  mutated before `respond`. Add a subclass whose renderer and favicon hook
  return Futures and assert `renderer must return an immediate value` before
  any send.

- [ ] **Step 3: Run the Pages red tests.** Run the project-Perl command for:

  ```text
  prove -lv t/pages/02-rendering-negotiation.t t/pages/03-invocation-composition.t
  ```

  Expected: FAIL because `PAGI::Pages` does not exist.

- [ ] **Step 4: Implement the public invocation dispatcher.** Use
  `Scalar::Util::blessed` to distinguish an HTTP Context from an unblessed
  scope hash. Normalize class invocants with `$class->new`, but retain instance
  identity for subclass hooks. Validate method options before returning a
  deferred coderef. Because options are a flat list, any unblessed hashref in
  request-source position is always treated as a scope candidate and receives
  the explicit-type diagnostic rather than becoming a stringified option key;
  any `PAGI::Context` object is likewise validated as HTTP before dispatch.
  The coderef closes over only the immutable instance and a fresh copy of
  normalized call options; it creates the descriptor per call. Use this exact
  ownership shape:

  ```perl
  return sub {
      my @call = @_;
      if (_is_http_context($call[0])) {
          return $self->_response_for($call[0]->scope, $descriptor_factory->());
      }
      if (_is_http_scope($call[0]) && @call == 1) {
          return $self->_response_for($call[0], $descriptor_factory->());
      }
      if (_is_http_scope($call[0]) && @call == 3
          && ref($call[1]) eq 'CODE' && ref($call[2]) eq 'CODE') {
          my $response = $self->_response_for($call[0], $descriptor_factory->());
          return Future->wrap($response->respond($call[2]));
      }
      croak 'invalid PAGI::Pages endpoint invocation';
  };
  ```

  Context calls may contain ignored trailing metadata; native triplets may not.
  `status` uses `_Catalog`; unknown 400–599 requires explicit absolute
  non-`about:blank` `type`, `title`, and `detail`. Out-of-range, reference, and
  nonnumeric statuses croak. Install every named method from Task 2 as an
  ordinary typeglob assignment during module compilation so `can` works and
  typos fail normally; do not use `AUTOLOAD`.

- [ ] **Step 5: Implement representations and negotiation.** Read Accept via
  `PAGI::Request->new($scope)->header('accept')` and call the corrected shared
  negotiator. For errors, score emitted `application/problem+json` and its
  `application/json` selection alias without allowing the alias to revive an
  exact problem+json q=0 exclusion. Encode hook Unicode with
  `Encode::encode('UTF-8', ..., FB_CROAK)`, encode hashes with
  `JSON::MaybeXS::encode_json`, and construct a new scope-bound Response.
  Validate renderer result shapes before calling body methods. HTML is a
  complete English document with `<html lang="en">`, no inferred navigation,
  and no external resources; text ends with exactly one newline.

- [ ] **Step 6: Implement the light exact-status SVG seam.** Base
  `favicon_href($page)` selects one of the four fixed colors, stringifies the
  already-validated numeric status, places the first digit in the large glyph
  and the final two in the smaller glyph, and percent-encodes the bounded ASCII
  SVG as `data:image/svg+xml,...`. `render_html` HTML-attribute-escapes the URI.
  Test only that stock HTML contains an inline SVG and no `/favicon.ico` or
  external URL, decoded registered `404` contains `404`, decoded custom `599`
  contains `599`, a custom same-origin URI is escaped, and `undef` omits the
  link. Do not assert exact byte count, colors, geometry, fonts, or pixels.

- [ ] **Step 7: Add composition, HEAD, and concurrency coverage.** In
  `t/pages/03-invocation-composition.t`, exercise one endpoint as Route, opaque
  Mount, Compose target, and direct triplet. Assert Mount owns descendants while
  Route does not; Compose owns lifespan and outer HEAD body suppression; a
  custom HEAD route is not bypassed. Invoke one compiled endpoint concurrently
  with two scopes carrying different Accept fields, hold both sends on separate
  Futures, release in reverse order, and assert no descriptor/representation
  leakage.

- [ ] **Step 8: Run focused regressions and commit.** Add `PAGI::Pages` to
  `t/00-load.t`, run the project-Perl command for:

  ```text
  prove -lv t/pages/01-catalog.t t/pages/02-rendering-negotiation.t t/pages/03-invocation-composition.t t/00-load.t
  ```

  Expected: PASS. Commit Task 3 files with
  `git commit -m "feat: add negotiated Pages response factory"`.

---

### Task 4: Status-Specific Fields, Header Validation, and Cache Policy

**Files:**

- Modify: `lib/PAGI/Pages.pm`
- Create: `t/pages/04-status-fields-cache.t`

**Interfaces:**

- Common error options and semantic options are exactly those in spec sections
  7.3 and 7.5; unrelated semantic options croak.
- `headers` is an even flat arrayref and is validated before `PAGI::Headers`.
- 401/407 require challenges; 405 always emits one normalized Allow including
  an empty value; 426 requires Upgrade on HTTP/1.1.
- Errors default to `Cache-Control: no-store`; 428/429/431/511 cannot weaken it.

- [ ] **Step 1: Write the failing field and validation matrix.** Use a table of
  method/options/expected field and include raw-header conflict cases:

  ```perl
  my @field_cases = (
      [unauthorized => { challenge => 'Basic realm="x"' },
       'WWW-Authenticate', 'Basic realm="x"'],
      [method_not_allowed => { allow => ['get', 'HEAD', 'GET'] },
       'Allow', 'GET, HEAD'],
      [range_not_satisfiable => { length => 42 },
       'Content-Range', 'bytes */42'],
      [upgrade_required => { upgrade => ['websocket', 'h2c'] },
       'Upgrade', 'websocket, h2c'],
      [unavailable_for_legal_reasons => { blocked_by => '/authority' },
       'Link', '</authority>; rel="blocked-by"'],
      [network_authentication_required => { login_url => '/login' },
       undef, undef],
  );
  ```

  Add mandatory-missing failures, 426 on HTTP/1.0/2/3, semantic/raw conflicts,
  retry delay and canonical IMF-fixdate, invalid/obsolete dates, unrelated
  semantic options, owned raw fields in mixed case, CRLF/control/wide/reference
  header values, invalid names, odd lists, JSON extension collisions, and the
  reserved 511 `login` member. Prove raw challenge/Allow/Upgrade headers may
  satisfy their mandatory field where permitted, multiple challenges remain
  separate field lines, and 511 `login_url` appears consistently in HTML, text,
  and problem JSON.

- [ ] **Step 2: Write failing cache tests.** Assert every named error defaults
  to no-store; an ordinary error can override it; 428/429/431/511 reject a
  conflicting value; Welcome has no default cache and accepts an explicit one.
  Assert auto Vary merging preserves a caller's `Origin, Accept-Encoding` and
  adds exactly one `Accept` token.

- [ ] **Step 3: Run the red test.** Run the project-Perl command for
  `prove -lv t/pages/04-status-fields-cache.t`. Expected: FAIL because semantic
  fields and strict raw-header validation are not implemented.

- [ ] **Step 4: Implement normalized header assembly.** Before touching
  Response, validate field names with the HTTP token grammar and values as
  narrow printable wire scalars without controls or wide characters. Reject
  `Content-Type`, `Content-Length`, `Transfer-Encoding`, `Location`,
  `Cache-Control`, and `Connection` from raw headers case-insensitively. Parse
  and merge Vary tokens case-insensitively. Apply validated raw headers and
  generated semantic fields only after all validation succeeds.

- [ ] **Step 5: Implement semantic option validators.** Normalize Allow and
  Upgrade with first-seen deduplication; allow the legal empty Allow. Preserve
  multiple challenge field lines. Validate nonnegative integers. Validate an
  IMF-fixdate by requiring both `HTTP::Date::str2time($value)` to succeed and
  `HTTP::Date::time2str($epoch) eq $value`. Validate URI references as narrow
  ASCII scalars without whitespace/control characters and absolute problem
  types with a leading URI scheme. For 426, use
  `PAGI::Request->new($scope)->http_version` and emit owned
  `Connection: Upgrade` only on 1.1.

- [ ] **Step 6: Implement cache and response invariants.** Default all error
  descriptors to no-store. Force no-store for 428/429/431/511 and croak on a
  conflicting override. Leave Welcome uncached by default. Ensure problem JSON
  status comes from the immutable descriptor after subclass rendering and
  cannot be replaced by a renderer hash.

- [ ] **Step 7: Run and commit.** Run the project-Perl command for:

  ```text
  prove -lv t/pages/02-rendering-negotiation.t t/pages/04-status-fields-cache.t
  ```

  Expected: PASS. Commit the two Task 4 files with
  `git commit -m "feat: enforce Pages status fields and cache policy"`.

---

### Task 5: Redirect Pages and Fragment-Safe Query Preservation

**Files:**

- Modify: `lib/PAGI/Pages.pm`
- Create: `t/pages/05-redirects.t`

**Interfaces:**

- `redirect($request_source?, $target, status => 302, %options)` supports only
  301/302/303/307/308.
- Named methods `moved_permanently`, `found`, `see_other`,
  `temporary_redirect`, and `permanent_redirect` pin their status and reject a
  supplied `status` option.
- `preserve_query` defaults false and appends the incoming raw query before a
  fragment without decoding/re-encoding.
- Redirect JSON is ordinary `application/json`, never RFC 9457.

- [ ] **Step 1: Write failing redirect API tests.** Cover every named helper,
  class/instance/immediate/deferred forms, status conflicts, invalid codes,
  absolute/relative targets, controls, wide/reference targets, HTML/text/JSON
  escaping, no default cache, explicit cache, and `retry_after`.

- [ ] **Step 2: Write the query/fragment table.** Use exact expected Location
  values:

  ```perl
  my @cases = (
      ['/search',                    'q=perl', '/search?q=perl'],
      ['/search?',                   'q=perl', '/search?q=perl'],
      ['/search?sort=date',          'q=perl', '/search?sort=date&q=perl'],
      ['/search#results',            'q=perl', '/search?q=perl#results'],
      ['/search?sort=date#results',  'q=perl',
       '/search?sort=date&q=perl#results'],
      ['/search#results',            '',       '/search#results'],
  );
  ```

  For each case assert Location, HTML href/text, plain text, and JSON location
  all describe the same final target. Add a control proving default
  `preserve_query => 0` leaves the target unchanged.

- [ ] **Step 3: Run the red test.** Run the project-Perl command for
  `prove -lv t/pages/05-redirects.t`. Expected: FAIL because redirect methods
  are not present.

- [ ] **Step 4: Implement redirect descriptors and target merging.** Split the
  target once at the first `#`, merge the raw incoming query into the pre-fragment
  portion, normalize a trailing empty `?`, and reattach the untouched fragment.
  Never decode or re-encode the incoming query. Put the exact merged scalar in
  Location and descriptor; renderers independently escape their body form.
  Preserve fixed/auto negotiation rules from Task 3 and redirect cache rules
  from Task 4.

- [ ] **Step 5: Run and commit.** Run the project-Perl command for:

  ```text
  prove -lv t/pages/02-rendering-negotiation.t t/pages/04-status-fields-cache.t t/pages/05-redirects.t
  ```

  Expected: PASS. Commit Task 5 files with
  `git commit -m "feat: add correct Pages redirect responses"`.

---

### Task 6: Routing Fallbacks, ErrorHandler, and Compose Defaults

**Files:**

- Modify: `lib/PAGI/Middleware/Routing/NotFound.pm`
- Modify: `lib/PAGI/Middleware/Routing/MethodNotAllowed.pm`
- Modify: `lib/PAGI/Middleware/ErrorHandler.pm`
- Modify: `lib/PAGI/Compose/Compiler.pm`
- Modify: `t/routing/15-fallback-middleware.t`
- Modify: `t/middleware/03-error-handler.t`
- Modify: `t/middleware/error-handler-contract.t`
- Modify: `t/compose/04-middleware.t`
- Modify: `t/compose/06-failsafes.t`

**Interfaces:**

- Routing fallback matching, checkpoints, handler contracts, and 405 response
  proxy remain unchanged; only `_default_response` delegates to Pages.
- ErrorHandler public options are `development`, `on_error`, `status`, and
  `handler`. The built-in renderer negotiates through Pages.
- Without a custom handler, only registered errors renderable without missing
  mandatory facts are accepted/preserved; all other status claims become 500.
- A Pages rendering failure before response start emits one hardcoded UTF-8
  `Internal Server Error\n` response with no-store. Post-start failure is
  reported and rethrown with no second response.

- [ ] **Step 1: Update fallback tests to fail against Pages semantics.** Keep
  all existing trace-selection assertions, but send Accept headers and assert
  problem JSON/HTML/text. Preserve custom-handler byte assertions. For 405,
  return a custom response with stale duplicate Allow fields and retain the
  existing proxy assertion that exactly one computed union survives.

- [ ] **Step 2: Update ErrorHandler/Compose tests to fail.** Add cases for
  removed `content_type`, negotiated built-ins, configured/exception statuses,
  invalid and throwing `status_code`, a Future-valued status claim, production
  secrecy, development detail, invalid `PAGI_ENV`, Pages renderer failure,
  post-start rethrow, and inner custom Pages middleware. Pin public defaults to
  `development => 0`, `status => 500`, `on_error => undef`; prove a custom
  handler may retain a normally incomplete 401 seed and owns its content type
  and cache policy unchanged. Replace old literal body assertions with
  status/content-type/semantic-body assertions.

- [ ] **Step 3: Run the red regression set.** Run the project-Perl command for:

  ```text
  prove -lv t/routing/15-fallback-middleware.t t/middleware/03-error-handler.t t/middleware/error-handler-contract.t t/compose/04-middleware.t t/compose/06-failsafes.t
  ```

  Expected: FAIL because defaults still use local text/HTML and ErrorHandler
  still accepts `content_type`.

- [ ] **Step 4: Delegate routing defaults.** Require `PAGI::Pages` in each
  fallback class. NotFound passes the current safe/diagnostic detail to
  `PAGI::Pages->not_found($context, detail => $detail)`. MethodNotAllowed passes
  `allow => $snapshot->allowed_methods` and the detail, then retains
  `_prepare_response` unchanged so the send proxy remains authoritative for
  custom and stock 405 values. Replace removed-App comparison POD with terminal
  Pages endpoint examples.

- [ ] **Step 5: Refactor ErrorHandler around Pages.** Reject unknown options
  and remove `content_type` storage and `_generate_error_body`. If no custom
  handler, validate configured status at construction by attempting
  `PAGI::Pages->status($status)`; if it croaks, rethrow a stable diagnostic that
  says a handler is required. At runtime, call `status_code` inside `eval`,
  reject any reference/Future/nonnumeric result, and attempt the same Pages
  endpoint validation before preserving it. Keep the original exception for
  `on_error` and diagnostics. Put exception stringification behind its own
  `eval`; a throwing overload cannot replace the original exception or escape
  the production-safe 500 path. Only a successfully obtained string may enter
  development detail, never production detail.

  Render with:

  ```perl
  my $response = $self->{handler}
      ? await Future->wrap($self->{handler}->($context, $error))
      : PAGI::Pages->status($context, $status, detail => $safe_detail);
  await Future->wrap($context->respond($response));
  ```

  Wrap built-in Pages construction in its own pre-start `eval`. On failure,
  send one hardcoded 500 with `Content-Type: text/plain; charset=utf-8`,
  byte-correct length, and `Cache-Control: no-store`; include no dynamic error
  text. If that send fails, propagate the current failure. Continue awaiting
  and containing `on_error`; continue reporting/rethrowing after response start.
  The private Compose development resolver remains exception-safe and treats an
  invalid environment as production. Update ErrorHandler POD with the four
  remaining options, Pages-backed negotiation, custom-handler fixed-format
  examples, status-claim rules, and hardcoded last-resort behavior.

- [ ] **Step 6: Keep Compose's graph, remove representation configuration.**
  Delete only `content_type => 'text/plain'` from the automatic ErrorHandler
  construction. Do not add Pages options or detect inner fallback instances.
  Assert outer HEAD, trace, ErrorHandler, guard, NotFound, MethodNotAllowed,
  author middleware, target order remains unchanged.

- [ ] **Step 7: Run and commit.** Run the Step 3 focused set through the project
  Perl. Expected: PASS. Commit Task 6 files with
  `git commit -m "feat: render routing and error defaults through Pages"`.

---

### Task 7: File, Directory, and Static Defaults

**Files:**

- Modify: `lib/PAGI/App/File.pm`
- Modify: `lib/PAGI/App/Directory.pm`
- Modify: `lib/PAGI/Middleware/Static.pm`
- Modify: `t/app-file.t`
- Modify: `t/34-directory-security.t`
- Modify: `t/middleware/04-static.t`

**Interfaces:**

- File delegates 400/403/404/405/416, passing `Allow: GET, HEAD` and known file
  length for 416.
- Directory delegates only its pre-File 403 branches; its listing and
  delegation order remain unchanged.
- Static delegates 403/404/500/416 only when it owns the response; pass-through
  and successful file/range behavior remain unchanged.

- [ ] **Step 1: Add failing adoption tests.** For each component, send one
  `Accept: application/problem+json` default branch and assert Pages media type,
  status, safe body, no-store, and Vary. Add File 405 exact Allow, File and
  Static invalid-range `Content-Range: bytes */N`, and text/HTML representative
  branches. Assert valid file bytes, HEAD, 206, 304, and Static pass-through are
  unchanged.

- [ ] **Step 2: Pin Directory ordering.** Add explicit cases proving a missing
  or unresolved candidate remains Directory's Pages-backed 403, POST to a
  listing remains 200, POST to a resolved delegated file reaches File's 405,
  and invalid Range against a resolved index reaches File's 416.

- [ ] **Step 3: Run the red tests.** Run the project-Perl command for:

  ```text
  prove -lv t/app-file.t t/34-directory-security.t t/middleware/04-static.t
  ```

  Expected: generic branches still emit literal local bodies and lack required
  405/416 fields.

- [ ] **Step 4: Replace private error senders with Pages responses.** Reshape
  each private helper to receive the original `$scope` and call, for example:

  ```perl
  my $response = PAGI::Pages->method_not_allowed(
      $scope, allow => [qw(GET HEAD)],
  );
  await Future->wrap($response->respond($send));
  ```

  Use `range_not_satisfiable($scope, length => $size)` only after size is known.
  Keep trigger decisions, filesystem safety checks, file streaming, range
  parsing, and pass-through control flow local. Update component POD to explain
  negotiated defaults and retained custom/pass-through seams.

- [ ] **Step 5: Run and commit.** Run the Step 3 focused set through the project
  Perl. Expected: PASS. Commit Task 7 files with
  `git commit -m "feat: render file defaults through Pages"`.

---

### Task 8: Authentication and Authority-Security Defaults

**Files:**

- Modify: `lib/PAGI/Middleware/Auth/Basic.pm`
- Modify: `lib/PAGI/Middleware/Auth/Bearer.pm`
- Modify: `lib/PAGI/Middleware/CSRF.pm`
- Modify: `lib/PAGI/Middleware/ReverseProxy.pm`
- Modify: `lib/PAGI/Middleware/TrustedHosts.pm`
- Modify: `t/middleware/10-session-auth.t`
- Modify: `t/middleware/06-security.t`
- Modify: `t/middleware/11-url-handling.t`

**Interfaces:**

- Basic/Bearer default failures delegate 401 with a scheme-specific safely
  quoted challenge; their successful auth scopes remain unchanged.
- CSRF enforced default delegates 403; `enforce => 'app'` and application-owned
  Context responses stay literal.
- ReverseProxy/TrustedHosts retain all authority decisions and delegate their
  generic HTTP 400 branches only.

- [ ] **Step 1: Add failing auth tests.** Exercise missing, malformed, and
  rejected credentials under problem JSON and text Accept values. Assert one
  correct `WWW-Authenticate` field. Use realms containing quote and backslash,
  and reject CR/LF field-delimiter attempts before any event:

  ```perl
  my @realms = (
      ['team "blue"', 'team \\"blue\\"'],
      ['team\\blue',  'team\\\\blue'],
  );
  ```

  Preserve successful Basic/Bearer identity/claims tests byte-for-byte.

- [ ] **Step 2: Add failing security-default tests.** Cover CSRF enforced 403,
  ReverseProxy invalid forwarded authority, and TrustedHosts missing,
  duplicate, structurally malformed, and structurally valid but allowlist-
  rejected Host. Assert `enforce => 'app'`, permitted hosts, normalized proxy
  scopes, and non-HTTP pass-through remain outside Pages.

- [ ] **Step 3: Run the red tests.** Run the project-Perl command for:

  ```text
  prove -lv t/middleware/10-session-auth.t t/middleware/06-security.t t/middleware/11-url-handling.t
  ```

  Expected: default branches still emit local literal bodies.

- [ ] **Step 4: Delegate while retaining protocol facts.** Add one private realm
  quoting helper per auth scheme that escapes backslash before quote, build the
  complete challenge locally, and pass it through Pages' `challenge` option.
  Reshape private default senders to accept `$scope` and use Pages Responses.
  Keep credential validation, CSRF policy, authority normalization, allowlist
  matching, and non-HTTP pass-through in their current classes. Do not add a
  configurable Pages object to any component. Update each affected POD to state
  that only its built-in HTTP failure negotiates through Pages and that existing
  custom/pass-through behavior remains authoritative.

- [ ] **Step 5: Run and commit.** Run the Step 3 set through the project Perl.
  Expected: PASS. Commit Task 8 files with
  `git commit -m "feat: render auth and authority failures through Pages"`.

---

### Task 9: Body Parsing and Content Negotiation Defaults

**Files:**

- Modify: `lib/PAGI/Middleware/ContentNegotiation.pm`
- Modify: `lib/PAGI/Middleware/FormBody.pm`
- Modify: `lib/PAGI/Middleware/JSONBody.pm`
- Modify: `t/middleware/09-body-parsing.t`

**Interfaces:**

- ContentNegotiation selects with shared `best_match`, retains existing
  `pagi.preferred_content_type` and `{type, q}` accepted-list scope shapes, and
  delegates strict 406 directly to Pages without redispatch.
- FormBody/JSONBody delegate 413; JSONBody delegates safe 400 detail exactly
  `The request body is not valid JSON.`

- [ ] **Step 1: Add failing shared-negotiation integration tests.** Assert
  scope shape and order after a successful request. In strict mode assert:

  ```text
  supported XML + Accept application/json -> one problem-JSON 406
  supported XML + Accept image/png        -> one configured-default 406
  supported XML + Accept */*;q=0          -> one 406
  ```

  In every strict case assert the downstream app is not called and exactly one
  response start is emitted.

- [ ] **Step 2: Add failing body-error tests.** Exercise FormBody and JSONBody
  limits under different Accept values. Feed malformed JSON whose decoder error
  contains a fake filesystem path and assert the client receives only
  `The request body is not valid JSON.` Successful parsing and scope values
  remain unchanged.

- [ ] **Step 3: Run the red test.** Run the project-Perl command for
  `prove -lv t/middleware/09-body-parsing.t`. Expected: private negotiation
  revives excluded ranges and local parsing errors do not use Pages.

- [ ] **Step 4: Share negotiation and delegate errors.** Replace `_negotiate`
  with `PAGI::Request::Negotiate->best_match`. Retain `_parse_accept`'s public
  scope representation by mapping shared array rows:

  ```perl
  my @accepted = map {
      +{ type => $_->[0], q => $_->[1] }
  } PAGI::Request::Negotiate->parse_accept($accept);
  ```

  Strict failure calls `PAGI::Pages->not_acceptable($scope, detail => $safe)`
  and responds once; Pages' failed Accept fallback cannot produce another 406.
  Body middleware passes the original scope to Pages. Never include `$@` in
  JSONBody's client detail. Update the three middleware PODs with shared
  negotiation/default-response behavior and unchanged successful scope shapes.

- [ ] **Step 5: Run and commit.** Run the project-Perl command for:

  ```text
  prove -lv t/request-negotiate.t t/middleware/09-body-parsing.t
  ```

  Expected: PASS. Commit Task 9 files with
  `git commit -m "feat: unify negotiated parsing failures through Pages"`.

---

### Task 10: Operational App, Rate-Limit, Maintenance, and Endpoint Defaults

**Files:**

- Modify: `lib/PAGI/App/Proxy.pm`
- Modify: `lib/PAGI/App/Loader.pm`
- Modify: `lib/PAGI/App/WrapCGI.pm`
- Modify: `lib/PAGI/App/Throttle.pm`
- Modify: `lib/PAGI/Middleware/Maintenance.pm`
- Modify: `lib/PAGI/Middleware/RateLimit.pm`
- Modify: `lib/PAGI/Endpoint/HTTP.pm`
- Create: `t/app-proxy.t`
- Modify: `t/app/04-utilities.t`
- Modify: `t/app-wrapcgi-env.t`
- Modify: `t/middleware/13-development.t`
- Modify: `t/middleware/rate-limit.t`
- Modify: `t/endpoint/02-http-dispatch.t`

**Interfaces:**

- Proxy 502, Loader HTTP 500, WrapCGI process-start 500, Throttle default 429,
  Maintenance built-in 503, RateLimit default 429, and Endpoint::HTTP automatic
  405 delegate to Pages.
- Throttle/RateLimit retain Retry-After and their current X-RateLimit fields;
  Maintenance retains Retry-After.
- Loader and Throttle named non-HTTP fallback cases croak without emitting HTTP
  events. Existing custom `on_limit`/Maintenance body branches remain literal.

- [ ] **Step 1: Add failing app/endpoint tests.** Use local subclasses to force
  Proxy connection failure and WrapCGI process-start failure; also cover a
  nonexistent Loader app, exhausted Throttle bucket, and an unsupported
  Endpoint method. Before changing behavior, extract
  `PAGI::App::Proxy->_connect_backend($host, $port, $timeout)` around
  `IO::Socket::INET->new` and
  `PAGI::App::WrapCGI->_open_cgi()` returning `($pid, $fh)` around
  `open my $fh, '-|'`; tests make `_connect_backend` return `undef` and
  `_open_cgi` return `(undef, undef)` deterministically rather than relying on
  network/process exhaustion. Assert
  Pages negotiation/status plus retained fields. Assert Loader non-HTTP failure
  names the scope type and Throttle non-HTTP failure names `on_limit`, with no
  `http.response.*` events.

- [ ] **Step 2: Add failing middleware tests.** Assert RateLimit 429 retains
  Retry-After and all X-RateLimit fields through Pages. Assert Maintenance uses
  Pages only when neither `body` nor `content_type` was supplied; either option
  retains the literal branch and Retry-After. Preserve bypass and disabled
  behavior. Reassert that App and Middleware Healthcheck 503 responses retain
  their existing protocol JSON rather than adopting Pages.

- [ ] **Step 3: Run the red tests.** Run the project-Perl command for:

  ```text
  prove -lv t/app-proxy.t t/app/04-utilities.t t/app-wrapcgi-env.t t/middleware/13-development.t t/middleware/rate-limit.t t/endpoint/02-http-dispatch.t
  ```

  Expected: default branches still emit local bodies and malformed non-HTTP
  fallbacks emit HTTP events.

- [ ] **Step 4: Delegate operational defaults.** Pass the original scope to
  private sender helpers. Proxy uses `bad_gateway`; Loader/WrapCGI use
  `internal_server_error`; rate limiters use `too_many_requests` with
  `retry_after` and their flat metadata headers; Maintenance uses
  `service_unavailable` only in the untouched built-in branch. In Maintenance
  `_init`, record `exists $config->{body} || exists $config->{content_type}`
  before assigning current literal defaults; that Boolean, not the eventual
  presence of defaulted fields, selects the custom branch. Endpoint::HTTP
  returns `PAGI::Pages->method_not_allowed($ctx, allow => [$self->allowed_methods])`
  and retains sorted `allowed_methods` behavior. Await every Response send with
  `Future->wrap`. Update each affected POD to name its negotiated built-in
  response, retained component facts, and custom-response seam.

- [ ] **Step 5: Make malformed non-HTTP fallbacks explicit.** Loader load
  failure croaks `application could not be loaded for scope type '$type'`.
  Throttle without `on_limit` croaks `built-in rate-limit response is HTTP-only;
  configure on_limit for scope type '$type'`. Preserve protocol-specific or
  successful child behavior.

- [ ] **Step 6: Run and commit.** Run the Step 3 set through the project Perl.
  Expected: PASS. Commit Task 10 files with
  `git commit -m "feat: render operational defaults through Pages"`.

---

### Task 11: URLMap and Redirecting Middleware

**Files:**

- Modify: `lib/PAGI/App/URLMap.pm`
- Modify: `lib/PAGI/Middleware/HTTPSRedirect.pm`
- Modify: `lib/PAGI/Middleware/Rewrite.pm`
- Modify: `t/app/02-routing.t`
- Modify: `t/app/07-routing-composition.t`
- Modify: `t/middleware/11-url-handling.t`

**Interfaces:**

- URLMap no-default HTTP exhaustion delegates 404; non-HTTP exhaustion croaks
  clearly. Opaque trace shielding and selected-target scope rewriting remain
  unchanged.
- HTTPSRedirect and Rewrite validate redirect codes at construction and pass
  unmodified logical targets to Pages with `preserve_query => 1`.
- HTTPSRedirect invalid authority delegates 400; HSTS/exclusion/pass-through
  behavior stays local.

- [ ] **Step 1: Add failing URLMap tests.** Assert no-default HTTP exhaustion
  negotiates through Pages without changing mount precedence/trace shielding.
  Assert no-default WebSocket/SSE scopes croak `URLMap has no default for scope
  type '$type'` and emit no HTTP events. Existing configured default and mounted
  app behavior remain unchanged.

- [ ] **Step 2: Add failing redirect middleware tests.** For HTTPSRedirect and
  Rewrite, use targets containing fragments plus incoming raw queries and assert
  query-before-fragment Location. Assert 301/302/303/307/308 constructors work,
  every other code croaks at construction, invalid authority uses negotiated
  Pages 400, and existing HTTPS/HSTS/internal-rewrite branches remain unchanged.

- [ ] **Step 3: Run the red tests.** Run the project-Perl command for:

  ```text
  prove -lv t/app/02-routing.t t/app/07-routing-composition.t t/middleware/11-url-handling.t
  ```

  Expected: local URLMap/redirect responses and fragment-unsafe concatenation
  fail the new assertions.

- [ ] **Step 4: Delegate with exact boundary ownership.** URLMap calls Pages
  only after no mount/default exists on HTTP; preserve trace deletion for
  opaque selected/default apps. HTTPSRedirect and Rewrite remove private query
  concatenation and call Pages redirect with the logical target,
  `status => $redirect_code`, and `preserve_query => 1`. Validate code during
  `_init`/construction against the five supported values. Keep authority/rule
  selection in the middleware. Update all three PODs with the negotiated
  defaults, fragment-safe preservation, valid-code set, and unchanged opaque or
  pass-through boundaries.

- [ ] **Step 5: Run and commit.** Run the Step 3 set through the project Perl.
  Expected: PASS. Commit Task 11 files with
  `git commit -m "feat: unify mapped and redirect defaults through Pages"`.

---

### Task 12: Remove Legacy Apps and Modernize Examples

**Files:**

- Delete: `lib/PAGI/App/NotFound.pm`
- Delete: `lib/PAGI/App/Redirect.pm`
- Modify: `t/app/02-routing.t`
- Modify: `examples/test-lifespan-shutdown/app.pl`
- Create: `examples/pages/app.pl`
- Create: `examples/pages/README.md`
- Modify: `examples/README.md`
- Modify: `examples/15-large-application/lib/MyApp/Root.pm`
- Modify: `examples/15-large-application/README.md`
- Modify: `t/integration-large-application.t`
- Create: `t/integration-pages-example.t`
- Modify: `lib/PAGI/App/Cascade.pm`
- Modify: `lib/PAGI/Middleware/Builder.pm`
- Modify: `lib/PAGI/Middleware/Routing/NotFound.pm`

**Interfaces:**

- Pages endpoints replace unconditional NotFound/Redirect apps. Dynamic redirect
  targets become ordinary handlers/raw closures.
- `examples/pages` demonstrates Welcome plus route, mount, Compose, raw unsent
  Response/send ownership, and HTML/JSON/text negotiation.
- The large app adds one natural `$c`-to-Pages response and keeps its branded
  Root/Blogs catchalls that teach routing ownership.

- [ ] **Step 1: Write failing removal and example tests.** Replace old App tests
  with Pages endpoint/Cascade tests. Add an integration test that loads
  `examples/pages/app.pl`, requests its route and mounted descendants with
  HTML/problem JSON/text Accept fields, checks Welcome, and verifies lifespan
  through Compose. Update the large-app test to follow a new `/pagi` link and
  assert a Pages Welcome response while preserving existing custom catchall
  ownership assertions.

- [ ] **Step 2: Run the red example set.** Run the project-Perl command for:

  ```text
  prove -lv t/app/02-routing.t t/integration-pages-example.t t/integration-large-application.t
  ```

  Expected: FAIL because the new example does not exist and legacy apps remain.

- [ ] **Step 3: Delete legacy apps and migrate live call sites.** Remove both
  module files. Replace `PAGI::App::NotFound->new->to_app` with
  `PAGI::Pages->not_found`; replace fixed Redirect apps with Pages redirect
  endpoints. For dynamic destinations use a normal closure that builds a Pages
  redirect from the request. Update Cascade/Builder/routing POD so it no longer
  cross-links either removed class. Do not rewrite historical files under
  `docs/superpowers/`.

- [ ] **Step 4: Build the runnable Pages example.** Run
  `mkdir -p examples/pages`, then create one Compose root with routes equivalent
  to:

  ```perl
  my $routing = router(routes => [
      route('/' => PAGI::Pages->welcome, name => 'welcome'),
      route('/old' => PAGI::Pages->permanent_redirect('/new')),
      route('/missing' => PAGI::Pages->not_found),
      mount('/terminal' => PAGI::Pages->gone),
      route('/context' => sub {
          my ($c) = @_;
          my $response = PAGI::Pages->not_found($c, as => 'text');
          $response->header('X-Demo' => 'Context response value');
          return $response;
      }),
      route('/raw', raw => async sub {
          my ($scope, $receive, $send) = @_;
          my $response = PAGI::Pages->not_found($scope, as => 'text');
          $response->header('X-Demo' => 'raw response value');
          await Future->wrap($response->respond($send));
      }),
  ]);
  compose(app => $routing)->to_app;
  ```

  The README explains Route versus subtree-owning Mount and shows a truly raw
  PAGI closure calling `respond($send)` separately from the Router-managed
  `$c` handler.

- [ ] **Step 5: Update the large app without erasing its lesson.** Add
  `use PAGI::Pages`, a named `/pagi` route whose handler returns
  `PAGI::Pages->welcome($c)`, and a home-page link generated through `path_for`.
  Keep Root and Blogs custom catchalls and domain-specific missing-person/blog
  pages unchanged. Update README and link-following integration assertions.

- [ ] **Step 6: Run focused examples verification and commit.** Run the
  project-Perl command for:

  ```text
  prove -lv t/app/02-routing.t t/integration-pages-example.t t/integration-large-application.t t/00-load.t
  ```

  Expected: PASS. Commit only Task 12 tracked files/deletions with
  `git commit -m "feat: replace legacy page apps in examples"`.

---

### Task 13: Public Documentation and Breaking Migration Guide

**Files:**

- Modify: `lib/PAGI/Pages.pm`
- Modify: `lib/PAGI/Routing.pm`
- Modify: `lib/PAGI/Compose.pm`
- Modify: `lib/PAGI/Response.pm`
- Modify: `lib/PAGI/Tools.pm`
- Modify: `lib/PAGI/Tools/Tutorial.pod`
- Modify: `lib/PAGI/Tools/Cookbook.pod`
- Modify: `README.md`
- Modify: `UPGRADING.md`
- Modify: `Changes`

**Interfaces:**

- Pages POD contains every supported composition form and clearly distinguishes
  response construction, Router-managed response sending, raw `respond`, HEAD,
  and lifespan ownership.
- The upgrade guide gives exact replacements for every intentional break and
  names every first-party default whose representation changes.

- [ ] **Step 1: Complete Pages and cross-module POD.** The Pages POD includes
  all 19 forms in spec section 14.1, the short Welcome copy, registered status
  methods, mandatory semantic fields, negotiation, subclass hooks, exact-status
  SVG/CSP omission, synchronous work budget, HEAD/lifespan ownership, and the
  Route-versus-Mount warning. Record the checked IANA registry date and explain
  that 407/511 are proxy/network-interception responses, not ordinary origin
  errors. Reconcile Tools front page, Tutorial, Cookbook, Routing, Compose,
  Response comparison/SEE ALSO, example index, and root README. Cross-link
  Pages and Response; do not add Context or Compose Pages shortcuts.

- [ ] **Step 2: Write the breaking upgrade guide and Changes entry.** Include
  exact before/after recipes for NotFound, Redirect including new
  `preserve_query => 0` default, ErrorHandler HTML/JSON/text handlers, automatic
  Compose appearance, and the section 12.5 component table. Call out File 405,
  File/Static 416, safe JSONBody detail, shared q=0 matching, auth realm
  validation, redirect fragments/codes, preserved custom branches, and the
  Loader/URLMap/Throttle non-HTTP failures.

- [ ] **Step 3: Run focused documentation verification.** Run the project-Perl
  command for:

  ```text
  prove -lv t/00-load.t t/integration-pages-example.t t/integration-large-application.t
  ```

  Then run:

  ```bash
  git diff --check
  if rg -n 'PAGI::App::(NotFound|Redirect)' lib t examples Changes README.md dist.ini; then exit 1; fi
  ```

  Expected: tests PASS, diff check exits 0, and the legacy search produces no
  matches. Historical Superpowers records and before-spellings in
  `UPGRADING.md` are intentionally outside that search.

- [ ] **Step 4: Commit.** Stage only Task 13 files and commit with
  `git commit -m "docs: document Pages and breaking migrations"`.

---

### Task 14: Contract Audit, Distribution Build, and Final Suite

**Files:**

- Modify only if an audit finds a contract-preserving omission in files already
  named by Tasks 1–13; record every such edit and focused rerun in the ledger.

**Interfaces:**

- The final reviewed HEAD satisfies every test requirement in spec section 16,
  ships Pages, excludes removed apps, and has no unreviewed scope expansion.

- [ ] **Step 1: Audit spec coverage before the full suite.** Walk spec sections
  5–16 and map each requirement to a test or POD paragraph. In the ledger record
  the exact test/subtest for invocation, negotiation, rendering, fields/cache,
  redirects, every section 12.5 component row, non-adoption boundaries,
  removals, examples, and migration docs. Fix only demonstrated omissions, run
  the affected focused test, and commit with a narrowly descriptive message.

- [ ] **Step 2: Run static checks.** Run:

  ```bash
  git diff --check
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -c lib/PAGI/Pages.pm'
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -c lib/PAGI/Pages/_Catalog.pm'
  if rg -n 'PAGI::App::(NotFound|Redirect)' lib t examples Changes README.md dist.ini; then exit 1; fi
  ```

  Expected: all exit 0 and no legacy reference output.

- [ ] **Step 3: Build and inspect the distribution without running its test
  command.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && dzil build'
  ```

  Then inspect the archive:

  ```bash
  tar -tf PAGI-Tools-0.002002.tar.gz | rg 'lib/PAGI/Pages.pm'
  if tar -tf PAGI-Tools-0.002002.tar.gz | rg 'lib/PAGI/App/(NotFound|Redirect).pm'; then exit 1; fi
  ```

  Expected: Pages appears once and neither removed app appears. Do not run
  `dzil test`.

- [ ] **Step 4: Run the one final repository suite.** At the reviewed HEAD run
  exactly:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t'
  ```

  Record exact exit status, elapsed time, test-file count, assertion count, and
  HEAD SHA. If it fails, record the failure, make the smallest contract-
  preserving fix, run the focused failing test, commit, and run one new final
  `prove -lr t` at corrected HEAD.

- [ ] **Step 5: Final diff and scope review.** Compare `starting-head..HEAD`,
  confirm every change belongs to the approved spec, verify preserved untracked
  files remain unstaged, and record any deliberate deviations with user
  decisions. Mark Task 14 and the ledger complete only after this review.
