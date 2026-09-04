# Remove the Mutable Router Frontends Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `PAGI::Routing` the sole routing-construction API, retain class behavior only at exact HTTP/WebSocket/SSE leaves, and remove both mutable Router frontends and their machinery.

**Architecture:** First repair the retained WebSocket/SSE endpoint lifecycle and make HTTP endpoint method capabilities authoritative at Route construction. Then migrate behavior-bearing examples and tests to immutable Route/Mount/Router/Compose topology before deleting `PAGI::App::Router`, `PAGI::Endpoint::Router`, their Builders, and the Materializer. Preserve configured immutable Router boundaries; ordinary application classes may expose `routes()` or `routing()`.

**Tech Stack:** Perl 5, Future::AsyncAwait, Test2::V0, PAGI, PAGI::Routing, PAGI::Compose, Dist::Zilla.

**Spec:** `docs/superpowers/specs/2026-09-02-remove-mutable-router-frontends-design.md`

## Global Constraints

- Repository: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools`.
- Ticket: none.
- Branch: `feature/remove-mutable-router-frontends`.
- Base: `b9cd32528a053190e9c560098f4323c78d7999bb`.
- Deployment boundary: unreleased PAGI-Tools distribution.
- Push target: remote branch and PR only after explicit authorization.
- No compatibility classes, forwarding aliases, string-to-method reflection, hidden materialization, endpoint cloning, or per-request/per-connection construction.
- Do not flatten an immutable Router that owns middleware, `http_default`, identity, description, or its own routing-outcome boundary.
- Endpoint objects may hold configuration and long-lived services, never request/connection-local mutable state.
- Finite explicit HTTP `methods` restrict an endpoint's `allowed_methods`; scalar `'*'` is the only bypass. WebSocket/SSE never inspect this capability.
- PAGI::Nano, PAGI, PAGI::Server, app-root framework design, and broader Response work are out of scope.
- Run focused tests per task. Run the complete suite once at final candidate HEAD, then one distribution build without rerunning tests.
- Stop if the implementation needs cloning, hidden caches, delayed construction, special Route/Mount cases, or repeated hacks.

---

## File Structure

| Area | Files | Responsibility |
|---|---|---|
| Endpoint lifecycle | `lib/PAGI/Endpoint/WebSocket.pm`, `SSE.pm`, `t/endpoint/*` | Resolve a class/instance once per `to_app` and retain identity. |
| HTTP method policy | `lib/PAGI/Routing/Route.pm`, routing/endpoint tests | Snapshot and validate `allowed_methods`; keep Router-owned PARTIAL/Allow behavior. |
| Endpoint examples | `examples/endpoint-demo/**`, renamed `endpoint-class-demo/**` | Demonstrate exact-leaf classes and ordinary immutable subtree assembly. |
| Other examples | chat, background-tasks, full-demo, all search hits | Replace mutable topology without changing behavior. |
| Behavioral tests | `t/app-router*`, `t/app-router/**`, `t/endpoint-router.t`, fixtures | Move reusable assertions to declarative APIs; delete grammar-only coverage. |
| Removed runtime | five frontend/Builder/Materializer modules | Eliminate duplicate APIs. |
| Public docs | API POD, Tutorial, Cookbook, UPGRADING, Changes, README, examples | Publish one construction model and complete migration guidance. |
| Tracking | `.superpowers/sdd/2026-09-02-remove-mutable-router-frontends/progress.md` | Task status, SHAs, real counts, verification, deviations. |

Stable final forms:

~~~perl
route('/messages' => MessageAPI->new);
websocket('/chat' => ChatEndpoint->new(hub => $hub));
sse('/events' => EventEndpoint->new(bus => $bus));

mount('/people',
    app  => MyApp::People->new(repo => $repo)->routing,
    name => 'people',
);

compose(routes => [route(...), mount(...)], lifespan => {...});
~~~

---

### Task 1: Reconfirm work map and baseline

**Files:**
- Create: `.superpowers/sdd/2026-09-02-remove-mutable-router-frontends/progress.md`

**Interfaces:**
- Produces: a 13-row audit ledger with status, commit, focused evidence, test count, and deviation columns.

- [ ] **Step 1: Verify branch/base**

Run:

~~~bash
git status -sb
git branch --show-current
git merge-base HEAD main
git rev-parse main
~~~

Expected: this branch; merge base and main equal the recorded base. If main moved, update the work map and re-evaluate conflicts before code.

- [ ] **Step 2: Create the ledger**

~~~markdown
# Mutable Router Frontend Removal Progress

| Task | Status | Commit | Focused verification | Tests | Deviation |
|---|---|---|---|---:|---|
| 1. Baseline | in progress | | | | |
| 2. WebSocket lifecycle | pending | | | | |
| 3. SSE lifecycle | pending | | | | |
| 4. HTTP method capability | pending | | | | |
| 5. Endpoint demo | pending | | | | |
| 6. Endpoint class demo | pending | | | | |
| 7. Endpoint fixtures | pending | | | | |
| 8. Chat examples | pending | | | | |
| 9. Remaining examples | pending | | | | |
| 10. Shared routing fixtures | pending | | | | |
| 11. Runtime removal | pending | | | | |
| 12. Public documentation | pending | | | | |
| 13. Final verification | pending | | | | |

## Deviations

No deviations.
~~~

- [ ] **Step 3: Run the focused baseline**

~~~bash
prove -lr t/endpoint t/routing t/endpoint-router.t t/app-router.t t/app-router-mount-routes.t t/app-router
~~~

Expected: PASS. Record exact file/test counts; diagnose any failure before implementation.

- [ ] **Step 4: Inventory references**

~~~bash
rg -l 'PAGI::(?:App|Endpoint)::Router|PAGI/(?:App|Endpoint)/Router|->to_router|middleware_as|app_as' lib t examples README.md UPGRADING.md Changes
~~~

Record the list in the ledger.

- [ ] **Step 5: Commit**

~~~bash
git add -f .superpowers/sdd/2026-09-02-remove-mutable-router-frontends/progress.md
git commit -m "chore: track mutable router removal"
~~~

---

### Task 2: Repair WebSocket endpoint lifecycle

**Files:**
- Modify: `lib/PAGI/Endpoint/WebSocket.pm`
- Modify: `t/endpoint/05-websocket-constructor.t`
- Modify: `t/endpoint/06-websocket-lifecycle.t`
- Modify: `t/endpoint/07-websocket-to-app.t`
- Modify: progress ledger

**Interfaces:**
- Produces: class `to_app` constructs once immediately; instance `to_app` retains that exact object.

- [ ] **Step 1: Add failing identity/count tests**

Create a configured subclass whose constructor counts calls and whose `on_connect` records `refaddr($self)`. Drive two complete connections:

~~~perl
my $configured = Local::ConfiguredWebSocket->new(hub => $hub);
my $app = $configured->to_app;

is $Local::ConfiguredWebSocket::NEW_CALLS, 1,
    'configured object was not reconstructed';
is \@Local::ConfiguredWebSocket::SEEN_IDS,
    [refaddr($configured), refaddr($configured)],
    'connections use the exact configured object';
~~~

Also assert `Local::ConfiguredWebSocket->to_app` constructs immediately once, two connections add no calls, and `websocket('/chat' => $configured)` works.

- [ ] **Step 2: Verify failure**

~~~bash
prove -lv t/endpoint/05-websocket-constructor.t t/endpoint/06-websocket-lifecycle.t t/endpoint/07-websocket-to-app.t
~~~

Expected: configured-instance blessing failure and/or per-connection count failure.

- [ ] **Step 3: Hoist receiver resolution**

~~~perl
use Scalar::Util qw(blessed);

sub to_app {
    my ($invocant) = @_;
    my $endpoint = blessed($invocant) ? $invocant : $invocant->new;

    return async sub {
        my ($scope, $receive, $send) = @_;
        # Keep existing scope validation/cache check/WebSocket construction.
        await Future->wrap($endpoint->handle($websocket));
        return;
    };
}
~~~

Do not clone or reconstruct the endpoint inside the closure.

- [ ] **Step 4: Document shared-instance/concurrency ownership**

Configuration and long-lived dependencies may live on the endpoint. Each protocol object and all connection-local state stay local to `handle`.

- [ ] **Step 5: Verify, update ledger, commit**

~~~bash
prove -lv t/endpoint/05-websocket-constructor.t t/endpoint/06-websocket-lifecycle.t t/endpoint/07-websocket-to-app.t
git add lib/PAGI/Endpoint/WebSocket.pm t/endpoint/05-websocket-constructor.t t/endpoint/06-websocket-lifecycle.t t/endpoint/07-websocket-to-app.t .superpowers/sdd/2026-09-02-remove-mutable-router-frontends/progress.md
git commit -m "fix: retain websocket endpoint instances"
~~~

Amend once to record the resulting SHA in the same ledger row.

---

### Task 3: Repair SSE endpoint lifecycle

**Files:**
- Modify: `lib/PAGI/Endpoint/SSE.pm`
- Modify: `t/endpoint/08-sse-constructor.t`, `09-sse-lifecycle.t`, `10-integration.t`, `10-sse-decline.t`
- Modify: progress ledger

**Interfaces:**
- Produces: same once-per-`to_app` receiver lifecycle, without changing decline, keepalive, disconnect, or settlement behavior.

- [ ] **Step 1: Add failing configured identity/count tests**

Mirror Task 2 with a configured SSE instance, two complete disconnecting streams, class construction count, and `sse('/events' => $configured)`.

- [ ] **Step 2: Verify failure**

~~~bash
prove -lv t/endpoint/08-sse-constructor.t t/endpoint/09-sse-lifecycle.t t/endpoint/10-integration.t t/endpoint/10-sse-decline.t
~~~

- [ ] **Step 3: Hoist receiver resolution**

Use the exact `blessed($invocant) ? $invocant : $invocant->new` rule before returning the async app. Keep `handle` and all settlement-streaming logic structurally unchanged.

- [ ] **Step 4: Document the same shared-instance rule**

- [ ] **Step 5: Verify, ledger, commit**

~~~bash
prove -lv t/endpoint/08-sse-constructor.t t/endpoint/09-sse-lifecycle.t t/endpoint/10-integration.t t/endpoint/10-sse-decline.t t/endpoint/14-sse-keepalive-ordering.t
git add lib/PAGI/Endpoint/SSE.pm t/endpoint/08-sse-constructor.t t/endpoint/09-sse-lifecycle.t t/endpoint/10-integration.t t/endpoint/10-sse-decline.t .superpowers/sdd/2026-09-02-remove-mutable-router-frontends/progress.md
git commit -m "fix: retain sse endpoint instances"
~~~

---

### Task 4: Enforce endpoint HTTP method capability at Route construction

**Files:**
- Modify: `lib/PAGI/Routing/Route.pm`
- Modify: `t/routing/01-constructors.t`, `t/routing/05-http-dispatch.t`, `t/routing/08-protocols.t`
- Modify: `t/endpoint/03-http-to-app.t`, `t/endpoint/04-http-options.t`
- Modify: progress ledger

**Interfaces:**
- Produces: one `allowed_methods` snapshot and finite explicit restriction validation.

- [ ] **Step 1: Add failing cases**

~~~perl
route('/x' => $endpoint);                         # snapshot once
route('/x' => $endpoint, methods => 'GET');       # valid scalar narrowing
route('/x' => $endpoint, methods => ['POST']);    # valid array narrowing
route('/x' => $endpoint, methods => ['DELETE']);  # construction error
route('/x' => $endpoint, methods => '*');         # no capability call
~~~

With capability `GET, POST, OPTIONS`, assert normalization `GET, HEAD, POST, OPTIONS`. Empty, invalid-token, wildcard-containing, and reference-valued results must name `route endpoint allowed_methods`. Unsupported explicit values must name both `methods` and `allowed_methods`. CODE handlers/objects without capability retain ordinary rules. WebSocket/SSE must never call it.

- [ ] **Step 2: Verify unsupported restriction currently fails the test**

~~~bash
prove -lv t/routing/01-constructors.t t/routing/05-http-dispatch.t t/routing/08-protocols.t t/endpoint/03-http-to-app.t t/endpoint/04-http-options.t
~~~

- [ ] **Step 3: Add explicit helpers**

~~~perl
sub _endpoint_allowed_methods {
    my ($endpoint) = @_;
    my @advertised = $endpoint->allowed_methods;
    return _normalize_methods(\@advertised, 'route endpoint allowed_methods');
}

sub _validate_method_restriction {
    my ($explicit, $advertised) = @_;
    my %advertised = map { $_ => 1 } @$advertised;
    my @unsupported = grep { !$advertised{$_} } @$explicit;
    croak "methods [@unsupported] are not advertised by route endpoint allowed_methods"
        if @unsupported;
    return $explicit;
}
~~~

In `_build`: scalar `'*'` bypasses lookup; finite explicit values normalize and validate against one snapshot; omitted methods use capability or GET+HEAD. Never inspect capability outside HTTP Route.

- [ ] **Step 4: Test Router-owned 405/Allow**

Sibling object routes at one path must produce Router PARTIAL with first-seen union, including endpoint-advertised OPTIONS. Standalone/mounted Endpoint::HTTP still owns its own OPTIONS/405.

- [ ] **Step 5: Verify, ledger, commit**

~~~bash
prove -lv t/routing/01-constructors.t t/routing/05-http-dispatch.t t/routing/08-protocols.t t/endpoint/03-http-to-app.t t/endpoint/04-http-options.t t/endpoint/10-integration.t
git add lib/PAGI/Routing/Route.pm t/routing/01-constructors.t t/routing/05-http-dispatch.t t/routing/08-protocols.t t/endpoint/03-http-to-app.t t/endpoint/04-http-options.t .superpowers/sdd/2026-09-02-remove-mutable-router-frontends/progress.md
git commit -m "feat: validate endpoint route methods"
~~~

---

### Task 5: Convert the compact endpoint demo

**Files:**
- Modify: `examples/endpoint-demo/app.pl`, `README.md`
- Modify: `t/integration-maintained-examples-load.t`
- Modify: progress ledger

**Interfaces:**
- Produces: direct declarative HTTP/WS/SSE endpoint-object example.

- [ ] **Step 1: Add final-shape assertions**

Reject mutable Router imports/manual endpoint `to_app`; require `route`, `websocket`, `sse`, and retained leaf middleware.

- [ ] **Step 2: Verify failure**

~~~bash
prove -lv t/integration-maintained-examples-load.t
~~~

- [ ] **Step 3: Replace final assembly**

Keep endpoint and middleware bodies unchanged:

~~~perl
use PAGI::Routing qw(middleware mount route sse websocket);

compose(routes => [
    route('/api/messages' => MessageAPI->new,
        middleware => [middleware($access_log), middleware($require_json)]),
    websocket('/ws/echo' => EchoWS->new,
        middleware => [middleware($access_log), middleware($timing)]),
    sse('/events' => MessageEvents->new,
        middleware => [middleware($timing)]),
    mount('/' => app => PAGI::App::File->from_app_path('public')),
]);
~~~

Remove App Router, `$router`, manual `to_app`, and redundant root Mount.

- [ ] **Step 4: Update README, verify, commit**

~~~bash
prove -lv t/integration-maintained-examples-load.t t/endpoint/10-integration.t
git add examples/endpoint-demo t/integration-maintained-examples-load.t .superpowers/sdd/2026-09-02-remove-mutable-router-frontends/progress.md
git commit -m "docs: make endpoint demo declarative"
~~~

---

### Task 6: Replace Endpoint Router demo with endpoint-class demo

**Files:**
- Rename: `examples/endpoint-router-demo/` to `examples/endpoint-class-demo/`
- Rename: `t/integration-endpoint-router-demo.t` to `t/integration-endpoint-class-demo.t`
- Create: `examples/endpoint-class-demo/lib/MyApp/API/User.pm`
- Create: `examples/endpoint-class-demo/lib/MyApp/StatusSocket.pm`
- Modify: all renamed app modules, entrypoint, README, integration test
- Modify: progress ledger

**Interfaces:**
- Produces: ordinary `MyApp::Main->routes`, reusable `MyApp::API->routing`, configured exact-leaf endpoint objects.

- [ ] **Step 1: Rename and add final-shape assertions**

Reject inheritance from Endpoint Router, `to_router`, string targets, `middleware_as`, and `app_as`; preserve custom API 404, names, middleware, state, HTTP, WS, and SSE behavior.

- [ ] **Step 2: Verify old construction fails new assertions**

~~~bash
prove -lv t/integration-endpoint-class-demo.t
~~~

- [ ] **Step 3: Make Main an ordinary assembler**

~~~perl
sub routes ($self) {
    return [
        route('/' => sub ($request) { $self->home($request) }, name => 'home'),
        mount('/api', app => $self->{api}->routing, name => 'api'),
        websocket('/status' => MyApp::StatusSocket->new, name => 'status_socket'),
        mount('/' => app => PAGI::App::File->from_app_path('public')),
    ];
}
~~~

Move the status WebSocket behavior into `MyApp::StatusSocket`; keep connection-local state on the protocol object.

- [ ] **Step 4: Make API an immutable subtree**

~~~perl
sub routing ($self) {
    return router(
        http_default => not_found(detail => 'No API endpoint route matched'),
        routes => [
            route('/index' => sub ($r) { $self->index($r) },
                name => 'index',
                middleware => [middleware(sub ($inner) {
                    return $self->require_demo_token($inner);
                })]),
            route('/show/{user_id:&Int}' =>
                MyApp::API::User->new(users => $self->{users}),
                name => 'show',
                middleware => [middleware(sub ($inner) {
                    return $self->require_demo_token($inner);
                })]),
            mount('/tools', routes => [
                route('/status' => sub ($r) { $self->status($r) }, name => 'status'),
            ], name => 'tools'),
            mount('/events', routes => [
                sse('/stream' => $self->{events}, name => 'stream'),
            ], name => 'events'),
        ],
    );
}
~~~

Import/define `Int` in the declaring package. `require_demo_token` returns the existing native middleware factory. `User` subclasses Endpoint::HTTP and implements the former show behavior. Convert `MyApp::API::Events` from an Endpoint Router into an Endpoint::SSE leaf and preserve its effective `/api/events/stream` path and `/api/events/stream` logical address through the named Mount and leaf above.

- [ ] **Step 5: Compose root with exact state**

~~~perl
my @users = (
    { id => 1, name => 'Alice' },
    { id => 2, name => 'Bob' },
);
my $events = MyApp::API::Events->new;
my $api = MyApp::API->new(events => $events, users => \@users);
my $main = MyApp::Main->new(api => $api);

compose(
    routes => $main->routes,
    lifespan => {
        startup => sub ($state) {
            $state->{resource} = { name => 'demo-resource', open => 1 };
            $state->{metrics} = { requests => 0, websocket_messages => 0 };
        },
        shutdown => sub ($state) {
            $state->{resource}{open} = 0;
            $state->{resource}{closed} = 1;
        },
    },
);
~~~

- [ ] **Step 6: Test direct `PAGI::Utils::app_path` ownership**

Call the exported helper in the asset-owning module, never through an inherited endpoint wrapper. Assert resolution from that module's `lib` root.

- [ ] **Step 7: Verify and commit**

~~~bash
prove -lv t/integration-endpoint-class-demo.t t/integration-maintained-examples-load.t t/endpoint/10-integration.t
git add -A examples/endpoint-router-demo examples/endpoint-class-demo t/integration-endpoint-router-demo.t t/integration-endpoint-class-demo.t .superpowers/sdd/2026-09-02-remove-mutable-router-frontends/progress.md
git commit -m "docs: replace endpoint router demo with endpoint classes"
~~~

---

### Task 7: Transfer Endpoint Router behavior coverage

**Files:**
- Modify: `t/endpoint/10-integration.t`, `t/router-middleware.t`, `t/router-named-routes.t`, `t/integration/sse-decline-end-to-end.t`
- Delete after transfer: `t/endpoint-router.t`, `t/endpoint/12-route-middleware.t`, `t/endpoint/13-router-frontends.t`
- Replace/delete: `t/lib/TestApps/AppPath/Endpoint.pm`
- Modify: progress ledger

**Interfaces:**
- Produces: declarative coverage of all reusable behavior; removes only frontend grammar tests.

- [ ] **Step 1: Classify each old subtest**

Label as grammar-only or reusable: middleware ordering, bound-method closures, native adapters, nested names, app-path origin, SSE decline, protocol dispatch.

- [ ] **Step 2: Add declarative equivalents before deletion**

~~~perl
route('/private' => sub ($request) { $object->private($request) },
    middleware => [middleware(sub ($inner) {
        return $object->require_auth($inner);
    })],
);
mount('/nested', app => $object->routing, name => 'nested');
~~~

- [ ] **Step 3: Run old and new coverage together**

~~~bash
prove -lv t/endpoint/10-integration.t t/router-middleware.t t/router-named-routes.t t/integration/sse-decline-end-to-end.t t/endpoint-router.t t/endpoint/12-route-middleware.t t/endpoint/13-router-frontends.t
~~~

- [ ] **Step 4: Delete grammar-only files, then verify/commit**

~~~bash
prove -lv t/endpoint t/router-middleware.t t/router-named-routes.t t/integration/sse-decline-end-to-end.t t/integration-endpoint-class-demo.t
git add -A t/endpoint-router.t t/endpoint t/router-middleware.t t/router-named-routes.t t/integration t/lib/TestApps .superpowers/sdd/2026-09-02-remove-mutable-router-frontends/progress.md
git commit -m "test: move endpoint router coverage to declarative routing"
~~~

---

### Task 8: Convert the mutable chat application

**Files:**
- Modify: `examples/10-chat-showcase/**`
- Modify: `t/integration-chat-compose.t`
- Modify: progress ledger

**Interfaces:**
- Produces: direct protocol routing while preserving lifespan, state, backpressure, disconnect, and static fallback.

- [ ] **Step 1: Add assertions rejecting mutable roots and requiring direct protocol nodes**

- [ ] **Step 2: Convert the root**

Retain existing lifespan bodies verbatim:

~~~perl
compose(
    routes => [
        websocket('/ws/chat' => as_app($ws_handler)),
        sse('/events' => as_app($sse_handler)),
        route('/*path' => as_app($http_handler), methods => '*'),
    ],
    middleware => [middleware(\&with_logging)],
    lifespan => {
        startup => async sub {
            say STDERR '[lifespan] Application starting up...';
            my $stats = get_stats();
            say STDERR "[lifespan] Initialized with $stats->{rooms_count} default rooms";
        },
        shutdown => async sub {
            say STDERR '[lifespan] Application shutting down...';
            my $stats = get_stats();
            say STDERR "[lifespan] Final stats: $stats->{users_online} users, $stats->{messages_total} messages";
        },
    },
);
~~~

Keep `as_app` for each native triplet coderef at Route. `examples/websocket-chat-v2` does not use either removed frontend and is not refactored by this task.

- [ ] **Step 3: Convert ChatApp::HTTP**

Move existing bodies unchanged into declarative `route(...)` nodes inside Compose or immutable Router. Preserve ordering and event flow before cleaning imports.

- [ ] **Step 4: Verify and commit**

~~~bash
prove -lv t/integration-chat-compose.t t/integration/sse-decline-end-to-end.t t/routing/08-protocols.t t/sse-router-support.t
git add examples/10-chat-showcase t/integration-chat-compose.t .superpowers/sdd/2026-09-02-remove-mutable-router-frontends/progress.md
git commit -m "docs: convert chat apps to declarative routing"
~~~

---

### Task 9: Convert remaining examples and audit apples

**Files:**
- Modify: `examples/background-tasks/**`, `examples/full-demo/**`, any other live inventory hit
- Modify: `examples/README.md`, relevant integration tests, progress ledger

**Interfaces:**
- Produces: zero mutable frontend use under examples; apples remains the style canary.

- [ ] **Step 1: Add load/behavior/negative-source assertions for each affected example**

- [ ] **Step 2: Verify pre-conversion failure**

~~~bash
prove -lv t/integration-maintained-examples-load.t t/integration-app-file-examples.t
~~~

- [ ] **Step 3: Translate literally in declaration order**

~~~perl
$r->get($p => $h)       # route($p => $h)
$r->post($p => $h)      # route($p => $h, methods => ['POST'])
$r->websocket($p => $h) # websocket($p => $h)
$r->sse($p => $h)       # sse($p => $h)
$r->mount($p, app=>$a)  # mount($p, app => $a)
~~~

Native triplet coderef: `as_app($native)` at Route or pass directly to Mount. Do not flatten configured Router boundaries.

- [ ] **Step 4: Audit apples**

~~~bash
rg -n 'PAGI::(?:App|Endpoint)::Router|to_router|middleware_as|app_as' examples/starlette-apples
rg -l 'starlette-apples' t
~~~

Run the discovered apple integration test; expect no forbidden hits and PASS.

- [ ] **Step 5: Verify and commit**

~~~bash
prove -lv t/integration-maintained-examples-load.t t/integration-app-file-examples.t t/integration-chat-compose.t
git add examples t/integration-maintained-examples-load.t t/integration-app-file-examples.t .superpowers/sdd/2026-09-02-remove-mutable-router-frontends/progress.md
git commit -m "docs: finish declarative example migration"
~~~

---

### Task 10: Transfer App Router behavior coverage

**Files:**
- Modify: `t/routing/05-http-dispatch.t`, `t/integration-router-application-boundaries.t`, `t/lib/TestRoutes/**`
- Delete after transfer: `t/app-router.t`, `t/app-router-mount-routes.t`, `t/app-router/**`, `t/app/03-router.t`
- Modify: progress ledger

**Interfaces:**
- Produces: declarative coverage for route order, FULL/PARTIAL/NONE, middleware, Mount, URLs, metadata, and configured boundaries.

- [ ] **Step 1: Classify old assertions**

Retain declaration/HEAD order, Allow union, constraints, middleware order, nested names, metadata, configured Router boundaries. Drop fluent verbs/modifiers, mutable snapshots, and mutable-cycle machinery.

- [ ] **Step 2: Add declarative equivalents**

~~~perl
router(routes => [
    route('/same' => \&head, methods => ['HEAD'], name => 'head'),
    route('/same' => \&get,  methods => ['GET'],  name => 'get'),
]);
~~~

Include a configured child Router proving Mount preserves middleware, `http_default`, metadata, boundary outcomes, and reverse discovery.

- [ ] **Step 3: Run old/new tests together**

~~~bash
prove -lv t/app-router.t t/app-router-mount-routes.t t/app-router t/app/03-router.t t/routing/05-http-dispatch.t t/integration-router-application-boundaries.t
~~~

- [ ] **Step 4: Delete grammar-only tests, convert fixtures, verify/commit**

~~~bash
prove -lv t/routing t/integration-router-application-boundaries.t t/router-middleware.t t/router-named-routes.t
git add -A t/app-router.t t/app-router t/app/03-router.t t/app-router-mount-routes.t t/routing t/integration-router-application-boundaries.t t/lib/TestRoutes .superpowers/sdd/2026-09-02-remove-mutable-router-frontends/progress.md
git commit -m "test: move app router coverage to declarative routing"
~~~

---

### Task 11: Remove both frontends and machinery

**Files:**
- Delete: `lib/PAGI/App/Router.pm`, `Builder.pm`, `Materializer.pm`
- Delete: `lib/PAGI/Endpoint/Router.pm`, `Builder.pm`
- Create: `t/router-frontend-removal.t`
- Modify: `t/00-load.t`, remaining live library references, progress ledger

**Interfaces:**
- Produces: no loadable compatibility surface.

- [ ] **Step 1: Create removal test**

~~~perl
use strict;
use warnings;
use Test2::V0;

my @removed = qw(
    PAGI/App/Router.pm
    PAGI/App/Router/Builder.pm
    PAGI/App/Router/Materializer.pm
    PAGI/Endpoint/Router.pm
    PAGI/Endpoint/Router/Builder.pm
);

for my $module (@removed) {
    ok !-e "lib/$module", "$module is absent";
    local @INC = ('lib');
    my $loaded = eval { require $module; 1 };
    ok !$loaded, "$module cannot load from source";
}
done_testing;
~~~

- [ ] **Step 2: Delete the five files; remove load/library references**

No stubs, aliases, warnings, or renamed copies.

- [ ] **Step 3: Verify**

~~~bash
prove -lv t/router-frontend-removal.t t/00-load.t t/routing t/endpoint
rg -n 'PAGI::App::Router|PAGI/App/Router|PAGI::Endpoint::Router|PAGI/Endpoint/Router|Endpoint::Router::Builder|App::Router::Builder|App::Router::Materializer|->to_router|middleware_as|app_as' lib t examples README.md UPGRADING.md Changes
~~~

Only negative assertions and future labelled UPGRADING Before examples may remain.

- [ ] **Step 4: Commit**

~~~bash
git add -A lib/PAGI/App/Router.pm lib/PAGI/App/Router lib/PAGI/Endpoint/Router.pm lib/PAGI/Endpoint/Router t/00-load.t t/router-frontend-removal.t .superpowers/sdd/2026-09-02-remove-mutable-router-frontends/progress.md
git commit -m "refactor: remove mutable router frontends"
~~~

---

### Task 12: Rewrite public documentation and upgrading guidance

**Files:**
- Modify: `lib/PAGI/Tools.pm`, `Routing.pm`, Route/Mount/Router POD, `Compose.pm`
- Modify: retained Endpoint POD, `Lifespan.pm`, `Request.pm`, Tutorial, Cookbook
- Modify: `UPGRADING.md`, `Changes`, example READMEs, generated `README.md`
- Modify: POD/upgrading tests, progress ledger

**Interfaces:**
- Produces: one public topology model and complete before/after migration guide.

- [ ] **Step 1: Add failing doc assertions**

Require representative `route`, `mount`, `router`, `websocket`, `sse`, endpoint-object, `routing()`, and direct Compose examples. Reject live recommendations of removed modules.

- [ ] **Step 2: Verify failure**

~~~bash
prove -lv t/00-pod/cookbook-examples.t t/upgrading-router-frontends.t t/upgrading-routing-composition.t
~~~

- [ ] **Step 3: Rewrite overview/API docs**

Communicate this boundary:

~~~text
Endpoint::HTTP/WebSocket/SSE  optional behavior for one exact route
Route                         exact path and HTTP method policy
Mount                         prefix ownership and app composition
Router                        ordered children and NONE/PARTIAL outcomes
Compose                       root lifespan, middleware, and safety
~~~

Document shared endpoint lifecycle/concurrency; finite method restriction; one-time capability snapshot; OPTIONS/Allow ownership; `'*'` bypass; and direct `PAGI::Utils::app_path` placement.

- [ ] **Step 4: Write complete Before/After upgrade sections**

Cover App Router verbs/modifiers/middleware/mounts/protocols/defaults/descriptions/names and Endpoint Router `routes`, strings, `to_router`, `middleware_as`, `app_as`, `new_request`, `app_path`. Explain closure versus leaf class, configured WS/SSE fix, method validation, and no compatibility layer.

- [ ] **Step 5: Update Changes/example READMEs and source POD for the root README**

Do not build here. Task 13's candidate build runs the configured `ReadmeAnyFromPod` plugins; stage the resulting root `README.md` there and verify it follows source POD.

- [ ] **Step 6: Verify and commit**

~~~bash
prove -lv t/00-pod/cookbook-examples.t t/upgrading-router-frontends.t t/upgrading-routing-composition.t t/upgrading-request-first-handlers.t
git diff --check
git add lib README.md UPGRADING.md Changes examples/README.md examples/*/README.md t/00-pod/cookbook-examples.t t/upgrading-router-frontends.t t/upgrading-routing-composition.t .superpowers/sdd/2026-09-02-remove-mutable-router-frontends/progress.md
git commit -m "docs: document declarative-only routing"
~~~

