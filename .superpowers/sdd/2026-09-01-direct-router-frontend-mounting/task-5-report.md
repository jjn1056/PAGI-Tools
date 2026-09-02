# Task 5 report — retained conversions and distribution verification

## Status

Audit and verification are complete. Final review remains for the controller.
No category-6 stale deployment ceremony was found, so Task 5 changed no live
product, test, example, or public-documentation file. Commit
`ddd661d6c04e16327e4f8ca36cd34163ccdd4aea` records the retained-conversion
inventory in the campaign ledger.

## Work map

- Repository:
  `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/.worktrees/compose-retained-router`
- Ticket: none
- Branch: `feature/compose-retained-router`
- Verification-start HEAD: `05b2dd5354080970a41c7689a294a54049f112e7`
- Candidate product/audit HEAD:
  `ddd661d6c04e16327e4f8ca36cd34163ccdd4aea`
- `main`: `558b14c282a38051bd8c1bb712290fe1df398330`
- `origin/main`: `558b14c282a38051bd8c1bb712290fe1df398330`
- Push target (not modified): `origin/feature/compose-retained-router` at
  `8dea8d0f3b21212d6a58b1b729a962e597eefb89`
- Deployment boundary: unreleased PAGI-Tools distribution
- Other repositories: out of scope and untouched
- No merge, rebase, push, branch switch, or sibling-repository mutation was
  performed.

## `to_router` inventory

The required search found 130 matching lines across 32 live files, containing
132 literal `->to_router` occurrences. Every matching line was classified into
an allowed category. Counts below are matching lines, so source-regression
regexes that mention `->to_router` are included even though they do not execute
a conversion.

### Category 1 — frontend implementation and inspection convenience

- `lib/PAGI/App/Router.pm` (3 of 6 hits): `named_routes`, `route_named`, and
  `path_for` inspect a fresh immutable frontend snapshot.
- `lib/PAGI/App/Router/Builder.pm` (1 hit): `to_app` materializes one Router
  snapshot and compiles it.
- `lib/PAGI/Endpoint/Router.pm` (1 of 4 hits): `to_app` materializes and
  compiles the configured Endpoint snapshot.

### Category 2 — parent descendant-name discovery

- `examples/endpoint-router-demo/lib/MyApp/Main.pm` (1 hit): Main converts API
  because `home` resolves `/api/index`.
- `examples/endpoint-router-demo/lib/MyApp/API.pm` (1 hit): API converts Events
  so `/api/events/stream` stays in API's inspectable tree.
- `examples/endpoint-router-demo/README.md` (2 hits): documents those two
  concrete consumers.
- `lib/PAGI/Compose.pm` (1 hit): parent/child example immediately resolves
  `/people/show`.
- `lib/PAGI/App/Router.pm` (2 of 6 hits): Synopsis and Mount documentation
  expose `/people/show` to a parent and then call parent `path_for`.
- `lib/PAGI/Endpoint/Router.pm` (1 of 4 hits): Endpoint child conversion is
  followed by parent `path_for('/people/show', ...)`.
- `lib/PAGI/Tools/Cookbook.pod` (2 of 3 hits): one App Router and one Endpoint
  parent retain child names for reverse routing.
- `lib/PAGI/Tools/Tutorial.pod` (2 hits): conversion is described only for
  reverse discovery/coherent retained identity.
- `UPGRADING.md` (2 of 7 hits): the nested Endpoint migration converts People
  and then resolves `/people/show` through the parent snapshot.
- Executable discovery coverage appears in `t/router-named-routes.t`,
  `t/router-middleware.t`, `t/app-router.t`,
  `t/app-router/05-middleware-order.t`,
  `t/app-router/06-public-api.t`,
  `t/endpoint/13-router-frontends.t`, and
  `t/upgrading-router-frontends.t`. These conversions have
  nested name, placement, middleware, constraint, or reverse-resolution
  assertions.

### Category 3 — retained immutable inspection or identity

- `UPGRADING.md` (3 of 7 hits): two retained root snapshots and one coherent
  App Router snapshot used for `route_named`, `path_for`, and `to_app`.
- `lib/PAGI/App/Router.pm` (1 of 6 hits): the `to_router` section demonstrates
  explicit snapshot retention.
- `lib/PAGI/Endpoint/Router.pm` (2 of 4 hits): class-call and object-call
  snapshot semantics.
- `lib/PAGI/Tools/Cookbook.pod` (1 of 3 hits): one retained snapshot supplies
  `path_for('/api/users')`.
- Inspection-oriented coverage is retained in `t/app-router.t` (2 of 7 hits),
  `t/app-router/06-public-api.t` (4 of 5 hits), and portions of
  `t/upgrading-router-frontends.t` and `t/integration-endpoint-router-demo.t`.

### Category 4 — construction, materialization, cycle, and snapshot tests

All remaining test hits are test subject construction, negative source-shape
guards, materialization/identity checks, cycle diagnostics, middleware
construction, constraint validation, or snapshot freshness. File-level audit:

- `t/00-pod/cookbook-examples.t` — 2 hits, executable POD guards.
- `t/app-router-mount-routes.t` — 3 hits, callback-child materialization and
  immutable node inspection.
- `t/app-router.t` — remaining 4 hits, explicit snapshot composition and
  immutable App Router behavior subjects.
- `t/app-router/01-builder-core.t` — 8 hits, builder materialization and
  immutable metadata/constraint subjects.
