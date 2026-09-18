# Protocol Refusal Applications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Choose the execution mode with the user; writing this plan does not begin implementation.

**Goal:** Make WebSocket `deny` and SSE `decline` accept ordinary Request handlers and PAGI application objects through their public interfaces, with consistent Request metadata/body support and useful documentation.

**Architecture:** Reuse `PAGI::Routing::RequestResponse` for handler adaptation and `PAGI::Utils::invoke_app` for native application execution. Require the public connection contract for refusals, retain asynchronous work independently of its observer, and leave terminal observation with the existing connection-owned cleanup. Share the small common refusal execution path; do not build concurrency arbitration or an event bridge.

**Tech Stack:** Perl, Future, Future::AsyncAwait, Test2::V0, existing PAGI Tools Request/Response/Pages and test clients. IO::Async and the existing PAGI-Server checkout are integration-test dependencies only.

**Spec:** [Protocol refusal applications design](../specs/2026-09-18-protocol-refusal-applications-design.md). Read the whole spec and this plan before implementation. The user reviewed the findings individually and requested this plan on 2026-09-18; the design document's original draft heading predates that review.

## Global Constraints

- “Backward compatibility is not a requirement for this redesign.” Replace superseded behavior and tests directly; no compatibility shims or deprecation phase.
- “`_emit` is private.” Response implementations can use their own internals; refusal helpers and adapters invoke public `to_app` applications.
- “Auth is out of scope.” No new Auth API, authentication backend, response-auth module, or renaming of existing Auth modules.
- “The delegated app receives the original send channel.” Preserve scope identity/type and the remaining original receive stream as well.
- “Keep library syntax compatible with the declared minimum Perl version.” Current `cpanfile` floors are Perl **5.018**, Future **0.50**, Future::AsyncAwait **0.66**. Unpack arguments from `@_` in library/test code; no dependency increases for this work.
- “Request, WebSocket, and SSE use `PAGI::Headers` for their shared `pagi.request.headers` cache.” Do not replace query/form containers.
- “Overlapping acceptance/start and refusal, repeated concurrent refusals, and reentrant conflicting helper calls are unsupported; helpers need not detect or arbitrate them.” No pending-accept/start flags, receive arbitration, or tests demanding a particular winner/error for these cases.
- The separate application-originated-cancellation proposal was **withdrawn**. Follow ordinary invocation/Future behavior. Do not add a cancellation policy, error class, or dedicated cancellation subsystem/test campaign.
- Preserve the existing distinction between cancelling a refusal observer and cancelling its underlying work; that supported observer behavior remains in the spec.
- Runtime code may use only the public PAGI connection contract, never PAGI-Server classes, internal fields, or timeout constants.
- A WebSocket HTTP refusal requires status >= 300; SSE may return an ordinary HTTP 200/204. Validation belongs to the sending environment, not a second refusal-specific validator.
- Full Tools-suite verification is required for implementation completion. Record skipped integration cases honestly; passing with skipped HTTP/2 cases is not HTTP/2 proof.

## Work map and workspace preservation

No external ticket was supplied. Work item: protocol refusal application contract.

| Repository | Branch / observed implementation base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | `feature/universal-connection-tools`; `e0f14366c1e7afffabfe87a14de2dcba14c89d63` before this plan commit | Plan now; Tasks 1–7 describe subsequent Tools implementation | Local source/tests/docs only; no release | None |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI` | `main`; `9aebdbcd938f4ff520d68ce2ea2e86cd00cf150f` | Read-only normative `lib/PAGI/Spec/Www.pod` | No changes | None |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server/.worktrees/feature-websocket-close-truthfulness` | `feature/websocket-close-truthfulness`; `c0c08f695a4ecb1cd1d553fdbdfec3dbda86601e` | Read-only real-server integration reference | No server edits or integration decision | None |

The Tools implementation base includes the approved review amendments. Reconfirm branch/HEAD and any intervening changes before execution; do not reset to the recorded hash. Keep the user's current branch unless an isolated execution checkout is chosen under the worktree skill. Record that checkout in this map before editing runtime files. No push/merge/tag/release is part of this plan.

The worktree already contains a modified `docs/superpowers/plans/2026-09-08-universal-connection-tracking.md` and unrelated `.pagi-*` / `.superpowers` notes. Preserve them. Stage exact owned paths only; never `git add .`. Planning documents are ignored by default and need `git add -f` when committing them.

## Execution order and files

Run tasks sequentially: **1 → 2 → 3 → 4 → 5 → 6 → 7**. Update affected old tests in the task that changes their behavior, not in a later cleanup task.

