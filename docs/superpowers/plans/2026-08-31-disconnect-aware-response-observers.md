# Disconnect-Aware Response Observers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every PAGI-Tools component that observes response completeness
distinguish a client disconnect from an application fault, so a client that
goes away mid-response never produces a fabricated response, a failed
application Future, or a misleading log line.

**Architecture:** One shared predicate in `PAGI::Utils` answers "did this
request end abnormally?" from the request scope, keyed on a defined
`disconnect_reason`. Nine components consume it: three that currently
fabricate a completeness claim stop emitting, two that currently fail or warn
reclassify, one stops swallowing the response, one gains an abort log field,
and two align their existing ad-hoc checks with the shared one. No new
protocol events and no changes to `PAGI::Response::Stream`, which already
behaves correctly.

**Tech Stack:** Perl 5.18-compatible distribution code (`lib/` must parse on
5.16.3), `Future`, `Future::AsyncAwait`, `Test2::V0`, existing
`PAGI::Utils` export machinery. No new dependencies.

**Spec:** `PAGI/lib/PAGI/Spec/Www.pod`, section "Application Left a Response
Incomplete" — specifically the three additions committed as PAGI `d19a642`
(what the terminal event asserts; the application-side MUST NOT; every
producer is bound). Findings ledger with file:line evidence:
`.pagi-open-issues.md`, item 1b.

## Global Constraints

- Every file under `lib/` must parse on Perl 5.16.3: classic `@_` unpacking,
  no signatures, no postfix dereferencing, no `try`/`catch`. Examples and
  tests may use newer syntax where the file already does.
- The discriminator is a **defined `disconnect_reason`**, never
  `is_connected` alone — a clean completion also clears `is_connected`. This
  is stated normatively in the spec section above; do not re-derive it.
- No component may gain a dependency on `PAGI::Response::Stream`,
  `PAGI::Compose`, or any routing class. The predicate takes a scope.
- No new event types. `http.response.abort` was considered and rejected; see
  `.pagi-open-issues.md` item 1b, "Panel verdict".
- Never stage the untracked `.pagi-*.md` working notes or `.superpowers/`.
  Stage only files named by the current task.
- Run Perl through the project toolchain:
  `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && <command>'`
- Focused tests run per task. The full suite (`prove -lr -j4 t/`) runs once,
  at Task 11. Baseline before starting: 219 files / 2380 tests PASS.
- Reclassify, don't merely suppress: where a component previously reported an
  application error, an abnormal end should produce a *distinct, quieter*
  outcome that carries the reason — not silence.

---

## File Structure

| File | Responsibility | Task |
| --- | --- | --- |
| `lib/PAGI/Utils.pm` | Owns `request_ended_abnormally($scope)`, the single discriminator | 1 |
| `t/utils/request-ended-abnormally.t` | Contract tests for the predicate | 1 |
| `lib/PAGI/Middleware/ETag.pm` | Must not validate a partial body | 2 |
| `lib/PAGI/Middleware/GZip.pm` | Must not length/compress a partial body | 3 |
| `lib/PAGI/Middleware/ContentLength.pm` | Must not length a partial body | 4 |
| `lib/PAGI/App/Cascade.pm` | Must not fail a disconnected child | 5 |
| `lib/PAGI/Middleware/Lint.pm` | Must reclassify, not misdiagnose | 6 |
| `lib/PAGI/Middleware/Debug.pm` | Must flush buffered events after the app returns | 7 |
| `lib/PAGI/Middleware/AccessLog.pm` | Must record aborts with their reason | 8 |
| `lib/PAGI/Response.pm` | Must use the shared discriminator | 9 |
| `lib/PAGI/Test/Response.pm` | Must expose completeness and an abort reason | 9 |
| `t/middleware/disconnect-laundering.t` | Pins the cross-component ordering hazard | 10 |
| `lib/PAGI/Middleware/Debug.pm` (POD) | Documents HTML buffering vs streaming | 10 |

---

### Task 1: Shared abnormal-end predicate

**Files:**
- Modify: `lib/PAGI/Utils.pm` (add sub + export + POD)
- Test: `t/utils/request-ended-abnormally.t` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `PAGI::Utils::request_ended_abnormally($scope)` — takes the
  request scope hashref, returns `1` if the request ended abnormally, `0`
  otherwise (including no connection object, still connected, or a clean
  completion). Exported on request and included in the `:all` tag. Every
  later task calls exactly this.

- [ ] **Step 1: Write the failing test**

Create `t/utils/request-ended-abnormally.t`:

