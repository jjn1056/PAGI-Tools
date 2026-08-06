# Bare Middleware Factory Shorthand Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let every immutable declarative `middleware => [...]` list accept a bare synchronous middleware factory coderef as shorthand for `middleware($factory)`, while preserving homogeneous middleware descriptions, introspection, compilation freshness, ordering, and compatibility boundaries.

**Architecture:** `PAGI::Routing::Middleware` gains one private construction-time list normalizer. `PAGI::Routing::Route`, `PAGI::Routing::Mount`, `PAGI::Routing::Router`, and `PAGI::Compose` call it once and store only `PAGI::Routing::Middleware` descriptions. The routing and Compose compilers remain strict and unchanged. Documentation teaches bare factories as the ordinary inline form and retains `middleware()` as the explicit immutable-description constructor for configured classes, configured objects, reuse, and inspection.

**Tech Stack:** Perl 5.18-compatible source, `Future`, `Future::AsyncAwait`, existing pure PAGI event middleware, `Test2::V0`, `PAGI::Test::Client`, POD, and Dist::Zilla; no new distribution dependency.

## Global Constraints

- Implement the approved contract in `docs/superpowers/specs/2026-08-06-middleware-coderef-shorthand-design.md`. A conflict with that design is a deviation, not an invitation to guess.
- Keep library source compatible with Perl 5.18: no signatures, no post-5.18 syntax, no `Moo`/`Moose`, and no new CPAN dependency.
- Accept exactly two direct list-entry shapes: a bare `CODE` reference or an object that is a `PAGI::Routing::Middleware` description/subclass. Class strings, arrays, hashes, arbitrary scalars, and configured objects remain explicit through `middleware(...)`.
- Normalize only while constructing the immutable description. Never invoke the factory, construct a middleware class, wrap an app, or emit protocol events during normalization.
- Preserve explicit description identity. Create a fresh base description for each bare-factory occurrence, including repeated occurrences of the same coderef. Preserve the original factory coderef identity inside each generated description.
- Keep constructor input arrays and middleware accessor arrays defensively copied. Accessors must always expose homogeneous description objects, never the caller's mixed list.
- Keep `PAGI::Routing::Middleware->_wrap_descriptors`, `PAGI::Routing::Compiler`, and `PAGI::Compose::Compiler` strict and behaviorally unchanged. The first listed middleware remains outermost; each `to_app` builds fresh wrapper instances; invalid and async factory results still fail synchronously at compilation.
- Apply the shorthand to all seven public positions: Compose, Router, HTTP Route, WebSocket Route, SSE Route, opaque application Mount, and inline subtree Mount.
- Do not change `PAGI::App::Router`, `PAGI::Endpoint::Router`, or `PAGI::Middleware::Builder`. In particular, Endpoint route middleware remains the shipped value-flow `$next` API and continues rejecting pure event-middleware coderefs.
- Do not add a public coercion API, a tuple/hash configuration mini-language, verb constructors, or a deprecation/rename of `middleware()`.
- Convert `examples/10-chat-showcase` incrementally: retain `PAGI::App::Router` and every HTTP/WebSocket/SSE route, but use `PAGI::Compose` for application middleware and startup/shutdown ownership.
- Use test-driven development for every behavior change: establish the intended red failure, make the smallest implementation, then run the focused and required regression suites.
- Stage only the named files in each task. Never use `git add -A`, and never stage `.cpan-testers-fix-report.md`, `.csrf-helper-brief.md`, or `.csrf-helper-report.md`; those are unrelated user files.
- After every task commit, complete the execution skill's review gate and update the task ledger with actual commit SHAs, commands, real test counts, and review evidence. Never record estimated counts.

## Execution Tracking and Deviation Control

Before Task 1, create the plan-scoped workspace with the `sdd-workspace` script bundled with `superpowers:subagent-driven-development`:

```bash
/Users/jnapiorkowski/.codex/plugins/cache/openai-curated-remote/superpowers/6.2.0/skills/subagent-driven-development/scripts/sdd-workspace docs/superpowers/plans/2026-08-06-middleware-coderef-shorthand.md
```

The command must print a directory ending in `.superpowers/sdd/2026-08-06-middleware-coderef-shorthand`. Create its `progress.md` with this exact first line and tables:

```markdown
# SDD ledger — plan: docs/superpowers/plans/2026-08-06-middleware-coderef-shorthand.md

| Task | Status | Commit range | Focused verification | Full-suite verification | Review |
|---|---|---|---|---|---|
| 1 | pending | — | — | — | — |
| 2 | pending | — | — | — | — |
| 3 | pending | — | — | — | — |
| 4 | pending | — | — | — | — |
| 5 | pending | — | — | — | — |
| 6 | pending | — | — | — | — |

## Deviations

| ID | Status | Conflicting plan text | Evidence and rationale | Affected tasks | User decision |
|---|---|---|---|---|---|
```

The coordinator, not an individual task implementer, owns the ledger. A discovered contract conflict gets the next ID (`D-001`, `D-002`, and so on), status `awaiting decision`, the exact conflicting text, concrete evidence, affected/dependent tasks, and no inferred approval. Stop those tasks until the user decides, then record the decision before continuing. Ordinary defects that preserve the approved behavior are fixed within the owning task and are not deviations.

