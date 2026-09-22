# WebSocket Refusal Close Metadata Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking. The choice of execution mode belongs to the user; this document does not start implementation.

**Goal:** Report `1006` / `undef` through connection close accessors before announcing successful completion of a WebSocket HTTP refusal, in Server and the Tools test double.

**Architecture:** Populate the existing terminal metadata at the existing completion boundary. Server owns the real connection outcome; Tools' simulated server reproduces it, and the production WebSocket helper continues to read it without a fallback. HTTP refusal delivery remains successful scope completion.

**Tech Stack:** Perl, Future / Future::AsyncAwait, IO::Async, Test2::V0 / Test::More, PAGI-Server's existing HTTP/1.1 and HTTP/2 test harnesses.

**Spec:** [WebSocket refusal close metadata design](../specs/2026-09-22-websocket-refusal-close-metadata-design.md). Read both documents before execution.

## Global constraints

- No PAGI specification change is required.
- No new public API, scope flag, timer, callback scheduling policy, or transport-completion boundary.
- No fallback in production `PAGI::WebSocket`; no changes to `deny`/`decline` argument shapes.
- Populate metadata before terminal publication; preserve the first terminal record and any received peer Close metadata.
- HTTP and SSE close accessors remain `undef`.
- No server dependency or server-startup test is added to the Tools distribution. Real transport tests stay in Server.
- No browser automation. No assertions against particular timeout values or server-private state in Tools tests.
- An HTTP/2 skip is not evidence that HTTP/2 works.
- Preserve existing unrelated work. No push, merge, release, or deployment is part of this plan.

## Work map and preflight

All paths are under `/Users/jnapiorkowski/Desktop/PAGI-Project/`. No ticket was supplied; identify this work by the design filename.

| Repository | Observed branch / base | Execution ownership | Publication boundary / push target |
| --- | --- | --- | --- |
| `PAGI-Tools` | `feature/universal-connection-tools`, HEAD `a068bffb815ebbcaff8cca8b2a892507c92397f5`; main merge-base `c4c007f7a0603c2e36cd88266f2289db4f3baa12` | Stay on the current working branch; Task 2 only | Tools distribution; no push |
| `PAGI-Server` | Clean `main`, HEAD `59c40cf78906b48f1a9a0482fd1d810053e302cd` | Task 1; proposed isolated branch `fix/websocket-refusal-close-metadata` based on that main commit | Server distribution; no push |
| `PAGI` | `main`, HEAD `9aebdbcd938f4ff520d68ce2ea2e86cd00cf150f` | Read-only contract reference | No changes |

- [x] Record `git status --short`, branch, and HEAD in each repository before implementation. Reconfirm or update this map if the baseline has moved. Do not use the old closing-handshake worktree as the assumed server baseline.
- [x] For Server execution, follow the worktree skill and record the actual checkout path. Server is outside this session's writable roots; use the normal filesystem approval mechanism if executing from this session. This is not authorization to change the protocol repo.
- [x] Record the initial Tools diff so earlier HTTP TestClient fixes, docs, and other branch work remain distinguishable. Do not reset, stash, or sweep them into this change's commits.
- [x] Use the existing Perl environments: `perl-5.40.0@default` for Tools and `perl-5.42.2@default` for Server. The latter already has `Net::HTTP2::nghttp2` 0.011 installed. Check HTTP/2 availability in the Server execution checkout:

```sh
perlbrew exec --with perl-5.42.2@default perl -Ilib -MPAGI::Server::Protocol::HTTP2 -e 'die "HTTP/2 unavailable\n" unless PAGI::Server::Protocol::HTTP2->available; print "HTTP/2 available\n"'
```

If unavailable, arrange an environment with the server-required `Net::HTTP2::nghttp2` 0.011+ and native prerequisites. Do not weaken the regression or silently accept its skip. Independent Tools work may proceed while this is resolved.

## File responsibilities

