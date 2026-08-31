# Buffering Middleware Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop buffering middleware from fabricating or destroying responses when
an event stream ends early, first by fixing the guard in place, then by making
the mistake unrepresentable behind a shared helper.

**Architecture:** Phase 1 replaces a guard that asks *why the request ended*
(`request_ended_abnormally($scope)`) with one that asks *what did I receive*
(`$terminal_seen`) in the three response-buffering middleware, and corrects the
tests that ratified the old behaviour. Phase 2 extracts the buffer-and-re-emit
pattern into two helpers — a whole-body transform whose callback runs only when
a terminal event was observed, and a streaming transform that never withholds
the head — then migrates the middleware onto them, moving GZip from the first
category to the second so it gains streaming compression.

**Tech Stack:** Perl 5.16+, `Future::AsyncAwait`, `Test2::V0`,
`Compress::Raw::Zlib`.

**Spec:** `PAGI::Spec::Www`, section "Application Left a Response Incomplete"
(PAGI 0.002008, currently UNRELEASED). The governing paragraphs are *Every
producer is bound, not only the server*, *Which signal answers which question*,
and *Re-emitting a buffered body event*.

## Global Constraints

- Perl 5.16 compatibility. Gate every changed module:
  `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.16.3 && perl -Ilib -c <module>'`
- All Perl runs through perlbrew:
  `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && <cmd>'`
- The suite has subdirectories: use `prove -lr t/`, never `prove -l t/`.
- Never `git add -A`. Files matching `.pagi-*` and `.superpowers/` are never
  staged. Another agent may hold uncommitted work in this checkout — commit with
  the pathspec form, `git commit <paths> -m "..."`, and verify with
  `git show --stat HEAD`.
- Public surface is documented in POD in the same commit that introduces it.
- **Prove every regression guard by mutation.** If an assertion guards a bug
  your RED step does not already demonstrate, break the code in a scratch copy
  *outside any git work tree* (confirm with `git rev-parse --is-inside-work-tree`
  failing there), run the assertion, confirm it fails, and report the transcript.
  Never mutate a tracked file. This plan's predecessor shipped three assertion
  sets that could not fail.
- `more` defaults to `0`, so a re-emitted non-terminal body event **must** carry
  `more => 1` explicitly. Omitting it asserts completeness.

---

## File Structure

**Phase 1** — corrective, lands on the existing `example/process-streaming`
branch alongside the disconnect-aware-observer work it corrects.

| File | Responsibility |
|---|---|
| `lib/PAGI/Middleware/ETag.pm` | Guard on terminal-seen; emit withheld head without a validator |
| `lib/PAGI/Middleware/GZip.pm` | Same, without `Content-Encoding` |
| `lib/PAGI/Middleware/ContentLength.pm` | Same, without `content-length` |
| `t/middleware/07-compression.t` | Correct the assertion that ratified swallowing |
| `t/middleware/etag.t`, `t/middleware/01-content-length.t` | Replace assertions that grep an empty list |
| `t/middleware/disconnect-laundering.t` | Unblocked; commits as written |

**Phase 2** — extraction, on a new branch `refactor/buffered-response-helpers`.

| File | Responsibility |
|---|---|
| `lib/PAGI/Middleware/BufferedResponse.pm` | Both helpers: `buffer_whole_response`, `stream_transform_response` |
| `t/middleware/buffered-response.t` | The helpers' own contract tests, incl. abort scenarios |
| `lib/PAGI/Middleware/ETag.pm`, `ContentLength.pm` | Migrated onto `buffer_whole_response` |
| `lib/PAGI/Middleware/GZip.pm` | Migrated onto `stream_transform_response` — behaviour change |

`Debug.pm` is **not** migrated. It is dev-only, was copied from Plack as a
curiosity, and is a candidate for deprecation; its hand-rolled flush is already
correct and documented. Leaving it out keeps a deprecation cheap.

---

# PHASE 1 — Fix the guard in place

### Task 1: ETag guards on terminal-seen

**Files:**
- Modify: `lib/PAGI/Middleware/ETag.pm` — lexicals at `:56-59`, guard at `:149`
- Test: `t/middleware/etag.t`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing. Phase 2 replaces this file's internals wholesale.

**Why:** `ETag.pm:149` reads `request_ended_abnormally($scope)`, which asks
whether the *client* left. When an application stops after `http.response.start`
with the client **still connected**, that guard is false and the middleware falls
through to synthesis, attaching a validator computed over an empty buffer to a
complete, cacheable 200. Measured today:
`ETag: "d41d8cd98f00b204e9800998ecf8427e"` — the MD5 of the empty string.

- [ ] **Step 1: Write the failing test**

Add to `t/middleware/etag.t`:

```perl
subtest 'no validator is attached when no terminal event was received' => sub {
    {
        package LiveConnE1;
        sub new               { return bless {}, shift }
        sub is_connected      { return 1 }
        sub disconnect_reason { return undef }
        sub on_disconnect     { return }
    }

    my @sent;
    my $app = sub {
        my ($scope, $receive, $inner_send) = @_;
        return (async sub {
            await $inner_send->({ type => 'http.response.start', status => 200,
                                  headers => [['content-type', 'text/plain']] });
            return;   # client still connected; app just stops
        })->();
    };

    my $wrapped = PAGI::Middleware::ETag->new->wrap($app);
    Future->wrap($wrapped->(
        { type => 'http', method => 'GET', path => '/x', scheme => 'http',
          http_version => '1.1', headers => [],
          'pagi.connection' => LiveConnE1->new },
        sub { Future->done },
        sub { push @sent, $_[0]; Future->done },
    ))->get;

    my @etags = map { @{ $_->{headers} || [] } }
                grep { $_->{type} eq 'http.response.start' } @sent;
    is(scalar(grep { lc($_->[0]) eq 'etag' } @etags), 0,
        'no ETag over a body that never terminated');
    is(scalar(grep { $_->{type} eq 'http.response.body' && !$_->{more} } @sent), 0,
        'no terminal body event is fabricated');
    is(scalar(grep { $_->{type} eq 'http.response.start' } @sent), 1,
        "the application's own response start still reaches the wire");
};
```