Use this Perl environment for every test, POD, and packaging command:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t/'
```

---

### Task 1: Add the Shared Construction-Time Normalizer

**Files:**
- Modify: `lib/PAGI/Routing/Middleware.pm`
- Modify: `t/routing/04-middleware-descriptors.t`

**Interfaces:**
- Produces private `PAGI::Routing::Middleware->_normalize_descriptors($entries, $error_prefix)`.
- Returns a new arrayref containing only `PAGI::Routing::Middleware` descriptions.
- Preserves explicit descriptions/subclasses by identity and turns each bare coderef occurrence into a fresh base description.
- Does not relax `_wrap_descriptors`; compilation still consumes description objects only.

- [ ] **Step 1: Add direct failing normalization tests**

In `t/routing/04-middleware-descriptors.t`, add a subclass fixture after the imports:

```perl
{
    package DescriptorMiddlewareSubclass;
    our @ISA = ('PAGI::Routing::Middleware');
}
```

Add these subtests before the existing production-fold tests:

```perl
subtest 'declarative lists normalize bare factories to descriptions' => sub {
    my $factory = sub { return $_[0] };
    my $explicit = middleware('Configured', enabled => 1);
    my $subclass = DescriptorMiddlewareSubclass->new(sub { return $_[0] });
    my $input = [$factory, $explicit, $factory, $subclass];

    my $normalized = PAGI::Routing::Middleware->_normalize_descriptors(
        $input,
        'middleware',
    );

    isnt(refaddr($normalized), refaddr($input), 'top-level input array is copied');
    isa_ok($normalized->[0], 'PAGI::Routing::Middleware');
    isa_ok($normalized->[2], 'PAGI::Routing::Middleware');
    is(refaddr($normalized->[0]->factory), refaddr($factory),
        'first generated description retains factory identity');
    is(refaddr($normalized->[2]->factory), refaddr($factory),
        'repeated occurrence retains the same factory identity');
    isnt(refaddr($normalized->[0]), refaddr($normalized->[2]),
        'repeated occurrences receive distinct descriptions');
    is(refaddr($normalized->[1]), refaddr($explicit),
        'explicit base description is preserved by identity');
    is(refaddr($normalized->[3]), refaddr($subclass),
        'explicit subclass description is preserved by identity');

    push @$input, middleware('LateMutation');
    is(scalar @$normalized, 4, 'later input mutation is invisible');
};

subtest 'normalization accepts only descriptions and coderef factories' => sub {
    is(
        PAGI::Routing::Middleware->_normalize_descriptors([], 'middleware'),
        [],
        'empty list normalizes to a fresh empty list',
    );
    like(
        dies {
            PAGI::Routing::Middleware->_normalize_descriptors({}, 'compose middleware')
        },
        qr/compose middleware must be an arrayref/,
        'caller prefix is retained for a non-array value',
    );

    my $configured = bless {}, 'DescriptorConfiguredObject';
    for my $invalid ('GZip', [], {}, 42, $configured) {
        like(
            dies {
                PAGI::Routing::Middleware->_normalize_descriptors(
                    [$invalid],
                    'middleware',
                )
            },
            qr/middleware must contain PAGI::Routing::Middleware descriptions or coderef factories/,
            'unsupported direct entry is rejected',
        );
    }
};
```

The configured object deliberately has `wrap` later in the test package. It is valid inside `middleware($configured)` but invalid as a direct declarative-list entry.

- [ ] **Step 2: Run the focused test and confirm the missing helper is the failure**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/04-middleware-descriptors.t'
```

Expected: FAIL because `_normalize_descriptors` does not exist. Existing descriptor wrapping assertions should remain green.

- [ ] **Step 3: Implement the private normalizer without touching compilation**

Add this method before `_wrap_descriptors` in `lib/PAGI/Routing/Middleware.pm`:

```perl
sub _normalize_descriptors {
    my ($class, $entries, $error_prefix) = @_;
    $error_prefix = 'middleware' unless defined $error_prefix;

    croak "$error_prefix must be an arrayref"
        unless ref($entries) eq 'ARRAY';

    my @normalized;
    for my $entry (@$entries) {
        if (ref($entry) eq 'CODE') {
            push @normalized, PAGI::Routing::Middleware->new($entry);
            next;
        }
        if (blessed($entry)
                && $entry->isa('PAGI::Routing::Middleware')) {
            push @normalized, $entry;
            next;
        }
        croak "$error_prefix must contain PAGI::Routing::Middleware "
            . 'descriptions or coderef factories';
    }

    return \@normalized;
}
```

Do not edit `_wrap`, `_wrap_descriptors`, `_resolve_class`, or `_validate_wrapped_app`.

