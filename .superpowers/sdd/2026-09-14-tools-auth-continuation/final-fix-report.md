# Final review fix report

## Work map

- Tools: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools`; final-review P2/P3 fixes; branch `feature/universal-connection-tools`; base `b5b0455`; owned changes: Pages negotiation, response_for regression, Pages::Application/Response POD, this report. Local commit/build only; no push target or deployment.
- PAGI: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI`; normative reference `9aebdbc`; read-only; no deployment or push.
- Server: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server/.worktrees/feature-websocket-close-truthfulness`; integration reference `c0c08f6`; read-only; no deployment or push.

Parent progress, tracking, handoff, and unrelated notes are excluded.

## Changes and boundaries

Resolved the review's one P2 and two P3 findings. Negotiation gives its metadata-only Request a shallow top-level scope copy, so its existing lazy header-cache installation cannot write into the caller scope. HTTP descriptor, policy, and negotiation hooks still receive the original scope; an existing HTTP cache retains its identity and values. Non-HTTP views continue omitting protocol caches and negotiating from repeated raw fields. No policy object cloning, new cache/registry, lifecycle changes, or Phase 2 behavior was introduced.

The regression covers raw HTTP and Request sources, uncached and cached headers, two calls per case, repeated Accept preference, unchanged scope keys/raw headers/cache identities and values, and original hook scope identities (68 inner assertions). Existing non-HTTP tests now assert that the internal Request's rebuilt cache stays private while retained raw metadata and negotiation remain correct.

Pages::Application POD explicitly accepts custom request-like materialization with adapter-owned emission and retains HTTP-only to_app. Response POD distinguishes HTTP events from permitted original WebSocket/SSE preaccept/prestart refusal scopes and retains unsupported/lifespan rejection and helper lifecycle guidance.

## Verification

All Perl commands use Perl 5.42.2, with PERL_FUTURE_NO_XS=1 for tests.

- RED: `perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -l t/pages/07-response-for.t` failed 1/7 top-level subtests, with eight expected failures for source cache injection in uncached raw/Request cases, before the runtime edit.
- GREEN: same command passed 1 file / 7 top-level subtests.
- Focused: `perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -lr t/pages t/auth t/00-load.t t/00-pod/cookbook-examples.t` passed 13 files / 429 tests.
- POD: `perlbrew exec --with perl-5.42.2@default podchecker lib/PAGI/Pages/Application.pm lib/PAGI/Response.pm` passed both files.
- Exactly one fresh full host gate: `perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -I /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server/.worktrees/feature-websocket-close-truthfulness/lib -lr t` passed **226 files / 2583 tests**, 44 seconds. All seven real protocol integration cases ran with Server/nghttp2 paths reported. The only reported skip was optional `t/request/multipart-stream-e2e.t` requiring RELEASE_TESTING=1. Expected request/access logs appeared; no failures.
- `git diff --check` passed.
- `perlbrew exec --with perl-5.42.2@default dzil build` rebuilt ignored `PAGI-Tools-0.002002.tar.gz` successfully. Direct archive inspection confirmed the Pages runtime copy and both corrected POD passages. Only the existing nonfatal PkgVersion layout warnings appeared; root README has no new delta. No version bump, upload, push, merge, or release.

No outstanding blocker. Parent owns the scoped rereview and final handoff.
