# Task 3 Report: Standalone Route Boundary and Endpoint Classification

## Status

Completed on branch `feature/application-valued-route-endpoints`.

Commit: `9a93113` (`docs: clarify standalone Route behavior`)

## Work map

| Repository | Ticket/task | Branch | Base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | Task 3: final Route contract cleanup | `feature/application-valued-route-endpoints` | reviewed Task 1–2 commit `fbcdcfcf96a3fe8779ce00a8a10e73366350d58d` | Route POD and endpoint-classification design wording | Documentation only; no runtime behavior change | None (do not push) |

## Files changed

- `lib/PAGI/Routing/Route.pm`
  - Documented the complete standalone Route routing boundary: negotiated stock
    Pages 404, stock Pages 405 with Router-authoritative `Allow`, HEAD wire
    suppression while retaining calculated headers, inert lifespan completion,
    and the absent Compose safety layers.
- `docs/superpowers/specs/2026-08-30-route-endpoints-and-application-valued-responses-design.md`
  - Replaced the ambiguous normalized-kind introspection language with the
    ruling that `kind` is only the protocol kind, while endpoint shape is the
    canonical handler/application classification.
  - Added an explicit adversarial ruling declining `endpoint_kind`.

No runtime source or test file changed.

## Controller-ruling deviation

The task brief originally called for source-text synchronization assertions in
`t/upgrading-routing-composition.t` (and possibly
`t/00-pod/cookbook-examples.t`). The controller explicitly superseded that
instruction: no human prose is tested by keyword/source grep. Accordingly, no
new synchronization assertions were added. Existing documentation, POD, and
behavioral routing tests provide the validation evidence below without
coupling test correctness to prose wording.

## Semantic cross-checks

Checked `lib/PAGI/Routing/Compiler.pm` against each new public statement:

- `_compile_router` returns immediately for `lifespan` before receive/send
  activity, so the compiled Route boundary is inert for lifespan.
- `_compile_router_body` defaults HTTP NONE to
  `PAGI::Pages->not_found`, and its dispatcher invokes that app for a path
  miss; this is the stock negotiated Pages 404.
- `_compile_dispatcher` turns HTTP PARTIAL into
  `PAGI::Pages->method_not_allowed`; `_authoritative_allow_send` replaces the
  generated response's `Allow` header with router-owned method state.
- `_compile_router` installs `PAGI::Routing::HeadBoundary` before dispatch,
  which preserves response metadata and suppresses body/sendfile/trailer wire
  delivery for HEAD.
- The compiler directly creates the Router graph and contains none of
  Compose's lifespan orchestration, `ErrorHandler`, or response-completion
  guard.
- Route's existing `kind` accessor is protocol metadata. The exact declared
  `endpoint` remains available, and no `endpoint_kind` accessor exists.

## Validation

All commands ran under `perlbrew perl-5.42.2@default`.

1. Documentation and POD validation:

   ```sh
   prove -lv t/upgrading-routing-composition.t t/00-pod/cookbook-examples.t
   podchecker lib/PAGI/Routing/Route.pm lib/PAGI/Routing/Mount.pm
   ```

   Result: PASS. `prove` reported `Files=2, Tests=14`; both POD files reported
   `pod syntax OK`.

2. Existing focused behavioral routing coverage:

   ```sh
   prove -lv t/routing/16-http-outcomes.t t/routing/06-head.t \
     t/routing/10-head-boundary.t t/app-router.t
   ```

   Result: PASS. `prove` reported `Files=4, Tests=36`. These tests cover
   negotiated Router 404/405 outcomes, generated authoritative `Allow`, HEAD
   body and sendfile suppression with preserved metadata, standalone Route
   404/405 ownership, and compiled routing's inert lifespan behavior.

3. Review checks:

   ```sh
   git diff --check
   git diff --cached --check
   ```

   Result: clean before commit. The committed diff contains exactly the two
   files listed above (23 insertions, 2 deletions).

## Self-review

- Preserved Task 1–2's origin-aware method diagnostics and Route/Mount
  constraints POD by changing neither file's corresponding content.
- Did not alter `lib/PAGI/Routing/Compiler.pm` or any runtime behavior.
- Kept the Route POD precise: it does not claim Pages receives lifespan; the
  compiler returns before default dispatch.
- Distinguished the protocol `kind` accessor from the absence of a separate
  handler/application classification accessor.
- Added no test that asserts human documentation text by source grep, as
  required by the controller ruling.

## Concerns

- Pre-existing untracked user/session files were present in the worktree and
  were left untouched.
- No push or merge was performed, as required.