| Task | Production responsibility | Primary tests / documentation |
| --- | --- | --- |
| 1 | WebSocket/SSE header access uses the Request header container | New `t/request/15-protocol-headers.t`; existing header/helper tests and POD |
| 2 | Request accepts supported scopes; every body path recognizes native HTTP/SSE input; WS body reads reject before effects | New `t/request/16-protocol-input.t`; all Request/body/multipart tests |
| 3 | RequestResponse and Pages applications execute on http/websocket/sse without type spoofing | `t/routing/17-request-response.t`, `t/pages/03-invocation-composition.t`, `t/pages/07-response-for.t` |
| 4 | Thin refusal helpers share public application execution and retained work | New `lib/PAGI/Utils/_Refusal.pm`, `t/protocol-refusal-applications.t`, `t/lib/PAGITest/RefusalHarness.pm`; existing refusal/endpoint tests |
| 5 | Confirm test-client and real HTTP/1.1/HTTP/2 agreement | Existing `t/integration/protocol-refusal-stream-disconnect.t`, `t/integration/sse-decline-end-to-end.t`; test-client tests |
| 6 | Teach the six usage forms and migrate maintained examples/docs | Protocol/Request/Pages/Utils POD, Cookbook/Tutorial, `Changes`, new `examples/protocol-refusal/` and its executable example test |
| 7 | Complete verification and handoff | Full suite, POD checks, focused integration output, scoped diff review |

Two internal boundaries are deliberately small:

1. `PAGI::Request::_BodyInput::event_kind($scope_type, $event)` classifies an already-received native event as `body` or `disconnect`; it does not receive, rewrite events, own a Future, or track lifecycle. The four existing body readers call it. A private `_scope_type` constructor value, defaulting to `http` for direct reader construction, carries Request's real type into those readers.
2. `PAGI::Utils::_Refusal::run_refusal($helper, $target)` validates refusal admission, adapts a bare callback through RequestResponse, invokes the application with the helper's original channels, retains its execution Future, and returns a cancellation-isolated observer resolving to the helper. It is private and limited to the two existing helper layouts. No configurable lifecycle hooks or public coordinator API.

## Preflight

- [ ] Confirm the work map and capture existing worktree changes:

```sh
git status --short
git branch --show-current
git rev-parse HEAD
git -C ../PAGI rev-parse HEAD
git -C ../PAGI-Server/.worktrees/feature-websocket-close-truthfulness rev-parse HEAD
```

- [ ] Confirm interpreter and optional transport availability, without installing/upgrading dependencies merely to silence a skip:

```sh
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 perl -MFuture -MFuture::AsyncAwait -e 'print "$^V Future=$Future::VERSION AsyncAwait=$Future::AsyncAwait::VERSION\n"'
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 perl -I /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server/.worktrees/feature-websocket-close-truthfulness/lib -MPAGI::Server -MPAGI::Server::Protocol::HTTP2 -e 'print "$INC{q(PAGI/Server.pm)}\nh2=", PAGI::Server::Protocol::HTTP2->available, "\n"'
```

- [ ] Run the initial focused baseline. Record any pre-existing failure before changing behavior:

```sh
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -l t/request/01-basic.t t/pages/07-response-for.t t/routing/17-request-response.t t/websocket/denial-response.t t/sse/13-decline.t t/websocket/15-connection-cleanup.t
```

## Task 1: Use one header container across Request and protocol helpers

**Files:** Modify `lib/PAGI/WebSocket.pm`, `lib/PAGI/SSE.pm`; create `t/request/15-protocol-headers.t`; update assertions in `t/websocket/01-constructor.t`, `t/sse/01-constructor.t`, `t/pages/07-response-for.t`, and other located tests that explicitly expect Hash::MultiValue headers. Request already uses PAGI::Headers.

**Interfaces:** Consumes `PAGI::Headers->new($pairs)`, `get`, `get_all`. Produces the same `PAGI::Headers` object at `scope->{'pagi.request.headers'}` from each helper's `headers`; `header`/`header_all` delegate to it.

- [ ] Add a failing public-helper regression for each class. Request/protocol shared-scope tests follow in Task 2 once Request accepts those scopes. Representative body:

```perl
my $scope = {
    type => 'sse',
    headers => [['X-Trace', 'one'], ['x-trace', 'two']],
};
my $sse = PAGI::SSE->new($scope, sub { die 'unexpected receive' },
    sub { die 'unexpected send' });
isa_ok($sse->headers, ['PAGI::Headers'], 'one header container');
is($sse->headers->get('X-TRACE'), 'two', 'case-insensitive lookup');
is([$sse->header_all('x-TrAcE')], ['one', 'two'], 'repeated values');
```

- [ ] Run `perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -l t/request/15-protocol-headers.t`; expect the container assertion to fail before implementation.
- [ ] Replace each helper's header-container construction and direct raw-array lookup with the existing Request pattern:

