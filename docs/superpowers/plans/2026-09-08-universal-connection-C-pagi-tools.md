# Universal Connection State, Plan C: PAGI-Tools (consumes Www 0.6)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make PAGI-Tools consume Www 0.6 so that Stream through `PAGI::WebSocket->deny` and `PAGI::SSE->decline` observes disconnects and cleans up on legal scopes, refusals are plain HTTP responses with no bridge, the Test Client models 0.6 faithfully, and Auth Phase 1 can resume at Task 5.

**Architecture:** The Test Client puts a connection object on every scope fixture. The protocol-response bridge and its capability are deleted; `deny`/`decline` emit the Response directly and observe the start commit by wrapping `$send`. Stream gates on the object's presence, calls `abort` on caller cancellation, and the handler objects register their close callbacks on the object. Every task is TDD against the Tools suite; the last task is an integration run against PAGI-Server 0.002014.

**Tech Stack:** Perl, Future/Future::AsyncAwait, Test2::V0, PAGI::Test::Client.

**Spec:** `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/docs/superpowers/specs/2026-09-05-universal-connection-design.md` section 6. Plans A and B must be complete first; the integration task requires the PAGI-Server branch or release.

## Global Constraints

- **Added 2026-09-08 (D12, D13, design 4.7):** raw-PAGI return without the terminal event is incomplete; Tools' handler objects send the terminal event on the handler's behalf (Task C5). Cookbook/POD in C7 must not show the bare-return SSE idiom.

- Repository: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools`. Base: `feature/authentication-outcomes-phase1` at `2733ba2`. Create `feature/universal-connection-tools` from it in Task C1. Do not push. The untracked `.pagi-*` notes and `.superpowers/` stay untracked and untouched; never `git add -A` at the root, add named paths only.
- Gate: do not start until Plan B is complete and John has approved the spec PR (tracking row A8).
- Perl always via `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && <cmd>'`.
- Full suite: `prove -l t/` (2333 tests at the paused commit). Capture to a file; output must be pristine.
- Scope fixtures report `pagi => { version => '0.5', spec_version => '0.6' }` after Task C3.
- No `on_abort` family; `on_close` callbacks on the handler objects receive `($code_or_undef, $reason, $detail)` for WebSocket and `($reason, $detail)` for SSE (see C5).
- Commit after every task; update `docs/superpowers/plans/2026-09-08-universal-connection-tracking.md` in the same step. Record every reversed shipped assertion by file and subtest name.

---

### Task C1: `PAGI::Test::ConnectionState` gains `disconnect_detail`, two-argument callbacks, and `abort`

**Files:**
- Modify: `lib/PAGI/Test/ConnectionState.pm` (constructor 26, `on_disconnect` 129, `_mark_complete` 152, `_mark_disconnected` 163)
- Test: `t/test/connection-state.t`

**Interfaces:**
- Produces: `new(on_abort => $coderef)`; `disconnect_detail()`; `abort($detail)`; `_mark_disconnected($reason, $detail)`; callbacks get `($reason, $detail)`. Mirrors `PAGI::Server::ConnectionState` from Plan B exactly.

- [ ] **Step 1: Branch**

```bash
cd /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools
git status --short | grep -v '^?? \.pagi-\|^?? \.superpowers/\|^?? docs/'   # nothing else may be dirty
git checkout -b feature/universal-connection-tools feature/authentication-outcomes-phase1
```

- [ ] **Step 2: Failing tests**

Append to `t/test/connection-state.t`:

```perl
subtest 'disconnect_detail and two-argument on_disconnect' => sub {
    my $cs = PAGI::Test::ConnectionState->new;
    my @got;
    $cs->on_disconnect(sub { push @got, [@_] });
    is $cs->disconnect_detail, undef, 'undef while active';
    $cs->_mark_disconnected('keepalive_timeout', 'no pong within 10s');
    is $cs->disconnect_detail, 'no pong within 10s', 'accessor';
    is \@got, [['keepalive_timeout', 'no pong within 10s']], 'callback arguments';
    my @late; $cs->on_disconnect(sub { push @late, [@_] });
    is \@late, [['keepalive_timeout', 'no pong within 10s']], 'late registration';
};

subtest 'abort: hook once, app_abort with detail, idempotent, no-op after completion' => sub {
    my @hook;
    my $cs = PAGI::Test::ConnectionState->new(on_abort => sub { push @hook, [@_] });
    my @cb; $cs->on_disconnect(sub { push @cb, [@_] });
    my $f = $cs->disconnect_future;
    $cs->abort('quota');
    is scalar @hook, 1, 'hook once';
    is $hook[0][1], 'quota', 'hook detail';
    is $cs->disconnect_reason, 'app_abort', 'token';
    is $cs->disconnect_detail, 'quota', 'detail';
    ok $f->is_ready, 'future resolved';
    is \@cb, [['app_abort', 'quota']], 'callback';
    $cs->abort('again');
    is scalar @hook, 1, 'idempotent';

    my $done = PAGI::Test::ConnectionState->new(on_abort => sub { push @hook, 'never' });
    $done->_mark_complete;
    $done->abort('late');
    is scalar @hook, 1, 'no hook after completion';
    is $done->response_complete, 1, 'completion preserved';
};
```

