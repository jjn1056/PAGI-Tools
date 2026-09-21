# Header helpers implementation handoff

Date: 2026-09-21

Repository: `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools`

Branch: `feature/universal-connection-tools`

Implementation range: `3f12918..a1a6867`. All eight tasks have passed individual spec/code reviews. Final whole-change review found no critical or important issue; its minor UTF-8 synopsis correction is committed and passed scoped re-review. No push, merge, deployment, server-repository change, or dependency upgrade was performed.

Design: [Header helpers and consumer migration](../specs/2026-09-21-header-helpers-design.md).
Execution: [Implementation plan](2026-09-21-header-helpers-plan.md).

## What is implemented

- `PAGI::Utils::Headers`: optional pure functions for Basic/Bearer extraction, WWW-Authenticate formatting, semicolon parameters and quoting, response Content-Disposition with UTF-8 filenames, token lists/Vary, and entity-tag parsing/formatting/comparison.
- `PAGI::Headers`: singleton reads, named authentication/content-type/disposition/ETag readers, token membership, and chainable Vary composition. Raw ordered pairs, duplicates, last-value `get`, and byte handling remain available.
- Request authentication and Content-Type shortcuts delegate; both multipart boundary paths and both part readers share parameter parsing. File download filenames use the new formatter.
- Pages, CORS, and GZip share Vary merging. ConditionalGet and File planning handle weak/repeated/comma-containing ETags, wildcard existence without an ETag, method/status eligibility, and conditional-before-range ordering. If-None-Match presence suppresses date fallback.
- Auth examples and documentation use the helpers while retaining application-owned verification, failures and 400/401/403 responses. Both JWT sandbox apps define `sub jwt_backend ($request)` and pass `backend => \&jwt_backend`, as requested.
- Exact API POD, four cookbook recipes, Tutorial guidance, example READMEs, load coverage, and unreleased change notes are updated.

## Verification

Task-specific red/green tests covered grammar, multiplicity, byte/character boundaries, multipart limits/metadata, Vary composition and real conditional responses. Task reviews caught and corrected explicit filename* charset grammar, App::File method normalization, the parser's regex-position side effect, and the Unicode documentation recipe.

The complete host-access command was:

```sh
perlbrew exec --with perl-5.40.0@default prove -lr t
```

At `561956c`: 242 files, 2,930 tests, no failing assertions. Overall exit status is nonzero because the pre-existing `t/integration-pages-example.t` cannot compile without `PAGI::Server` on the Perl include path. Four optional server/release suites skip. The initial unchanged baseline had the same missing dependency. This file unconditionally imports the server for two auto/on startup-policy probes calling its private `_run_lifespan_startup`; the remaining Pages example coverage only uses Test::Client. Separating those server-policy probes is a test-organization follow-up, not a new runtime requirement introduced here. Socket tests pass with host access. Existing Future lost-sequence warnings remain.

The subsequent `8dd51f9` changes only documentation. Its focused cookbook/JWT checks pass (3 files, 39 tests), as do POD checks. The broader example gate passed (14 files, 280 tests), including JWT verification tests without an optional-dependency skip. The final `a1a6867` edit only adds `use utf8;` to the Utils POD synopsis; POD and scoped review pass. Whitespace checks pass. This is not a claim of a fully green default repository gate.

Local execution evidence is in `.superpowers/sdd/2026-09-21-header-helpers-plan/`; full-suite logs are `/tmp/pagi-headers-baseline.log` and `/tmp/pagi-headers-final.log`. These are local scratch artifacts, not release files.

## Decisions made during execution

1. **Multipart boundaries containing spaces remain unsupported by the existing multipart parser.** The header helper correctly extracts the quoted value, but HTTP::MultiPartParser 0.02 rejects spaces in its constructor. Successful integration coverage uses a quoted punctuation boundary; separate tests cover extraction and downstream rejection for spaces. No boundary rewriting or parser workaround was added. Supporting those uploads requires a separately scoped dependency/parser change.
2. **App::File now treats method names case-sensitively.** Its old uppercasing could turn a nonexact method into GET/HEAD before conditional planning. Removing that normalization gives nonexact spellings 405 and preserves exact GET/HEAD behavior. Callers relying on lowercase spellings must send the actual HTTP method name. No original-method flags or compatibility branches were added.

## Workspace preservation

The unrelated modification to `docs/superpowers/plans/2026-09-08-universal-connection-tracking.md` and pre-existing untracked scratch files were left untouched. A task report accidentally included in `7a37ec2` was removed from tracking in `2046696`; its local evidence remains. Commits are local to the requested working branch.