| Repository / file | Planned change |
| --- | --- |
| Server `lib/PAGI/Server/Connection.pm` | Set metadata before existing h1/h2 refusal completion |
| Server `t/83-ws-close-code.t` | HTTP/1.1 refusal metadata and observer-order regressions |
| Server `t/http2/48-ws-close-code.t` | HTTP/2 refusal metadata and observer-order regressions |
| Server `t/71-http-refusal-on-protocol-scopes.t` | Extend existing streaming/trailer/interruption coverage only where the new tests do not already cover it |
| Tools `lib/PAGI/Test/ConnectionState.pm` | Normalize missing WebSocket terminal code before clean publication |
| Tools `t/test/client-ws-lifecycle.t` | Public TestClient + production helper refusal regression |
| Tools `t/test/connection-state.t` | Focused terminal immutability and non-WebSocket controls |
| Tools `t/websocket/deny-close-code.t` | Replace the contrary `undef` expectation and comment |
| Tools `t/websocket/15-connection-cleanup.t` | Remove the refusal fixture's manual insertion of `1006`; keep useful projection coverage |
| Tools `lib/PAGI/WebSocket.pm` | POD only: refusal lifecycle explanation and accessor cross-reference |

No new runtime module is needed. Server `ConnectionState.pm` and Tools `Test/WebSocket.pm` are inspection points, not anticipated edits. If evidence requires edits there, explain why before expanding the change.

## Task 1: Correct Server refusal completion on both transports

**Consumes:** Existing `pagi.connection` close accessors, completion callbacks, `end_future`, and terminal output paths.

**Produces:** The design's completed-refusal outcome on real HTTP/1.1 and HTTP/2, without changing the wire response or accepted-WebSocket closure.

- [x] Add a refusing app to each existing close-code test harness. Register observers before output; collect assertions outside the callback because callback exceptions may be isolated. Use the following observation shape and native application body:

```perl
my %seen = (complete => 0, end => 0, disconnect => 0);
my $app = async sub {
    my ($scope, $receive, $send) = @_;
    return unless $scope->{type} eq 'websocket';
    my $conn = $scope->{'pagi.connection'};
    await $receive->(); # consume websocket.connect
    my $snapshot = sub {
        return [
            $conn->close_code, $conn->close_reason,
            $conn->response_complete ? 1 : 0,
            $conn->is_connected ? 1 : 0,
            $conn->disconnect_reason, $conn->disconnect_detail,
        ];
    };
    $conn->on_complete(sub {
        ++$seen{complete};
        $seen{at_complete} = $snapshot->();
    });
    $conn->on_end(sub {
        ++$seen{end};
        $seen{at_end} = $snapshot->();
    });
    $conn->on_disconnect(sub { ++$seen{disconnect} });
    my $end = $conn->end_future;
    await $send->({type => 'http.response.start', status => 403, headers => []});
    $seen{before_body} = $conn->close_code;
    await $send->({type => 'http.response.body', body => 'Access denied'});
    $seen{end_value} = await $end;
    $seen{after_end} = $snapshot->();
    $seen{receive_type} = (await $receive->())->{type};
    $seen{returned} = 1;
};
```

Drive each harness until the app returns and both callbacks have run. Assert:

```perl
is $seen{before_body}, undef, 'no close metadata before refusal completion';
is $seen{at_complete}, [1006, undef, 1, 0, undef, undef], 'complete sees terminal facts';
is $seen{at_end},      [1006, undef, 1, 0, undef, undef], 'end sees terminal facts';
is $seen{after_end},   [1006, undef, 1, 0, undef, undef], 'end future sees terminal facts';
is [@seen{qw(complete end disconnect)}], [1, 1, 0], 'clean callback families';
is $seen{end_value}, undef, 'successful end future';
is $seen{receive_type}, 'http.disconnect', 'no synthetic WebSocket disconnect';
```

For h1 send a normal upgrade request and read the HTTP refusal through EOF; do not reuse `ws_upgrade` unchanged, because it waits for a 101. Assert HTTP 403 and the decoded body exactly. For h2 use the existing extended-CONNECT request helper and capture status, DATA, and server END_STREAM. Assert HTTP 403 and exactly `Access denied` as response data, with no extra WebSocket Close payload. Keep the client's sending direction open through the observation; do not make success depend on a new client END_STREAM requirement.

