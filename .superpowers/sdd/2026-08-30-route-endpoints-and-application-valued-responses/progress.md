# SDD ledger — plan: docs/superpowers/plans/2026-08-30-route-endpoints-and-application-valued-responses.md

Starting HEAD: 8ffe0af3a4f59bc9ae0ef233375a7a0bd966484c

Work map: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/.worktrees/application-valued-route-endpoints` | ticket: none, approved WIP design campaign | branch: `feature/application-valued-route-endpoints` | base: `main@8ffe0af3a4f59bc9ae0ef233375a7a0bd966484c` | owns only PAGI-Tools code/tests/examples/live docs named by the plan | no deployment, merge, push, tag, or release | push target `origin/main` only after explicit user authorization. PAGI 0.002007 and PAGI::Server 0.002011 are read-only references.

Preserved source-checkout artifacts: `.pagi-0.4-alignment-tools-review.md`, `.pagi-0.4-alignment-tools-rulings.md`, `.pagi-0.5-settlement-streaming-correction.md`, `.pagi-0.5-settlement-testclient-audit-probe.pl`, `.pagi-0.5-settlement-testclient-audit.md`, `.superpowers/brainstorm/`, and `.superpowers/plans/`. They are outside this worktree and not owned.

Baseline: `prove -lv t/utils-to-app.t t/routing/01-constructors.t t/integration-starlette-apples.t` under Perl 5.42.2 — PASS, Files=3, Tests=21, output pristine.

| Task | Status | Implementation SHA | Review/fix SHAs | Focused verification and actual counts | Full-suite/build evidence | Verdict |
|---|---|---|---|---|---|---|
| 1 | complete | `e61872e` | `8a019b6`; review + scoped re-review clean | `/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/utils/application-values.t t/utils-to-app.t'` — PASS, Files=2, Tests=17; both required syntax checks exit 0 (pre-existing circular-load redefinition warnings recorded) | deferred to Task 13 | approved after fix round 1 |
| 2 | complete | `f79df5d` | independent task review clean | `/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/routing/17-request-response.t t/utils/application-values.t t/utils-to-app.t'` — PASS, Files=3, Tests=27; `perl -Ilib -c lib/PAGI/Routing/RequestResponse.pm` — PASS | deferred to Task 13 | approved |
| 3 | complete | `7021800` | independent task review clean; controller verified permitted half-migration | Perl 5.42.2: `prove -lv t/routing/01-constructors.t t/routing/03-reverse-inspection.t` — PASS, Files=2 Tests=29. Deferred files 05/08/09 inspected: all 35 failing subtests terminate at stale Compiler `is_raw` calls on lines 309/351; 2 protocol scope-gate subtests still pass. Syntax clean. | deferred to Task 13 | approved under recorded sequencing ruling |
| 4 | complete | `0264d2e` | independent task review clean | Perl 5.42.2: required gate PASS, Files=6 Tests=58; Compiler and RequestResponse syntax PASS; metadata audit HTTP subtests 1–9 PASS with only Task-5-owned protocol subtest failing at stale `_compile_protocol_leaf` `is_raw`; `git diff --check` PASS | deferred to Task 13 | approved |
| 5 | complete | `fc30cb9` | independent task review clean | Perl 5.42.2: non-loopback gate PASS, Files=3 Tests=48, no skips; host-only bounded SSE integration PASS, Files=1 Tests=1 (4 nested assertions), no skips; changed-file syntax and `git diff --check` PASS | deferred to Task 13 | approved |
| 6 | complete | `2bd79f0` | `3f13587`; original review found shallow arbitrary policy copy, fix round 1 re-review clean under DEV-01 | Perl 5.42.2: Pages gate PASS Files=7 Tests=303; Router gate PASS Files=2 Tests=24; Pages/Application/Compiler syntax and range diff checks PASS | deferred to Task 13 | approved after fix round 1 |
| 6A | complete | `bab9dd1` | independent task review clean | Perl 5.42.2: Response + protocol gate PASS Files=6 Tests=61; five module syntax checks, object-copy search, and `git diff --check` clean | deferred to Task 13 | approved DEV-02 implemented before Task 7 |
| 6B | complete | `5f37667` | independent scoped review clean | Perl 5.42.2: Request/Headers gate PASS Files=2 Tests=33; Request/test syntax, ownership search, and diff checks clean | deferred to Task 13 | approved DEV-03 implemented before Task 7 |
| 6C | complete | `2fa1bb4` | independent scoped review clean | Perl 5.42.2: Lifespan/Test Client gate PASS Files=2 Tests=19, no skips; module/test syntax, POD, shallow-copy search, and diff checks clean | deferred to Task 13 | approved DEV-04 implemented before Task 7 |
| 7 | complete | `46e3689` | `9ad82da`; scoped re-review clean | Perl 5.40.0: focused fix Files=2 Tests=13; final Task-7 gate Files=13 Tests=78; five syntax checks PASS | deferred to Task 13 | approved after fix round 1 |
| 8 | complete | `fd6c48f`; implementer `/root/task8_runtime_callers` | independent task review clean | Perl 5.40.0 ownership cone PASS Files=44 Tests=584; file/static PASS Files=7 Tests=128; WrapCGI PASS Files=1 Tests=4; host App::Proxy PASS Files=1 Tests=3 (17 nested); eighth frozen target executed with only ruled Task-10 example red; 23 syntax checks PASS | deferred to Task 13 | approved |
| 8A | complete | `3fbc0a0`; implementer `/root/task8a_security_test` | independent corrective review clean | Perl 5.42.2: `t/middleware/06-security.t` PASS Files=1 Tests=31; stale caller search and syntax/diff checks clean | deferred to Task 13 | approved |
| 9 | complete | `a3be036`; implementer `/root/task9_apples_canary` | independent task review clean | Perl 5.40 apples canary PASS, Files=1 Tests=4 (52 assertions in the main integration subtest); required stale-form search clean; README/app equality and Python digest pass | deferred to Task 13 | approved |
| 10 | complete | `ffc8ec3`; implementer `/root/task10_all_examples` | independent task review approved with one deferred Minor | Perl 5.42.2 all-example gate PASS Files=13 Tests=125; Cookbook PASS Files=1 Tests=4; reviewer focused rerun Files=3 Tests=20; stale gate clean | deferred to Task 13 | approved |
| 11 | complete | `8d14410`; base `3fbc0a0`; implementer `/root/task11_response_seam` | independent settlement-focused review clean | strict RED recorded; public surface PASS Files=3 Tests=35; critical PASS Files=9 Tests=88; recursive broad PASS Files=32 Tests=231; extra changed-file PASS Files=3 Tests=37; runtime/is_response removal and syntax/diff audits clean; exact 33 Task-12 POD residual retained | deferred to Task 13 | approved |
| 12 | complete | base `8d14410`; implementer `/root/task12_live_docs`; implementation `53c5443892fe5ff5592e4752406292e990c6c85d` | independent correction `474b01f`; prose correction `1f3e686`; independent re-review APPROVE | final docs gate PASS Files=4 Tests=47; mutable-router regression PASS Files=8 Tests=52; exact and expanded podchecker PASS | callable map, Route/Mount ownership, method/lifecycle sharp edges, Pages/Response/invoke_app/identity guidance reconciled; exact Task-11 33 POD calls reduced to zero live `lib` matches | approved after independent fix/re-review; `task-12-report.md` |
| 13 | complete | original runtime candidate `d06e521`; final-review correction/final runtime candidate `b19c815b23800c9bcd40f13e30cd6bf4aeb4938f`; earlier cleanup `fa615f5..d06e521` | final reviews found 1 Important and 2 Minor; all corrected in `b19c815` | original canary PASS Files=6 Tests=47; settlement PASS Files=6 Tests=73; final correction PASS Files=4 Tests=34; broad affected gate PASS Files=14 Tests=122 | original suite PASS Files=218 Tests=2371; corrected suite PASS Files=218 Tests=2373; each has one release-only file skip and 40 wallclock seconds; corrected syntax/diff/build exit 0; artifact 956814 bytes | corrected implementation/audit complete; `task-13-report.md` |