```perl
sub headers {
    my ($self) = @_;
    return $self->{scope}{'pagi.request.headers'}
        //= PAGI::Headers->new($self->{scope}{headers} // []);
}
sub header { my ($self, $name) = @_; return $self->headers->get($name) }
sub header_all { my ($self, $name) = @_; return $self->headers->get_all($name) }
```

Load `PAGI::Headers ()` in both modules. Keep Hash::MultiValue imports where query/form code still uses them. Update each helper's `headers` POD to name PAGI::Headers; do not preserve hash dereference semantics for headers.

- [ ] Audit type assertions and header consumers with `rg -n 'Hash::MultiValue|pagi.request.headers|->headers' t/websocket t/sse t/pages lib/PAGI/WebSocket.pm lib/PAGI/SSE.pm`; fix only the header-related assumptions.
- [ ] Run the focused gate:

```sh
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -lr t/headers.t t/request/01-basic.t t/request/15-protocol-headers.t t/websocket t/sse t/pages/07-response-for.t
```

- [ ] Review the diff for unrelated container changes, then stage exact modified files and commit as `fix: share PAGI headers across protocol helpers`.

## Task 2: Give Request coherent WebSocket metadata and SSE body support

**Files:** Modify `lib/PAGI/Request.pm`, `lib/PAGI/Request/BodyStream.pm`, `lib/PAGI/Request/MultipartStream.pm`, `lib/PAGI/Request/MultiPartHandler.pm`; create `lib/PAGI/Request/_BodyInput.pm`, `t/request/16-protocol-input.t`; extend `t/request/15-protocol-headers.t` and existing multipart tests as needed.

**Interfaces:** Request keeps `new($scope, $receive)` and the exact raw scope. Private `event_kind($scope_type, $event)` returns `body`/`disconnect`; `_scope_type` passes through reader construction without replacing `$receive`. No public body-method signature changes.

- [ ] Add failing tests for supported types, absent WS method, ws/wss schemes, construction with a receive tripwire, rejected lifespan/custom types, and same-scope header access in both orders. Example for each protocol:

```perl
my $scope = {type => 'websocket', scheme => 'wss', path => '/socket',
    headers => [['X-Trace', 'one'], ['x-trace', 'two']]};
my $receive = sub { die 'metadata must not receive' };
my $ws = PAGI::WebSocket->new($scope, $receive, sub { die 'send' });
my $cached = $ws->headers;
my $request = PAGI::Request->new($scope, $receive);
is(refaddr($request->scope), refaddr($scope), 'original scope');
is(refaddr($request->headers), refaddr($cached), 'same cache object');
is($request->header('X-TRACE'), 'two', 'helper-first lookup');
is($request->method, undef, 'no fabricated method');
```

Use fresh scopes for Request-first and helper-first cases. Compare references with `Scalar::Util::refaddr` where equality helpers might compare structure rather than identity.

- [ ] Add actual SSE body events for buffered/chunked JSON and URL-encoded input. Representative JSON test:

```perl
my @input = (
    {type => 'sse.request', body => '{"job":', more => 1},
    {type => 'sse.request', body => '42}', more => 0},
);
my $request = PAGI::Request->new(
    {type => 'sse', method => 'POST', headers => [['content-type', 'application/json']]},
    sub { die 'over-read' unless @input; Future->done(shift @input) },
);
is($request->json->get, {job => 42}, 'SSE JSON reads native chunks');
is(scalar @input, 0, 'consumes only supplied body');
```

- [ ] Add the meaningful body-path matrix: empty final body; mid-body `sse.disconnect`; wrong event family; cached buffered re-read; streaming/buffered exclusion; size limits; multi-chunk UTF-8; complete multipart fields/uploads; interrupted multipart with file spooling and cleanup. Reuse existing multipart payload builders from `t/request/11-multipart-handler.t`, `t/request/12-uploads.t`, and streaming tests. Exercise `form_params`/`upload`, not just MultipartStream. Run HTTP equivalents through the same cases to prevent changed HTTP behavior.
- [ ] Add WS body rejection tests for `body`, `text`, `json`, `form_params`, `uploads`, `body_stream`, `multipart_stream`, and their public convenience delegates. Repeat with populated body/form/upload caches and absent Content-Type; assert zero receive calls and unchanged body-consumption flags.
- [ ] Run `perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -l t/request/15-protocol-headers.t t/request/16-protocol-input.t`; expected initial failure is unsupported Request scope.
- [ ] Broaden Request's constructor to `http`, `websocket`, `sse`. Add a private `_require_body_scope` check used before any body/cache/stream state changes, including fast-return branches in form/upload methods. It rejects WS reads without calling receive. Keep method absence and native schemes truthful.
- [ ] Implement the small shared classifier. Core logic for a defined event:

```perl
sub event_kind {
    my ($scope_type, $event) = @_;
    Carp::croak('body input requires HTTP or SSE scope')
        unless $scope_type eq 'http' || $scope_type eq 'sse';
    return 'disconnect' unless defined $event;
    Carp::croak('invalid request-body event') unless ref($event) eq 'HASH';
    my $type = $event->{type} // '';
    return 'body' if $type eq "$scope_type.request";
    return 'disconnect' if $type eq "$scope_type.disconnect";
    Carp::croak("unexpected request-body event '$type' on $scope_type scope");
}
```

The `undef` branch retains existing reader EOF handling, not an additional wire event. Readers keep their existing empty/truncated/parser-finalization behavior. Do not map `sse.request` into a fabricated `http.request`, and do not accept `http.disconnect` as the normal SSE end event.

- [ ] Set `_scope_type => $scope->{type}` when Request constructs BodyStream, MultipartStream, or MultiPartHandler. Default it to `http` in direct reader construction. Replace HTTP-only tests in each receive loop with calls to the classifier; feed the original event's bytes to the existing parser. No parser rewrite, background receiver, lifecycle state, or additional dependencies.
- [ ] Update Request/body-reader POD for supported input scopes and WS body rejection. Run:

```sh
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -lr t/request t/request-body-stream.t t/multipart-limits.t t/request-negotiate.t t/request-state.t t/request-stash.t
```

- [ ] Review all four receive paths and fast-return guards; stage exact owned files and commit as `feat: support protocol scopes in Request metadata and body readers`.

## Task 3: Execute Request handlers and Pages on real protocol scopes

**Files:** Modify `lib/PAGI/Routing/RequestResponse.pm`, `lib/PAGI/Pages/Application.pm`, `lib/PAGI/Pages.pm`; tests `t/routing/17-request-response.t`, `t/pages/03-invocation-composition.t`, `t/pages/07-response-for.t`, `t/pages/06-lifespan-decline.t`, and `t/integration-pages-example.t` (its lifespan diagnostic currently assumes HTTP-only Pages).

**Interfaces:** `request_response($handler, request_factory => $factory)` retains its existing contract and accepts http/websocket/sse invocation. Pages `to_app` and `response_for($source)` support the same three types. Descriptor factories see the original source scope; materialization remains synchronous and no-send.

- [ ] Extend RequestResponse tests across all three scope types with immediate and async handler results, native returned apps, custom Request factories, and exact triplet identity. Preserve exactly-once factory/handler/to_app calls. Example application construction:

```perl
my $application = request_response(sub {
    my ($request) = @_;
    is($request->scope, $scope, 'handler sees original scope');
    return sub {
        is([@_], [$scope, $receive, $send], 'native result sees original triplet');
        return Future->done;
    };
});
$application->to_app->($scope, $receive, $send)->get;
```

Add an SSE handler that reads one body chunk then returns a native app: that app receives only the remaining original events, without replay. Reject undef/hash/scalar handler results; a returned native app that produces no output remains valid.

- [ ] Change Pages tests that currently demand HTTP-only invocation to test direct http/websocket/sse use. Verify JSON/HTML/text negotiation, caller-configured renderers, shared headers remaining unchanged, and separate response values across repeated/concurrent invocations on different requests. Reject lifespan and custom scope materialization before rendering or I/O.
- [ ] Run `perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -lr t/routing/17-request-response.t t/pages`; expect old scope guards to fail the new accepted-scope tests.
- [ ] Replace the adapters' exact-HTTP guards with the explicit supported set. Keep invocation through `invoke_app`; do not duplicate RequestResponse's Future-backed return grammar.
- [ ] Replace `_http_metadata_scope` and every call site with metadata handling that keeps the real type/method/path. A shallow copy for cache isolation remains appropriate:

```perl
my %metadata = %$scope;
delete $metadata{'pagi.request.headers'};
my $request = PAGI::Request->new(\%metadata, $no_body);
```

Keep the descriptor factory's original-scope identity and configured policy object. Do not run descriptor factories against this isolated copy. Preserve Pages no-source-mutation tests; do not manufacture GET for WebSocket or allow arbitrary custom types via HTTP coercion.
- [ ] Update affected adapter/Pages POD and old assertions in the same task, including HTTP-only diagnostic assertions in the Pages integration test and any Auth outcome tests. Keep lifespan unsupported; broaden only the request scope set. Run:

```sh
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -I /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server/.worktrees/feature-websocket-close-truthfulness/lib -lr t/pages t/routing t/utils/application-values.t t/utils-to-app.t t/auth/03-outcomes.t t/integration-pages-example.t
```

- [ ] Commit exact changed paths as `feat: invoke Request handlers and Pages on refusal scopes`.

## Task 4: Replace refusal emitters with shared public application execution

**Files:** Create `lib/PAGI/Utils/_Refusal.pm`, `t/protocol-refusal-applications.t`, `t/lib/PAGITest/RefusalHarness.pm`; modify `lib/PAGI/WebSocket.pm`, `lib/PAGI/SSE.pm`, `t/websocket/denial-response.t`, `t/websocket/deny-close-code.t`, `t/sse/13-decline.t`, affected endpoint/refusal fixtures, and their immediate POD descriptions.

