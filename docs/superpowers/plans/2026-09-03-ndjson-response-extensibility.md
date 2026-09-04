# NDJSON Response and Streaming Extensibility Proof Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a first-party, backpressured NDJSON response as a thin public-API specialization of `PAGI::Response::Stream`, document the streaming extension seam, and prove it through the runnable apples application.

**Architecture:** `PAGI::Response::NDJSON` subclasses Stream and adapts each generic per-invocation Writer into a narrow `PAGI::Response::NDJSON::Writer`. `write_item($value)` performs one UTF-8 JSON encoding, appends one `LF`, and returns the generic Writer's real write Future; every lifecycle, disconnect, cleanup, close, and cancellation decision remains in Stream. The response joins the existing class/factory family and `/apples/export` exercises it through an ordinary Request handler, Route, mount middleware, Compose, and the PAGI Test Client.

**Tech Stack:** Perl 5.18-compatible distribution modules; Perl 5.40 signatures only in the already-modern apples example; `Future`, `Future::AsyncAwait`, `JSON::MaybeXS`, `PAGI::Response::Stream`, `PAGI::Response::Writer`, `PAGI::Test::Client`, `PAGI::Test::ConnectionState`, Test2::V0, POD, and Dist::Zilla. No new runtime dependency.

**Spec:** `docs/superpowers/specs/2026-09-03-ndjson-response-extensibility-design.md` at reviewed commit `28fd101bf46f210f62197d04debd86b29894692d`.

## Global Constraints

- The approved specification above is authoritative. If source evidence conflicts with it, stop, record a deviation, and obtain the user's ruling before dependent work continues.
- Reuse `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/.worktrees/compose-retained-router` on `feature/remove-mutable-router-frontends`; the user explicitly wants this work in the existing large PR #28.
- The execution starting point is `28fd101bf46f210f62197d04debd86b29894692d`. Reconfirm the branch, HEAD, PR mapping, and dirty state before Task 1 and before push.
- Preserve all pre-existing work in this branch. Never stage with `git add .` or `git add -A`; stage exact owned paths.
- Keep distribution code compatible with the declared Perl 5.18 floor. The apples example may continue using Perl 5.40 signatures.
- Add no dependency. Use the existing `JSON::MaybeXS`, `Future`, and `Future::AsyncAwait` prerequisites.
- `PAGI::Response::NDJSON` must subclass `PAGI::Response::Stream`; do not add an NDJSON mode or condition to base Response or Stream.
- `PAGI::Response::NDJSON::Writer` must delegate only public generic Writer methods. It must not call `_abort`, `_cleanup`, `_disconnect_signal`, `_refresh_disconnect`, or any other private generic Writer method.
- Do not copy or restructure `_emit`, `_run_lifecycle`, cancellation arbitration, disconnect signaling, close, cleanup, or send-settlement logic.
- Do not modify runtime code in `PAGI::Response::Stream`, `PAGI::Response::Writer`, Routing, Compose, Pages, WebSocket, SSE, PAGI, or PAGI::Server merely to admit NDJSON. Documentation-only cross-links in Stream and Writer are expected.
- Stop for design review if implementation needs a private Stream hook, lifecycle copy, app-class special case, queue, prefetcher, replay buffer, hidden cache, captured-state clone, or compatibility branch.
- The NDJSON Writer exposes `write_item`, observation, flow-control, and cleanup registration. It does not expose `write`, `write_text`, `pipe_from`, or `close`.
- `write_item(undef)` emits `null\n`. EOF belongs to the producer; do not overload `undef` as a termination signal.
- JSON uses UTF-8 without canonical key sorting or pretty printing. Every successful item receives exactly one `LF`; no `CRLF` and no blank record are generated.
- Encoding errors occur synchronously before an item body send and enter Stream's existing post-start producer-failure path. Send failures remain Future failures from the generic Writer.
- Every write Future must remain the real backpressure boundary. Do not resolve it early, detach it, or schedule the next record before it settles.
- A send pending at disconnect follows the existing PAGI 0.5 settlement contract: it resolves after the server finishes with the event; disconnect does not manufacture a failed write.
- Use the existing generic Writer defaults for absent connection/transport capabilities. Do not add NDJSON-specific fallbacks.
- `PAGI::Response::NDJSON` inherits `body-events-v1`, HTTP-only `to_app`, Stream reuse, mutation, HEAD, and protocol-response behavior without overrides.
- Use strict TDD: run the named RED gate before implementation, implement the minimum, then run the named GREEN gate. Record exact commands, assertion counts, and elapsed time.
- Use focused tests during Tasks 1–4. Run `prove -lr t` once at the final Task 5 boundary; run it again only if a later fix changes HEAD.
- The apples README must preserve the original Python block byte-for-byte and keep its copied Perl source identical to `app.pl` apart from the shebang, as existing tests require.
- Do not assert JSON object-member byte order. Decode each NDJSON line for semantic comparisons.
- Every task ends with an implementation/documentation commit, immediate ledger update recording that SHA and evidence, and review before dependent work starts.