The third assertion is what distinguishes this from the old behaviour; the first
two would pass against an empty `@sent` too, which is exactly the vacuity Task 4
fixes elsewhere in this file.

- [ ] **Step 2: Run it and confirm it fails for the stated reason**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/middleware/etag.t'`

Expected: FAIL on assertion 1 — an `etag` header **is** present, value
`"d41d8cd98f00b204e9800998ecf8427e"`. Assertion 2 also fails (a `more => 0`
event was fabricated). Assertion 3 passes already. If assertion 1 passes, stop
and report: the premise does not hold.

- [ ] **Step 3: Add the in-band flag**

Beside the other lexicals (`ETag.pm:56-59`):

```perl
        my @body_parts;
        my $original_headers;
        my $status;
        my $is_streaming = 0;
        my $terminal_seen = 0;
```

And where body bytes are accumulated, immediately after
`push @body_parts, $event->{body} // '';`:

```perl
                $terminal_seen = 1 unless $event->{more};
```

`unless $event->{more}` is deliberate: `more` defaults to `0`, so an omitted
`more` is terminal.

- [ ] **Step 4: Replace the guard**

Replace this, at `ETag.pm:149`:

```perl
        return if request_ended_abnormally($scope);
```

with:

```perl
        # We withheld the application's start event; emit it whatever else
        # happened. Swallowing it tells every outer observer that no response
        # was ever started -- a different state, which servers report
        # differently and which can license a client to retry an idempotent
        # request (RFC 9110 S9.2.2).
        #
        # Only a terminal event we actually received licenses the validator: an
        # ETag over a partial buffer asserts those bytes are the whole
        # representation. This asks what we received, not why the application
        # stopped, so it is equally correct for a client disconnect and for an
        # application that returned early with its client still connected.
        unless ($terminal_seen) {
            await $send->({
                type    => 'http.response.start',
                status  => $status,
                headers => $original_headers // [],
            });
            return;
        }
```

Then remove the now-unused import at the top of the file:

```perl
use PAGI::Utils qw(request_ended_abnormally);
```

Leave `return unless defined $status;` above it exactly as it is — nothing
withheld, nothing emitted.

- [ ] **Step 5: Confirm green, and confirm nothing else regressed**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t/middleware/etag.t t/compose/ t/integration/'`

Expected: PASS throughout.

Then the 5.16 gate:
`bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.16.3 && perl -Ilib -c lib/PAGI/Middleware/ETag.pm'`

- [ ] **Step 6: Confirm no stray reference to the dropped import**

Run: `grep -n 'request_ended_abnormally' lib/PAGI/Middleware/ETag.pm`

Expected: no output. Perl will not catch a leftover call at compile time.

- [ ] **Step 7: Commit**

```bash
git commit lib/PAGI/Middleware/ETag.pm t/middleware/etag.t -m "fix: ETag licenses its validator on the terminal event, not on connection state"
git show --stat HEAD
```

---

### Task 2: GZip guards on terminal-seen

**Files:**
- Modify: `lib/PAGI/Middleware/GZip.pm` — guard at `:168`
- Test: `t/middleware/07-compression.t`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

**Why:** identical defect to Task 1. With the client connected, GZip falls
through to synthesis and emits a fabricated terminal event
(`body len=0 more=0`) for a response that produced no body.

- [ ] **Step 1: Write the failing test**

Add to `t/middleware/07-compression.t`, following that file's existing helpers
(`make_scope`, `run_async`):

```perl
subtest 'GZip fabricates nothing when no terminal event was received' => sub {
    {
        package LiveConnG1;
        sub new               { return bless {}, shift }
        sub is_connected      { return 1 }
        sub disconnect_reason { return undef }
        sub on_disconnect     { return }
    }

    my @events;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200,
                        headers => [['content-type', 'text/plain']] });
        return;
    };

    my $scope = make_scope(headers => [['Accept-Encoding', 'gzip']]);
    $scope->{'pagi.connection'} = LiveConnG1->new;

    my $wrapped = PAGI::Middleware::GZip->new->wrap($app);
    run_async { $wrapped->($scope,
        (async sub { { type => 'http.request', body => '', more => 0 } }),
        (async sub { push @events, $_[0] })) };

    is(scalar(grep { $_->{type} eq 'http.response.body' && !$_->{more} } @events), 0,
        'no terminal body event is fabricated');
    is(scalar(grep { $_->{type} eq 'http.response.start' } @events), 1,
        "the application's own response start still reaches the wire");
};
```

- [ ] **Step 2: Run it and confirm it fails for the stated reason**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/middleware/07-compression.t'`

Expected: FAIL on assertion 1 — a `more => 0` body event was fabricated.

- [ ] **Step 3: Add the flag and replace the guard**

Add `my $terminal_seen = 0;` beside the other lexicals, and
`$terminal_seen = 1 unless $event->{more};` immediately after
`push @body_parts, $event->{body} // '';`.

Replace, at `GZip.pm:168`:

```perl
        return if request_ended_abnormally($scope);
```

with:

```perl
        # See ETag: emit the head we withheld, but compress nothing and claim
        # nothing. Only a terminal event we received licenses Content-Encoding
        # and Content-Length.
        unless ($terminal_seen) {
            await $send->({
                type    => 'http.response.start',
                status  => $status,
                headers => $original_headers // [],
            });
            return;
        }
```

Remove `use PAGI::Utils qw(request_ended_abnormally);`.

- [ ] **Step 4: Confirm green**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t/middleware/07-compression.t t/compose/ t/integration/'`