- [ ] **Step 3: Verify failure, implement**

Run `prove -lv t/test/connection-state.t`; expect method-not-found failures. Implement, mirroring Plan B Task B1: add `_detail`, `_on_abort` to the hash in `new`; `sub disconnect_detail { $_[0]->{_detail} }`; `_mark_disconnected($reason, $detail)` stores `_detail` and fires `_fire($_, $reason, $detail)`; late `on_disconnect` fires with both; `_mark_complete` and `_mark_disconnected` both `delete $self->{_on_abort}`; and:

```perl
sub abort {
    my ($self, $detail) = @_;
    return unless $self->{_connected};
    my $hook = delete $self->{_on_abort};
    $self->_mark_disconnected('app_abort', $detail);
    $hook->($self, $detail) if $hook;
    return;
}
```
Document each in the POD with the spec link.

- [ ] **Step 4: Run, commit**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/test/connection-state.t > /tmp/tools-C1.txt 2>&1 && prove -l t/ >> /tmp/tools-C1.txt 2>&1; echo exit=$?'; tail -3 /tmp/tools-C1.txt
git add lib/PAGI/Test/ConnectionState.pm t/test/connection-state.t
git commit -m "test-client: connection state gains disconnect_detail, abort, two-arg callbacks

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPw16KQfvnDHyg7oA2TaKs"
```

---

### Task C2: `PAGI::Utils::_SendValidation` accepts HTTP refusals on protocol scopes

**Files:**
- Modify: `lib/PAGI/Utils/_SendValidation.pm` (websocket states doc 224-249, sse states 253-269, `complete` 298-303, and the `_check_websocket`/`_check_sse` implementations that follow `_check_http` at 355)
- Test: `t/utils-send-validation.t` (176-194 currently test the extension-gated denial)

**Interfaces:**
- Produces: websocket states `connecting | accepted | refusing | refusal_complete | closed`; sse states `initial | streaming | refusing | refusal_complete | closed`; `complete` true for `refusal_complete`; `websocket.close` in `connecting` is a sequence error; `websocket.http.response.*` and `sse.http.response.*` are unknown types; `new(extensions => ...)` no longer needs `websocket.http.response`.
- Consumes: the HTTP checks already in `_check_http` (reuse them for the refusal body/trailers rules).

- [ ] **Step 1: Rewrite the tests at 176-194**

Replace those assertions with:

```perl
subtest 'websocket: HTTP response events refuse the handshake before accept' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'websocket', extensions => {});
    is $sv->check({ type => 'http.response.start', status => 401, headers => [] }), undef, 'start accepted';
    ok !$sv->complete, 'not complete after start';
    is $sv->check({ type => 'http.response.body', body => 'more', more => 1 }), undef, 'more keeps refusing';
    is $sv->check({ type => 'http.response.body', body => 'done' }), undef, 'terminal';
    ok $sv->complete, 'complete after terminal';
    like $sv->check({ type => 'websocket.accept' }), qr/refusal already complete/, 'nothing after completion';
};
subtest 'websocket: websocket.close before accept is a sequence error; HTTP events after accept fail' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'websocket');
    like $sv->check({ type => 'websocket.close', code => 1008 }), qr/before websocket.accept/, 'close before accept';
    is $sv->check({ type => 'websocket.accept' }), undef, 'accept';
    like $sv->check({ type => 'http.response.start', status => 200 }), qr/after websocket.accept/, 'HTTP after accept';
    like $sv->check({ type => 'websocket.http.response.start', status => 401 }), qr/unknown|Unrecognized/, 'old event is unknown';
};
subtest 'sse: HTTP response events refuse the stream before start' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'sse');
    is $sv->check({ type => 'http.response.start', status => 404, headers => [] }), undef, 'start';
    is $sv->check({ type => 'http.response.body', body => 'nope' }), undef, 'terminal';
    ok $sv->complete, 'complete';
    my $sv2 = PAGI::Utils::_SendValidation->new(scope_type => 'sse');
    is $sv2->check({ type => 'sse.start', status => 200 }), undef, 'start stream';
    like $sv2->check({ type => 'http.response.start', status => 404 }), qr/after sse.start/, 'refusal after start';
};
```

- [ ] **Step 2: Implement**

In `_check_websocket`: in state `connecting`, `http.response.start` -> `refusing` after running the same field checks `_check_http` applies to a start (call a shared `_check_http_start_fields($event)` factored out of `_check_http`); `websocket.close` -> `_error(sequence => "cannot send websocket.close before websocket.accept")`. In `refusing`: `http.response.body` -> `refusal_complete` when `_http_body_is_terminal` else `refusing`; `http.response.trailers` -> `refusal_complete`; anything else -> sequence error "after http.response.start". In `accepted`: HTTP events -> sequence error "after websocket.accept". Drop the `denial`/`denial_complete` states and the extension gate. Same for `_check_sse` with `initial -> refusing`. `complete` returns true for `refusal_complete`. Update the POD state tables.

- [ ] **Step 3: Run, commit**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/utils-send-validation.t > /tmp/tools-C2.txt 2>&1 && prove -l t/ >> /tmp/tools-C2.txt 2>&1; echo exit=$?'; tail -3 /tmp/tools-C2.txt
```
Other files will now fail (Test::WebSocket, Lint, routing tests using the old events); that is expected and fixed in C3, C4, C7. Commit this task alone with the failing-test count noted in tracking:
```bash
git add lib/PAGI/Utils/_SendValidation.pm t/utils-send-validation.t
git commit -m "send-validation: HTTP refusals on websocket and sse scopes; drop the denial events

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPw16KQfvnDHyg7oA2TaKs"
```