Functional commands use the project Perl:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/response/05-ndjson.t'
```

## Work Map

| Repository | Ticket | Execution branch | Base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | None; approved response-extensibility proof | `feature/remove-mutable-router-frontends` in `.worktrees/compose-retained-router` | `28fd101bf46f210f62197d04debd86b29894692d` on top of current PR #28 | NDJSON response/writer, response exports and live POD, focused tests, Cookbook, Changes, apples example and integration test, plan execution evidence | Unreleased PAGI-Tools library/example change; no release, tag, or merge | Existing `origin/feature/remove-mutable-router-frontends` / PR #28 after final verification and authorization |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI` | NDJSON wire delivery dependency | released repository; read-only | Current PAGI 0.5 send/disconnect contract | Normative reference only | No change | None |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server` | NDJSON wire delivery dependency | released repository; read-only | Current server settlement implementation | Integration context only | No change | None |

If the work exposes a PAGI or PAGI::Server defect, stop and open a separate work item. Do not edit either sibling repository in this campaign.

## Execution Tracking and Deviation Control

Before Task 1, create:

```text
.superpowers/sdd/2026-09-03-ndjson-response-extensibility/
  progress.md
  starting-head
```

Write the exact 40-character starting SHA and one newline to `starting-head`.
Initialize `progress.md` as:

```markdown
# SDD ledger — NDJSON response and streaming extensibility proof

Starting HEAD: 28fd101bf46f210f62197d04debd86b29894692d

| Task | Status | Implementation SHA | Review/fix SHAs | Focused verification and actual counts | Full-suite/build evidence | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | pending | — | — | — | deferred to Task 5 | — |
| 2 | pending | — | — | — | deferred to Task 5 | — |
| 3 | pending | — | — | — | deferred to Task 5 | — |
| 4 | pending | — | — | — | deferred to Task 5 | — |
| 5 | pending | — | — | — | final gate | — |

## Deviations