Expected: PASS. Note `07-compression.t:210` still asserts zero start events and
will now FAIL — that assertion is corrected in Task 4, which must land in the
same working session. If you cannot complete Task 4, say so rather than leaving
the suite red.

- [ ] **Step 5: 5.16 gate, stray-reference check, commit**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.16.3 && perl -Ilib -c lib/PAGI/Middleware/GZip.pm'
grep -n 'request_ended_abnormally' lib/PAGI/Middleware/GZip.pm    # expect no output
git commit lib/PAGI/Middleware/GZip.pm t/middleware/07-compression.t -m "fix: GZip licenses compression on the terminal event, not on connection state"
```

---

### Task 3: ContentLength guards on terminal-seen

**Files:**
- Modify: `lib/PAGI/Middleware/ContentLength.pm` — guard at `:129-130`
- Test: `t/middleware/01-content-length.t`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

**Why:** same defect, third shape. With the client connected this emits
`content-length: 0` on the head and **no body event at all** — a head claiming a
length for a body that never arrives.

Note this middleware buffers whole *events* in `@buffered_events` (start and
body together), not body strings, so its guard is a positive `if` and inverts
rather than short-circuits.

- [ ] **Step 1: Write the failing test**

Add to `t/middleware/01-content-length.t`:

```perl
subtest 'no content-length is claimed without a terminal event' => sub {
    {
        package LiveConnC1;
        sub new               { return bless {}, shift }
        sub is_connected      { return 1 }
        sub disconnect_reason { return undef }
        sub on_disconnect     { return }
    }

    my @sent;
    my $app = sub {
        my ($scope, $receive, $inner_send) = @_;
        return (async sub {
            await $inner_send->({ type => 'http.response.start', status => 200,
                                  headers => [['content-type', 'text/plain']] });
            return;
        })->();
    };

    my $wrapped = PAGI::Middleware::ContentLength->new->wrap($app);
    Future->wrap($wrapped->(
        { type => 'http', method => 'GET', path => '/x', scheme => 'http',
          http_version => '1.1', headers => [],
          'pagi.connection' => LiveConnC1->new },
        sub { Future->done },
        sub { push @sent, $_[0]; Future->done },
    ))->get;

    my @headers = map { @{ $_->{headers} || [] } }
                  grep { $_->{type} eq 'http.response.start' } @sent;
    is(scalar(grep { lc($_->[0]) eq 'content-length' } @headers), 0,
        'no content-length over a body that never terminated');
    is(scalar(grep { $_->{type} eq 'http.response.start' } @sent), 1,
        "the application's own response start still reaches the wire");
};
```

- [ ] **Step 2: Run it and confirm it fails for the stated reason**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/middleware/01-content-length.t'`

Expected: FAIL on assertion 1 — `content-length: 0` is present.

- [ ] **Step 3: Add the flag**

Beside the other lexicals, `my $terminal_seen = 0;`. Where body events are
buffered, immediately after `push @buffered_events, $event;`:

```perl
                $terminal_seen = 1 if $event->{type} eq 'http.response.body'
                                   && !$event->{more};
```

- [ ] **Step 4: Invert the guard**

Replace the post-`await` block:

```perl
        if (@buffered_events && !$has_content_length && !$is_streaming
            && !request_ended_abnormally($scope)) {
```

with:

```perl
        return unless @buffered_events;

        # No terminal event means no length to claim. Emit what we withheld,
        # verbatim, so the response the application started is not destroyed --
        # but attach nothing. Events are forwarded unchanged, which preserves
        # each one's `more` (it defaults to 0, so dropping it would assert a
        # completeness the application never claimed).
        if (!$terminal_seen) {
            for my $buffered (@buffered_events) {
                await $send->($buffered);
            }
            return;
        }

        if (!$has_content_length && !$is_streaming) {
```

The remainder of the original block is unchanged. Remove
`use PAGI::Utils qw(request_ended_abnormally);`.

Use `for my $buffered (...)`, never `for (...)` — `await` inside a `foreach`
over the non-lexical `$_` is a compile error under `Future::AsyncAwait`.

- [ ] **Step 5: Confirm green, 5.16 gate, stray-reference check, commit**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t/middleware/01-content-length.t t/compose/ t/integration/'
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.16.3 && perl -Ilib -c lib/PAGI/Middleware/ContentLength.pm'
grep -n 'request_ended_abnormally' lib/PAGI/Middleware/ContentLength.pm   # expect no output
git commit lib/PAGI/Middleware/ContentLength.pm t/middleware/01-content-length.t -m "fix: ContentLength claims a length only for a terminated body"
```

---

### Task 4: Correct the tests that ratified the old behaviour

**Files:**
- Modify: `t/middleware/07-compression.t:210`
- Modify: `t/middleware/etag.t` (the abort subtest's assertions)
- Modify: `t/middleware/01-content-length.t` (same)
- Commit: `t/middleware/disconnect-laundering.t` (already written, currently untracked)

**Interfaces:**
- Consumes: Tasks 1-3.
- Produces: nothing.

**Why:** three shipped assertions encode the behaviour Tasks 1-3 correct. One
directly contradicts them; two are vacuous — they `grep` a list that is empty
under the old behaviour, so they pass against `sub { }`.

- [ ] **Step 1: Correct the contradicting assertion**

At `t/middleware/07-compression.t:210`, replace:

```perl
    is(scalar(grep { $_->{type} eq 'http.response.start' } @events), 0,
        'no start event is fabricated for an aborted response');
```

with:

```perl
    is(scalar(grep { $_->{type} eq 'http.response.start' } @events), 1,
        "the application's own response start is forwarded, not swallowed");
    my @enc = map { @{ $_->{headers} || [] } }
              grep { $_->{type} eq 'http.response.start' } @events;
    is(scalar(grep { lc($_->[0]) eq 'content-encoding' } @enc), 0,
        'but no Content-Encoding is claimed for a body that never terminated');
