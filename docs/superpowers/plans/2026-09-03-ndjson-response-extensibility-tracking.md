# NDJSON Response Extensibility Execution Tracking

**Plan:** `docs/superpowers/plans/2026-09-03-ndjson-response-extensibility.md`

**Starting HEAD:** `0bc9293ac417821027272960221865f442cedb87`

| Task | Status | Implementation SHA | Review/fix SHAs | Focused verification and actual counts | Full-suite/build evidence | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | complete | `694f1bbdc91befd166667d13a7378b90e28a92fc` | clean task review | PASS — `prove -l t/response/05-ndjson.t t/response/03-stream.t t/response-writer.t`: 3 files, 39 tests; NDJSON syntax checks OK; private-name audit empty; `git diff --check` clean | deferred to Task 5 | spec PASS; quality PASS |
| 2 | complete | `11c8880276e2b195a539437512befc82fc1e7e2f` | clean task review | PASS — `prove -lv t/response/05-ndjson.t t/00-load.t`: 2 files, 77 tests; parent export probe exits 0; `git diff --check` clean | deferred to Task 5 | spec PASS; quality PASS |
| 3 | complete | `ce3ff86d9f6b941af32d95f11e894f67b307f6e8` | `b8f32a4`; fix re-review clean | PASS — `prove -lv t/00-pod/cookbook-examples.t t/response/05-ndjson.t`: 2 files, 21 tests; published recipe executes and captures two LF-terminated JSON records; `git diff --check` clean | deferred to Task 5 | spec PASS; quality PASS |
| 4 | complete | `82d5cf08c429e50927845e4ebbbfe03d22521523` | `6543c21`; clean task review | PASS — `prove -lv t/integration-starlette-apples.t t/00-pod/cookbook-examples.t`: 2 files, 13 subtests; app syntax OK; `git diff --check` clean | deferred to Task 5 | spec PASS; quality PASS |
| 5 | complete | `ce57e996844364faa7378f11b9eeb70afe6e85ff` (evidence-required test correction) | self-review clean | PASS — corrected-HEAD focused gate: 6 files, 119 tests, 0 failures, 2 wallclock seconds; all three syntax checks OK; private-name audit empty; `git diff --check` clean; `git status -sb` clean on the expected branch, ahead 14 | full suite: 213 files, 2,395 tests, four independently baseline-proven failures and no campaign failure; `dzil build`: PASS, `PAGI-Tools-0.002002.tar.gz` inspected | spec PASS locally; quality PASS; controller-owned PR push pending |

## Deviations and rulings

| ID | Status | Conflicting plan/spec text | Evidence and rationale | Affected tasks | Ruling |
| --- | --- | --- | --- | --- | --- |
| `DEV-001` | ruled | Plan says commit `.superpowers/sdd/...`; SDD skill says the workspace is disposable scratch | The execution ledger cannot contain its own final commit SHA and the skill deletes its workspace after review | Tasks 1–5 | Keep scratch progress in the SDD workspace and mirror completed task evidence here after every task. |
| `DEV-002` | ruled | Plan calls `28fd101` the base while execution starts after plan commit `0bc9293` | `28fd101` is the approved spec/runtime base; `0bc9293` contains only the approved plan | Tasks 1 and 5 | Use `0bc9293` as starting HEAD and retain `28fd101` as the runtime/spec comparison point. |

Ruling: `DEV-001` — preserve a committed audit record without violating the disposable SDD workspace contract — cost if wrong: bookkeeping duplication, no runtime effect.

Ruling: `DEV-002` — start after the plan commit while retaining the spec commit as runtime baseline — cost if wrong: a documentation-only commit appears in the review range.

## Baseline verification

`perl-5.42.2@default`: `prove -l t/response/03-stream.t t/response-writer.t t/00-load.t t/00-pod/cookbook-examples.t t/integration-starlette-apples.t`

Result: PASS — 5 files, 103 tests.

## Final specification map