- [ ] **Step 4: Run the helper and existing descriptor suites green**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/01-constructors.t t/routing/04-middleware-descriptors.t'
```

Expected: PASS. The public constructors still reject bare factories at this checkpoint; only the shared primitive exists.

- [ ] **Step 5: Verify the diff is private and commit**

```bash
git diff --check
git diff -- lib/PAGI/Routing/Middleware.pm t/routing/04-middleware-descriptors.t
git add lib/PAGI/Routing/Middleware.pm t/routing/04-middleware-descriptors.t
git commit -m "refactor: normalize declarative middleware lists"
```

Update Task 1's ledger row with the commit SHA, focused command/count, and review result.

---

### Task 2: Accept Bare Factories Throughout Declarative Routing

**Files:**
- Modify: `lib/PAGI/Routing/Route.pm`
- Modify: `lib/PAGI/Routing/Mount.pm`
- Modify: `lib/PAGI/Routing/Router.pm`
- Modify: `t/routing/01-constructors.t`
- Create: `t/routing/11-bare-middleware.t`

**Interfaces:**
- Adds the shorthand to Router, HTTP Route, WebSocket Route, SSE Route, opaque Mount, and inline Mount.
- Stores only normalized descriptions, so `PAGI::Routing::Compiler` remains unchanged.
- Preserves route/mount/router boundary placement, protocol behavior, generated-outcome coverage, and fresh `to_app` compilation.

- [ ] **Step 1: Change constructor tests from rejection to all-position normalization**

In `t/routing/01-constructors.t`, add a package fixture:

```perl
{
    package BareListConfiguredObject;
    sub wrap { return $_[1] }
}
```

Add this subtest before `constructors reject invalid declarations`:

```perl
subtest 'every routing middleware position normalizes bare factories' => sub {
    my $handler = sub { };
    my $factory = sub { return $_[0] };
    my $explicit = middleware('Configured', enabled => 1);
    my $input = [$factory, $explicit, $factory];

    my @nodes = (
        route('/http' => $handler, middleware => $input),
        websocket('/socket' => $handler, middleware => [$factory]),
        sse('/events' => $handler, middleware => [$factory]),
        mount('/opaque' => sub { }, middleware => [$factory]),
        mount('/inline', routes => [], middleware => [$factory]),
        router(routes => [], middleware => [$factory]),
    );

    for my $node (@nodes) {
        isa_ok($node->middleware->[0], 'PAGI::Routing::Middleware');
        is(refaddr($node->middleware->[0]->factory), refaddr($factory),
            ref($node) . ' retains bare factory identity');
    }

    my $route_middleware = $nodes[0]->middleware;
    is(refaddr($route_middleware->[1]), refaddr($explicit),
        'mixed explicit description is preserved by identity');
    isnt(refaddr($route_middleware->[0]), refaddr($route_middleware->[2]),
        'repeated bare route entries receive distinct descriptions');
    is(
        [map {
            ref($_->factory) eq 'CODE' ? 'bare' : $_->factory
        } @$route_middleware],
        ['bare', 'Configured', 'bare'],
        'mixed list preserves declaration order',
    );

    push @$input, middleware('InputMutation');
    is(scalar @{$nodes[0]->middleware}, 3, 'constructor copied mixed input');
    push @{$nodes[0]->middleware}, middleware('AccessorMutation');
    is(scalar @{$nodes[0]->middleware}, 3, 'accessor returns a fresh array');
};
```

Replace the old `route('/bare-middleware' ...)` rejection assertion with these invalid-direct-entry assertions:

```perl
    my $configured = bless {}, 'BareListConfiguredObject';
    for my $invalid ('GZip', [], {}, $configured) {
        like dies {
            route '/invalid-middleware' => $handler,
                middleware => [$invalid]
        }, qr/descriptions or coderef factories/,
            'direct middleware entries stay intentionally narrow';
    }
```

Retain the existing non-array assertion and all `middleware(...)` constructor validation assertions.

- [ ] **Step 2: Add a failing runtime matrix for all six routing positions**

Create `t/routing/11-bare-middleware.t`:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use PAGI::Routing qw(router route websocket sse mount middleware);

sub scope {
    my (%change) = @_;
    return {
        type        => 'http',
        method      => 'GET',
        path        => '/',
        root_path   => '',
        raw_path    => '/',
        path_params => {},
        headers     => [],
        %change,
    };
}

sub run_scope {
    my ($app, $request_scope) = @_;
    my @events;
    $app->(
        $request_scope,
        sub { return Future->done({ type => 'unused.receive' }) },
        sub { push @events, $_[0]; return Future->done },
    )->get;
    return \@events;
}

sub tracing_factory {
    my ($label, $builds, $runs) = @_;
    return sub {
        my ($inner) = @_;
        push @$builds, $label;
        return sub {
            my ($request_scope, $receive, $send) = @_;
            push @$runs, "$label:$request_scope->{type}";
            return $inner->($request_scope, $receive, $send);
        };
    };
}

subtest 'router, inline mount, and HTTP route factories keep nested order' => sub {
    my (@builds, @runs);
    my $router_factory = tracing_factory('router', \@builds, \@runs);
    my $mount_factory  = tracing_factory('mount',  \@builds, \@runs);
    my $route_factory  = tracing_factory('route',  \@builds, \@runs);
    my $app = router(
        middleware => [$router_factory],
        routes => [
            mount('/api', middleware => [$mount_factory], routes => [
                route('/item' => sub {
                    push @runs, 'handler:http';
                    return $_[0]->text('ok');
                }, middleware => [$route_factory]),
            ]),
        ],
    )->to_app;

    is(\@builds, [qw(route mount router)],
        'compilation folds inner boundaries before outer boundaries');
    run_scope($app, scope(path => '/api/item', raw_path => '/api/item'));
    is(\@runs, [qw(router:http mount:http route:http handler:http)],
        'first visible execution proceeds outermost to handler');
};

subtest 'opaque mount, WebSocket, and SSE accept bare factories' => sub {
    my (@builds, @runs);
    my $opaque = tracing_factory('opaque', \@builds, \@runs);
    my $ws = tracing_factory('ws', \@builds, \@runs);
    my $events = tracing_factory('sse', \@builds, \@runs);
    my $app = router(routes => [
        mount('/opaque' => async sub {
            my ($request_scope, $receive, $send) = @_;
            await $send->({ type => 'http.response.start', status => 204, headers => [] });
            await $send->({ type => 'http.response.body', body => '', more => 0 });
        }, middleware => [$opaque]),
        websocket('/socket' => async sub {
            push @runs, 'handler:websocket';
            await $_[0]->close(1000, 'done');
        }, middleware => [$ws]),
        sse('/events' => async sub {
            push @runs, 'handler:sse';
            await $_[0]->close;
        }, middleware => [$events]),
    ])->to_app;

    run_scope($app, scope(path => '/opaque', raw_path => '/opaque'));
    run_scope($app, scope(type => 'websocket', path => '/socket', raw_path => '/socket'));
    run_scope($app, scope(type => 'sse', path => '/events', raw_path => '/events'));
    is(\@runs, [
        'opaque:http',
        'ws:websocket', 'handler:websocket',
        'sse:sse', 'handler:sse',
    ], 'each protocol and opaque boundary executes its bare factory wrapper');
};

subtest 'bare router factory sees generated outcomes and mixed lists retain order' => sub {
    my (@statuses, @runs);
    my $observer = sub {
        my ($inner) = @_;
        return sub {
            my ($request_scope, $receive, $send) = @_;
            push @runs, 'bare';
            my $observing_send = sub {
                my ($event) = @_;
                push @statuses, $event->{status}
                    if ($event->{type} // '') eq 'http.response.start';
                return $send->($event);
            };
            return $inner->($request_scope, $receive, $observing_send);
        };
    };
    my $explicit = middleware(sub {
        my ($inner) = @_;
        return sub { push @runs, 'explicit'; return $inner->(@_) };
    });
    my $app = router(
        routes => [route('/present' => sub { return $_[0]->text('present') })],
        middleware => [$observer, $explicit],
    )->to_app;

    run_scope($app, scope(path => '/missing'));
    run_scope($app, scope(method => 'POST', path => '/present'));
    is(\@runs, [qw(bare explicit bare explicit)],
        'mixed bare and explicit list keeps first-listed-outermost order');
    is(\@statuses, [404, 405], 'router wrapper sees both generated outcomes');
};

subtest 'bare factory timing and failures remain compile-time behavior' => sub {
    my $builds = 0;
    my $description = route('/fresh' => sub { return $_[0]->text('fresh') },
        middleware => [sub { ++$builds; return $_[0] }]);
    my $one = $description->to_app;
    my $two = $description->to_app;
    is($builds, 2, 'each to_app creates a fresh wrapper occurrence');
    run_scope($one, scope(path => '/fresh'));
    run_scope($two, scope(path => '/fresh'));
    is($builds, 2, 'requests do not rerun the factory');

    like dies {
        route('/bad' => sub { return $_[0]->text('bad') },
            middleware => [sub { return 'not an app' }])->to_app
    }, qr/middleware factory must return PAGI app coderef/,
        'invalid bare factory result fails at to_app';
    like dies {
        router(routes => [], middleware => [sub {
            return Future->done(sub { })
        }])->to_app
    }, qr/middleware factory must return PAGI app coderef.*Future/,
        'accidentally async bare factory remains invalid';
};

done_testing;
```