```perl
use strict;
use warnings;
use Test2::V0;
use PAGI::Utils qw(request_ended_abnormally);

{
    package TestConn;
    sub new {
        my ($class, %args) = @_;
        return bless { reason => $args{reason}, complete => $args{complete} }, $class;
    }
    sub is_connected      { return $_[0]->{reason} ? 0 : 1 }
    sub disconnect_reason { return $_[0]->{reason} }
    sub on_disconnect     { return }
}

sub scope_with {
    my ($conn) = @_;
    return { type => 'http', method => 'GET', path => '/', headers => [],
             defined $conn ? ('pagi.connection' => $conn) : () };
}

is(request_ended_abnormally(scope_with(TestConn->new(reason => 'client_closed'))), 1,
    'a defined disconnect reason is an abnormal end');
is(request_ended_abnormally(scope_with(TestConn->new(reason => 'write_error'))), 1,
    'any standard reason counts');
is(request_ended_abnormally(scope_with(TestConn->new(reason => undef))), 0,
    'a connected request has not ended abnormally');
is(request_ended_abnormally(scope_with(undef)), 0,
    'a scope without pagi.connection is not an abnormal end');
is(request_ended_abnormally({ type => 'websocket' }), 0,
    'a non-http scope without a connection object is not an abnormal end');

# The discriminator is the reason, not is_connected: a clean completion also
# clears is_connected, and those responses must still be guarded.
{
    package CompletedConn;
    sub new               { return bless {}, shift }
    sub is_connected      { return 0 }
    sub disconnect_reason { return undef }
    sub on_disconnect     { return }
}
is(request_ended_abnormally(scope_with(CompletedConn->new)), 0,
    'a cleanly completed request is not an abnormal end');

# An empty-string reason is not a reason.
{
    package EmptyReasonConn;
    sub new               { return bless {}, shift }
    sub is_connected      { return 0 }
    sub disconnect_reason { return '' }
    sub on_disconnect     { return }
}
is(request_ended_abnormally(scope_with(EmptyReasonConn->new)), 0,
    'an empty reason string does not count as an abnormal end');

# A connection object missing the accessor must not explode.
{
    package BareConn;
    sub new { return bless {}, shift }
}
is(request_ended_abnormally(scope_with(BareConn->new)), 0,
    'a connection object without disconnect_reason is handled safely');

done_testing;
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/utils/request-ended-abnormally.t'`

Expected: FAIL — `"request_ended_abnormally" is not exported by the PAGI::Utils module`.

- [ ] **Step 3: Implement the predicate**

In `lib/PAGI/Utils.pm`, add to the `@EXPORT_OK` list (the `qw(handle_lifespan
to_app as_app request_response invoke_app)` line) the name
`request_ended_abnormally`, then add the sub near the other scope helpers:

```perl
sub request_ended_abnormally {
    my ($scope) = @_;
    return 0 unless ref($scope) eq 'HASH';
    my $connection = $scope->{'pagi.connection'};
    return 0 unless blessed($connection) && $connection->can('disconnect_reason');
    my $reason = $connection->disconnect_reason;
    return defined($reason) && length($reason) ? 1 : 0;
}
```

`blessed` is already imported in this file; confirm with
`grep -n 'use Scalar::Util' lib/PAGI/Utils.pm` and add it to the existing
import list if absent.

- [ ] **Step 4: Add the POD**

In the `PAGI::Utils` POD, beside the other helper entries:

```pod
=head2 request_ended_abnormally

    return if request_ended_abnormally($scope);

True when this request ended abnormally -- the client disconnected, a timeout
fired, or the server aborted the exchange -- and false otherwise, including
for a request that completed cleanly, one still in flight, and a scope with
no C<pagi.connection> object.

The discriminator is a defined C<disconnect_reason>, B<not> C<is_connected>:
a clean completion also reports false for C<is_connected>, and those
responses must still be validated. See L<PAGI::Spec::Www/"Application Left a
Response Incomplete">.

Components that observe response events use this to tell a spec-legal
disconnect from an application fault. An observer that infers completeness
from the event stream alone cannot distinguish them: an application that
stops early because its client vanished is required B<not> to send the
terminal event, so its event stream is indistinguishable from a buggy one.
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/utils/request-ended-abnormally.t'`

Expected: PASS, 8 tests.

- [ ] **Step 6: Verify the Perl 5.16 floor and POD**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.16.3 && perl -Ilib -c lib/PAGI/Utils.pm'`
Expected: `syntax OK`. If perl-5.16.3 is not installed, run `perl -Ilib -c`
under the project perl and record that the stricter gate was unavailable.

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/00-pod/'`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/PAGI/Utils.pm t/utils/request-ended-abnormally.t
git commit -m "feat: add request_ended_abnormally predicate

One discriminator for every component that observes response completeness:
a defined disconnect_reason means the request ended abnormally, while
is_connected alone is also cleared by a clean completion."
```

---

### Task 2: ETag must not validate a partial body

**Files:**
- Modify: `lib/PAGI/Middleware/ETag.pm:143-161`
- Test: `t/middleware/etag.t` (add a subtest; create the file only if absent)

**Interfaces:**
- Consumes: `PAGI::Utils::request_ended_abnormally($scope)` from Task 1.
- Produces: nothing consumed by later tasks.

**Why:** on an abnormal end the middleware synthesizes a complete response
from whatever it buffered, computing a validator over it and emitting
`more => 0`. A probe produced `etag="d41d8cd98f00b204e9800998ecf8427e"` —
the MD5 of the empty string — for an abandoned response. Paired with
`ConditionalGet`, a later request carrying that validator receives a 304 for
an empty representation.

> **Correction (applied during execution, ruled by the controller).** The
> test app shape below originally sent `http.response.start` plus one
> `more => 1` chunk. That does **not** reach the defect: ETag sets a
> streaming-passthrough flag on the first non-terminal chunk (`ETag.pm:89`)
> and returns before the synthesis block (`:138`), so the test passed against
> unmodified source. The defect requires an app that starts a response and
> sends **no body event at all** — the shape Task 4 already used. The code
> below is the corrected version. The same correction applies to Task 3.

- [ ] **Step 1: Write the failing test**

Add to `t/middleware/etag.t` (match the file's existing harness style; if it
has none, use this self-contained form):

```perl
use PAGI::Middleware::ETag;