## Preflight interface scan

## Task 11 frozen final direct-call inventory

Recorded by `/root/task11_response_seam` before any Task 11 test or production
edit with `rg -n -- '->respond\(' lib t`. The command returned 96 call
occurrences across 19 files. Every occurrence is classified below using the
Task 11 categories; line numbers are the frozen pre-edit positions.

| Required classification | Frozen occurrences | Disposition |
| --- | --- | --- |
| base implementation | `lib/PAGI/Response.pm:438`; `t/response/01-base.t:148,171,176,180,183`; `t/response/02-buffered.t:24,201,309,337,409`; `t/response-value.t:9`; `t/upgrading-response-family.t:165,170` | Task 11 seam/tests. |
| File implementation | `lib/PAGI/Response/File.pm:237`; `t/response/04-file.t:56,93,105,122,203,238,463,483,501,549`; `t/34-directory-security.t:117`; `t/app-file-resolution.t:456` | Task 11 seam/tests. |
| Stream implementation | `lib/PAGI/Response/Stream.pm:220`; `t/response/03-stream.t:57,100,225,233,235`; `t/response-writer.t:150,188,243,266,290,321,359,374,400,418,439,465,497,526,555,583,644,705,743,777,807,836,873,908,932,962,985,1000` | Task 11 seam/tests. |
| denial/decline adapter | `lib/PAGI/Response.pm:699` | Task 11 shared adapter; settlement-sensitive. |
| subclass fixture | none among literal arrow calls | Inherited override/SUPER spellings are inventoried in `task-11-report.md`. |
| stale caller — Task-12-owned non-executable documentation | `lib/PAGI/Response.pm:80,115`; `lib/PAGI/App/Cascade.pm:23`; `lib/PAGI/Pages.pm:1099,1308`; `lib/PAGI/Request.pm:1181`; `lib/PAGI/Routing.pm:331`; `lib/PAGI/Tools/Tutorial.pod:53,61,604,656,1307,1316,1323`; `lib/PAGI/Tools/Cookbook.pod:626,631,1810,1822,1833,1860,1894,2203,2259,2265,2299,2304,2351,2354,2557,2564,2569,2576,2674` | Exact 33-match Task 12 documentation inventory; ruled out of Task 11, not an ordinary runtime caller. |
| stale caller — initial blocker | `t/middleware/06-security.t:1232` | Task 8A commit `3fbc0a0` corrected this before Task 11 RED; refreshed inventory has zero stale ordinary executable callers. |

Task 11 is `NEEDS_CONTEXT`: Task 8 must correct or the controller must explicitly
reclassify `t/middleware/06-security.t:1232`; the controller must also reconcile
Task-12 live-doc ownership with Task 11's final literal `rg ... lib` no-match gate.

Resolution: Task 8A commit `3fbc0a0` migrated the executable stale caller and
passed independent review. Task 11 now enforces zero executable runtime matches
while carrying the exact non-executable POD inventory to Task 12, which owns the
eventual literal all-`lib` no-match gate.

Refreshed at `3fbc0a0` before Task 11 test or production edits: 95 calls across
18 files, comprising the same 62 Task-11-owned base/File/Stream/adapter and
implementation-test calls above, zero stale ordinary executable callers, and
the exact same 33 Task-12-owned non-executable POD calls above. This refreshed
blocker-free inventory is the Task 11 implementation baseline.

## Task 11 implementation evidence

- Strict RED before production: Response/File/Stream and subclass public-surface
  failures plus Utils export/removal failures, Files=2 Tests=25; after the ruled
  upgrading-test prerequisite migration, that exact file failed only the public
  `respond` absence assertion, Files=1 Tests=10.
- Public-surface GREEN: Files=3 Tests=35.
- Immediate critical settlement GREEN: Files=9 Tests=88.
- Recursive broad Response/WebSocket/SSE GREEN: Files=32 Tests=231.
- Additional changed File integration/Utils GREEN: Files=3 Tests=37.
- Mechanical audit: Base/File/Stream rename only; WebSocket/SSE production zero
  diff; File capability remains `undef`; no lifecycle, writer, range, mapping,
  event, copying, or error-text change.
- Removal/audit: zero executable runtime `->respond(`, zero test arrow callers,
  zero `is_response` in `lib`, exact 33 ruled POD matches retained, four changed
  modules syntax OK, and `git diff --check` clean.

## Task 10 frozen all-examples migration inventory

Recorded by `/root/task10_all_examples` before any test or example edit with
`find examples -mindepth 1 -maxdepth 1 -type d -print | sort`. All 20 returned
directories are maintained and in scope.

