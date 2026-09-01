# SDD ledger — plan: docs/superpowers/plans/2026-08-31-compose-retained-router.md

## Compose Retained-Router Execution

Base: `558b14c282a38051bd8c1bb712290fe1df398330`

| Task | Status | Implementation commit | Tests | Evidence |
|---|---|---|---|---|
| 1. Retained description | complete | `9b9e4f16c5dcfba83e5018f961e7ed296c990ec3` | 4 files, 104 tests | RED: `t/compose/01-description.t` stopped after 4 assertions with `unknown compose option 'router'`; GREEN: focused constructor/reverse suite passed. |
| 2. Compiler and safety | complete | `b860142fdb7f042626245faa73528b929bb68894` | 7 files, 62 tests | RED: migrated focused gate failed only the retained-Router count (`got 0`, expected `1` then `2`); GREEN: compiler now calls the retained Router and the focused safety gate passed. |
| 3. Lifespan and ordering | complete | `da561c66545665025d5a927da6474dcebba99f5d` | 4 files, 45 tests | RED: all migrated Compose gates failed on the retired `app =>` constructor; GREEN: root-only lifespan, middleware visibility, mounted boundaries, strict bare-Router failure, and HEAD/buffering gate passed. |
| 4. Router frontends | complete | `f3e3972` | 6 files, 57 tests | RED: focused frontend gate failed in the background-task root and retired Compose-native bridge, plus the old `router =>` classifier; GREEN: all six required frontend/POD-example files passed with explicit frontend snapshots. |
| 5. Flagship examples | complete | `ae8e37f` | 2 files, 12 top-level tests | RED: new source-shape assertions rejected the retired apples nested Router and large-app `app =>` boundary; GREEN: both flagship integrations passed with CRUD, URL, default, static-file, middleware, and lifespan coverage. |
| 6. Remaining examples | complete | `c1129e6d0fc55939dd04c2a480aa50d88c5ffbaa` | 9 files, 109 tests | RED: source-shape gate rejected every retired live app-mode target; GREEN: every selected example loaded and retained HTTP, WebSocket, SSE, lifespan, stream terminal, and disconnect behavior. |
| 7. Public docs and upgrade | complete | `8aa8283c50563014909727e09be4d5f9981e7c99` | 3 files, 36 tests | Compose POD, public cross-links, exact migration recipes, Starlette comparison, Cookbook synchronization, and release notes now describe the retained-Router surface; POD syntax and semantic searches are clean. |
| 8. Final verification | in progress | `887c2b54cfd9a1f9f5ee0ea0c9f5b8686144451b` | focused: 5 files, 39 tests; full: 224 files, 2,459 tests | Diff/syntax/search clean; focused settlement gate PASS; host-access full suite PASS; `dzil build` PASS with 563 archive members and 123 example assets. Final whole-branch review pending. |

## Task 6 example inventory (before edits)

`rg -l 'PAGI::Compose|compose\(' examples | sort` reported:

```text
examples/10-chat-showcase/README.md
examples/10-chat-showcase/app.pl
examples/10-chat-showcase/lib/ChatApp/HTTP.pm
examples/15-large-application/README.md
examples/15-large-application/lib/MyApp/Root.pm
examples/background-tasks/README.md
examples/background-tasks/app.pl
examples/compose/README.md
examples/compose/app.pl
examples/declarative-routing/README.md
examples/declarative-routing/app.pl
examples/endpoint-demo/README.md
examples/endpoint-demo/app.pl
examples/endpoint-router-demo/README.md
examples/endpoint-router-demo/app.pl
examples/full-demo/README.md
examples/full-demo/app.pl
examples/pages/README.md
examples/pages/app.pl
examples/process-streaming/app.pl
examples/starlette-apples/README.md
examples/starlette-apples/app.pl
```

`rg -n -U 'compose\(\s*app\s*=>' examples` identified the retired live
targets: declarative-routing, endpoint-demo, endpoint-router-demo, pages,
process-streaming, full-demo, 10-chat-showcase (root and HTTP child), and the
corresponding README prose. `background-tasks`, `compose`,
`15-large-application`, and `starlette-apples` already use approved forms.
`sse-close`, `sse-dashboard`, and the WebSocket examples were inspected for
their explicit terminal/close/disconnect behavior and contain no Compose
app-mode usage; they require no source change.

Task 6 GREEN evidence: `perlbrew exec --with perl-5.42.2@default prove -lv`
over the eight planned maintained-example integrations plus
`t/integration-app-file-examples.t` passed (9 files, 109 tests). It includes
the process-streaming end-to-end bulk/404/client-disconnect cases and the
Endpoint Router WebSocket/SSE cases. The post-edit retired-mode search
`rg -n -U 'compose\(\s*app\s*=>' examples t` produced no matches.

## Task 7 public-documentation evidence

Commit `8aa8283c50563014909727e09be4d5f9981e7c99` rewrites the public Compose
contract around one retained Router, adds the exact immutable Router, mutable
frontend, flattened routes-form, and arbitrary-native-app migration recipes,
and records the deliberate Starlette lifespan comparison against the official
application, routing, and routing-test sources. App and Endpoint Router POD now
distinguish bare Router `to_app` from root `compose(router => $routing)`
deployment. The Cookbook's complete apples block again matches the runnable
example byte for byte.