```

The old label said "no start event is *fabricated*". Nothing was fabricated —
the application at that subtest's `$app` genuinely sent that start. The label
described its sibling assertion, not itself.

- [ ] **Step 2: De-vacuum the ETag and ContentLength abort assertions**

In `t/middleware/etag.t` and `t/middleware/01-content-length.t`, each abort
subtest builds `@etags` / `@headers` by mapping over start events and greps for
a header. Under the old behaviour no start event existed, so both greps ran over
an empty list. Add to each, before the existing assertions:

```perl
    is(scalar(grep { $_->{type} eq 'http.response.start' } @sent), 1,
        'a start event was actually forwarded, so the header check is not vacuous');
```

- [ ] **Step 3: Run the full middleware suite**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t/middleware/'`

Expected: PASS.

- [ ] **Step 4: Commit the blocked laundering test**

`t/middleware/disconnect-laundering.t` is already written and currently
untracked; its four `http.response.start` assertions were blocked pending this
change and are now correct as written. Verify, then commit:

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/middleware/disconnect-laundering.t'
git add t/middleware/disconnect-laundering.t
git commit t/middleware/disconnect-laundering.t t/middleware/07-compression.t t/middleware/etag.t t/middleware/01-content-length.t -m "test: pin the forwarding contract and de-vacuum the abort assertions"
```

- [ ] **Step 5: Full suite**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr -j4 t/' > "$SCRATCH/full-suite.txt" 2>&1; echo "prove exit=$?"`

Open the file with the Read tool and read it in full — do not judge from a
tail. Expected: PASS, pristine. Baseline at the end of the predecessor plan was
221 files / 2405 tests plus one pre-existing skip.

---

# PHASE 2 — Make the mistake unrepresentable

Phase 2 runs on a **new branch**, `refactor/buffered-response-helpers`, cut from
`main` after Phase 1 merges.

### Task 5: The whole-body helper

**Files:**
- Create: `lib/PAGI/Middleware/BufferedResponse.pm`
- Test: `t/middleware/buffered-response.t`

**Interfaces:**
- Consumes: nothing.
- Produces:
  `buffer_whole_response($app, engage => \&code, transform => \&code)`
  returning an async coderef with the PAGI app signature.
  - `engage->($status, $headers)` → true to buffer, false to pass through from
    this response's start onward. Called once, on `http.response.start`.
  - `transform->($status, $headers, $body)` → `($status, $headers, $body)`.
    **Called only when a terminal body event was observed.**

**Why:** four middleware hand-rolled this pattern and all four got it wrong. The
helper makes the error unrepresentable: on an incomplete stream the `transform`
callback is never invoked, so no author can compute metadata over a partial body.

- [ ] **Step 1: Write the failing contract tests**

Create `t/middleware/buffered-response.t`:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Middleware::BufferedResponse qw(buffer_whole_response);

sub http_scope {
    return { type => 'http', method => 'GET', path => '/x', scheme => 'http',
             http_version => '1.1', headers => [] };
}

sub drive {
    my ($wrapped, $scope) = @_;
    my @sent;
    Future->wrap($wrapped->($scope // http_scope(), sub { Future->done },
        sub { push @sent, $_[0]; Future->done }))->get;
    return @sent;
}

subtest 'a complete response reaches transform and is rewritten' => sub {
    my $called = 0;
    my $app = sub {
        my ($s, $r, $send) = @_;
        return (async sub {
            await $send->({ type => 'http.response.start', status => 200,
                            headers => [['content-type', 'text/plain']] });
            await $send->({ type => 'http.response.body', body => 'hello',
                            more => 0 });
            return;
        })->();
    };

    my @sent = drive(buffer_whole_response($app,
        engage    => sub { 1 },
        transform => sub {
            my ($status, $headers, $body) = @_;
            $called++;
            push @$headers, ['X-Len', length $body];
            return ($status, $headers, uc $body);
        },
    ));

    is($called, 1, 'transform ran once');
    is(scalar(@sent), 2, 'start and one body event');
    is($sent[1]{body}, 'HELLO', 'transformed body is emitted');
    is($sent[1]{more}, 0, 'terminal event preserved');
    my ($len) = grep { $_->[0] eq 'X-Len' } @{ $sent[0]{headers} };
    is($len->[1], 5, 'header added by transform is present');
};

subtest 'an incomplete response never reaches transform' => sub {
    my $called = 0;
    my $app = sub {
        my ($s, $r, $send) = @_;
        return (async sub {
            await $send->({ type => 'http.response.start', status => 200,
                            headers => [['content-type', 'text/plain']] });
            return;   # no body event at all
        })->();
    };

    my @sent = drive(buffer_whole_response($app,
        engage    => sub { 1 },
        transform => sub { $called++; return @_ },
    ));

    is($called, 0, 'transform never ran -- metadata cannot be computed');
    is(scalar(@sent), 1, 'only the withheld start was emitted');
    is($sent[0]{type}, 'http.response.start', 'and it is the start');
    is(scalar(grep { $_->{type} eq 'http.response.body' } @sent), 0,
        'no body event is fabricated');
};

subtest 'a partial stream emits what arrived, with no terminal event' => sub {
    my $called = 0;
    my $app = sub {
        my ($s, $r, $send) = @_;
        return (async sub {
            await $send->({ type => 'http.response.start', status => 200,
                            headers => [] });
            await $send->({ type => 'http.response.body', body => 'part',
                            more => 1 });
            return;
        })->();
    };

    my @sent = drive(buffer_whole_response($app,
        engage    => sub { 1 },
        transform => sub { $called++; return @_ },
    ));

    is($called, 0, 'transform never ran');
    is(scalar(grep { $_->{type} eq 'http.response.body' && !$_->{more} } @sent), 0,
        'no terminal event is fabricated');
    is(scalar(grep { $_->{type} eq 'http.response.start' } @sent), 1,
        'the start still reaches the wire');
};