| Example | Affected? | Frozen old form(s) | Intended final form | Exact executable/load test |
| --- | --- | --- | --- | --- |
| `09-psgi-bridge` | no | none | existing native WrapPSGI application | new all-examples load assertion |
| `10-chat-showcase` | yes | `raw =>` HTTP/WS/SSE leaves | Request handlers returning Responses; native protocol CODE via `as_app` | `t/integration-chat-compose.t` |
| `13-contact-form` | yes | direct `respond` | raw-triplet `invoke_app` | `t/integration-app-file-examples.t` |
| `14-lifespan-utils` | yes | source-first `_page`, direct `respond` | source-free Pages app plus `invoke_app` | `t/integration-lifespan-utils-example.t` |
| `15-large-application` | yes | `_page`, `request_app` defaults | returned Pages apps; `request_response` defaults | `t/integration-large-application.t` |
| `app-01-file` | no | none | existing file app | `t/integration-app-file-demo.t` |
| `background-tasks` | yes | `raw =>`, direct `respond` | Route `as_app`; `invoke_app`; native Mount CODE direct | `t/integration-router-application-boundaries.t` |
| `compose` | no | none | existing returned Response | `t/integration-compose-demo.t` |
| `declarative-routing` | yes | `_page`, `request_app` defaults | returned Pages apps; `request_response` defaults | `t/integration-declarative-routing-demo.t` |
| `endpoint-demo` | yes | source-first Pages, direct `respond` | source-free Pages app plus `invoke_app` | `t/integration-app-file-examples.t` |
| `endpoint-router-demo` | yes | `_page`, direct `respond` | `app_as` native default; `invoke_app`; returned Pages app | `t/integration-endpoint-router-demo.t` |
| `full-demo` | yes | `raw =>` native leaves | native Route CODE via `as_app` | new all-examples load assertion |
| `pages` | yes | `_page`, source-first factories, `request_app`, `raw =>`, direct `respond` | class/configured/export apps; direct Route/Mount; request-derived return; `as_app` + `invoke_app`; Compose root | `t/integration-pages-example.t` |
| `sse-close` | no | none | existing native app | new all-examples load assertion |
| `sse-dashboard` | no | none | existing native/File app | `t/integration-app-file-examples.t` |
| `starlette-apples` | no; Task 9 migrated | none | preserve Task 9 application-valued forms | `t/integration-starlette-apples.t` |
| `test-lifespan-shutdown` | yes | source-first `_page`, direct `respond` | source-free Pages app plus `invoke_app` | new all-examples load assertion |
| `websocket-bidirectional` | no | none | existing native app | new all-examples load assertion; source checks in `t/integration-app-file-examples.t` |
| `websocket-chat-v2` | yes | source-first Pages, direct `respond` | source-free Pages apps plus `invoke_app` | `t/integration-websocket-chat-v2.t` |
| `websocket-echo-v2` | no | none | existing native app | new all-examples load assertion |

Frozen stale-form gate: `rg -n "request_app|raw =>|_page\\b|->respond\\(|is_response" examples`
returned 84 matches. Exact output:

```text
examples/declarative-routing/app.pl:7:use PAGI::Pages qw(not_found_page);
examples/declarative-routing/app.pl:8:use PAGI::Routing qw(:routes request_app);
examples/declarative-routing/app.pl:14:    return not_found_page($request, detail => 'No API route matched');
examples/declarative-routing/app.pl:19:    return not_found_page($request, detail => 'No root route matched');
examples/declarative-routing/app.pl:55:    http_default => request_app(\&api_not_found),
examples/declarative-routing/app.pl:72:    http_default => request_app(\&root_not_found),
examples/test-lifespan-shutdown/app.pl:5:use PAGI::Pages qw(not_found_page);
examples/test-lifespan-shutdown/app.pl:31:    my $response = not_found_page($scope, as => 'text');
examples/test-lifespan-shutdown/app.pl:32:    return await $response->respond($scope, $receive, $send);
examples/declarative-routing/lib/MyApp/Routes/Home.pm:6:use PAGI::Pages qw(not_found_page);
examples/declarative-routing/lib/MyApp/Routes/Home.pm:28:    return not_found_page($request,
examples/13-contact-form/app.pl:42:        return await $response->respond($scope, $receive, $send);
examples/background-tasks/app.pl:153:$router->get('/', raw => async sub {
examples/background-tasks/app.pl:192:    await $response->respond($scope, $receive, $send);
examples/background-tasks/app.pl:196:$router->get('/async', raw => async sub {
examples/background-tasks/app.pl:204:    await $response->respond($scope, $receive, $send);
examples/background-tasks/app.pl:215:$router->get('/blocking', raw => async sub {
examples/background-tasks/app.pl:223:    await $response->respond($scope, $receive, $send);
examples/background-tasks/app.pl:231:$router->post('/signup', raw => async sub {
examples/background-tasks/app.pl:243:    await $response->respond($scope, $receive, $send);
examples/websocket-chat-v2/lib/ChatApp/HTTP.pm:65:            return await $response->respond($scope, $receive, $send);
examples/websocket-chat-v2/lib/ChatApp/HTTP.pm:78:            return await $response->respond($scope, $receive, $send);
examples/websocket-chat-v2/lib/ChatApp/HTTP.pm:89:        return await $response->respond($scope, $receive, $send);
examples/pages/app.pl:9:    welcome_page redirect_page not_found_page gone_page
examples/pages/app.pl:11:use PAGI::Routing qw(router route mount request_app);
examples/pages/app.pl:14:    route('/' => \&welcome_page, name => 'welcome'),
examples/pages/app.pl:17:        return redirect_page($request, '/new', status => 308);
examples/pages/app.pl:19:    route('/missing' => \&not_found_page),
examples/pages/app.pl:20:    mount('/terminal', app => request_app(\&gone_page)),
examples/pages/app.pl:23:        my $response = not_found_page($request, as => 'text');
examples/pages/app.pl:27:    route('/raw', raw => async sub {
examples/pages/app.pl:29:        my $response = not_found_page($scope, as => 'text');
examples/pages/app.pl:31:        await Future->wrap($response->respond($scope, $receive, $send));
examples/14-lifespan-utils/app.pl:2:use PAGI::Pages qw(welcome_page);
examples/14-lifespan-utils/app.pl:21:    my $response = welcome_page($scope, as => 'text');
examples/14-lifespan-utils/app.pl:22:    return await $response->respond($scope, $receive, $send);
examples/endpoint-demo/app.pl:179:                return await $response->respond($scope, $receive, $send);
examples/background-tasks/README.md:53:await $response->respond($scope, $receive, $send);
examples/pages/README.md:25:redirect handler. `mount('/terminal', app => request_app(\&gone_page))`
examples/pages/README.md:34:route('/' => \&welcome_page);
examples/pages/README.md:35:route('/missing' => \&not_found_page);
examples/pages/README.md:39:`not_found_page($request)` returns an ordinary unsent concrete Response; the
examples/pages/README.md:45:    my $response = not_found_page($request, as => 'text');
examples/pages/README.md:56:route('/raw', raw => async sub {
examples/pages/README.md:58:    my $response = not_found_page($scope, as => 'text');
examples/pages/README.md:60:    await Future->wrap($response->respond($scope, $receive, $send));
examples/pages/README.md:65:`request_app(\&handler)` for Mount, Compose `app`, or another native placement.
examples/14-lifespan-utils/README.md:29:scope, it constructs `welcome_page($scope, as => 'text')` and explicitly emits
examples/endpoint-demo/README.md:88:return await $response->respond($scope, $receive, $send);
examples/15-large-application/README.md:64:- Root and Blogs adapt named `not_found_page` Request handlers with
examples/15-large-application/README.md:65:  `request_app(...)` for their Router `http_default` values. The details
examples/15-large-application/README.md:68:- Root's named `/pagi` route returns `welcome_page($request)`. The home
examples/15-large-application/lib/MyApp/Person/Blogs.pm:5:use PAGI::Pages qw(not_found_page);
examples/15-large-application/lib/MyApp/Person/Blogs.pm:7:use PAGI::Routing qw(router route request_app);
examples/15-large-application/lib/MyApp/Person/Blogs.pm:91:    return not_found_page($request,
examples/15-large-application/lib/MyApp/Person/Blogs.pm:108:        http_default => request_app(\&blogs_not_found),
examples/endpoint-router-demo/lib/MyApp/API.pm:6:use PAGI::Pages qw(not_found_page unauthorized_page);
examples/endpoint-router-demo/lib/MyApp/API.pm:43:    my $response = not_found_page($scope,
examples/endpoint-router-demo/lib/MyApp/API.pm:45:    await $response->respond($scope, $receive, $send);
examples/endpoint-router-demo/lib/MyApp/API.pm:57:        my $response = unauthorized_page($scope,
examples/endpoint-router-demo/lib/MyApp/API.pm:60:        return await $response->respond($scope, $receive, $send);
examples/endpoint-router-demo/lib/MyApp/API.pm:90:    return not_found_page($request,
examples/15-large-application/lib/MyApp/Root.pm:6:use PAGI::Pages qw(welcome_page not_found_page);
examples/15-large-application/lib/MyApp/Root.pm:8:use PAGI::Routing qw(router route mount request_app);
examples/15-large-application/lib/MyApp/Root.pm:41:    return welcome_page($request);
examples/15-large-application/lib/MyApp/Root.pm:45:    return not_found_page($request,
examples/15-large-application/lib/MyApp/Root.pm:69:        http_default => request_app(\&root_not_found),
examples/full-demo/app.pl:32:$router->get('/', raw => async sub {
examples/full-demo/app.pl:48:$router->post('/echo', raw => async sub {
examples/full-demo/app.pl:85:$router->get('/stream', raw => async sub {
examples/full-demo/app.pl:120:$router->websocket('/ws/echo', raw => async sub {
examples/full-demo/app.pl:158:$router->sse('/events', raw => async sub {
examples/10-chat-showcase/app.pl:77:$router->websocket('/ws/chat', raw => $ws_handler);
examples/10-chat-showcase/app.pl:78:$router->sse('/events', raw => $sse_handler);
examples/full-demo/README.md:104:$router->get('/', raw => async sub { ... })->name('hello');
examples/full-demo/README.md:105:$router->post('/echo', raw => async sub { ... })->name('echo');
examples/full-demo/README.md:106:$router->websocket('/ws/echo', raw => async sub { ... });
examples/full-demo/README.md:107:$router->sse('/events', raw => async sub { ... });
examples/endpoint-router-demo/README.md:96:through `unauthorized_page($scope, ...)` and explicitly emitted with the full
examples/endpoint-router-demo/README.md:102:`not_found_page($request, ...)` returns an unsent Response value,
examples/10-chat-showcase/lib/ChatApp/HTTP.pm:99:    $router->get('/api/rooms', raw => _rooms_handler());
examples/10-chat-showcase/lib/ChatApp/HTTP.pm:100:    $router->get('/api/room/{name}/history', raw => _room_history_handler());
examples/10-chat-showcase/lib/ChatApp/HTTP.pm:101:    $router->get('/api/room/{name}/users', raw => _room_users_handler());
examples/10-chat-showcase/lib/ChatApp/HTTP.pm:102:    $router->get('/api/stats', raw => _stats_handler());
```

