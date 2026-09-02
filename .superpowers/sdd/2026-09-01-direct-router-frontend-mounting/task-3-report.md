# Task 3 report — Mount the Endpoint root directly and preserve nested discovery

## Scope

Repository: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/.worktrees/compose-retained-router`

Branch: `feature/compose-retained-router`

Base SHA: `2d3cbeafadaaea104d704edf8843d2a846e684c7`

Task: mount the configured `Main` Endpoint directly at the Compose root while
retaining the explicit API and Events snapshots required for nested reverse
inspection.

Only the requested files changed:

- `examples/endpoint-router-demo/app.pl`
- `examples/endpoint-router-demo/README.md`
- `t/integration-endpoint-router-demo.t`

No nested Endpoint modules or files under `lib/` were changed.

## RED verification

The source-shape assertions were added before changing the application root.
The required focused command then failed only on the two new root assertions:
the app still mounted `$main->to_router`, and the source still contained that
unused root snapshot conversion. Nested API and Events snapshot assertions
passed, as did all existing live behavior checks.

```text
$ perlbrew exec --with perl-5.42.2@default prove -lv t/integration-endpoint-router-demo.t
Result: FAIL
Failed test: subtest 4 (`the nested demo exercises the complete Endpoint design`)
Failures: 2 source-shape assertions (root direct mount and no root to_router)
Nested assertions and live checks: passed
```

## Implementation

- Changed only the outer Compose mount from `app => $main->to_router` to
  `app => $main`.
- Preserved `Main`'s `app => $self->{api}->to_router` and API's
  `app => $self->{events}->to_router` declarations so descendant names remain
  inspectable within their parent namespaces.
- Updated the README to explain direct root deployment, Main's local resolver,
  the nested snapshot consumers, and the continuing inspection use of
  `$main->to_router`.
- Added source assertions for the mixed direct-root/explicit-nested composition.

## GREEN verification

```text
$ perlbrew exec --with perl-5.42.2@default prove -lv t/integration-endpoint-router-demo.t
All tests successful.
Files=1, Tests=4, Result: PASS
```

The four subtests contain 35 assertions. The passing run covers home-to-API and
API-to-item generated links followed by the Test Client, static files,
middleware and authentication, callback routes, API default and 405 `Allow`,
WebSocket, SSE, unmatched nested paths, and lifespan shutdown state.

Additional verification: `git diff --check` exited successfully with no output
before the implementation commit.

## Commits

- `c954880272f59e8f583287db56c0e08807e8e4ef` — `docs: mount endpoint root directly`
- Ledger update/report commit: recorded after this report is written.

## Concerns

None. The requested root migration and documentation/test changes are complete;
nested Endpoint modules and runtime library code remain unchanged.