---

### Task C3: Test Client: connection object on every scope, 0.6, refusals as HTTP responses

**Files:**
- Modify: `lib/PAGI/Test/Client.pm` (`%WEBSOCKET_EXTENSIONS` 26, `_build_scope` 260-300, `websocket` 320-405, `sse` 406-470)
- Modify: `lib/PAGI/Test/WebSocket.pm` (`_start` 31-130: the `websocket.close`-before-accept and `websocket.http.response.*` branches at ~100-111)
- Modify: `lib/PAGI/Test/SSE.pm` (`_start` 31-115: the `sse.http.response.*` branches at 92-99)
- Test: `t/test/client-headers-extensions.t:185-196`, `t/test/client-ws-lifecycle.t`, `t/test/client-sse-decline.t`, `t/test/client-connection.t`

**Interfaces:**
- Produces: every scope from the Test Client carries `PAGI::Test::ConnectionState` with `on_abort` wired to close the test connection; `pagi => { version => '0.5', spec_version => '0.6' }`; `$client->websocket(...)` on a completed refusal returns the `PAGI::Test::WebSocket` object with `->refused` true and `->response` a `PAGI::Test::Response`; `$client->sse(...)` on a refusal returns a `PAGI::Test::Response` as today.

- [ ] **Step 1: Failing tests**

`t/test/client-headers-extensions.t:185-196` currently asserts the websocket scope advertises exactly `websocket.http.response`; change it to assert `extensions` is `{}`. Add to `t/test/client-ws-lifecycle.t`:

```perl
subtest 'websocket scope carries pagi.connection and refusal is an HTTP response' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $c = $scope->{'pagi.connection'} or die 'no connection object';
        await $receive->();
        await $send->({ type => 'http.response.start', status => 401, headers => [['www-authenticate', 'Bearer']] });
        await $send->({ type => 'http.response.body', body => 'nope' });
        die 'should be complete' unless $c->response_complete;
    };
    my $client = PAGI::Test::Client->new(app => $app);
    my $ws = $client->websocket('/ws');
    ok $ws->refused, 'refused';
    is $ws->response->status, 401, 'status';
    is $ws->response->body, 'nope', 'body';
    is $ws->close_code, undef, 'no close code for an HTTP refusal';
};
subtest 'websocket.close before accept is rejected by the test client' => sub {
    my $app = async sub { my ($scope, $receive, $send) = @_; await $receive->(); await $send->({ type => 'websocket.close', code => 1008 }) };
    my $client = PAGI::Test::Client->new(app => $app);
    like dies { $client->websocket('/ws') }, qr/before websocket.accept/, 'strict send rejects it';
};
subtest 'client close marks the object client_closed; clean handshake marks complete' => sub {
    my %r;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $c = $scope->{'pagi.connection'};
        $c->on_disconnect(sub { $r{disc} = [@_] }); $c->on_complete(sub { $r{complete}++ });
        await $receive->(); await $send->({ type => 'websocket.accept' });
        while (1) { my $e = await $receive->(); last if $e->{type} eq 'websocket.disconnect' }
    };
    my $client = PAGI::Test::Client->new(app => $app);
    my $ws = $client->websocket('/ws'); $ws->close;
    is $r{complete}, 1, 'client-initiated close handshake is a clean end';
    ok !$r{disc}, 'no disconnect';
};
```
Add to `t/test/client-sse-decline.t` the same shape with `http.response.*` (rename the old events there), and to `t/test/client-connection.t` an assertion that `$scope->{pagi}{spec_version}` is `'0.6'` on http, websocket, and sse scopes.