subtest 'an app that starts nothing produces nothing' => sub {
    my $app = sub { my ($s, $r, $send) = @_; return Future->done };
    my @sent = drive(buffer_whole_response($app,
        engage => sub { 1 }, transform => sub { return @_ }));
    is(scalar(@sent), 0, 'nothing withheld, nothing emitted');
};

subtest 'engage false passes everything through untouched' => sub {
    my $called = 0;
    my $app = sub {
        my ($s, $r, $send) = @_;
        return (async sub {
            await $send->({ type => 'http.response.start', status => 200,
                            headers => [] });
            await $send->({ type => 'http.response.body', body => 'x',
                            more => 0 });
            return;
        })->();
    };
    my @sent = drive(buffer_whole_response($app,
        engage => sub { 0 }, transform => sub { $called++; return @_ }));
    is($called, 0, 'transform never ran');
    is(scalar(@sent), 2, 'events passed through');
    is($sent[1]{body}, 'x', 'body untouched');
};

subtest 'non-http scopes are passed through' => sub {
    my $ran = 0;
    my $app = sub { my ($s, $r, $send) = @_; $ran++; return Future->done };
    my $wrapped = buffer_whole_response($app,
        engage => sub { 1 }, transform => sub { return @_ });
    Future->wrap($wrapped->({ type => 'websocket' }, sub { Future->done },
        sub { Future->done }))->get;
    is($ran, 1, 'inner app ran');
};

done_testing;
```

- [ ] **Step 2: Run and confirm it fails**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/middleware/buffered-response.t'`

Expected: FAIL — `Can't locate PAGI/Middleware/BufferedResponse.pm`.

- [ ] **Step 3: Implement the helper**

Create `lib/PAGI/Middleware/BufferedResponse.pm`:

```perl
package PAGI::Middleware::BufferedResponse;

use strict;
use warnings;
use Exporter qw(import);
use Carp qw(croak);
use Future;
use Future::AsyncAwait;
use PAGI::Middleware ();

our @EXPORT_OK = qw(buffer_whole_response);

sub buffer_whole_response {
    my ($app, %opts) = @_;
    croak 'buffer_whole_response requires a coderef app'
        unless ref($app) eq 'CODE';
    my $engage    = $opts{engage}    || sub { 1 };
    my $transform = $opts{transform} or croak 'transform is required';

    return async sub {
        my ($scope, $receive, $send) = @_;
        if (($scope->{type} // '') ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        my ($status, $headers);
        my @body_parts;
        my $engaged       = 0;
        my $passing       = 0;
        my $terminal_seen = 0;

        my $flush_as_stream = async sub {
            await $send->({ type    => 'http.response.start',
                            status  => $status,
                            headers => $headers // [] });
            for my $part (@body_parts) {
                await $send->({ type => 'http.response.body',
                                body => $part, more => 1 });
            }
            @body_parts = ();
            $passing = 1;
        };

        my $wrapped_send = async sub {
            my ($event) = @_;
            my $type = $event->{type} // '';

            if ($passing) { await $send->($event); return }

            if ($type eq 'http.response.start') {
                $status  = $event->{status};
                $headers = [ @{ $event->{headers} // [] } ];   # our copy
                $engaged = $engage->($status, $headers) ? 1 : 0;
                unless ($engaged) { $passing = 1; await $send->($event) }
                return;
            }

            if ($type eq 'http.response.body') {
                return unless defined $status;   # never invent a start

                # An opaque body has no string to transform. Flush what we
                # withheld as stream chunks and hand over.
                if (PAGI::Middleware::body_event_is_opaque($event)) {
                    await $flush_as_stream->();
                    await $send->($event);
                    return;
                }

                push @body_parts, $event->{body} // '';
                # `more` defaults to 0, so an omitted `more` is terminal.
                if ($event->{more}) {
                    await $flush_as_stream->();
                    return;
                }
                $terminal_seen = 1;
                return;
            }

            await $send->($event);
        };

        await $app->($scope, $receive, $wrapped_send);

        return if $passing;
        return unless defined $status;   # nothing withheld, nothing to emit

        # No terminal event: emit the head the application gave us and stop.
        # transform() is not called, so no author can compute completeness-
        # dependent metadata from a partial buffer. See PAGI::Spec::Www,
        # "Application Left a Response Incomplete".
        unless ($terminal_seen) {
            await $send->({ type    => 'http.response.start',
                            status  => $status,
                            headers => $headers // [] });
            for my $part (@body_parts) {
                await $send->({ type => 'http.response.body',
                                body => $part, more => 1 });
            }
            return;
        }

        my ($out_status, $out_headers, $out_body) =
            $transform->($status, $headers // [], join('', @body_parts));

        await $send->({ type    => 'http.response.start',
                        status  => $out_status,
                        headers => $out_headers // [] });
        await $send->({ type => 'http.response.body',
                        body => $out_body // '', more => 0 });
        return;
    };
}

1;

__END__

=head1 NAME

PAGI::Middleware::BufferedResponse - safe buffer-and-re-emit for middleware

=head1 SYNOPSIS

    use PAGI::Middleware::BufferedResponse qw(buffer_whole_response);

    sub wrap {
        my ($self, $app) = @_;
        return buffer_whole_response($app,
            engage    => sub { my ($status, $headers) = @_; $status == 200 },
            transform => sub {
                my ($status, $headers, $body) = @_;
                push @$headers, ['ETag', '"' . md5_hex($body) . '"'];
                return ($status, $headers, $body);
            },
        );
    }

=head1 DESCRIPTION

Middleware that computes a response header from the whole body -- an C<ETag>, a
C<Content-Length>, a digest -- must buffer the body before it can emit anything.
That pattern has one dangerous case: the event stream can end without its
terminal event, because the client disconnected or the application stopped
early. A middleware that synthesizes its header anyway asserts that the bytes it
happened to observe are the complete representation, which
L<PAGI::Spec::Www/"Application Left a Response Incomplete"> forbids to every
producer, not only to servers.

This helper owns that case. Your C<transform> callback runs B<only> when a
terminal body event was actually received, so a validator over a partial body is
not something you can accidentally write. When the stream ends early, the helper
emits the C<http.response.start> the application produced -- unmodified, with no
computed metadata -- and no terminal event. The response stays observably
incomplete, and outer observers still see that a response was started.

=head2 buffer_whole_response

    my $wrapped = buffer_whole_response($app, engage => \&engage, transform => \&transform);

=over

=item * C<engage> (optional, defaults to always true)

Called once with C<< ($status, $headers) >> when C<http.response.start> arrives.
Return false to pass this response through untouched.

=item * C<transform> (required)

Called with C<< ($status, $headers, $body) >> and must return the same triple.
Runs only for a response that reached its terminal body event.

=back

Responses that turn out to be streaming (a body event with C<< more => 1 >>) or
opaque (a C<file> or C<fh> body) are flushed and passed through; C<transform>
does not run for them, because there is no whole body to give it.

=cut
```