subtest 'a disconnected client gets no fabricated validator' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; return Future->done };

    {
        package AbortedConn;
        sub new               { return bless {}, shift }
        sub is_connected      { return 0 }
        sub disconnect_reason { return 'client_closed' }
        sub on_disconnect     { return }
    }

    my $scope = { type => 'http', method => 'GET', path => '/x', headers => [],
                  'pagi.connection' => AbortedConn->new };

    # An application that starts a response and stops before sending any
    # body, because the client vanished. A non-terminal chunk here would
    # trip ETag's streaming passthrough and never reach the defect.
    my $app = sub {
        my ($app_scope, $receive, $inner_send) = @_;
        return (async sub {
            await $inner_send->({ type => 'http.response.start',
                                  status => 200, headers => [] });
            return;
        })->();
    };

    my $wrapped = PAGI::Middleware::ETag->new->wrap($app);
    Future->wrap($wrapped->($scope, sub { Future->done }, $send))->get;

    my @etags = map { @{ $_->{headers} || [] } }
                grep { $_->{type} eq 'http.response.start' } @sent;
    is(scalar(grep { lc($_->[0]) eq 'etag' } @etags), 0,
        'no ETag is attached to an aborted response');
    is(scalar(grep { $_->{type} eq 'http.response.body' && !$_->{more} } @sent), 0,
        'no terminal body event is fabricated');
};
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/middleware/etag.t'`

Expected: FAIL — an ETag header is present and a fabricated terminal body
event was sent.

- [ ] **Step 3: Implement the guard**

In `lib/PAGI/Middleware/ETag.pm`, add `use PAGI::Utils qw(request_ended_abnormally);`
to the imports, then guard the post-completion synthesis block that begins
with `my $body = join('', @body_parts);` (around line 144):

```perl
        # A client that vanished mid-response leaves a partial body. Computing
        # a validator over it and emitting more => 0 would assert that those
        # bytes are the whole representation -- forbidden for any producer by
        # PAGI::Spec::Www, "Application Left a Response Incomplete".
        return if request_ended_abnormally($scope);

        my $body = join('', @body_parts);
```

Confirm `$scope` is in lexical scope at that point; if the wrapper names it
differently, use that name.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/middleware/etag.t'`

Expected: PASS, including every pre-existing subtest in the file.

- [ ] **Step 5: Commit**

```bash
git add lib/PAGI/Middleware/ETag.pm t/middleware/etag.t
git commit -m "fix: ETag never validates a partial body

On an abnormal end the middleware computed a validator over whatever
partial body had accumulated and emitted it as complete -- with
ConditionalGet, a later request carrying it received a 304 for an empty
representation."
```

---

### Task 3: GZip must not compress and length a partial body

**Files:**
- Modify: `lib/PAGI/Middleware/GZip.pm:178-207`
- Test: `t/middleware/gzip.t` (add a subtest)

**Interfaces:**
- Consumes: `request_ended_abnormally($scope)`.
- Produces: nothing.

- [ ] **Step 1: Write the failing test**

Add a subtest to `t/middleware/gzip.t`, structurally identical to Task 2's
**as corrected** — an app that starts a response and sends no body event,
since a non-terminal chunk trips GZip's streaming passthrough the same way it
trips ETag's. Redeclare the `AbortedConn` package locally in this file; do not
create a shared test library in this task. Assert:

```perl
    is(scalar(grep { $_->{type} eq 'http.response.start' } @sent), 0,
        'no start event is fabricated for an aborted response');
    is(scalar(grep { $_->{type} eq 'http.response.body' && !$_->{more} } @sent), 0,
        'no terminal body event is fabricated');
```

Use the corrected Task 2 app shape: start only, no body event.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/middleware/gzip.t'`

Expected: FAIL — a fabricated `http.response.start` carrying
`Content-Length` plus a terminal body event.

- [ ] **Step 3: Implement the guard**

Add `use PAGI::Utils qw(request_ended_abnormally);` and guard the
post-completion block that builds `@new_headers` and emits start plus
terminal body (around line 178):

```perl
        # Same rule as ETag: a Content-Length computed from a partial buffer
        # asserts a completeness the application never claimed.
        return if request_ended_abnormally($scope);
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/middleware/gzip.t'`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/PAGI/Middleware/GZip.pm t/middleware/gzip.t
git commit -m "fix: GZip never fabricates a complete response after a disconnect"
```

---

### Task 4: ContentLength must not length a partial body

**Files:**
- Modify: `lib/PAGI/Middleware/ContentLength.pm:126-144`
- Test: `t/middleware/content-length.t` (add a subtest)

**Interfaces:**
- Consumes: `request_ended_abnormally($scope)`.
- Produces: nothing.

**Note on scope:** this defect is narrower than ETag's. The synthesis block
is gated by `!$is_streaming` (line 128), so it fires only when the
application disconnected *before* sending any `more => 1` chunk. The test
must therefore use an app that sends **only** `http.response.start`.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'a disconnected client gets no fabricated content-length' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; return Future->done };

    {
        package AbortedConn4;
        sub new               { return bless {}, shift }
        sub is_connected      { return 0 }
        sub disconnect_reason { return 'client_closed' }
        sub on_disconnect     { return }
    }

    my $scope = { type => 'http', method => 'GET', path => '/x', headers => [],
                  'pagi.connection' => AbortedConn4->new };

    # Starts a response, then the client vanishes before any body chunk.
    my $app = sub {
        my ($app_scope, $receive, $inner_send) = @_;
        return (async sub {
            await $inner_send->({ type => 'http.response.start',
                                  status => 200, headers => [] });
            return;
        })->();
    };

    my $wrapped = PAGI::Middleware::ContentLength->new->wrap($app);
    Future->wrap($wrapped->($scope, sub { Future->done }, $send))->get;

    my @headers = map { @{ $_->{headers} || [] } }
                  grep { $_->{type} eq 'http.response.start' } @sent;
    is(scalar(grep { lc($_->[0]) eq 'content-length' } @headers), 0,
        'no content-length is fabricated for an aborted response');
};
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/middleware/content-length.t'`

