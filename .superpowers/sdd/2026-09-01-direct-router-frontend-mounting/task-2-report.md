# Task 2 report — Migrate App Router examples to direct mounting

## Scope

Repository: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/.worktrees/compose-retained-router`

Branch: `feature/compose-retained-router`

Base SHA: `1c46eb0281fab5aba7e0b0b51ff82ef15515f1d3`

Task: replace unnecessary App Router snapshots at the five example application
boundaries, update the affected explanations, and add source-shape assertions.

No files under `lib/` were changed.

## Prior RED intent

The prior worker's RED intent was to add the direct-root source assertions first
and run the four affected integration files before changing the examples. That
pre-change run was expected to fail only on the new assertions checking that
the background-task, full-demo, endpoint-demo, chat root, and chat HTTP child
use `mount('/' => app => $router)` and do not call `$router->to_router`.
The implementation then changed only those five root boundaries, preserving
route declarations, middleware, protocol handlers, static applications,
lifespan callbacks, and return types.

## Implementation

- Background tasks, full demo, endpoint demo, chat root, and `ChatApp::HTTP`
  now mount the existing `PAGI::App::Router` directly.
- The four affected READMEs explain `to_app` and the opaque unnamed root Mount;
  snapshot conversion is retained only as an explicit parent-side inspection
  or immutable-snapshot choice.
- Source-shape assertions cover all five direct roots.

## GREEN verification

Each focused test was run separately with Perl 5.42.2:

```text
$ perlbrew exec --with perl-5.42.2@default prove -lv t/integration-router-application-boundaries.t
All tests successful.
Files=1, Tests=3, Result: PASS

$ perlbrew exec --with perl-5.42.2@default prove -lv t/integration-maintained-examples-load.t
All tests successful.
Files=1, Tests=6, Result: PASS

$ perlbrew exec --with perl-5.42.2@default prove -lv t/integration-app-file-examples.t
All tests successful.
Files=1, Tests=11, Result: PASS

$ perlbrew exec --with perl-5.42.2@default prove -lv t/integration-chat-compose.t
All tests successful.
Files=1, Tests=34, Result: PASS
```

The focused suite totals 54 top-level tests. The output also included passing
direct-mount assertions for each affected boundary and retained HTTP,
WebSocket, SSE, static-file, middleware, and lifespan behavior.

Additional verification: `git diff --check` exited successfully with no output.

## Commits

- `8ddb014544be465ebbbd3d9245209b30089b18bc` — `docs: mount app router examples directly`
- Ledger/report commit: recorded after this report was written.

## Concerns

None. The requested direct mounts are limited to the five App Router example
boundaries, and no `lib/` runtime code was modified.