| ID | Status | Conflicting plan/spec text | Evidence and rationale | Affected tasks | User decision |
| --- | --- | --- | --- | --- | --- |
```

After each implementation commit, immediately record its SHA, exact command,
actual test/assertion counts, elapsed time, and review verdict in the ledger.
Commit that evidence as a small follow-up ledger commit before beginning the
next task; a Git commit cannot contain its own final SHA. Any divergence gets
the next stable `DEV-NNN` identifier and blocks dependent tasks until the user
rules on it.

## File Responsibility Map

| File | Responsibility |
| --- | --- |
| `lib/PAGI/Response/NDJSON.pm` | Reusable Stream subclass, producer adaptation, default media type, concrete factory |
| `lib/PAGI/Response/NDJSON/Writer.pm` | Per-invocation structured-record facade over one generic Writer |
| `lib/PAGI/Response.pm` | Response-family discovery, `ndjson_response` forwarding factory, `:all` membership, subclassing links |
| `lib/PAGI/Response/Stream.pm` | Documentation only: public semantic streaming-subclass seam and NDJSON cross-link |
| `lib/PAGI/Response/Writer.pm` | Documentation only: byte/source/structured-writer distinction and NDJSON cross-link |
| `lib/PAGI/Tools/Cookbook.pod` | Complete public-only streaming extension recipe and synchronized apples source |
| `t/response/05-ndjson.t` | Construction, encoding, framing, delegation, lifecycle, reuse, and failure behavior |
| `t/00-load.t` | Distribution loadability of both new modules |
| `t/00-pod/cookbook-examples.t` | Executable/canonical Cookbook proof |
| `examples/starlette-apples/app.pl` | Real `/apples/export` Request-handler integration |
| `examples/starlette-apples/README.md` | Preserved Python comparison, synchronized Perl source, route rationale, curl usage |
| `examples/README.md` | Briefly identify the apples streaming export |
| `t/integration-starlette-apples.t` | End-to-end status, media type, records, middleware, HEAD, and source synchronization |
| `Changes` | Unreleased feature and architectural proof |

## Specification Coverage Map

| Design area | Owning tasks |
| --- | --- |
| Class/factory construction and subclass identity (§7) | Tasks 1–2 |
| Specialized Writer contract and encoding (§§8–9) | Task 1 |
| Backpressure, disconnect, cleanup, reuse (§§10–11) | Task 1 |
| Route, HEAD, and protocol boundaries (§12) | Tasks 1 and 4 |
| Apples canary (§13) | Task 4 |
| Response/Stream/Writer/Cookbook documentation (§14) | Tasks 2–3 |
| Diagnostics (§15) | Task 1 |
| Verification outcomes and extensibility gate (§16) | Tasks 1–5 |
| Rejected alternatives and stop rules (§17) | Enforced globally; audited in Task 5 |
| Completion criteria (§19) | Task 5 |

---

### Task 1: Implement the NDJSON Response and Structured Writer

**Files:**

- Create: `lib/PAGI/Response/NDJSON.pm`
- Create: `lib/PAGI/Response/NDJSON/Writer.pm`
- Create: `t/response/05-ndjson.t`
- Create: `.superpowers/sdd/2026-09-03-ndjson-response-extensibility/progress.md`
- Create: `.superpowers/sdd/2026-09-03-ndjson-response-extensibility/starting-head`

**Interfaces:**

- `PAGI::Response::NDJSON->new($producer, %response_options) -> PAGI::Response::NDJSON`
- `PAGI::Response::NDJSON::ndjson_response($producer, %response_options) -> PAGI::Response::NDJSON`
- producer: `sub ($ndjson_writer) -> immediate value | Future`
- `PAGI::Response::NDJSON::Writer->write_item($value) -> the generic Writer write Future`
- observation/flow methods exactly as listed in the approved spec §8.2

- [ ] **Step 1: Reconfirm and record the workspace.** Run:

  ```bash
  git status -sb
  git rev-parse HEAD
  git branch --show-current
  gh pr view 28 --json number,state,headRefName,baseRefName,url
  ```

  Create the ledger and `starting-head` exactly as specified above. Stop if
  HEAD, branch, PR, or existing dirty state differs from the work map without
  an understood same-campaign reason.

- [ ] **Step 2: Write the failing construction and wire-format tests.** In
  `t/response/05-ndjson.t`, use the concrete class/factory and pin:

  ```perl
  use Future;
  use Future::AsyncAwait;
  use JSON::MaybeXS ();
  use Test2::V0;
  use PAGI::Response::NDJSON qw(ndjson_response);

  my @events;
  my @writers;
  my $response = ndjson_response(
      async sub {
          my ($writer) = @_;
          push @writers, $writer;
          await $writer->write_item({ id => 1 });
          await $writer->write_item(undef);
          await $writer->write_item("first\nsecond");
      },
      status  => 201,
      headers => ['X-Export' => 1],
  );

  $response->to_app->(
      { type => 'http', method => 'GET', headers => [] },
      sub { Future->done({ type => 'http.request', body => '', more => 0 }) },
      sub { push @events, $_[0]; Future->done },
  )->get;

  isa_ok $response, ['PAGI::Response::NDJSON', 'PAGI::Response::Stream'];
  isa_ok $writers[0], 'PAGI::Response::NDJSON::Writer';
  is $events[0]{status}, 201;
  is $events[0]{headers}, array {
      item ['X-Export' => 1];
      item ['Content-Type' => 'application/x-ndjson'];
      end;
  };
  is [map { $_->{body} } grep { $_->{more} } @events], [
      qq|{"id":1}\n|,
      "null\n",
      qq|"first\\nsecond"\n|,
  ];
  is $events[-1], { type => 'http.response.body', body => '', more => 0 };
  ```

  Add semantic decoding tests for hash, array, string, number, JSON boolean,
  `undef`, and non-ASCII text. Assert each nonterminal body is unflagged UTF-8
  bytes with one trailing `LF`, no raw interior CR/LF, and no key-order claim.
  Add an empty producer assertion proving there is no blank NDJSON record.
  Construct one response with an explicit Content-Length header and prove it
  is retained without NDJSON calculating one of its own.

- [ ] **Step 3: Add failing API, validation, and subclass tests.** Pin:

  ```perl
  ok !$writer->can('write');
  ok !$writer->can('write_text');
  ok !$writer->can('pipe_from');
  ok !$writer->can('close');

  {
      package T::AuditExport;
      use parent 'PAGI::Response::NDJSON';
  }
  isa_ok T::AuditExport->new(sub { }), 'T::AuditExport';
  ```

  Assert non-coderef producers and malformed common options croak at
  construction. Pass a blessed value unsupported by JSON::MaybeXS and assert
  the error identifies `NDJSON item encoding failed`, sends no body event for
  that item, emits no false terminal success, and runs `on_close` once.

- [ ] **Step 4: Add failing delegation and lifecycle tests.** Use a pending
  body-send Future to prove:

  ```perl
  my $write = $writer->write_item({ id => 1 });
  ok !$write->is_ready;
  ok !$running->is_ready;
  like dies { $writer->write_item({ id => 2 }) }, qr/outstanding|await.*write/i;
  $body_send->done;
  $write->get;
  ```

  Add one focused facade test with a local delegate whose public `write`
  returns a known Future. Construct the facade through its package-private
  `_new` and compare `refaddr($facade->write_item($value))` with that known
  Future, proving NDJSON adds no adapter Future. This test may call NDJSON
  Writer's own `_new`; production code must never call a private method on the
  generic Writer. Pin that `bytes_written` includes encoded bytes plus `LF`. Provide a test
  transport and assert `buffered_amount`, watermarks, `is_writable`,
  `on_high_water`, and `on_drain` delegate, while chainers return the NDJSON
  Writer. Without transport/connection, assert the inherited neutral values.

  Invoke one unchanged Response twice and concurrently; assert distinct
  specialized writers and independent producer calls. Use
  `PAGI::Test::ConnectionState` plus a pending send to prove disconnect waits
  for the server-owned send, does not count discarded bytes, sends no terminal
  success, and runs cleanup exactly once. Pin normal completion, synchronous
  producer failure, Future failure, and caller cancellation without copying
  the generic Stream matrix.

- [ ] **Step 5: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/response/05-ndjson.t'
  ```

  Expected: FAIL because `PAGI::Response::NDJSON` and its Writer do not exist.
  Record the exact failure and count.