Expected: FAIL — a `content-length: 0` header is present.

- [ ] **Step 3: Implement the guard**

Add `use PAGI::Utils qw(request_ended_abnormally);` and change line 128's
condition:

```perl
        if (@buffered_events && !$has_content_length && !$is_streaming
            && !request_ended_abnormally($scope)) {
```

- [ ] **Step 4: Run the test to verify it passes**

Run the same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/PAGI/Middleware/ContentLength.pm t/middleware/content-length.t
git commit -m "fix: ContentLength never lengths a partial body"
```

---

### Task 5: Cascade must not fail a disconnected child

**Files:**
- Modify: `lib/PAGI/App/Cascade.pm:143-151`
- Test: `t/app/cascade.t` (add a subtest; locate the existing Cascade test
  file first with `ls t/app*/ | grep -i cascade`)

**Interfaces:**
- Consumes: `request_ended_abnormally($scope)`.
- Produces: nothing.

**Why:** this is a verbatim duplicate of the ResponseGuard defect fixed in
`eb4b2c6` — same `IncompleteResponse` message string, no connection-state
check. Read `lib/PAGI/Compose/ResponseGuard.pm` for the shape of the fix,
but call the shared predicate rather than copying its private helper.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'a child whose client disconnected is not an application error' => sub {
    {
        package AbortedConn5;
        sub new               { return bless {}, shift }
        sub is_connected      { return 0 }
        sub disconnect_reason { return 'client_closed' }
        sub on_disconnect     { return }
    }

    my $scope = { type => 'http', method => 'GET', path => '/x', headers => [],
                  'pagi.connection' => AbortedConn5->new };
    my $send = sub { return Future->done };

    my $child = sub {
        my ($app_scope, $receive, $inner_send) = @_;
        return (async sub {
            await $inner_send->({ type => 'http.response.start',
                                  status => 200, headers => [] });
            await $inner_send->({ type => 'http.response.body',
                                  body => 'partial', more => 1 });
            return;
        })->();
    };

    my $cascade = PAGI::App::Cascade->new(apps => [$child]);
    ok(lives {
        Future->wrap($cascade->to_app->($scope, sub { Future->done }, $send))->get;
    }, 'an incomplete response from a disconnected client does not raise')
        or note($@);
};
```

The constructor is `PAGI::App::Cascade->new(apps => [...], catch => [...])`
(`Cascade.pm:36-43`); `catch` defaults to `[404, 405]` and is not needed here.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/app/cascade.t'`

Expected: FAIL with "HTTP application completed after response start without
a terminal body".

- [ ] **Step 3: Implement the guard**

Add `use PAGI::Utils qw(request_ended_abnormally);` and guard the
`unless ($terminal_seen)` block:

```perl
            if ($start_seen) {
                unless ($terminal_seen || request_ended_abnormally($scope)) {
                    die PAGI::Exception::IncompleteResponse->new(
```

- [ ] **Step 4: Run the test to verify it passes**

Run the same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/PAGI/App/Cascade.pm t/app/cascade.t
git commit -m "fix: Cascade exempts an already-disconnected client

Verbatim duplicate of the ResponseGuard defect fixed in eb4b2c6, now
consuming the shared predicate rather than a private copy."
```

---

### Task 6: Lint must reclassify, not misdiagnose

**Files:**
- Modify: `lib/PAGI/Middleware/Lint.pm:182-208`
- Test: `t/middleware/lint.t` (add a subtest)

**Interfaces:**
- Consumes: `request_ended_abnormally($scope)`.
- Produces: nothing.

**Why:** Lint currently warns "Did you forget to 'await' the final `$send`
call?" for every disconnected client, and in strict mode `_warn` dies
(`:364-366`), failing the application Future — contradicting its own POD at
`:68-73`, which promises only shared-core sequencing violations are fatal.
`PAGI::Spec.pod:462` recommends Lint specifically for detecting incomplete
responses, so a false positive here is worse than in an ordinary middleware.

This task **reclassifies rather than suppresses**: a disconnect still
produces a diagnostic, but a truthful, non-fatal one.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'a disconnected client is reported as a disconnect, not a missing await' => sub {
    {
        package AbortedConn6;
        sub new               { return bless {}, shift }
        sub is_connected      { return 0 }
        sub disconnect_reason { return 'client_closed' }
        sub on_disconnect     { return }
    }

    my $scope = { type => 'http', method => 'GET', path => '/x', headers => [],
                  'pagi.connection' => AbortedConn6->new };
    my $send = sub { return Future->done };

    my $app = sub {
        my ($app_scope, $receive, $inner_send) = @_;
        return (async sub {
            await $inner_send->({ type => 'http.response.start',
                                  status => 200, headers => [] });
            await $inner_send->({ type => 'http.response.body',
                                  body => 'partial', more => 1 });
            return;
        })->();
    };

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, join '', @_ };

    my $wrapped = PAGI::Middleware::Lint->new->wrap($app);
    ok(lives {
        Future->wrap($wrapped->($scope, sub { Future->done }, $send))->get;
    }, 'a disconnect does not fail the application Future') or note($@);

    is(scalar(grep { /forget to .await./i } @warnings), 0,
        'no misleading missing-await diagnosis');
    is(scalar(grep { /disconnect/i } @warnings), 1,
        'the disconnect is still reported, with its reason');
    like(join('', @warnings), qr/client_closed/,
        'the report names the disconnect reason');
};

subtest 'strict mode does not fail a disconnected request' => sub {
    my $scope = { type => 'http', method => 'GET', path => '/x', headers => [],
                  'pagi.connection' => AbortedConn6->new };

    my $app = sub {
        my ($app_scope, $receive, $inner_send) = @_;
        return (async sub {
            await $inner_send->({ type => 'http.response.start',
                                  status => 200, headers => [] });
            await $inner_send->({ type => 'http.response.body',
                                  body => 'partial', more => 1 });
            return;
        })->();
    };

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, join '', @_ };

    my $wrapped = PAGI::Middleware::Lint->new(strict => 1)->wrap($app);
    ok(lives {
        Future->wrap($wrapped->($scope, sub { Future->done },
            sub { Future->done }))->get;
    }, 'strict mode does not die for a client that disconnected') or note($@);
    is(scalar(grep { /Lint Error/ } @warnings), 0,
        'no fatal Lint error was raised');
};
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/middleware/lint.t'`

