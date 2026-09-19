# Pages API Reference Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan. Steps use checkbox syntax for tracking.

**Goal:** A programmer can look up any public Pages method and find its exact calling forms, arguments, defaults, return value, and relevant errors without reading implementation code.

**Architecture:** Preserve the existing explanatory overview and add a complete, navigable POD reference in the existing modules. Give every named factory its own anchor and short entry; link shared option definitions instead of repeating them in full.

**Tech Stack:** Perl POD, existing Pages tests and examples.

**Spec:** User request of 2026-09-18: retain the high-level documentation and make every method fully usable from its reference entry, particularly exported and class-method forms of `not_found`. This is a bounded documentation change; no separate design document is needed.

## Global constraints

- Documentation only: describe the existing API; no Auth work or runtime redesign.
- Remove `PAGI::Auth` references and recommendations from the Pages POD and
  Pages example guidance; keep the direct authentication status and challenge
  option documentation.
- Preserve developed explanatory prose; make targeted additions and corrections.
- Do not expose private helpers or promote `PAGI::Pages::Application->new` to a user construction API.
- No generated-documentation framework or broad documentation-test infrastructure.
- Stay on `feature/universal-connection-tools`; preserve unrelated dirty files. No push or merge.

## Work map

Only `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` is in scope. Work item: Pages API reference; current planning base `38f4fd8`; owned changes are the Pages POD and directly related example guidance. Local documentation commit only; no deployment or push target. Reconfirm HEAD before implementation.

## Task 1: Add and verify the complete Pages reference

**Files:** Update `lib/PAGI/Pages.pm` and `lib/PAGI/Pages/Application.pm`; update `examples/pages/README.md` only where a direct reference link or corrected example helps. Consult `lib/PAGI/Pages/_Catalog.pm` and `t/pages/*.t` as evidence, not public documentation destinations.

**Interfaces:** Document existing factories, policy construction, rendering hooks, and the returned application's `to_app` and `response_for`. Factory results are immediate `PAGI::Pages::Application` objects; rendering and negotiation occur at invocation or explicit materialization.

- [ ] Inventory every public named factory from the checked-in catalog, the three generic factories, five redirect helpers, constructor, and presentation hooks. Compare the export lists and tests; do not assume every public method is exportable.
- [ ] Give each factory a searchable POD heading. Show its exported, class, and configured-instance forms, positional arguments if any, resulting status, return type, complete accepted option names, required fields, defaults, and direct links to shared option definitions. A reader arriving at `not_found` should not need to infer its signature from `status` or search the synopsis.

Use this shape for the `not_found` entry:

```perl
use PAGI::Pages qw(not_found);
my $page = not_found(detail => 'No matching record');
my $class_page = PAGI::Pages->not_found(detail => 'No matching record');

my $pages = PAGI::Pages->new(as => 'auto', default => 'text');
my $configured_page = $pages->not_found(detail => 'No matching record');
```

State that all three return a deferred 404 application; options are a flat key/value list, with no Request/scope argument. List `as`, `detail`, `type`, `title`, `instance`, `extensions`, `headers`, and `cache_control`. Explain stock title/detail, `about:blank`, default `no-store`, and paired `type`/`title` overrides. Link shared constraints. Show that a configured policy is retained and a per-call `as` overrides policy selection.

- [ ] Add shared option reference entries with accepted Perl value shapes, defaults, applicability, conflicts, and short examples. Separate welcome, error, and redirect option sets. Cover header array shape and reserved fields; problem members/extensions; constructor-only `default`; status-specific `challenge`, `allow`, `length`, `upgrade`, `retry_after`, `blocked_by`, and `login_url`. Put each status's mandatory arguments in that method's own entry as well as linking the shared definition. Verify details against normalization code and tests.
- [ ] Document generic `status($code, %options)` and `redirect($target, %options)` precisely, including custom error requirements, redirect defaults and named-helper restrictions. Document imports and subclass behavior without implying exports use a caller's configured policy.
- [ ] Complete hook reference signatures using method syntax, descriptor keys by page kind, accepted return shapes, and which outputs policy reasserts. Add one small override example. Keep existing ownership explanation and synchronous hook constraints.
- [ ] Give application methods explicit signatures and returns: `$page->to_app()` returns a native coderef; `$page->response_for($source)` immediately returns a concrete Response. Link these from factory return descriptions. Distinguish factory-time validation from invocation/materialization-time errors using actual existing cases; do not promise every failure occurs during construction.
- [ ] Review the reference by looking up `not_found`, `unauthorized`, `method_not_allowed`, a named redirect, and a rendering hook in isolation. Each entry must lead directly to all information needed for a valid call. Check all catalog names have public reference anchors and preserve high-level explanation without wholesale rewriting.
- [ ] Run the existing focused verification and POD checks:

```sh
perlbrew exec --with perl-5.42.2@default podchecker lib/PAGI/Pages.pm lib/PAGI/Pages/Application.pm
perlbrew exec --with perl-5.42.2@default env PERL_FUTURE_NO_XS=1 prove -lr t/pages t/integration-pages-example.t
git diff --check
```

Exercise newly documented examples through existing public APIs where their correctness is not already covered. Do not add tests that merely assert prose text or reproduce catalog data. Full server/transport suites are unnecessary for documentation-only edits.

- [ ] Review the final diff for API accuracy and findability, then commit only owned paths as `docs: add complete Pages API reference`. If code and intended behavior disagree, report the concrete discrepancy before changing behavior.

## Plan self-review

The task covers function/class/instance forms, all public entrypoints, option shapes and defaults, return types, validation timing, subclass hooks, navigation, and focused verification. Runtime behavior and the Auth design remain outside scope. No public documentation or code has been changed while preparing this plan.