Focused GREEN evidence:

```text
perlbrew exec --with perl-5.42.2@default prove -lv \
  t/00-pod t/upgrading-router-frontends.t \
  t/upgrading-routing-composition.t
Files=3, Tests=36, Result: PASS
```

`podchecker` reported `pod syntax OK` for all 11 modified public POD sources,
including the three additional live contract cross-links in Router Mount,
ErrorHandler, and Response. `git diff --check` passed. No malformed-POD or
other warnings were present in the focused gate.

The required multiline search
`rg -n -U 'compose\(\s*app\s*=>' lib examples t README.md UPGRADING.md Changes`
has exactly these intentional migration-before matches:

```text
UPGRADING.md:29:compose(app => $router)
UPGRADING.md:47:compose(app => $builder)
UPGRADING.md:64:compose(
UPGRADING.md:65:    app => router(routes => \@routes, http_default => $default),
```

The companion semantic search for arbitrary-app acceptance, routes/app
constructor claims, and temporary routes-mode Router construction produced no
matches. Tutorial terminal event examples retain their explicit `more => 0`.

## Work map

| Repository | Ticket | Branch | Base | Owned changes | Deployment boundary | Push target |
|---|---|---|---|---|---|---|
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | none | `feature/compose-retained-router` | `558b14c282a38051bd8c1bb712290fe1df398330` | Runtime, tests, all live examples, public POD/README/Tutorial/Cookbook, `UPGRADING.md`, and `Changes` required by the retained-Router design | One unreleased PAGI-Tools distribution | `origin/feature/compose-retained-router`, only after user authorization |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI` | none | read-only | published local specification | none | normative reference | none |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server` | none | read-only | released local server | none | integration reference | none |

## Baseline

- Local `main`, `origin/main`, and the feature-worktree base all resolved to
  `558b14c282a38051bd8c1bb712290fe1df398330` on 2026-09-01.
- `perlbrew exec --with perl-5.42.2@default prove -lr -j4 t/` passed:
  224 files, 2,435 tests, 13 wall-clock seconds.
- The baseline emitted one existing test-only warning from
  `t/compose/07-response-guard.t:232` (`else_done` in void context). Task 2
  owns a lexical-only warning cleanup while preserving the tested behavior.

## Preflight task/interface scan

| Producer | Consumer | Shared file or interface | Finding / ruling |
|---|---|---|---|
| Task 1 | Task 2 | `PAGI::Compose->router` and `lib/PAGI/Compose.pm` contract | Clean: Task 2 consumes the exact retained Router produced by Task 1. |
| Task 1 | Task 3 | Compose lifespan/middleware accessors | Clean: Task 3 tests existing root behavior on the Task 1 description. |
| Task 1 | Task 4 | strict `router => $immutable_router` constructor | Clean: frontends cross explicitly through `to_router`; Compose performs no coercion. |
| Task 1 | Tasks 5-6 | routes-form and router-form constructors | Clean: examples consume only the two approved forms. |
| Task 1 | Task 7 | `lib/PAGI/Compose.pm` implementation then POD | Clean: Task 7 edits documentation after the runtime surface is final. |
| Task 2 | Task 3 | compiled root layer order | Clean: Task 3 pins lifespan, middleware, and HEAD behavior after retained-Router compilation lands. |
| Task 2 | Task 8 | ResponseGuard and settlement regression surface | Ruling: direct event-level ResponseGuard tests remain direct; only obsolete Compose app-mode fixtures route through a selected application. Cost if wrong: a routing refactor could accidentally weaken settled disconnect/body/trailer semantics. |
| Task 3 | Task 7 | root-only lifespan and middleware visibility | Clean: documentation consumes the behavior Task 3 proves. |
| Task 4 | Tasks 5-6 | App/Endpoint Router `to_router` boundary | Clean: examples use the explicit immutable-Router crossing established by Task 4. |
| Task 4 | Task 7 | frontend module POD files | Clean: Task 4 may update live examples/assertions; Task 7 performs the final public documentation pass. |
| Tasks 5-6 | Task 7 | canonical examples and prose | Clean: public docs copy only the already-migrated shapes. |
| Tasks 1-7 | Task 8 | whole branch | Clean: final semantic searches, focused settlement gate, suite, build, and review cover all prior outputs. |

## Per-task internal consistency scan