- [ ] **Step 3: Run the constructor and runtime tests red**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/01-constructors.t t/routing/11-bare-middleware.t'
```

Expected: FAIL because the public constructors still require prebuilt descriptions.

- [ ] **Step 4: Normalize middleware once in each routing constructor**

In `lib/PAGI/Routing/Route.pm`:

- replace `use Scalar::Util qw(blessed);` with `use PAGI::Routing::Middleware ();`;
- remove `_validate_middleware`;
- before constructing the pattern, compute:

```perl
    my $middleware = PAGI::Routing::Middleware->_normalize_descriptors(
        exists $opts{middleware} ? $opts{middleware} : [],
        'middleware',
    );
```

- store `middleware => $middleware` rather than copying the unnormalized input.

In `lib/PAGI/Routing/Mount.pm`, add `use PAGI::Routing::Middleware ();`, replace the call to `PAGI::Routing::Route::_validate_middleware`, compute the same normalized `$middleware`, and store it. Retain `Scalar::Util qw(blessed)` because route-tree validation still uses it.

In `lib/PAGI/Routing/Router.pm`, add `use PAGI::Routing::Middleware ();`, replace the call to `PAGI::Routing::Route::_validate_middleware`, compute the same normalized `$middleware`, and store it.

Do not add fallback normalizing logic to any compiler.

- [ ] **Step 5: Run routing shorthand and compatibility suites green**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/01-constructors.t t/routing/04-middleware-descriptors.t t/routing/05-http-dispatch.t t/routing/05-generated-outcomes.t t/routing/07-mounts.t t/routing/08-protocols.t t/routing/11-bare-middleware.t t/router-middleware.t t/endpoint/12-route-middleware-value-flow.t'
```

Expected: PASS. This simultaneously proves the new six-position shorthand, the unchanged mutable-router bare middleware, and the unchanged Endpoint coderef rejection/value-flow guidance.

- [ ] **Step 6: Prove the compiler diff is empty and run the full suite**

```bash
git diff --exit-code -- lib/PAGI/Routing/Compiler.pm
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t/'
```

Expected: no compiler diff and PASS. Record exact full-suite counts.

- [ ] **Step 7: Commit and complete the review gate**

```bash
git add lib/PAGI/Routing/Route.pm lib/PAGI/Routing/Mount.pm lib/PAGI/Routing/Router.pm t/routing/01-constructors.t t/routing/11-bare-middleware.t
git commit -m "feat: accept bare routing middleware factories"
```

Update Task 2's ledger row with the commit SHA, focused/full commands and counts, compiler audit, and review result.

---

### Task 3: Accept Bare Factories in Compose

**Files:**
- Modify: `lib/PAGI/Compose.pm`
- Modify: `t/compose/01-description.t`
- Modify: `t/compose/04-middleware.t`

**Interfaces:**
- Adds the seventh public shorthand position: `compose(..., middleware => [\&factory])`.
- Reuses the same normalizer and the Compose-specific error prefix.
- Leaves target coercion, lifecycle ownership/provenance, generated routing outcomes, final HEAD ownership, and compiler order unchanged.

- [ ] **Step 1: Add failing Compose construction assertions**

In `t/compose/01-description.t`, define a bare factory separately from the explicit descriptor:

```perl
my $factory = sub { my ($inner) = @_; return $inner };
my $mw = middleware(sub { my ($inner) = @_; return $inner });
my $middleware = [$factory, $mw, $factory];
```

Add a configured-object fixture that is valid only through the explicit constructor:

```perl
{
    package ComposeConfiguredMiddleware;
    sub wrap { return $_[1] }
}
```

Replace the one-entry middleware assertions with:

```perl
my $stored = $composition->middleware;
isa_ok($stored->[0], 'PAGI::Routing::Middleware');
is(refaddr($stored->[0]->factory), refaddr($factory),
    'bare factory identity is retained');
is(refaddr($stored->[1]), refaddr($mw),
    'explicit description identity is retained');
isnt(refaddr($stored->[0]), refaddr($stored->[2]),
    'repeated bare occurrences receive distinct descriptions');
```

Replace the existing middleware defensive-copy assertion with:

```perl
push @$middleware, middleware(sub { return $_[0] });
push @{$composition->middleware}, $mw;
is(scalar @{$composition->middleware}, 3,
    'normalized middleware input and accessor arrays are defensively copied');
```

Before `@invalid`, create the direct configured object and replace the old `invalid middleware member` case, which used a now-valid coderef, with these cases:

```perl
my $bare_configured = bless {}, 'ComposeConfiguredMiddleware';

my @invalid = (
    # retain every existing non-middleware case
    ['invalid middleware class string',
        [routes => [], middleware => ['RequestId']],
        qr/descriptions or coderef factories/],
    ['invalid middleware array',
        [routes => [], middleware => [[]]],
        qr/descriptions or coderef factories/],
    ['invalid middleware hash',
        [routes => [], middleware => [{}]],
        qr/descriptions or coderef factories/],
    ['invalid bare configured middleware object',
        [routes => [], middleware => [$bare_configured]],
        qr/descriptions or coderef factories/],
    # retain every existing lifespan case
);
```

Do not literally duplicate the `my @invalid` declaration: splice the four rows into the existing table while retaining all its other rows.

- [ ] **Step 2: Make the Compose runtime tests exercise bare and mixed forms**

In `t/compose/04-middleware.t`, rename `tracing_middleware` to `tracing_factory` and make it return the factory coderef directly rather than `middleware(...)`:

```perl
sub tracing_factory {
    my ($name, $trace) = @_;
    return sub {
        my ($inner) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            push @$trace, "$name before " . ($scope->{type} // '');
            my $wrapped_send = sub {
                my ($event) = @_;
                push @$trace, "$name send " . ($event->{type} // '');
                return $send->($event);
            };
            await Future->wrap($inner->($scope, $receive, $wrapped_send));
            push @$trace, "$name after " . ($scope->{type} // '');
            return;
        };
    };
}
```

Use a mixed list in the first ordering test:

```perl
middleware => [
    tracing_factory('outer', \@trace),
    middleware(tracing_factory('inner', \@trace)),
],
```

In `application middleware sees every delegated protocol and generated routing outcomes`, make both observers bare without changing their wrapper bodies:

```perl
my $observer = sub {
    my ($inner) = @_;
    return sub {
        my ($scope, $receive, $send) = @_;
        push @scope_types, $scope->{type};
        return $inner->($scope, $receive, $send);
    };
};

my $outcome_observer = sub {
    my ($inner) = @_;
    return sub {
        my ($scope, $receive, $send) = @_;
        my $wrapped_send = sub {
            my ($event) = @_;
            push @statuses, $event->{status}
                if ($event->{type} // '') eq 'http.response.start';
            return $send->($event);
        };
        return $inner->($scope, $receive, $wrapped_send);
    };
};
```

Make the state-provenance clone a bare factory so the existing startup assertion proves that normalization does not move middleware inside lifecycle dispatch:

```perl
my $clone = sub {
    my ($inner) = @_;
    return sub {
        my ($scope, $receive, $send) = @_;
        return $inner->({ %$scope, worker => 'wrapped' }, $receive, $send);
    };
};
```

Replace the final fresh/failure block with bare forms:

```perl
subtest 'each to_app builds fresh bare middleware instances' => sub {
    my $factory_calls = 0;
    my $factory = sub {
        my ($inner) = @_;
        ++$factory_calls;
        return $inner;
    };
    my $composition = compose(app => sub { return }, middleware => [$factory]);
    my $one = $composition->to_app;
    my $two = $composition->to_app;
    is($factory_calls, 2, 'factory runs once for each compiled graph');

    my $throwing = compose(
        app => sub { return },
        middleware => [sub { die "factory exploded\n" }],
    );
    like(dies { $throwing->to_app }, qr/factory exploded/,
        'bare factory failure aborts to_app synchronously');

    my $invalid = compose(
        app => sub { return },
        middleware => [sub { return 'not an app' }],
    );
    like(dies { $invalid->to_app }, qr/must return PAGI app coderef/,
        'invalid bare wrapper result aborts compilation');

    my $async = compose(
        app => sub { return },
        middleware => [sub { return Future->done(sub { }) }],
    );
    like(dies { $async->to_app }, qr/must return PAGI app coderef.*Future/,
        'an accidentally async bare factory remains invalid');
};
```

- [ ] **Step 3: Run Compose tests red**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/compose/01-description.t t/compose/04-middleware.t'
```

Expected: FAIL at Compose construction because its local validator still rejects bare factories.

- [ ] **Step 4: Replace Compose's duplicate validator with shared normalization**

In `lib/PAGI/Compose.pm`, add:

```perl
use PAGI::Routing::Middleware ();
```

Replace:

```perl
    my $middleware = exists $opts{middleware} ? $opts{middleware} : [];
    _validate_middleware($middleware);
```

with:

```perl
    my $middleware = PAGI::Routing::Middleware->_normalize_descriptors(
        exists $opts{middleware} ? $opts{middleware} : [],
        'compose middleware',
    );
```

Store `middleware => $middleware` and remove Compose's private `_validate_middleware`. Keep `Scalar::Util qw(blessed)` for `_validate_app_shape`.

- [ ] **Step 5: Run Compose behavior and boundary regressions green**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/compose/ t/routing/06-head.t t/routing/10-head-boundary.t'
```

Expected: PASS, including mixed order, all delegated scope types, generated 404, lifespan state proof, short-circuiting, exception propagation, fresh graphs, and final HEAD behavior.

