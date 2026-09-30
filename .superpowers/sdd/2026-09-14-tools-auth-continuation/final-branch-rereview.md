# Final branch scoped rereview

Reviewed `b5b0455..7b90716` using the complete prepared fix diff and `final-fix-report.md`. Scope was the original three findings and regressions introduced by their corrections. No source/index/HEAD edits, broader audit, test reruns, or build reruns were performed; this report is the only output file.

## Strengths

The runtime correction is confined to the metadata-only Request boundary. The shallow hash copy prevents lazy header-cache installation from mutating the source while preserving the original HTTP scope at descriptor, policy, and negotiation hooks. Existing cached HTTP headers remain shared for read access; non-HTTP protocol caches remain excluded from synthesized metadata. No new lifecycle machinery or policy indirection was added.

## Findings disposition

1. **P2 — Negotiated HTTP materialization mutates its source: addressed.** `lib/PAGI/Pages.pm:829` now constructs the private Request against a shallow scope copy. The added regression exercises raw HTTP and Request sources, with and without a preexisting cache, across repeated materializations. It checks negotiated repeated Accept behavior, unchanged source keys, raw header identities and values, cached header identities and values, and original hook scope identities. Updated non-HTTP assertions correctly expect the rebuilt Request cache to remain private. The reported red run reproduced eight source-cache failures before this correction; the focused and full green runs cover the final implementation.

2. **P3 — Custom request-like scope POD: addressed.** `PAGI::Pages::Application` now documents custom request-like materialization, adapter-owned emission, lifespan rejection, and the separate HTTP-only `to_app` boundary.

3. **P3 — Response HTTP-only POD: addressed.** `PAGI::Response` now distinguishes HTTP response events from the supported original WebSocket/SSE refusal scopes, retains lifecycle-helper guidance, and explicitly rejects lifespan and unsupported types.

## Issues

No remaining critical, important, or minor issue identified in this fix delta. All three original findings are closed; no new breakage was found in the scoped rereview.

## Verification evidence

The fix report records 13 files / 429 focused tests passing, both affected POD checks passing, and a fresh full run of 226 files / 2,583 tests passing with all seven real integration cases executed. Its sole skip is the optional RELEASE_TESTING multipart case. It also records the archive rebuild and inspection of the affected runtime and POD members. These are reported execution results inspected during rereview, not independently rerun commands.

## Assessment

**Ready to merge? Yes.**

The bounded correction resolves the reproducible materialization contract violation without altering policy-hook identity or protocol behavior, and both public documentation contradictions are corrected. Combined with the preceding whole-branch review and final verification evidence, there is no outstanding review blocker. This assessment does not authorize a merge, push, or release.