**Interfaces:** Private `run_refusal($helper, $target)` uses the helper's stored original scope/receive/send, accepts one Request callback or instantiated `to_app` object, and returns an observer Future resolving to that helper. Public `deny($target)` / `decline($target)` remain one-argument methods. `as_app_object` itself needs no runtime change.

- [ ] Add a compact test harness using `PAGI::Test::ConnectionState`. Its send callback records events and marks progress at event processing; terminal callbacks are deferred. Reuse the pattern in existing refusal tests, corrected where necessary:

```perl
my $send = sub {
    my ($event) = @_;
    local $connection->{_defer_notifications} = 1;
    push @sent, $event;
    $connection->_mark_response_started
        if $event->{type} eq 'http.response.start';
    $connection->_mark_complete
        if $event->{type} eq 'http.response.body' && !$event->{more};
    return Future->done;
};
```

These private mutations belong only to the Tools test server fixture. Production code reads public methods. For trailers and File/fh cases use the existing test client or extend the fixture to mark terminal at the actual final event; do not make the simple body condition above pretend to model all response forms. The fixture exposes stored scope/channels/events/connection and explicit terminal-notification delivery; it does not simulate server internals or timers.

- [ ] Add both-protocol dispatch tests for the eight spec forms: sync handler, async handler returning Pages, handler returning native app, direct buffered/File/Stream Response, direct Pages, custom to_app-only object, as_app_object native callback, and request_response with custom Request factory. Assert the original channels using `refaddr`, one handler argument, exactly-once to_app conversion, expected response events, and helper return identity.

```perl
my $method = $kind eq 'websocket' ? 'deny' : 'decline';
my $result = $helper->$method(sub {
    my ($request) = @_;
    is(scalar @_, 1, 'one Request argument');
    is($request->scope->{type}, $kind, 'native scope type');
    return PAGI::Response::text_response('Unavailable', status => 503);
})->get;
is(Scalar::Util::refaddr($result), Scalar::Util::refaddr($helper), 'fluent result');
```

Use a to_app object whose `_emit` dies as a regression proving the old cross-class boundary is gone. Also test an object with no `_emit`/`is_buffered`/`response_for` methods at all.

- [ ] Add supported lifetime cases: async handler pending; observer cancellation during handler/start/body work without cancelling worker/server sends; worker survives loss of caller references and early connection end; sequential pre-start recovery; post-start failure; terminal-before-start failure; no-output app return; partial-output return; repeated sequential refusal; SSE pending keepalive preserved before start and never armed after HTTP response start. Keep existing asynchronous on_close ownership tests. Do not add competing-call race tests or the withdrawn application-self-cancellation campaign.
- [ ] Add missing/invalid connection rejection for every target form, including buffered Responses. Capability validation happens before Request factories, handlers, or to_app calls. Check public methods actually required by admission/helper cleanup (`response_started`, `is_connected`, `on_end`, and the existing terminal accessors); do not test a particular server class. Diagnostics identify the missing capability and advertised spec version where available.
- [ ] Run `perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -l t/protocol-refusal-applications.t`; initially the Response-only guards should reject the new forms.
- [ ] Implement the coordinator using the existing adapter and invocation utility. The execution/retention spine after admission and shape validation is:

```perl
my $application = ref($target) eq 'CODE'
    ? PAGI::Routing::RequestResponse->new(handler => $target)
    : $target;
my $initial_phase = $helper->{_state};
$helper->{_state} = $scope->{type} eq 'websocket' ? 'denying' : 'declining';
my $worker = (async sub {
    await PAGI::Utils::invoke_app($application, $scope, $receive, $send);
    return $helper;
})->();
$worker->on_ready(sub {
    if ($connection->is_connected && !$connection->response_started) {
        $helper->{_state} = $initial_phase;
    } else {
        $helper->_refresh_connection;
    }
});
$worker->retain;
return $worker->without_cancel;
```

Keep strong ownership only until settlement; verify weak-reference release through meaningful lifetime tests. Do not add another normalization pass that calls the target's to_app twice. Fail shape/admission consistently; do not inspect its eventual response or buffer content. Do not catch an app error to invent a replacement response.