- [x] Run the two files and establish the intended red failure: the callback code is `undef` instead of `1006`. A skip, harness timeout, or dependency load error does not establish that failure.

```sh
perlbrew exec --with perl-5.42.2@default prove -lv t/83-ws-close-code.t t/http2/48-ws-close-code.t
```

- [x] Update the existing completion methods in `Connection.pm`. The minimal intended shape is below; preserve their existing wake-after-mark order and surrounding behavior:

```perl
sub _h2_end_scope_output {
    my ($self, $stream) = @_;
    if (my $conn = $stream->{connection_state}) {
        $conn->_set_ws_close(1006, undef)
            if $stream->{is_websocket} && !defined $conn->close_code;
        $conn->_mark_complete;
    }
    $self->_h2_wake_pending($stream);
    return;
}

sub _h1_end_scope_output {
    my ($self) = @_;
    if (my $conn = $self->{current_connection_state}) {
        $conn->_set_ws_close(1006, undef)
            if ($self->{scope_kind} // '') eq 'websocket'
                && !defined $conn->close_code;
        $conn->_mark_complete;
    }
    $self->_wake_receive_pending;
    return;
}
```

These output-completion methods serve HTTP response completion, including refusal. Accepted-WebSocket handshake settlement remains in its existing separate paths. `_set_ws_close` already rejects changes after termination; keep that protection. Do not put a scope-blind fallback in Server's generic ConnectionState.

- [x] Extend the refusal tests to observe an incremental body and declared trailers. Use the same observer setup with this send sequence; the two intermediate snapshots must retain `close_code = undef`, an active scope, and no terminal notification:

```perl
await $send->({type => 'http.response.start', status => 403,
              headers => [], trailers => 1});
await $send->({type => 'http.response.body', body => 'Access ', more => 1});
$seen{after_chunk} = $snapshot->();
await $send->({type => 'http.response.body', body => 'denied'});
$seen{before_trailers} = $snapshot->();
await $send->({type => 'http.response.trailers', headers => [['x-finished', 'yes']]});
```

Reuse existing file/fh refusal tests and inspect their terminal routing. Add metadata assertions there only if necessary to establish that they reach the corrected boundary; do not build another response-format matrix.

- [x] Cover interruption deterministically: hold the app after a `more => 1` body with a harness-owned Future, close the h1 client socket / reset the h2 stream, and pump until `on_disconnect`. Capture the terminal snapshot. Release the app to attempt its last body, allowing the existing send-failure behavior. Assert no `on_complete`, one `on_end`, `1006` / `undef`, the existing `client_closed` token, and an unchanged terminal snapshot. Keep the observed detail verbatim; do not pin OS error text. Reuse existing interruption coverage if it already checks these facts.
- [x] Run the affected server coverage. The generic HTTP/SSE controls and accepted-WebSocket peer-code tests must remain green:

```sh
perlbrew exec --with perl-5.42.2@default prove -lv t/83-ws-close-code.t t/http2/48-ws-close-code.t t/71-http-refusal-on-protocol-scopes.t t/37-connection-state.t
```

- [x] Review the Server diff as one bounded change. If committing during execution, stage only the Task 1 files actually changed and use `fix: populate websocket refusal close metadata before completion`. No push.

## Task 2: Align the Tools test double, regressions, and documentation

**Consumes:** The same existing PAGI outcome from Task 1; no Server classes or private server fields.

**Produces:** Matching simulated refusal behavior and a documented public helper contract. This task can be implemented independently of Task 1.

- [x] Extend `t/test/client-ws-lifecycle.t` with a public-path refusal regression. Use its existing imports plus `PAGI::Response qw(text_response)` as needed:

```perl
my ($conn, @closed, @complete, @ended);
my $disconnected = 0;
my $client = PAGI::Test::Client->new(app => async sub {
    my ($scope, $receive, $send) = @_;
    $conn = $scope->{'pagi.connection'};
    $conn->on_complete(sub { push @complete, $conn->close_code });
    $conn->on_end(sub { push @ended, $conn->close_code });
    $conn->on_disconnect(sub { ++$disconnected });
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->on_close(sub { push @closed, [@_]; return });
    await $ws->deny(text_response('Access denied', status => 403));
});
my $session = $client->websocket('/ws');
ok $session->refused, 'handshake refused';
is $session->response->status, 403, 'HTTP status preserved';
is $session->response->content, 'Access denied', 'body preserved';
is \@complete, [1006], 'complete observer sees code';
is \@ended, [1006], 'end observer sees code';
is \@closed, [[1006, undef, undef]], 'production helper reads supplied metadata';
is $disconnected, 0, 'successful refusal is not a disconnect failure';
ok $conn->response_complete, 'response complete';
is $conn->disconnect_reason, undef, 'no abnormal outcome';
is $conn->end_future->get, undef, 'successful end future';
```

Read metadata from the app's `pagi.connection` and production helper. `PAGI::Test::WebSocket->close_code` separately records the app's wire Close; do not silently redefine that client-side accessor in this correction.

- [x] Replace `undef` with `1006` in `t/websocket/deny-close-code.t` and correct its misleading comment/title. Remove the refusal fixture's `_set_peer_close(1006, undef)` in `t/websocket/15-connection-cleanup.t`, so its expectation now tests normal settlement.
- [x] Establish the red failures:

```sh
perlbrew exec --with perl-5.40.0@default prove -lv t/test/client-ws-lifecycle.t t/websocket/deny-close-code.t t/websocket/15-connection-cleanup.t
```

- [x] In `PAGI::Test::ConnectionState::_mark_complete`, immediately after the existing connected guard and before any terminal publication, add:

```perl
if ($self->{_websocket} && !defined $self->{_close_code}) {
    $self->{_close_code} = 1006;
    $self->{_close_reason} = undef;
}
```

Keep the existing connected guard, notification deferral, and `_deliver_notifications` behavior. The abnormal path already normalizes a missing code; update its comment to avoid implying it applies only after acceptance. Do not change production helper code.

- [x] In `t/test/connection-state.t`, add focused controls using the file's Test::More assertions. Check ordinary non-WebSocket completion stays undefined; supplied peer `1000` / `bye` survives completion; abnormal termination followed by completion remains abnormal; and repeated completion emits observers only once. The abnormal case is:

```perl
my $c = PAGI::Test::ConnectionState->new(websocket => 1);
my ($complete, $end) = (0, 0);
$c->on_complete(sub { ++$complete });
$c->on_end(sub { ++$end });
$c->_mark_disconnected('client_closed');
$c->_mark_complete;
$c->_mark_complete;
is_deeply [$c->close_code, $c->close_reason, $c->disconnect_reason,
           $c->response_complete ? 1 : 0, $complete, $end],
          [1006, undef, 'client_closed', 0, 0, 1],
          'late completion cannot replace abnormal termination';
```

Extend the existing fh/trailer public refusal test with snapshots before the terminal trailer and at completion. Do not redesign TestClient to return a still-pending refusal session; collect intermediate snapshots inside the app as Task 1 does.

- [x] Add the following explanation beside `deny` in `lib/PAGI/WebSocket.pm`, and link to `deny` from the close-accessor section:

> A successfully delivered HTTP refusal completes the PAGI scope normally: `on_complete` runs and `disconnect_reason` is undefined. Its WebSocket `close_code` is nevertheless `1006`, with an undefined `close_reason`, because no peer Close frame was received. This value is local metadata; no WebSocket Close frame is sent. Use scope completion to distinguish successful refusal delivery from an interrupted response.

Include this API-correct example in POD (within an async handler that has `$ws` and `$scope`):

```perl
use PAGI::Response qw(text_response);
my $connection = $scope->{'pagi.connection'};
$connection->on_complete(sub {
    # The HTTP refusal completed successfully.
});
$ws->on_close(sub {
    my ($code, $reason, $detail) = @_;
    # After this refusal: 1006, undef, undef.
});
await $ws->deny(text_response('Access denied', status => 403));
```