- [ ] **Step 2: Implement**

`Client.pm`: `%WEBSOCKET_EXTENSIONS = ()`; in `_build_scope`, `websocket`, and `sse` set `pagi => { version => '0.5', spec_version => '0.6' }` and add `'pagi.connection' => PAGI::Test::ConnectionState->new(on_abort => ...)` to the websocket and sse scopes (http already has it; give it the hook too). The hook closes the test connection object: for websocket `sub { $ws->_transport_closed }`, for sse `sub { $sse->_transport_closed }`, for http mark the response aborted; since the object is built before the `PAGI::Test::WebSocket`/`SSE` instance, create the state first, build the handler, then `$state->_set_abort_hook(sub { $handler->_transport_closed })`. Add to `PAGI::Test::ConnectionState`:

```perl
# Server-internal: the test client installs the teardown hook after the handler
# that owns the transport exists.
sub _set_abort_hook { $_[0]->{_on_abort} = $_[1]; return }
```
and add `sub _transport_closed { my ($self) = ; $self->{closed} = 1; $self->{scope}{'pagi.connection'}->_mark_disconnected('app_abort') unless $self->{scope}{'pagi.connection'}->is_connected == 0; $self->_wake_pending_receives; return }` to `PAGI::Test::WebSocket` and `PAGI::Test::SSE`, where `_wake_pending_receives` resolves each Future in `_pending_receives` with the scope's disconnect event (`websocket.disconnect` 1006 `app_abort`, or `sse.disconnect` `app_abort`).

`Test/WebSocket.pm` `_start`: replace the `websocket.close`-before-accept acceptance (it is now rejected by `$sv->check`, so the branch is unreachable; delete it) and the `websocket.http.response.*` branch with:
```perl
        elsif ($type =~ /^http\.response\./) {
            $self->{refusal_status}  = $event->{status}  if $type eq 'http.response.start';
            $self->{refusal_headers} = $event->{headers} if $type eq 'http.response.start';
            $self->{refusal_body}   .= ($event->{body} // '') if $type eq 'http.response.body';
            if ($sv->complete) {
                $self->{closed} = 1;
                $self->{refused} = 1;
                $self->{scope}{'pagi.connection'}->_mark_complete;
            }
        }
```
Add `sub refused { $_[0]{refused} ? 1 : 0 }` and `sub response { PAGI::Test::Response->new(status => ..., headers => ..., body => ...) }` (match how `Test::SSE` builds its decline response). On the client-side `close` path call `_mark_complete` when a close handshake completed (client `close` sends a Close frame and the app answers or vice versa) and `_mark_disconnected('client_closed')` on `_transport_closed` (abnormal). `Test/SSE.pm`: same replacement for the decline branches; `_declined` becomes `refused` internally but keep the public behaviour of `$client->sse` returning a `PAGI::Test::Response`.

- [ ] **Step 3: Run the four test files, then full suite, commit**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/test/ > /tmp/tools-C3.txt 2>&1 && prove -l t/ >> /tmp/tools-C3.txt 2>&1; echo exit=$?'; tail -3 /tmp/tools-C3.txt
git add lib/PAGI/Test/Client.pm lib/PAGI/Test/WebSocket.pm lib/PAGI/Test/SSE.pm t/test/
git commit -m "test-client: pagi.connection on every scope, spec_version 0.6, HTTP refusals