- [ ] Make each helper a thin caller into this path. Admission checks its allowed pre-accept/pre-start state and the public connection's live/unclaimed response facts. Remove `_require_connection_for_stream`, Response isa/is_buffered checks, `_emit` calls, observing-send closures, and refusal-only no-connection completion inference. Unrelated legacy accepted-stream behavior is not a cleanup target; remove additional branches only if needed for this coherent refusal path.
- [ ] Integrate sequential helper behavior using public progress. Keep terminal transitions in `_refresh_connection`/on_end. Reuse existing `denying`/`declining` phase names to identify invocation of a refusal, not to promise concurrency arbitration. Remove or derive refusal flags instead of storing an independent `$committed` truth. Read connection progress in that refusal phase; never infer refusal from `response_started` alone, because normal accept/start sets it too. In particular, a normal SSE start must retain and arm its pending keepalive. After HTTP refusal start, sequential protocol sends cannot reopen that response and deferred keepalive must not arm. Derive those decisions from progress plus the existing phase, without wrapping send. The settlement callback above restores the initial phase only while live and unstarted; it does not manufacture a terminal outcome.
- [ ] Update superseded tests and fixtures now: bare callbacks are valid; to_app-only objects are valid; finite refusal without a connection is invalid; repeated settled SSE decline is no longer idempotent success. Replace legacy streaming fixtures with current connection doubles that update progress while processing sends. Do not restore send interception to keep an inaccurate fixture green.
- [ ] Run:

```sh
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -lr t/protocol-refusal-applications.t t/websocket t/sse t/endpoint t/test t/test-client t/auth/04-protocol-integration.t t/response/15-cancel-connection.t
```

- [ ] Review the production diff against the stop conditions before committing. Commit as `refactor: delegate protocol refusals through public PAGI applications`.

## Task 5: Prove agreement with test clients and both real transports

**Files:** Extend `t/integration/protocol-refusal-stream-disconnect.t`, `t/integration/sse-decline-end-to-end.t`, `t/test/client-sse-decline.t`, and `t/test/client-ws-lifecycle.t`. Modify `lib/PAGI/Test/Client.pm`, `lib/PAGI/Test/SSE.pm`, or `lib/PAGI/Test/WebSocket.pm` only if a focused test demonstrates a missing spec-defined behavior needed by these scenarios; no speculative double rewrite.

**Interfaces:** Existing integration `transport($version, $type, $app, $logs)` remains the transport harness; extend it with an optional request-options hash for method/body/headers. Keep its four-argument call sites working within the same file. The test-client send/receive contract remains ordinary public PAGI behavior.

- [ ] Add direct Pages refusals on WS and SSE over HTTP/1.1 and HTTP/2. Example server application body:

```perl
my ($scope, $receive, $send) = @_;
my $class = $scope->{type} eq 'websocket' ? 'PAGI::WebSocket' : 'PAGI::SSE';
my $method = $scope->{type} eq 'websocket' ? 'deny' : 'decline';
my $helper = $class->new($scope, $receive, $send);
return await $helper->$method(PAGI::Pages->service_unavailable(
    detail => 'Scheduled maintenance', as => 'text',
));
```

Assert HTTP status/body, unchanged scope identity, no websocket.accept/sse.start, and once-only clean terminal callback. Add negotiated JSON with `Accept` advertising both SSE and problem JSON for SSE requests, or use the Pages policy to select JSON explicitly while keeping SSE request classification genuine.

- [ ] Add an SSE POST JSON-body handler on both transports. HTTP/1.1 sends Content-Type, Content-Length and real body bytes; HTTP/2 submits matching headers and DATA with END_STREAM for the request body. Expected request JSON `{ "job": 42 }` yields a JSON HTTP 503 containing job 42 through `$request->json`. This proves the server's native `sse.request` path, not a fake HTTP body.
- [ ] Keep the four parked-stream refusal/client-drop cases and three accepted-WebSocket close-truthfulness cases already in `protocol-refusal-stream-disconnect.t`. Exercise the new delegation path in the refusal cases. Do not weaken producer cancellation, Writer/helper release, once-only cleanup, peer close metadata, or uncancelled server-send assertions.
- [ ] Run the test-client comparison using the same application shapes. Continue asserting public status/body/reason/progress; no production-server fields or timeout values in outcome assertions. Existing test-server fixture methods are allowed in test setup.
- [ ] Run the real-server gate, retaining verbose output to distinguish execution from skips:

```sh
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -v -I /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server/.worktrees/feature-websocket-close-truthfulness/lib -l t/integration/protocol-refusal-stream-disconnect.t t/integration/sse-decline-end-to-end.t
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -lr t/test t/test-client t/protocol-refusal-applications.t
```

Expect new Pages/body cases plus all existing seven real-server cases to execute when optional dependencies are available. Local socket sandbox denial is an execution-environment issue: rerun with the required host permission rather than changing the test or treating it as a protocol defect. If a real contract mismatch appears, stop with the smallest reproducer; do not patch the server from this task.

- [ ] Commit verified test changes as `test: verify application refusals across PAGI transports`.

## Task 6: Make all six usage forms discoverable and executable