Expected: FAIL — the missing-await text is present, no disconnect text, and
in strict mode the Future fails.

- [ ] **Step 3: Implement the reclassification**

Add `use PAGI::Utils qw(request_ended_abnormally);`. In the post-completion
diagnosis, before the `no_body` / `no_start` / `trailers` branches, add:

```perl
    # A client that vanished mid-response is not an application fault: the
    # application is required not to send the terminal event once it knows.
    # Report it truthfully, and never fatally, whatever the strictness.
    if (request_ended_abnormally($scope)) {
        my $conn = $scope->{'pagi.connection'};
        my $reason = $conn->disconnect_reason;
        $self->_note(
            "HTTP app stopped after the client disconnected ($reason); "
          . "no terminal http.response.body was sent, which is correct."
        );
        return;
    }
```

If `Lint` has no non-fatal reporting method, add `_note` as a sibling of
`_warn` that always uses `warn` and never dies, regardless of strict mode,
and document it in the Lint POD's diagnostics section.

- [ ] **Step 4: Run the test to verify it passes**

Run the same command. Expected: PASS, both subtests.

- [ ] **Step 5: Commit**

```bash
git add lib/PAGI/Middleware/Lint.pm t/middleware/lint.t
git commit -m "fix: Lint reports a disconnect instead of a missing await

Lint warned 'did you forget to await' for every client that vanished
mid-response, and died in strict mode -- despite its POD promising only
shared-core sequencing violations are fatal, and despite the spec
recommending Lint for exactly this detection."
```

---

### Task 7: Debug must flush buffered events after the app returns

**Files:**
- Modify: `lib/PAGI/Middleware/Debug.pm:95-149`
- Test: `t/middleware/debug.t` (add a subtest)

**Interfaces:**
- Consumes: `request_ended_abnormally($scope)`.
- Produces: nothing.

**Why:** for HTML responses Debug buffers the start event and every body
chunk, forwarding only inside `if (!$event->{more})`. The wrapper's last
statement is `await $app->(...)` with no post-completion flush, so an
incomplete response is swallowed entirely — **including the start event** —
turning an `after_start` condition into an apparent `before_start` one for
every outer observer.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'an aborted HTML response still reaches the wire' => sub {
    {
        package AbortedConn7;
        sub new               { return bless {}, shift }
        sub is_connected      { return 0 }
        sub disconnect_reason { return 'client_closed' }
        sub on_disconnect     { return }
    }

    my @sent;
    my $send = sub { push @sent, $_[0]; return Future->done };
    my $scope = { type => 'http', method => 'GET', path => '/x', headers => [],
                  'pagi.connection' => AbortedConn7->new };

    my $app = sub {
        my ($app_scope, $receive, $inner_send) = @_;
        return (async sub {
            await $inner_send->({ type => 'http.response.start', status => 200,
                headers => [['content-type', 'text/html']] });
            await $inner_send->({ type => 'http.response.body',
                body => '<html><body>partial', more => 1 });
            return;
        })->();
    };

    my $wrapped = PAGI::Middleware::Debug->new->wrap($app);
    Future->wrap($wrapped->($scope, sub { Future->done }, $send))->get;

    is(scalar(grep { $_->{type} eq 'http.response.start' } @sent), 1,
        'the start event is forwarded even though the response never completed');
    ok(scalar(grep { $_->{type} eq 'http.response.body' } @sent) >= 1,
        'the buffered body reaches the wire');
    is(scalar(grep { $_->{type} eq 'http.response.body' && !$_->{more} } @sent), 0,
        'no terminal body event is fabricated');
};
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/middleware/debug.t'`

Expected: FAIL — nothing reached the wire at all.

- [ ] **Step 3: Implement the flush**

Add `use PAGI::Utils qw(request_ended_abnormally);`. Replace the wrapper's
final `await $app->($scope, $receive, $wrapped_send);` with:

```perl
        await $app->($scope, $receive, $wrapped_send);

        # The response never reached its terminal event, so the buffered
        # start and body were never flushed. Forward what the application
        # actually produced -- without inventing a terminal event, which
        # would assert a completeness it never claimed.
        if (!$headers_sent && $response_status) {
            await $send->({
                type    => 'http.response.start',
                status  => $response_status,
                headers => \@response_headers,
            });
            $headers_sent = 1;
            await $send->({
                type => 'http.response.body',
                body => $body,
                more => 1,
            }) if length $body;
        }
```

Confirm the lexical names (`$headers_sent`, `$response_status`,
`@response_headers`, `$body`) against the file; use whatever it declares.