## Task 8 frozen ownership inventory

Recorded before any Task 8 production or test source edit. The literal first
Step 1 command, `rg -n -- '->respond\(' lib --glob '*.pm'`, returned the listed
matches but exited 2 because this ripgrep treats `--glob` and `*.pm` after `--`
as paths. The intended equivalent, `rg -n --glob '*.pm' -- '->respond\(' lib`,
was also run successfully. The second literal command,
`rg -n 'PAGI::Pages->|_page\(' lib --glob '*.pm'`, exited 0. Exact raw output
for both searches is frozen in `task-8-report.md`.

| Hit(s) | Owner / disposition | Focused tests |
| --- | --- | --- |
| `App/URLMap.pm:92-93` | Task 8 executable migration | `t/app/02-routing.t`, `t/app/07-routing-composition.t` |
| `App/Loader.pm:57-58`, `App/Throttle.pm:126-131`, `App/Healthcheck.pm:75` | Task 8 executable migration | `t/app/04-utilities.t` |
| `App/WrapCGI.pm:136-137`, `App/Proxy.pm:152-153` | Task 8 executable migration | `t/app-wrapcgi-env.t`, `t/app-proxy.t` |
| `App/File.pm:341,392,396,398,416,445,449`, `App/Directory.pm:164,214,255` | Task 8 executable migration | `t/app-file.t`, `t/app-file-resolution.t`, `t/integration-app-file-demo.t`, `t/integration-app-file-examples.t`, `t/34-directory-security.t`, `t/middleware/04-static.t`, `t/middleware/15-xsendfile.t`, `t/response/04-file.t` |
| `Middleware/RateLimit.pm:195-204` | Task 8 executable migration | `t/middleware/rate-limit.t`, `t/middleware/08-flow-control.t` |
| `Middleware/JSONBody.pm:174-185`, `FormBody.pm:174-175`, `ContentNegotiation.pm:135-139` | Task 8 executable migration | `t/middleware/09-body-parsing.t` |
| `Middleware/ErrorHandler.pm:190-202,242` | Task 8 executable migration | `t/middleware/03-error-handler.t`, `t/middleware/error-handler-contract.t`, `t/compose/04-middleware.t` |
| `Middleware/HTTPSRedirect.pm:175,181-182`, `Rewrite.pm:158`, `ReverseProxy.pm:241-242` | Task 8 executable migration | `t/middleware/11-url-handling.t` |
| `Middleware/CORS.pm:146`, `CSRF.pm:217-218`, `TrustedHosts.pm:170-171` | Task 8 executable migration | `t/middleware/06-security.t`, `t/33-csrf-timing-safe.t` |
| `Middleware/Maintenance.pm:188-203`, `Healthcheck.pm:116,135,155` | Task 8 executable migration | `t/middleware/13-development.t` |
| `Middleware/Auth/Basic.pm:168-171`, `Auth/Bearer.pm:264-269` | Task 8 executable migration | `t/middleware/10-session-auth.t` |
| `Routing/Compiler.pm:125,162`, `Endpoint/HTTP.pm:62` | executable and already source-free; Task 8 audit/no edit | `t/routing/05-http-dispatch.t`, `t/routing/16-http-outcomes.t`, `t/endpoint/02-http-dispatch.t` |
| `Response.pm:80,115,438,699`, `Response/File.pm:237`, `Response/Stream.pm:220` | Task 11-reserved Response/protocol-settlement internals | `t/response/01-base.t`, `t/response/03-stream.t`, `t/response/04-file.t`, `t/websocket/denial-response.t`, `t/sse/13-decline.t` |
| `Pages.pm:1077,1084,1096,1099,1139,1192,1199,1216,1300,1308`, `Request.pm:1181`, `Routing.pm:331,554`, `Tools.pm:67`, `App/Router.pm:42`, `App/Cascade.pm:22-23`, `Middleware/ErrorHandler.pm:78`, `Middleware/CSRF.pm:277` | POD only, non-executable; Task 12 documentation inventory | `t/00-pod/cookbook-examples.t` where applicable; Task 12 live-doc gate |