- [ ] **Step 6: Prove the Compose compiler diff is empty and run the full suite**

```bash
git diff --exit-code -- lib/PAGI/Compose/Compiler.pm
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t/'
```

Expected: no compiler diff and PASS with exact counts recorded.

- [ ] **Step 7: Commit and complete the review gate**

```bash
git add lib/PAGI/Compose.pm t/compose/01-description.t t/compose/04-middleware.t
git commit -m "feat: accept bare compose middleware factories"
```

Update Task 3's ledger row with the commit SHA, focused/full counts, compiler audit, and review result.

---

### Task 4: Publish the Shorthand and Convert the Declarative Routing Demo

**Files:**
- Modify: `lib/PAGI/Routing.pm`
- Modify: `lib/PAGI/Routing/Middleware.pm`
- Modify: `lib/PAGI/Compose.pm`
- Modify: `lib/PAGI/Tools/Cookbook.pod`
- Modify: `lib/PAGI/Tools/Tutorial.pod`
- Modify: `examples/declarative-routing/app.pl`
- Modify: `examples/declarative-routing/README.md`
- Modify: `t/integration-declarative-routing-demo.t`

**Interfaces:**
- Teaches `middleware => [\&factory]` as the low-boilerplate inline form.
- Teaches `middleware(...)` as the explicit middleware-description constructor, including why it remains necessary.
- Keeps configured-class examples explicit and documents that all accessors return normalized descriptions.

- [ ] **Step 1: Add an executable-source contract for the converted demo**

At the top of `t/integration-declarative-routing-demo.t`, read the app source before `do $app_file`:

```perl
open my $app_fh, '<', $app_file or die "cannot read $app_file: $!";
my $app_source = do { local $/; <$app_fh> };
close $app_fh;

like($app_source, qr/use PAGI::Routing qw\(:routes\)/,
    'demo imports route constructors without the middleware helper');
like($app_source, qr/my \$home_header = sub \{/,
    'demo declares its pure factory directly');
like($app_source, qr/middleware\s*=>\s*\[\$home_header\]/,
    'demo uses the bare factory in its route middleware list');
unlike($app_source, qr/my \$home_header = middleware\(/,
    'demo does not add a redundant description wrapper');
```

These assertions are intentionally structural because `app.pl` returns the already-compiled coderef and no longer exposes the route description. Keep all existing HTTP, custom fallback, HEAD, and reverse-URL assertions.