- [ ] **Step 6: Implement the minimal Stream subclass.** Create
  `lib/PAGI/Response/NDJSON.pm` with this structure:

  ```perl
  package PAGI::Response::NDJSON;

  use strict;
  use warnings;
  use Carp qw(croak);
  use Exporter qw(import);
  use parent 'PAGI::Response::Stream';
  use PAGI::Response::NDJSON::Writer ();

  our @EXPORT_OK = qw(ndjson_response);

  sub ndjson_response {
      return PAGI::Response::NDJSON->new(@_);
  }

  sub default_content_type { 'application/x-ndjson' }

  sub new {
      my ($class, $producer, @response_options) = @_;
      croak 'PAGI::Response::NDJSON->new requires a producer coderef'
          unless @_ >= 2 && ref($producer) eq 'CODE';

      my $adapted = sub {
          my ($writer) = @_;
          return $producer->(
              PAGI::Response::NDJSON::Writer->_new($writer)
          );
      };

      return $class->SUPER::new($adapted, @response_options);
  }

  1;
  ```

  Do not override `to_app`, `_emit`, `_stream_delivery_plan`,
  `_run_lifecycle`, `protocol_response_capability`, or any lifecycle method.

- [ ] **Step 7: Implement the narrow Writer facade.** Create
  `lib/PAGI/Response/NDJSON/Writer.pm` with one private delegate and explicit
  public methods—no `AUTOLOAD`, generated symbol-table methods, inheritance,
  or copied state:

  ```perl
  package PAGI::Response::NDJSON::Writer;

  use strict;
  use warnings;
  use Carp qw(croak);
  use JSON::MaybeXS ();

  my $JSON = JSON::MaybeXS->new(utf8 => 1);

  sub _new {
      my ($class, $writer) = @_;
      return bless { _writer => $writer }, $class;
  }

  sub write_item {
      my ($self, $value) = @_;
      my ($bytes, $ok);
      $ok = eval { $bytes = $JSON->encode($value); 1 };
      croak "NDJSON item encoding failed: $@" unless $ok;
      return $self->{_writer}->write($bytes . "\n");
  }

  sub on_close {
      my ($self, $callback) = @_;
      $self->{_writer}->on_close($callback);
      return $self;
  }

  sub is_closed         { return $_[0]{_writer}->is_closed }
  sub is_disconnected   { return $_[0]{_writer}->is_disconnected }
  sub disconnect_reason { return $_[0]{_writer}->disconnect_reason }
  sub bytes_written     { return $_[0]{_writer}->bytes_written }
  sub buffered_amount   { return $_[0]{_writer}->buffered_amount }
  sub high_water_mark   { return $_[0]{_writer}->high_water_mark }
  sub low_water_mark    { return $_[0]{_writer}->low_water_mark }
  sub is_writable       { return $_[0]{_writer}->is_writable }

  sub on_high_water {
      my ($self, $callback) = @_;
      $self->{_writer}->on_high_water($callback);
      return $self;
  }

  sub on_drain {
      my ($self, $callback) = @_;
      $self->{_writer}->on_drain($callback);
      return $self;
  }

  1;
  ```