- [x] Run focused Tools checks and POD validation:

```sh
perlbrew exec --with perl-5.40.0@default prove -lv t/test/connection-state.t t/test/client-ws-lifecycle.t t/test/client-terminal-outcomes.t t/test/client-sse-decline.t t/websocket/deny-close-code.t t/websocket/15-connection-cleanup.t t/protocol-refusal-applications.t
perlbrew exec --with perl-5.40.0@default podchecker lib/PAGI/WebSocket.pm
```

- [x] Review the Tools diff; if committing during execution, stage only Task 2 changes and use `fix: align websocket refusal metadata in test client`. Preserve all unrelated working changes. No push.

## Task 3: Close the verification gate

**Consumes:** Completed Tasks 1 and 2, with real HTTP/2 execution available.

**Produces:** A concrete completion report tied to the tested checkout identities; no new feature or test framework.

- [x] Compare the real-server observer snapshots with the public TestClient regression. Both must show the same six terminal values, the same callback families, and HTTP 403 with the expected body. The helper's `on_close` must see `[1006, undef, undef]` without manufacturing a code. This comparison uses the existing contract, not private cross-repository calls.
- [x] Run each changed repository's complete suite once after focused checks pass. Run from the relevant repository root:

```sh
# PAGI-Server execution checkout
perlbrew exec --with perl-5.42.2@default prove -lr t

# PAGI-Tools current working checkout
perlbrew exec --with perl-5.40.0@default prove -lr t
```

- [x] Inspect the TAP summary and skip reasons. Specifically verify `t/http2/48-ws-close-code.t` executed its new refusal assertions. Keep logs and report any unrelated failure separately; do not label skipped HTTP/2 coverage a completed gate.
- [x] Run `git diff --check` in both changed repositories. Confirm the PAGI checkout is untouched and production Tools helper behavior is unchanged. Check final commits/diffs against the recorded initial dirty state.
- [x] Report the actual branch/commit or working-tree identity for both repositories, files changed, targeted and full-suite results, and any unresolved blocker. No claim of completion until both transports are verified. Do not push or merge.

## Stop conditions

If this requires changing terminal timing, adding a new scope flag, waiting for an extra Close/END_STREAM, changing accepted-WebSocket behavior, or synthesizing metadata in the production helper, stop and explain the concrete evidence before expanding scope. A missing HTTP/2 dependency is a verification prerequisite, not a reason to redesign the protocol or add fallbacks.


## Execution result — 2026-09-22

Completed and independently reviewed; no remaining findings. Tools remained on
`feature/universal-connection-tools` (implementation `3da2131`, expectation fix
`4efd8ca`). Server work is on `fix/websocket-refusal-close-metadata`, in
`PAGI-Server/.worktrees/fix-websocket-refusal-close-metadata` (implementation
`443499c`, additional review assertions `887181e`). Neither branch was pushed
or merged. The PAGI specification checkout and pre-existing Tools edits are
unchanged.

- Tools regular full suite: **242 files, 2941 tests, PASS**, Perl 5.40.0.
- Server regular full suite at `443499c`: **169 files, 1193 tests, PASS**,
  Perl 5.42.2 with nghttp2 0.011; the HTTP/2 refusal regression executed.
- The subsequent test-only `887181e` change passed its complete affected file:
  `t/71-http-refusal-on-protocol-scopes.t`, **15 tests, PASS**. Runtime unchanged.
- Temporary real Server + production Tools helper probe: **6 assertions PASS**;
  it reproduced the missing metadata before the Server correction.
- Existing opt-in release/stress and optional integration skips remain enabled;
  they are not additional claims of verification.

Server patch application was performed by the controller from subagent-authored
artifacts because that worktree was outside the agent's writable roots. Test
fixture corrections addressed response arrival/framing and an early HTTP/2
frame callback; no production timing or transport policy was changed.