- [ ] **Step 4: Run the test to verify it passes**

Run the same command. Expected: PASS, and every pre-existing Debug subtest
still passes.

- [ ] **Step 5: Commit**

```bash
git add lib/PAGI/Middleware/Debug.pm t/middleware/debug.t
git commit -m "fix: Debug flushes buffered events when a response never completes

Debug buffered HTML start and body events and forwarded them only on the
terminal event, so an aborted response was swallowed entirely -- including
the start event, which made an after_start condition look like
before_start to every outer observer."
```

---

### Task 8: AccessLog records aborts with their reason

**Files:**
- Modify: `lib/PAGI/Middleware/AccessLog.pm:69-95` and `_log_request`
- Test: `t/middleware/access-log.t` (add a subtest)

**Interfaces:**
- Consumes: `request_ended_abnormally($scope)`.
- Produces: nothing.

**Why:** an aborted 2MB transfer currently logs identically to a small
successful `200`. This is the observability half of the panel's finding:
Kestrel emits a *distinct* event for an aborted request rather than going
silent, and nginx has `499` plus `$request_completion` for the same purpose.
PAGI can express neither today.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'an aborted transfer is distinguishable in the log' => sub {
    {
        package AbortedConn8;
        sub new               { return bless {}, shift }
        sub is_connected      { return 0 }
        sub disconnect_reason { return 'client_closed' }
        sub on_disconnect     { return }
    }

    my @lines;
    my $scope = { type => 'http', method => 'GET', path => '/stream',
                  headers => [], 'pagi.connection' => AbortedConn8->new };

    my $app = sub {
        my ($app_scope, $receive, $inner_send) = @_;
        return (async sub {
            await $inner_send->({ type => 'http.response.start',
                                  status => 200, headers => [] });
            await $inner_send->({ type => 'http.response.body',
                                  body => 'partial', more => 1 });
            return;
        })->();
    };

    my $wrapped = PAGI::Middleware::AccessLog->new(
        logger => sub { push @lines, $_[0] },
    )->wrap($app);
    Future->wrap($wrapped->($scope, sub { Future->done },
        sub { Future->done }))->get;

    is(scalar @lines, 1, 'one line was logged');
    like($lines[0], qr/client_closed/,
        'the line records that the client disconnected, with its reason');
};
```

The sink option is `logger` (`AccessLog.pm:49`, defaulting to a sub that
warns), and the formatted line is emitted at `AccessLog.pm:100`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/middleware/access-log.t'`

Expected: FAIL — the line contains no reason.

- [ ] **Step 3: Implement the abort field**

Add `use PAGI::Utils qw(request_ended_abnormally);`, then pass the reason
into `_log_request` and append it to the formatted line:

```perl
        my $abort_reason;
        if (request_ended_abnormally($scope)) {
            my $conn = $scope->{'pagi.connection'};
            $abort_reason = $conn->disconnect_reason;
        }
        $self->_log_request($scope, $status, $response_size, $start_time,
            $abort_reason);
```

In `_log_request`, accept the extra argument and append
` aborted=$abort_reason` to the line when it is defined, leaving the format
byte-identical when it is not. Document the field in the AccessLog POD,
noting it is the nginx `499` / `$request_completion` analogue.

- [ ] **Step 4: Run the test to verify it passes**

Run the same command. Expected: PASS, and existing AccessLog format tests
still pass unchanged.

- [ ] **Step 5: Commit**

```bash
git add lib/PAGI/Middleware/AccessLog.pm t/middleware/access-log.t
git commit -m "feat: AccessLog records aborted transfers with their reason

An aborted 2MB stream previously logged identically to a small successful
200. Suppressing the error was correct; going silent was not."
```

---

### Task 9: Align Response.pm and Test::Response

**Files:**
- Modify: `lib/PAGI/Response.pm:699-709`
- Modify: `lib/PAGI/Test/Response.pm:10-26` and add an accessor
- Test: `t/response/` (add to the existing emission test) and
  `t/test-response.t` (locate with `ls t | grep -i response`)

**Interfaces:**
- Consumes: `request_ended_abnormally($scope)`.
- Produces: `PAGI::Test::Response->body_complete` — returns `1` when the
  captured events reached a terminal body, `0` otherwise.

**Why (Response.pm):** it keys on `!is_connected` with a `response_complete`
correction, but `PAGI::Server::ConnectionState::response_complete` always
returns `undef`, so against the reference server that branch reads a *clean
completion* as a disconnect and suppresses a real error. Two incompatible
readings of one rule in one distribution.

**Why (Test::Response):** `_body_complete` is already tracked at `:47` but
never exposed, so a test cannot assert whether a captured response completed.

- [ ] **Step 1: Write the failing tests**

For `Response.pm`, a test that a *cleanly completed* connection object does
not suppress the incomplete-response croak:

The croak lives in the protocol-emission path (`Response.pm:685-712`), which
is reached through WebSocket denial and SSE decline — `$response->_emit(...)`
followed by the completeness checks. Add the case to the existing denial
test, `t/websocket/denial-response.t`, whose harness already builds a
WebSocket scope and drives `deny`:

```perl
subtest 'a cleanly completed connection still reports an incomplete denial' => sub {
    {
        package CompletedConn9;
        sub new                { return bless {}, shift }
        sub is_connected       { return 0 }       # cleared by clean completion
        sub disconnect_reason  { return undef }   # ... but no abnormal reason
        sub response_complete  { return undef }   # what the reference server returns
        sub on_disconnect      { return }
    }

    # A Response subclass that starts but never emits a terminal body.
    {
        package IncompleteResponseFixture;
        our @ISA = ('PAGI::Response');
        sub _emit {
            my ($self, $scope, $receive, $send) = @_;
            return (async sub {
                await $send->({ type => 'http.response.start',
                                status => 401, headers => [] });
                return;   # no terminal body
            })->();
        }
    }

    # Reuse this file's existing scope/send builders, substituting
    # CompletedConn9 for its pagi.connection, then assert the denial croaks
    # rather than being silently accepted as an abnormal end.
    my $error;
    eval { run_denial(IncompleteResponseFixture->new(''), CompletedConn9->new); 1 }
        or $error = $@;
    like($error, qr/did not emit a terminal response body/,
        'a clean completion does not excuse an incomplete denial response');
};
```

Name the helper `run_denial` after whatever this file already uses to drive a
denial; if it has no such helper, extract one from an existing subtest rather
than duplicating the setup.

For `Test::Response`:

```perl
is(PAGI::Test::Response->new(events => [
    { type => 'http.response.start', status => 200, headers => [] },
    { type => 'http.response.body', body => 'x', more => 0 },
])->body_complete, 1, 'a terminal body marks the response complete');

is(PAGI::Test::Response->new(events => [
    { type => 'http.response.start', status => 200, headers => [] },
    { type => 'http.response.body', body => 'x', more => 1 },
])->body_complete, 0, 'a response with no terminal body is incomplete');
```

- [ ] **Step 2: Run both to verify they fail**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/test-response.t t/response/'`

Expected: FAIL — `body_complete` is not a method; the Response.pm case does
not croak.

- [ ] **Step 3: Implement both**

In `Response.pm`, replace the four-condition `blessed`/`can`/`response_complete`
block with the shared predicate:

```perl
        croak "$operation Response did not emit a terminal response body"
            unless $start_committed && request_ended_abnormally(\%http_scope);
```

adding `use PAGI::Utils qw(request_ended_abnormally);` — check for a circular
dependency first with `grep -n 'use PAGI::Response' lib/PAGI/Utils.pm`; if
one exists, require the module lazily inside the sub instead.

In `Test/Response.pm`, add beside the other accessors:

```perl
sub body_complete { return $_[0]->{_body_complete} ? 1 : 0 }
```

and document it in the POD as "true when the captured events reached a
terminal body; false for a response that stopped short, including one whose
client disconnected."

- [ ] **Step 4: Run both to verify they pass**

Run the same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/PAGI/Response.pm lib/PAGI/Test/Response.pm t/test-response.t t/response/
git commit -m "fix: one abnormal-end discriminator across Response and Test::Response

Response.pm keyed on !is_connected plus response_complete, which the
reference server always reports as undef -- so a clean completion read as
a disconnect and suppressed a real error. Test::Response now exposes the
completeness it already tracked."
```

---

### Task 10: Pin the laundering hazard and document Debug's HTML buffering

**Files:**
- Create: `t/middleware/disconnect-laundering.t`
- Modify: `lib/PAGI/Middleware/Debug.pm` (POD only)

**Interfaces:**
- Consumes: the fixes from Tasks 2, 3, 5.
- Produces: nothing.

**Why the test:** before Tasks 2 and 3, ETag and GZip *laundered*
incompleteness — they emitted a terminal event, so an outer guard or Cascade
saw a complete response and stayed quiet. Detection therefore depended on
middleware order *and* on where in the stream the client left. That should
now be impossible; this test proves it and stops it regressing.

**Why the doc:** Debug buffers HTML to inject its panel, so streaming HTML
does not stream through it. This is defensible by design — a panel cannot be
injected before `</body>` without buffering — but it is currently
undocumented, and a user streaming HTML through Debug will see their stream
collapse into one response with no explanation.

- [ ] **Step 1: Write the laundering test**

```perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use PAGI::Middleware::ETag;
use PAGI::Middleware::GZip;
use PAGI::Compose::ResponseGuard;

{
    package AbortedConn10;
    sub new               { return bless {}, shift }
    sub is_connected      { return 0 }
    sub disconnect_reason { return 'client_closed' }
    sub on_disconnect     { return }
}

sub aborted_scope {
    return { type => 'http', method => 'GET', path => '/x', headers => [],
             'pagi.connection' => AbortedConn10->new };
}

sub aborted_app {
    return sub {
        my ($scope, $receive, $send) = @_;
        return (async sub {
            await $send->({ type => 'http.response.start', status => 200,
                headers => [['content-type', 'text/plain']] });
            await $send->({ type => 'http.response.body',
                body => 'partial', more => 1 });
            return;
        })->();
    };
}

# An inner middleware must not manufacture a terminal event that would make
# an outer observer believe the response completed.
for my $case (
    ['ETag', sub { PAGI::Middleware::ETag->new->wrap($_[0]) }],
    ['GZip', sub { PAGI::Middleware::GZip->new->wrap($_[0]) }],
) {
    my ($label, $wrap) = @$case;

    subtest "$label does not launder an aborted response past an outer guard" => sub {
        my @sent;
        my $send = sub { push @sent, $_[0]; return Future->done };

        my $inner   = $wrap->(aborted_app());
        my $guarded = PAGI::Compose::ResponseGuard->wrap($inner);

        ok(lives {
            Future->wrap($guarded->(aborted_scope(), sub { Future->done }, $send))->get;
        }, "$label: the guard does not raise for a disconnected client") or note($@);

        is(scalar(grep { $_->{type} eq 'http.response.body' && !$_->{more} } @sent), 0,
            "$label: no terminal event is emitted, so completeness is not laundered");
    };
}