- [ ] **Step 8: Run the GREEN gate and syntax checks.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/response/05-ndjson.t t/response/03-stream.t t/response-writer.t'
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -c lib/PAGI/Response/NDJSON.pm && perl -Ilib -c lib/PAGI/Response/NDJSON/Writer.pm'
  ```

  Expected: all three test files PASS; both modules report `syntax OK`.

- [ ] **Step 9: Audit the extensibility gate.** Run:

  ```bash
  rg -n '_run_lifecycle|_emit|_abort|_cleanup|_disconnect_signal|_refresh_disconnect|AUTOLOAD' lib/PAGI/Response/NDJSON.pm lib/PAGI/Response/NDJSON/Writer.pm
  git diff --check
  ```

  Expected: the private-name search has no matches; `git diff --check` exits
  zero. Manually confirm the only generic Writer calls are the public methods
  named in the design.

- [ ] **Step 10: Commit and record evidence.** Stage only the two modules,
  test, and initial ledger files. Commit:

  ```bash
  git add lib/PAGI/Response/NDJSON.pm lib/PAGI/Response/NDJSON/Writer.pm t/response/05-ndjson.t
  git add -f .superpowers/sdd/2026-09-03-ndjson-response-extensibility/progress.md .superpowers/sdd/2026-09-03-ndjson-response-extensibility/starting-head
  git commit -m 'Add backpressured NDJSON responses'
  ```

  Then record the implementation SHA and actual evidence in the Task 1 row,
  commit the ledger update, and review specifically for hidden lifecycle work,
  defensive cloning, indirect Future completion, or raw-write escape hatches.

---

### Task 2: Integrate NDJSON into the Response Family and Live POD

**Files:**

- Modify: `lib/PAGI/Response.pm`
- Modify: `lib/PAGI/Response/NDJSON.pm`
- Modify: `lib/PAGI/Response/NDJSON/Writer.pm`
- Modify: `lib/PAGI/Response/Stream.pm`
- Modify: `lib/PAGI/Response/Writer.pm`
- Modify: `t/response/05-ndjson.t`
- Modify: `t/00-load.t`
- Modify: `Changes`
- Modify: `.superpowers/sdd/2026-09-03-ndjson-response-extensibility/progress.md`

**Interfaces:**

- `PAGI::Response::ndjson_response(...) -> PAGI::Response::NDJSON`
- `use PAGI::Response qw(ndjson_response)`
- `use PAGI::Response qw(:all)` includes `ndjson_response`
- both new classes load as distribution modules

- [ ] **Step 1: Add failing family/export/load assertions.** Extend
  `t/response/05-ndjson.t` and `t/00-load.t` to assert:

  ```perl
  PAGI::Response->import('ndjson_response');
  my $factory = __PACKAGE__->can('ndjson_response');
  isa_ok $factory->(sub { }), 'PAGI::Response::NDJSON';
  is PAGI::Response::NDJSON->new(sub { })->protocol_response_capability,
      'body-events-v1';
  ```

  In an isolated package, import `:all` and prove the factory exists. Add
  `PAGI::Response::NDJSON` and `PAGI::Response::NDJSON::Writer` to the load
  module list.

- [ ] **Step 2: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/response/05-ndjson.t t/00-load.t'
  ```

  Expected: FAIL because base `PAGI::Response` does not yet export or forward
  `ndjson_response`. The newly added load assertions should already pass for
  the Task 1 modules.

- [ ] **Step 3: Add the forwarding factory and export.** In
  `lib/PAGI/Response.pm`, add `ndjson_response` to `@EXPORT_OK` and implement:

  ```perl
  sub ndjson_response {
      require PAGI::Response::NDJSON;
      return PAGI::Response::NDJSON->new(@_);
  }
  ```

  Because `:all` aliases `@EXPORT_OK`, no second bundle list is introduced.