| Spec section | Concrete implementation/test evidence | Verdict |
| --- | --- | --- |
| §1 Decision | `lib/PAGI/Response/NDJSON.pm`, `lib/PAGI/Response/NDJSON/Writer.pm`, and `lib/PAGI/Response.pm`; construction/wire assertions in `t/response/05-ndjson.t` | PASS |
| §2 Work map | Scratch ledger plus this tracked mirror; final branch-map audit records the sole writable repository, branch, bases, deployment boundary, and PR target | PASS |
| §3 Governing and superseded decisions | NDJSON subclasses Stream and wraps a fresh generic Writer; `git diff 0bc9293..ce57e99` shows POD-only generic Stream/Writer changes; lifecycle coverage remains in `t/response/03-stream.t` and `t/response-writer.t` | PASS |
| §4 First-party response-family rationale | First-party modules, parent factory/export, response-family POD, Cookbook recipe, and `Changes` ship the format and extension proof together | PASS |
| §5 Goals | `t/response/05-ndjson.t` covers encoding, LF framing, backpressure, no raw API, common response behavior, reuse, lifecycle, and cleanup; apples integration covers the canary | PASS |
| §6 Non-goals | Specialized Writer exposes no `write`, `write_text`, `pipe_from`, or `close`; source audit finds no parser, iterator constructor, queue, registry, retry, or NDJSON special case; `pipe_items` remains absent | PASS |
| §7 Public construction and export API | NDJSON constructor/factory and parent factory are in `lib/PAGI/Response/NDJSON.pm` and `lib/PAGI/Response.pm`; `t/response/05-ndjson.t` covers class/factory/subclass/options/`:all`; `t/response-convenience.t` now expects all ten factories | PASS |
| §8 NDJSON Writer contract | `lib/PAGI/Response/NDJSON/Writer.pm` contains exactly `write_item` plus the eleven public generic-Writer delegates; narrowness, chainability, neutral defaults, and exact-Future delegation are covered in `t/response/05-ndjson.t` | PASS |
| §9 Encoding and wire format | Package-local `JSON::MaybeXS->new(utf8 => 1)` encoder plus one appended LF; `t/response/05-ndjson.t` covers hashes, arrays, strings, numbers, booleans, `undef`, UTF-8 bytes, escaped CR/LF, empty output, and semantic rather than key-order comparison | PASS |
| §10 Backpressure, disconnects, and cleanup | `write_item` returns the delegate's exact `write` Future; NDJSON and generic Writer tests cover pending sends, overlapping-write rejection, byte counts, disconnect settlement, cancellation, normal close, failure, and exactly-once cleanup | PASS |
| §11 Reuse, mutation, and subclassing | Constructor adapter creates a new facade inside each producer invocation and dispatches with `$class->SUPER::new`; reuse/concurrency and subclass identity are tested; Cookbook gives the public-only semantic Stream pattern | PASS |
| §12 Route, HEAD, and protocol boundaries | `examples/starlette-apples/app.pl` returns NDJSON from an ordinary Request handler/Route; integration tests cover GET and HEAD; `t/response/05-ndjson.t` checks inherited `body-events-v1` | PASS |
| §13 Apples canary | `examples/starlette-apples/app.pl`, synchronized README/Cookbook copies, and `t/integration-starlette-apples.t` cover two decoded LF records, status/media type, both middleware headers, HEAD suppression, CRUD continuity, and the preserved Python checksum | PASS |
| §14 Documentation changes | Response, NDJSON, NDJSON Writer, Stream, Writer, and Cookbook POD; apples/example READMEs; and `Changes` contain the required factory, delivery, extension, failure, cleanup, HEAD, and method-boundary documentation | PASS |
| §15 Error handling and diagnostics | Constructor delegates common option validation; encoding croaks with `NDJSON item encoding failed` before write; tests cover malformed producer/options, no event for the bad item, propagation, and cleanup | PASS |
| §16 Required verification outcomes | Focused final gate passes 6 files/119 tests; `t/00-load.t` loads both modules; executable Cookbook and apples integration tests pass; `t/response-convenience.t` passes after the scoped stale-expectation correction | PASS |
| §17 Adversarial review and rejected alternatives | Required private-name audit is empty; NDJSON code is 201 source/POD lines across two modules, with one delegate field and no lifecycle copy, raw escape hatch, queue, prefetch, replay, clone, or framework special case | PASS |
| §18 Implementation sequencing constraints | Reviewed commits separate core implementation, response-family integration, Cookbook, apples canary, and evidence; Tasks 1–4 retain their recorded RED/GREEN and independent review evidence; Task 5 correction is separate | PASS |
| §19 Completion criteria | Public API, public-only seam, focused tests, docs, canary, source preservation, comparison, and local reviewed branch are complete; remote PR synchronization is pending explicit controller authorization and is not an implementation deviation | PASS locally; push pending |