| Task | Tests versus implementation | Files versus later steps | Finding / ruling |
|---|---|---|---|
| 1 | Constructor/identity tests fail before and pass after `Compose.pm` change | Compiler waits until Task 2 | Clean. |
| 2 | Counting Router, dispatch, failsafe, and direct guard tests cover only compiler/fixture changes | Task 3 consumes final layer order | Ruling: preserve `558b14c`'s failed-send-Future, post-completion re-raise, abnormal-disconnect exemption, terminal-body, and trailer contracts. The warning cleanup is test-only. Cost if wrong: settled PAGI 0.002008 behavior regresses. |
| 3 | Lifecycle/middleware/HEAD tests correspond to existing compiler boundaries | No later runtime owner overlaps | Clean. |
| 4 | Frontend tests cover explicit `to_router` crossing | Example and POD migrations follow | Clean. |
| 5 | Source-shape and behavioral integrations cover both canaries | Task 7 documents their final API | Clean. |
| 6 | Execution-time inventory prevents stale example lists | Task 7 follows after every live example | Ruling: inventory includes newly landed `process-streaming`; `sse-close`, `sse-dashboard`, and WebSocket examples retain close/disconnect semantics even when no source edit is required. Cost if wrong: examples could silently regress while the API migration passes. |
| 7 | POD/upgrading tests and semantic searches match the documented edits | Task 8 verifies the same live surface | Ruling: append to existing `0.002003 - UNRELEASED` notes and preserve explicit `more => 0`; do not rewrite the buffering/disconnect campaign. Cost if wrong: release notes or protocol examples lose current-main facts. |
| 8 | Focused settlement gate precedes one final full suite and distribution build | No downstream task | Clean. |

## Process rulings

- Ruling: keep this ledger force-added and committed as required by the
  approved plan, even though the generic SDD workflow normally treats its
  workspace as disposable scratch. The tracked ledger is the campaign's
  audit record and compaction recovery map. Cost if wrong: one extra internal
  execution artifact remains in history; deleting it would lose the audit
  trail the user explicitly requested.
- Task 4 Ruling: `t/00-pod/cookbook-examples.t` is an owned Task 4 file even
  though the plan's Files list omitted it. Step 5 explicitly runs that test,
  and it contains executable retired `compose(app => $router)` syntax coupled
  to the Cookbook POD Task 4 already owns. Update the assertion with the POD.
  Cost if wrong: one Task 7 documentation-test edit lands earlier than planned;
  leaving it would make Task 4's mandated focused gate knowingly fail.
- Task 5 Ruling: Task 4 already moved the executable apples root from
  `compose(app => router(...))` to `compose(router => router(...))`, while its
  README still shows the pre-migration form. Proceed directly to Task 5's
  approved final `compose(routes => ...)` shape and update the README to match.
  Cost if wrong: the intermediate Router-form state is not preserved in the
  example history; preserving it would knowingly retain a README/application
  mismatch and miss the canary's intended simplification.

## Deviations

None.

## Task review log

- Task 1: complete (commits `dab35e7..8801391`, review clean; spec compliance
  PASS, task quality PASS, no findings).
- Task 2: complete (commits `0b460bb..3e5dae3`, review clean; spec compliance
  PASS, task quality PASS, no findings).
- Task 3: complete (commits `8899a69..0368801`, review clean; spec compliance
  PASS, task quality PASS, no findings).
- Task 3: complete (commits `da561c6`; focused root-lifespan, middleware,
  mounted-boundary, and HEAD/buffering gate PASS; no production code changed).
- Task 4: complete (commit `f3e3972`; focused frontend, integration, upgrading,
  and Cookbook-example gate PASS: 6 files, 57 tests; no concerns).
- Task 4: fix round 1/5 (2 addressed, 0 open — corrected bare-Router safety
  and Cascade deployment prose; commit `669b51b`).
- Task 4: complete (commits `da55ee4..669b51b`, review clean after fix round
  1; both Important findings addressed, no new breakage).
- Task 5: complete (commits `ce986ec..61229a9`, review clean; spec compliance
  PASS, task quality PASS, no findings).
- Task 6: complete (commits `0ecf0eb..8769ea5`, review clean; spec compliance
  PASS, task quality PASS, no findings).
- Task 7: fix round 1/5 (2 addressed, 0 open — corrected the routes/router
  value-type distinction and restored Mount's exact target contract; commit
  `c49ba0d`).
- Task 7: complete (commits `df0c489..c49ba0d`, review clean after fix round
  1; both Important findings addressed, no new breakage).
- Task 5: complete (commit `ae8e37f`; RED exercised the new source-shape
  canaries; GREEN: `t/integration-starlette-apples.t` and
  `t/integration-large-application.t` passed. Reviewed the direct
  routes-form apples Compose and retained Router-form modular boundary; no
  concerns.)
- Task 6: complete (implementation commit `c1129e6`; RED source-shape
  failures identified retired live Compose app-mode examples; GREEN: 9 focused
  integrations / 109 tests passed, including the process-streaming terminal
  and client-disconnect contract. `sse-close`, `sse-dashboard`, and all
  WebSocket examples were inspected without protocol-semantic edits; no
  concerns.)
- Task 7: complete (implementation commit `8aa8283`; RED documentation
  assertions identified the retired Compose callable position, missing
  migration recipes, missing Starlette sources, and stale frontend/root
  distinction; GREEN: 3 focused files / 36 tests plus 11 clean POD syntax
  checks. Semantic searches leave only the three intentional `UPGRADING.md`
  before recipes; self-review found no concerns.)