The frozen file/static discovery output is, exactly:

```text
t/integration-app-file-examples.t
t/app-file-resolution.t
t/app-file-script-static/marker.txt
t/app-file.t
t/integration-app-file-demo.t
t/static_test_files/app.js
t/static_test_files/hello.txt
t/static_test_files/style.css
t/34-directory-security.t
t/app-file-fixtures/two/static/marker.txt
t/static_test_files/index.html
t/response/04-file.t
t/static_test_files/subdir/file.txt
t/middleware/04-static.t
t/app-file-fixtures/two/lib/TestApps/AppFile/Two.pm
t/middleware/15-xsendfile.t
t/app-file-fixtures/one/lib/TestApps/AppFile/One.pm
t/app-file-fixtures/one/static/nested/marker.txt
t/app-file-fixtures/one/static/marker.txt
t/app-file-fixtures/one/static/index.html
```

The eight `.t` paths are mandatory Task 8 prove targets; all other discovered
paths are fixtures/inventory inputs and are not prove targets.

| Tasks | Producer / consumer seam | Finding and ruling |
|---|---|---|
| 1 self | Tests introduce `as_app` and `invoke_app`; code creates only the adapters those tests require | Consistent. |
| 2 self | RequestResponse tests precede its class and Utils factory | Consistent; it consumes Task 1 `invoke_app`. |
| 3 self | Route tests replace `target`/`is_raw` and define method precedence before constructor changes | Consistent. |
| 4 self | Compiler tests pin static/dynamic compilation and Allow/HEAD before implementation | Consistent. |
| 5 self | Protocol tests remove raw classification while retaining direct handler completion | Consistent. |
| 6 self | Pages tests move negotiation from factory time to invocation time | Consistent; existing validation remains owned. |
| 7 self | Frontend and Endpoint tests move together so no frontend gets a separate contract | Consistent. |
| 8 self | Runtime callers migrate semantically without touching Response settlement internals | Consistent. Ruling: directory discovery commands are not test evidence; run the exact files they discover. |
| 9 self | Apples executable, copied README source, and integration canary migrate together | Consistent. |
| 10 self | Every example gets a matrix row and an executable load/integration gate | Consistent. |
| 11 self | Public emission removal happens after caller migration and is mechanically constrained | Consistent. Ruling: recursive test directories use `prove -lvr`, or exact files, never a bare non-recursive directory assumption. |
| 12 self | Live docs follow runtime completion and historical specs remain untouched | Consistent. |
| 13 self | Final searches, focused canaries, one full suite, one build | Consistent. |
| 1 → 2 | `invoke_app`/`as_app` are consumed by RequestResponse | Clean dependency; Task 2 must not duplicate normalization. |
| 1 → 3 | `as_app` is the explicit native-CODE Route marker | Clean dependency; Route classifies only top-level CODE versus object. |
| 2 → 4 | RequestResponse is the sole HTTP CODE endpoint adapter | Clean dependency; Compiler must compile it once per Router compilation. |
| 3 → 4 | Route exposes `endpoint` and resolved `methods` | Clean dependency; Compiler must not re-query `allowed_methods`. |
| 3 → 5 | Protocol Routes share endpoint classification but not HTTP capabilities | Clean dependency; protocol compiler ignores method metadata. |
| 3 → 7 | Mutable builders materialize the immutable Route contract | Clean dependency; builders store `endpoint`, not a parallel mode. |
| 4 → 6 | Compiler defaults and generated 405s consume Pages apps | Transitional old Pages result is already an app; Task 6 removes source arguments and direct emission. |
| 4 → 7 | Router owns PARTIAL/Allow for routed Endpoint::HTTP objects | Clean dependency; Endpoint keeps standalone 405 only. |
| 5 → 11 | Protocol response mapping is settlement-sensitive | Task 5 verifies behavior; Task 11 changes only the invocation seam and repeats the gate. |
| 6 → 8 | First-party Pages callers must drop source-first invocation | Clean dependency; Task 8 owns all runtime callers. |
| 6/7 → 9 | Apples uses deferred Pages, object endpoints, and Router defaults | Clean dependency; Task 9 is the first integration canary. |
| 6/7 → 10 | Remaining examples consume the final Pages/frontend contracts | Clean dependency; example migration is not optional cleanup. |
| 8 → 11 | All public `respond` callers must be gone before the method is removed | Load-bearing gate; stale callers return to Task 8 before Task 11 proceeds. |
| 9 → 10 | Dedicated apples work precedes the all-examples pass | No overlap conflict; Task 10 records apples as already migrated and reruns only its final stale-form audit. |
| 11 → 12 | POD must describe only `to_app`/`invoke_app` after public `respond` is gone | Clean dependency. |
| 12 → 13 | Live docs and upgrade Before blocks feed final searches | Clean dependency; historical superpowers records remain exempt. |

## Rulings