---

### Task 13: Final audit, verification, and review

**Files:**
- Modify: progress ledger
- Modify only files required by verified defects found here

**Interfaces:**
- Produces: review-ready candidate and evidence that source, docs, examples, tests, and archive agree.

- [ ] **Step 1: Audit forbidden/live DSL surfaces**

~~~bash
rg -n 'PAGI::App::Router|PAGI/App/Router|PAGI::Endpoint::Router|PAGI/Endpoint/Router|Endpoint::Router::Builder|App::Router::Builder|App::Router::Materializer|->to_router|middleware_as|app_as' lib t examples README.md UPGRADING.md Changes
rg -n -- '->(?:get|post|put|patch|delete|head|options|websocket|sse)\(' lib t examples README.md UPGRADING.md Changes
~~~

Inspect every hit: only labelled UPGRADING Before examples, negative assertions, and legitimate endpoint verb methods survive.

- [ ] **Step 2: Run final focused gates**

~~~bash
prove -lr t/endpoint t/routing t/integration-maintained-examples-load.t t/integration-endpoint-class-demo.t t/integration-chat-compose.t t/integration-router-application-boundaries.t t/router-frontend-removal.t t/00-pod/cookbook-examples.t
~~~

Expected: PASS; record exact counts.

- [ ] **Step 3: Run complete suite once at candidate HEAD**

~~~bash
prove -lr t
~~~

Expected: PASS. If it fails, diagnose, fix, rerun relevant focused tests, then rerun the whole suite only after candidate changes.

- [ ] **Step 4: Build once without test rerun and verify the archive**

Run:

~~~bash
dzil build
archive=$(ls -t PAGI-Tools-*.tar.gz | head -1)
tar tf "$archive" | rg 'lib/PAGI/Endpoint/(HTTP|WebSocket|SSE)\.pm'
if tar tf "$archive" | rg 'lib/PAGI/(App/Router|Endpoint/Router)'; then exit 1; fi
git diff -- README.md
~~~

Expected: all three retained Endpoint classes are present, none of the five removed modules is present, and the generated root README matches the source POD changes from Task 12.

- [ ] **Step 5: Request code review**

Use `superpowers:requesting-code-review`; check implementation against the spec, this plan, stop conditions, ledger, and diff. Fix verified issues with focused tests.

- [ ] **Step 6: Close ledger and commit final evidence**

~~~bash
git diff --check
git status -sb
git add README.md
git add -f .superpowers/sdd/2026-09-02-remove-mutable-router-frontends/progress.md
git commit -m "chore: record router removal verification"
~~~

Do not push or open a PR without explicit authorization.