- [ ] **Step 4: Confirm green and gate**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/middleware/buffered-response.t'
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.16.3 && perl -Ilib -c lib/PAGI/Middleware/BufferedResponse.pm'
```

- [ ] **Step 5: Commit**

```bash
git add lib/PAGI/Middleware/BufferedResponse.pm t/middleware/buffered-response.t
git commit lib/PAGI/Middleware/BufferedResponse.pm t/middleware/buffered-response.t -m "feat: BufferedResponse makes partial-body metadata unrepresentable"
```

---

### Task 6: Migrate ETag onto the helper

**Files:**
- Modify: `lib/PAGI/Middleware/ETag.pm`
- Test: `t/middleware/etag.t` (existing; no new tests)

**Interfaces:**
- Consumes: `buffer_whole_response` from Task 5.
- Produces: nothing.

**Why:** ETag's `wrap` becomes a call to the helper. The hand-written guard from
Phase 1 Task 1 is deleted rather than maintained.

- [ ] **Step 1: Rewrite `wrap`**

Replace the whole body of `sub wrap` with:

```perl
sub wrap {
    my ($self, $app) = @_;

    return buffer_whole_response($app,
        engage => sub {
            my ($status, $headers) = @_;
            # An application that set its own ETag owns it.
            return 0 if grep { lc($_->[0]) eq 'etag' } @$headers;
            return 1;
        },
        transform => sub {
            my ($status, $headers, $body) = @_;
            push @$headers, ['ETag', $self->_generate_etag($body)];
            return ($status, $headers, $body);
        },
    );
}
```

Add `use PAGI::Middleware::BufferedResponse qw(buffer_whole_response);` at the
top and delete the now-unused lexicals and `$wrapped_send` closure.

- [ ] **Step 2: Confirm the existing suite still passes**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t/middleware/etag.t t/middleware/disconnect-laundering.t t/compose/ t/integration/'`

Expected: PASS, unchanged. These tests were written against the hand-rolled
implementation; passing them unmodified is the evidence the migration is
behaviour-preserving.

- [ ] **Step 3: 5.16 gate and commit**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.16.3 && perl -Ilib -c lib/PAGI/Middleware/ETag.pm'
git commit lib/PAGI/Middleware/ETag.pm -m "refactor: ETag uses the shared buffered-response helper"
```

---

### Task 7: Migrate ContentLength onto the helper

**Files:**
- Modify: `lib/PAGI/Middleware/ContentLength.pm`
- Test: `t/middleware/01-content-length.t` (existing)

**Interfaces:**
- Consumes: `buffer_whole_response` from Task 5.
- Produces: nothing.

**Why:** same migration. This one also fixes a latent bug: the current code does
`push @{$event->{headers}}, ['content-length', $body_length]`, mutating the
arrayref the **application** owns. The helper hands `transform` its own copy.

- [ ] **Step 1: Rewrite `wrap`**

```perl
sub wrap {
    my ($self, $app) = @_;

    return buffer_whole_response($app,
        engage => sub {
            my ($status, $headers) = @_;
            return 0 if $self->{auto_chunked};
            return 0 if grep { lc($_->[0]) eq 'content-length' } @$headers;
            return 1;
        },
        transform => sub {
            my ($status, $headers, $body) = @_;
            push @$headers, ['content-length', length $body];
            return ($status, $headers, $body);
        },
    );
}
```

Add the `use` line; delete the hand-rolled closure and lexicals.

- [ ] **Step 2: Confirm the existing suite still passes**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t/middleware/01-content-length.t t/compose/ t/integration/'`