Reverses t/test/client-headers-extensions.t 'websocket scope advertises exactly
websocket.http.response' (D4/D11).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPw16KQfvnDHyg7oA2TaKs"
```

---

### Task C4: Delete the protocol-response bridge; `deny`/`decline` emit the Response directly

**Files:**
- Modify: `lib/PAGI/Response.pm` (delete `_validate_protocol_response` ~703 and `_respond_for_protocol` 715-797; delete `protocol_response_capability` 470 and its POD 127, 175)
- Modify: `lib/PAGI/Response/File.pm:141` (delete the override), `lib/PAGI/Response/NDJSON.pm:51` (POD)
- Modify: `lib/PAGI/WebSocket.pm` (`supports_denial_response` 420-426 delete; `deny` 429-491 rewrite; `close` 393-410 croak before accept; POD 1126-1140, 1313-1340)
- Modify: `lib/PAGI/SSE.pm` (`decline` 325-382 rewrite; POD 1159-1230)
- Test: `t/websocket/denial-response.t`, `t/websocket/deny-close-code.t`, `t/sse/13-decline.t`, `t/sse/14-keepalive-deferred-arm.t:96-97`, `t/routing/08-protocols.t`, `t/routing/12-router-mounts.t`, `t/routing/16-http-outcomes.t`, `t/upgrading-response-family.t`, `t/response/05-ndjson.t`, `t/auth/04-protocol-integration.t` (the capability subtest at ~318-340)

**Interfaces:**
- Consumes: `PAGI::Response->_emit($scope, $receive, $send)` (existing), `$response->is_buffered` (existing: Response 468 returns 1; File 139 and Stream 79 return 0).
- Produces: `deny($response)` and `decline($response)` accept any `PAGI::Response` (File included); before emitting a non-buffered Response they require `$scope->{'pagi.connection'}` and croak `"<op> of a streaming Response requires pagi.connection (server reports spec_version $v; 0.6 needed)"` otherwise; `websocket.close`-before-accept via `close()` croaks `'WebSocket close is only valid after accept; use deny'`.

- [ ] **Step 1: Rewrite the tests**

Mechanical rename first:
```bash
grep -rl "websocket.http.response\|sse.http.response" t/ lib/ | xargs perl -pi -e 's/websocket\.http\.response\./http.response./g; s/sse\.http\.response\./http.response./g; s/\{ .websocket\.http\.response. => \{\} \}/{}/g'
```
Then by file:
- `t/websocket/deny-close-code.t`: keep subtest 1 with `extensions => {}` and `http.response.start`; replace subtest 2 with "close() before accept croaks and sends nothing".
- `t/websocket/denial-response.t`: delete subtests 'unsupported response capabilities fail before denial start' (329), 'without the extension deny uses policy-close' (475), 'cancelling policy-close fallback' (615), 'supports_denial_response reports the advertised extension' (642), each recorded as reversed under D4/D5/D11; change 'deny adapts the complete concrete Response matrix' (153) to include `PAGI::Response::File` and assert `http.response.body` with `file`; 'Response receives a shallow HTTP scope clone' (199) becomes 'Response receives the websocket scope unchanged' asserting `$seen_scope == $scope`; the fixture at 417 keeps `'pagi.connection' => $connection` (now legal) and additionally asserts `$connection->response_complete` is 0 after the drop.
- `t/sse/13-decline.t`: mirror the above; the fixture at 415 likewise.
- `t/auth/04-protocol-integration.t`: the subtest 'Pages response classes advertise the denial body capability and File stays opted out' becomes 'every concrete Response, File included, is a valid refusal' asserting `deny`/`decline` with `PAGI::Response::File->new(__FILE__)` emits a `file` body event.
- Routing/upgrading/ndjson tests: after the rename, fix the `extensions` expectations and any assertion that File is rejected.

- [ ] **Step 2: Implement `deny`**

Replace `PAGI::WebSocket::deny` (429-491) with:

```perl
# Refuse the handshake with a concrete HTTP Response: an ordinary HTTP response
# on this scope before accept (Www 0.6, "Refusing the handshake").
sub deny {
    my ($self, @args) = @_;
    croak 'WebSocket denial response is pending' if $self->{_state} eq 'denying';
    croak 'WebSocket deny is only valid before accept while connecting'
        unless $self->{_state} eq 'connecting';
    croak 'WebSocket deny requires exactly one concrete PAGI::Response'
        unless @args == 1 && blessed($args[0]) && $args[0]->isa('PAGI::Response');
    my $response = $args[0];
    $self->_require_connection_for_stream($response, 'WebSocket deny');

    $self->{_state} = 'denying';
    my $committed = 0;
    my $send = $self->{send};
    my $observing_send = async sub {
        my ($event) = @_;
        await Future->wrap($send->($event));
        if (($event->{type} // '') eq 'http.response.start') {
            # The accepted start owns the handshake response slot.
            $committed = 1;
            $self->{_state} = 'closed';
        }
        return;
    };
    my $lifecycle = async sub {
        my $completed = eval { await Future->wrap($response->_emit($self->{scope}, $self->{receive}, $observing_send)); 1 };
        my $error = $@ unless $completed;
        if (!$committed) {
            $self->{_state} = 'connecting' if $self->{_state} eq 'denying';
            die $error unless $completed;
        }
        await $self->_run_close_callbacks if $committed;
        die $error unless $completed;
        return $self;
    }->();
    $self->{_response_lifecycle} = $lifecycle;
    $lifecycle->on_ready(sub { my ($ready) = @_; delete $self->{_response_lifecycle}
        if $self->{_response_lifecycle} && $self->{_response_lifecycle} == $ready });
    return $lifecycle->without_cancel;
}

# A streaming Response can only be refused safely when the scope carries a
# connection object (Www 0.6). Refuse synchronously, naming the server version.
sub _require_connection_for_stream {
    my ($self, $response, $op) = @_;
    return if $response->is_buffered;
    return if $self->{scope}{'pagi.connection'};
    my $v = $self->{scope}{pagi}{spec_version} // '0.1';
    croak "$op of a streaming Response requires pagi.connection (server reports spec_version $v; 0.6 needed)";
}
```
Delete `supports_denial_response`. In `close()`, add at the top: `croak 'WebSocket close is only valid after accept; use deny' if $self->{_state} eq 'connecting';`. Do the same rewrite for `PAGI::SSE::decline` (325-382), keeping its `_declined`, `_disconnect_reason //= 'declined'`, and `_pending_keepalive` handling inside the start-commit branch. Delete `_respond_for_protocol`, `_validate_protocol_response`, and every `protocol_response_capability`. Update POD: `deny`/`decline` accept any Response, prefer a finite one, and what streaming commits you to (spec 4.3 note).

- [ ] **Step 3: Run, commit**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/websocket/ t/sse/ t/routing/ t/auth/ t/upgrading-response-family.t t/response/ > /tmp/tools-C4.txt 2>&1 && prove -l t/ >> /tmp/tools-C4.txt 2>&1; echo exit=$?'; tail -3 /tmp/tools-C4.txt
git add lib/PAGI/Response.pm lib/PAGI/Response/File.pm lib/PAGI/Response/NDJSON.pm lib/PAGI/WebSocket.pm lib/PAGI/SSE.pm t/
git commit -m "tools: refusals are plain HTTP responses; delete the protocol-response bridge

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPw16KQfvnDHyg7oA2TaKs"
```

---

### Task C5: Handlers and Stream use the object: close callbacks from the object, `abort` on caller cancel, detail passthrough

**Files:**
- Modify: `lib/PAGI/WebSocket.pm` (constructor ~20-45; `_run_close_callbacks` 276-300)
- Modify: `lib/PAGI/SSE.pm` (constructor ~20-45; `_run_close_callbacks` 647-670)
- Modify: `lib/PAGI/Response/Stream.pm` (`_run_lifecycle` 126-244, the `caller_cancelled` branch at 173-180)
- Modify: `lib/PAGI/Response/Writer.pm` (`_new` 86-96: the `on_disconnect` registration accepts `($reason, $detail)` and stores the detail; add `disconnect_detail` accessor)
- Test: `t/websocket/` (new `t/websocket/connection-object.t`), `t/sse/` (new `t/sse/connection-object.t`), `t/response/` Stream tests (`ls t/response/ | grep -i stream` and add to the lifecycle file)

**Interfaces:**
- Produces (added 2026-09-08, D12/D13, design 4.7): when a handler returns from a started `PAGI::SSE` stream without `sse.close`, the helper sends `sse.close`; when a handler returns from an accepted `PAGI::WebSocket` with no closing handshake, the helper sends `websocket.close` code 1000. Tests: one each, asserting the terminal event is emitted exactly once and not emitted when the handler already closed. `PAGI::WebSocket->on_close` callbacks receive `($code, $reason, $detail)`; `PAGI::SSE->on_close` callbacks receive `($sse, $reason, $detail)` (its existing signature plus detail); on a scope with a connection object, close callbacks run exactly once on either terminal family without the handler consuming the queue; `Stream` calls `$scope->{'pagi.connection'}->abort('response cancelled by caller')` on `caller_cancelled` when the object exists and `can('abort')`.

- [ ] **Step 1: Tests**

`t/websocket/connection-object.t`:
```perl
subtest 'on_close runs once from the object on an abnormal end, with reason and detail' => sub {
    my $cs = PAGI::Test::ConnectionState->new;
    my @calls;
    my $ws = PAGI::WebSocket->new({ type => 'websocket', path => '/', headers => [], 'pagi.connection' => $cs },
                                  sub { Future->new }, sub { Future->done });
    $ws->on_close(sub { push @calls, [@_] });
    $cs->_mark_disconnected('keepalive_timeout', 'no pong within 10s');
    is scalar @calls, 1, 'once';
    is $calls[0][1], 'keepalive_timeout', 'reason';
    is $calls[0][2], 'no pong within 10s', 'detail';
    ok $ws->is_closed, 'handler closed';
};
subtest 'on_close runs once from the object on a clean end' => sub { ...same with _mark_complete; reason undef... };
subtest 'deny of a Stream on a scope without the object croaks synchronously naming the version' => sub {
    my $ws = PAGI::WebSocket->new({ type => 'websocket', path => '/', headers => [], pagi => { spec_version => '0.5' } }, sub { Future->new }, sub { Future->done });
    like dies { $ws->deny(PAGI::Response::Stream->new(async sub { })) }, qr/spec_version 0\.5; 0\.6 needed/, 'gate';
};
```
Stream lifecycle test: emit a Stream on an http scope with a `PAGI::Test::ConnectionState` whose `on_abort` records calls; cancel the returned observer while the producer is parked; assert one `abort` call with detail matching `/cancelled by caller/`, the producer cancelled, Writer cleanup once, and that a pending send Future was awaited, not cancelled (reuse the shape of `t/websocket/denial-response.t:573` 'cancelling deny during a body send preserves producer and cleanup ownership').

- [ ] **Step 2: Implement**

In both handler constructors, if `$scope->{'pagi.connection'}` exists, register:
```perl
    if (my $conn = $scope->{'pagi.connection'}) {
        weaken(my $weak = $self);
        $conn->on_disconnect(sub { my ($reason, $detail) = @_; $weak && $weak->_note_disconnected(undef, $reason, $detail)->retain });
        $conn->on_complete(sub { $weak && $weak->_note_completed->retain });
    }
```
`_note_disconnected` gains a third argument stored as `$self->{_disconnect_detail}`; `_run_close_callbacks` passes it (`$cb->($code, $reason, $detail)` for WebSocket; `$cb->($sse, $reason, $detail)` for SSE); `_note_completed` marks closed and runs the callbacks with `reason` undef. The once-guard `_close_callbacks_ran` already prevents double runs when the queue also delivers the disconnect. In `Stream::_run_lifecycle`'s `caller_cancelled` branch, before `_abort`, add:
```perl
        my $conn = $scope->{'pagi.connection'};
        $conn->abort('response cancelled by caller') if $conn && $conn->can('abort');
```
In `Writer::_new`, the `on_disconnect` callback becomes `sub { my ($reason, $detail) = @_; ...; $weak_self->_record_disconnect($reason, $detail) }`, `_record_disconnect` stores `_disconnect_detail`, and add `sub disconnect_detail { $_[0]{_disconnect_detail} }` with POD.

- [ ] **Step 3: Run, commit**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/websocket/ t/sse/ t/response/ > /tmp/tools-C5.txt 2>&1 && prove -l t/ >> /tmp/tools-C5.txt 2>&1; echo exit=$?'; tail -3 /tmp/tools-C5.txt
git add lib/PAGI/WebSocket.pm lib/PAGI/SSE.pm lib/PAGI/Response/Stream.pm lib/PAGI/Response/Writer.pm t/websocket/connection-object.t t/sse/connection-object.t t/response/
git commit -m "tools: handlers observe the connection object; Stream aborts on caller cancel; detail passthrough

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPw16KQfvnDHyg7oA2TaKs"
```

---

### Task C6: Task 5 with legal fixtures, and the integration run against PAGI-Server 0.002014

**Files:**
- Modify: `t/auth/04-protocol-integration.t` (`direct_protocol` 51-60; the disconnect subtest ~253-330)
- Create: `t/integration/protocol-refusal-stream-disconnect.t`
- Test: both

- [ ] **Step 1: Legal fixtures**

`direct_protocol` builds its scope with `'pagi.connection' => PAGI::Test::ConnectionState->new` for every type and `pagi => { version => '0.5', spec_version => '0.6' }`; the disconnect subtest reads `my $connection = $protocol->scope->{'pagi.connection'}` instead of injecting one via `%changes`. Its assertions are unchanged. Add a second subtest that uses a `PAGI::Response::Stream` whose producer awaits a Future the test never resolves after one write, marks the connection disconnected, and asserts: the rejection Future resolves, the producer Future is cancelled, `writer_cleanup` and `close_calls` are 1, and no send was cancelled. This is the handoff's reproduction, now passing.

- [ ] **Step 2: Integration test**

`t/integration/protocol-refusal-stream-disconnect.t`, modelled on `t/integration/sse-decline-end-to-end.t` (skip unless `PAGI::Server->VERSION >= 0.002014`), runs a real `PAGI::Server` with an app that calls `PAGI::WebSocket->new(...)->deny($stream)` and `PAGI::SSE->new(...)->decline($stream)` where `$stream`'s producer parks after its first write; a raw client drops mid-body; assert on both transports (reuse the h1/h2 harness from `.pagi-server-protocol-disconnect-matrix-probe.pl`) that the deny/decline Future resolves, the producer is cancelled, cleanup ran once, and the server logged nothing at error level.

- [ ] **Step 3: Run, commit**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/auth/04-protocol-integration.t t/integration/protocol-refusal-stream-disconnect.t > /tmp/tools-C6.txt 2>&1 && prove -l t/ >> /tmp/tools-C6.txt 2>&1; echo exit=$?'; tail -3 /tmp/tools-C6.txt
git add t/auth/04-protocol-integration.t t/integration/protocol-refusal-stream-disconnect.t
git commit -m "auth: Task 5 protocol integration with legal 0.6 fixtures and a real-server run

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPw16KQfvnDHyg7oA2TaKs"
```

---

### Task C7: Lint, Cookbook, POD, Changes

**Files:**
- Modify: `lib/PAGI/Middleware/Lint.pm:127-145` (the http-only `_SendValidation` wiring and the `sse.start` check: wire `_SendValidation` for websocket and sse scopes too, so refusals are validated everywhere)
- Modify: `lib/PAGI/Tools/Cookbook.pod:1241,1374`
- Modify: POD in `PAGI::WebSocket`, `PAGI::SSE`, `PAGI::Response`, `PAGI::Response::File`, `PAGI::Test::Client`, `PAGI::Test::ConnectionState`
- Modify: `Changes` (0.002003 UNRELEASED section)
- Test: `t/middleware/` Lint tests (`ls t/middleware | grep -i lint`), `prove -l t/`

- [ ] **Step 1: Lint**

Add a test to the Lint file: a websocket app that sends `http.response.start` before accept produces no warning; one that sends `websocket.close` before accept produces the sequence warning. Implement by constructing `_SendValidation` for every scope type in `wrap`.

- [ ] **Step 2: Docs and Changes**

Cookbook 1241 and 1374: remove the `body-events-v1` sentences; state that any Response, File included, refuses a handshake or stream, and that a streaming Response requires a 0.6 server. Add to `Changes` under 0.002003:

```
  [Universal connection state (Www 0.6)]
  - Requires PAGI-Server 0.002014 for websocket and sse scopes to carry
    pagi.connection. Test::Client fixtures report spec_version 0.6 and carry
    the object on every scope.
  - PAGI::WebSocket->deny and PAGI::SSE->decline emit any PAGI::Response
    directly as an ordinary HTTP response; PAGI::Response::File is accepted;
    the body-events-v1 capability, the protocol response bridge,
    supports_denial_response, and the websocket.close fallback are removed.
    close() before accept croaks. A streaming Response on a scope without
    pagi.connection croaks naming the server version.
  - on_close callbacks receive the disconnect reason and detail; the handlers
    observe the connection object's terminal callbacks. Stream calls
    pagi.connection->abort on caller cancellation.
  - Test::ConnectionState gains disconnect_detail and abort.
```

- [ ] **Step 3: Run, commit**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/ > /tmp/tools-C7.txt 2>&1; echo exit=$?'; tail -3 /tmp/tools-C7.txt
git add lib/PAGI/Middleware/Lint.pm lib/PAGI/Tools/Cookbook.pod lib/PAGI/WebSocket.pm lib/PAGI/SSE.pm lib/PAGI/Response.pm lib/PAGI/Response/File.pm lib/PAGI/Test/Client.pm lib/PAGI/Test/ConnectionState.pm Changes t/middleware/
git commit -m "tools: lint refusals on every scope; docs and Changes for Www 0.6

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPw16KQfvnDHyg7oA2TaKs"
git log --oneline feature/authentication-outcomes-phase1..HEAD
```

Plan C is complete when the full suite is pristine with the integration test passing against PAGI-Server 0.002014. Then Auth Phase 1 resumes at Task 6 of `docs/superpowers/plans/2026-09-04-authentication-outcomes-phase1.md` with Task 5 re-marked done in its tracking ledger, referencing the C6 commit.