- [ ] **Step 4: Write complete class and Writer POD.** Document constructor,
  factory, common options, `application/x-ndjson`, one-record framing,
  `write_item(undef)`, escaped CR/LF, key-order non-contract, encoding failure
  after start, Future backpressure, connection/transport methods, cleanup,
  reuse, HEAD cost, `body-events-v1`, and the absence of raw emission/close.
  Include this canonical producer:

  ```perl
  return ndjson_response(async sub ($writer) {
      my $cursor = await $database->people_cursor;
      $writer->on_close(sub { return $cursor->close });

      while (!$writer->is_disconnected) {
          my $person = await $cursor->next_item;
          last unless defined $person;
          await $writer->write_item($person);
      }
  });
  ```

  State explicitly that this cursor's `undef` means EOF while
  `write_item(undef)` means JSON null.

- [ ] **Step 5: Update Response, Stream, and Writer POD.** Add NDJSON to the
  Response class/factory table, change the `:all` count, distinguish buffered
  JSON from NDJSON streaming, and link to the Cookbook extension proof. In
  Stream, document that a semantic format subclass may wrap its producer and
  the public generic Writer before delegating to `SUPER::new`, but must not
  override private lifecycle methods. In generic Writer, publish this exact
  distinction:

  ```text
  $writer->write($bytes)       generic encoded-byte chunk
  $writer->pipe_from($source)  generic next_chunk byte source
  $writer->write_item($value)  NDJSON Writer: one encoded record
  ```

  Do not imply that generic Writer gains `write_item`.

- [ ] **Step 6: Update Changes.** Under `0.002003 - UNRELEASED`, add a concise
  `[NDJSON response]` entry describing the class/factory, UTF-8+LF framing,
  backpressure, specialized Writer, and public Stream-extension proof. Do not
  claim canonical key ordering, request parsing, or cursor construction.

- [ ] **Step 7: Run the GREEN documentation/family gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/response/05-ndjson.t t/00-load.t'
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -MPAGI::Response=:all -e "die unless __PACKAGE__->can(q(ndjson_response))"'
  git diff --check
  ```

  Expected: tests PASS, export probe exits zero, diff check exits zero.

- [ ] **Step 8: Commit and record evidence.** Stage only the Task 2 paths and
  commit `Document and export NDJSON responses`. Record the SHA, exact counts,
  and review verdict in the ledger, then commit the ledger update. Review the
  POD for any claim that Writer owns disconnect, Stream parses items, or
  NDJSON buffers the sequence.

---

### Task 3: Publish the Streaming Response Extension Recipe

**Files:**

- Modify: `lib/PAGI/Tools/Cookbook.pod`
- Modify: `t/00-pod/cookbook-examples.t`
- Modify: `.superpowers/sdd/2026-09-03-ndjson-response-extensibility/progress.md`

**Interfaces:**

- Cookbook section `=head2 Streaming Response Extension: NDJSON`
- executable example uses only `PAGI::Response::Stream->new`, a format Writer
  facade, and public generic Writer methods

- [ ] **Step 1: Add a failing Cookbook extraction/execution test.** Extend
  `t/00-pod/cookbook-examples.t` to locate the new heading, extract its first
  complete code block, execute it under `perl -Ilib`, invoke the constructed
  response, and assert the captured body is two newline-terminated JSON
  records. The test must fail with `section not found` before the POD exists.

- [ ] **Step 2: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/00-pod/cookbook-examples.t'
  ```

  Expected: FAIL because `Streaming Response Extension: NDJSON` is absent.

- [ ] **Step 3: Add the complete recipe.** Explain the two proven extension
  shapes:

  1. buffered semantic subclasses normalize at construction and delegate to
     `PAGI::Response::JSON`; and
  2. streaming semantic subclasses adapt the producer's public Writer and
     delegate to `PAGI::Response::Stream`.

  Publish a complete runnable miniature with both pieces of the adaptation;
  the format Writer must be defined in the same example rather than referenced
  as an unexplained type:

  ```perl
  package MyApp::RecordWriter;
  use JSON::MaybeXS ();

  my $JSON = JSON::MaybeXS->new(utf8 => 1);

  sub new {
      my ($class, $writer) = @_;
      return bless { writer => $writer }, $class;
  }

  sub write_record {
      my ($self, $value) = @_;
      return $self->{writer}->write($JSON->encode($value) . "\n");
  }

  sub on_close {
      my ($self, $callback) = @_;
      $self->{writer}->on_close($callback);
      return $self;
  }

  sub is_disconnected {
      return $_[0]{writer}->is_disconnected;
  }

  package MyApp::RecordStream;
  use parent 'PAGI::Response::Stream';

  sub default_content_type { 'application/x-ndjson' }

  sub new {
      my ($class, $producer, @response_options) = @_;
      die 'producer must be a coderef' unless ref($producer) eq 'CODE';

      my $adapted = sub {
          my ($writer) = @_;
          return $producer->(MyApp::RecordWriter->new($writer));
      };
      return $class->SUPER::new($adapted, @response_options);
  }
  ```

  Invoke it with `write_record` in the executable block. Explain that this is
  deliberately small anatomy of the public seam, not a recommendation to
  copy a second NDJSON implementation. The shipped
  `PAGI::Response::NDJSON` supplies the complete validation, diagnostics,
  method surface, and tests. The recipe's Writer calls only generic `write`,
  `on_close`, and `is_disconnected`.