**Files:** Modify POD in `lib/PAGI/WebSocket.pm`, `lib/PAGI/SSE.pm`, `lib/PAGI/Request.pm`, `lib/PAGI/Routing/RequestResponse.pm`, `lib/PAGI/Pages.pm`, `lib/PAGI/Pages/Application.pm`, `lib/PAGI/Utils.pm`; update `lib/PAGI/Tools/Cookbook.pod`, `lib/PAGI/Tools/Tutorial.pod`, `Changes`. Create `examples/protocol-refusal/app.pl`, `examples/protocol-refusal/README.md`, `t/integration-protocol-refusal-example.t`; extend `t/00-pod/cookbook-examples.t` where it validates changed Cookbook examples.

**Interfaces:** Six example factories produce ordinary handler or application values; both websocket and sse routes exercise them on separate requests. No Auth dependency or new convenience API.

- [ ] Build one small example app using existing `PAGI::Routing`/Compose patterns. Expose `/ws/<form>` and `/events/<form>` for `response`, `handler`, `async-handler`, `pages`, `object`, and `native`. Each endpoint awaits its selected refusal and returns. Keep the custom object class complete in the example and use a labelled in-memory Future-returning notice service for the async case; no external service required.
- [ ] Use this public shape in the example's route handlers (with the necessary imports):

```perl
websocket('/ws/handler' => async sub {
    my ($ws) = @_;
    await $ws->deny(sub {
        my ($request) = @_;
        return json_response({error => 'Unavailable', path => $request->path}, status => 503);
    });
    return;
});
sse('/events/handler' => async sub {
    my ($sse) = @_;
    await $sse->decline(sub {
        my ($request) = @_;
        return json_response({error => 'Unavailable', path => $request->path}, status => 503);
    });
    return;
});
```

The response form demonstrates text and JSON across the two protocols; the Pages form demonstrates direct use and a handler returning Pages. The native example uses the complete application:

```perl
my $native = as_app_object(async sub {
    my ($scope, $receive, $send) = @_;
    await $send->({type => 'http.response.start', status => 503,
        headers => [['content-type', 'text/plain; charset=utf-8']]});
    await $send->({type => 'http.response.body', body => 'Scheduled maintenance', more => 0});
});
```

- [ ] Add an example test that loads the app using the existing example-test convention and calls all twelve routes through PAGI::Test::Client, checking HTTP response status/content and no accepted protocol. For Pages, verify HTML and JSON negotiation. Test real output rather than counting source-text tokens. Use Perl 5.18-compatible syntax in the example, so no version skip is needed.
- [ ] Write a maintained Cookbook section named `Refusing WebSocket and SSE with applications`, covering all six forms. Put basic Response and Request-handler examples directly in both methods' POD and link each to that section. Include imports, async context, one-request alternatives, code-position distinction, original scope/channel behavior, sequential usage, connection requirement, WS >=300 versus SSE 200/204, and returning after refusal.
- [ ] Replace the Utils POD's “narrow Route escape hatch” description with the exact approved wording in spec §15; add deny/decline call sites. Update Request/Pages supported-type statements and headers-container docs. Do not explain private coordinator details in application recipes.
- [ ] Audit maintained examples and docs using:

```sh
rg -n -- 'deny\(|decline\(|response_for\(|->_emit|concrete.*Response|HTTP scope|Hash::MultiValue' examples lib/PAGI/Tools lib/PAGI/WebSocket.pm lib/PAGI/SSE.pm lib/PAGI/Request.pm lib/PAGI/Pages.pm lib/PAGI/Pages/Application.pm lib/PAGI/Utils.pm README.md
```

Review every relevant hit. Remove mandatory materialization instructions; explicit response_for remains legal where intentionally desired. Existing Auth outcome snippets may pass their existing Pages objects directly, but do not alter Auth APIs or the authentication design. Preserve unrelated examples and historical plans. Record changed behavior in Changes without a version bump or compatibility layer.
- [ ] Run:

```sh
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -I /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server/.worktrees/feature-websocket-close-truthfulness/lib -l t/integration-protocol-refusal-example.t t/00-pod/cookbook-examples.t t/integration-maintained-examples-load.t t/integration-pages-example.t t/integration-starlette-apples.t t/auth/04-protocol-integration.t
perlbrew exec --with perl-5.42.2@default podchecker lib/PAGI/WebSocket.pm lib/PAGI/SSE.pm lib/PAGI/Request.pm lib/PAGI/Routing/RequestResponse.pm lib/PAGI/Pages.pm lib/PAGI/Pages/Application.pm lib/PAGI/Utils.pm lib/PAGI/Tools/Cookbook.pod lib/PAGI/Tools/Tutorial.pod
```

- [ ] Account explicitly for all six documentation forms, then commit exact changed paths as `docs: teach application-based WebSocket and SSE refusals`.

## Task 7: Final verification, review, and handoff

