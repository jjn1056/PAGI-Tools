# Public-surface inventory — route endpoints and application-valued responses

## Final audit context

- Repository: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/.worktrees/application-valued-route-endpoints`
- Ticket: none; approved WIP design campaign
- Branch: `feature/application-valued-route-endpoints`
- Base and starting HEAD: `main@8ffe0af3a4f59bc9ae0ef233375a7a0bd966484c`
- Final verification candidate before the evidence-only commit: `d06e521`
- Deployment boundary: unreleased PAGI-Tools only; no deployment, merge, push,
  tag, or release
- Push target: `origin/main` only after explicit user authorization

The PAGI `0.002007` and PAGI::Server `0.002011` repositories remained clean,
read-only references. The source-checkout `.pagi-*` notes and existing
`.superpowers/` material listed in `progress.md` remain preserved and outside
this worktree.

The only permitted classifications are `retained`, `replaced by approved
design`, and `deferred by approved design`. Every inventoried row below has a
final classification and evidence.

## Final public contract

| Public surface | Final contract | Classification | Evidence |
| --- | --- | --- | --- |
| `PAGI::Utils::to_app($value)` | Sole application normalizer: native CODE is returned unchanged; an instantiated object's `to_app` is called once and must return CODE. | retained | `lib/PAGI/Utils.pm`; `t/utils-to-app.t`; `t/utils/application-values.t`. |
| `PAGI::Utils::as_app($code)` | Opt-in native-CODE marker returning a distinct instantiated `to_app` component that retains the exact CODE. | replaced by approved design | Present in `@EXPORT_OK` and `:all`; `t/utils/application-values.t`. |
| `PAGI::Utils::request_response($handler)` | Opt-in one-Request-handler adapter returning `PAGI::Routing::RequestResponse`; no duplicate Routing export. | replaced by approved design | Present only in Utils exports; `t/routing/17-request-response.t`; `t/routing/01-constructors.t`. |
| `PAGI::Utils::invoke_app($value, $scope, $receive, $send)` | Generic application invocation helper preserving the exact triplet and awaiting immediate/Future completion. | replaced by approved design | Present in Utils exports; `t/utils/application-values.t`; all first-party response delegation uses it. |
| `PAGI::Utils::is_response` | Removed nominal Response predicate; it cannot be called or imported. | replaced by approved design | Absent from exports/runtime; negative coverage in `t/utils/is-response.t` and `t/upgrading-response-family.t`. |
| Other Utils bundles | `:env` and `:path` remain unchanged; `:all` includes the three application bridges plus the retained helpers. Nothing is exported by default. | retained | Final export introspection at candidate `d06e521`; `lib/PAGI/Utils.pm`. |
| `PAGI::Routing` exports | `router`, `route`, `websocket`, `sse`, `mount`, and `middleware`; `:routes`, `:middleware`, and uppercase `:ALL` remain exact. | retained | Final export introspection; `t/routing/01-constructors.t`. |
| `PAGI::Routing::request_app` | Removed; Request-handler adaptation is `PAGI::Utils::request_response`. | replaced by approved design | No Routing export/implementation; negative coverage in `t/routing/01-constructors.t`. |
| Route constructor grammar | Canonical object form is `Route->new(path => ..., endpoint => ...)`; concise functions take `($path => $endpoint, %opts)`. CODE means one facade argument; instantiated `to_app` means native application. | replaced by approved design | `lib/PAGI/Routing/Route.pm`; `t/routing/01-constructors.t`; `t/routing/08-protocols.t`. |
| Route accessors | `endpoint` retains the exact declaration; `target` and `is_raw` do not exist. Methods are explicit, one construction-time `allowed_methods` snapshot, or GET+HEAD; scalar `'*'` is the only unrestricted form. | replaced by approved design | `t/routing/01-constructors.t`, `t/routing/05-http-dispatch.t`. |
| Router description | Ordered Route/Mount collection with optional native `http_default`; it is not a leaf and has no `endpoint`, `target`, or `is_raw` accessor. | retained | `lib/PAGI/Routing/Router.pm`; final correction `fa615f5..d06e521`; `t/routing/01-constructors.t`. |
| Mount description | One prefix-owning `app` or `routes` child, with scope rewrite and subtree ownership; no positional target, `router`, `target`, or `is_raw` mode. | retained | `lib/PAGI/Routing/Mount.pm`; `t/routing/01-constructors.t`; `t/routing/07-mounts.t`. |
| Router `http_default` | Native three-argument CODE or instantiated `to_app`; Pages applications work directly and Request handlers use `request_response`. | retained | `lib/PAGI/Routing/Router.pm`; `t/routing/16-http-outcomes.t`; apples/large-app integrations. |
| `PAGI::App::Router` declarations | Mutable declarations preserve written order and endpoint identity, then materialize the same immutable Route contract. Generic CODE requires methods; object omission is left for immutable capability/default resolution. | replaced by approved design | `lib/PAGI/App/Router/Builder.pm`; `t/app-router/01-builder-core.t`; `t/app-router/03-composition-order.t`. |
| `PAGI::Endpoint::Router` declarations | Local method names and CODE become one-argument handlers; native local methods use `as_app($self->app_as(...))`; mounts/defaults remain native app positions. | replaced by approved design | `lib/PAGI/Endpoint/Router.pm`, Builder POD/tests; `t/endpoint/13-router-frontends.t`; endpoint-router example integration. |
| `PAGI::Endpoint::HTTP` | Verb methods return immediate/Future application values. `dispatch` validates and returns the app; instance `to_app` retains that instance and delegates through `invoke_app`. `allowed_methods` supplies routed method metadata including HEAD/OPTIONS. | replaced by approved design | `lib/PAGI/Endpoint/HTTP.pm`; `t/endpoint/11-return-contract.t`; `t/endpoint/04-http-options.t`. |
| Pages factory methods | Class, configured-instance, subclass, and opt-in function forms return deferred HTTP applications. Factories are source-free and negotiate at invocation. | replaced by approved design | `lib/PAGI/Pages.pm`, `lib/PAGI/Pages/Application.pm`; `t/pages/01-catalog.t` through `06-lifespan-decline.t`. |
| Pages exports | Nothing by default; `:common` is the exact ten-name low-collision set; `:all` contains every factory; `status` and `redirect` are explicit/`:all` only. | replaced by approved design | Final export introspection; `t/pages/03-invocation-composition.t`. |
| Old Pages `*_page` exports/helpers | Removed with no compatibility aliases. The unused private `_named_page_functions` generator was removed in `fa615f5`. | replaced by approved design | Negative import/method tests in `t/pages/03-invocation-composition.t`; final forbidden-form classification. |
| Base Response and concrete subclasses | HTTP application values invoked through `to_app`; exact configured object retained; every invocation derives its own plain delivery plan before first send. | retained | `lib/PAGI/Response.pm` and subclasses; `t/response/01-base.t` through `04-file.t`; DEV-02 tests/docs. |
| Public `Response->respond` | Removed. Private `_emit` is implementation-only and raw callers use `invoke_app`. | replaced by approved design | `Response`, Text, File, and Stream all have `to_app`, no `respond`; `t/upgrading-response-family.t`; literal live `lib` search has zero `->respond(`. |
| Response factories/export bundle | `response`, text/html/json/problem/redirect/empty/file/stream factories remain opt-in and in `:all`. | retained | `lib/PAGI/Response.pm`; response convenience tests. |
| Response metadata helpers | `status`, `status_try`, `headers`, `header_try`, `content_type_try`, cookies, and body/representation hooks retain their documented behavior. | retained | `lib/PAGI/Response.pm`; base/buffered/subclass suites. |
| `PAGI::Response::File` | Request-time file plan, ranges/conditionals, one terminal body event, no public `respond`; `protocol_response_capability` is deliberately `undef`. | retained | `lib/PAGI/Response/File.pm`; `t/response/04-file.t`; denial/decline gates. |
| `PAGI::Response::Stream` and Writer | One fresh Writer per invocation; awaited sequential writes preserve backpressure and disconnect/cancellation settlement; no hidden queue or public Response emission seam. | retained | `lib/PAGI/Response/Stream.pm`, Writer; `t/response/03-stream.t`, `t/response-writer.t`. |
| WebSocket denial / SSE decline | Continue requiring a concrete compatible Response with `body-events-v1`; start ownership and disconnect settlement are unchanged; File is rejected. | retained | `lib/PAGI/WebSocket.pm`, `lib/PAGI/SSE.pm`, private Response adapter; denial/decline and end-to-end tests. |
| Synthetic denial/decline HTTP scope | Retained unchanged for this campaign; model review remains explicitly ledgered as REVIEW-01. | deferred by approved design | `progress.md` post-plan ledger; no Task 13 runtime change. |
| Compose lifespan provenance scope | Retained unchanged for this campaign; model review remains explicitly ledgered as REVIEW-02. | deferred by approved design | `progress.md` post-plan ledger; no Task 13 runtime change. |

## Final forbidden-form search classification

Command at candidate `d06e521`:

```text
rg -n "request_app|raw =>|is_raw|->target\b|_page\b|->respond\(|is_response" README.md UPGRADING.md Changes lib t examples
```

The command returned 87 lines. Every line is classified; none endorses or
implements a removed current surface.

| Match group | Count | Classification | Evidence / reason retained |
| --- | ---: | --- | --- |
| `Changes` removal record | 1 | retained | Historical release record says `target`/`is_raw` were removed. |
| `UPGRADING.md` Before/removal/absence material | 19 | retained | Explicitly labelled Before examples, Before/After map rows, or prose stating the APIs are absent. |
| `UPGRADING.md` local `missing_page` example | 1 | retained | Ordinary user function name, not a removed Pages export. |
| Request/WebSocket/SSE raw query/form-byte options and tests | 28 | retained | `raw => 1` means skip decoding; unrelated to Route native-app grammar. |
| Internal/local names `_respond_page`, `$hook_page`, and `admin_page` | 14 | retained | Ordinary private/local identifiers, not public `*_page` Pages factories. |
| Negative removal tests | 24 | retained | Assert absent `request_app`, `is_response`, `respond`, `target`, `is_raw`, old Pages exports, and rejected Route `raw`. |

The search initially exposed two real residuals: Router's public `target` and
`is_raw` compatibility methods, and the unused private Pages catalog
`_named_page_functions` generator. Commit `fa615f5` removes both and adds the
Router absence test. Follow-up `d06e521` enforces the user's collection-only
Router ruling by removing an accidentally proposed `endpoint` accessor and
correcting the Router POD. Focused verification passes at `d06e521`.

## Maintained examples

All 20 directories under `examples/` were inspected at candidate `d06e521`.
Each contains an `app.pl` and README; Task 10's matrix maps each to an existing
integration/load assertion. A per-directory forbidden-form scan reports
`stale=no` for every directory:

`09-psgi-bridge`, `10-chat-showcase`, `13-contact-form`,
`14-lifespan-utils`, `15-large-application`, `app-01-file`,
`background-tasks`, `compose`, `declarative-routing`, `endpoint-demo`,
`endpoint-router-demo`, `full-demo`, `pages`, `sse-close`, `sse-dashboard`,
`starlette-apples`, `test-lifespan-shutdown`, `websocket-bidirectional`,
`websocket-chat-v2`, and `websocket-echo-v2`.

The final focused canary gate and the repository-wide suite provide executable
evidence for those load/integration assertions; their exact counts are
recorded in `progress.md` and `task-13-report.md`.