## Final verification and build evidence

- Required source audit: no `_run_lifecycle`, private lifecycle/generic Writer call, or `AUTOLOAD` match in either NDJSON module. Every `ndjson`/`NDJSON` occurrence under `lib`, `t`, `examples`, and `Changes` classified as implementation, public API/POD, release note, example, load assertion, or focused/integration coverage. Both modules occur in `t/00-load.t`.
- Initial focused gate at `d08f8cd`: PASS — 6 files, 119 tests, 0 failures, 3 wallclock seconds (2.29 CPU seconds).
- Initial full suite at `d08f8cd`: FAIL — 213 files, 2,395 tests, 41 wallclock seconds. It exposed one campaign-owned stale expectation in `t/response-convenience.t` plus four unrelated failures.
- Root cause and scoped correction: production already exported `ndjson_response`; `t/response-convenience.t` still expected the pre-feature nine-factory literal. Commit `ce57e996844364faa7378f11b9eeb70afe6e85ff` adds only `ndjson_response` to that literal and changes `nine` to `ten`. Its direct verification passes: 1 file, 2 tests.
- Baseline proof: the four unrelated failures reproduce from execution starting HEAD `0bc9293ac417821027272960221865f442cedb87` in 4 files/16 tests: `t/app-proxy.t`, `t/integration/process-streaming-end-to-end.t`, and `t/integration/sse-decline-end-to-end.t` cannot bind listeners under the sandbox; `t/integration-pages-example.t` has the same missing raw-triplet header assertion.
- Corrected-HEAD focused gate at `ce57e99`: PASS — 6 files, 119 tests, 0 failures, 2 wallclock seconds (2.27 CPU seconds).
- Syntax/hygiene: `lib/PAGI/Response/NDJSON.pm`, `lib/PAGI/Response/NDJSON/Writer.pm`, and `examples/starlette-apples/app.pl` each report `syntax OK`; `git diff --check` exits zero. Final `git status -sb` at `dbb889be16d2ca1678b951f151a4ae7c6a2805e6` exits zero and reports exactly `## feature/remove-mutable-router-frontends...origin/feature/remove-mutable-router-frontends [ahead 14]`, with no changed-file lines.
- Corrected-HEAD full suite at `ce57e99`: baseline-limited FAIL — 213 files, 2,395 tests, 42 wallclock seconds (40.21 CPU seconds). `t/response-convenience.t` passes; only the four independently reproduced baseline failures remain. No NDJSON, Response, Routing, export, documentation, load, Cookbook, or apples test fails.
- Distribution: `dzil build` exits zero and writes `PAGI-Tools-0.002002/` plus `PAGI-Tools-0.002002.tar.gz` (952,595 bytes). The archive contains both NDJSON modules with live POD, generated `README.md`, and live `Changes`; `docs/` and `.superpowers/` have no archive entries. The configured root README generator produced only unrelated line reflow, which was not retained; build artifacts were retained.

## Final deviation and external-state verdict

`DEV-001` and `DEV-002` are ruled decisions, not open deviations. No unruled `DEV-NNN` or implementation deviation remains. Deferred `pipe_items` and request parsing are explicit non-goals, not defects. The only remaining campaign action is controller-owned synchronization of the existing branch to PR #28 after authorization.