**Files:** Review all owned changes; create `docs/superpowers/plans/2026-09-18-protocol-refusal-applications-handoff.md` after results are known. No speculative release work.

- [ ] Run the complete Tools suite against the recorded server checkout:

```sh
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -I /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server/.worktrees/feature-websocket-close-truthfulness/lib -lr t
```

The previous handoff recorded 226 files / 2,583 tests; that is historical context, not the expected new count or evidence for this implementation. Record actual totals and every skip. The new multipart tests must run normally even if an unrelated existing release-only multipart test skips.

- [ ] Review exact changes from the implementation base:

```sh
git diff --check
git diff --stat e0f14366c1e7afffabfe87a14de2dcba14c89d63
git diff e0f14366c1e7afffabfe87a14de2dcba14c89d63 -- lib/PAGI/WebSocket.pm lib/PAGI/SSE.pm lib/PAGI/Utils/_Refusal.pm lib/PAGI/Request.pm lib/PAGI/Request/_BodyInput.pm
rg -n -- '->_emit|is_buffered|PAGI::Server|\{type\}.*=.*http' lib/PAGI/Utils/_Refusal.pm lib/PAGI/WebSocket.pm lib/PAGI/SSE.pm lib/PAGI/Pages.pm lib/PAGI/Pages/Application.pm
git status --short
```

Review search hits in context. No cross-class `_emit`, buffering dispatch, scope rewriting, or server dependency may remain in the refusal path. Do not ban legitimate Response internals or unrelated mentions with a blanket text assertion. Check library syntax against the declared Perl floor; running on 5.42 alone is not proof of minimum-version compatibility.

- [ ] Apply the requesting-code-review skill for final implementation review. Ask the reviewer to assess correctness and mergeability and identify blockers, not to confirm a predetermined conclusion. Focus on scope/channel identity, cleanup retention, all four body readers, header-cache access order, sequential recovery, server independence, and actual removal of duplicated refusal code. Do not reopen settled FAFO or compatibility choices without concrete contradictory evidence.
- [ ] Fix confirmed defects, rerunning only their relevant gates plus the full suite after runtime changes. If all checks already passed and no code changed, do not repeatedly rerun the same suite.
- [ ] Write the handoff with branch/commit IDs, actual test commands/results/skips, six-example documentation links, affected API behavior, and any real blockers. Explicitly distinguish verified H1/H2 cases from unavailable cases. State that no server/spec runtime implementation was changed and no push/merge/release occurred.
- [ ] Stage only the handoff and any final owned fixes; commit the handoff as `docs: hand off protocol refusal application redesign`. Leave unrelated worktree changes untouched.

## Stop conditions

Stop, show the smallest concrete failing case, and discuss before adding:

- send interception to reconstruct response progress;
- synthetic HTTP scope types, fabricated request-body events, or event replay;
- a receive watcher or concurrency/receive arbitration framework;
- a new cancellation policy or machinery for application self-cancellation;
- server-specific terminal inference, connection fields, or timeout assumptions;
- private Response emission calls or response-class/capability certification;
- old-server buffered-only fallback paths;
- a second Request-handler dispatch implementation;
- a multi-hook coordinator whose complexity exceeds the two helpers it replaces;
- server/spec changes or Auth redesign to make a Tools shortcut work.

A test fixture failing because it lacks required connection progress is a fixture correction, not grounds for a runtime fallback. A pre-existing unrelated failure is reported separately. A genuine missing public contract is a stop-and-discuss issue, not an invitation to patch another repository.

## Spec coverage and planning verification

| Spec requirement | Implementation task |
| --- | --- |
| Input/result grammar, exactly-once normalization, original triplet | 3, 4 |
| Shared PAGI::Headers cache | 1, 2 |
| HTTP/WS/SSE Request metadata and all body paths | 2 |
| Pages execution/materialization without scope spoofing | 3 |
| Current connection baseline, no private emitter, retained work | 4 |
| Sequential recovery/repeated calls; unsupported overlap | 4, 6 |
| Existing connection-owned cleanup and streamed refusal release | 4, 5 |
| Real transports and test-client agreement | 5, 7 |
| All six examples, both POD entry points, Utils and maintained docs | 6 |
| Scope boundaries, no compatibility/cancellation/concurrency expansion | Global constraints, 4, stop conditions |

This plan is based on source inspection and the recorded review decisions. Planning-time checks on 2026-09-18:

- The exact focused preflight command above passed: **6 files / 85 tests**. These test current behavior, not the proposed implementation.
- A load check resolved PAGI::Server from the recorded checkout and reported HTTP/2 available (`h2=1`); this proves dependency availability, not transport correctness.
- Local document links, task numbering, code-fence balance, placeholder scan, and shell-block syntax checks passed.

No runtime code or tests were changed while planning. Execution must record its own implementation results; the baseline can be reused if implementation starts against the same unchanged runtime tree and environment.
