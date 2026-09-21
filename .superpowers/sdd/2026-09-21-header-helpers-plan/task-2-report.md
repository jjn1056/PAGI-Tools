# Task 2 report: parameterized header helpers

## RED

Command: `perlbrew exec --with perl-5.40.0@default prove -l t/utils/headers-parameters.t t/headers.t t/request/01-basic.t t/request/09-form.t`

Result: exit 1. The new utility test could not import the three missing functions; `PAGI::Headers` had no `content_type` method; Request returned unnormalized `APPLICATION/JSON` and accepted malformed `charset=`. `t/request/09-form.t` passed at this stage. During self-review, a narrower `t/headers.t` run also failed as expected because the duplicate-field exception named `get_single` instead of `content_type`.

## GREEN

Command: `perlbrew exec --with perl-5.40.0@default prove -l t/utils/headers-parameters.t t/headers.t t/request/01-basic.t t/request/09-form.t t/utils/headers-auth.t t/auth/07-www-authenticate.t`

Result: exit 0, 6 files, 79 tests, all successful. `git diff --check` and `perlbrew exec --with perl-5.40.0@default podchecker lib/PAGI/Utils/Headers.pm lib/PAGI/Headers.pm lib/PAGI/Request.pm` also returned exit 0.

## Files and self-review

- `lib/PAGI/Utils/Headers.pm`: optional exports, complete-input cursor parser, formatter, shared quoted-string encoder, and POD.
- `lib/PAGI/Headers.pm`: four named readers with leading-value validation, duplicate checks, no mutation, and POD.
- `lib/PAGI/Request.pm`: Content-Type delegation and exact normalized form predicates; POD.
- `t/utils/headers-parameters.t`, `t/headers.t`, `t/request/01-basic.t`, `t/request/09-form.t`: grammar, duplicate, normalization, fallback, and predicate coverage.

No multipart/File migrations were made. The existing auth tests passed after sharing quoted-string formatting. The full suite was not run, per task instruction and its recorded baseline limitations. Unrelated dirty files were left untouched.