# Order independence: the same outcome whichever way the two are nested.
subtest 'detection does not depend on middleware order' => sub {
    my @orders = (
        ['ETag outside GZip', sub {
            PAGI::Middleware::ETag->new->wrap(
                PAGI::Middleware::GZip->new->wrap($_[0]))
        }],
        ['GZip outside ETag', sub {
            PAGI::Middleware::GZip->new->wrap(
                PAGI::Middleware::ETag->new->wrap($_[0]))
        }],
    );

    for my $order (@orders) {
        my ($label, $wrap) = @$order;
        my @sent;
        my $send = sub { push @sent, $_[0]; return Future->done };
        my $app  = PAGI::Compose::ResponseGuard->wrap($wrap->(aborted_app()));

        ok(lives {
            Future->wrap($app->(aborted_scope(), sub { Future->done }, $send))->get;
        }, "$label: no application error") or note($@);
        is(scalar(grep { $_->{type} eq 'http.response.body' && !$_->{more} } @sent), 0,
            "$label: no fabricated terminal event");
    }
};

done_testing;
```

- [ ] **Step 2: Run it**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/middleware/disconnect-laundering.t'`

Expected: PASS, because Tasks 2, 3, and 5 already landed. If it fails, the
earlier fix is incomplete — fix that task's component rather than weakening
this test.

- [ ] **Step 3: Document Debug's HTML buffering**

Add to the `PAGI::Middleware::Debug` POD, under a `=head2 Streaming HTML`
heading:

```pod
=head2 Streaming HTML

The debug panel is injected before the closing C<< </body> >> tag, which
requires the complete document, so Debug B<buffers HTML responses> and
forwards them as a single response once the application finishes. An HTML
response that streams in chunks through this middleware therefore reaches
the client all at once, not progressively.

Non-HTML responses are forwarded chunk by chunk and are unaffected. If you
need progressive HTML delivery, place Debug outside the streaming route, or
omit it in that environment.

If the response never completes -- the client disconnected mid-stream --
Debug forwards the events the application did produce and does not
manufacture a terminal event, so the response stays observably incomplete
(see L<PAGI::Spec::Www/"Application Left a Response Incomplete">).
```

- [ ] **Step 4: Verify the POD**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/00-pod/'`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add t/middleware/disconnect-laundering.t lib/PAGI/Middleware/Debug.pm
git commit -m "test: pin that middleware cannot launder an aborted response

Before the ETag and GZip fixes, an inner middleware emitting a terminal
event made an outer guard see a complete response, so detection depended
on middleware order and on where the client left. Also documents that
Debug buffers HTML to inject its panel."
```

---

### Task 11: Full suite, Changes, and ledger closeout

**Files:**
- Modify: `Changes`
- Modify: `.pagi-open-issues.md` (mark items closed)

**Interfaces:**
- Consumes: Tasks 1-10.
- Produces: nothing.

- [ ] **Step 1: Run the full suite once**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr -j4 t/' > /tmp/full-suite.txt 2>&1; echo "exit=$?"; tail -20 /tmp/full-suite.txt`

Expected: PASS. Baseline was 219 files / 2380 tests; this plan adds roughly
9 files' worth of subtests plus one new file. Read the captured output in
full — do not judge from a truncated tail. Output must be pristine: no
stray warnings.

- [ ] **Step 2: Verify the cross-repo integration test still passes**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l -I ~/Desktop/PAGI-Project/PAGI-Server/lib t/integration/process-streaming-end-to-end.t'`

Expected: PASS, 4 subtests. This is the end-to-end canary that found the
original defect.

- [ ] **Step 3: Write the Changes entry**

Add under `0.002003 - UNRELEASED`, above the existing entries:

```
  - FIX: components that observe response completeness now distinguish a
    client disconnect from an application fault, via the new
    PAGI::Utils::request_ended_abnormally predicate. Previously a client
    that vanished mid-response could cause ETag to attach a validator
    computed over a partial body, GZip and ContentLength to emit a
    fabricated Content-Length, Cascade to fail the application Future,
    Lint to report a nonexistent missing-await bug (fatally, in strict
    mode), and Debug to swallow the response entirely. AccessLog now
    records aborted transfers with their disconnect reason. Response and
    Test::Response use the same discriminator, which is a defined
    disconnect_reason -- is_connected alone is also cleared by a clean
    completion.
```

- [ ] **Step 4: Close the ledger items**

In `.pagi-open-issues.md`, mark F0-F9 closed with their commit SHAs, leaving
the panel verdict and prior-art sections intact as the rationale record.

- [ ] **Step 5: Commit**

```bash
git add Changes .pagi-open-issues.md
git commit -m "docs: record the disconnect-aware observer fixes"
```

---

## Notes for the executor

- **Do not modify `PAGI::Response::Stream`.** It already omits the terminal
  event on disconnect, which is exactly what the spec requires. Every defect
  in this plan is in a component that *observes* Stream's output.
- **Do not add an abort event.** A four-expert panel evaluated
  `http.response.abort` and rejected it; the rationale is recorded in
  `.pagi-open-issues.md` item 1b. If a task seems to need one, stop and ask.
- **If a component's `$scope` is not in lexical scope** where the guard
  belongs, that is a signal the wrapper needs a small refactor to capture it —
  do that rather than threading the connection object separately.
- **If a fix requires more than the guard plus a test**, stop and report. The
  shape of every fix in Tasks 2-5 is one predicate call; if a component
  resists that, it likely has a second defect worth its own review.