- [ ] **Step 3: 5.16 gate and commit**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.16.3 && perl -Ilib -c lib/PAGI/Middleware/ContentLength.pm'
git commit lib/PAGI/Middleware/ContentLength.pm -m "refactor: ContentLength uses the shared helper and stops mutating app headers"
```

---

### Task 8: Streaming compression for GZip

**Files:**
- Modify: `lib/PAGI/Middleware/GZip.pm`
- Modify: `lib/PAGI/Middleware/BufferedResponse.pm` (add the second helper)
- Test: `t/middleware/07-compression.t`

**Interfaces:**
- Consumes: nothing from Task 5 — this is the other helper.
- Produces:
  `stream_transform_response($app, begin => \&code)`.
  - `begin->($status, $headers)` is called **once per response**, on
    `http.response.start`. It may mutate `$headers` in place. It returns either
    `undef` (pass this response through untransformed) or a hashref
    `{ chunk => sub { $bytes }, finish => sub { } }` holding that response's
    transformer. The possibly-modified headers are emitted immediately.

  **`begin` is a per-response factory, not a pair of shared callbacks.** A
  streaming compressor holds mutable zlib state, and `wrap` runs once while
  requests are concurrent — callbacks created at wrap time would share one
  deflate stream across every in-flight response and corrupt all of them.
  Returning the pair from `begin` gives each response its own closure.

**Why — and this is a deliberate behaviour change.** GZip currently
**abandons compression entirely** for streaming responses: `GZip.pm:136-149`
switches to pass-through on the first `more => 1` chunk and forwards every chunk
uncompressed, without `Content-Encoding`. So the responses that benefit most from
compression — large streaming exports — are the ones never compressed. Gzip is an
incremental format; `Compress::Raw::Zlib` deflates chunk by chunk. Plack's
`Deflater` has always streamed compressed output and dropped `Content-Length`.

Moving GZip to the streaming helper also removes its exposure to this plan's bug
class **by construction**: it never withholds the head, so it has nothing to
swallow and nothing to fabricate.

**Observable consequences to document:** streaming responses now arrive
compressed, and `Content-Length` is absent from them (the compressed size is not
known in advance), so they are chunked. This is what `Deflater` does and what
HTTP/1.1 chunked framing exists for.

- [ ] **Step 1: Write the failing test**

Add to `t/middleware/07-compression.t`:

```perl
subtest 'a streaming response is compressed incrementally' => sub {
    my @events;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200,
                        headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body',
                        body => 'A' x 2000, more => 1 });
        await $send->({ type => 'http.response.body',
                        body => 'B' x 2000, more => 0 });
    };

    my $scope = make_scope(headers => [['Accept-Encoding', 'gzip']]);
    my $wrapped = PAGI::Middleware::GZip->new->wrap($app);
    run_async { $wrapped->($scope,
        (async sub { { type => 'http.request', body => '', more => 0 } }),
        (async sub { push @events, $_[0] })) };

    my ($start) = grep { $_->{type} eq 'http.response.start' } @events;
    my @enc = grep { lc($_->[0]) eq 'content-encoding' } @{ $start->{headers} };
    is(scalar(@enc), 1, 'Content-Encoding is set on a streaming response');
    is($enc[0][1], 'gzip', 'and it is gzip');
    is(scalar(grep { lc($_->[0]) eq 'content-length' } @{ $start->{headers} }), 0,
        'no Content-Length -- the compressed size is not known in advance');

    my $compressed = join '', map { $_->{body} // '' }
                     grep { $_->{type} eq 'http.response.body' } @events;
    require IO::Uncompress::Gunzip;
    my $plain = '';
    IO::Uncompress::Gunzip::gunzip(\$compressed => \$plain)
        or die "gunzip failed: $IO::Uncompress::Gunzip::GunzipError";
    is($plain, ('A' x 2000) . ('B' x 2000),
        'the stream round-trips to the original bytes');
    ok(length($compressed) < 4000, 'and it was actually compressed');
};
```

- [ ] **Step 2: Run and confirm it fails**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/middleware/07-compression.t'`

Expected: FAIL on the first assertion — no `Content-Encoding` is set today,
because the streaming path abandons compression.

- [ ] **Step 3: Add `stream_transform_response` to the helper module**

Append to `lib/PAGI/Middleware/BufferedResponse.pm`, adding it to
`@EXPORT_OK`:

```perl
sub stream_transform_response {
    my ($app, %opts) = @_;
    croak 'stream_transform_response requires a coderef app'
        unless ref($app) eq 'CODE';
    my $begin = $opts{begin} or croak 'begin is required';

    return async sub {
        my ($scope, $receive, $send) = @_;
        if (($scope->{type} // '') ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Per-response, so concurrent requests never share transformer state.
        my $xform;

        my $wrapped_send = async sub {
            my ($event) = @_;
            my $type = $event->{type} // '';

            if ($type eq 'http.response.start') {
                my $headers = [ @{ $event->{headers} // [] } ];
                $xform = $begin->($event->{status}, $headers);
                await $send->({ type    => 'http.response.start',
                                status  => $event->{status},
                                headers => $headers });
                return;
            }

            if ($type eq 'http.response.body' && $xform) {
                # An opaque body cannot be transformed in flight. Hand it over
                # untouched and stop transforming this response.
                if (PAGI::Middleware::body_event_is_opaque($event)) {
                    $xform = undef;
                    await $send->($event);
                    return;
                }
                my $out = $xform->{chunk}->($event->{body} // '');
                # `more` defaults to 0; an omitted `more` is terminal.
                if ($event->{more}) {
                    await $send->({ type => 'http.response.body',
                                    body => $out, more => 1 })
                        if length $out;
                    return;
                }
                $out .= $xform->{finish}->();
                $xform = undef;
                await $send->({ type => 'http.response.body',
                                body => $out, more => 0 });
                return;
            }

            await $send->($event);
        };

        await $app->($scope, $receive, $wrapped_send);
        return;
    };
}
```

Note this helper never withholds the head, so an application that stops early
simply stops: there is nothing buffered to swallow and nothing to fabricate.
That is why GZip leaves this plan's bug class entirely rather than being guarded
against it.

Note this helper never withholds the head, so an application that stops early
simply stops: there is nothing buffered to swallow and nothing to fabricate.

- [ ] **Step 4: Rewrite GZip's `wrap`**

Add at the top of `GZip.pm`:

```perl
use PAGI::Middleware::BufferedResponse qw(stream_transform_response);
use Compress::Raw::Zlib qw(WANT_GZIP Z_OK Z_SYNC_FLUSH Z_FINISH);
```

Then replace `wrap`. `$scope` is needed for the `Accept-Encoding` check, so the
per-request scope is captured by wrapping the helper rather than by reaching for
shared state:

```perl
sub wrap {
    my ($self, $app) = @_;

    my $inner = stream_transform_response($app, begin => sub {
        my ($status, $headers) = @_;

        return undef if grep { lc($_->[0]) eq 'content-encoding' } @$headers;
        my ($ct) = map { $_->[1] }
                   grep { lc($_->[0]) eq 'content-type' } @$headers;
        return undef unless $self->_type_is_compressible($ct // '');

        my ($d, $err) = Compress::Raw::Zlib::Deflate->new(
            WindowBits   => WANT_GZIP,
            AppendOutput => 1,
        );
        return undef unless $d && $err == Z_OK;

        # The compressed length is not known in advance, so the response is
        # chunked and carries no Content-Length.
        @$headers = grep { lc($_->[0]) ne 'content-length' } @$headers;
        push @$headers, ['Content-Encoding', 'gzip'], ['Vary', 'Accept-Encoding'];

        return {
            chunk => sub {
                my ($bytes) = @_;
                my $out = '';
                $d->deflate($bytes, $out);
                # Z_SYNC_FLUSH makes each chunk independently deliverable,
                # which is the point of streaming compression.
                $d->flush($out, Z_SYNC_FLUSH);
                return $out;
            },
            finish => sub {
                my $out = '';
                $d->flush($out, Z_FINISH);
                return $out;
            },
        };
    });

    # Accept-Encoding lives on the request, so gate on the scope out here;
    # begin() only sees the response.
    return async sub {
        my ($scope, $receive, $send) = @_;
        if (($scope->{type} // '') ne 'http'
            || !$self->_client_accepts_gzip($scope)) {
            await $app->($scope, $receive, $send);
            return;
        }
        await $inner->($scope, $receive, $send);
        return;
    };
}
```

`_client_accepts_gzip($scope)` and `_type_is_compressible($content_type)`
replace the existing `_should_compress($content_type, $size)`, whose size
argument no longer exists — a streaming compressor cannot know the body size
before compressing it. Lift the existing `Accept-Encoding` parsing and the
`mime_types` match out of `_should_compress` into the two new methods
unchanged; only the size test is dropped.

**`min_size` is removed.** Document it as ignored: a streaming compressor cannot
know the body size before compressing. Note this in the POD and in `Changes`.

- [ ] **Step 5: Confirm green**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t/middleware/ t/compose/ t/integration/'`

Expected: PASS. Existing non-streaming compression subtests must still pass —
they exercise the same deflate path with a single chunk.

- [ ] **Step 6: Declare the new dependency**

`GZip.pm` currently uses the one-shot `IO::Compress::Gzip`, declared at
`cpanfile:22`. The streaming path uses `Compress::Raw::Zlib` directly. It ships
in the same distribution as `IO::Compress::Gzip`, so nothing new is installed —
but a directly-used module gets a direct declaration. Add beside the existing
line:

```perl
requires 'Compress::Raw::Zlib';
```

If `IO::Compress::Gzip` is no longer used anywhere after the rewrite
(`grep -rn 'IO::Compress::Gzip' lib/`), remove its `requires` line too. The
new test uses `IO::Uncompress::Gunzip`; add it under `on 'test' => sub { ... }`
if that block exists, otherwise beside the others with a comment that it is
test-only.

- [ ] **Step 7: Document the behaviour change and commit**

Three places:

1. **GZip's POD** — streaming responses are now compressed; they carry no
   `Content-Length` and are chunked; `min_size` no longer applies and is
   ignored.
2. **`BufferedResponse`'s POD** — add a `stream_transform_response` section
   beside `buffer_whole_response`, including the reason `begin` is a
   per-response factory (shared transformer state would corrupt concurrent
   responses).
3. **`Changes`**, under the current UNRELEASED entry.

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -MPod::Checker -e "my \$c = Pod::Checker->new(); \$c->parse_from_file(q{lib/PAGI/Middleware/BufferedResponse.pm}, \\*STDERR); printf qq{errors=%d warnings=%d\n}, \$c->num_errors, \$c->num_warnings;"'
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.16.3 && perl -Ilib -c lib/PAGI/Middleware/GZip.pm'
git commit lib/PAGI/Middleware/GZip.pm lib/PAGI/Middleware/BufferedResponse.pm t/middleware/07-compression.t cpanfile Changes -m "feat: GZip compresses streaming responses incrementally"
```

---

### Task 9: Close out

**Files:**
- Modify: `Changes`
- Modify: `.pagi-open-issues.md` (never staged — working notes)

**Interfaces:**
- Consumes: Tasks 1-8.
- Produces: nothing.

- [ ] **Step 1: Full suite**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr -j4 t/' > "$SCRATCH/full-suite.txt" 2>&1; echo "prove exit=$?"`

Read the file in full with the Read tool. Expected: PASS, pristine.

- [ ] **Step 2: Reopen and re-close the ledger items**

F1-F4 in `.pagi-open-issues.md` are currently marked fixed. Their fixes covered
only the disconnect half; the connected-client half shipped broken. Record that,
then close them against this plan's commits. Do **not** `git add` this file.

- [ ] **Step 3: Write the Changes entry and commit**

```bash
git status                      # confirm .pagi-open-issues.md is NOT staged
git commit Changes -m "docs: record the buffering-contract fixes"
```

---

## Notes for the executor

- **Do not modify `Debug.pm`.** It is dev-only, was copied from Plack as a
  curiosity, is a deprecation candidate, and its hand-rolled flush is already
  correct. It is deliberately outside this plan.
- **`for my $x (...)`, never `for (...)`** when the loop body contains `await` —
  a `foreach` over the non-lexical `$_` is a compile error under
  `Future::AsyncAwait`.
- **If a middleware resists the helper**, stop and report rather than widening
  the helper's interface to accommodate one caller. Three callers with one shape
  is the point; a helper with four optional hooks is the pattern this plan
  exists to remove.