- [ ] **Step 4: State the stop boundary in user-facing language.** Explain
  that application response extensions own format validation and producer
  adaptation, while Stream owns response start, close, cancellation,
  disconnect, send settlement, and cleanup. If an extension needs a private
  Stream/Writer method, it has crossed the supported seam.

- [ ] **Step 5: Run the GREEN gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/00-pod/cookbook-examples.t t/response/05-ndjson.t'
  git diff --check
  ```

  Expected: both files PASS; the published example executes; diff check exits
  zero.

- [ ] **Step 6: Commit and record evidence.** Commit
  `Document streaming response extensions`, update and commit the Task 3
  ledger evidence, and review that the recipe does not teach private calls,
  producer-held close, raw receive loops, or detached writes.

---

### Task 4: Add the Apples NDJSON Export Canary

**Files:**

- Modify: `examples/starlette-apples/app.pl`
- Modify: `examples/starlette-apples/README.md`
- Modify: `examples/README.md`
- Modify: `t/integration-starlette-apples.t`
- Modify: `lib/PAGI/Tools/Cookbook.pod`
- Modify: `.superpowers/sdd/2026-09-03-ndjson-response-extensibility/progress.md`

**Interfaces:**

- `GET /apples/export -> application/x-ndjson`
- `HEAD /apples/export -> same status/headers, no wire body`
- Route name: `/apples/export` through local name `export`
- existing global `X-Request-ID` and mount-local `X-Apples-API: 1` remain

- [ ] **Step 1: Write the failing integration assertions first.** In
  `t/integration-starlette-apples.t`, request `/apples/export`, split the raw
  body on `LF` while retaining the requirement for a final delimiter, decode
  each nonempty line with `JSON::PP`, and assert:

  ```perl
  is $export->status, 200;
  is $export->content_type, 'application/x-ndjson';
  is $records, [
      { id => 1, name => 'Gala',       color => 'Red/Yellow' },
      { id => 2, name => 'Honeycrisp', color => 'Rosy Red' },
  ];
  ok defined($export->header('X-Request-ID'));
  is $export->header('X-Apples-API'), '1';
  ```

  Assert the body ends in `"\n"`, contains exactly two records, and has no
  blank interior line. Add HEAD assertions for status 200, empty body, and
  `application/x-ndjson`. Add source-shape assertions for the ordinary
  Request handler and named Route. Keep the Python checksum assertion
  unchanged.

- [ ] **Step 2: Run the RED gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-starlette-apples.t'
  ```

  Expected: FAIL because `/apples/export` currently falls through the integer
  constraint and produces the child Router's 404.

- [ ] **Step 3: Implement the ordinary Request handler.** Import
  `ndjson_response` beside the existing response factories and add:

  ```perl
  async sub export_apples($request) {
      my $items = apples($request)->all;

      return ndjson_response(async sub ($writer) {
          for my $apple (@$items) {
              last if $writer->is_disconnected;
              await $writer->write_item($apple);
          }
      });
  }
  ```

  Add this static child Route before `/{apple_id:&Int}`:

  ```perl
  route('/export' => \&export_apples,
      methods => ['GET'], name => 'export'),
  ```

  Do not add `request_response`, `as_app_object`, `invoke_app`, a raw PAGI
  closure, a dedicated source protocol, or a copied array for framework
  defensiveness.

- [ ] **Step 4: Synchronize documentation.** Copy the executable Perl source
  into the README's canonical Perl block without its shebang, preserving the
  Python block byte-for-byte. Explain that `/apples/export` is an intentional
  PAGI extension absent from the original Starlette sample. Add:

  ```bash
  curl -i http://127.0.0.1:5000/apples/export
  ```

  Update the example index description and the Cookbook's synchronized apples
  block.