- Ruling: the worktree skill's generic full-baseline instruction conflicts with the approved plan's single full-suite boundary; use the focused utility/Route/apples baseline above and reserve `prove -lr t` for Task 13 — cost if wrong: a pre-existing failure outside these canaries may surface only at the final suite.
- Ruling: Task 8 and Task 11 directory test commands are discovery shorthand; execution must use `prove -lvr` or exact discovered files and record unsuppressed results — cost if wrong: a subdirectory could otherwise be skipped silently.
- Ruling: Task 3 removes `target`/`is_raw` before Tasks 4–5 migrate Compiler consumers, so Compiler-invoking portions of `t/routing/05-http-dispatch.t` and `t/routing/08-protocols.t` may remain red only when inspection ties the failure exactly to those removed accessors. Do not add compatibility accessors or prematurely implement later dispatch behavior; Task 3's green ownership is construction, reverse inspection, and metadata. Cost if wrong: a genuine description-layer regression could be misclassified as a half-migration, so every deferred failure must name its exact Compiler call and later owner.
- Ruling: Task 4 may also update `lib/PAGI/Routing/RequestResponse.pm` and `t/routing/17-request-response.t` to correct the load-bearing Task 2 scalar-context defect discovered during Compiler integration. Add the focused scalar-context assertion first, preserve the RED evidence, then make only the minimal scalar capture before `Future->wrap`; do not restructure the adapter. Cost if wrong: Task 4's diff includes repair of a preceding contract, so its independent review must inspect this change explicitly rather than attributing every changed line to Compiler work.
- Ruling: `PAGI::Headers->new($pairs)` continues to copy its documented plain input pairs. Constructor independence is expected `new` semantics, unlike the removed automatic copy from `Request->headers`; callers who want shared mutation retain the constructed Headers object, while callers wanting another independent container use explicit `clone`. Cost if wrong: raw scope pairs and a constructed Headers container intentionally remain separate representations, so mutation of one does not rewrite the other.
- Ruling: Task 8 runs `t/app-proxy.t` with host access after the implementer commit because its loopback socket is denied by the workspace sandbox; no code workaround or skipped semantic assertion is permitted. Cost if wrong: a real App::Proxy regression could be misclassified as an environment failure, so independent host execution must pass before Task 8 review.
- Ruling: Task 8 may record `t/integration-app-file-examples.t` as expected sequencing red only when the failure is the Task-10-owned stale source-first Pages call in `examples/endpoint-demo/app.pl`; Task 8 must not edit examples. Cost if wrong: a File/Directory runtime regression could be hidden behind the example failure, so the agent must show all other owned tests green and Task 10 must make this exact integration green.
- Ruling: Task 11's literal `rg -n -- '->respond\(' lib` conflicts with Task 12's explicit ownership of live POD migration. Task 11 must produce zero executable runtime matches and retain an exact inventory of non-executable POD matches for Task 12; Task 12 must make the literal repository search clean. Cost if wrong: stale executable code could be mislabeled as documentation, so Task 11's inventory must classify every match and its review must verify the runtime/documentation boundary.
- Ruling: Task 11 may migrate only the stale executable Pages block in `t/upgrading-response-family.t`, because that required broad-gate file already receives Task-11 public-surface assertions and cannot compile against the Task-6 Pages API. Replace `not_found_page`/`request_app` with direct `not_found()` application placement; do not broaden into live documentation or production. Cost if wrong: the nominally mechanical Task-11 commit includes one prerequisite test-contract migration, so the task review must inspect it separately and reject any production or behavioral scope expansion.

## Task completion log

- Task 1: fix round 1/5 (3 addressed, 0 open — exact-one-argument validation, immutable wrapped CODE, and covering boundary tests; commit `8a019b6`).
- Task 1: complete (commits `8ffe0af..8a019b6`, review clean after scoped re-review).
- Task 2: complete (commit `f79df5d`, review clean).
- Task 2: complete (commit `f79df5d`; RequestResponse creates a request-local facade, delegates returned app values through Task 1 `invoke_app`, and focused GREEN is clean).
- Task 3: complete (commit `7021800`, review clean; old Compiler failures independently verified and assigned to Tasks 4–5).
- Task 4: complete (commit `0264d2e`, independent review clean; static HTTP endpoints compile once per Router compilation, returned applications normalize per request without caching, scalar handler context is repaired, and the only residual red is the Task-5-owned protocol accessor).
- Task 5: complete (commit `fc30cb9`, independent review clean; protocol CODE/object classification is explicit, `as_app` is the sole native-CODE marker, method capabilities do not leak into protocols, and denial/decline settlement implementations remain untouched).
- Task 6: fix round 1/5 (1 High addressed, 0 open — removed arbitrary shallow policy copying; configured Pages objects are retained exactly and subclass state is explicitly shared/subclass-owned under DEV-01; commit `3f13587`).
- Task 6: complete (commits `2bd79f0..3f13587`, independent re-review clean; Pages Files=7 Tests=303 and Router Files=2 Tests=24 pass under Perl 5.42.2).
- Task 6A: complete (commit `bab9dd1`, independent review clean; exact Response objects retained, plain per-invocation Base/Stream delivery values and existing File Plan captured before start, Redirect/Problem invariants preserved, and Response/protocol gate PASS Files=6 Tests=61 under Perl 5.42.2).
- Task 6B: complete (commit `5f37667`, independent scoped review clean; Request returns its exact cached Headers object, deliberate mutation is visible across Request accessors, and explicit caller cloning remains available; focused gate PASS Files=2 Tests=33 under Perl 5.42.2).
- Task 6C: complete (commit `2fa1bb4`, independent scoped review clean; Lifespan injects state into and passes the exact request scope, supplied/shared state identity is retained, and focused gate PASS Files=2 Tests=19 under Perl 5.42.2; stale Pages example failure remains Task-10-owned).
- Task 7: review findings entering fix round 1/5 — Important: standalone/mounted `Endpoint::HTTP` dispatch can execute unrelated helper methods; explicit `methods => undef` presence is lost during App::Router materialization. Minor (deferred to final review): strengthen direct `methods => '*'`/object-dispatch coverage; reconcile Task-7 live POD edits with Task-12 documentation ownership.
- Task 7: fix round 1/5 (2 addressed, 0 open — Endpoint dispatch is gated by its advertised method capability; explicit `methods => undef` reaches immutable Route validation; commit `9ad82da`).
- Task 7: complete (commits `46e3689..9ad82da`, scoped re-review clean; final gate Files=13 Tests=78). Out-of-scope documentation observation deferred to Task 12/final review: stale Route POD still mentions raw marker semantics.
- Task 8: implementation commit `fd6c48f` ready for review; 23 first-party runtime modules now delegate exact application values through `invoke_app`, source-first Pages arguments are absent from executable callers, focused tests use the final application-valued Route/Pages contracts, and only the ruled Task-10 example red plus controller-owned host App::Proxy rerun remain.
- Task 8: complete (commit `fd6c48f`, independent review clean; all owned runtime callers use source-free Pages factories and `invoke_app` with exact channels; Task-11 response/protocol internals untouched; host App::Proxy gate clean; sole remaining integration red is the ruled Task-10 endpoint-demo caller).
- Task 9: complete (commit `a3be036`, implementer `/root/task9_apples_canary`; direct `welcome()` Route and `not_found(...)` Router default work without adapters; Perl 5.40 apples canary PASS Files=1 Tests=4, 52 main-subtest assertions; Python digest and README/app equality retained; required stale-form search clean).
- Task 9: independent review clean; no findings.
- Task 10: complete at `ffc8ec3` by `/root/task10_all_examples`; froze all 20 maintained directories (12 affected, 8 unaffected), preserved RED at Files=13 Tests=114, added six missing/undercovered load assertions plus full Pages executable coverage, and reached GREEN Files=13 Tests=125 plus Cookbook Files=1 Tests=4. Final all-examples stale-form search has no matches; ready for independent review.
- Task 10: independent review approved. Minor (deferred to Task 12/final review): `PAGI::Tools::Cookbook` still calls direct `welcome()` an ordinary function handler despite the synchronized Route now containing a Pages application value.
- Task 8A: complete (commit `3fbc0a0`, independent corrective review clean; final stale first-party test caller now delegates through `invoke_app`; security gate Files=1 Tests=31).
- Task 11: complete (commit `8d14410`, independent settlement-focused review clean; production seam rename mechanical; public Files=3 Tests=35, critical Files=9 Tests=88, broad Files=32 Tests=231, extra Files=3 Tests=37; zero executable `respond`/`is_response`; exact 33 POD calls carried to Task 12).
- Task 12: complete (implementation `53c5443`; independent correction
  `474b01f`; prose correction `1f3e686`; independent re-review APPROVE;
  final documentation Files=4 Tests=47 and mutable-router Files=8 Tests=52
  passed).
- Task 13: scoped final-search correction `fa615f5` removed Router's stale
  `target`/`is_raw` accessors and the unused private Pages
  `_named_page_functions`; correction `d06e521` enforced the user ruling that
  Router remains collection-only and must not gain an `endpoint` accessor.
- Task 13: original implementation/audit complete at runtime candidate
  `d06e521`. Final reviews found one Important frontend-parity defect and two
  Minor cleanup/example findings; `b19c815` corrects all three without a
  compatibility shim or dispatch special case and is the final runtime
  candidate.

## Task 13 final verification evidence

### Work map and repository boundaries

- PAGI-Tools worktree/branch/base remained
  `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/.worktrees/application-valued-route-endpoints`,
  `feature/application-valued-route-endpoints`, and
  `main@8ffe0af3a4f59bc9ae0ef233375a7a0bd966484c`.
- Ticket: none. Deployment/publish boundary: no deploy, merge, push, tag, or
  release. Push target remains `origin/main` only after explicit authorization.
- PAGI stayed clean at `main@822d0a2014b31e62174e87af650cd5737415173c`;
  PAGI-Server stayed clean at
  `main@c6b304ced1e6c03c62d600574c998983efa9e703`. Neither was modified.
- All seven preserved source-checkout artifact groups named at the top of this
  ledger were present. All 20 maintained example directories were inspected;
  each has an `app.pl`, a README, an executable/load-test mapping from Task 10,
  and no unclassified forbidden form.

### Final surface/search correction

- Initial audit found two real residuals: Router still exposed retired
  `target`/`is_raw` compatibility accessors, and Pages retained the unused
  private `_named_page_functions` generator for removed `*_page` names.
- Focused RED before the Router correction:
  `prove -lv t/routing/01-constructors.t` failed one new public-surface
  assertion (Files=1, Tests=11, exit 1).
- Commit `fa615f5` removed both residuals and added absence coverage. Commit
  `d06e521` then removed an accidentally proposed Router `endpoint` accessor
  and corrected its POD, preserving the explicit collection-only ruling.
- Final focused correction gate under Perl 5.42.2:
  `prove -lv t/routing/01-constructors.t t/pages/03-invocation-composition.t`
  — PASS, Files=2, Tests=17, exit 0; `podchecker
  lib/PAGI/Routing/Router.pm` — syntax OK, exit 0.
- Final exact forbidden-form command returned 87 lines. Manual classification:
  1 historical `Changes` removal record; 19 labelled `UPGRADING.md`
  Before/removal/absence lines; 1 ordinary `missing_page` local; 28 unrelated
  raw query/form byte options/tests; 14 ordinary private/local identifiers;
  24 negative-removal tests. Zero line implements or endorses a retired current
  surface. Historical superpowers records were excluded.
- `public-surface-inventory.md` classifies and evidences every row as retained,
  replaced by approved design, or deferred by approved design.

### Focused gates at candidate `d06e521`

- Canary command: PASS, Files=6, Tests=47, exit 0, 2 wallclock seconds,
  real 1.72s (user 1.40s, sys 0.19s), no skips.
- Settlement command in the workspace sandbox: the five unit files passed;
  `t/integration/sse-decline-end-to-end.t` could not bind loopback and the
  command exited 1 (Files=6, Tests=73, real 1.55s). No product assertion failed.
- The same settlement command with host loopback access: PASS, Files=6,
  Tests=73, exit 0, 3 wallclock seconds, real 2.70s (user 1.26s, sys 0.20s),
  no skips. No code changed between the environment failure and host pass.

### Single repository-wide suite at candidate `d06e521`

- Command: `prove -lr t`, Perl 5.42.2, host access for loopback integrations.
- PASS, Files=218, Tests=2371, exit 0, 40 wallclock seconds; real 40.02s,
  user 32.74s, sys 5.06s.
- Exactly one file-level skip:
  `t/request/multipart-stream-e2e.t` requires `RELEASE_TESTING=1` for its
  full-stack PAGI::Server test.
- The execution wrapper temporarily yielded while the original process
  continued; the same process completed and wrote the final summary. The suite
  was not restarted or run a second time.

### Syntax, diff, and distribution checks

- `git diff --check`: exit 0.
- `perl -Ilib -c` for `PAGI::Utils`, `PAGI::Routing::Compiler`, `PAGI::Pages`,
  and `PAGI::Response::Stream`: all exit 0 and report `syntax OK`.
  `PAGI::Utils` emits the pre-existing circular-load subroutine-redefinition
  warnings already recorded by Task 1; no new warning appeared.
- `dzil build`: exit 0, real 9.23s (user 8.21s, sys 0.50s). Artifact:
  `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/.worktrees/application-valued-route-endpoints/PAGI-Tools-0.002002.tar.gz`,
  956363 bytes. `dzil test` was not run. The build's root README regeneration
  was restored immediately through an explicit patch; final `git diff --check`
  and tracked status are clean apart from this evidence update.

### Final-review correction and corrected candidate `b19c815`

- Important: mutable App Router generic CODE declarations incorrectly required
  explicit methods even though functional/immutable Route defaults omission to
  GET plus automatic HEAD. This also blocked Endpoint Router's generic
  method-name and CODE declarations. Focused RED was exact: Files=2, Tests=19,
  with only the two new parity subtests failing at `route requires methods
  option`.
- Fix: remove only the CODE-specific rejection and preserve omitted methods
  into immutable Route. Explicit arrays/scalar `'*'`, explicit undef
  validation, object `allowed_methods`, verb helpers, WS/SSE rejection,
  declaration order, and endpoint identity remain unchanged. Tests prove GET,
  HEAD, and Router-owned POST 405 with `Allow: GET, HEAD` for App Router CODE
  and Endpoint method-name/CODE declarations.
- Minor: remove the dead object-copy SKIP wrapper in
  `t/response/02-buffered.t`; its exact retained-object assertions now run
  directly.
- Minor: simplify the large application's Root and Blogs `http_default` values
  to direct source-free `not_found(...)` applications, removing two
  request-independent handlers and their `request_response` imports. Runtime
  boundary-specific details remain unchanged.
- Focused GREEN under Perl 5.42.2: Files=4, Tests=34, exit 0, 1 wallclock
  second; real 1.27s (user 0.98s, sys 0.15s). Broader affected GREEN:
  Files=14, Tests=122, exit 0, 3 wallclock seconds; real 3.20s (user 2.81s,
  sys 0.37s). Builder/App Router/Endpoint Router POD checks and corrected
  Builder/large-example syntax checks pass.
- Corrected full suite: the worker's attempted host command never started; the
  controller verified that fact and ran the sole corrected-candidate suite.
  At `b19c815`, `prove -lr t` passed Files=218, Tests=2373, 40 wallclock
  seconds, exit 0. The same one file-level skip remains:
  `t/request/multipart-stream-e2e.t` requires `RELEASE_TESTING=1`.
- Corrected syntax/diff: the four required Task 13 modules plus
  `PAGI::App::Router::Builder` report `syntax OK`, all exit 0;
  `git diff --check` exits 0. The same pre-existing Utils circular-load warnings
  remain.
- Corrected `dzil build`: exit 0, real 10.59s (user 9.43s, sys 0.63s).
  Artifact `PAGI-Tools-0.002002.tar.gz` is 956814 bytes. `dzil test` was not
  run. Dist::Zilla's root README formatting rewrite was again restored through
  an explicit patch.
- The exact forbidden-form search remains 87 manually classified lines at the
  corrected candidate. The affected large-application source contains no
  `request_response`, `root_not_found`, or `blogs_not_found` residual.

## Deviations

| ID | Status | Conflicting plan/spec text | Evidence and rationale | Affected tasks | User decision |
|---|---|---|---|---|---|
| DEV-01 | approved | Design §11.1 lines 773–776 says a Pages factory snapshots a configured policy so later mutation cannot affect invocation; Task 6 calls the result immutable. | The implementation attempted `bless { %$policy }, ref($policy)`, which assumes hash storage and only shallow-copies arbitrary subclass state. There is no legitimate framework need to isolate a configured collaborator from its owner's later intentional mutation, and generic cloning/snapshot protocols are expressly rejected. Revised contract: the deferred application retains the exact Pages policy object; subclass state is shared and subclass-owned; request descriptors and Responses remain invocation-local; ordinary factory inputs continue their existing defensive normalization. Work map remains PAGI-Tools only, same branch/base/push boundary. | 6, 12, 13 | User explicitly approved breaking the snapshot promise and directed: no cloning or tricks; later mutation is unwise but valid; remove the copying design. |
| DEV-02 | approved | Design/plan and current Response POD specify that `respond`/`to_app` manufacture stable Response snapshots, while Task 11 intended to preserve those internals mechanically. | Copying selected hash fields into another blessed object attempts to hide deliberate mutation after `to_app`, assumes first-party object storage, and can discard subclass state. Revised contract: `to_app` retains the exact Response; deliberate later changes affect later invocations; each invocation captures only a plain request-local wire/delivery plan before its first send; concurrent mutation remains unsupported. Redirect/Problem invariants validate before start; File plans at request time; Stream captures producer/status/headers without cloning. Work map remains the same PAGI-Tools branch and deployment/push boundary, with owned changes expanded to the Response hierarchy, focused tests, approved design, report, and later live docs. | 6A, 11, 12, 13 | User explicitly approved breaking snapshot semantics, categorized mutation-after-`to_app` as caller-owned misuse, requested a Cookbook gotcha at most, and directed that future user-visible object copying/freezing/reconstruction be proposed before implementation. |
| DEV-03 | approved | `PAGI::Request->headers` currently clones the cached `PAGI::Headers` object on every call so caller mutation cannot affect later Request header lookups. | This is unnecessary defensive ownership work for Perl callers and obscures normal shared-object semantics. Revised contract: `headers` returns the exact cached `PAGI::Headers` object; deliberate mutation affects subsequent `headers`, `header`, `header_all`, and derived Request header accessors. A caller wanting isolation explicitly calls `clone`. Work map remains the same PAGI-Tools branch and deployment/push boundary, with owned changes limited to Request/header tests, immediate Request POD, task report, and later Cookbook/upgrading text. | 6B, 12, 13 | User explicitly rejected the automatic defensive copy and directed that Perl programmers own mutation/copy choices. |
| DEV-04 | approved | `PAGI::Lifespan` currently shallow-copies each non-lifespan request scope before injecting its application `state`. | The copy protects unusual callers that reuse one scope across unrelated/concurrent apps or blindly serialize it afterward, but there is no ordinary need for two semantic request views. Revised contract: Lifespan injects/adopts state on the exact request scope and passes that same scope downstream; deliberate scope sharing remains caller-owned. Do not alter Compose's separate lifespan proof scope in this task. Work map remains the same PAGI-Tools branch and deployment/push boundary, with owned changes limited to Lifespan, focused tests/POD, report, and later Cookbook/upgrading text. | 6C, 12, 13 | User explicitly rejected this defensive copy after reviewing concrete reuse/concurrency/logging scenarios. |

## Post-plan design ledger

- REVIEW-01: Revisit the WebSocket-denial/SSE-decline Response adapter after Task 13. It currently derives a shallow synthetic HTTP/GET scope so an ordinary HTTP Response can emit through a mapped protocol send channel while the live protocol scope remains unchanged. The copy is retained for this campaign, but the ownership/model feels suspect; evaluate whether protocol adaptation should consume a lower-level Response emission plan or capability instead of pretending the protocol request is HTTP. Do not change settlement, first-send-wins, File opt-out, or disconnect semantics without a separate design.
- REVIEW-02: Revisit Compose's derived lifespan provenance scope after Task 13. It currently attaches a private token plus the original server-state identity to a shallow middleware-facing scope, then rejects startup if middleware replaces/drops that state; this prevents false startup success against a hash the server will not propagate. Retain it for this campaign. Later evaluate whether lifespan should traverse ordinary middleware at all, whether the proof belongs in another channel, and whether the private derived scope remains the clearest contract.