- [ ] **Step 2: Run the integration test red**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-declarative-routing-demo.t'
```

Expected: the existing behavior passes, while the four new source-contract assertions fail against the explicit wrapper.

- [ ] **Step 3: Convert the declarative routing example**

In `examples/declarative-routing/app.pl`:

```perl
use PAGI::Routing qw(:routes);
```

Declare the middleware as the bare factory:

```perl
my $home_header = sub {
    my ($app) = @_;

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $wrapped_send = wrap_send($send, async sub {
            my ($event, $downstream) = @_;
            if (($event->{type} // '') eq 'http.response.start') {
                $event = {
                    %$event,
                    headers => [
                        @{$event->{headers} // []},
                        ['x-route-demo', 'home'],
                    ],
                };
            }
            await $downstream->($event);
        });

        await $app->($scope, $receive, $wrapped_send);
    };
};
```

Keep `middleware => [$home_header]`. Update its README bullet from “one pure route middleware descriptor” to “one bare pure route middleware factory, normalized to an inspectable description.”

- [ ] **Step 4: Update all public POD surfaces consistently**

Make these concrete documentation changes:

- `lib/PAGI/Routing.pm`: add `middleware => [$code]` to the coderef-position table; state that the enclosing list calls it with `($inner_app)` at `to_app`; show one bare factory plus one configured-class description; replace “first descriptor listed” with “first entry listed”; state that constructors normalize and accessors expose descriptions only.
- `lib/PAGI/Routing/Middleware.pm`: define the class as the normalized immutable description; explain that `middleware($factory)` is optional inside a list but remains the explicit form for class/config, configured objects, reuse, and pre-attachment inspection.
- `lib/PAGI/Compose.pm`: add the bare-list position to its coderef table; list the two accepted entry shapes; show a bare logging factory beside `middleware('RequestId', ...)`; state that the accessor is homogeneous and explicit identities are preserved.
- `lib/PAGI/Tools/Cookbook.pod`: change the channel-helper recipe to declare `my $factory = sub { ... };` and attach it bare; retain a nearby configured-class `middleware(...)` example.
- `lib/PAGI/Tools/Tutorial.pod`: replace the claim that all pure middleware is “described with `middleware(...)`” with the bare/explicit distinction; keep configured `RequestId`/`RouterMetrics` examples explicit.

Do not edit `lib/PAGI/Tools.pm` or generated `README.md` unless an independently discovered inconsistency requires it. If `lib/PAGI/Tools.pm` does change, record why and regenerate `README.md` with `dzil build`; never hand-edit generated README text.

- [ ] **Step 5: Run docs, example, and public API tests green**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && podchecker lib/PAGI/Routing.pm lib/PAGI/Routing/Middleware.pm lib/PAGI/Compose.pm lib/PAGI/Tools/Cookbook.pod lib/PAGI/Tools/Tutorial.pod'
```

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -c examples/declarative-routing/app.pl && prove -lv t/routing/01-constructors.t t/compose/01-description.t t/integration-declarative-routing-demo.t'
```

Expected: every POD file reports syntax OK; the example compiles; integration and description tests pass.

- [ ] **Step 6: Commit and complete the review gate**

```bash
git add lib/PAGI/Routing.pm lib/PAGI/Routing/Middleware.pm lib/PAGI/Compose.pm lib/PAGI/Tools/Cookbook.pod lib/PAGI/Tools/Tutorial.pod examples/declarative-routing/app.pl examples/declarative-routing/README.md t/integration-declarative-routing-demo.t
git commit -m "docs: teach bare middleware factory shorthand"
```

Update Task 4's ledger row with the commit SHA, POD/example/test results and counts, and review result.

---

### Task 5: Move the Chat Showcase Root to Compose

**Files:**
- Modify: `examples/10-chat-showcase/app.pl`
- Modify: `examples/10-chat-showcase/README.md`
- Modify: `examples/README.md`
- Create: `t/integration-chat-compose.t`
- Modify: `Changes`

**Interfaces:**
- Retains `PAGI::App::Router` and all existing HTTP, WebSocket, SSE, and static handlers.
- Replaces the manual `PAGI::Lifespan` plus `with_logging(...)` root nesting with `compose(app => $router, middleware => [\&with_logging], lifespan => {...})->to_app`.
- Demonstrates that application middleware surrounds lifecycle and request protocols without requiring the route tree to migrate.

- [ ] **Step 1: Add a failing architecture plus behavior integration test**

Create `t/integration-chat-compose.t`:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../examples/10-chat-showcase/lib";
use PAGI::Test::Client;

my $app_file = "$Bin/../examples/10-chat-showcase/app.pl";
open my $fh, '<', $app_file or die "cannot read $app_file: $!";
my $source = do { local $/; <$fh> };
close $fh;

like($source, qr/use PAGI::Compose qw\(compose\)/,
    'chat root imports Compose');
unlike($source, qr/use PAGI::Lifespan/,
    'chat root no longer hand-assembles Lifespan');
like($source, qr/middleware\s*=>\s*\[\s*\\&with_logging\s*\]/,
    'chat root demonstrates the bare factory shorthand');
like($source, qr/app\s*=>\s*\$router/,
    'chat keeps its existing mutable router as the request target');

my $app = do $app_file;
my $load_error = $@ || $!;
ok(!$load_error, 'chat app loads cleanly') or diag($load_error);
is(ref($app), 'CODE', 'chat app returns one compiled PAGI coderef');

SKIP: {
    skip 'chat app did not load', 6 unless ref($app) eq 'CODE';

    my $stderr = '';
    my $stats;
    {
        local *STDERR;
        open STDERR, '>', \$stderr or die "cannot capture STDERR: $!";
        PAGI::Test::Client->run($app, sub {
            my ($client) = @_;
            $stats = $client->get('/api/stats');
        });
    }

    is($stats->status, 200, 'existing HTTP API remains reachable');
    ok(exists $stats->json->{rooms_count}, 'existing statistics payload remains intact');
    like($stderr, qr/\[lifespan\] Application starting up/,
        'Compose runs the existing startup callback');
    like($stderr, qr/\[lifespan\] Application shutting down/,
        'Compose runs the existing shutdown callback');
    like($stderr, qr/^\[http\] GET \/api\/stats 200 /m,
        'bare logging factory surrounds HTTP dispatch');
    like($stderr, qr/^\[lifespan\] - - - /m,
        'application logging also surrounds the complete lifespan loop');
}

done_testing;
```

- [ ] **Step 2: Run the new integration test red**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-chat-compose.t'
```

Expected: the architecture assertions fail because the example still uses `PAGI::Lifespan`; existing HTTP/lifecycle behavior may already pass.

- [ ] **Step 3: Replace the manual root with Compose**

In `examples/10-chat-showcase/app.pl`, replace `use PAGI::Lifespan;` with:

```perl
use PAGI::Compose qw(compose);
```

Leave handler construction and `PAGI::App::Router` route declarations untouched. Replace the manual Lifespan object and final logging call with:

```perl
compose(
    app => $router,
    middleware => [\&with_logging],
    lifespan => {
        startup => async sub {
            say STDERR "[lifespan] Application starting up...";

            my $stats = get_stats();
            say STDERR "[lifespan] Initialized with $stats->{rooms_count} default rooms";
        },
        shutdown => async sub {
            say STDERR "[lifespan] Application shutting down...";

            my $stats = get_stats();
            say STDERR "[lifespan] Final stats: $stats->{users_online} users, $stats->{messages_total} messages";
        },
    },
)->to_app;
```

The final expression itself is the app; do not assign and manually wrap another `$app`.

- [ ] **Step 4: Document the architecture and release note**

In the chat README, show this nesting explicitly:

```text
PAGI::Compose
  -> application-wide logging middleware
    -> PAGI::App::Router
      -> HTTP / WebSocket / SSE handlers
```

State that:

- Compose is the deployed application root but the mutable router remains deliberately in place;
- configured startup/shutdown callbacks require server lifespan state support;
- application middleware receives the lifespan scope and events as well as request protocols; and
- `middleware => [\&with_logging]` is normalized into an inspectable immutable middleware description at construction.

Update `examples/README.md` entry 2 to mention the Compose root, application-wide logging, and HTTP/WebSocket/SSE target router. Under unreleased `0.002003` in `Changes`, add one concise bullet recording the additive bare-factory shorthand across all immutable declarative lists and the converted chat example.

- [ ] **Step 5: Run the chat and surrounding integration suites green**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -Iexamples/10-chat-showcase/lib -c examples/10-chat-showcase/app.pl && prove -lv t/integration-chat-compose.t t/integration-compose-demo.t t/integration-declarative-routing-demo.t'
```

Expected: compile and all integration assertions PASS, including startup, shutdown, API response, HTTP logging, and lifespan logging.

- [ ] **Step 6: Run the full suite and commit**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t/'
```

```bash
git add examples/10-chat-showcase/app.pl examples/10-chat-showcase/README.md examples/README.md t/integration-chat-compose.t Changes
git commit -m "examples: compose chat application root"
```

Update Task 5's ledger row with the commit SHA, focused/full counts, lifecycle evidence, and review result.

---

### Task 6: Run Release Verification and Audit Scope

**Files:**
- Modify only files already named in Tasks 1–5 if verification proves a correction necessary
- Inspect: `docs/superpowers/specs/2026-08-06-middleware-coderef-shorthand-design.md`
- Inspect: `.superpowers/sdd/2026-08-06-middleware-coderef-shorthand/progress.md`
- Inspect: complete branch diff from `git merge-base main HEAD`

**Interfaces:**
- Produces a clean, fully verified feature branch and complete evidence ledger.
- Does not create an empty verification commit. A real defect gets the narrowest failing regression and correction in its owning files.

- [ ] **Step 1: Run the focused feature and compatibility matrix from a clean process**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/01-constructors.t t/routing/04-middleware-descriptors.t t/routing/05-http-dispatch.t t/routing/05-generated-outcomes.t t/routing/07-mounts.t t/routing/08-protocols.t t/routing/11-bare-middleware.t t/compose/01-description.t t/compose/04-middleware.t t/compose/05-head-concurrency.t t/router-middleware.t t/endpoint/12-route-middleware-value-flow.t t/integration-declarative-routing-demo.t t/integration-chat-compose.t t/integration-compose-demo.t'
```

Expected: PASS. Record exact test-file/assertion counts and elapsed time.

- [ ] **Step 2: Run the complete suite twice**

Run these as two distinct invocations:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t/'
```

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t/'
```

Expected: both PASS with the same test-file/assertion count. Treat any flaky difference as a failure to investigate.

- [ ] **Step 3: Run POD and distribution packaging checks**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && podchecker lib/PAGI/Routing.pm lib/PAGI/Routing/Middleware.pm lib/PAGI/Compose.pm lib/PAGI/Tools/Cookbook.pod lib/PAGI/Tools/Tutorial.pod'
```

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && dzil test'
```

Expected: all POD syntax OK and distribution tests PASS. Inspect generated package input to confirm the new integration test and edited examples are included as expected.

- [ ] **Step 4: Audit constructor normalization and compiler non-change**

```bash
rg -n "_normalize_descriptors|middleware\s*=>" lib/PAGI/Routing/Middleware.pm lib/PAGI/Routing/Route.pm lib/PAGI/Routing/Mount.pm lib/PAGI/Routing/Router.pm lib/PAGI/Compose.pm
```

Confirm one helper and four constructor call sites, with no duplicate validator.

```bash
git diff --exit-code "$(git merge-base main HEAD)"..HEAD -- lib/PAGI/Routing/Compiler.pm lib/PAGI/Compose/Compiler.pm
```

Expected: no compiler changes.

```bash
rg -n "must contain PAGI::Routing::Middleware descriptors|_validate_middleware" lib/PAGI/Routing lib/PAGI/Compose.pm
```

Expected: no stale constructor-only validation. `_wrap_descriptors` must still contain its strict compiler diagnostic.

- [ ] **Step 5: Audit compatibility boundaries and documentation claims**

```bash
git diff --exit-code "$(git merge-base main HEAD)"..HEAD -- lib/PAGI/App/Router.pm lib/PAGI/Endpoint/Router.pm lib/PAGI/Middleware/Builder.pm
```

Expected: no changes.

```bash
rg -n "bare|coderef factor|middleware description|configured object|class name|first.*outermost" lib/PAGI/Routing.pm lib/PAGI/Routing/Middleware.pm lib/PAGI/Compose.pm lib/PAGI/Tools/Cookbook.pod lib/PAGI/Tools/Tutorial.pod examples/declarative-routing/README.md examples/10-chat-showcase/README.md
```

Confirm the docs distinguish:

- bare factories inside immutable declarative lists;
- explicit descriptions for class/config, objects, reuse, and inspection;
- native app coderefs in `compose(app => ...)`, `route(..., raw => ...)`, and opaque `mount` target positions; and
- Endpoint's unrelated value-flow middleware.

- [ ] **Step 6: Audit diff hygiene and unrelated user files**

```bash
git diff --check
git status --short
git diff --name-status "$(git merge-base main HEAD)"..HEAD
```

Inspect every path. The only allowed untracked files are:

```text
?? .cpan-testers-fix-report.md
?? .csrf-helper-brief.md
?? .csrf-helper-report.md
```

Confirm those files are absent from `git ls-files` and every feature commit.

- [ ] **Step 7: Correct a verified defect narrowly, if necessary**

If Steps 1–6 expose a defect, record the failing command/evidence in Task 6's ledger row, add or tighten the closest test, observe it fail, make the smallest correction in files already owned by the relevant task, and rerun the focused gate, both full suites, POD, and `dzil test`. Stage only explicit paths and commit a real correction as:

```bash
git commit -m "fix: resolve middleware shorthand verification findings"
```

If there is no defect, skip the commit and record `no correction commit required`.

- [ ] **Step 8: Complete the ledger and final whole-feature review**

Fill every ledger cell with actual status, commit range, command results/counts, and review decisions. Ensure the deviation table is empty or contains only user-decided entries. Run the execution skill's final whole-feature review against `git merge-base main HEAD` through `HEAD` and record its result.

The task is complete only when all six rows say `complete`, every review is approved, the focused matrix, both full suites, POD, and packaging pass, the design/non-goal audit is clean, and unrelated user files remain untouched.

---

## Required Final Evidence

The implementation handoff must report:

- final commit range and each task commit SHA;
- exact focused and twice-run full-suite test counts;
- POD and `dzil test` results;
- whole-feature review result;
- approved deviation IDs and decisions, or `none`;
- confirmation that the three unrelated untracked files were preserved; and
- links to `lib/PAGI/Routing/Middleware.pm`, `lib/PAGI/Compose.pm`, `examples/declarative-routing/app.pl`, `examples/10-chat-showcase/app.pl`, and the completed execution ledger.
