# Session mutation silently dropped by Store::Cookie — design spec

**Date:** 2026-07-13
**Status:** Draft for spec-owner (John) review — no code changes made
**Background:** `~/Desktop/Valiant-Project/Parley/docs/nano-gaps.md` lines 205-238 (field repro from Parley phase-3 signup work)
**Repo:** PAGI-Tools (`lib/PAGI/Middleware/Session.pm` et al.), version 0.002001
**Related dist (read-only for this spec):** PAGI-Middleware-Session-Store-Cookie 0.001004

## 1. Intended semantics

**The rule this spec proposes:** the session middleware must emit transport
(response headers carrying the session ID/data) on a response whenever the
session's persisted representation could have changed relative to what the
client currently holds — i.e. when the session is **new**, **regenerated**,
or its **data differs from what was loaded at the start of the request**. It
must emit nothing extra on a pure-read request.

This amends the task's working hypothesis ("inject when new OR regenerated
OR dirty") in one respect: "dirty" should be defined as *data changed since
load*, not *a mutator method was called*. Section 3 defends this amendment
— a method-based dirty flag provably misses two supported, tested mutation
paths.

### Why the two store families need different things

- **Server-side stores** (`Store::Memory`, and by extension any future
  Redis/DB store): the transport is the session **ID**, which does not
  change when the data changes. Re-emitting it on every dirty response is
  not required for correctness — the server already has the current data
  under that ID — but it **does** refresh the cookie's `Max-Age` on the
  client, giving mutated sessions a sliding expiry window on activity. That
  is a desirable side effect, not a regression (see §3, "server-side store
  impact").
- **`Store::Cookie`**: the transport **is** the data (base64 of AES-256-GCM
  ciphertext of the whole session hash — `Store/Cookie.pm:98-103`, `119-134`
  in the sibling dist). There is no server-side copy. If the middleware
  computes a fresh transport via `_save_session` but never hands it to
  `state->inject`, that computation is thrown away and the client is left
  holding a stale, now-incorrect blob. For this store family, re-injecting
  on every dirty response is **required for correctness**, not an
  optimization.

One rule — inject when `new || regenerated || dirty` — satisfies both
families: it's a no-op-ish refresh for server-side stores and a correctness
requirement for `Store::Cookie`. No per-store special-casing is needed in
`PAGI::Middleware::Session::wrap`.

### Reserved-key mutator surface (from `lib/PAGI/Session.pm`)

| Method | Effect | Reserved-key writes |
|---|---|---|
| `set($k,$v,...)` (`Session.pm:178-185`) | writes `_data->{$k}` | none |
| `delete(@keys)` (`Session.pm:211-215`) | deletes keys from `_data` | none |
| `clear` (`Session.pm:257-262`) | deletes all non-`_`-prefixed keys | none |
| `regenerate` (`Session.pm:277-280`) | sets `_data->{_regenerated}=1` | `_regenerated` |
| `destroy` (`Session.pm:292-295`) | sets `_data->{_destroyed}=1` | `_destroyed` |
| `data` (`Session.pm:130-133`) | **returns the live `_data` hashref** — any caller can mutate it directly (`$session->data->{x}=1`) | none, and **untracked by any mutator hook** |

`data()` is not a theoretical hole: `t/middleware/session/helper.t:385`
has a passing test, `'data mutations visible through get/set'`, that
exercises exactly `$session->data->{color} = 'blue'` as supported API.
Additionally,
`PAGI::Middleware::Session`'s own POD SYNOPSIS (`Session.pm:42-44`) shows
raw scope mutation — `$session->{user_id} = 123` directly on
`$scope->{'pagi.session'}` — as the *first*, primary usage example, ahead of
the `PAGI::Session` helper. Both paths write into the same shared hashref
that `PAGI::Session` wraps (`_data => $scope->{'pagi.session'}`,
`Session.pm:88/93`), so a dirty flag that only lives inside `set`/`delete`/
`clear` would never see either of them fire.

## 2. Root cause

`PAGI::Middleware::Session::wrap`'s response wrapper
(`lib/PAGI/Middleware/Session.pm:308-340`) has three branches on the normal
(non-idempotent-skip) path, keyed off two flags stored in the session
hashref:

- `_destroyed` (lines 313-317): deletes from the store, calls
  `$self->{state}->clear`. Unconditional emission (a clearing Set-Cookie).
- `_regenerated` (lines 318-327): generates a new ID, deletes the old store
  entry, saves under the new ID, and calls `$self->{state}->inject`
  **unconditionally**.
- else — the "normal" branch (lines 328-334):
  ```perl
  else {
      # Normal: save and inject if new
      my $transport = await $self->_save_session($session_id, $session);
      if ($is_new) {
          $self->{state}->inject(\@headers, $transport, {});
      }
  }
  ```
  `_save_session` (delegating to `$self->{store}->set`, `Session.pm:385-388`)
  runs on **every** request that reaches this branch, computing a fresh
  transport. `inject` — the only call that pushes a transport-carrying
  header onto `\@headers` for `State::Cookie` (`Set-Cookie`,
  `State/Cookie.pm:96-101`) — only runs `if ($is_new)`. `$is_new` is `0` for
  every request against an already-established session
  (`_load_or_create_session`, `Session.pm:346-369`, returns `($session, 0)`
  on the existing-session path at line 356, and `($session, 1)` only for a
  freshly created one at line 368).

  Confirmed against `Store::Cookie` (`PAGI-Middleware-Session-Store-Cookie/lib/PAGI/Middleware/Session/Store/Cookie.pm`):
  `set` (lines 98-103) always returns a **freshly encrypted blob** —
  `_encrypt` (lines 119-134) draws a new random 12-byte IV via
  `Crypt::PRNG::random_bytes` every call, so the returned transport differs
  from the previous one even when the underlying data is byte-identical.
  Because nothing server-side retains this blob (`delete` at lines 114-117
  is a no-op — "client manages cookie lifetime"), the freshly computed,
  correct blob at `Session.pm:330` is the *only* copy of the session's
  current state, and it is discarded whenever `$is_new` is false. The
  client's cookie is permanently pinned to whatever blob was issued at
  session creation.

  This matches the field repro in `nano-gaps.md:205-238` exactly: a
  `PAGI::Session->set(...)` call (`$c->session->set('user_id', ...)`, which
  is `Session.pm:178`) against an existing `Store::Cookie` session produced
  no `Set-Cookie` on the response, and the next request's `get('user_id')`
  died per `Session.pm:147-164`'s strict-missing-key behavior. `regenerate`
  (`nano-gaps.md:227`) worked around it because it lands in the
  unconditional-inject `elsif` branch, not because the underlying "normal"
  bug was fixed.

  **One correction to the task's summary:** the nano-gaps entry's own
  suggested upstream fix ("inject unconditionally whenever the store
  returns a transport that differs from what was read, not only when the
  session is new," `nano-gaps.md:235-237`) does not work as literally
  stated. Because `Store::Cookie::set` re-encrypts with a fresh random IV
  every call, the returned transport differs from the previous one on
  **every** request, mutated or not — comparing transports would inject on
  every single response, including pure reads, defeating the purpose. The
  comparison needs to happen at the **data** level (before encryption), not
  the **transport** level (after it) — see §3.

## 3. Proposed fix

### Chosen mechanism: compare session data at load vs. at save, not a mutator-set flag

Given §1's finding that `data()` and raw scope mutation are supported,
tested access patterns that bypass any hook placed inside `set`/`delete`/
`clear`, a flag toggled only by those three methods would leave the exact
bug open for `$session->data->{x} = 1` or `$scope->{'pagi.session'}{x} = 1`.
The proposed fix instead snapshots the loaded session's data and diffs it
against the current data immediately before saving. This is mutation-path
agnostic — it does not matter *how* the hash changed.

`JSON::MaybeXS` is already a hard dependency (`cpanfile:14`), so no new
dependency is introduced. Canonical mode is required for a stable diff —
verified empirically: `JSON::MaybeXS->new(canonical=>1)->encode(...)`
produces key-order-independent output; the bare `encode_json()` convenience
function does not (it preserves hash iteration order and is unsuitable for
this comparison).

**`lib/PAGI/Middleware/Session.pm`:**

```diff
@@ -1,6 +1,7 @@
 package PAGI::Middleware::Session;
 
 use strict;
 use warnings;
 use parent 'PAGI::Middleware';
 use Future::AsyncAwait;
 use Digest::SHA qw(sha256_hex);
+use JSON::MaybeXS;
 use PAGI::Utils::Random qw(secure_random_bytes);
@@ -244,6 +245,7 @@ sub _init {
     $self->{secret} = $config->{secret}
         // die "Session middleware requires 'secret' option";
     $self->{expire} = $config->{expire} // 3600;
+    $self->{_json}  = JSON::MaybeXS->new(canonical => 1);
 
     # State: pluggable session ID transport
@@ -294,7 +296,7 @@ sub wrap {
         my $session_id = $self->{state}->extract($scope);
 
         # Validate and load session
-        my ($session, $is_new) = await $self->_load_or_create_session($session_id);
+        my ($session, $is_new, $snapshot) = await $self->_load_or_create_session($session_id);
         $session_id = $session->{_id};
 
         # Add session to scope
@@ -318,15 +320,18 @@ sub wrap {
                 elsif ($session->{_regenerated}) {
                     # Regenerate: new ID, delete old, save under new
                     my $old_id = $session_id;
                     $session_id = $self->_generate_session_id();
                     $session->{_id} = $session_id;
                     delete $session->{_regenerated};
                     await $self->{store}->delete($old_id);
                     my $transport = await $self->_save_session($session_id, $session);
                     $self->{state}->inject(\@headers, $transport, {});
                 }
                 else {
-                    # Normal: save and inject if new
+                    # Normal: save always; inject if new or the session's
+                    # data changed since it was loaded (the transport for
+                    # cookie-backed stores IS the data, so a stale client
+                    # copy after mutation is a correctness bug, not just
+                    # a missed refresh).
+                    my $dirty = $is_new
+                        || !defined($snapshot)
+                        || $self->{_json}->encode($session) ne $snapshot;
                     my $transport = await $self->_save_session($session_id, $session);
-                    if ($is_new) {
+                    if ($dirty) {
                         $self->{state}->inject(\@headers, $transport, {});
                     }
                 }
@@ -352,10 +357,11 @@ async sub _load_or_create_session {
     if (defined $session_id && length $session_id) {
         my $session = await $self->_get_session($session_id);
         if ($session && !$self->_is_expired($session)) {
             $session->{_last_access} = time();
-            return ($session, 0);
+            return ($session, 0, $self->{_json}->encode($session));
         }
     }
 
     # Create new session
     $session_id = $self->_generate_session_id();
     my $session = {
         _id          => $session_id,
         _created     => time(),
         _last_access => time(),
     };
 
-    return ($session, 1);
+    return ($session, 1, undef);
 }
```

Notes on the diff:

- The snapshot is taken **after** `_last_access` is bumped
  (`Session.pm:355`), so an unmodified request's pre/post encode is
  identical — `_last_access` doesn't itself manufacture a false "dirty".
- `$dirty` is computed from `$session` **before** `_save_session` mutates
  anything transport-related (it doesn't mutate `$session` itself, only
  reads it), so ordering of the two lines doesn't matter for correctness;
  kept in the shown order to match the diff context.
- No new reserved key is introduced (unlike a flag-based design, there is
  nothing to `delete` from `$session` before saving — the snapshot lives in
  a lexical, never touches the hash).

### Answers to the specific questions posed

- **Does `delete`/`clear` mark dirty?** Not via a flag — under this design
  they don't need to. Both mutate `_data` in place, which the load/save
  snapshot diff will catch regardless.
- **Does a `regenerate` after mutations double-inject?** No. The `elsif
  ($session->{_regenerated})` branch (lines 318-327) is mutually exclusive
  with the `else` branch — only one runs per response — and it already
  injects unconditionally, so any pending data mutations are carried by the
  same single `_save_session`/`inject` pair. Unchanged by this fix.
- **Does the fix change behavior for server-side stores?** Yes, for
  `Store::Memory` (and future server-side stores): a mutated-but-not-new
  session now also gets a `Set-Cookie` refresh. This is desirable — today,
  even for the in-memory store, an existing session's cookie `Max-Age` is
  fixed at creation time and never slides forward on activity unless the
  app calls `regenerate`. The fix incidentally restores sliding-expiry
  behavior on mutation for server-side stores too. It does **not** change
  behavior for pure-read requests against server-side stores — no new
  header is emitted when `$dirty` is false.
- **Read-only requests emit nothing new:** confirmed by construction —
  `$dirty` is false whenever the canonical JSON of `$session` at save time
  equals the canonical JSON captured at load time, which holds for any
  request that performs no mutation through any path (accessor, raw
  hashref, or `data()`).
- **Backward compatibility:** grepped all six files under
  `t/middleware/session/` (`helper.t`, `middleware-integration.t`,
  `state-callback.t`, `state-cookie.t`, `state-header.t`,
  `store-memory.t`). None assert that mutating an *existing* session
  suppresses `Set-Cookie`. The two tests that check "no Set-Cookie" are:
  `middleware-integration.t`'s `'header state does not set cookies'`
  (asserts on a session that is also new — `State::Header::inject` is
  itself a no-op regardless of `$dirty`, `Header.pm` `sub inject { ...
  return; }`, so this holds unconditionally, not because of `$is_new`) and
  `'idempotency: skips if session already in scope'` (returns before
  `wrap`'s branch logic runs at all — the idempotency short-circuit at
  `Session.pm:287-292` fires first). Neither depends on the buggy
  not-dirty-not-new suppression this spec removes.

### Rejected alternative (documented per task instructions)

A dirty flag set inside `PAGI::Session::set`/`delete`/`clear` (writing
e.g. `_data->{_dirty}=1`, consulted and `delete`d in `wrap`'s normal
branch) was considered — it's cheaper (no JSON encode/decode per request)
and closer to the task's original working hypothesis. It is rejected as the
primary mechanism because it does not fire for `$session->data->{x}=1`
(tested, supported — `helper.t`, `'data mutations visible through
get/set'`) or `$scope->{'pagi.session'}{x}=1` (documented as the primary
usage pattern in `Session.pm`'s own SYNOPSIS, lines 42-44). Shipping it
would fix the exact reported symptom while leaving an equally-reachable
variant of the same bug in place for the framework's own headline example.
If John wants the cheaper mechanism anyway (e.g. because session payloads
are large enough that a per-request JSON round-trip is a real cost), the
right pairing is: keep the mutator-based flag **and** update
`PAGI::Middleware::Session`/`PAGI::Session` POD to state plainly that
direct hashref/`data()` mutation is not observed by `Store::Cookie` and
must go through `set`/`delete`/`clear` — turning the gap into a documented
constraint instead of a silent one. This is flagged as an open question
below rather than decided unilaterally.

## 4. Test plan

New tests, target file `t/middleware/session/middleware-integration.t`
(existing subtests in that file already cover the create/regenerate/destroy
shapes this extends):

- `'mutating an existing session emits a fresh Set-Cookie carrying the new data'`
  — using `Store::Memory` + default `State::Cookie` (round-trip is
  observable without needing the separate Store::Cookie dist): request 1
  creates a session and sets `counter => 1`; request 2, using the cookie
  from request 1, calls `$scope->{'pagi.session'}{counter} = 2` (or
  `PAGI::Session->new($scope)->set(counter => 2)` — cover both call
  shapes since they're the two the fix is meant to unify); assert a
  `Set-Cookie` header is present on request 2's response even though
  `$is_new` is false; request 3, using the cookie captured from request
  2's `Set-Cookie`, asserts `counter == 2` was restored.
- `'mutating via $session->data directly is also observed'` — same shape,
  mutating through `PAGI::Session->new($scope)->data->{counter} = 2`
  instead of `->set`, to pin down that the fix is not mutator-specific.
  This is the test that would fail under the rejected flag-based
  alternative in §3 and must be included regardless of which mechanism
  John picks, to make the choice's coverage explicit.
- `'pure read request emits no new Set-Cookie'` — request 1 creates a
  session; request 2 reuses the cookie and performs no mutation; assert
  zero `Set-Cookie` headers on request 2's response (tightening the
  existing implicit assumption, not currently asserted anywhere for the
  *existing*-session case — today's tests only assert the *new*-session
  case gets a cookie and the *header-state* case gets none).
- `'regenerate after mutation emits exactly one Set-Cookie'` — extend the
  existing `'regenerate creates new session ID and deletes old'` subtest
  (`middleware-integration.t:277-332`) with an assertion that
  `scalar(@set_cookies) == 1` (currently only checked truthy at line 310),
  to lock in "no double-inject."
- `'expired-then-reloaded session with no snapshot is treated as new for dirty purposes'`
  — an edge case worth one assertion: if `_is_expired` is true,
  `_load_or_create_session` falls through to the create-new path
  (`Session.pm:352-368`) regardless of what was in the store, so
  `$snapshot` is `undef` and `$is_new` is `1` — confirm this still injects
  (guards the `!defined($snapshot)` branch of the `$dirty` computation
  against ever being reached with `$is_new` false, which would be a bug in
  the diff itself, not existing behavior).

`Store::Cookie`-specific regression test (separate dist — see §5): add to
`PAGI-Middleware-Session-Store-Cookie/t/store-cookie.t`, a test wiring the
real `PAGI::Middleware::Session` (not just the store in isolation) with
`Store::Cookie` as the store, reproducing the exact Parley failure mode:
create a session, mutate it on a second request without regenerating,
assert the second response's `Set-Cookie` decrypts (via the store's own
`get`) to the mutated data. This is the test that would have caught the
original field bug directly against the store this spec is fixing the
symptom for.

## 5. Store::Cookie dist impact

None required. The fix is entirely contained in
`PAGI::Middleware::Session::wrap`/`_load_or_create_session` in PAGI-Tools.
`PAGI::Middleware::Session::Store::Cookie` already implements its documented
contract correctly (`set` returns the current encrypted blob for whatever
data it's given — `Store/Cookie.pm:88-96`); the bug is entirely that the
middleware discards a correctly-computed transport. The only PAGI-Tools ↔
Store::Cookie coupling is the new regression test recommended in §4, which
lives in the Store::Cookie dist's own test suite because it's the dist best
positioned to assert "this store family requires inject-on-dirty" against
its own store implementation, but it exercises unmodified PAGI-Tools code.

## Open questions for John

1. **Mechanism:** snapshot/JSON-diff (this spec's recommendation — correct
   for all three mutation paths, small added per-request cost) vs.
   mutator-set dirty flag (cheaper, but requires accepting and documenting
   that `data()`/raw-hashref mutation won't be observed for `Store::Cookie`
   — see §3 "Rejected alternative"). If the flag is preferred for
   performance reasons, should `data()` be changed (e.g. to warn, or to
   return a tied hashref that can set the flag) rather than just
   documented as a caveat?
2. **Sliding expiry for server-side stores on pure reads:** this fix only
   refreshes the cookie's `Max-Age` on *dirty* responses. A true
   activity-based sliding session window (refresh on every read too) is a
   related but separate enhancement — confirm it's out of scope here.
3. Confirm the `t/middleware/session/middleware-integration.t` file is the
   right home for the new PAGI-Tools-side tests (matches existing
   convention in that file) rather than a new file.