- `t/app-router/02-declaration-package.t` — 2 hits, declaration-package child
  placement and resulting nodes.
- `t/app-router/03-composition-order.t` — 3 hits, completed-app test subject
  and declaration-order inspection.
- `t/app-router/04-snapshots-cycles.t` — 9 hits, snapshot freshness, identity,
  mutation isolation, reuse, and cycle diagnostics.
- `t/app-router/05-middleware-order.t` — the single hit also exercises nested
  discovery while pinning middleware construction.
- `t/app-router/06-public-api.t` — snapshot identity/freshness coverage beyond
  its parent-discovery example.
- `t/app/03-router.t` — 2 hits, constructor/method snapshot behavior.
- `t/endpoint-router.t` — 9 hits, Endpoint materialization, errors, and
  inspection.
- `t/endpoint/12-route-middleware.t` — 3 hits, route-middleware snapshots and
  missing-method diagnostics.
- `t/endpoint/13-router-frontends.t` — remaining 9 hits, frontend
  materialization, malformed declarations, repeated placement, constraints,
  and duplicate-default diagnostics.
- `t/integration-app-file-examples.t`, `t/integration-chat-compose.t`,
  `t/integration-maintained-examples-load.t`, and
  `t/integration-router-application-boundaries.t` — 1 hit each, negative
  source assertions that forbid unconsumed root snapshots.
- `t/integration-endpoint-router-demo.t` — 4 hits, two required nested-source
  assertions, whole-tree inspection, and a negative root assertion.
- `t/router-middleware.t` — its other hit is immutable middleware inspection.
- `t/upgrading-router-frontends.t` — remaining hits cover construction,
  error, constraint, fresh-snapshot, metadata, and opaque-vs-inspectable
  behavior.
- `t/upgrading-routing-composition.t` — current-guidance, retained-snapshot,
  and source-shape regression patterns.

### Category 5 — explicitly labelled history

- `UPGRADING.md` (2 of 7 hits) retains the removed
  `compose(router => $frontend->to_router)` forms in explicitly labelled
  **Before: historical removed constructor form** blocks.
- `t/upgrading-routing-composition.t` matches those labels and their current
  stable-snapshot replacements.

### Category 6 — stale deployment ceremony

None.

For completeness, the file-level classification is: `UPGRADING.md` (7:
categories 2/3/5); Endpoint demo README/Main/API (4: category 2); App Router
POD (6: 1/2/3); App Router Builder (1: 1); Compose POD (1: 2); Endpoint Router
POD (4: 1/2/3); Cookbook (3: 2/3); Tutorial (2: 2); and all 22 test files
(102: categories 2/3/4/5 as described above). These totals account for all 130
matching lines and all 132 literal occurrences.

## Stale prose and flattening searches

The stale-prose search returned no hits. The flattening search returned three:

- `lib/PAGI/Compose.pm` — explicitly labelled deliberately lossy composition;
- `lib/PAGI/Routing/Mount.pm` — explicit warning against flattening; and
- `UPGRADING.md` — **Flatten direct child nodes deliberately**, documenting
  the policy loss.

All are intentional explanatory examples, not canonical deployment guidance.

## Verification

### Integrated focused suite

Command:

    perlbrew exec --with perl-5.42.2@default prove -lr \
      t/app-router.t t/app-router t/endpoint-router.t t/endpoint \
      t/integration-router-application-boundaries.t \
      t/integration-maintained-examples-load.t \
      t/integration-app-file-examples.t t/integration-chat-compose.t \
      t/integration-endpoint-router-demo.t \
      t/upgrading-routing-composition.t t/upgrading-router-frontends.t t/00-pod

Result at `ddd661d6c04e16327e4f8ca36cd34163ccdd4aea`: PASS, 32 files,
232 tests, 7 wallclock seconds (6.94 CPU seconds).

### Complete suite

Command, run exactly once at the final candidate product/audit HEAD:

    perlbrew exec --with perl-5.42.2@default prove -lr t

Result at `ddd661d6c04e16327e4f8ca36cd34163ccdd4aea`: PASS, 224 files,
2,464 tests, 47 wallclock seconds (42.77 CPU seconds). There were zero
failures and no reported test warnings. One file was intentionally skipped:
`t/request/multipart-stream-e2e.t` requires `RELEASE_TESTING=1` for its
full-stack PAGI::Server run.

### Distribution build

Command:

    perlbrew exec --with perl-5.42.2@default dzil build

No `dzil test` command was run. Build result: PASS. Dist::Zilla emitted its
existing `PkgVersion` package-layout advisories and produced:

- archive: `PAGI-Tools-0.002002.tar.gz`
- size: 1,013,774 bytes
- SHA-256:
  `5e7793d963ce998f813cc57c247d99647b07e7d196dfdd1517b53a5435562234`
- entries: 563

The archive README is byte-identical to tracked `README.md`. `Changes`,
`UPGRADING.md`, the relevant Router/Compose/Tutorial/Cookbook POD, upgrade
tests, and affected example READMEs are present. `docs/superpowers`,
`.superpowers`, VCS metadata, nested archives, and unrelated build debris are
absent. The only `blib` entry is the deliberately tracked
`t/app-path-fixtures/blib` source fixture used by app-path tests.

`git diff --check` passed. The build did not modify tracked README content or
any other tracked file.

## Blockers and deviations

None. No hack pressure, runtime conversion magic, resolver duplication, or
design contradiction was encountered.