- [ ] **Step 5: Run the GREEN gate.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-starlette-apples.t t/00-pod/cookbook-examples.t'
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -Iexamples/starlette-apples/lib -c examples/starlette-apples/app.pl'
  git diff --check
  ```

  Expected: both test files PASS, app syntax is OK, diff check exits zero.

- [ ] **Step 6: Commit and record evidence.** Commit
  `Demonstrate NDJSON with the apples export`, update and commit the Task 4
  ledger evidence, and review the complete application visually for API
  ceremony. The export should read as an ordinary Route handler returning an
  ordinary Response. If it does not, stop and revisit the Response design.

---

### Task 5: Audit the Design, Run Final Verification, and Update the Existing PR

**Files:**

- Modify only if evidence requires a scoped correction: files owned by Tasks
  1–4
- Modify: `.superpowers/sdd/2026-09-03-ndjson-response-extensibility/progress.md`

**Interfaces:**

- final branch implements every approved spec section without a recorded open
  deviation
- existing PR #28 receives the verified commits only after branch-map review

- [ ] **Step 1: Compare implementation to the specification line by line.** In
  the ledger, record each spec section (§§1–19), its implementing file/test,
  and verdict. Confirm no open `DEV-NNN` deviation remains. Run:

  ```bash
  rg -n '_run_lifecycle|->_(?:emit|abort|cleanup|disconnect_signal|refresh_disconnect)|AUTOLOAD' lib/PAGI/Response/NDJSON.pm lib/PAGI/Response/NDJSON/Writer.pm
  rg -n 'ndjson|NDJSON' lib t examples Changes
  rg -n 'PAGI::Response::NDJSON|PAGI::Response::NDJSON::Writer' t/00-load.t
  ```

  Expected: no private lifecycle/generic Writer calls; every NDJSON occurrence
  has a classified purpose; both modules appear in the load test.

- [ ] **Step 2: Run the complete focused gate at final HEAD.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/response/05-ndjson.t t/response/03-stream.t t/response-writer.t t/00-load.t t/00-pod/cookbook-examples.t t/integration-starlette-apples.t'
  ```

  Record actual files, tests/assertions, failures, and elapsed time.

- [ ] **Step 3: Run syntax and repository hygiene checks.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -c lib/PAGI/Response/NDJSON.pm && perl -Ilib -c lib/PAGI/Response/NDJSON/Writer.pm && perl -Ilib -Iexamples/starlette-apples/lib -c examples/starlette-apples/app.pl'
  git diff --check
  git status -sb
  ```

  Expected: all syntax checks report OK; diff check exits zero; only expected
  ledger evidence may remain uncommitted.

- [ ] **Step 4: Run the full repository suite once.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t'
  ```

  Record the exact file/test totals and result. If a failure is related to
  NDJSON, Response, Routing, examples, exports, packaging, or documentation,
  diagnose and fix it, then rerun the focused gate and one new full suite at
  the corrected HEAD. If an unrelated pre-existing failure appears, prove its
  baseline status and report it rather than weakening a test.

- [ ] **Step 5: Build the distribution once.** Run:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && dzil build'
  ```

  Inspect the build output and generated archive to confirm both NDJSON
  modules, live POD, Changes, and README are packaged while `docs/` and
  `.superpowers/` remain pruned as configured. Do not edit historical design
  documents to make distribution searches pass.

- [ ] **Step 6: Record final evidence and commit any scoped correction.** Mark
  all five ledger rows complete, record final suite/build evidence, actual
  counts, and a no-open-deviation verdict. Commit the ledger update. If Tasks
  1–4 needed corrections, commit them separately with descriptive subjects
  before the ledger commit.

- [ ] **Step 7: Reconfirm the push map and update PR #28.** Run:

  ```bash
  git status -sb
  git branch --show-current
  git rev-parse HEAD
  gh pr view 28 --json number,state,headRefName,baseRefName,url
  git log --oneline 28fd101bf46f210f62197d04debd86b29894692d..HEAD
  ```

  Confirm the branch remains `feature/remove-mutable-router-frontends`, PR #28
  still uses it, no other repository is in the push set, and the commit list
  contains only this approved campaign plus pre-existing PR work. Push the
  existing branch only when authorized, then verify the remote PR head equals
  local HEAD.

## Completion Handoff

Report:

- the exact public API added;
- the fact that NDJSON uses only the public Stream/Writer seam;
- focused and full-suite counts from fresh final runs;
- distribution-build result;
- apples endpoint and curl command;
- all implementation and ledger SHAs;
- PR #28 URL and remote head, if pushed; and
- any deviations or remaining follow-ups, explicitly distinguishing deferred
  `pipe_items`/request parsing from defects.

Do not claim completion from prior task output or ledger text. Re-read the
fresh final command outputs immediately before the handoff.
